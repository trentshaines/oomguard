import Darwin
import Foundation

/// Carries out the engine's actions: sampling, scanning, signals, notifications, tmux and hooks.
public final class Runner {
    let config: Config
    var engine: Engine
    let rules: Rules
    let recorder: Recorder
    let ownPgid = getpgrp()
    /// Overrides applied to every reading (for testing rules and hooks without a memory crisis).
    let simulate: ((inout Signals) -> Void)?

    public init(config: Config, simulate: ((inout Signals) -> Void)? = nil) {
        self.config = config
        self.simulate = simulate
        self.engine = Engine(config: config)
        self.rules = Rules(config)
        self.recorder = Recorder(enabled: config.recorderEnabled, maxMB: config.recorderMaxMB)
    }

    /// `protection` says what happened to the guard's own jetsam band, for the start-up line.
    public func run(protection: String? = nil) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        log("oomguard started (pid \(getpid())\(config.dryRun ? ", dry run" : "")); kills the biggest job over "
            + "\(config.minSizeGB)GB at \(percent(config.killOccupancy)) compressor occupancy, under "
            + "\(Int(config.killEtaSeconds))s to full, or under \(config.killHeadroomGB)GB of swap headroom")
        if let protection { log(protection) }
        if simulate != nil { log("SIMULATING readings: kills are real unless --dry-run") }
        while true {
            var signals = System.signals()
            simulate?(&signals)
            let tick = engine.step(signals) { self.candidates().first }
            let eventful = !tick.actions.isEmpty
            recorder.record(tick.sample, top: tick.top, durable: eventful)
            for action in tick.actions { perform(action, sample: tick.sample) }
            Thread.sleep(forTimeInterval: config.intervalSeconds)
        }
    }

    /// Kill candidates, best first, with the owning agent resolved for the first one.
    public func candidates(minBytes: UInt64? = nil) -> [Job] {
        let processes = System.processes()
        var jobs = Jobs.build(
            processes: processes, ownPgid: ownPgid,
            minBytes: minBytes ?? UInt64(config.minSizeGB * 1_073_741_824), rules: rules,
            arguments: System.arguments)
        if !jobs.isEmpty {
            jobs[0].agent = Jobs.agent(for: jobs[0], processes: processes, names: config.agentNames, arguments: System.arguments)
        }
        return jobs
    }

    func log(_ message: String) { recorder.event(message) }

    func perform(_ action: Action, sample: Sample) {
        switch action {
        case .log(let message):
            log(message)
        case .warn(let job, let reasons):
            log("WARN \(reasons)" + (job.map { "; biggest job \(describe($0))" } ?? ""))
            notify("Memory is getting tight (\(reasons))." + (job.map { " Biggest job: \(short($0)), \(gb($0.bytes))." } ?? ""))
            if let job { hook(config.onWarn, event: "warn", job: job) }
        case .messageAgent(let job):
            guard let agent = job.agent else { return }
            let pane = agent.tty.flatMap(tmuxPane)
            log("AGENT \(agent.name) pid \(agent.pid) owns \(describe(job)); "
                + (pane.map { "messaging tmux pane \($0)" } ?? "not in tmux, hook only"))
            if let pane { sendToPane(pane, message: agentMessage(job)) }
            hook(config.onAgentJob, event: "agent_job", job: job, extra: [
                "OOMGUARD_AGENT_PID": String(agent.pid), "OOMGUARD_AGENT_NAME": agent.name,
                "OOMGUARD_TMUX_PANE": pane ?? "", "OOMGUARD_MESSAGE": agentMessage(job),
            ])
        case .kill(let job, let reasons, let immediate):
            kill(job, reasons: reasons, immediate: immediate, sample: sample)
        }
    }

    func kill(_ job: Job, reasons: String, immediate: Bool, sample: Sample) {
        let s = sample.signals
        let state = "\(reasons); compressor \(percent(s.occupancy)), swap headroom \(gb(s.headroom)), pressure \(s.pressure)"
        if config.dryRun {
            log("DRY RUN would kill \(describe(job)) [\(state)]")
            notify("Would kill \(short(job)) (\(gb(job.bytes))). Dry run: nothing was killed.")
            return
        }
        // Stop the job growing before anything else: stopping is instant and needs no memory.
        Darwin.killpg(job.pgid, SIGSTOP)
        log("KILL \(describe(job)) [\(state)]")
        if !immediate {
            hook(config.preKill, event: "pre_kill", job: job, wait: true)
            if config.termSeconds > 0 {
                Darwin.killpg(job.pgid, SIGTERM)
                Darwin.killpg(job.pgid, SIGCONT)  // a stopped process cannot run its SIGTERM handler
                waitForExit(job.pgid, seconds: config.termSeconds)
            }
        }
        Darwin.killpg(job.pgid, SIGKILL)
        waitForExit(job.pgid, seconds: 10)
        if groupAlive(job.pgid) { log("group \(job.pgid) still has processes 10s after SIGKILL") }
        notify("Killed \(short(job)) (\(gb(job.bytes))) before this Mac ran out of memory.")
        hook(config.postKill, event: "post_kill", job: job)
    }

    func waitForExit(_ pgid: Int32, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, groupAlive(pgid) { Thread.sleep(forTimeInterval: 0.1) }
    }

    func groupAlive(_ pgid: Int32) -> Bool { Darwin.killpg(pgid, 0) == 0 }

    // MARK: agents

    func agentMessage(_ job: Job) -> String {
        return config.agentMessage
            .replacingOccurrences(of: "{size}", with: gb(job.bytes))
            .replacingOccurrences(of: "{command}", with: String(job.command.prefix(200)))
            .replacingOccurrences(of: "{pgid}", with: String(job.pgid))
    }

    var tmux: String? {
        let candidates = config.tmuxPath.isEmpty ? ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] : [config.tmuxPath]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The tmux pane whose terminal is `tty`.
    func tmuxPane(_ tty: String) -> String? {
        guard let tmux else { return nil }
        let out = shell(tmux, ["list-panes", "-a", "-F", "#{pane_tty} #{pane_id}"])
        return out.split(separator: "\n").lazy.compactMap { line -> String? in
            let parts = line.split(separator: " ")
            return parts.count == 2 && parts[0] == "/dev/\(tty)" ? String(parts[1]) : nil
        }.first
    }

    func sendToPane(_ pane: String, message: String) {
        guard let tmux else { return }
        _ = shell(tmux, ["send-keys", "-t", pane, "-l", message])
        Thread.sleep(forTimeInterval: 0.3)
        _ = shell(tmux, ["send-keys", "-t", pane, "Enter"])
    }

    // MARK: side effects

    func notify(_ message: String) {
        guard config.notifications else { return }
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        _ = shell("/usr/bin/osascript", ["-e", "display notification \"\(escaped)\" with title \"oomguard\""], wait: false)
    }

    func hook(_ command: String, event: String, job: Job, extra: [String: String] = [:], wait: Bool = false) {
        guard !command.isEmpty else { return }
        var env = ProcessInfo.processInfo.environment
        env["OOMGUARD_EVENT"] = event
        env["OOMGUARD_PGID"] = String(job.pgid)
        env["OOMGUARD_BYTES"] = String(job.bytes)
        env["OOMGUARD_COMMAND"] = job.command
        env["OOMGUARD_DRY_RUN"] = config.dryRun ? "1" : "0"
        env.merge(extra) { _, new in new }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = env
        do {
            try process.run()
        } catch {
            log("hook \(event) failed to start: \(error)")
            return
        }
        guard wait else { return }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            log("hook \(event) still running after 3s; continuing without it")
        }
    }

    @discardableResult
    func shell(_ path: String, _ args: [String], wait: Bool = true) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        guard wait else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

public func gb(_ bytes: UInt64) -> String { String(format: "%.1fGB", Double(bytes) / 1_073_741_824) }

func short(_ job: Job) -> String {
    let words = job.command.split(separator: " ").prefix(3).map { ($0 as NSString).lastPathComponent }
    return String(words.joined(separator: " ").prefix(60))
}

public func describe(_ job: Job) -> String {
    "\(gb(job.bytes)) group \(job.pgid) (\(job.processes) processes): \(job.command.prefix(160))"
}
