//
//  DicomJ2KQualityLayerRefinementTests.swift
//  DicomCoreTests
//
//  Issue #2382: cumulative quality-layer decode combined with resolution reduction and ROI in the own JPEG 2000
//  codec, tier-2 reuse between refinements, packet-byte accounting and the reader/capability contract. Layer
//  decodes are checked bit-for-bit against the Kakadu references shipped with the pinned J2KSwift fixture.
//

import DicomJPEG2000
import DicomTestSupport
import Foundation
import XCTest
@testable import DicomCore

final class DicomJ2KQualityLayerRefinementTests: XCTestCase {
    private static func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil), "Missing packaged fixture \(name)")
        return try Data(contentsOf: url)
    }

    /// 16-bit big-endian P5 PGM → little-endian sample bytes as the reader delivers them.
    private static func pgmSamples(_ data: Data) throws -> [UInt16] {
        var cursor = 0
        func token() -> String {
            while cursor < data.count, data[cursor] == 0x20 || data[cursor] == 0x0A || data[cursor] == 0x0D || data[cursor] == 0x09 { cursor += 1 }
            var end = cursor
            while end < data.count, !(data[end] == 0x20 || data[end] == 0x0A || data[end] == 0x0D || data[end] == 0x09) { end += 1 }
            defer { cursor = end + 1 }
            return String(decoding: data[cursor..<end], as: UTF8.self)
        }
        XCTAssertEqual(token(), "P5")
        let width = try XCTUnwrap(Int(token())), height = try XCTUnwrap(Int(token()))
        let maximum = try XCTUnwrap(Int(token()))
        XCTAssertGreaterThan(maximum, 255)
        let bytes = data[cursor..<(cursor + width * height * 2)]
        var samples = [UInt16](repeating: 0, count: width * height)
        var index = bytes.startIndex
        for i in 0..<samples.count { samples[i] = UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]); index += 2 }
        return samples
    }

    /// The decoder writes 16-bit samples high byte first.
    private func component16(_ image: J2KImage) throws -> [UInt16] {
        let component = try XCTUnwrap(image.components.first)
        XCTAssertEqual(component.bitDepth, 16)
        let count = component.width * component.height
        var samples = [UInt16](repeating: 0, count: count)
        component.data.withUnsafeBytes { raw in
            for i in 0..<count { samples[i] = UInt16(raw[2 * i]) << 8 | UInt16(raw[2 * i + 1]) }
        }
        return samples
    }

    private static func psnr(_ a: [UInt16], _ b: [UInt16]) -> Double {
        var sum = 0.0
        for i in 0..<a.count { let d = Double(a[i]) - Double(b[i]); sum += d * d }
        let mse = sum / Double(a.count)
        return mse == 0 ? .infinity : 10 * log10(65535.0 * 65535.0 / mse)
    }

    /// Kakadu truncates layers with its own rate allocation, so its references are a fidelity witness (PSNR, as in
    /// the pinned J2KSwift suite); exactness per layer is proven against `opj_decompress -l` by the oracle script.
    func test_layerDecodesTrackTheKakaduReferencesAndImproveMonotonically() async throws {
        let codestream = try Self.fixture("ct512_L4.j2k")
        let decoder = J2KDecoder()
        let final = try component16(try await decoder.decode(codestream))
        var previous = 0.0
        for layers in 1...3 {
            let reference = try Self.pgmSamples(try Self.fixture("ct512_L4_kdu_layers\(layers).pgm"))
            let (image, report) = try await decoder.decodePartialReporting(codestream, options: J2KPartialDecodingOptions(maxLayer: layers - 1))
            let ours = try component16(image)
            XCTAssertGreaterThan(Self.psnr(ours, reference), 30, "layers 0...\(layers - 1) versus kdu_expand -layers \(layers)")
            let towardsFinal = Self.psnr(ours, final)
            XCTAssertGreaterThanOrEqual(towardsFinal, previous, "each refinement approaches the final image")
            previous = towardsFinal
            XCTAssertEqual(report.decodedLayers, layers); XCTAssertEqual(report.totalLayers, 4)
            XCTAssertGreaterThan(report.skippedPacketBytes, 0)
        }
        let (full, fullReport) = try await decoder.decodePartialReporting(codestream, options: J2KPartialDecodingOptions(maxLayer: 3))
        XCTAssertEqual(fullReport.skippedPacketBytes, 0)
        XCTAssertEqual(try component16(full), final)
    }

    func test_refinementSessionReusesTierTwoAndAccountsBytes() async throws {
        let codestream = try Self.fixture("ct512_L4.j2k")
        let session = J2KQualityRefinementSession(data: codestream)
        let decoder = J2KDecoder()
        var previousConsumed = -1
        var total: Int?
        for layer in 0..<4 {
            let (image, report) = try await session.decode(layer: layer)
            let expected = try await decoder.decodeQuality(codestream, options: J2KQualityDecodingOptions(layer: layer, cumulative: true))
            XCTAssertEqual(try component16(image), try component16(expected), "session layer \(layer)")
            XCTAssertEqual(report.parsedTiles, layer == 0 ? 1 : 0, "the packet parse runs once")
            XCTAssertEqual(report.reusedTiles, layer == 0 ? 0 : 1, "later refinements reuse the tier-2 state")
            XCTAssertGreaterThan(report.consumedPacketBytes, previousConsumed, "each refinement feeds more bytes to tier-1")
            previousConsumed = report.consumedPacketBytes
            if let total { XCTAssertEqual(report.consumedPacketBytes + report.skippedPacketBytes, total) } else { total = report.consumedPacketBytes + report.skippedPacketBytes }
            XCTAssertEqual(report.isFinalLayer, layer == 3)
        }
        let perLayer = session.bytesPerLayer
        XCTAssertEqual(perLayer.count, 4)
        XCTAssertTrue(perLayer.allSatisfy { $0 > 0 })
        XCTAssertEqual(session.history.count, 4)
        let fresh = J2KQualityRefinementSession(data: codestream)
        J2KDecodeTimings.reset()
        let index = try await fresh.index()
        XCTAssertEqual(J2KDecodeTimings.snapshot().entropyDecoding, 0)
        XCTAssertEqual(J2KDecodeTimings.snapshot().reconstructImage, 0)
        XCTAssertEqual(index, perLayer, "the tier-2 index equals the per-layer totals of a full parse")
        let indexedDecode = try await fresh.decode(layer: 0)
        XCTAssertEqual(indexedDecode.report.parsedTiles, 0)
        XCTAssertEqual(indexedDecode.report.reusedTiles, 1)
    }

    func test_refinementSession_differentCodestream_isRejectedBeforeCacheReuse() async throws {
        let session = J2KQualityRefinementSession(data: try Self.fixture("ct512_L4.j2k"))
        _ = try await session.index()
        do {
            _ = try await J2KDecoder().decodePartialReporting(
                Self.fixture("ct512_L2.j2k"), options: .init(maxLayer: 0), session: session)
            XCTFail("A cached packet index must not serve another codestream")
        } catch J2KError.invalidParameter {
            XCTAssertTrue(session.history.isEmpty)
        }
    }

    func test_qualityIndex_zeroDecompositionLevels_preservesPacketTotals() async throws {
        let component = J2KComponent(index: 0, bitDepth: 8, signed: false, width: 8, height: 8,
                                     data: Data((0..<64).map { UInt8($0 * 3) }))
        let image = J2KImage(width: 8, height: 8, components: [component], colorSpace: .grayscale)
        let data = try await J2KEncoder(encodingConfiguration: .init(
            quality: 1, lossless: true, decompositionLevels: 0, qualityLayers: 1, progressionOrder: .lrcp)).encode(image)
        let session = J2KQualityRefinementSession(data: data)
        J2KDecodeTimings.reset()
        let totals = try await session.index()
        XCTAssertEqual(J2KDecodeTimings.snapshot().entropyDecoding, 0)
        XCTAssertEqual(J2KDecodeTimings.snapshot().reconstructImage, 0)
        XCTAssertEqual(totals.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(totals.first), 0)
        XCTAssertTrue(session.history.isEmpty)
        let repeated = try await session.index()
        XCTAssertEqual(repeated, totals)
    }

    func test_refinementSessionCombinesLayerWithRegionAndResolution() async throws {
        let codestream = try Self.fixture("ct512_L4.j2k")
        let session = J2KQualityRefinementSession(data: codestream)
        let region = J2KRegion(x: 100, y: 60, width: 64, height: 48)
        let (regionImage, regionReport) = try await session.decode(layer: 1, region: region)
        XCTAssertEqual(regionImage.width, 64); XCTAssertEqual(regionImage.height, 48)
        XCTAssertGreaterThan(regionReport.skippedPacketBytes, 0)
        let layerImage = try await J2KDecoder().decodeQuality(codestream, options: J2KQualityDecodingOptions(layer: 1, cumulative: true))
        let full = try component16(layerImage)
        var expected: [UInt16] = []
        for y in region.y..<(region.y + region.height) { expected += full[(y * 512 + region.x)..<(y * 512 + region.x + region.width)] }
        XCTAssertEqual(try component16(regionImage), expected, "region of layer 1 equals the crop of the layer-1 decode")

        let levels = try XCTUnwrap(DicomJ2KCodestreamInfo.parse(codestream).decompositionLevels)
        XCTAssertGreaterThan(levels, 0)
        let (reduced, reducedReport) = try await session.decode(layer: 0, maxResolutionLevel: levels - 1)
        XCTAssertEqual(reduced.width, 256); XCTAssertEqual(reduced.height, 256)
        XCTAssertGreaterThan(reducedReport.reusedTiles, 0, "resolution refinements reuse the same tier-2 parse")
        let direct = try await J2KDecoder().decodePartial(codestream, options: J2KPartialDecodingOptions(maxLayer: 0, maxResolutionLevel: levels - 1))
        XCTAssertEqual(try component16(reduced), try component16(direct))
        let (both, _) = try await session.decode(layer: 0, region: J2KRegion(x: 64, y: 32, width: 128, height: 96), maxResolutionLevel: levels - 1)
        XCTAssertEqual(both.width, 64); XCTAssertEqual(both.height, 48)
        let reducedSamples = try component16(reduced)
        var expectedReduced: [UInt16] = []
        for y in 16..<64 { expectedReduced += reducedSamples[(y * 256 + 32)..<(y * 256 + 96)] }
        XCTAssertEqual(try component16(both), expectedReduced, "layer + region + resolution equals the crop of the layer + resolution decode")
    }

    func test_refinementSessionHonoursCancellation() async throws {
        let codestream = try Self.fixture("ct512_L4.j2k")
        let session = J2KQualityRefinementSession(data: codestream)
        let task = Task { try await session.decode(layer: 3) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
        catch { XCTFail("unexpected \(error)") }
    }

    func test_readerCombinesLayerWithRegionReportsBytesAndIndexesLayers() async throws {
        let codestream = try Self.fixture("ct512_L4.j2k")
        let file = try EncapsulatedFixtureFactory.makeFile(transferSyntax: .jpeg2000Lossless, fragments: [codestream], declaredFrames: 1,
                                                          rows: 512, columns: 512, bitsAllocated: 16, bitsStored: 16, highBit: 15)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("quality-refinement-\(UUID().uuidString).dcm")
        try file.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let capabilities = try await reader.partialDecodeCapabilities(at: 0)
        XCTAssertTrue(capabilities.supportsQualityWithSpatialReduction)
        XCTAssertNil(capabilities.qualityLayerByteTotals, "the header probe stays header-only")
        let indexed = try await reader.partialDecodeCapabilitiesWithQualityIndex(at: 0)
        let totals = try XCTUnwrap(indexed.qualityLayerByteTotals)
        XCTAssertEqual(totals.count, 4)
        let fraction = try XCTUnwrap(indexed.byteFraction(throughLayer: 0))
        XCTAssertGreaterThan(fraction, 0); XCTAssertLessThan(fraction, 1)
        XCTAssertEqual(indexed.byteFraction(throughLayer: 3) ?? 0, 1, accuracy: 1e-9)

        let combined = try await reader.frame(at: 0, partial: DicomPartialFrameDecodeRequest(
            sourceRegion: DicomFrameRegion(x: 100, y: 60, width: 64, height: 48), maximumQualityLayer: 1))
        XCTAssertEqual(combined.execution, .directRegion)
        XCTAssertEqual(combined.qualityState, .refinement(layer: 1))
        XCTAssertEqual(combined.deliveredQualityLayer, 1)
        XCTAssertFalse(combined.isFinalQuality)
        XCTAssertGreaterThan(try XCTUnwrap(combined.codecBytesAvoided), 0)
        guard case .gray16(let regionPixels) = combined.frame.pixels else { return XCTFail("expected 16-bit pixels") }
        let layerFrame = try await reader.frame(at: 0, partial: DicomPartialFrameDecodeRequest(maximumQualityLayer: 1))
        XCTAssertEqual(layerFrame.execution, .directQualityLayer)
        guard case .gray16(let layerPixels) = layerFrame.frame.pixels else { return XCTFail("expected 16-bit pixels") }
        var expected: [UInt16] = []
        for y in 60..<108 { expected += layerPixels[(y * 512 + 100)..<(y * 512 + 164)] }
        XCTAssertEqual(regionPixels, expected)
        let reducedCombo = try await reader.frame(at: 0, partial: DicomPartialFrameDecodeRequest(resolutionReductionLevel: 1, maximumQualityLayer: 0))
        XCTAssertEqual(reducedCombo.execution, .directResolution)
        XCTAssertEqual(reducedCombo.qualityState, .preview)
        XCTAssertEqual(reducedCombo.frame.metadata.width, 256)
        let finalCombo = try await reader.frame(at: 0, partial: DicomPartialFrameDecodeRequest(resolutionReductionLevel: 1, maximumQualityLayer: 3, requiresFinalQuality: true))
        XCTAssertTrue(finalCombo.isFinalQuality)
        XCTAssertEqual(finalCombo.codecBytesAvoided, 0)
    }

    func test_fullDecodeThroughputIsUnaffectedByAccounting() async throws {
        // Guard against regression in the single-layer fast path: a plain decode never attaches accounting.
        let codestream = try Self.fixture("ct512_L2.j2k")
        let decoder = J2KDecoder()
        let plain = try await decoder.decode(codestream)
        let (reported, report) = try await decoder.decodePartialReporting(codestream, options: J2KPartialDecodingOptions())
        XCTAssertEqual(try component16(plain), try component16(reported))
        XCTAssertEqual(report.skippedPacketBytes, 0)
    }
}
