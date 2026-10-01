import XCTest
@testable import DicomCore

final class DicomExportSupportMatrixTests: XCTestCase {
    func testPackageDefaultListsIssue1073SupportScope() throws {
        let matrix = DicomExportSupportMatrix.packageDefault

        XCTAssertEqual(matrix.rows.map(\.feature), [
            "Image export",
            "Secondary Capture",
            "Print management",
            "Waveform",
            "Video"
        ])

        let secondaryCapture = try XCTUnwrap(matrix.row(feature: "secondary capture"))
        XCTAssertTrue(secondaryCapture.requiredTags.contains("Patient Name"))
        XCTAssertTrue(secondaryCapture.requiredTags.contains("Study Instance UID"))
        XCTAssertTrue(secondaryCapture.payloadRules.contains("interleaved RGB"))
        XCTAssertTrue(secondaryCapture.typedFailure.contains("DicomSecondaryCaptureError"))

        let print = try XCTUnwrap(matrix.row(feature: "Print management"))
        XCTAssertTrue(print.supportedIODs.contains("Basic Grayscale and Color Print Management"))
        XCTAssertTrue(print.payloadRules.contains("interleaved RGB8"))
        XCTAssertTrue(print.unsupportedCases.contains("Presentation LUT"))
        XCTAssertFalse(print.unsupportedCases.contains("Color print"))

        let waveform = try XCTUnwrap(matrix.row(feature: "Waveform"))
        XCTAssertTrue(waveform.supportedIODs.contains("12-lead ECG"))
        XCTAssertTrue(waveform.payloadRules.contains("SB, UB, SS, US, SL, UL, MB, and AB"))

        let video = try XCTUnwrap(matrix.row(feature: "Video"))
        XCTAssertTrue(video.transferSyntaxes.contains("MPEG-2"))
        XCTAssertTrue(video.payloadRules.contains("native frame decode"))
        XCTAssertTrue(video.unsupportedCases.contains("DICOMweb rendered frames"))
        XCTAssertTrue(video.typedFailure.contains("DICOMWEB_RENDERED_FRAME_UNSUPPORTED"))
    }

    func testMarkdownTableExposesRequiredColumns() {
        let markdown = DicomExportSupportMatrix.packageDefault.markdown

        XCTAssertTrue(markdown.contains("| Feature | Supported IODs | Required Tags |"))
        XCTAssertTrue(markdown.contains("| Secondary Capture |"))
        XCTAssertTrue(markdown.contains("| Print management |"))
        XCTAssertTrue(markdown.contains("| Waveform |"))
        XCTAssertTrue(markdown.contains("| Video |"))
    }
}
