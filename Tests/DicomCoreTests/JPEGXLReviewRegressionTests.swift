import Foundation
import XCTest
@testable import DicomJPEGXL

final class JPEGXLReviewRegressionTests: XCTestCase {
    func test_modularResidualMultiplication_wrapsAt32Bits() throws {
        for (value, multiplier, expected): (Int32, UInt32, Int32) in [(.max, 3, 2_147_483_645), (.min, 2, 0), (7, 3, 21)] {
            var writer = BitWriter()
            try GroupHeader(useGlobalTree: false, wpHeader: .default, transforms: []).write(to: &writer)
            let config = HybridUintConfig(splitExponent: 0, msbInToken: 0, lsbInToken: 0)
            let book = MultiClusterCodebook(huffmanTables: [try PrefixCodeTable(lengths: Array(repeating: 6, count: 64))],
                                           ansCounts: [], alphabetSizes: [64])
            func header(contexts: Int) -> EntropySectionHeader {
                EntropySectionHeader(lz77: .disabled, contextMap: .trivial(numContexts: contexts),
                                     usePrefixCode: true, logAlphaSize: 15, uintConfigs: [config])
            }
            let treeHeader = header(contexts: 6)
            try treeHeader.write(to: &writer, numContexts: 6)
            try book.write(to: &writer, header: treeHeader)
            let tree = ModularTree(nodes: [.init(property: -1, splitVal: 0, leftChildOrLeafId: 0, rightChild: 0,
                predictor: .zero, predictorOffset: 0, multiplier: multiplier, rawPredictor: 0)])
            let treeWriter = TokenStreamWriter(header: treeHeader, codebook: book)
            try tree.encode { context, token in try treeWriter.writeToken(context: context, value: token, to: &writer) }
            let pixelHeader = header(contexts: 1)
            try pixelHeader.write(to: &writer, numContexts: 1)
            try book.write(to: &writer, header: pixelHeader)
            try TokenStreamWriter(header: pixelHeader, codebook: book).writeToken(context: 0, value: ZigZag.pack(value), to: &writer)
            var reader = BitReader(writer.finishToData())
            XCTAssertEqual(try ModularSubImage.read(from: &reader, width: 1, height: 1, bitsPerSample: 32, channelCount: 1), [[expected]])
        }
    }

    func test_jpegContainer_rejectsInvalidScanIndicesAndHuffmanTableIDs() throws {
        let image = JPEGCoefficientImage(width: 8, height: 8, precision: 8, frameKind: .baselineDCT,
            frameComponents: [.init(componentId: 1, hSamplingFactor: 1, vSamplingFactor: 1, quantTableId: 0)],
            quantisedComponents: [.init(componentId: 1, blocksWide: 1, blocksHigh: 1, blocks: [.init()])],
            quantTables: [.init(tableId: 0, precision: .bits8, zigZagValues: Array(repeating: 1, count: 64))])
        func write(componentIndex: Int = 0, dcID: Int = 0, acID: Int = 0) throws -> Data {
            let bits: [UInt8] = [1] + Array(repeating: 0, count: 15)
            return try JPEGContainerWriter.write(image: image,
                dcHuffmanTables: [.init(class: .dc, tableId: dcID, bits: bits, huffvals: [0])],
                acHuffmanTables: [.init(class: .ac, tableId: acID, bits: bits, huffvals: [0])],
                scanComponents: [.init(componentIndex: componentIndex, dcTableId: dcID, acTableId: acID)])
        }
        for index in [-1, 1] {
            XCTAssertThrowsError(try write(componentIndex: index)) { error in
                guard case JPEGScanEncodeError.shapeMismatch = error else { return XCTFail("\(error)") }
            }
        }
        for id in [-1, 4, 256] {
            for dc in [true, false] {
                XCTAssertThrowsError(try write(dcID: dc ? id : 0, acID: dc ? 0 : id)) { error in
                    XCTAssertEqual(error as? JPEGScanEncodeError, .invalidTableId(id))
                }
            }
        }
        for id in [0, 3] {
            XCTAssertNoThrow(try JPEGDecoder.decode(try write(dcID: id, acID: id)))
        }
    }

