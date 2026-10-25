import Darwin
import Foundation

/// The kernel's memory pressure level: what turns Activity Monitor's graph yellow or red,
/// and what jetsam itself acts on. macOS's equivalent of Linux PSI for our purposes.
public enum PressureLevel: Int, Comparable, Sendable, CustomStringConvertible {
    case normal = 1, warn = 2, critical = 4

    public static func < (a: PressureLevel, b: PressureLevel) -> Bool { a.rawValue < b.rawValue }
    public var description: String {
        switch self {
        case .normal: "normal"
        case .warn: "warn"
        case .critical: "critical"
        }
    }

    public static func current() -> PressureLevel {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return .normal }
        return PressureLevel(rawValue: Int(value)) ?? (value > 4 ? .critical : .normal)
    }
}

/// One process, read straight from the kernel (no `ps`).
public struct ProcessInfoRecord: Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let pgid: Int32
    public let uid: UInt32
    public let name: String
    /// Controlling terminal, e.g. "ttys012", if any.
    public let tty: String?
    /// phys_footprint: Activity Monitor's "Memory", including compressed and swapped pages.
    public let footprint: UInt64
}

public enum System {
    /// All processes owned by `uid`.
    public static func processes(uid: UInt32 = getuid()) -> [ProcessInfoRecord] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return [] }
        return pids.prefix(Int(filled)).compactMap { pid in
            guard pid > 0, let info = bsdInfo(pid), info.pbi_uid == uid else { return nil }
            return ProcessInfoRecord(
                pid: pid, ppid: Int32(info.pbi_ppid), pgid: Int32(info.pbi_pgid), uid: info.pbi_uid,
                name: name(info), tty: ttyName(info.e_tdev), footprint: footprint(pid))
        }
    }

    static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func name(_ info: proc_bsdinfo) -> String {
        var copy = info
        let long = withUnsafeBytes(of: &copy.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return long.isEmpty ? withUnsafeBytes(of: &copy.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } : long
    }

    static func ttyName(_ dev: UInt32) -> String? {
        guard dev != 0, dev != UInt32.max, let name = devname(dev_t(bitPattern: dev), S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty.hasPrefix("?") ? nil : tty
    }

    public static func footprint(_ pid: Int32) -> UInt64 {
        var info = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        return ok == 0 ? info.ri_phys_footprint : 0
    }

    /// argv of `pid`, via KERN_PROCARGS2. Empty if unreadable.
    public static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // executable path
        while index < size, buffer[index] == 0 { index += 1 }  // padding
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}

/// One raw reading of what the kernel runs out of. See docs/RESEARCH.md for why these and
/// not the pressure level: the compressor limits count data in RAM and in swap, and the
/// kernel declares memory exhausted at 98% of either.
public struct Signals: Equatable, Sendable {
    public var time: Double
    /// Compressor segments in use / limit.
    public var segments: Double
    /// Compressed pages / limit.
    public var pages: Double
    public var swapUsed: UInt64
    /// Room left for swap: free disk on the VM volume plus unused swapfile space, capped by
    /// macOS's limit of 100 swapfiles of 1GB.
    public var headroom: UInt64
    public var ram: UInt64
    /// Cumulative swap-ins; its rate is the closest thing macOS has to a thrashing gauge.
    public var swapins: UInt64
    public var pressure: PressureLevel
    /// kern.memorystatus_level, recorded for comparison only.
    public var level: Int

    public var occupancy: Double { max(segments, pages) }

    public init(time: Double, segments: Double, pages: Double, swapUsed: UInt64, headroom: UInt64, ram: UInt64,
                swapins: UInt64 = 0, pressure: PressureLevel = .normal, level: Int = 0) {
        self.time = time; self.segments = segments; self.pages = pages; self.swapUsed = swapUsed
        self.headroom = headroom; self.ram = ram; self.swapins = swapins; self.pressure = pressure; self.level = level
    }
}

extension System {
    static let swapFileCap: UInt64 = 100 << 30

    /// Reads a 4- or 8-byte integer sysctl without allocating.
    static func sysctlNumber(_ name: String) -> UInt64 {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return 0 }
        return size == 4 ? value & 0xFFFF_FFFF : value
    }

    public static func signals() -> Signals {
        func fraction(_ used: String, _ limit: String) -> Double {
            let cap = sysctlNumber(limit)
            return cap == 0 ? 0 : Double(sysctlNumber(used)) / Double(cap)
        }
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        var fs = statfs()
        let diskFree = statfs("/System/Volumes/VM", &fs) == 0 ? UInt64(fs.f_bavail) * UInt64(fs.f_bsize) : 0
        let fileRoom = swapFileCap > swap.xsu_used ? swapFileCap - swap.xsu_used : 0
        return Signals(
            time: Date().timeIntervalSince1970,
            segments: fraction("vm.compressor.segment.total", "vm.compressor.segment.limit"),
            pages: fraction("vm.compressor.pages_compressed", "vm.compressor.pages_compressed_limit"),
            swapUsed: swap.xsu_used, headroom: min(diskFree + swap.xsu_avail, fileRoom),
            ram: sysctlNumber("hw.memsize"), swapins: sysctlNumber("vm.compressor.swapper.swapins_total"),
            pressure: PressureLevel.current(), level: Int(sysctlNumber("kern.memorystatus_level")))
    }
}

