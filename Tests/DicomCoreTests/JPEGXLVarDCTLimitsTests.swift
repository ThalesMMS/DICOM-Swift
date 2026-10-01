import Foundation
@testable import DicomCore
@testable import DicomJPEGXL
import XCTest

final class JPEGXLVarDCTLimitsTests: XCTestCase {
    func test_patchAndSplineHeadersAreRefusedByName() throws {
        for (flag, reason) in [(FrameFlag.patches, "patch dictionary"), (.splines, "splines")] {
            let data = try stream(header: FrameHeader(flags: flag.rawValue))
            assertRefused(reason) { try JXLDecoder().decode(data) }
        }
    }

    func test_upsampledAlphaDepthAndSpotChannelsAreRefusedBeforePixels() throws {
        for type in [ExtraChannelType.alpha, .depth, .spotColor] {
            let extra = ExtraChannelInfo(type: type, bitDepth: .standard, dimShift: 0, name: "",
                                        spotColorRGBA: type == .spotColor ? (1, 0, 0, 1) : nil)
            for upsampling: UInt32 in [2, 4, 8] {
                let data = try stream(header: FrameHeader(upsampling: upsampling), extras: [extra])
                assertRefused("extra channels in an upsampled frame") { try JXLDecoder().decode(data) }
            }
        }
    }

    func test_customSizeAndSignedOriginsAreRefusedBeforePixels() throws {
        for origin: (Int32, Int32) in [(0, 0), (1, 2), (-1, -2)] {
            let header = FrameHeader(customSizeOrOrigin: true, frameOrigin: origin,
                                     frameSize: SizeHeader(xsize: 16, ysize: 12))
            assertRefused("custom size or origin") { try JXLDecoder().decode(stream(header: header)) }
        }
    }

    func test_customOpsinIsRefusedByName() throws {
        assertRefused("custom opsin inverse matrix") {
            try JXLDecoder().decode(stream(header: FrameHeader(), customOpsin: true))
        }
    }

    func test_modularXYBWithEPFIsRefusedBeforePixels() throws {
        for iterations: UInt32 in [1, 2, 3] {
            let header = FrameHeader(encoding: .modular,
                                     loopFilter: LoopFilter(allDefault: false, gab: false, epfIters: iterations))
            assertRefused("XYB frame with EPF") { try JXLDecoder().decode(stream(header: header)) }
        }
    }

    func test_blendingIsRefusedInsteadOfReturningUncompositedPixels() throws {
        let chunks = try VarDCTBitstreamWriter.buildFrameSections(frame: sourceFrame(), gaborish: false)
        for mode in [BlendMode.add, .mul] {
            let header = FrameHeader(bQmScale: 4, blendingInfo: BlendingInfo(mode: mode, source: 1),
                                     loopFilter: LoopFilter(allDefault: false, gab: false, epfIters: 0))
            let data = try stream(header: header, sections: chunks.sections)
            assertRefused("blending") { try JXLDecoder().decode(data) }
        }
    }

    func test_animationBeyondFirstImageIsRefusedByFrameAPIs() throws {
        let source = sourceFrame()
        let data = try VarDCTBitstreamWriter.encodeAnimation(frames: [source, source], gaborish: false)
        let decoder = JXLDecoder()
        let first = try decoder.decode(data)
        XCTAssertEqual(first.data, try decoder.decodeFrame(data, at: 0).data)
        XCTAssertEqual(first.data, try decoder.decode(VarDCTBitstreamWriter.encode(frame: source, gaborish: false)).data)
        XCTAssertEqual(try decoder.countFrames(data), 2)
        assertRefused("animation beyond the first image") { try decoder.decodeAll(data) }
        assertRefused("animation beyond the first image") { try decoder.decodeFrame(data, at: 1) }
    }

    func test_standaloneVarDCTDCFrameIsRefusedByFrameAPI() throws {
        let data = try corpus("rgb8_300_d1_prog_dc2")
        let parts = try split(data)
        let index = try XCTUnwrap(parts.frames.firstIndex { $0.header.frameType == .dcFrame && $0.header.encoding == .varDCT })
        assertRefused("outside a frame sequence") { try JXLDecoder().decodeFrame(data, at: index) }
    }

