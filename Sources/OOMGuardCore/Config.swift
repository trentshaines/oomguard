import Foundation

/// Everything oomguard can be told. Every field has a default, so no config file is needed.
public struct Config: Equatable, Sendable {
    /// Seconds between samples.
    public var intervalSeconds: Double = 1
    /// Log and notify what would be killed, but never send a signal.
    public var dryRun = false

    // [trigger] Occupancy is the compressor's fill fraction (segments or pages, whichever is
    // higher); the kernel declares memory exhausted at 0.98. Headroom is room left for swap.
    /// Kill after 2 strikes at or above this occupancy.
    public var killOccupancy: Double = 0.85
    /// Kill immediately at or above this occupancy.
    public var killOccupancyNow: Double = 0.92
    /// Kill after 2 strikes when occupancy would reach 0.98 within this many seconds.
    public var killEtaSeconds: Double = 60
    /// Kill after 2 strikes when swap headroom is below this.
    public var killHeadroomGB: Double = 4
    /// Kill immediately when swap headroom is below this.
    public var killHeadroomNowGB: Double = 2
    /// Kill after this many accumulated seconds of critical kernel pressure. 0 disables:
    /// the level ignores swap and flickers, so it is only a backstop.
    public var pressureCriticalSeconds: Double = 10
    /// Warn you and the owning agent at or above this occupancy.
    public var warnOccupancy: Double = 0.60
    /// Warn when occupancy would reach 0.98 within this many seconds.
    public var warnEtaSeconds: Double = 300
    /// Warn when swap headroom is below this. 0 means the machine's RAM size.
    public var warnHeadroomGB: Double = 0
    /// After a kill, only the immediate triggers may kill again for this long.
    public var settleSeconds: Double = 5
    /// The occupancy and fill-rate triggers only count while memory is actually tight: free
    /// memory (kern.memorystatus_level) at or below this fraction, or kernel pressure above
    /// normal. The kernel frees empty compressor segments lazily, so segment occupancy stays
    /// high for a long time after a crunch ends; without this a kill would be followed by
    /// kills of innocent jobs. 1 makes those triggers count at any time.
    public var tightFreeRAM: Double = 0.40

    // [victim]
    /// Jobs smaller than this are never killed: they cannot be what is breaking the machine.
    public var minSizeGB: Double = 2
    /// Command-line regexes. Matching jobs are killed before any others (oom_score_adj > 0).
    public var prefer: [String] = []
    /// Matching jobs are killed only when nothing else qualifies (oom_score_adj < 0).
    public var avoid: [String] = []
    /// Matching jobs are never killed (oom_score_adj = -1000). Matched against the
    /// group leader's name and full command line.
    public var never: [String] = Config.defaultNever

    // [kill]
    /// Seconds a job gets between SIGTERM and SIGKILL. 0 sends SIGKILL at once, which is the
    /// safe default: near exhaustion a SIGTERM handler may never get to run. The immediate
    /// triggers always SIGKILL.
    public var termSeconds: Double = 0

    // [agents]
    public var agentsEnabled = true
    /// Executable names of coding agents (matched against argv[0] and the process name).
    public var agentNames: [String] = ["claude", "codex"]
    /// Typed into the agent's tmux pane at the warning stage. Placeholders: {size} {command} {pgid}.
    public var agentMessage = Config.defaultAgentMessage
    /// tmux binary; empty means search the usual Homebrew and system locations.
    public var tmuxPath = ""

    // [notify]
    public var notifications = true

    // [recorder] One line of every signal per sample, for calibrating thresholds and post-mortems.
    public var recorderEnabled = true
    /// Samples are kept in two files of at most half this size each.
    public var recorderMaxMB: Double = 50

    // [guard]
    /// Jetsam priority band the guard re-executes itself into at startup, so the kernel's
    /// compressor-shortage kill (which only takes band 0) cannot take the guard. 0 disables.
    public var jetsamBand: Int = 180

    // [hooks] Shell commands run with OOMGUARD_* environment variables.
    public var onWarn = ""
    public var onAgentJob = ""
    public var preKill = ""
    public var postKill = ""

    public init() {}

    public static let defaultNever = [
        "^(tmux|tmux: server)$", "^(alacritty|Alacritty|iTerm2|Terminal|WezTerm|wezterm-gui|kitty|ghostty|Ghostty|Warp)$",
        "^(Finder|Dock|SystemUIServer|loginwindow|WindowManager|ControlCenter)$", "^oomguard$",
    ]

    public static let defaultAgentMessage =
        "[oomguard] This Mac is running low on memory. A job you started is using {size} "
        + "(process group {pgid}): {command}. Stop it or cut its memory use now (fewer workers, smaller "
        + "batches). If memory keeps filling, oomguard will kill it without further warning."

    /// Where samples and events are kept.
    public static var stateDirectory: String {
        let base = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".local/state")
        return (base as NSString).appendingPathComponent("oomguard")
    }

    public static var defaultPath: String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")
        return (base as NSString).appendingPathComponent("oomguard/config.toml")
    }
}

public struct ConfigError: Error, CustomStringConvertible {
    public let description: String
}

