import AppKit
import Darwin
import WebKit

/// Memory measurement.
///
/// Preferred: the physical footprint (`proc_pid_rusage`), the number Activity Monitor shows in
/// its "Memory" column. Inside the App Sandbox that call is denied for other processes (such as
/// WebKit's page/GPU/network processes), so we fall back to the resident size from
/// `proc_pidinfo`, which the sandbox allows. Resident size also counts memory shared with other
/// processes, so it reads somewhat higher; the UI marks such totals as approximate (≈).
enum MemoryProbe {
    struct Sample {
        let bytes: UInt64
        let isExact: Bool
    }

    static func sample(of pid: pid_t) -> Sample? {
        var usage = rusage_info_v4()
        let rusageResult = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        if rusageResult == 0 {
            return Sample(bytes: usage.ri_phys_footprint, isExact: true)
        }
        var task = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
        if size == Int32(MemoryLayout<proc_taskinfo>.size) {
            return Sample(bytes: task.pti_resident_size, isExact: false)
        }
        return nil
    }

    /// PID of a WebKit helper process, read from a private WebKit property (SPI) via KVC.
    /// The selector is checked first, so if Apple removes it the indicator only loses that
    /// number; the app does not crash. Used for memory metrics only.
    @MainActor
    static func pid(of object: NSObject, _ key: String) -> pid_t? {
        guard object.responds(to: NSSelectorFromString(key)),
              let number = object.value(forKey: key) as? NSNumber else { return nil }
        let pid = number.int32Value
        return pid > 0 ? pid : nil
    }

    static func format(_ bytes: UInt64) -> String {
        bytes == 0 ? "0 MB" : ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}

struct MemoryReport {
    struct ProfileUsage {
        let name: String
        let color: NSColor
        let bytes: UInt64
        let panes: Int
        let hidden: Bool
    }

    var app: UInt64 = 0
    var gpu: UInt64 = 0
    var network: UInt64 = 0
    var profiles: [ProfileUsage] = []
    /// True when at least one number is a resident-size estimate instead of the footprint.
    var isApproximate = false

    var total: UInt64 { app + gpu + network + profiles.reduce(0) { $0 + $1.bytes } }

    /// Total formatted for display, prefixed with "≈" when approximate.
    var totalText: String { (isApproximate ? "≈ " : "") + MemoryProbe.format(total) }
}

/// Calls the handler when macOS reports memory pressure (warning or critical).
@MainActor
final class MemoryPressureWatcher {
    private var source: DispatchSourceMemoryPressure?

    func start(_ handler: @escaping @MainActor (DispatchSource.MemoryPressureEvent) -> Void) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated { handler(event) }
        }
        source.resume()
        self.source = source
    }
}
