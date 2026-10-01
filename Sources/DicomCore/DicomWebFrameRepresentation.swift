import Foundation

struct DicomWebFrameRepresentation: Equatable, Sendable {
    let frameNumbers: [Int]
    let mediaType: String
    let transferSyntaxUID: String?
    let data: Data
}
