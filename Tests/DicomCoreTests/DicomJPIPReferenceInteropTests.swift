import CryptoKit
import Foundation
import XCTest
@testable import DicomCore

final class DicomJPIPReferenceInteropTests: XCTestCase {
    func test_referenceServer_returnsProgressivelyDecodableGoldenImages() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let urlValue = environment["DICOM_JPIP_REFERENCE_URL"],
              let providerURL = URL(string: urlValue) else {
            throw XCTSkip("Set DICOM_JPIP_REFERENCE_URL to run the external JPIP qualification.")
        }
        guard let uid = environment["DICOM_JPIP_REFERENCE_TRANSFER_SYNTAX_UID"],
              let transferSyntax = DicomTransferSyntax(uid: uid),
              transferSyntax.usesPixelDataProviderURL else {
            XCTFail("DICOM_JPIP_REFERENCE_TRANSFER_SYNTAX_UID must be .94, .95, .204, or .205")
            return
        }
        guard let expectedHashesValue = environment["DICOM_JPIP_REFERENCE_PIXEL_SHA256"] else {
            XCTFail("DICOM_JPIP_REFERENCE_PIXEL_SHA256 must list one decoded-pixel hash per layer")
            return
        }
        let expectedHashes = expectedHashesValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard !expectedHashes.isEmpty else {
            XCTFail("At least one decoded-pixel hash is required")
            return
        }
        guard DicomJPEG2000Codec.isAvailable else {
            throw XCTSkip("The OpenJPEG runtime is required to qualify decoded golden pixels.")
        }
        if transferSyntax == .jpipHTJ2KReferenced || transferSyntax == .jpipHTJ2KReferencedDeflate,
           !DicomJPEG2000Codec.supportsHTJ2K {
            throw XCTSkip("The active OpenJPEG runtime does not support HTJ2K.")
        }
        let allowsInsecureHTTP = environment["DICOM_JPIP_REFERENCE_ALLOW_INSECURE_HTTP"] == "1"
        guard let origin = DicomJPIPOrigin(url: providerURL) else {
            XCTFail("Reference URL must use HTTP or HTTPS")
            return
        }
        var configuration = DicomJPIPTransportConfiguration(
            defaultLayerCount: expectedHashes.count,
            maximumLayerCount: expectedHashes.count,
            maximumResponseBytes: 64 * 1_024 * 1_024,
            maximumTotalBytes: 256 * 1_024 * 1_024,
            allowsInsecureHTTP: allowsInsecureHTTP,
            allowedOrigins: [origin]
        )
        configuration.redirectPolicy = .sameOrigin(maximumHops: 1)
        let transport = try DicomJPIPHTTPTransport(configuration: configuration)
        let request = DicomJPIPRequest(
            pixelDataProviderURL: providerURL,
            resource: .volume,
            transferSyntax: transferSyntax
        )

        var actualHashes = [String]()
        var decodedShape: (width: Int, height: Int, bits: Int, components: Int)?
        for try await payload in transport.payloads(for: request) {
            try Task.checkCancellation()
            let decoded = try DicomJPEG2000Codec.decode(payload.data)
            let shape = (
                width: decoded.width,
                height: decoded.height,
                bits: decoded.bitsPerSample,
                components: decoded.componentCount
            )
            if let decodedShape {
                XCTAssertEqual(shape.width, decodedShape.width)
                XCTAssertEqual(shape.height, decodedShape.height)
                XCTAssertEqual(shape.bits, decodedShape.bits)
                XCTAssertEqual(shape.components, decodedShape.components)
            } else {
                decodedShape = shape
            }
            actualHashes.append(Self.sha256(decoded.bytes))
        }

        XCTAssertEqual(actualHashes, expectedHashes)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
