import Testing
@testable import OOMGuardCore

func job(_ pgid: Int32 = 401, gb: Double = 52, agent: Agent? = nil) -> Job {
    Job(pgid: pgid, bytes: UInt64(gb * Double(GB)), processes: 12, leader: "gtimeout",
        command: "timeout python3 make_dataset.py", tier: .normal, agent: agent)
}

/// A reading on a 24GB Mac with RAM full (as during any crunch); tests override what they are about.
func reading(_ t: Double, occupancy: Double = 0.2, pressure: PressureLevel = .normal, headroomGB: Double = 70,
             freeRAM: Int = 20) -> Signals {
    Signals(time: 1000 + t, segments: occupancy, pages: occupancy * 0.9, swapUsed: 5 * GB,
            headroom: UInt64(headroomGB * Double(GB)), ram: 24 * GB, pressure: pressure, level: freeRAM)
}

struct Outcome {
    var kills: [(time: Double, reasons: String, immediate: Bool, occupancy: Double)] = []
    var warns = 0
    var agentMessages = 0
    var logs: [String] = []
    var victimLookups = 0
}

/// Feeds one reading per second for `seconds` and collects what the engine asked for.
func simulate(_ config: Config = Config(), seconds: Int, victim: Job? = job(), _ make: (Double) -> Signals) -> Outcome {
    var engine = Engine(config: config)
    var outcome = Outcome()
    for second in 0..<seconds {
        let signals = make(Double(second))
        let tick = engine.step(signals) { outcome.victimLookups += 1; return victim }
        for action in tick.actions {
            switch action {
            case .kill(_, let reasons, let immediate):
                outcome.kills.append((Double(second), reasons, immediate, signals.occupancy))
            case .warn: outcome.warns += 1
            case .messageAgent: outcome.agentMessages += 1
            case .log(let message): outcome.logs.append(message)
            }
        }
    }
    return outcome
}

@Test func calmMachineNeverKillsWarnsOrScans() {
    // An hour of ordinary noise: occupancy drifting 20-25%, the odd one-second warn blip.
    let outcome = simulate(seconds: 3600) { t in
        reading(t, occupancy: 0.2 + 0.05 * Double(Int(t) % 7) / 7, pressure: Int(t) % 500 == 0 ? .warn : .normal)
    }
    #expect(outcome.kills.isEmpty)
    #expect(outcome.warns == 0)
    #expect(outcome.victimLookups < 20)  // the process table is only scanned during the blips
}

/// 2026-10-11: pressure flipped between critical and warn every few seconds for nine minutes.
/// A guard that needed 30 continuous seconds of critical never fired and the Mac froze.
@Test func flickeringCriticalPressureStillKills() throws {
    let outcome = simulate(seconds: 600) { t in reading(t, pressure: Int(t / 3) % 2 == 0 ? .critical : .warn) }
    let first = try #require(outcome.kills.first)
    #expect(first.time < 60)
    #expect(first.reasons.contains("critical pressure"))
}

@Test func sustainedCriticalPressureKillsInTenSeconds() throws {
    let outcome = simulate(seconds: 30) { t in reading(t, pressure: .critical) }
    #expect(try #require(outcome.kills.first).time <= 10)
}

@Test func fastFillKillsLongBeforeTheLimit() throws {
    // 2% of the compressor per second: 40% -> 98% in 29 seconds.
    let outcome = simulate(seconds: 40) { t in reading(t, occupancy: min(0.40 + 0.02 * t, 0.99)) }
    let first = try #require(outcome.kills.first)
    #expect(first.occupancy < 0.75)
    #expect(first.reasons.contains("full in"))
    #expect(!first.immediate)
}

@Test func fastFillFromNearlyEmptyIsNotBelieved() {
    // Unzipping a big archive fills an empty compressor quickly, then stops: no kill below 50%.
    let outcome = simulate(seconds: 20) { t in reading(t, occupancy: min(0.05 + 0.02 * t, 0.45)) }
    #expect(outcome.kills.isEmpty)
}

@Test func slowCreepWarnsThenKillsAtTheOccupancyThreshold() throws {
    let outcome = simulate(seconds: 400) { t in reading(t, occupancy: 0.55 + 0.001 * t) }
    let first = try #require(outcome.kills.first)
    #expect(outcome.warns >= 1)
    #expect((0.85...0.86).contains(first.occupancy))
}