    func test_truncatedFrameRangeIsRefusedWithoutSubdataTrap() throws {
        let data = try VarDCTBitstreamWriter.encode(frame: sourceFrame(), gaborish: false)
        XCTAssertThrowsError(try JXLDecoder().decodeFrame(Data(data.dropLast()), at: 0)) { error in
            guard case DecoderError.notImplemented(let reason) = error else {
                return XCTFail("Expected typed refusal, got \(error)")
            }
            XCTAssertTrue([
                "decodeFrame: frame extends past codestream end",
                "decodeFrame: frame sections extend beyond the codestream"
            ].contains(reason), "\(error)")
        }
    }

    func test_eightDCFramesAreAcceptedAndNinthIsRefusedWithoutPartialImage() throws {
        let data = try corpus("rgb8_300_d1_prog")
        let parts = try split(data)
        let dc = try XCTUnwrap(parts.frames.first { $0.header.frameType == .dcFrame && $0.header.encoding == .modular })
        let image = try XCTUnwrap(parts.frames.last)
        XCTAssertEqual(image.header.frameType, .regular)
        var boundary = parts.prelude
        for _ in 0..<8 { boundary.append(dc.bytes) }
        let beyond = boundary + dc.bytes + image.bytes
        boundary.append(image.bytes)
        XCTAssertEqual(try JXLDecoder().decode(boundary).data, try JXLDecoder().decode(data).data)
        assertRefused("more than 8 frames before the image") { try JXLDecoder().decode(beyond) }
    }

    func test_highDepthRGBIsRefusedByDICOMAdapterBeforeReadingPixels() async throws {
        for bits in [9, 12, 16] {
            let descriptor = DicomCompressedFrameDescriptor(
                transferSyntaxUID: DicomTransferSyntax.jpegXL.rawValue, rows: 13, columns: 17,
                bitsAllocated: 16, bitsStored: bits, highBit: bits - 1, pixelRepresentation: 0,
                samplesPerPixel: 3, photometricInterpretation: "RGB", planarConfiguration: 0)
            do {
                _ = try await DicomJXLSwiftBackend().decode(
                    DicomFrameDecodeRequest(frameData: Data(), descriptor: descriptor, frameIndex: 0))
                XCTFail("High-depth RGB must not be truncated to RGB8")
            } catch let error as DicomJXLSwiftBackendError {
                guard case .unsupportedShape = error else { return XCTFail("\(error)") }
                XCTAssertTrue("\(error)".lowercased().contains("bit"), "\(error)")
            }
        }
    }

    func test_largeDCTStrategiesRefuseNonzeroACInEveryChannelAndKeepDCOnly() throws {
        let strategies: [ACStrategy] = [.dct128x128, .dct128x64, .dct64x128, .dct256x256, .dct256x128, .dct128x256]
        for strategy in strategies {
            let cells = strategy.blockCells
            let count = cells.cellsX * cells.cellsY * 64
            let zero = [[Int32]](repeating: [Int32](repeating: 0, count: count), count: 3)
            XCTAssertNoThrow(try JXLDecoder.requireInverseTransform(strategy, coefficients: zero))
            for channel in 0..<3 {
                var coefficients = zero
                coefficients[channel][count - 1] = channel == 1 ? -1 : 1
                assertRefused("per-strategy IDCT") {
                    try JXLDecoder.requireInverseTransform(strategy, coefficients: coefficients)
                }
            }
        }
        for strategy in ACStrategy.allCases where !strategies.contains(strategy) {
            XCTAssertNoThrow(try JXLDecoder.requireInverseTransform(strategy, coefficients: [[1], [-1], [2]]))
        }
    }

    func test_spotColorMetadataPreservesHeaderBoundaryAndValues() throws {
        let extra = ExtraChannelInfo(type: .spotColor, bitDepth: .standard, dimShift: 0, name: "",
                                     spotColorRGBA: (1, 0.5, 0.25, 1))
        let data = try stream(header: FrameHeader(upsampling: 2), extras: [extra])
        var reader = BitReader(data, startingAt: 16)
        _ = try SizeHeader.read(from: &reader)
        let metadata = try ImageMetadata.read(from: &reader)
        let decoded = try XCTUnwrap(metadata.extraChannels.first?.spotColorRGBA)
        XCTAssertEqual(decoded.0, 1)
        XCTAssertEqual(decoded.1, 0.5)
        XCTAssertEqual(decoded.2, 0.25)
        XCTAssertEqual(decoded.3, 1)
        XCTAssertTrue(try reader.readBit(), "CustomTransformData all_default follows the metadata")
    }

