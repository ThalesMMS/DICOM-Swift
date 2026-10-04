import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

/// Ordered retrieve Accepts, the new attempt after a refused one, unquoted transfer syntaxes and the media type table.
final class DicomWebAcceptListTests: XCTestCase {
    private static let jpeg2000 = "1.2.840.10008.1.2.4.90"
    private static let explicitVRLittleEndian = "1.2.840.10008.1.2.1"
    private static let dicom = "multipart/related; type=\"application/dicom\""

    func test_instanceAcceptList_sendsEverySyntaxWithDecreasingQ() throws {
        let accept = try DicomWebMediaTypeNegotiator.instanceAccept(
            transferSyntaxUIDs: [Self.jpeg2000, Self.explicitVRLittleEndian, "*"])
        XCTAssertEqual(accept.headerValue,
                       "\(Self.dicom); transfer-syntax=1.2.840.10008.1.2.4.90, "
                       + "\(Self.dicom); transfer-syntax=1.2.840.10008.1.2.1; q=0.9, "
                       + "\(Self.dicom); transfer-syntax=*; q=0.8")
        XCTAssertEqual(accept.headerValue(droppingFirst: 1),
                       "\(Self.dicom); transfer-syntax=1.2.840.10008.1.2.1, \(Self.dicom); transfer-syntax=*; q=0.9")
        XCTAssertEqual(accept.headerValue(droppingFirst: 2), "\(Self.dicom); transfer-syntax=*")
        XCTAssertEqual(accept.fallbackStatuses, [406])
    }

    func test_acceptList_replacesGivenQAndKeepsQDecreasingUpToTheLimit() throws {
        let ranges = try ["image/jpeg; q=0.1", "image/png"].map(DicomWebMediaType.init)
        XCTAssertEqual(try DicomWebAcceptList(ranges).headerValue, "image/jpeg, image/png; q=0.9")
        for count in [11, 37, DicomWebAcceptList.maximumRangeCount] {
            let list = try DicomWebAcceptList(Array(repeating: try DicomWebMediaType("image/jpeg"), count: count))
            let weights = try list.headerValue.components(separatedBy: ", ").map {
                try DicomWebMediaType($0).parameters["q"].flatMap(Double.init) ?? 1
            }
            XCTAssertEqual(weights.count, count)
            XCTAssertEqual(weights.first, 1)
            XCTAssertTrue(zip(weights, weights.dropFirst()).allSatisfy { $0 > $1 }, "\(count) ranges")
            XCTAssertGreaterThan(weights.last ?? 0, 0)
        }
        for invalid in [[], Array(repeating: try DicomWebMediaType("image/jpeg"), count: 1001)] {
            XCTAssertThrowsError(try DicomWebAcceptList(invalid)) { XCTAssertEqual(($0 as? DicomWebError)?.kind, .badRequest) }
        }
    }