// Private but exported by libsystem since macOS 10.11; the kernel applies it without a
// privilege check (bsd/kern/kern_exec.c). Used by launchd to place jobs in jetsam bands.
// Looked up at run time so that a macOS without it degrades instead of failing to launch.
private typealias SetJetsam = @convention(c) (
    UnsafeMutablePointer<posix_spawnattr_t?>, Int16, Int32, Int32, Int32) -> Int32
private let setJetsam: SetJetsam? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "posix_spawnattr_setjetsam_ext")
    .map { unsafeBitCast($0, to: SetJetsam.self) }

// memorystatus_control(MEMORYSTATUS_CMD_GET_PRIORITY_LIST): root only, even for oneself.
private typealias MemorystatusControl = @convention(c) (UInt32, Int32, UInt32, UnsafeMutableRawPointer?, Int) -> Int32
private let memorystatusControl: MemorystatusControl? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "memorystatus_control")
    .map { unsafeBitCast($0, to: MemorystatusControl.self) }

public enum Spawn {
    static let useEffectivePriority: Int16 = 0x1
    static let memlimitActiveFatal: Int16 = 0x4
    static let memlimitInactiveFatal: Int16 = 0x8
    public static let defaultBand: Int32 = 180  // JETSAM_PRIORITY_DEFAULT

    /// Whether this macOS still exports the private call that bands and memory caps rely on.
    public static var available: Bool { setJetsam != nil }

    /// Replaces this process with `arguments` (argv[0] is looked up on PATH), placed in jetsam
    /// `band` and, if `limitMB` is given, under a kernel-enforced fatal memory limit: the kernel
    /// kills the process the moment its footprint passes the limit, with no help from userspace.
    /// The limit is per process and is not inherited by children. Returns only on failure.
    public static func exec(_ arguments: [String], band: Int32 = defaultBand, limitMB: Int32? = nil,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        guard let setJetsam else { return ENOTSUP }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETEXEC))
        var flags = useEffectivePriority
        if limitMB != nil { flags |= memlimitActiveFatal | memlimitInactiveFatal }
        let rc = setJetsam(&attr, flags, band, limitMB ?? -1, limitMB ?? -1)
        guard rc == 0 else { return rc }
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        var pid: pid_t = 0
        return posix_spawnp(&pid, arguments[0], nil, &attr, &argv, &envp)
    }

    /// The jetsam band a process is in, or nil when it can't be read (that needs root).
    public static func band(of pid: pid_t) -> Int32? {
        // memorystatus_priority_entry_t: pid, priority, user_data, limit, state
        struct Entry { var pid: Int32 = 0; var priority: Int32 = 0; var userData: UInt64 = 0; var limit: Int32 = 0; var state: UInt32 = 0 }
        var entry = Entry()
        guard let memorystatusControl,
              memorystatusControl(1, pid, 0, &entry, MemoryLayout<Entry>.size) > 0, entry.pid == pid else { return nil }
        return entry.priority
    }
}
