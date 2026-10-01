import Foundation

/// Opaque service-class information, with Q/R FIND helpers per PS3.4 C.5.1.1.
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

    private func flag(_ offset: Int) -> Bool {
        let bytes = Array(serviceClassApplicationInformation)
        return offset < bytes.count && bytes[offset] == 1
    }

    public var relationalQueries: Bool { flag(0) }
    public var dateTimeMatching: Bool { flag(1) }
    public var fuzzyPersonNameMatching: Bool { flag(2) }
    public var timezoneQueryAdjustment: Bool { flag(3) }
    public var enhancedMultiFrameConversion: Bool { flag(4) }

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
