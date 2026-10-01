import Foundation

/// Resources and representations offered by the Annex H JSON capabilities document.
public struct DicomWebCapabilities: Codable, Equatable, Sendable {
    public struct Application: Codable, Equatable, Sendable {
        public let resources: Resources
    }
    public struct Resources: Codable, Equatable, Sendable {
        public let base: String
        public let resource: [Resource]
    }
    public struct Resource: Codable, Equatable, Sendable {
        public struct Method: Codable, Equatable, Sendable {
            public let name: String
        }
        public let path: String
        public let method: [Method]
    }
    public let application: Application
    public let mediaTypes: [String]
    public let fuzzyMatching: Bool?
    public let maximumSearchResults: Int?
    public let maximumRequestBodyBytes: Int?
    public let notificationConnection: String?
    public let notificationEncoding: String?

    public func offers(path: String, method: String = "GET") -> Bool {
        application.resources.resource.contains {
            $0.path == path && $0.method.contains { $0.name == method }
        }
    }
}
