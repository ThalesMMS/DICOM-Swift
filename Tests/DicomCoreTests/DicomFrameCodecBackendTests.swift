import Foundation
import XCTest
@testable import DicomCore

final class DicomFrameCodecBackendTests: XCTestCase {
    func test_capabilityModelRepresentsPlannedPartialMetalCodec() {
        let capability = makeCapability(
            identifier: "j2kswift-metal",
            executionClass: .metal,
            partialDecode: DicomPartialDecodeCapabilities(
                supportsRegionOfInterest: true,
                supportsResolutionLevels: true,
                supportsQualityLayers: true
            ),
            outputOwnership: .sharedBuffer
        )

        XCTAssertEqual(capability.families, [.jpeg2000])
        XCTAssertEqual(capability.executionClass, .metal)
        XCTAssertEqual(capability.outputOwnership, .sharedBuffer)
        XCTAssertTrue(capability.partialDecode.supportsRegionOfInterest)
        XCTAssertTrue(capability.partialDecode.supportsResolutionLevels)
        XCTAssertTrue(capability.partialDecode.supportsQualityLayers)
        XCTAssertNil(capability.unsupportedReason(for: makeDescriptor()))
    }

    func test_currentCapabilityCatalogIncludesLinkedAndRuntimeBackends() throws {
        let capabilities = DicomCodecCapabilities.frameBackends(environment: [:])

        XCTAssertEqual(capabilities.count, 12)
        XCTAssertEqual(
            capabilities.first { $0.identifier == .j2kSwiftCPU }?.transferSyntaxUIDs,
            DicomJ2KSwiftBackend.qualifiedTransferSyntaxes
        )
        XCTAssertEqual(capabilities.first { $0.identifier == .jlSwift }?.version, "0.9.0")
        XCTAssertEqual(capabilities.first { $0.identifier == .jxlSwift }?.version, "1.4.0")
        XCTAssertEqual(
            capabilities.first { $0.identifier == .jxlSwift }?.transferSyntaxUIDs,
            DicomJXLSwiftBackend.allTransferSyntaxes
        )
        XCTAssertEqual(
            capabilities.first { $0.identifier == "native-rle-lossless" }?.source,
            .packageLinked
        )
        XCTAssertEqual(
            capabilities.first { $0.identifier == "imageio-jpeg-2000" }?.source,
            .systemFramework
        )
        let charLS = try XCTUnwrap(capabilities.first { $0.identifier == "charls-jpeg-ls" })
        XCTAssertEqual(charLS.families, [.jpegLS])
        XCTAssertFalse(charLS.transferSyntaxUIDs.isEmpty)
    }

    func test_registryHonorsPreferenceAndReportsFallback() throws {
        let unavailable = Backend(
            capabilities: makeCapability(
                identifier: "candidate",
                isAvailable: false,
                unsupportedReason: "candidate runtime missing"
            ),
            bytes: [9]
        )
        let production = Backend(
            capabilities: makeCapability(identifier: "production", source: .defaultSearchPath, version: "2.5.0"),
            bytes: [1]
        )
        let registry = DicomFrameCodecRegistry(backends: [unavailable, production])
        let request = makeRequest(preference: .preferred("candidate", allowsFallback: true))

        let selection = try registry.select(for: request)

        XCTAssertEqual(selection.diagnostics.selectedBackend, "production")
        XCTAssertEqual(selection.diagnostics.selectedSource, .defaultSearchPath)
        XCTAssertEqual(selection.diagnostics.selectedVersion, "2.5.0")
        XCTAssertEqual(selection.diagnostics.fallbackReason, "candidate runtime missing")
    }

    func test_registryStrictPreferenceProducesTypedUnsupportedReasons() {
        let backend = Backend(
            capabilities: makeCapability(
                identifier: "candidate",
                isAvailable: false,
                unsupportedReason: "candidate runtime missing"
            ),
            bytes: [1]
        )
        let registry = DicomFrameCodecRegistry(backends: [backend])
        let request = makeRequest(preference: .preferred("candidate", allowsFallback: false))

        XCTAssertThrowsError(try registry.select(for: request)) { error in
            guard case .unsupported(let uid, let reasons) = error as? DicomCodecSelectionError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(uid, DicomTransferSyntax.jpeg2000Lossless.rawValue)
            XCTAssertTrue(reasons.joined().contains("candidate runtime missing"))
        }
    }

    func test_registryFallsBackWhenPreferredBackendCannotHonorPartialRequest() throws {
        let fullFrameOnly = Backend(capabilities: makeCapability(identifier: "full-frame"), bytes: [1])
        let partial = Backend(
            capabilities: makeCapability(
                identifier: "partial",
                partialDecode: DicomPartialDecodeCapabilities(supportsRegionOfInterest: true)
            ),
            bytes: [2]
        )
        let registry = DicomFrameCodecRegistry(backends: [fullFrameOnly, partial])
        let base = makeRequest(preference: .preferred("full-frame", allowsFallback: true))
        let request = DicomFrameDecodeRequest(
            frameData: base.frameData,
            descriptor: base.descriptor,
            frameIndex: base.frameIndex,
            partialRequest: DicomPartialDecodeRequest(
                region: .init(x: 0, y: 0, width: 1, height: 1)
            ),
            backendPreference: base.backendPreference
        )

        let selection = try registry.select(for: request)

        XCTAssertEqual(selection.diagnostics.selectedBackend, "partial")
        XCTAssertEqual(selection.diagnostics.fallbackReason, "Backend full-frame does not support ROI decode.")
    }

