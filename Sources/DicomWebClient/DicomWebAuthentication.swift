import Foundation

/// How a DICOMweb client authenticates (#2894). Every mode is validated before it becomes a header, and no error
/// message ever carries a secret.
public enum DicomWebAuthentication: Equatable, Sendable {
    case none
    case basic(username: String, password: String)
    /// A fixed key in a named header, such as `X-API-Key`.
    case apiKey(headerName: String, value: String)
    /// A fixed bearer token.
    case bearer(token: String)

    /// Headers a client must not carry as credentials: they frame, route or authenticate the transport itself.
    static let reservedHeaderNames: Set<String> = [
        "host", "content-length", "content-type", "content-encoding", "transfer-encoding", "connection", "keep-alive",
        "upgrade", "te", "trailer", "expect", "accept", "cookie", "set-cookie", "proxy-authorization",
        "proxy-authenticate", "proxy-connection"
    ]

    /// The header this mode sends, or nil for `.none`.
    public func header() throws -> (name: String, value: String)? {
        switch self {
        case .none:
            return nil
        case .basic(let username, let password):
            try Self.validate(username, field: .username)
            guard !username.contains(":") else { throw DicomWebAuthenticationError.usernameContainsColon }
            try Self.validate(password, field: .password)
            return ("Authorization", "Basic " + Data("\(username):\(password)".utf8).base64EncodedString())
        case .apiKey(let name, let value):
            guard !name.isEmpty, name.utf8.allSatisfy(Self.isTokenCharacter) else {
                throw DicomWebAuthenticationError.invalidHeaderName
            }
            guard !Self.reservedHeaderNames.contains(name.lowercased()) else {
                throw DicomWebAuthenticationError.reservedHeaderName(name)
            }
            try Self.validate(value, field: .apiKey)
            return (name, value)
        case .bearer(let token):
            try Self.validate(token, field: .token)
            return ("Authorization", "Bearer \(token)")
        }
    }

    /// RFC 9110 5.6.2 `tchar`.
    private static func isTokenCharacter(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
            || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }

    /// Not empty, no control character (which would split the request), no blank at either end.
    private static func validate(_ value: String, field: DicomWebAuthenticationError.Field) throws {
        guard !value.isEmpty else { throw DicomWebAuthenticationError.empty(field) }
        guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw DicomWebAuthenticationError.controlCharacter(field)
        }
        guard value.first?.isWhitespace != true, value.last?.isWhitespace != true else {
            throw DicomWebAuthenticationError.surroundingWhitespace(field)
        }
    }
}

/// An authentication setting that cannot become a header. Messages name the field, never its value.
public enum DicomWebAuthenticationError: Error, Equatable, LocalizedError, Sendable {
    public enum Field: String, Sendable { case username, password, apiKey = "API key", token }
    case empty(Field)
    case controlCharacter(Field)
    case surroundingWhitespace(Field)
    case usernameContainsColon
    case invalidHeaderName
    case reservedHeaderName(String)

    public var errorDescription: String? {
        switch self {
        case .empty(let field): return "The \(field.rawValue) is empty."
        case .controlCharacter(let field): return "The \(field.rawValue) contains a control character."
        case .surroundingWhitespace(let field): return "The \(field.rawValue) starts or ends with a blank."
        case .usernameContainsColon: return "A Basic authentication username cannot contain a colon."
        case .invalidHeaderName: return "The header name is not an HTTP token."
        case .reservedHeaderName(let name): return "The header \(name) is reserved by HTTP and cannot carry a credential."
        }
    }
}

extension DicomWebClientConfiguration {
    /// A configuration that sends `authentication` to the configured origin only.
    public init(baseURL: URL, authentication: DicomWebAuthentication, timeout: TimeInterval = 30) throws {
        self.init(baseURL: baseURL, timeout: timeout)
        if let header = try authentication.header() { headers[header.name] = header.value }
    }
}

/// What a DICOMweb failure asks the user to fix (#2894).
public enum DicomWebFailureKind: String, Equatable, Sendable {
    case configuration, credentials, network, tls, timeout, authentication, notFound, redirect, http, invalidResponse
    case cancelled
}

/// A classified DICOMweb failure.
public struct DicomWebConnectionFailure: Error, Equatable, Sendable {
    public let kind: DicomWebFailureKind
    /// The HTTP status, when the server answered.
    public let statusCode: Int?

    public init(kind: DicomWebFailureKind, statusCode: Int? = nil) {
        self.kind = kind
        self.statusCode = statusCode
    }

    public init(classifying error: Error) {
        switch error {
        case let failure as DicomWebConnectionFailure:
            self = failure
        case is CancellationError:
            self.init(kind: .cancelled)
        case is DicomWebAuthenticationError:
            self.init(kind: .credentials)
        case let error as URLError:
            self.init(kind: Self.kind(of: error.code))
        case let error as DicomWebError:
            switch error.kind {
            case .originDenied: self.init(kind: .redirect)
            case .invalidResponse: self.init(kind: .invalidResponse)
            default: self.init(kind: Self.kind(ofStatus: error.statusCode), statusCode: error.statusCode)
            }
        case let error as DicomWebClientError:
            switch error {
            case .invalidBaseURL, .invalidBulkDataURI, .unsupportedConnectAddress: self.init(kind: .configuration)
            case .httpStatus(let status, _, _, _): self.init(kind: Self.kind(ofStatus: status), statusCode: status)
            default: self.init(kind: .invalidResponse)
            }
        default:
            self.init(kind: .invalidResponse)
        }
    }

    private static func kind(ofStatus status: Int) -> DicomWebFailureKind {
        switch status {
        case 300..<400: return .redirect
        case 401, 403: return .authentication
        case 404: return .notFound
        default: return .http
        }
    }

    private static func kind(of code: URLError.Code) -> DicomWebFailureKind {
        switch code {
        case .cancelled: return .cancelled
        case .timedOut: return .timeout
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .tls
        case .badURL, .unsupportedURL: return .configuration
        case .httpTooManyRedirects, .redirectToNonExistentLocation: return .redirect
        case .userAuthenticationRequired, .userCancelledAuthentication: return .authentication
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData:
            return .invalidResponse
        default: return .network
        }
    }
}

extension DicomWebClient {
    /// Checks the endpoint and its credentials with a QIDO-RS `studies?limit=1` and returns quietly, or throws a
    /// classified `DicomWebConnectionFailure` (#2894).
    public func verifyConnection() async throws {
        do {
            let page = try await search(parameters: .init(level: .study, includeFields: [], limit: 1))
            guard page.statusCode == 200 || page.statusCode == 204 else {
                throw DicomWebConnectionFailure(kind: .http, statusCode: page.statusCode)
            }
        } catch {
            throw DicomWebConnectionFailure(classifying: error)
        }
    }
}
