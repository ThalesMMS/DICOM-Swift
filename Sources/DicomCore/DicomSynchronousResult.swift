/// A one-shot result shared between an asynchronous callback and a synchronous caller.
/// All access to `storage` is serialized by `lock`.
final class DicomSynchronousResult<Value: Sendable>: @unchecked Sendable {
    private let lock = DicomLock()
    private var storage: Result<Value, Error>?

    @discardableResult
    func resolve(_ result: Result<Value, Error>) -> Bool {
        lock.withLock {
            guard storage == nil else { return false }
            storage = result
            return true
        }
    }

    func get() throws -> Value? {
        try lock.withLock {
            try storage?.get()
        }
    }
}
