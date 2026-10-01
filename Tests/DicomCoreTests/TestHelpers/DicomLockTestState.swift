@testable import DicomCore

/// Mutable test state whose synchronization is provided by the `DicomLock` under test.
final class DicomLockTestState<Value: Sendable>: @unchecked Sendable {
    private let lock = DicomLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock {
            try body(&storedValue)
        }
    }
}