@Test func emergencyThresholdsKillOnTheFirstSample() throws {
    let full = simulate(seconds: 1) { t in reading(t, occupancy: 0.93) }
    #expect(try #require(full.kills.first).immediate)
    let noSwap = simulate(seconds: 1) { t in reading(t, headroomGB: 1.5) }
    #expect(try #require(noSwap.kills.first).reasons.contains("swap headroom"))
}

@Test func lowSwapHeadroomKillsAfterTwoStrikes() throws {
    let outcome = simulate(seconds: 5) { t in reading(t, headroomGB: 3) }
    #expect(try #require(outcome.kills.first).time == 1)
}

@Test func warnsOnceAndMessagesTheAgentOnceWithoutKilling() {
    let agent = Agent(pid: 300, name: "claude", tty: "ttys004")
    let outcome = simulate(seconds: 500, victim: job(agent: agent)) { t in reading(t, occupancy: 0.62) }
    #expect(outcome.kills.isEmpty)
    #expect(outcome.warns == 1)
    #expect(outcome.agentMessages == 1)
}

@Test func afterAKillOnlyEmergenciesFireUntilMemorySettles() {
    // Occupancy stays at 86% (two-strike arm). Without settling it would kill every 2s.
    var config = Config()
    config.settleSeconds = 20
    let steady = simulate(config, seconds: 20) { t in reading(t, occupancy: 0.86) }
    #expect(steady.kills.map(\.time) == [1])
    // An emergency reading during the settle period still kills.
    let worse = simulate(config, seconds: 6) { t in reading(t, occupancy: t < 4 ? 0.86 : 0.95) }
    #expect(worse.kills.map(\.time) == [1, 4, 5])
}

@Test func nothingToKillIsReportedOnce() {
    let outcome = simulate(seconds: 120, victim: nil) { t in reading(t, occupancy: 0.95) }
    #expect(outcome.kills.isEmpty)
    #expect(outcome.logs.filter { $0.contains("nothing to kill") }.count == 1)
}

@Test func aGapBetweenSamplesIsReportedAsAStallNotAFillRate() {
    var engine = Engine(config: Config())
    _ = engine.step(reading(0, occupancy: 0.50)) { job() }
    // The guard was not scheduled for 90s while occupancy rose 5%: slow, not an emergency.
    let tick = engine.step(reading(90, occupancy: 0.55)) { job() }
    #expect(tick.actions.contains { if case .log(let m) = $0 { m.contains("STALL") } else { false } })
    #expect(!tick.actions.contains { if case .kill = $0 { true } else { false } })
    #expect(tick.sample.eta == .infinity)
}

@Test func pressureArmCanBeDisabled() {
    var config = Config()
    config.pressureCriticalSeconds = 0
    #expect(simulate(config, seconds: 300) { t in reading(t, pressure: .critical) }.kills.isEmpty)
}

/// 2026-10-25 fill test on a 64GB Mac mini: after the pool was killed, free memory was back to
/// 65% within 20s but compressor segment occupancy stayed where the crunch left it for good.
/// Leftover empty segments are not a crunch, so nothing else may die for them.
@Test func leftoverSegmentsWithFreeMemoryDoNotKill() {
    let outcome = simulate(seconds: 600) { t in reading(t, occupancy: 0.95, freeRAM: 65) }
    #expect(outcome.kills.isEmpty)
    #expect(outcome.warns == 0)
}

@Test func raisedPressureMakesFreeMemoryReadingsTight() throws {
    let outcome = simulate(seconds: 3) { t in reading(t, occupancy: 0.93, pressure: .warn, freeRAM: 65) }
    #expect(try #require(outcome.kills.first).immediate)
}

@Test func swapHeadroomCountsEvenWithFreeMemory() throws {
    let outcome = simulate(seconds: 1) { t in reading(t, headroomGB: 1.5, freeRAM: 65) }
    #expect(try #require(outcome.kills.first).reasons.contains("swap headroom"))
}

/// The same fill, replayed: free memory fell 67% -> 36% while occupancy rose 4 points a second.
@Test func realFillFromTheMacMiniKillsOnceTight() throws {
    let trace: [(Double, Int, PressureLevel)] = [(0.165, 67, .normal), (0.186, 63, .normal), (0.282, 48, .normal),
                                                 (0.307, 41, .warn), (0.340, 36, .warn), (0.36, 33, .warn)]
    var config = Config()
    config.killOccupancy = 0.285
    config.killOccupancyNow = 0.335
    let outcome = simulate(config, seconds: trace.count) { t in
        let (occupancy, free, pressure) = trace[Int(t)]
        return reading(t, occupancy: occupancy, pressure: pressure, freeRAM: free)
    }
    #expect(try #require(outcome.kills.first).time == 4)
}
