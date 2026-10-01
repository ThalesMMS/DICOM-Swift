import Foundation

/// Lock-backed storage for the small process-wide seams used by CLI commands.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    @discardableResult
    func replace(with value: Value) -> Value {
        lock.withLock {
            let previous = storage
            storage = value
            return previous
        }
    }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock {
            try body(&storage)
        }
    }
}
