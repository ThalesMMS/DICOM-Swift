import Foundation

public struct DicomSRParseDiagnostic: Equatable, Sendable {
    public let path: [Int]
    public let code: String
    public let message: String

    public init(path: [Int], code: String, message: String) {
        self.path = path
        self.code = code
        self.message = message
    }
}
