import Darwin
import Foundation

/// The flight recorder: one line of every signal per sample, plus an event log. When memory
/// next gets tight this is the record of what led up to it, on this machine; a gap in the
/// samples means the guard itself was not running. Lines are flushed as written and synced to
/// disk every ten seconds and on every event, so a freeze loses at most a few samples.
public final class Recorder {
    public static var samplesPath: String { (Config.stateDirectory as NSString).appendingPathComponent("samples.tsv") }
    public static var eventsPath: String { (Config.stateDirectory as NSString).appendingPathComponent("events.log") }
    static let header = "time\tsegments\tpages\tswap_used_gb\theadroom_gb\teta_s\tswapins_per_s\tpressure\tlevel\tlag_s\ttop_gb\ttop_pgid\ttop_command\n"

    let maxBytes: Int
    let enabled: Bool
    var samples: UnsafeMutablePointer<FILE>?
    var events: UnsafeMutablePointer<FILE>?
    var lastSync = 0.0

    public init(enabled: Bool, maxMB: Double) {
        self.enabled = enabled
        self.maxBytes = Int(maxMB * 1_048_576 / 2)
        try? FileManager.default.createDirectory(atPath: Config.stateDirectory, withIntermediateDirectories: true)
        events = fopen(Recorder.eventsPath, "a")
    }

    public func record(_ sample: Sample, top: Job?, durable: Bool = false) {
        guard enabled else { return }
        if samples == nil || ftello(samples) > off_t(maxBytes) {
            if samples != nil {
                fclose(samples)
                rename(Recorder.samplesPath, Recorder.samplesPath + ".1")
            }
            samples = fopen(Recorder.samplesPath, "a")
            if let samples, ftello(samples) == 0 { fputs(Recorder.header, samples) }
        }
        guard let samples else { return }
        let s = sample.signals
        let eta = sample.eta.isFinite ? String(Int(sample.eta)) : ""
        let job = top.map { "\(String(format: "%.1f", Double($0.bytes) / 1_073_741_824))\t\($0.pgid)\t\($0.command.prefix(120))" } ?? "\t\t"
        fputs("\(stamp(s.time))\t\(String(format: "%.3f\t%.3f\t%.2f\t%.1f", s.segments, s.pages, Double(s.swapUsed) / 1_073_741_824, Double(s.headroom) / 1_073_741_824))"
            + "\t\(eta)\t\(Int(sample.swapinsPerSecond))\t\(s.pressure.rawValue)\t\(s.level)\t\(String(format: "%.1f", sample.lag))\t\(job)\n", samples)
        fflush(samples)
        if durable || s.time - lastSync >= 10 {
            fsync(fileno(samples))
            lastSync = s.time
        }
    }

    /// Writes an event to stdout (the service log) and durably to the event log.
    public func event(_ message: String) {
        let line = "\(stamp(Date().timeIntervalSince1970)) \(message)\n"
        fputs(line, stdout)
        guard let events else { return }
        fputs(line, events)
        fflush(events)
        fsync(fileno(events))
    }

    func stamp(_ time: Double) -> String {
        var seconds = time_t(time)
        var parts = tm()
        localtime_r(&seconds, &parts)
        var buffer = [CChar](repeating: 0, count: 32)
        strftime(&buffer, buffer.count, "%Y-%m-%dT%H:%M:%S", &parts)
        return String(cString: buffer)
    }
}
