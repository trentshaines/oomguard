/// What the engine wants done. The engine itself never touches the system, so the whole
/// policy is testable with synthetic samples.
public enum Action: Equatable, Sendable {
    case log(String)
    /// Tell the user memory is getting tight, and why. The job is the would-be victim, if any.
    case warn(Job?, reasons: String)
    /// Tell the coding agent that owns this job to fix it while there is still time.
    case messageAgent(Job)
    /// Kill the job. `immediate` means an emergency trigger fired: SIGKILL, no hooks first.
    case kill(Job, reasons: String, immediate: Bool)
}

/// A raw reading plus what the engine derived from recent history.
public struct Sample: Equatable, Sendable {
    public var signals: Signals
    /// Seconds until occupancy reaches the kernel's 98% limit at the recent fill rate.
    public var eta: Double
    public var swapinsPerSecond: Double
    /// Seconds since the previous sample; a large value means the guard itself was stalled.
    public var lag: Double
    /// Memory is actually tight: little free memory, or kernel pressure above normal. Only
    /// then do the compressor readings mean a crunch rather than leftover empty segments.
    public var tight: Bool
}

public struct Tick: Sendable {
    public var sample: Sample
    /// The biggest kill candidate, looked up only while something is elevated.
    public var top: Job?
    public var actions: [Action]
}

/// The policy. Every trigger is an arm with a leaky bucket of strikes: a sample that trips the
/// arm adds one, a clean sample drains half, and the arm fires at its threshold. Requiring
/// *continuous* pressure fails when the signal flickers (the bucket resets every few seconds
/// and never fills); resetting on one clean sample is how a Mac froze on 2026-10-11 with the
/// guard watching. Immediate arms have a threshold of one.
///
/// The compressor arms (occupancy, time to full) only count while memory is tight; see
/// `Config.tightFreeRAM`.
///
///   warn   occupancy >= warnOccupancy, eta < warnEtaSeconds or headroom low
///          -> notify the user, message the agent that owns the biggest job
///   kill   any arm fires -> kill the biggest job, then let memory settle
public struct Engine: Sendable {
    public let config: Config
    var history: [Signals] = []
    var strikes: [String: Double] = [:]
    var warnedAt = -Double.infinity
    var agentToldAt: [Int32: Double] = [:]
    var settleUntil = -Double.infinity
    var reportedNoVictim = false
    var lastPressure: PressureLevel = .normal

    /// Fill rate is measured over about this long.
    static let rateWindow: Double = 10
    /// Re-warn (and re-message an agent) after this long.
    static let rewarnSeconds: Double = 600
    /// The kernel's own exhaustion threshold.
    static let kernelLimit = 0.98

    public init(config: Config) { self.config = config }

    struct Arm {
        let name: String
        let strikesNeeded: Double
        let tripped: (Sample) -> Bool
    }

    var arms: [Arm] {
        let gb = 1_073_741_824.0
        var arms = [
            Arm(name: "occupancy >= \(percent(config.killOccupancyNow))", strikesNeeded: 1) { $0.tight && $0.signals.occupancy >= config.killOccupancyNow },
            Arm(name: "swap headroom < \(config.killHeadroomNowGB)GB", strikesNeeded: 1) { Double($0.signals.headroom) < config.killHeadroomNowGB * gb },
            Arm(name: "occupancy >= \(percent(config.killOccupancy))", strikesNeeded: 2) { $0.tight && $0.signals.occupancy >= config.killOccupancy },
            // A fast fill from nearly empty is common and harmless; only believe it from half full.
            Arm(name: "full in < \(Int(config.killEtaSeconds))s", strikesNeeded: 2) { $0.tight && $0.eta < config.killEtaSeconds && $0.signals.occupancy >= 0.5 },
            Arm(name: "swap headroom < \(config.killHeadroomGB)GB", strikesNeeded: 2) { Double($0.signals.headroom) < config.killHeadroomGB * gb },
        ]
        if config.pressureCriticalSeconds > 0 {
            arms.append(Arm(name: "critical pressure", strikesNeeded: max(config.pressureCriticalSeconds / config.intervalSeconds, 1)) {
                $0.signals.pressure == .critical
            })
        }
        return arms
    }