    func test_rawQuantTables_rejectNonpositiveSamplesBeforeUse() throws {
        for value: Int32 in [0, -1, 1, 255] {
            var samples = [Int32](repeating: 1, count: 3 * 64)
            samples[64] = value
            var writer = BitWriter()
            try QuantEncodingBitstream.writeRAWEncoding(
                payload: .init(qtable: samples, qtableDen: 1, dcQuantization: [1, 1, 1]),
                size: (8, 8), to: &writer)
            var reader = BitReader(writer.finishToData())
            if value > 0 {
                let decoded = try QuantEncoding.read(from: &reader, requiredSizeX: 8, requiredSizeY: 8)
                XCTAssertEqual(decoded.rawQtable, samples)
                XCTAssertEqual(try QuantWeights.getRAWQuantWeights(qtable: samples, qtableDen: 1),
                               samples.map { 1 / Float($0) })
            } else {
                XCTAssertThrowsError(try QuantEncoding.read(from: &reader, requiredSizeX: 8, requiredSizeY: 8))
                XCTAssertThrowsError(try QuantWeights.getRAWQuantWeights(qtable: samples, qtableDen: 1))
            }
        }
    }

    func test_grayscaleBridge_preservesSyntheticDCChannels() throws {
        let image = JPEGCoefficientImage(width: 8, height: 8, precision: 8, frameKind: .baselineDCT,
            frameComponents: [.init(componentId: 1, hSamplingFactor: 1, vSamplingFactor: 1, quantTableId: 0)],
            quantisedComponents: [.init(componentId: 1, blocksWide: 1, blocksHigh: 1, blocks: [.init()])],
            quantTables: [.init(tableId: 0, precision: .bits8, zigZagValues: Array(repeating: 4, count: 64))])
        let none = try JXLBridgeEncoder.prepareFromJPEG(image, colorTransform: .none)
        XCTAssertEqual(none.planes.dcPerChannel, [[0], [256], [0]])
        let ycbcr = try JXLBridgeEncoder.prepareFromJPEG(image, colorTransform: .ycbcr)
        XCTAssertEqual(ycbcr.planes.dcPerChannel, [[0], [0], [0]])
    }

