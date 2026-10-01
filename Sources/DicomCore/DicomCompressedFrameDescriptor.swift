import Foundation

/// DICOM pixel metadata used to qualify a frame operation without patient identification.
public struct DicomCompressedFrameDescriptor: Equatable, Codable, Sendable {
    public let transferSyntaxUID: String
    public let rows: Int
    public let columns: Int
    public let bitsAllocated: Int
    public let bitsStored: Int
    public let highBit: Int
    public let pixelRepresentation: Int
    public let samplesPerPixel: Int
    public let photometricInterpretation: String
    public let planarConfiguration: Int?

    public init(
        transferSyntaxUID: String,
        rows: Int,
        columns: Int,
        bitsAllocated: Int,
        bitsStored: Int,
        highBit: Int,
        pixelRepresentation: Int,
        samplesPerPixel: Int,
        photometricInterpretation: String,
        planarConfiguration: Int?
    ) {
        self.transferSyntaxUID = transferSyntaxUID
        self.rows = rows
        self.columns = columns
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.pixelRepresentation = pixelRepresentation
        self.samplesPerPixel = samplesPerPixel
        self.photometricInterpretation = photometricInterpretation
        self.planarConfiguration = planarConfiguration
    }

    func validationReason(maximumDimension: Int = 65_535, maximumFrameBytes: Int = 512 * 1_024 * 1_024) -> String? {
        guard rows > 0, columns > 0, rows <= maximumDimension, columns <= maximumDimension,
              samplesPerPixel > 0, pixelRepresentation == 0 || pixelRepresentation == 1,
              bitsAllocated == 8 || bitsAllocated == 16,
              bitsStored > 0, bitsStored <= bitsAllocated,
              highBit >= bitsStored - 1, highBit < bitsAllocated else {
            return "The DICOM frame dimensions, precision, or sample representation are invalid."
        }
        let pixels = rows.multipliedReportingOverflow(by: columns)
        let samples = pixels.partialValue.multipliedReportingOverflow(by: samplesPerPixel)
        let bytes = samples.partialValue.multipliedReportingOverflow(by: bitsAllocated / 8)
        guard !pixels.overflow, !samples.overflow, !bytes.overflow, bytes.partialValue <= maximumFrameBytes else {
            return "The decoded frame exceeds the backend byte limit."
        }
        let photometric = photometricInterpretation.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if ["MONOCHROME1", "MONOCHROME2", "PALETTE COLOR"].contains(photometric), samplesPerPixel != 1 {
            return "The photometric interpretation requires one sample per pixel."
        }
        if photometric == "RGB" || photometric.hasPrefix("YBR") {
            guard samplesPerPixel == 3, planarConfiguration == nil || planarConfiguration == 0 || planarConfiguration == 1 else {
                return "Color frames require three samples and Planar Configuration 0 or 1 when present."
            }
        }
        return nil
    }
}
