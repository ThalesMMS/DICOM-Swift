import Foundation

/// The status of a local file when a `DicomByteSource` opened it: device, inode, size, and modification and
/// status-change times. Every validating read of the source checks that the open descriptor and the path still have
/// it, so a caller can key work derived from those reads by it without reading the file's status again (issue #3111).
public struct DicomFileIdentity: Equatable, Hashable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64

    public init(device: UInt64, inode: UInt64, size: Int64, modifiedSeconds: Int64, modifiedNanoseconds: Int64,
                changedSeconds: Int64, changedNanoseconds: Int64) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modifiedSeconds = modifiedSeconds
        self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds
        self.changedNanoseconds = changedNanoseconds
    }
}
