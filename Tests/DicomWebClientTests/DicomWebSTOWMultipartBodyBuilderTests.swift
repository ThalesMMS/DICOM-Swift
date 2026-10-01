import DicomTestUtilities
import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

final class DicomWebSTOWMultipartBodyBuilderTests: XCTestCase {
    func test_build_multipleInstancesPreservesExactWireBytes() throws {
        let instances = [
            DicomWebStoreInstance(
                data: Data([0x00, 0x44, 0x49, 0x43, 0x4D, 0xFF]),
                transferSyntax: "1.2.840.10008.1.2.1"
            ),
            DicomWebStoreInstance(
                data: Data(),
                transferSyntax: nil
            )
        ]

        let body = try DicomWebSTOWMultipartBodyBuilder.build(
            instances: instances,
            boundary: "EXACT",
            maximumBytes: .max
        )

        var expected = Data(
            (
                "--EXACT\r\nContent-Type: application/dicom; transfer-syntax=1.2.840.10008.1.2.1\r\n" +
                    "Content-Length: 6\r\n\r\n"
            ).utf8
        )
        expected.append(instances[0].data)
        expected.append(Data(
            "\r\n--EXACT\r\nContent-Type: application/dicom\r\nContent-Length: 0\r\n\r\n".utf8
        ))
        expected.append(instances[1].data)
        expected.append(Data("\r\n--EXACT--\r\n".utf8))
        XCTAssertEqual(body, expected)
        XCTAssertEqual(
            try DicomWebSTOWMultipartBodyBuilder.serializedByteCount(
                instances: instances,
                boundary: "EXACT",
                maximumBytes: .max
            ),
            body.count
        )
    }

    func test_build_emptyInputEmitsOnlyClosingBoundary() throws {
        let body = try DicomWebSTOWMultipartBodyBuilder.build(
            instances: [],
            boundary: "EMPTY",
            maximumBytes: .max
        )

        XCTAssertEqual(body, Data("--EMPTY--\r\n".utf8))
    }

    func test_build_atLimitSucceedsAndLimitPlusOneFails() throws {
        let boundary = "B"
        let atLimit = [DicomWebStoreInstance(data: Data([0x01]), transferSyntax: nil)]
        let overLimit = [DicomWebStoreInstance(data: Data([0x01, 0x02]), transferSyntax: nil)]
        let limit = 69

        let body = try DicomWebSTOWMultipartBodyBuilder.build(
            instances: atLimit,
            boundary: boundary,
            maximumBytes: limit
        )

        XCTAssertEqual(body.count, limit)
        XCTAssertThrowsError(
            try DicomWebSTOWMultipartBodyBuilder.build(
                instances: overLimit,
                boundary: boundary,
                maximumBytes: limit
            )
        ) { error in
            XCTAssertEqual(
                error as? DicomWebClientError,
                .storeRequestBodyTooLarge(byteCount: limit + 1, limit: limit)
            )
        }
    }

    func test_build_closingBoundaryCountsAgainstBudget() throws {
        let body = try DicomWebSTOWMultipartBodyBuilder.build(
            instances: [],
            boundary: "B",
            maximumBytes: 7
        )

        XCTAssertEqual(body, Data("--B--\r\n".utf8))
        XCTAssertThrowsError(
            try DicomWebSTOWMultipartBodyBuilder.build(
                instances: [],
                boundary: "B",
                maximumBytes: 6
            )
        ) { error in
            XCTAssertEqual(error as? DicomWebClientError, .storeRequestBodyTooLarge(byteCount: 7, limit: 6))
        }
    }

    func test_build_emptyPayloadMIMEOverheadCountsAgainstBudget() throws {
        let instance = DicomWebStoreInstance(data: Data(), transferSyntax: nil)
        let body = try DicomWebSTOWMultipartBodyBuilder.build(
            instances: [instance],
            boundary: "B",
            maximumBytes: 68
        )

        XCTAssertEqual(body.count, 68)
        XCTAssertThrowsError(
            try DicomWebSTOWMultipartBodyBuilder.build(
                instances: [instance],
                boundary: "B",
                maximumBytes: 67
            )
        ) { error in
            XCTAssertEqual(error as? DicomWebClientError, .storeRequestBodyTooLarge(byteCount: 68, limit: 67))
        }
    }

    func test_build_manySmallPartsEnforcesExactAggregateBudget() throws {
        let instances = (0..<128).map { _ in
            DicomWebStoreInstance(data: Data([0x01]), transferSyntax: nil)
        }

        try assertExactBudget(instances: instances, boundary: "MANY")
    }