    func test_acStrategies_rejectIntersectingFootprintsInBothBuilders() throws {
        func build(_ strategies: [ACStrategy], multiGroup: Bool) throws -> ACStrategyImage {
            let channel = strategies.map { Int32($0.rawValue) } + [Int32](repeating: 0, count: strategies.count)
            if multiGroup {
                return try ACStrategyImage.buildMultiGroup(fullWidth: 3, fullHeight: 2,
                    segments: [.init(offsetX: 0, offsetY: 0, width: 3, height: 2,
                        channel2: channel, count: strategies.count)])
            }
            return try ACStrategyImage.build(from: channel, count: strategies.count, numBlocksX: 3, numBlocksY: 2)
        }
        for multiGroup in [false, true] {
            // The final horizontal transform at (0,1) intersects the earlier 2x2 transform at (1,0).
            XCTAssertThrowsError(try build([.dct8x8, .dct16x16, .dct8x16], multiGroup: multiGroup)) { error in
                guard case ACStrategyImageError.overlap(blockX: 1, blockY: 1) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
            let valid = try build([.dct8x8, .dct16x16, .dct8x8], multiGroup: multiGroup)
            for y in 0..<2 {
                for x in 1..<3 {
                    let entry = valid.at(x: x, y: y)
                    XCTAssertEqual(entry.strategy, .dct16x16)
                    XCTAssertEqual(entry.firstBlockX, 1)
                    XCTAssertEqual(entry.firstBlockY, 0)
                    XCTAssertEqual(entry.isFirstBlock, x == 1 && y == 0)
                }
            }
            XCTAssertTrue(valid.at(x: 0, y: 1).isFirstBlock)
        }
    }

    func test_modularTreeOffsets_preserveInt32BoundsAndRejectOverflow() throws {
        func tree(_ offset: Int64) -> ModularTree {
            ModularTree(nodes: [ModularTreeNode(property: -1, splitVal: 0, leftChildOrLeafId: 0,
                rightChild: 0, predictor: .zero, predictorOffset: offset, multiplier: 1)])
        }
        for (offset, expected): (Int64, UInt32) in [(Int64(Int32.min), .max), (-1, 1), (0, 0),
                                                    (Int64(Int32.max), UInt32.max - 1)] {
            var encodedOffset: UInt32?
            try tree(offset).encode { context, value in
                if context == 3 { encodedOffset = value }
            }
            XCTAssertEqual(encodedOffset, expected)
        }
        for offset in [Int64.min, Int64(Int32.min) - 1, Int64(Int32.max) + 1, Int64.max] {
            XCTAssertThrowsError(try tree(offset).encode { _, _ in }) { error in
                guard case ModularTreeError.invalidPredictorOffset(let rejected) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(rejected, offset)
            }
        }
    }

    func test_jpegQuantTable_requiresExactly64Values() throws {
        func write(_ quant: JPEGQuantTable) throws -> Data {
            let image = JPEGCoefficientImage(width: 8, height: 8, precision: 8, frameKind: .baselineDCT,
                frameComponents: [JPEGFrameComponent(componentId: 1, hSamplingFactor: 1, vSamplingFactor: 1, quantTableId: 0)],
                quantisedComponents: [JPEGComponentBlocks(componentId: 1, blocksWide: 1, blocksHigh: 1,
                    blocks: [JPEGCoefficientBlock()])], quantTables: [quant])
            let bits: [UInt8] = [1] + Array(repeating: 0, count: 15)
            return try JPEGContainerWriter.write(image: image,
                dcHuffmanTables: [JPEGHuffmanTable(class: .dc, tableId: 0, bits: bits, huffvals: [0])],
                acHuffmanTables: [JPEGHuffmanTable(class: .ac, tableId: 0, bits: bits, huffvals: [0])],
                scanComponents: [JPEGScanComponentEncode(componentIndex: 0, dcTableId: 0, acTableId: 0)])
        }
        for precision: JPEGQuantPrecision in [.bits8, .bits16] {
            for count in [0, 63, 64, 65] {
                let quant = JPEGQuantTable(tableId: 0, precision: precision,
                    zigZagValues: (0..<count).map { UInt16($0 + (precision == .bits8 ? 1 : 257)) })
                if count == 64 {
                    var reader = JPEGSegmentReader(try write(quant))
                    var parsed: [JPEGQuantTable] = []
                    while let segment = try reader.next() {
                        if case .defineQuantizationTable = segment.kind {
                            parsed = try JPEGQuantTable.parse(dqtPayload: segment.payload)
                            break
                        }
                    }
                    XCTAssertEqual(parsed, [quant])
                } else {
                    XCTAssertThrowsError(try write(quant)) { error in
                        XCTAssertEqual(error as? JPEGContainerWriteError, .invalidQuantTableSize(count))
                    }
                }
            }
        }
    }

    func test_quantWeightInterpolation_handlesZeroRangeAndNegativePositions() {
        XCTAssertEqual(QuantWeights.interpolate(pos: 0, max: 0, array: [4, 16]), 4)
        XCTAssertEqual(QuantWeights.interpolate(pos: -1, max: 1, array: [4, 16]), 1, accuracy: 0.000001)
        for (position, expected): (Float, Float) in [(0, 4), (1, 16), (2, 64)] {
            XCTAssertEqual(QuantWeights.interpolate(pos: position, max: 2, array: [4, 16, 64]), expected)
        }
    }

    func test_iccMarkerCount_preservesTheLargestSequenceNumber() throws {
        var box = JBRDBox(appData: Array(repeating: Data(count: 17), count: 255),
            appMarkerType: Array(repeating: .icc, count: 255))
        try box.distributeBrotliPayload(Data())
        for (index, marker) in box.appData.enumerated() {
            XCTAssertEqual(marker[15], UInt8(index + 1))
            XCTAssertEqual(marker[16], 255)
        }
    }

    func test_iccMarkerCount_rejectsAnUnrepresentableSequenceNumber() {
        var box = JBRDBox(appData: Array(repeating: Data(count: 17), count: 256),
            appMarkerType: Array(repeating: .icc, count: 256))
        XCTAssertThrowsError(try box.distributeBrotliPayload(Data())) { error in
            guard case JBRDError.notImplemented(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("ICC marker count"))
        }
    }

    func test_floatMetrics_useTheNormalizedSamplePeak() {
        let reference = ImageFrame(width: 1, height: 1, channels: 1, pixelType: .float32, colorSpace: .grayscale)
        var test = reference
        test.setPixel(x: 0, y: 0, channel: 0, value: 32768)
        let metrics = ImageMetrics.compute(reference: reference, test: test)
        XCTAssertEqual(metrics.overallPSNR, 20 * log10(65535.0 / 32768.0), accuracy: 0.001)
    }

    func test_quantization_saturatesNonfiniteAndOutOfRangeValues() {
        XCTAssertEqual(Dequantize.quantize(amplitudes: [.nan, .infinity, -.infinity, 1e30, -1e30, 2.6],
            weights: [Float](repeating: 1, count: 6), scale: 1), [0, .max, .min, .max, .min, 3])
    }

    func test_ansTokenOutsideTheHistogram_throwsBeforeIndexing() throws {
        let header = EntropySectionHeader(lz77: .disabled, contextMap: .trivial(numContexts: 1),
            usePrefixCode: false, logAlphaSize: 8, uintConfigs: [.raw4])
        let codebook = MultiClusterCodebook(huffmanTables: [], ansCounts: [[4096]], alphabetSizes: [1])
        var tokens = try ANSTokenStreamWriter(header: header, codebook: codebook)
        try tokens.writeToken(context: 0, value: 1000)
        var writer = BitWriter()
        XCTAssertThrowsError(try tokens.finish(to: &writer)) { error in
            guard case ANSTokenStreamWriterError.symbolHasZeroFrequency = error else { return XCTFail("\(error)") }
        }
    }

    func test_modularTreeValidation_boundsPropertyRangeScratchSpace() {
        let root = ModularTreeNode(property: .max, splitVal: 0, leftChildOrLeafId: 1, rightChild: 2,
            predictor: .zero, predictorOffset: 0, multiplier: 1)
        let leaf = ModularTreeNode(property: -1, splitVal: 0, leftChildOrLeafId: 0, rightChild: 0,
            predictor: .zero, predictorOffset: 0, multiplier: 1)
        XCTAssertThrowsError(try mdValidateTree(ModularTree(nodes: [root, leaf, leaf]))) { error in
            guard case MDStreamError.tree(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("64 MiB"))
        }
    }

    func test_embeddedModularSubImage_preservesSignedPredictions() throws {
        let samples: [[Int32]] = [[-7, -3, -9, -1, 300, 700, 800, -8]]
        var writer = BitWriter()
        try ModularSubImage.write(channels: samples, width: 4, height: 2, bitsPerSample: 8, to: &writer)
        var reader = BitReader(writer.finishToData())
        XCTAssertEqual(try ModularSubImage.read(from: &reader, width: 4, height: 2, bitsPerSample: 8, channelCount: 1), samples)
    }

    func test_frameIndexDecode_refusesTruncatedSections() throws {
        var frame = ImageFrame(width: 16, height: 16, channels: 1, colorSpace: .grayscale)
        frame.data = (0..<256).map { UInt8(($0 * 37) & 255) }
        let encoded = try JXLEncoder().encode(frame).data
        XCTAssertEqual(try JXLDecoder().decodeFrame(encoded, at: 0).data, try JXLDecoder().decode(encoded).data)
        XCTAssertThrowsError(try JXLDecoder().decodeFrame(encoded.dropLast(), at: 0))
    }

    func test_progressOverloads_observeCancellationBeforeCPUWork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await JXLDecoder().decode(Data(), progress: nil)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled decode must throw")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func test_fullWidthU32Distribution_roundTripsNonzeroValues() throws {
        for value: UInt32 in [1, 0x8000_0000, .max] {
            var writer = BitWriter()
            try writer.writeU32(value, distributions: (.bits(32), .bits(32), .bits(32), .bits(32)))
            var reader = BitReader(writer.finishToData())
            XCTAssertEqual(try reader.readU32((.bits(32), .bits(32), .bits(32), .bits(32))), value)
        }
    }

