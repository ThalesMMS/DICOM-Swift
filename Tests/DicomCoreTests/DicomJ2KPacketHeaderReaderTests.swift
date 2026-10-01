import Foundation
import XCTest
@testable import DicomCore

final class DicomJ2KPacketHeaderReaderTests: XCTestCase {
    func test_emptyPacketAndEPH_areBounded() throws {
        var reader = try DicomJ2KPacketHeaderReader(bands: [.init(columns: 1, rows: 1)], eph: true)
        XCTAssertEqual(try reader.packetLength(in: Data([0, 255, 146]), range: 0..<3, layer: 0), 3)
        XCTAssertThrowsError(try reader.packetLength(in: Data([0]), range: 0..<1, layer: 1))
        XCTAssertThrowsError(try DicomJ2KPacketHeaderReader(bands: [.init(columns: Int.max, rows: 2)]))
    }
}
