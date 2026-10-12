import Foundation

/// The coding agent (Claude Code, Codex, ...) whose shell started a job.
public struct Agent: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let tty: String?
}

/// A process group: the kernel's notion of a job. Shells, Claude and Codex start every
/// command in its own group, so a worker pool is one job and the agent that launched it
/// is another. Killing a group is one `killpg`, which also reaches detached children.
public struct Job: Equatable, Sendable {
    public let pgid: Int32
    public let bytes: UInt64
    public let processes: Int
    public let leader: String
    public let command: String
    public var tier: Tier
    public var agent: Agent?

    /// Kill order, like oom_score_adj collapsed to three bands.
    public enum Tier: Int, Comparable, Sendable {
        case avoid = 0, normal = 1, prefer = 2
        public static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }
}

public struct Rules: Sendable {
    let prefer: [NSRegularExpression]
    let avoid: [NSRegularExpression]
    let never: [NSRegularExpression]

    public init(_ config: Config) {
        func compile(_ patterns: [String]) -> [NSRegularExpression] { patterns.compactMap { try? NSRegularExpression(pattern: $0) } }
        prefer = compile(config.prefer)
        avoid = compile(config.avoid)
        never = compile(config.never)
    }

    /// nil means never kill.
    public func tier(leader: String, command: String) -> Job.Tier? {
        func matches(_ list: [NSRegularExpression], _ text: String) -> Bool {
            list.contains { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
        }
        if matches(never, leader) || matches(never, command) { return nil }
        if matches(prefer, command) || matches(prefer, leader) { return .prefer }
        if matches(avoid, command) || matches(avoid, leader) { return .avoid }
        return .normal
    }
}

public enum Jobs {
    /// Groups `processes` into jobs at least `minBytes` big, largest kill-candidate first.
    /// `arguments` is only called for those, so a scan stays cheap.
    public static func build(
        processes: [ProcessInfoRecord], ownPgid: Int32, minBytes: UInt64, rules: Rules,
        arguments: (Int32) -> [String]
    ) -> [Job] {
        var members: [Int32: [ProcessInfoRecord]] = [:]
        for p in processes where p.pgid != ownPgid && p.pgid > 1 { members[p.pgid, default: []].append(p) }
        var jobs: [Job] = []
        for (pgid, group) in members {
            let bytes = group.reduce(UInt64(0)) { $0 + $1.footprint }
            guard bytes >= minBytes else { continue }
            let leader = group.first { $0.pid == pgid } ?? group.max { $0.footprint < $1.footprint }!
            let argv = arguments(leader.pid)
            let command = argv.isEmpty ? leader.name : argv.joined(separator: " ")
            guard let tier = rules.tier(leader: leader.name, command: command) else { continue }
            jobs.append(Job(pgid: pgid, bytes: bytes, processes: group.count, leader: leader.name,
                            command: command, tier: tier, agent: nil))
        }
        return jobs.sorted { ($0.tier, $0.bytes) > ($1.tier, $1.bytes) }
    }

    /// The nearest ancestor of the job's leader that is a coding agent.
    public static func agent(
        for job: Job, processes: [ProcessInfoRecord], names: [String], arguments: (Int32) -> [String]
    ) -> Agent? {
        guard !names.isEmpty else { return nil }
        let byPid = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var current = byPid[job.pgid]?.ppid ?? processes.first { $0.pgid == job.pgid }?.ppid
        var hops = 0
        while let pid = current, pid > 1, let record = byPid[pid], hops < 32 {
            let argv0 = arguments(pid).first.map { ($0 as NSString).lastPathComponent } ?? ""
            if let name = names.first(where: { $0 == record.name || $0 == argv0 }) {
                return Agent(pid: pid, name: name, tty: record.tty)
            }
            current = record.ppid
            hops += 1
        }
        return nil
    }
}