    func test_nondefaultColorEncoding_survivesMetadataDefaultShortcut() throws {
        let metadata = ImageMetadata(allDefault: true, orientation: 1, intrinsicSize: nil, preview: nil,
            animation: nil, bitDepth: .standard, modular16BitBufferSufficient: true, extraChannels: [],
            xybEncoded: true, colorEncoding: .grayscaleD65, intensityTarget: 255, minNits: 0,
            relativeToMaxDisplay: false, linearBelow: 0)
        var writer = BitWriter()
        try metadata.write(to: &writer)
        var reader = BitReader(writer.finishToData())
        XCTAssertEqual(try ImageMetadata.read(from: &reader).colorEncoding.colorSpace, .grayscale)
    }

    func test_extraChannelEnums_roundTripWithoutLosingBitAlignment() throws {
        for type in ExtraChannelType.allCases {
            let channel = ExtraChannelInfo(type: type, bitDepth: .standard, dimShift: 0, name: "channel")
            var writer = BitWriter()
            try channel.write(to: &writer)
            writer.write(bits: 5, value: 23)
            var reader = BitReader(writer.finishToData())
            let decoded = try ExtraChannelInfo.read(from: &reader)
            XCTAssertEqual(decoded.type, type)
            XCTAssertEqual(decoded.name, "channel")
            XCTAssertEqual(try reader.read(bits: 5), 23)
        }
    }

