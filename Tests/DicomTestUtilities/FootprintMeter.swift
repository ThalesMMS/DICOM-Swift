import Darwin
import Foundation

/// The peak physical footprint above the one at creation, sampled every millisecond.
public final class FootprintMeter: @unchecked Sendable {
    private let lock = NSLock()
    private let baseline = FootprintMeter.footprint()
    private var peak = 0
    private var running = true

    public init() {
        peak = baseline
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let current = Self.footprint()
                lock.withLock { peak = max(peak, current) }
                usleep(1_000)
            }
        }
    }

    public func stop() -> Int {
        lock.withLock {
            running = false
            return max(peak, Self.footprint()) - baseline
        }
    }

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

