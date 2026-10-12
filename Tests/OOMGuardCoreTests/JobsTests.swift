import Testing
@testable import OOMGuardCore

let GB: UInt64 = 1_073_741_824

func proc(_ pid: Int32, ppid: Int32, pgid: Int32, _ name: String, gb: Double = 0.01, tty: String? = nil) -> ProcessInfoRecord {
    ProcessInfoRecord(pid: pid, ppid: ppid, pgid: pgid, uid: 501, name: name, tty: tty, footprint: UInt64(gb * Double(GB)))
}

/// The 2026-10-10 crash: a Claude session ran `timeout python3 make_dataset.py`, which
/// started ten ~5GB workers in their own process group.
let crash: [ProcessInfoRecord] = [
    proc(100, ppid: 1, pgid: 100, "tmux"),
    proc(200, ppid: 100, pgid: 200, "fish", tty: "ttys004"),
    proc(300, ppid: 200, pgid: 300, "2.1.296", gb: 0.4, tty: "ttys004"),  // Claude Code reports its version as its name
    proc(301, ppid: 300, pgid: 300, "node", gb: 0.2, tty: "ttys004"),     // its MCP server
    proc(400, ppid: 300, pgid: 400, "zsh", tty: "ttys004"),
    proc(401, ppid: 400, pgid: 401, "gtimeout", tty: "ttys004"),
    proc(402, ppid: 401, pgid: 401, "Python", gb: 0.1, tty: "ttys004"),
] + (0..<10).map { proc(410 + $0, ppid: 402, pgid: 401, "Python", gb: 5.2, tty: "ttys004") }
    + [proc(900, ppid: 1, pgid: 900, "OrbStack Helper", gb: 6)]

let argv: [Int32: [String]] = [
    300: ["claude", "--resume", "abc"],
    401: ["timeout", "3000", "python3", "make_dataset.py"],
    900: ["/Applications/OrbStack.app/Contents/MacOS/OrbStack Helper", "vmgr"],
]

func build(_ processes: [ProcessInfoRecord], _ config: Config = Config(), minGB: Double = 2) -> [Job] {
    Jobs.build(processes: processes, ownPgid: 1, minBytes: UInt64(minGB * Double(GB)), rules: Rules(config)) { argv[$0] ?? [] }
}

@Test func groupsWorkerPoolIntoOneJobAboveTheAgent() throws {
    let jobs = build(crash)
    #expect(jobs.map(\.pgid) == [401, 900])
    let pool = try #require(jobs.first)
    #expect(pool.processes == 12)
    #expect(pool.bytes > 52 * GB)
    #expect(pool.command == "timeout 3000 python3 make_dataset.py")
}

@Test func findsTheOwningAgentByArgv() throws {
    let pool = try #require(build(crash).first)
    let agent = Jobs.agent(for: pool, processes: crash, names: ["claude", "codex"]) { argv[$0] ?? [] }
    #expect(agent == Agent(pid: 300, name: "claude", tty: "ttys004"))
    let orb = build(crash)[1]
    #expect(Jobs.agent(for: orb, processes: crash, names: ["claude"]) { argv[$0] ?? [] } == nil)
}

@Test func preferAvoidAndNeverReorderCandidates() {
    var config = Config()
    config.avoid = ["make_dataset"]
    #expect(build(crash, config).map(\.pgid) == [900, 401])  // avoided job goes last despite its size

    config = Config()
    config.prefer = ["OrbStack"]
    #expect(build(crash, config).first?.pgid == 900)

    config = Config()
    config.never = ["^gtimeout$"]
    #expect(build(crash, config).map(\.pgid) == [900])
}

@Test func defaultNeverListSparesTmuxAndSmallJobs() {
    let processes = [proc(10, ppid: 1, pgid: 10, "tmux", gb: 3), proc(20, ppid: 1, pgid: 20, "small", gb: 1)]
    #expect(build(processes).isEmpty)
}

@Test func ownGroupIsNeverACandidate() {
    let processes = [proc(10, ppid: 1, pgid: 10, "oomguard-dev", gb: 3)]
    #expect(Jobs.build(processes: processes, ownPgid: 10, minBytes: 0, rules: Rules(Config())) { _ in [] }.isEmpty)
}
