import Foundation

public struct DicomCDASection: Equatable, Sendable, Identifiable {
    public let id: Int
    public let title: String?
    public let text: String

    public init(id: Int, title: String?, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}
