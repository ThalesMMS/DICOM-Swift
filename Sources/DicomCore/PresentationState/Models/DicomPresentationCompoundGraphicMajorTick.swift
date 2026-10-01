import Foundation

public struct DicomPresentationCompoundGraphicMajorTick: Equatable, Sendable {
    public let position: Double
    public let label: String

    public init(position: Double, label: String) {
        self.position = position
        self.label = label
    }
}
