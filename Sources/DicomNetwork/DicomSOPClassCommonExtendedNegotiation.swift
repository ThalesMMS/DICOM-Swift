import Foundation

/// PS3.7 D.3.3.6: this item is carried only in A-ASSOCIATE-RQ.
public struct DicomSOPClassCommonExtendedNegotiation: Equatable, Sendable {
    public var sopClassUID: String
    public var serviceClassUID: String
    public var relatedGeneralSOPClassUIDs: [String]

    public init(sopClassUID: String, serviceClassUID: String, relatedGeneralSOPClassUIDs: [String] = []) {
        self.sopClassUID = sopClassUID
        self.serviceClassUID = serviceClassUID
        self.relatedGeneralSOPClassUIDs = relatedGeneralSOPClassUIDs
    }
}