    func test_emptyANSStream_preservesTheRequiredFinalSignature() throws {
        var encoder = ANSStreamEncoder(distributions: [])
        var reader = BitReader(encoder.finish())
        XCTAssertEqual(try reader.read(bits: 32), ANSConstants.initialState)
    }

    func test_emptyModularTree_isRefusedBeforeReadingTokens() throws {
        let header = EntropySectionHeader(lz77: .disabled, contextMap: try ContextMap(numClusters: 1, map: [0]),
                                          usePrefixCode: true, logAlphaSize: 8, uintConfigs: [.defaultConfig])
        let codebook = MultiClusterCodebook(huffmanTables: [try PrefixCodeTable(lengths: [1])], ansCounts: [], alphabetSizes: [1])
        var stream = TokenStreamReader(header: header, codebook: codebook)
        var reader = BitReader(Data())
        var output: [Int32] = [123]
        XCTAssertThrowsError(try decodeModularChannel(width: 1, height: 1, staticChannel: 0, groupId: 0,
            tree: ModularTree(nodes: []), stream: &stream, from: &reader, out: &output))
        XCTAssertEqual(output, [123])
        XCTAssertEqual(reader.position, 0)
    }

    func test_m0ResidualCountMustMatchDeclaredGeometry() throws {
        let frame = ImageFrame(width: 2, height: 2, channels: 1, colorSpace: .grayscale)
        let encoded = try MinimalLosslessCodec.encode(frame)
        var reader = BitReader(encoded)
        try reader.skip(bits: 16)
        _ = try SizeHeader.read(from: &reader)
        let metadata = try ImageMetadata.read(from: &reader)
        try reader.alignToByte()
        XCTAssertEqual(try reader.read(bits: 16), MinimalLosslessCodec.placeholderMarker)
        let tail = encoded.dropFirst(reader.position / 8)
        var writer = BitWriter()
        writer.write(bits: 8, value: 0xFF)
        writer.write(bits: 8, value: 0x0A)
        try SizeHeader(xsize: 4, ysize: 4).write(to: &writer)
        try metadata.write(to: &writer)
        writer.alignToByte()
        writer.write(bits: 16, value: MinimalLosslessCodec.placeholderMarker)
        for byte in tail { writer.write(bits: 8, value: UInt32(byte)) }
        XCTAssertThrowsError(try MinimalLosslessCodec.decode(writer.finishToData())) { error in
            guard case MinimalLosslessError.truncated = error else { return XCTFail("\(error)") }
        }
    }

