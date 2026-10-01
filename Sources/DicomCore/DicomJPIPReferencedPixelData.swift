import Foundation

/// DICOM metadata that locates JPIP pixel data outside the Part 10 dataset.
public struct DicomJPIPReferencedPixelData: Sendable, Equatable {
    /// Referenced JPEG 2000 or HTJ2K transfer syntax.
    public let transferSyntax: DicomTransferSyntax
    /// Pixel Data Provider URL from (0028,7FE0).
    public let pixelDataProviderURL: URL
    /// Declared number of image frames represented by the provider URL.
    public let numberOfFrames: Int

    /// Creates a validated referenced-pixel descriptor.
    public init(
        transferSyntax: DicomTransferSyntax,
        pixelDataProviderURL: URL,
        numberOfFrames: Int = 1
    ) throws {
        guard transferSyntax.usesPixelDataProviderURL else {
            throw DICOMError.unsupportedTransferSyntax(syntax: transferSyntax.rawValue)
        }
        guard numberOfFrames > 0 else {
            throw DicomJPIPTransportError.invalidFrameCount(numberOfFrames)
        }
        self.transferSyntax = transferSyntax
        self.pixelDataProviderURL = pixelDataProviderURL
        self.numberOfFrames = numberOfFrames
    }

    /// Reads referenced-pixel metadata from a parsed DICOM dataset.
    public init(decoder: DCMDecoder) throws {
        guard let transferSyntaxUID = decoder.info(for: .transferSyntaxUID).jpipNilIfBlank,
              let transferSyntax = DicomTransferSyntax(uid: transferSyntaxUID) else {
            throw DICOMError.missingRequiredTag(tag: "0002,0010", description: "Transfer Syntax UID")
        }
        guard let urlString = decoder.info(for: .pixelDataProviderURL).jpipNilIfBlank,
              let url = URL(string: urlString) else {
            throw DICOMError.missingRequiredTag(tag: "0028,7FE0", description: "Pixel Data Provider URL")
        }
        try self.init(
            transferSyntax: transferSyntax,
            pixelDataProviderURL: url,
            numberOfFrames: max(1, decoder.nImages)
        )
    }

    /// Creates the compatibility request for a provider URL representing one complete image entity.
    public func makeVolumeRequest() -> DicomJPIPRequest {
        DicomJPIPRequest(
            pixelDataProviderURL: pixelDataProviderURL,
            resource: .volume,
            transferSyntax: transferSyntax
        )
    }

    /// Creates a zero-based frame request and validates it against Number of Frames.
    public func makeFrameRequest(index: Int) throws -> DicomJPIPRequest {
        guard index >= 0, index < numberOfFrames else {
            throw DicomJPIPTransportError.frameIndexOutOfRange(index: index, frameCount: numberOfFrames)
        }
        return DicomJPIPRequest(
            pixelDataProviderURL: pixelDataProviderURL,
            resource: .frame(index: index),
            transferSyntax: transferSyntax
        )
    }
}

private extension String {
    var jpipNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }
}