    func test_build_oneLargePartEnforcesExactAggregateBudget() throws {
        let instance = DicomWebStoreInstance(
            data: Data(repeating: 0xA5, count: 1_024 * 1_024),
            transferSyntax: nil
        )

        try assertExactBudget(instances: [instance], boundary: "LARGE")
    }

    func test_build_contentTypeHeaderSeparatorsThrowTypedError() {
        for separator in ["\r", "\n", "\r\n"] {
            let instance = DicomWebStoreInstance(
                data: Data([0x01]),
                contentType: "application/dicom\(separator)X-Injected: true"
            )

            XCTAssertThrowsError(
                try DicomWebSTOWMultipartBodyBuilder.build(
                    instances: [instance],
                    boundary: "REJECT",
                    maximumBytes: .max
                )
            ) { error in
                XCTAssertEqual(error as? DicomWebClientError, .invalidStoreContentType(instanceIndex: 0))
            }
        }
    }

    func test_build_transferSyntaxHeaderSeparatorsThrowTypedError() {
        for separator in ["\r", "\n", "\r\n"] {
            let instance = DicomWebStoreInstance(
                data: Data([0x01]),
                transferSyntax: "1.2.840.10008.1.2.1\(separator)X-Injected: true"
            )

            XCTAssertThrowsError(
                try DicomWebSTOWMultipartBodyBuilder.build(
                    instances: [instance],
                    boundary: "REJECT",
                    maximumBytes: .max
                )
            ) { error in
                XCTAssertEqual(error as? DicomWebClientError, .invalidStoreTransferSyntaxUID(instanceIndex: 0))
            }
        }
    }

    func test_build_invalidMediaTypesThrowTypedErrorAtTheirInstanceIndex() {
        let invalidValues = ["", "text/plain", "application/dicom; charset=utf-8", "application/dicóm"]

        for value in invalidValues {
            let instances = [
                DicomWebStoreInstance(data: Data([0x01])),
                DicomWebStoreInstance(data: Data([0x02]), contentType: value)
            ]

            XCTAssertThrowsError(
                try DicomWebSTOWMultipartBodyBuilder.serializedByteCount(
                    instances: instances,
                    boundary: "REJECT",
                    maximumBytes: .max
                )
            ) { error in
                XCTAssertEqual(error as? DicomWebClientError, .invalidStoreContentType(instanceIndex: 1))
            }
        }
    }

    func test_build_invalidTransferSyntaxUIDsThrowTypedError() {
        let invalidValues = [
            "", ".1.2", "1.2.", "1..2", "1.02.3", "1.2 3", "1.2.é", String(repeating: "1", count: 65)
        ]

        for value in invalidValues {
            let instance = DicomWebStoreInstance(data: Data([0x01]), transferSyntax: value)

            XCTAssertThrowsError(
                try DicomWebSTOWMultipartBodyBuilder.build(
                    instances: [instance],
                    boundary: "REJECT",
                    maximumBytes: .max
                )
            ) { error in
                XCTAssertEqual(error as? DicomWebClientError, .invalidStoreTransferSyntaxUID(instanceIndex: 0))
            }
        }
    }

    func test_build_validHeaderValuesPreserveExactWireBytes() throws {
        let instances = [
            DicomWebStoreInstance(
                data: Data([0x01]),
                contentType: "Application/Dicom",
                transferSyntax: "2.25.123456789"
            ),
            DicomWebStoreInstance(data: Data([0x02]), transferSyntax: nil)
        ]

        let body = try DicomWebSTOWMultipartBodyBuilder.build(
            instances: instances,
            boundary: "VALID",
            maximumBytes: .max
        )

        var expected = Data(
            (
                "--VALID\r\nContent-Type: Application/Dicom; transfer-syntax=2.25.123456789\r\n" +
                    "Content-Length: 1\r\n\r\n"
            ).utf8
        )
        expected.append(Data([0x01]))
        expected.append(Data(
            "\r\n--VALID\r\nContent-Type: application/dicom\r\nContent-Length: 1\r\n\r\n".utf8
        ))
        expected.append(Data([0x02]))
        expected.append(Data("\r\n--VALID--\r\n".utf8))
        XCTAssertEqual(body, expected)
    }

    func test_parser_acceptsLegacyPartWithoutLengthOrLocation() throws {
        let body = Data(
            "--LEGACY\r\nContent-Type: application/dicom\r\n\r\nDICM\r\n--LEGACY--\r\n".utf8
        )

        let part = try XCTUnwrap(DicomWebMultipartParser.parts(from: body, boundary: "LEGACY").first)

        XCTAssertEqual(part.contentType, "application/dicom")
        XCTAssertEqual(part.body, Data("DICM".utf8))
        XCTAssertNil(part.headers["Content-Length"])
        XCTAssertNil(part.headers["Content-Location"])
    }