    private func assertRefused<T>(_ reason: String, file: StaticString = #filePath, line: UInt = #line,
                                  _ body: () throws -> T) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertTrue(error is DecoderError, "\(error)", file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains(reason), "\(error)", file: file, line: line)
        }
    }

    private func sourceFrame() -> ImageFrame {
        let count = 17 * 13 * 3
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = UInt8((i * 7 + i / 17) % 256) }
        return ImageFrame(width: 17, height: 13, channels: 3, data: bytes)
    }

    /// Header probes intentionally omit pixel sections when the refusal precedes pixel decoding.
    /// The blending tests instead retain a complete, valid own-encoder payload.
    private func stream(header: FrameHeader, extras: [ExtraChannelInfo] = [], customOpsin: Bool = false,
                        sections: [Data] = [Data()]) throws -> Data {
        var writer = BitWriter()
        writer.write(bits: 16, value: 0x0AFF)
        try SizeHeader(xsize: 17, ysize: 13).write(to: &writer)
        let metadata = ImageMetadata(
            allDefault: true, orientation: 1, intrinsicSize: nil, preview: nil, animation: nil,
            bitDepth: .standard, modular16BitBufferSufficient: true, extraChannels: extras,
            xybEncoded: true, colorEncoding: .srgb, intensityTarget: 255, minNits: 0,
            relativeToMaxDisplay: false, linearBelow: 0)
        try metadata.write(to: &writer)
        writer.writeBit(!customOpsin)
        if customOpsin { writer.writeBit(false) }
        writer.alignToByte()
        try header.write(to: &writer, context: FrameHeaderContext(xybEncoded: true, numExtraChannels: extras.count))
        var total: UInt64 = 0
        var offsets: [UInt64] = [0]
        for section in sections { total += UInt64(section.count); offsets.append(total) }
        try TOC(hasPermutation: false, entrySizes: sections.map { UInt32($0.count) }, offsets: offsets).write(to: &writer)
        var data = writer.finishToData()
        for section in sections { data.append(section) }
        return data
    }

    private func corpus(_ name: String) throws -> Data {
        guard let directory = ProcessInfo.processInfo.environment["DICOM_JPEGXL_LOSSY_CORPUS_DIRECTORY"] else {
            throw XCTSkip("DICOM_JPEGXL_LOSSY_CORPUS_DIRECTORY unset")
        }
        return try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent(name + ".jxl"))
    }

    private func split(_ data: Data) throws -> (prelude: Data, frames: [(header: FrameHeader, bytes: Data)]) {
        var reader = BitReader(data, startingAt: 16)
        let size = try SizeHeader.read(from: &reader)
        let metadata = try ImageMetadata.read(from: &reader)
        _ = try CustomTransformData.read(from: &reader, xybEncoded: metadata.xybEncoded)
        if metadata.colorEncoding.useICC { _ = try ICCStream.decode(from: &reader) }
        try reader.alignToByte()
        let prelude = data.prefix(reader.position / 8)
        let context = FrameHeaderContext(xybEncoded: metadata.xybEncoded, numExtraChannels: metadata.extraChannels.count,
                                         haveAnimation: metadata.animation != nil)
        var frames: [(header: FrameHeader, bytes: Data)] = []
        while true {
            let start = reader.position / 8
            let header = try FrameHeader.read(from: &reader, context: context)
            let shape = JXLDecoder.codedFrameSize(header, imageWidth: Int(size.xsize), imageHeight: Int(size.ysize))
            let group = 128 << Int(header.groupSizeShift), dcGroup = group << 3
            let groups = ((shape.width + group - 1) / group) * ((shape.height + group - 1) / group)
            let dcGroups = ((shape.width + dcGroup - 1) / dcGroup) * ((shape.height + dcGroup - 1) / dcGroup)
            let entries = TOC.numEntries(numGroups: groups, numDcGroups: dcGroups, numPasses: Int(header.passes.numPasses))
            let toc = try TOC.read(from: &reader, numEntries: entries)
            let bytes = toc.entrySizes.reduce(0) { $0 + Int($1) }
            try reader.skip(bits: bytes * 8)
            frames.append((header, data.subdata(in: start..<(reader.position / 8))))
            if header.isLast { break }
        }
        return (Data(prelude), frames)
    }
}
