import Foundation

/// The sub-operation counts of one C-MOVE (issue #2817), updated from the sub-association's worker thread as each
/// object's outcome arrives; each object counts once.
final class DicomRetrieveTally: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = Set<Int>()
    private var remaining: UInt16
    private var completed: UInt16 = 0
    private var failed: UInt16 = 0
    private var warning: UInt16 = 0
    private var failedUIDs: [String] = []

    init(remaining: UInt16) {
        self.remaining = remaining
    }

    /// Records object `index`: status 0 completed, 0xBxxx warning, anything else (or nil) failed.
    func record(index: Int, status: UInt16?, sopInstanceUID: String)
        -> (remaining: UInt16, completed: UInt16, failed: UInt16, warning: UInt16) {
        lock.lock()
        defer { lock.unlock() }
        if reported.insert(index).inserted {
            remaining -= 1
            switch status {
            case 0: completed += 1
            case let status? where status & 0xF000 == 0xB000: warning += 1
            default:
                failed += 1
                failedUIDs.append(sopInstanceUID)
            }
        }
        return (remaining, completed, failed, warning)
    }

    /// Counts every object not yet reported as failed.
    func failUnreported(_ sopInstanceUIDs: [String]) {
        for (index, uid) in sopInstanceUIDs.enumerated() {
            _ = record(index: index, status: nil, sopInstanceUID: uid)
        }
    }

    var snapshot: (UInt16, UInt16, UInt16, UInt16, [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (remaining, completed, failed, warning, failedUIDs)
    }
}
