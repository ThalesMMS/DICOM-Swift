import Foundation

/// An injected range-capable transport. The host owns origin authorization, credentials,
/// redirects and TLS. It must enforce `maximumResponseBytes` while receiving the body,
/// before allocating an oversized response. No app network route is enabled implicitly.
public struct DicomByteRangeTransport: Sendable {
    public struct Request: Sendable {
        public let range: Range<Int>
        public let ifMatch: String
        public let maximumResponseBytes: Int
    }

    public struct Response: Sendable {
        public let status: Int
        public let contentRange: String?
        public let entityTag: String?
        public let body: Data

        public init(status: Int, contentRange: String?, entityTag: String?, body: Data) {
            self.status = status
            self.contentRange = contentRange
            self.entityTag = entityTag
            self.body = body
        }
    }

    private let operation: @Sendable (Request) async throws -> Response

    public init(_ operation: @escaping @Sendable (Request) async throws -> Response) {
        self.operation = operation
    }

    package func read(_ request: Request) async throws -> Response { try await operation(request) }
}