    func test_shadowModeComparesCandidateWithoutChangingProductionOutput() async throws {
        let production = Backend(capabilities: makeCapability(identifier: "production"), bytes: [1, 2, 3])
        let candidate = Backend(capabilities: makeCapability(identifier: "candidate"), bytes: [1, 2, 4])
        let registry = DicomFrameCodecRegistry(backends: [production, candidate])
        let request = makeRequest()
        let selection = try registry.select(
            for: request,
            shadowPolicy: DicomCodecShadowPolicy(candidatesByFamily: [.jpeg2000: "candidate"])
        )
        let recorder = ShadowRecorder()

        let decoded = try await DicomFrameCodecExecutor { recorder.record($0) }
            .decode(request, selection: selection)

        XCTAssertEqual(decoded.buffer.data, Data([1, 2, 3]))
        XCTAssertEqual(selection.diagnostics.shadowBackend, "candidate")
        XCTAssertEqual(
            recorder.comparisons,
            [DicomCodecShadowComparison(
                productionBackend: "production",
                shadowBackend: "candidate",
                result: .mismatched
            )]
        )
    }

    func test_defaultEncodeBoundaryRemainsAsyncAndTypedUnsupported() async {
        let backend = Backend(capabilities: makeCapability(identifier: "decode-only"), bytes: [1])
        let decoded = DicomCodecDecodedFrame(
            buffer: .owned(Data([1])),
            width: 1,
            height: 1,
            bitsPerSample: 8,
            componentCount: 1
        )
        let request = DicomFrameEncodeRequest(
            frame: decoded,
            descriptor: makeDescriptor(),
            targetTransferSyntaxUID: DicomTransferSyntax.jpeg2000Lossless.rawValue
        )

        do {
            _ = try await backend.encode(request)
            XCTFail("Expected typed unsupported error")
        } catch {
            XCTAssertEqual(
                error as? DicomFrameCodecBackendError,
                .encodeUnsupported(backend: "decode-only")
            )
        }
    }

    private func makeRequest(
        preference: DicomCodecBackendPreference = .automatic
    ) -> DicomFrameDecodeRequest {
        DicomFrameDecodeRequest(
            frameData: Data([0xFF, 0x4F]),
            descriptor: makeDescriptor(),
            frameIndex: 0,
            backendPreference: preference
        )
    }

    private func makeDescriptor() -> DicomCompressedFrameDescriptor {
        DicomCompressedFrameDescriptor(
            transferSyntaxUID: DicomTransferSyntax.jpeg2000Lossless.rawValue,
            rows: 1,
            columns: 1,
            bitsAllocated: 16,
            bitsStored: 12,
            highBit: 11,
            pixelRepresentation: 1,
            samplesPerPixel: 1,
            photometricInterpretation: "MONOCHROME2",
            planarConfiguration: nil
        )
    }

    private func makeCapability(
        identifier: DicomCodecBackendIdentifier,
        executionClass: DicomCodecExecutionClass = .cpu,
        partialDecode: DicomPartialDecodeCapabilities = .none,
        outputOwnership: DicomCodecOutputOwnership = .ownedData,
        source: DicomCodecBackendSource = .packageLinked,
        version: String? = nil,
        isAvailable: Bool = true,
        unsupportedReason: String? = nil
    ) -> DicomFrameCodecCapabilities {
        DicomFrameCodecCapabilities(
            identifier: identifier,
            families: [.jpeg2000],
            transferSyntaxUIDs: [DicomTransferSyntax.jpeg2000Lossless.rawValue],
            supportedGrayscaleBitDepths: 1...16,
            partialDecode: partialDecode,
            executionClass: executionClass,
            outputOwnership: outputOwnership,
            source: source,
            version: version,
            isAvailable: isAvailable,
            unsupportedReason: unsupportedReason
        )
    }
}

private struct Backend: DicomFrameCodecBackend {
    let capabilities: DicomFrameCodecCapabilities
    let bytes: [UInt8]

    func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame {
        DicomCodecDecodedFrame(
            buffer: .owned(Data(bytes)),
            width: request.descriptor.columns,
            height: request.descriptor.rows,
            bitsPerSample: request.descriptor.bitsStored,
            componentCount: request.descriptor.samplesPerPixel
        )
    }
}

private final class ShadowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [DicomCodecShadowComparison] = []

    var comparisons: [DicomCodecShadowComparison] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ comparison: DicomCodecShadowComparison) {
        lock.lock()
        storage.append(comparison)
        lock.unlock()
    }
}