    func test_implicitVRLittleEndian_isRefusedClearlyInAList() throws {
        XCTAssertThrowsError(try DicomWebMediaTypeNegotiator.instanceAccept(
            transferSyntaxUIDs: [Self.explicitVRLittleEndian, " 1.2.840.10008.1.2 "])) { error in
            XCTAssertEqual(error as? DicomWebImplicitVRAcceptError, DicomWebImplicitVRAcceptError())
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("Implicit VR Little Endian") == true)
        }
        XCTAssertThrowsError(try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUIDs: ["1..2"])) {
            XCTAssertEqual(($0 as? DicomWebError)?.kind, .badRequest)
        }
        XCTAssertThrowsError(try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUIDs: []))
    }

    func test_singleAccept_leavesTheTransferSyntaxUnquotedAndKeepsTypeQuoted() throws {
        XCTAssertEqual(try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUID: Self.jpeg2000).headerValue,
                       "\(Self.dicom); transfer-syntax=1.2.840.10008.1.2.4.90")
        XCTAssertEqual(try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUID: nil).headerValue,
                       "\(Self.dicom); transfer-syntax=*")
        let media = try DicomWebMediaType("multipart/related; q=0.5; boundary=\"a;b\"; type=application/dicom")
        XCTAssertEqual(media.headerValue, "multipart/related; type=\"application/dicom\"; boundary=\"a;b\"; q=0.5")
        XCTAssertEqual(try DicomWebMediaType(media.headerValue), media)
    }

    /// The negotiator the package's server answers with reads a transfer syntax quoted or not, and the list's `q`.
    func test_negotiator_readsQuotedAndUnquotedSyntaxesAndTheListOrder() throws {
        let stored = "1.2.840.10008.1.2.5"
        let choices: [DicomWebMediaTypeNegotiator.Representation] = [
            .init("application/dicom", transferSyntaxUID: stored, multipart: true),
            .init("application/dicom", transferSyntaxUID: Self.explicitVRLittleEndian, multipart: true)
        ]
        for accept in ["\(Self.dicom); transfer-syntax=\(stored)", "\(Self.dicom); transfer-syntax=\"\(stored)\"",
                       "multipart/related; type=application/dicom; transfer-syntax=\(stored)"] {
            XCTAssertEqual(try DicomWebMediaTypeNegotiator.select(accept: accept, resource: .instance, available: choices,
                                                                  storedSyntaxUID: stored).transferSyntaxUID, stored, accept)
        }
        let list = try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUIDs: [Self.explicitVRLittleEndian, stored])
        XCTAssertEqual(try DicomWebMediaTypeNegotiator.select(accept: list.headerValue, resource: .instance, available: choices,
            storedSyntaxUID: stored, transcoding: ExplicitTranscoder()).transferSyntaxUID, Self.explicitVRLittleEndian)
        XCTAssertEqual(try DicomWebMediaTypeNegotiator.select(accept: list.headerValue, resource: .instance, available: choices,
            storedSyntaxUID: stored).transferSyntaxUID, stored, "the second range when the first cannot be served")
    }

    func test_mediaTypeTable_readsBothWaysWithAlternativeSpellings() {
        let expected: [(String, [String])] = [
            ("application/octet-stream", ["1.2.840.10008.1.2.1"]),
            ("image/jpeg", ["1.2.840.10008.1.2.4.70", "1.2.840.10008.1.2.4.50", "1.2.840.10008.1.2.4.51",
                            "1.2.840.10008.1.2.4.57"]),
            ("image/jls", ["1.2.840.10008.1.2.4.80", "1.2.840.10008.1.2.4.81"]),
            ("image/jp2", ["1.2.840.10008.1.2.4.90", "1.2.840.10008.1.2.4.91"]),
            ("image/jpx", ["1.2.840.10008.1.2.4.92", "1.2.840.10008.1.2.4.93"]),
            ("image/jphc", ["1.2.840.10008.1.2.4.201", "1.2.840.10008.1.2.4.202", "1.2.840.10008.1.2.4.203"]),
            ("image/jxl", ["1.2.840.10008.1.2.4.110", "1.2.840.10008.1.2.4.111", "1.2.840.10008.1.2.4.112"]),
            ("image/dicom-rle", ["1.2.840.10008.1.2.5"]),
            ("application/x-deflate", ["1.2.840.10008.1.2.8.1"]),
            ("video/mpeg", ["1.2.840.10008.1.2.4.100", "1.2.840.10008.1.2.4.100.1", "1.2.840.10008.1.2.4.101",
                            "1.2.840.10008.1.2.4.101.1"]),
            ("video/mp4", ["1.2.840.10008.1.2.4.102", "1.2.840.10008.1.2.4.102.1", "1.2.840.10008.1.2.4.103",
                           "1.2.840.10008.1.2.4.103.1", "1.2.840.10008.1.2.4.104", "1.2.840.10008.1.2.4.104.1",
                           "1.2.840.10008.1.2.4.105", "1.2.840.10008.1.2.4.105.1", "1.2.840.10008.1.2.4.106",
                           "1.2.840.10008.1.2.4.106.1", "1.2.840.10008.1.2.4.107", "1.2.840.10008.1.2.4.108"])
        ]
        for (mediaType, uids) in expected {
            XCTAssertEqual(DicomWebTransferSyntaxMediaTypes.transferSyntaxUIDs(forMediaType: mediaType), uids, mediaType)
            for uid in uids {
                XCTAssertEqual(DicomWebTransferSyntaxMediaTypes.mediaType(forTransferSyntaxUID: uid), mediaType, uid)
            }
        }
        for (alternative, canonical) in [("image/x-jls", "image/jls"), ("image/jhc", "image/jphc"),
                                         ("image/x-dicom-rle", "image/dicom-rle"), ("video/mpeg2", "video/mpeg"),
                                         ("IMAGE/JLS", "image/jls"),
                                         ("image/x-dicom-rle; transfer-syntax=1.2.840.10008.1.2.5", "image/dicom-rle")] {
            XCTAssertEqual(DicomWebTransferSyntaxMediaTypes.canonicalMediaType(alternative), canonical, alternative)
            XCTAssertEqual(DicomWebTransferSyntaxMediaTypes.transferSyntaxUIDs(forMediaType: alternative),
                           DicomWebTransferSyntaxMediaTypes.transferSyntaxUIDs(forMediaType: canonical), alternative)
        }
        for uid in ["1.2.840.10008.1.2", "1.2.840.10008.1.2.2", "1.2.840.10008.1.2.1.99", "2.25.1"] {
            XCTAssertNil(DicomWebTransferSyntaxMediaTypes.mediaType(forTransferSyntaxUID: uid), uid)
        }
        XCTAssertEqual(DicomWebTransferSyntaxMediaTypes.transferSyntaxUIDs(forMediaType: "image/png"), [])
        XCTAssertNil(DicomWebTransferSyntaxMediaTypes.canonicalMediaType("image/png"))
    }
}

private struct ExplicitTranscoder: DicomWebTranscoding {
    func canTranscode(from storedSyntaxUID: String, to requestedSyntaxUID: String) -> Bool {
        requestedSyntaxUID == "1.2.840.10008.1.2.1"
    }
}
