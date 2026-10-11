import Foundation

/// Opaque service-class information, with Q/R helpers for FIND (PS3.4 C.5.1.1, Table C.5-1) and for MOVE and
/// GET (C.5.2.1 and C.5.3.1, Tables C.5-3 and C.5-4).
public struct DicomSOPClassExtendedNegotiation: Equatable, Sendable {
    public var sopClassUID: String
    public var serviceClassApplicationInformation: Data

    public init(sopClassUID: String, serviceClassApplicationInformation: Data) {
        self.sopClassUID = sopClassUID
        self.serviceClassApplicationInformation = serviceClassApplicationInformation
    }

    public init(sopClassUID: String, relationalQueries: Bool, dateTimeMatching: Bool = false,
                fuzzyPersonNameMatching: Bool = false, timezoneQueryAdjustment: Bool = false,
                enhancedMultiFrameConversion: Bool = false) {
        self.init(sopClassUID: sopClassUID, serviceClassApplicationInformation: Data([
            relationalQueries, dateTimeMatching, fuzzyPersonNameMatching,
            timezoneQueryAdjustment, enhancedMultiFrameConversion
        ].map { $0 ? 1 : 0 }))
    }

    /// MOVE or GET layout: byte 1 relational-retrieval, byte 2 Enhanced Multi-Frame Image Conversion. A
    /// relational retrieve names a series or instance without the unique keys of the levels above it.
    public init(sopClassUID: String, relationalRetrieval: Bool, enhancedMultiFrameConversion: Bool = false) {
        self.init(sopClassUID: sopClassUID, serviceClassApplicationInformation: Data([
            relationalRetrieval, enhancedMultiFrameConversion
        ].map { $0 ? 1 : 0 }))
    }

    private func flag(_ offset: Int) -> Bool {
        let bytes = Array(serviceClassApplicationInformation)
        return offset < bytes.count && bytes[offset] == 1
    }

    public var relationalQueries: Bool { flag(0) }
    public var dateTimeMatching: Bool { flag(1) }
    public var fuzzyPersonNameMatching: Bool { flag(2) }
    public var timezoneQueryAdjustment: Bool { flag(3) }
    /// FIND layout (byte 5).
    public var enhancedMultiFrameConversion: Bool { flag(4) }
    /// MOVE or GET layout (byte 1). Bytes the acceptor did not return count as 0, and an omitted item means
    /// unsupported (C.5.2.1).
    public var relationalRetrieval: Bool { flag(0) }
    /// MOVE or GET layout (byte 2).
    public var retrievalEnhancedMultiFrameConversion: Bool { flag(1) }

    /// Only flags offered and implemented may be returned; retain the offered length.
    public func answering(with supported: Self) -> Self {
        let capabilities = Array(supported.serviceClassApplicationInformation)
        return Self(sopClassUID: sopClassUID, serviceClassApplicationInformation: Data(
            serviceClassApplicationInformation.enumerated().map { index, value in
                value == 1 && index < capabilities.count && capabilities[index] == 1 ? 1 : 0
            }
        ))
    }
}
