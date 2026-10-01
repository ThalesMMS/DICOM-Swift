import Foundation

/// Opaque host accounting retained with decoded pixels. No renderer or pool types
/// cross this boundary. A copy must be admitted separately from the original bytes.
public protocol DicomFrameMemoryOwner: AnyObject, Sendable {
    var allocationIdentity: UUID { get }
    func reserveCopy(byteCount: Int) throws -> any DicomFrameMemoryOwner
    func didMaterialize(byteCount: Int) throws
}
