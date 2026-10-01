import XCTest
@testable import DicomCore

final class DicomWebMediaTypeNegotiatorTests: XCTestCase {
    func test_renderedSelection_equalQualityExactRangeAfterWildcard_prefersExactRange() throws {
        let selection = try DicomWebMediaTypeNegotiator.renderedSelection(
            accept: "image/*;q=0.8, image/png;q=0.8",
            representationCount: 1
        )

        XCTAssertEqual(selection.mediaType, "image/png")
        XCTAssertFalse(selection.isMultipart)
    }

    func test_renderedSelection_specificJPEGExclusion_usesAllowedWildcardRepresentation() throws {
        let selection = try DicomWebMediaTypeNegotiator.renderedSelection(
            accept: "image/jpeg;q=0, */*;q=1",
            representationCount: 1
        )

        XCTAssertEqual(selection.mediaType, "image/png")
        XCTAssertFalse(selection.isMultipart)
    }

    func test_rawFrameSelection_specificMultipartExclusion_rejectsWildcardFallback() {
        XCTAssertThrowsError(
            try DicomWebMediaTypeNegotiator.rawFrameSelection(
                accept: "multipart/related;type=image/jp2;q=0, */*;q=1",
                transferSyntax: .jpeg2000Lossless,
                isCompressed: true
            )
        ) { error in
            XCTAssertEqual(error as? DicomWebFrameRouteError, .mediaTypeNotAcceptable)
        }
    }

    func test_rawFrameSelection_multipartWildcard_acceptsRawFrameRepresentation() throws {
        let selection = try DicomWebMediaTypeNegotiator.rawFrameSelection(
            accept: "multipart/*",
            transferSyntax: .jpeg2000Lossless,
            isCompressed: true
        )

        XCTAssertEqual(selection.mediaType, "image/jp2")
        XCTAssertEqual(selection.transferSyntaxUID, DicomTransferSyntax.jpeg2000Lossless.rawValue)
        XCTAssertTrue(selection.isMultipart)
    }
}
