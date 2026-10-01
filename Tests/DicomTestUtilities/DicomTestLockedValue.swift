import Foundation

/// Lock-protected mutable storage for test fixtures shared across concurrent tests.
public final class DicomTestLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    public init(_ value: Value) {
        storedValue = value
    }

    public var value: Value {
        lock.withLock { storedValue }
    }

    @discardableResult
    public func replace(with value: Value) -> Value {
        lock.withLock {
            let previousValue = storedValue
            storedValue = value
            return previousValue
        }
    }

    public func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock {
            try body(&storedValue)
        }
    }
}
