import Darwin
import Foundation
import OOMGuardCore

let version = "0.2.1"

let usage = """
oomguard \(version): an early OOM killer for macOS.

macOS does not kill a runaway job when memory runs out: it compresses, swaps, pauses apps
and finally freezes. oomguard watches what the kernel actually runs out of (compressor
space and room for swap) and kills the biggest job (process group) seconds before that.
Coding agents (Claude Code, Codex) that started the job are warned earlier.

Usage: oomguard [command] [options]

Commands:
  run       Watch memory and kill when needed (default; what the service runs)
  status    Show the readings, the biggest jobs and which one would be killed
  log       Show recent events; -s/--samples shows the per-second readings instead
  exec      Run a command under a kernel-enforced memory cap:
              oomguard exec --max-gb 16 -- python3 train.py
            The kernel kills it the moment it passes the cap. Per process: children
            are not capped unless they are started through `oomguard exec` too.
  config    Validate the config file and print the effective settings
  version   Print the version

Options:
  -c, --config PATH          Config file (default: \(Config.defaultPath))
  -n, --dry-run              Log and notify what would be killed, but never kill
      --min-size-gb N        Never kill jobs smaller than this
      --interval N           Seconds between samples
      --simulate KEY=VALUE   Override a reading to test rules and hooks: occupancy=0.9
                             (also sets free RAM to 10%), free-ram=0.5, headroom-gb=3 or
                             pressure=critical. Repeatable, applied in order. Kills are
                             real unless combined with --dry-run.
  -h, --help                 Show this help
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("oomguard: \(message)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
var command = "run"
if let first = args.first, !first.hasPrefix("-") { command = first; args.removeFirst() }

// `exec` owns everything after `--`.
var execCommand: [String] = []
if command == "exec", let separator = args.firstIndex(of: "--") {
    execCommand = Array(args[(separator + 1)...])
    args = Array(args[..<separator])
}

var configPath = Config.defaultPath
var overrides: [(inout Config) -> Void] = []
var simulations: [(inout Signals) -> Void] = []
var showSamples = false
var lines = 30
var maxGB: Double?
while !args.isEmpty {
    let flag = args.removeFirst()
    func value() -> String {
        guard !args.isEmpty else { fail("\(flag) needs a value") }
        return args.removeFirst()
    }
    func number() -> Double {
        let text = value()
        guard let n = Double(text), n >= 0 else { fail("\(flag) needs a non-negative number, not \(text)") }
        return n
    }
    switch flag {
    case "-c", "--config": configPath = value()
    case "-n", "--dry-run": overrides.append { $0.dryRun = true }
    case "--min-size-gb": let n = number(); overrides.append { $0.minSizeGB = n }
    case "--interval": let n = number(); overrides.append { $0.intervalSeconds = max(n, 0.1) }
    case "--max-gb" where command == "exec": maxGB = number()
    case "-s" where command == "log", "--samples" where command == "log": showSamples = true
    case "--lines" where command == "log": lines = Int(number())
    case "--simulate":
        let pair = value().split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { fail("--simulate takes KEY=VALUE") }
        switch (pair[0], Double(pair[1]), pair[1]) {
        case ("occupancy", let n?, _) where (0...1).contains(n):
            // A full compressor with plenty of free memory is not a crunch; simulate one.
            simulations.append { $0.segments = n; $0.pages = n; $0.level = min($0.level, 10) }
        case ("free-ram", let n?, _) where (0...1).contains(n):
            simulations.append { $0.level = Int(n * 100) }
        case ("headroom-gb", let n?, _) where n >= 0:
            simulations.append { $0.headroom = UInt64(n * 1_073_741_824) }
        case ("pressure", _, "normal"): simulations.append { $0.pressure = .normal }
        case ("pressure", _, "warn"): simulations.append { $0.pressure = .warn }
        case ("pressure", _, "critical"): simulations.append { $0.pressure = .critical }
        default: fail("--simulate takes occupancy=0..1, free-ram=0..1, headroom-gb=N or pressure=normal|warn|critical")
        }
    case "-h", "--help": print(usage); exit(0)
    default: fail("unknown option \(flag)\n\n\(usage)")
    }
}

var config: Config
do {
    config = try Config.load(path: configPath)
} catch {
    fail("\(error)")
}
for apply in overrides { apply(&config) }

func tail(_ path: String, _ count: Int) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("nothing recorded yet at \(path)")
        return
    }
    print(text.split(separator: "\n").suffix(count).joined(separator: "\n"))
}

switch command {
case "run":
    // Move out of jetsam band 0, the only band the kernel's compressor-shortage kill takes.
    // The guard re-executes itself once; the environment variable stops a loop.
    var protection: String
    if config.jetsamBand == 0 {
        protection = "jetsam band left as launched (guard.jetsam_band = 0)"
    } else if let band = ProcessInfo.processInfo.environment["OOMGUARD_BAND"] {
        protection = "re-executed into jetsam band \(band)" + (Spawn.band(of: getpid()).map { " (kernel reports \($0))" } ?? "")
    } else {
        var environment = ProcessInfo.processInfo.environment
        environment["OOMGUARD_BAND"] = String(config.jetsamBand)
        var argv = CommandLine.arguments
        argv[0] = Bundle.main.executablePath ?? argv[0]
        let error = Spawn.exec(argv, band: Int32(config.jetsamBand), environment: environment)
        // Only reached if the re-exec failed; carry on unprotected rather than not at all.
        protection = "WARNING: could not move into jetsam band \(config.jetsamBand) (\(String(cString: strerror(error))))"
            + "; the kernel's own memory-shortage kill may take the guard"
    }
    Runner(config: config, simulate: simulations.isEmpty ? nil : { signals in simulations.forEach { $0(&signals) } })
        .run(protection: protection)

case "status":
    let runner = Runner(config: config)
    let s = System.signals()
    print("compressor:    \(Int(s.occupancy * 100))% full (segments \(Int(s.segments * 100))%, pages \(Int(s.pages * 100))%); "
          + "the kernel gives up at 98%, oomguard kills at \(Int(config.killOccupancy * 100))%")
    print("swap:          \(gb(s.swapUsed)) used, \(gb(s.headroom)) of headroom; oomguard kills under \(config.killHeadroomGB)GB")
    let tight = s.pressure > .normal || Double(s.level) <= config.tightFreeRAM * 100
    print("pressure:      \(s.pressure), \(s.level)% of memory free (kern.memorystatus_level); "
          + (tight ? "memory is tight: compressor triggers are live" : "compressor triggers wait for free memory under \(percent(config.tightFreeRAM)) or raised pressure"))
    // Under sudo, look for the invoking user's guard.
    let user = ProcessInfo.processInfo.environment["SUDO_UID"].flatMap(UInt32.init) ?? getuid()
    let guards = System.processes(uid: user).filter {
        $0.pid != getpid() && $0.name == "oomguard" && System.arguments($0.pid).dropFirst().first.map { $0 == "run" || $0.hasPrefix("-") } ?? true
    }
    if guards.isEmpty {
        print("guard:         NOT RUNNING (start it with `make install-service` or `brew services start oomguard`)")
    } else {
        for g in guards {
            let band = Spawn.band(of: g.pid).map { "jetsam band \($0)" } ?? "jetsam band readable only as root (sudo oomguard status)"
            print("guard:         running, pid \(g.pid), \(band)")
        }
    }
    print("config:        \(FileManager.default.fileExists(atPath: configPath) ? configPath : "defaults (no \(configPath))")"
          + (config.dryRun ? " (dry run)" : ""))
    let jobs = runner.candidates(minBytes: 256 * 1_048_576)
    let minBytes = UInt64(config.minSizeGB * 1_073_741_824)
    let victim = jobs.first { $0.bytes >= minBytes }
    print("\nbiggest jobs (process groups):")
    for job in jobs.prefix(10) {
        let mark = job.pgid == victim?.pgid ? "→" : " "
        let tier = job.tier == .normal ? "" : " [\(job.tier)]"
        print("\(mark) \(gb(job.bytes).padding(toLength: 7, withPad: " ", startingAt: 0)) \(String(job.processes).padding(toLength: 4, withPad: " ", startingAt: 0))procs  \(job.command.prefix(90))\(tier)")
    }
    if let victim {
        let agent = Jobs.agent(for: victim, processes: System.processes(), names: config.agentNames, arguments: System.arguments)
        print("\n→ would be killed if memory ran out now"
              + (agent.map { " (started by \($0.name), pid \($0.pid), which is warned first)" } ?? ""))
    } else {
        print("\nno job is over \(config.minSizeGB)GB; nothing would be killed")
    }

case "log":
    tail(showSamples ? Recorder.samplesPath : Recorder.eventsPath, lines + (showSamples ? 1 : 0))

case "exec":
    guard !execCommand.isEmpty, let maxGB, maxGB > 0 else {
        fail("usage: oomguard exec --max-gb N -- command [args...]")
    }
    guard Spawn.available else { fail("this macOS no longer exports posix_spawnattr_setjetsam_ext, so exec cannot cap memory") }
    let error = Spawn.exec(execCommand, limitMB: Int32(min(maxGB * 1024, Double(Int32.max))))
    fail("cannot run \(execCommand[0]): \(String(cString: strerror(error)))")

case "config":
    print("""
    file:                      \(FileManager.default.fileExists(atPath: configPath) ? configPath : "none (defaults)")
    interval_seconds:          \(config.intervalSeconds)
    dry_run:                   \(config.dryRun)
    kill_occupancy:            \(config.killOccupancy) (immediately at \(config.killOccupancyNow))
    kill_eta_seconds:          \(config.killEtaSeconds)
    kill_headroom_gb:          \(config.killHeadroomGB) (immediately under \(config.killHeadroomNowGB))
    pressure_critical_seconds: \(config.pressureCriticalSeconds)
    tight_free_ram:            \(config.tightFreeRAM)
    warn_occupancy:            \(config.warnOccupancy)
    warn_eta_seconds:          \(config.warnEtaSeconds)
    warn_headroom_gb:          \(config.warnHeadroomGB == 0 ? "RAM size" : String(config.warnHeadroomGB))
    settle_seconds:            \(config.settleSeconds)
    min_size_gb:               \(config.minSizeGB)
    prefer:                    \(config.prefer)
    avoid:                     \(config.avoid)
    never:                     \(config.never)
    term_seconds:              \(config.termSeconds)
    agents:                    \(config.agentsEnabled ? "\(config.agentNames)" : "off")
    notifications:             \(config.notifications)
    recorder:                  \(config.recorderEnabled ? "\(Config.stateDirectory), up to \(Int(config.recorderMaxMB))MB" : "off")
    jetsam_band:               \(config.jetsamBand == 0 ? "unchanged" : String(config.jetsamBand))
    hooks:                     \([("on_warn", config.onWarn), ("on_agent_job", config.onAgentJob), ("pre_kill", config.preKill), ("post_kill", config.postKill)].filter { !$0.1.isEmpty }.map { $0.0 })
    """)

case "version":
    print(version)

default:
    fail("unknown command \(command)\n\n\(usage)")
}
