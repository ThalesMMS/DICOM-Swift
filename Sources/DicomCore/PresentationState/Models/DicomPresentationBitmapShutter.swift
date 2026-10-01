import Foundation

public struct DicomPresentationBitmapShutter: Equatable, Sendable {
    public let overlayGroup: UInt16
    public let rows: Int
    public let columns: Int
    public let originRow: Int
    public let originColumn: Int
    public let presentationValue: UInt16?
    /// One byte per overlay pixel, normalized to 0 or 1.
    public let mask: Data

    public init(
        overlayGroup: UInt16,
        rows: Int,
        columns: Int,
        originRow: Int,
        originColumn: Int,
        presentationValue: UInt16? = nil,
        mask: Data
    ) {
        self.overlayGroup = overlayGroup
        self.rows = max(0, rows)
        self.columns = max(0, columns)
        self.originRow = originRow
        self.originColumn = originColumn
        self.presentationValue = presentationValue
        self.mask = mask
    }
}