extension Config {
    /// Loads `path`, or the defaults when the file does not exist.
    public static func load(path: String) throws -> Config {
        guard FileManager.default.fileExists(atPath: path) else { return Config() }
        let text = try String(contentsOfFile: path, encoding: .utf8)
        do {
            return try Config(toml: parseTOML(text))
        } catch let error as TOMLError {
            throw ConfigError(description: "\(path): \(error)")
        } catch let error as ConfigError {
            throw ConfigError(description: "\(path): \(error)")
        }
    }

    public init(toml: [String: TOMLValue]) throws {
        self.init()
        var values = toml
        func take(_ key: String) -> TOMLValue? { values.removeValue(forKey: key) }
        func number(_ key: String, _ current: Double) throws -> Double {
            switch take(key) {
            case nil: return current
            case .integer(let i)?: return Double(i)
            case .float(let d)?: return d
            default: throw ConfigError(description: "\(key) must be a number")
            }
        }
        func bool(_ key: String, _ current: Bool) throws -> Bool {
            switch take(key) {
            case nil: return current
            case .bool(let b)?: return b
            default: throw ConfigError(description: "\(key) must be true or false")
            }
        }
        func string(_ key: String, _ current: String) throws -> String {
            switch take(key) {
            case nil: return current
            case .string(let s)?: return s
            default: throw ConfigError(description: "\(key) must be a string")
            }
        }
        func strings(_ key: String, _ current: [String]) throws -> [String] {
            switch take(key) {
            case nil: return current
            case .array(let items)?:
                return try items.map {
                    guard case .string(let s) = $0 else { throw ConfigError(description: "\(key) must be a list of strings") }
                    return s
                }
            default: throw ConfigError(description: "\(key) must be a list of strings")
            }
        }

        intervalSeconds = try number("interval_seconds", intervalSeconds)
        dryRun = try bool("dry_run", dryRun)
        killOccupancy = try number("trigger.kill_occupancy", killOccupancy)
        killOccupancyNow = try number("trigger.kill_occupancy_now", killOccupancyNow)
        killEtaSeconds = try number("trigger.kill_eta_seconds", killEtaSeconds)
        killHeadroomGB = try number("trigger.kill_headroom_gb", killHeadroomGB)
        killHeadroomNowGB = try number("trigger.kill_headroom_now_gb", killHeadroomNowGB)
        pressureCriticalSeconds = try number("trigger.pressure_critical_seconds", pressureCriticalSeconds)
        warnOccupancy = try number("trigger.warn_occupancy", warnOccupancy)
        warnEtaSeconds = try number("trigger.warn_eta_seconds", warnEtaSeconds)
        warnHeadroomGB = try number("trigger.warn_headroom_gb", warnHeadroomGB)
        settleSeconds = try number("trigger.settle_seconds", settleSeconds)
        tightFreeRAM = try number("trigger.tight_free_ram", tightFreeRAM)
        minSizeGB = try number("victim.min_size_gb", minSizeGB)
        prefer = try strings("victim.prefer", prefer)
        avoid = try strings("victim.avoid", avoid)
        never = try strings("victim.never", never) + strings("victim.never_extra", [])
        termSeconds = try number("kill.term_seconds", termSeconds)
        agentsEnabled = try bool("agents.enabled", agentsEnabled)
        agentNames = try strings("agents.names", agentNames)
        agentMessage = try string("agents.message", agentMessage)
        tmuxPath = try string("agents.tmux", tmuxPath)
        notifications = try bool("notify.enabled", notifications)
        recorderEnabled = try bool("recorder.enabled", recorderEnabled)
        recorderMaxMB = try number("recorder.max_mb", recorderMaxMB)
        jetsamBand = Int(try number("guard.jetsam_band", Double(jetsamBand)))
        onWarn = try string("hooks.on_warn", onWarn)
        onAgentJob = try string("hooks.on_agent_job", onAgentJob)
        preKill = try string("hooks.pre_kill", preKill)
        postKill = try string("hooks.post_kill", postKill)

        if let unknown = values.keys.sorted().first {
            throw ConfigError(description: "unknown key \(unknown)")
        }
        for pattern in prefer + avoid + never where (try? NSRegularExpression(pattern: pattern)) == nil {
            throw ConfigError(description: "invalid regex \(pattern)")
        }
        let nonNegative = [killEtaSeconds, killHeadroomGB, killHeadroomNowGB, pressureCriticalSeconds, warnEtaSeconds,
                           warnHeadroomGB, settleSeconds, termSeconds, minSizeGB, recorderMaxMB]
        guard intervalSeconds > 0, nonNegative.allSatisfy({ $0 >= 0 }) else {
            throw ConfigError(description: "durations and sizes must not be negative")
        }
        for (name, value) in [("kill_occupancy", killOccupancy), ("kill_occupancy_now", killOccupancyNow), ("warn_occupancy", warnOccupancy),
                             ("tight_free_ram", tightFreeRAM)]
        where !(0...1).contains(value) {
            throw ConfigError(description: "trigger.\(name) must be a fraction between 0 and 1")
        }
        guard jetsamBand == 0 || (30...210).contains(jetsamBand) else {
            throw ConfigError(description: "guard.jetsam_band must be 0 or between 30 and 210")
        }
    }
}
