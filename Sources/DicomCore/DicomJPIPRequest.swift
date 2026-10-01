import Foundation

/// A bounded stateless JPIP request derived from a DICOM Pixel Data Provider URL.
public struct DicomJPIPRequest: Sendable, Equatable {
    /// Selects either one DICOM frame or the image entity already identified by the provider URL.
    public enum Resource: Sendable, Equatable {
        case frame(index: Int)
        case volume
    }

    /// Untrusted Pixel Data Provider URL carried by the DICOM dataset.
    public let pixelDataProviderURL: URL
    /// Requested image resource.
    public let resource: Resource
    /// Zero-based updates to request as cumulative `layers=index+1` JPIP queries.
    public let requestedLayerRange: Range<Int>?
    /// Referenced transfer syntax that constrains the accepted complete-image media type.
    public let transferSyntax: DicomTransferSyntax?

    public let streamMode: DicomJPIPStreamMode
    public let window: DicomJPIPWindow?
    public let session: DicomJPIPSession?
    public let cacheModel: DicomJPIPCacheModel?

    /// Creates a stateless cumulative JPIP request.
    public init(
        pixelDataProviderURL: URL,
        resource: Resource,
        requestedLayerRange: Range<Int>? = nil,
        transferSyntax: DicomTransferSyntax? = nil,
        streamMode: DicomJPIPStreamMode = .completeEntity,
        window: DicomJPIPWindow? = nil,
        session: DicomJPIPSession? = nil,
        cacheModel: DicomJPIPCacheModel? = nil
    ) {
        self.pixelDataProviderURL = pixelDataProviderURL
        self.resource = resource
        self.requestedLayerRange = requestedLayerRange
        self.transferSyntax = transferSyntax
        self.streamMode = window?.type ?? streamMode
        self.window = window
        self.session = session
        self.cacheModel = cacheModel
    }
}
