import Foundation
import Synchronization

/// A non-identifying lifetime token; closure prevents late admission after source close.
final class DicomShadowSession: Sendable {
    let id = UUID()
    private let closed = Mutex(false)

    var isClosed: Bool { closed.withLock { $0 } }
    func close() { closed.withLock { $0 = true } }
}
