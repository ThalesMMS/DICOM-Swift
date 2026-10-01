import Foundation

public enum DicomUserIdentityType: UInt8, Codable, Equatable, Hashable, Sendable {
    case username = 1
    case usernameAndPasscode = 2
    case kerberos = 3
    case saml = 4
    case jwt = 5
}

public struct DicomUserIdentity: Codable, Equatable, Sendable {
    public var type: DicomUserIdentityType
    public var primaryField: Data
    public var secondaryField: Data
    public var positiveResponseRequested: Bool

    public init(type: DicomUserIdentityType,
                primaryField: Data,
                secondaryField: Data = Data(),
                positiveResponseRequested: Bool = false) {
        self.type = type
        self.primaryField = primaryField
        self.secondaryField = secondaryField
        self.positiveResponseRequested = positiveResponseRequested
    }

    public static func username(_ username: String,
                                positiveResponseRequested: Bool = false) -> DicomUserIdentity {
        DicomUserIdentity(type: .username,
                          primaryField: Data(username.utf8),
                          positiveResponseRequested: positiveResponseRequested)
    }

    public static func usernameAndPasscode(_ username: String,
                                           passcode: String,
                                           positiveResponseRequested: Bool = false) -> DicomUserIdentity {
        DicomUserIdentity(type: .usernameAndPasscode,
                          primaryField: Data(username.utf8),
                          secondaryField: Data(passcode.utf8),
                          positiveResponseRequested: positiveResponseRequested)
    }
}

/// Positive user identity response carried by item 59H in A-ASSOCIATE-AC.
public struct DicomUserIdentityServerResponse: Equatable, Sendable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}

/// An acceptor authenticates the unmodified identity bytes before accepting the association.
public protocol DicomUserIdentityAuthenticating: Sendable {
    func authenticate(_ identity: DicomUserIdentity) throws -> DicomUserIdentityServerResponse?
}