    func test_parser_usesDeclaredLengthWhenPayloadContainsBoundaryBytes() throws {
        let payload = Data("prefix\r\n--COLLISION\r\ninside-payload".utf8)
        let body = try DicomWebSTOWMultipartBodyBuilder.build(
            instances: [DicomWebStoreInstance(data: payload, transferSyntax: nil)],
            boundary: "COLLISION",
            maximumBytes: .max
        )

        let part = try XCTUnwrap(DicomWebMultipartParser.parts(from: body, boundary: "COLLISION").first)

        XCTAssertEqual(part.body, payload)
        XCTAssertEqual(part.headers["Content-Length"], String(payload.count))
    }

    func test_parser_rejectsDeclaredLengthThatDoesNotMatchFraming() {
        let body = Data(
            (
                "--MISMATCH\r\nContent-Type: application/dicom\r\nContent-Length: 3\r\n\r\nDICM\r\n" +
                    "--MISMATCH--\r\n"
            ).utf8
        )

        XCTAssertThrowsError(try DicomWebMultipartParser.parts(from: body, boundary: "MISMATCH")) { error in
            XCTAssertEqual(error as? DicomWebClientError, .malformedMultipartBody)
        }
    }

    func test_build_part10FixturesDeriveMatchingTransferSyntaxAndPreservePayloadBytes() throws {
        let fixtures = [
            (
                "DecoderParity/ct_explicit_vr_le_rescale.dcm",
                DicomTransferSyntax.explicitVRLittleEndian.rawValue
            ),
            (
                "DecoderParity/jpeg_lossless_sv1_parity.dcm",
                DicomTransferSyntax.jpegLosslessFirstOrder.rawValue
            )
        ]

        for (relativePath, expectedTransferSyntax) in fixtures {
            let payload = try fixtureData(relativePath)
            let instances = [DicomWebStoreInstance(data: payload, transferSyntax: nil)]
            let body = try DicomWebSTOWMultipartBodyBuilder.build(
                instances: instances,
                boundary: "PART10",
                maximumBytes: .max
            )
            let parts = try DicomWebMultipartParser.parts(from: body, boundary: "PART10")

            XCTAssertEqual(parts.count, 1, relativePath)
            XCTAssertEqual(
                parts.first?.contentType,
                "application/dicom; transfer-syntax=\(expectedTransferSyntax)",
                relativePath
            )
            XCTAssertEqual(parts.first?.body, payload, relativePath)
            XCTAssertEqual(
                try DicomWebSTOWMultipartBodyBuilder.serializedByteCount(
                    instances: instances,
                    boundary: "PART10",
                    maximumBytes: .max
                ),
                body.count,
                relativePath
            )
        }
    }

    func test_build_part10FixtureWithMatchingExplicitTransferSyntaxPreservesPayloadBytes() throws {
        let payload = try fixtureData("DecoderParity/jpeg_lossless_sv1_parity.dcm")
        let instance = DicomWebStoreInstance(
            data: payload,
            transferSyntax: DicomTransferSyntax.jpegLosslessFirstOrder.rawValue
        )

        let body = try DicomWebSTOWMultipartBodyBuilder.build(
            instances: [instance],
            boundary: "MATCH",
            maximumBytes: .max
        )
        let part = try XCTUnwrap(DicomWebMultipartParser.parts(from: body, boundary: "MATCH").first)

        XCTAssertEqual(
            part.contentType,
            "application/dicom; transfer-syntax=\(DicomTransferSyntax.jpegLosslessFirstOrder.rawValue)"
        )
        XCTAssertEqual(part.body, payload)
    }

    func test_build_slicedPart10DataDerivesTransferSyntaxWithoutIndexTrap() throws {
        let payload = try fixtureData("DecoderParity/jpeg_lossless_sv1_parity.dcm")
        var storage = Data(repeating: 0xA5, count: 150)
        storage.append(payload)
        let slicedPayload: Data = storage[150...]
        XCTAssertEqual(slicedPayload.startIndex, 150)

        let body = try DicomWebSTOWMultipartBodyBuilder.build(
            instances: [DicomWebStoreInstance(data: slicedPayload, transferSyntax: nil)],
            boundary: "SLICED",
            maximumBytes: .max
        )
        let part = try XCTUnwrap(DicomWebMultipartParser.parts(from: body, boundary: "SLICED").first)

        XCTAssertEqual(
            part.contentType,
            "application/dicom; transfer-syntax=\(DicomTransferSyntax.jpegLosslessFirstOrder.rawValue)"
        )
        XCTAssertEqual(part.body, payload)
    }

