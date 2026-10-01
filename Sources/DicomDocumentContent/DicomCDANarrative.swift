import Foundation

public struct DicomCDANarrative: Equatable, Sendable {
    public let title: String
    public let sections: [DicomCDASection]
    public let hasStructuredBody: Bool
}
