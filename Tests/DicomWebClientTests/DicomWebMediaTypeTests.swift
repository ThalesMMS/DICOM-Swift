import DicomData
import XCTest
@testable import DicomWebClient

final class DicomWebMediaTypeTests: XCTestCase {
    func test_quotedParametersAndQualityExclusions() throws {
        let media = try DicomWebMediaType("multipart/related; boundary=\"a;b\"; type=\"application/dicom\"")
        XCTAssertEqual(media.parameters["boundary"], "a;b")
        let selected = try DicomWebMediaTypeNegotiator.select(accept: "image/*;q=1, image/jpeg;q=0", resource: .rendered,
            available: [.init("image/jpeg"), .init("image/png")])
        XCTAssertEqual(selected.mediaType, "image/png")
        XCTAssertThrowsError(try DicomWebMediaTypeNegotiator.select(accept: "application/dicom+json", resource: .thumbnail,
            available: [.init("image/jpeg")])) { XCTAssertEqual(($0 as? DicomWebError)?.statusCode, 406) }
    }

    func test_instanceNegotiation_requiresStoredOrReachableSyntax() throws {
        let stored = "1.2.840.10008.1.2.4.90"
        let explicit = "1.2.840.10008.1.2.1"
        let choices: [DicomWebMediaTypeNegotiator.Representation] = [
            .init("application/dicom", transferSyntaxUID: stored, multipart: true),
            .init("application/dicom", transferSyntaxUID: explicit, multipart: true)
        ]
        XCTAssertEqual(try DicomWebMediaTypeNegotiator.select(accept: "multipart/related;type=application/dicom;transfer-syntax=*",
            resource: .instance, available: choices, storedSyntaxUID: stored).transferSyntaxUID, stored)
        XCTAssertThrowsError(try DicomWebMediaTypeNegotiator.select(accept: "multipart/related;type=application/dicom",
            resource: .instance, available: choices, storedSyntaxUID: stored))
        XCTAssertEqual(try DicomWebMediaTypeNegotiator.select(accept: "multipart/related;type=application/dicom",
            resource: .instance, available: choices, storedSyntaxUID: stored, transcoding: Transcoder()).transferSyntaxUID, explicit)
    }

    func test_metadataFramesBulkAndRendered_haveResourceSpecificRepresentations() throws {
        for (kind, candidate) in [
            (DicomWebMediaTypeNegotiator.ResourceKind.metadata, DicomWebMediaTypeNegotiator.Representation("application/dicom+xml", multipart: true)),
            (.frames, .init("image/jp2", transferSyntaxUID: "1.2.840.10008.1.2.4.90", multipart: true)),
            (.bulkdata, .init("application/octet-stream")), (.rendered, .init("image/gif"))
        ] {
            XCTAssertEqual(try DicomWebMediaTypeNegotiator.select(accept: candidate.contentType, resource: kind, available: [candidate]), candidate)
        }
        XCTAssertThrowsError(try DicomWebMediaTypeNegotiator.select(accept: "image/png;transfer-syntax=*", resource: .rendered,
            available: [.init("image/png")]))
    }
}

private struct Transcoder: DicomWebTranscoding {
    func canTranscode(from storedSyntaxUID: String, to requestedSyntaxUID: String) -> Bool {
        requestedSyntaxUID == "1.2.840.10008.1.2.1"
    }
}