    func warnReasons(_ s: Sample) -> [String] {
        let warnHeadroom = config.warnHeadroomGB > 0 ? config.warnHeadroomGB * 1_073_741_824 : Double(s.signals.ram)
        var reasons: [String] = []
        if s.tight && s.signals.occupancy >= config.warnOccupancy { reasons.append("compressor \(percent(s.signals.occupancy)) full") }
        if s.tight && s.eta < config.warnEtaSeconds && s.signals.occupancy >= 0.3 { reasons.append("full in about \(Int(s.eta))s") }
        if Double(s.signals.headroom) < warnHeadroom { reasons.append("\(gb(s.signals.headroom)) of swap headroom left") }
        return reasons
    }

    /// Feeds one reading through the policy. `victim` is called at most once, and only when
    /// something is elevated, so a calm machine never scans its process table.
    public mutating func step(_ signals: Signals, victim: () -> Job?) -> Tick {
        let sample = derive(signals)
        history.append(signals)
        history.removeAll { signals.time - $0.time > Engine.rateWindow + 5 }
        var actions: [Action] = []

        if sample.lag > max(5 * config.intervalSeconds, 5) {
            actions.append(.log("STALL: \(Int(sample.lag))s since the previous sample; the guard was not running"))
        }
        if signals.pressure != lastPressure {
            actions.append(.log("pressure \(lastPressure) -> \(signals.pressure)"))
            lastPressure = signals.pressure
        }

        var fired: [Arm] = []
        for arm in arms {
            let count = arm.tripped(sample) ? (strikes[arm.name] ?? 0) + 1 : max((strikes[arm.name] ?? 0) - 0.5, 0)
            strikes[arm.name] = count
            if count >= arm.strikesNeeded && (arm.strikesNeeded <= 1 || signals.time >= settleUntil) { fired.append(arm) }
        }
        let reasons = warnReasons(sample)
        let elevated = !fired.isEmpty || !reasons.isEmpty || signals.pressure > .normal || signals.occupancy >= 0.3
        let top = elevated ? victim() : nil

        if !fired.isEmpty {
            strikes.removeAll()
            let why = fired.map(\.name).joined(separator: ", ")
            if let job = top {
                actions.append(.kill(job, reasons: why, immediate: fired.contains { $0.strikesNeeded <= 1 }))
                history.removeAll()  // measure the fill rate afresh after the kill
                settleUntil = signals.time + config.settleSeconds
                agentToldAt[job.pgid] = nil
                reportedNoVictim = false
            } else if !reportedNoVictim {
                actions.append(.log("\(why), but no job is over \(config.minSizeGB)GB; nothing to kill"))
                reportedNoVictim = true
            }
        } else if !reasons.isEmpty {
            if signals.time - warnedAt >= Engine.rewarnSeconds {
                warnedAt = signals.time
                actions.append(.warn(top, reasons: reasons.joined(separator: ", ")))
            }
            if config.agentsEnabled, let job = top, job.agent != nil,
               signals.time - (agentToldAt[job.pgid] ?? -.infinity) >= Engine.rewarnSeconds {
                agentToldAt[job.pgid] = signals.time
                actions.append(.messageAgent(job))
            }
        } else {
            reportedNoVictim = false
        }
        return Tick(sample: sample, top: top, actions: actions)
    }

    func derive(_ signals: Signals) -> Sample {
        var eta = Double.infinity
        // The oldest reading within the window, at least half a window back.
        if let old = history.first(where: { signals.time - $0.time <= Engine.rateWindow + 1 }),
           signals.time - old.time >= Engine.rateWindow / 2 {
            let rate = (signals.occupancy - old.occupancy) / (signals.time - old.time)
            if rate > 0 { eta = max((Engine.kernelLimit - signals.occupancy) / rate, 0) }
        }
        var swapins = 0.0
        var lag = 0.0
        if let previous = history.last {
            lag = signals.time - previous.time
            if lag > 0, signals.swapins >= previous.swapins { swapins = Double(signals.swapins - previous.swapins) / lag }
        }
        let tight = signals.pressure > .normal || Double(signals.level) <= config.tightFreeRAM * 100
        return Sample(signals: signals, eta: eta, swapinsPerSecond: swapins, lag: lag, tight: tight)
    }
}

public func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