    func test_build_part10TransferSyntaxMismatchThrowsBeforeBudgetCheck() throws {
        let payload = try fixtureData("DecoderParity/jpeg_lossless_sv1_parity.dcm")
        let instance = DicomWebStoreInstance(data: payload)

        XCTAssertThrowsError(
            try DicomWebSTOWMultipartBodyBuilder.build(
                instances: [instance],
                boundary: "MISMATCH",
                maximumBytes: 1
            )
        ) { error in
            XCTAssertEqual(error as? DicomWebClientError, .storeTransferSyntaxMismatch(instanceIndex: 0))
        }
    }

    func test_build_recognizedPart10WithoutTransferSyntaxThrowsTypedError() {
        var payload = Data(repeating: 0, count: 132)
        payload.replaceSubrange(128..<132, with: Data("DICM".utf8))
        let instance = DicomWebStoreInstance(data: payload, transferSyntax: nil)

        XCTAssertThrowsError(
            try DicomWebSTOWMultipartBodyBuilder.build(
                instances: [instance],
                boundary: "MALFORMED",
                maximumBytes: .max
            )
        ) { error in
            XCTAssertEqual(error as? DicomWebClientError, .invalidStorePart10FileMeta(instanceIndex: 0))
        }
    }

    func test_add_whenCapacityOverflowsThrowsTypedErrorWithoutMutation() {
        var byteCount = Int.max

        XCTAssertThrowsError(try DicomWebSTOWMultipartBodyBuilder.add(1, to: &byteCount)) { error in
            XCTAssertEqual(error as? DicomWebClientError, .multipartBodyTooLarge)
        }
        XCTAssertEqual(byteCount, Int.max)
    }

    func test_build_whenTaskIsCancelledStopsBeforeAllocation() async {
        let stoppedBeforeAllocation = await Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            do {
                _ = try DicomWebSTOWMultipartBodyBuilder.build(
                    instances: [DicomWebStoreInstance(data: Data(repeating: 0xA5, count: 1_024))],
                    boundary: "CANCEL",
                    maximumBytes: .max
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        XCTAssertTrue(stoppedBeforeAllocation)
    }

    func test_build_reportedBytesParseToOriginalPartsAndTransferSyntaxes() throws {
        let instances = [
            DicomWebStoreInstance(data: Data([0x10]), transferSyntax: "1.2.840.10008.1.2.1"),
            DicomWebStoreInstance(data: Data([0x20, 0x21]), transferSyntax: nil),
            DicomWebStoreInstance(data: Data([0x30, 0x31, 0x32]), transferSyntax: "1.2.840.10008.1.2.4.90")
        ]

        let body = try DicomWebSTOWMultipartBodyBuilder.build(
            instances: instances,
            boundary: "PARSE",
            maximumBytes: .max
        )
        let parts = try DicomWebMultipartParser.parts(from: body, boundary: "PARSE")

        XCTAssertEqual(parts.map(\.body), instances.map(\.data))
        XCTAssertEqual(parts.map(\.contentType), [
            "application/dicom; transfer-syntax=1.2.840.10008.1.2.1",
            "application/dicom",
            "application/dicom; transfer-syntax=1.2.840.10008.1.2.4.90"
        ])
    }

    private func assertExactBudget(instances: [DicomWebStoreInstance], boundary: String) throws {
        let byteCount = try DicomWebSTOWMultipartBodyBuilder.serializedByteCount(
            instances: instances,
            boundary: boundary,
            maximumBytes: .max
        )

        XCTAssertNoThrow(
            try DicomWebSTOWMultipartBodyBuilder.build(
                instances: instances,
                boundary: boundary,
                maximumBytes: byteCount
            )
        )
        XCTAssertThrowsError(
            try DicomWebSTOWMultipartBodyBuilder.build(
                instances: instances,
                boundary: boundary,
                maximumBytes: byteCount - 1
            )
        ) { error in
            XCTAssertEqual(
                error as? DicomWebClientError,
                .storeRequestBodyTooLarge(byteCount: byteCount, limit: byteCount - 1)
            )
        }
    }

    private func fixtureData(_ relativePath: String) throws -> Data {
        try Data(contentsOf: DicomTestFixtures.directory.appendingPathComponent(relativePath))
    }
}