    func test_u64_highBitsPreserveTheFollowingField() throws {
        for value: UInt64 in [0, 16, 272, 273, 1 << 59, 1 << 60, UInt64.max] {
            var writer = BitWriter()
            writer.writeU64(value)
            if value >= 1 << 60 { XCTAssertEqual(writer.bitCount, 73) }
            writer.write(bits: 5, value: 23)
            var reader = BitReader(writer.finishToData())
            XCTAssertEqual(try reader.readU64(), value)
            XCTAssertEqual(try reader.read(bits: 5), 23)
        }
    }

    func test_singleSymbolPrefixCode_consumesNoBits() throws {
        let code = try PrefixCodeTable(lengths: [0, 1, 0])
        var writer = BitWriter()
        for _ in 0..<20 { try code.encode(1, to: &writer) }
        XCTAssertEqual(writer.bitCount, 0)
        writer.write(bits: 7, value: 83)
        var reader = BitReader(writer.finishToData())
        for _ in 0..<20 { XCTAssertEqual(try code.decode(from: &reader), 1) }
        XCTAssertEqual(try reader.read(bits: 7), 83)
        XCTAssertThrowsError(try code.encode(0, to: &writer))
    }

    func test_modularAveragePredictors_truncateNegativeOddSums() {
        let neighbours = Neighbourhood(w: -5, n: -2, nw: -4, ne: -7, ww: -8, nn: -3)
        for (id, expected): (UInt32, Int32) in [(3, -3), (10, -4), (11, -3), (12, -4), (13, -4)] {
            XCTAssertEqual(applyLibjxlPredictor(raw: id, neighbourhood: neighbours), expected, "predictor \(id)")
        }
        XCTAssertEqual(Predictor.avgWN.apply(to: neighbours), -3)
    }

    func test_modularProperty8_usesThePreviousGradientAndResetsEachRow() {
        var properties = [Int32](repeating: 0, count: 16)
        func fill(x: Int32, y: Int32, top: Int32, left: Int32, topLeft: Int32) {
            fillModularProperties(into: &properties, staticChannel: 0, groupId: 0,
                                  x: x, y: y, top: top, left: left, topLeft: topLeft,
                                  topRight: top, leftLeft: left, topTop: top)
        }
        fill(x: 0, y: 0, top: 4, left: 2, topLeft: 1)
        XCTAssertEqual(properties[8], 2)
        XCTAssertEqual(properties[9], 5)
        fill(x: 1, y: 0, top: 20, left: 9, topLeft: 4)
        XCTAssertEqual(properties[8], 4)
        fill(x: 0, y: 1, top: 7, left: 7, topLeft: 7)
        XCTAssertEqual(properties[8], 7)
    }

    func test_containerSlice_extractsOffsetsFromItsOwnIndexBase() throws {
        let codestream = Data([0xFF, 0x0A, 1, 2])
        let reconstruction = Data([7, 8, 9])
        let container = buildJXLContainerWithReconstruction(codestream: codestream, jbrdPayload: reconstruction)
        let slice = (Data(repeating: 0xAA, count: 11) + container).dropFirst(11)
        XCTAssertEqual(slice.startIndex, 11)
        guard case let .iso(boxes) = try parseJXLContainer(slice) else { return XCTFail("expected container") }
        XCTAssertEqual(try extractCodestream(from: boxes, in: slice), codestream)
        XCTAssertEqual(try extractJBRDBox(from: boxes, in: slice), reconstruction)
        XCTAssertEqual(try extractMetadataBox(type: "jbrd", from: boxes, in: slice), reconstruction)
    }

    func test_extendedContainerSize_refusesAddressOverflow() {
        var container = Data(jxlContainerSignature)
        container.append(contentsOf: [0, 0, 0, 1, 0x6A, 0x78, 0x6C, 0x63])
        container.append(contentsOf: [0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try parseJXLContainer(container))
    }
}
