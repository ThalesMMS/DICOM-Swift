import Foundation
import XCTest
@testable import DicomJPEGXL

final class JPEGXLTransformRegressionTests: XCTestCase {
    func test_frameHeaderCustomSize_rejectsMissingDimensions() throws {
        var missingSizeWriter = BitWriter()
        XCTAssertThrowsError(try FrameHeader(encoding: .modular, colorTransform: .none,
            customSizeOrOrigin: true, frameSize: nil).write(to: &missingSizeWriter)) { error in
            guard case FrameHeaderError.invalidValue = error else { return XCTFail("\(error)") }
        }
        var writer = BitWriter()
        try FrameHeader(encoding: .modular, colorTransform: .none, customSizeOrOrigin: true,
                        frameSize: .init(xsize: 3, ysize: 5)).write(to: &writer)
        var reader = BitReader(writer.finishToData())
        let decoded = try FrameHeader.read(from: &reader)
        XCTAssertEqual(decoded.frameSize?.xsize, 3)
        XCTAssertEqual(decoded.frameSize?.ysize, 5)
    }

    func test_jbrdWriter_rejectsInvalidMarkerCodesAndShortScanComponents() {
        var badMarker = JBRDBox(); badMarker.markerOrder = [0xBF, 0xD9]
        var badScan = JBRDBox(); badScan.scanInfo = [.init(numComponents: 2, components: [.init()])]
        for box in [badMarker, badScan] {
            var writer = BitWriter()
            XCTAssertThrowsError(try JBRDBoxWriter.write(box, to: &writer)) { error in
                guard case JBRDError.notImplemented = error else { return XCTFail("\(error)") }
            }
        }
    }

    func test_coefficientDecoder_rejectsShortSOFPayloads() throws {
        for count in 0..<5 {
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xC0, 0, UInt8(count + 2)] + Array(repeating: 0, count: count) + [0xFF, 0xD9])
            var reader = JPEGSegmentReader(jpeg)
            _ = try reader.next()
            let segment = try XCTUnwrap(try reader.next())
            XCTAssertEqual(segment.payload.startIndex, 0)
            XCTAssertThrowsError(try JPEGDecoder.decodeToCoefficients(jpeg)) { error in
                guard case JPEGDecoderError.unsupported = error else { return XCTFail("\(error)") }
            }
        }
    }

    func test_inverseSqueeze_rejectsIncompatibleSplitDimensions() {
        for (low, high) in [(0, 1), (1, 2), (3, 1)] {
            let ll = ModularChannel(width: low, height: 1, pixels: Array(repeating: 0, count: low))
            let residual = ModularChannel(width: high, height: 1, pixels: Array(repeating: 0, count: high))
            XCTAssertThrowsError(try SpecSqueeze.inverseHorizontal(ll: ll, residual: residual)) { error in
                guard case SpecSqueezeError.sizeMismatch = error else { return XCTFail("\(error)") }
            }
            XCTAssertThrowsError(try SpecSqueeze.inverseVertical(
                ll: ModularChannel(width: 1, height: low, pixels: ll.pixels),
                residual: ModularChannel(width: 1, height: high, pixels: residual.pixels))) { error in
                guard case SpecSqueezeError.sizeMismatch = error else { return XCTFail("\(error)") }
            }
        }
    }

    func test_autonomousJPEGBridge_restoresDCForNoColorTransform() throws {
        for count in [1, 3] {
            var block = JPEGCoefficientBlock(); block.coefficients[0] = 8
            let image = JPEGCoefficientImage(width: 8, height: 8, precision: 8, frameKind: .baselineDCT,
                frameComponents: (1...count).map { .init(componentId: $0, hSamplingFactor: 1, vSamplingFactor: 1, quantTableId: 0) },
                quantisedComponents: (1...count).map { .init(componentId: $0, blocksWide: 1, blocksHigh: 1, blocks: [block]) },
                quantTables: [.init(tableId: 0, precision: .bits8, zigZagValues: Array(repeating: 4, count: 64))])
            let bits: [UInt8] = [1] + Array(repeating: 0, count: 15)
            let jpeg = try JPEGContainerWriter.write(image: image,
                dcHuffmanTables: [.init(class: .dc, tableId: 0, bits: bits, huffvals: [4])],
                acHuffmanTables: [.init(class: .ac, tableId: 0, bits: bits, huffvals: [0])],
                scanComponents: (0..<count).map { .init(componentIndex: $0, dcTableId: 0, acTableId: 0) })
            let prepared = try JXLBridgeEncoder.prepareFromJPEG(image, colorTransform: .none)
            let bridge = JXLJPEGBridgeData(planes: prepared.planes,
                rawQuantTable: image.buildJXLBridgeRAWQuantPayload(colorTransform: .none).qtable,
                chromaSubsampling: .default, colorTransform: .none, width: 8, height: 8)
            let reconstruction = try JPEGReconstructionReader.read(jpeg)
            XCTAssertEqual(try JXLToJPEGAdapter.reconstruct(bridgeData: bridge, jbrd: reconstruction.jbrd), jpeg)
        }
    }

    func test_quantTableRedefinitions_bindEachComponentAtItsFirstScan() throws {
        for betweenComponents in [false, true] {
            var jpeg = Data([0xFF, 0xD8])
            func marker(_ id: UInt8, _ payload: [UInt8]) {
                let length = payload.count + 2
                jpeg.append(contentsOf: [0xFF, id, UInt8(length >> 8), UInt8(length & 0xFF)] + payload)
            }
            marker(0xC2, [8, 0, 8, 0, 8, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0])
            let bits: [UInt8] = [1] + Array(repeating: 0, count: 15)
            marker(0xC4, [0] + bits + [4] + [0x10] + bits + [0])
            if !betweenComponents {
                for value: UInt8 in [2, 4] { marker(0xDB, [0] + Array(repeating: value, count: 64)) }
            }
            for component: UInt8 in 1...3 {
                if betweenComponents {
                    marker(0xDB, [0] + Array(repeating: UInt8(1 << component), count: 64))
                }
                marker(0xDA, [1, component, 0, 0, 0, 0])
                jpeg.append(0x47) // DC category 4, magnitude 8, then padding ones.
                marker(0xDA, [1, component, 0, 1, 63, 0])
                jpeg.append(0x7F) // AC EOB, then padding ones.
            }
            jpeg.append(contentsOf: [0xFF, 0xD9])
            let decoded = try JPEGDecoder.decodeToCoefficients(jpeg)
            let values: [Int32] = betweenComponents ? [2, 4, 8] : [4, 4, 4]
            XCTAssertEqual(decoded.quantTables.map { $0.zigZagValues[0] }, betweenComponents ? [2, 4, 8] : [2, 4])
            let planes = try JPEGPixelAssembler.assemble(componentBlocks: decoded.quantisedComponents,
                frameComponents: decoded.frameComponents, quantTables: decoded.quantTables)
            for (plane, value) in zip(planes, values) {
                XCTAssertEqual(plane.samples, Array(repeating: 128 + value, count: 64))
            }
            let payload = decoded.buildJXLBridgeRAWQuantPayload(colorTransform: .none)
            XCTAssertEqual(payload.qtable, values.flatMap { Array(repeating: $0, count: 64) })
            let reconstruction = try JPEGReconstructionReader.read(jpeg)
            XCTAssertEqual(reconstruction.jbrd.components.map(\.quantIdx), betweenComponents ? [0, 1, 2] : [1, 1, 1])
            XCTAssertEqual(try JPEGReconstructionWriter.write(jbrd: reconstruction.jbrd,
                coefficients: reconstruction.coefficients), jpeg)
        }
    }

    func test_progressiveACRefinement_rejectsSizesOtherThanOne() throws {
        for size: UInt8 in [1, 2, 15] {
            let table = JPEGHuffmanTable(class: .ac, tableId: 0,
                bits: [1] + Array(repeating: 0, count: 15), huffvals: [size])
            let codebook = try table.buildCodebook()
            var reader = JPEGBitReader(Data([0x7F]))
            var components = [JPEGComponentBlocks(componentId: 1, blocksWide: 1, blocksHigh: 1, blocks: [.init()])]
            let decode = {
                try JPEGScanDecoder.decodeProgressive(from: &reader,
                    scanHeader: .init(components: [.init(componentId: 1, dcTableId: 0, acTableId: 0)],
                        spectralSelectionStart: 1, spectralSelectionEnd: 1,
                        successiveApproximationHigh: 1, successiveApproximationLow: 0),
                    frameComponents: [.init(componentId: 1, hSamplingFactor: 1, vSamplingFactor: 1, quantTableId: 0)],
                    imageWidth: 8, imageHeight: 8, dcCodebooks: [:],
                    acCodebooks: [0: (codebook, table.huffvals)], restartInterval: 0, components: &components)
            }
            if size == 1 {
                try decode()
                XCTAssertEqual(components[0].blocks[0].coefficients[JPEGZigZag.order[1]], 1)
            } else {
                XCTAssertThrowsError(try decode()) { error in
                    guard case JPEGBlockDecodeError.malformedACSymbol = error else { return XCTFail("\(error)") }
                }
            }
        }
    }

    func test_progressiveScans_visitCodedBlocksWithoutMCUPadding() throws {
        let frame: [JPEGFrameComponent] = [
            .init(componentId: 1, hSamplingFactor: 2, vSamplingFactor: 2, quantTableId: 0),
            .init(componentId: 2, hSamplingFactor: 1, vSamplingFactor: 1, quantTableId: 0),
            .init(componentId: 3, hSamplingFactor: 1, vSamplingFactor: 1, quantTableId: 0)]
        let table = JPEGHuffmanTable(class: .dc, tableId: 0,
            bits: [1] + Array(repeating: 0, count: 15), huffvals: [1])
        let book = try table.buildCodebook()
        for (spectral, refinement) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
            var components = frame.map { component in
                JPEGComponentBlocks(componentId: component.componentId,
                    blocksWide: component.hSamplingFactor * 2, blocksHigh: component.vSamplingFactor * 2,
                    blocks: Array(repeating: .init(), count: component.hSamplingFactor * component.vSamplingFactor * 4))
            }
            var writer = JPEGBitWriter()
            for _ in 0..<9 {
                if spectral != 0 || refinement == 0 { writer.writeBit(0) }
                writer.writeBit(1)
            }
            writer.flushPaddingOnes()
            var reader = JPEGBitReader(writer.data)
            try JPEGScanDecoder.decodeProgressive(from: &reader,
                scanHeader: .init(components: [.init(componentId: 1, dcTableId: 0, acTableId: 0)],
                    spectralSelectionStart: spectral, spectralSelectionEnd: spectral,
                    successiveApproximationHigh: refinement, successiveApproximationLow: 0),
                frameComponents: frame, imageWidth: 17, imageHeight: 17,
                dcCodebooks: [0: (book, table.huffvals)], acCodebooks: [0: (book, table.huffvals)],
                restartInterval: 0, components: &components)
            for y in 0..<4 {
                for x in 0..<4 {
                    let coded = x < 3 && y < 3
                    let expected: Int32 = coded ? (spectral == 0 && refinement == 0 ? Int32(y * 3 + x + 1) : 1) : 0
                    XCTAssertEqual(components[0].blocks[y * 4 + x].coefficients[JPEGZigZag.order[spectral]], expected,
                                   "scan \(spectral)/\(refinement), block \(x),\(y)")
                }
            }
        }
    }

    func test_inverseSqueeze_preservesMetaMarkersBeforePaletteExpansion() throws {
        let vertical = try SpecSqueeze.inverseVertical(
            ll: ModularChannel(width: 1, height: 1, hshift: -1, vshift: -1, pixels: [15]),
            residual: ModularChannel(width: 1, height: 1, hshift: -1, vshift: -1, pixels: [-10]))
        XCTAssertEqual(vertical.hshift, -1)
        XCTAssertEqual(vertical.vshift, -1)
        XCTAssertEqual(vertical.pixels, [10, 20])

        let palette = ModularTransform(id: .palette, numC: 1, nbColors: 2)
        let squeeze = ModularTransform(id: .squeeze,
            squeezes: [.init(horizontal: true, inPlace: true, beginC: 0, numC: 1)])
        var image = ModularImage(channels: [.init(width: 2, height: 1)], nbMetaChannels: 0)
        try metaApplyTransforms(image: &image, transforms: [palette, squeeze])
        image.channels[0].pixels = [15]
        image.channels[1].pixels = [-10]
        image.channels[2].pixels = [0, 1]
        try applyInverseTransforms(image: &image, transforms: [squeeze])
        XCTAssertEqual(image.channels[0].hshift, -1)
        XCTAssertEqual(image.channels[0].vshift, -1)
        XCTAssertEqual(image.channels[0].pixels, [10, 20])
        try applyInverseTransforms(image: &image, transforms: [palette])
        XCTAssertEqual(image.nbMetaChannels, 0)
        XCTAssertEqual(image.channels.count, 1)
        XCTAssertEqual(image.channels[0].pixels, [10, 20])
    }

    func test_jpegReconstruction_refusesAnEmptyScanComponentList() {
        let box = JBRDBox(components: [.init()], scanInfo: [.init(numComponents: 0)], markerOrder: [0xDA, 0xD9])
        XCTAssertThrowsError(try JPEGReconstructionWriter.write(jbrd: box, coefficients: [[]])) { error in
            guard case JPEGReconstructionError.malformed(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(reason, "scan component list mismatch")
        }
    }

    func test_jpegProgressiveEncoding_refusesMissingEOBAndZRLSymbols() {
        let table = JPEGHuffmanEncodeTable.build(counts: [0, 1] + [UInt32](repeating: 0, count: 15), values: [1])
        for (ah, nonzero, expected): (Int, Int?, UInt8) in [(0, nil, 0), (1, nil, 0), (0, 20, 0xF0), (1, 20, 0xF0)] {
            var coefficients = [Int32](repeating: 0, count: 64)
            if let nonzero { coefficients[JPEGZigZag.order[nonzero]] = 1 }
            let component = JPEGComponentBlocks(componentId: 1, blocksWide: 1, blocksHigh: 1,
                blocks: [JPEGCoefficientBlock(coefficients)])
            XCTAssertThrowsError(try JPEGScanEncoder.encodeProgressive(ss: 1, se: 63, ah: ah, al: 0,
                components: [component],
                frameComponents: [.init(componentId: 1, hSamplingFactor: 1, vSamplingFactor: 1, quantTableId: 0)],
                scanComponents: [.init(componentIndex: 0, dcTableId: 0, acTableId: 0)],
                dcTables: [], acTables: [table], restartInterval: 0, imageWidth: 8, imageHeight: 8)) { error in
                guard case JPEGScanEncodeError.blockEncodeFailed(.missingHuffmanSymbol(let symbol), _, _) = error else {
                    return XCTFail("\(error)")
                }
                XCTAssertEqual(symbol, expected)
            }
        }
    }

    func test_losslessJPEG_restoresEachScansPointTransform() throws {
        func segment(_ marker: UInt8, _ payload: [UInt8]) -> Data {
            Data([0xFF, marker, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 255)] + payload)
        }
        for precision: UInt8 in [8, 12] {
            var jpeg = Data([0xFF, 0xD8])
            jpeg.append(segment(0xC4, [0, 1] + [UInt8](repeating: 0, count: 15) + [0]))
            jpeg.append(segment(0xC3, [precision, 0, 1, 0, 1, 3, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0]))
            for component: UInt8 in 1...3 {
                jpeg.append(segment(0xDA, [1, component, 0, 1, 0, component - 1]))
                jpeg.append(0x7F) // Difference zero, followed by JPEG's one-bit padding.
            }
            jpeg.append(contentsOf: [0xFF, 0xD9])
            let frame = try JPEGLosslessDecoder.decode(jpeg)
            for channel in 0..<3 {
                XCTAssertEqual(frame.getPixel(x: 0, y: 0, channel: channel), UInt16(1 << (precision - 1)))
            }
        }
    }

    func test_jbrdWriter_refusesEmptyMarkerPayloads() {
        for box in [JBRDBox(appData: [Data()], appMarkerType: [.unknown]), JBRDBox(comData: [Data()])] {
            var writer = BitWriter()
            XCTAssertThrowsError(try JBRDBoxWriter.write(box, to: &writer))
            XCTAssertEqual(writer.bitCount, 0)
        }
    }

    func test_jpegQuantTables_refuseWrongLengthAndUnrepresentableValues() {
        let coefficients = JXLCoefficientPlanes(blocksX: 1, blocksY: 1, channelCount: 1,
            dcPerChannel: [[0]], acPerChannel: [[[Int32](repeating: 0, count: 64)]])
        for values in [[], [Int32](repeating: 0, count: 64), [Int32](repeating: 1, count: 63), [Int32](repeating: -1, count: 64),
                       [Int32](repeating: 65536, count: 64)] {
            let box = JBRDBox(quant: [.init(values: values)], components: [.init()], markerOrder: [0xD9])
            XCTAssertThrowsError(try JXLToJPEGAdapter.reconstruct(coefficients: coefficients, jbrd: box, colorTransform: .none)) { error in
                guard case JXLToJPEGAdapterError.malformedJBRD = error else { return XCTFail("\(error)") }
            }
        }
    }

    func test_jpegDCRefinement_flushesBeforeRestartMarkers() throws {
        let component = JPEGComponentBlocks(componentId: 1, blocksWide: 2, blocksHigh: 1,
                                            blocks: [JPEGCoefficientBlock(), JPEGCoefficientBlock()])
        let bytes = try JPEGScanEncoder.encodeProgressive(
            ss: 0, se: 0, ah: 1, al: 0, components: [component],
            frameComponents: [.init(componentId: 1, hSamplingFactor: 1, vSamplingFactor: 1, quantTableId: 0)],
            scanComponents: [.init(componentIndex: 0, dcTableId: 0, acTableId: 0)],
            dcTables: [], acTables: [], restartInterval: 1, imageWidth: 16, imageHeight: 8)
        XCTAssertEqual(bytes, Data([0x7F, 0xFF, 0xD0, 0x7F]))
    }

    func test_squeezeCoveringEveryMetaChannel_restoresTheOriginalCount() throws {
        let transform = ModularTransform(id: .squeeze, squeezes: [.init(horizontal: true, inPlace: true, beginC: 0, numC: 1)])
        var image = ModularImage(channels: [.init(width: 2, height: 1)], nbMetaChannels: 1)
        let transforms = try mdMetaApply([transform], image: &image)
        XCTAssertEqual(image.nbMetaChannels, 2)
        try mdUndoTransforms(transforms, image: &image, wpHeader: .default, bitDepth: 8)
        XCTAssertEqual(image.nbMetaChannels, 1)
        XCTAssertEqual(image.channels.count, 1)
        XCTAssertEqual(image.channels[0].width, 2)
    }

    func test_inverseGaborish_mirrorsTinyImageBorders() {
        for (width, height) in [(1, 1), (1, 2), (2, 1), (2, 2)] {
            var pixels = [Float](repeating: 17, count: width * height)
            Gaborish.applyInverse5x5(to: &pixels, width: width, height: height)
            for value in pixels { XCTAssertEqual(value, 17, accuracy: 0.00001) }
        }
    }

    func test_inverseJPEGDCT_clampsBeforeNarrowingLargeCoefficients() {
        for coefficient in [Int32.min, Int32.max] {
            let block = JPEGCoefficientBlock([Int32](repeating: coefficient, count: 64))
            for precision in [8, 12] {
                let pixels = JPEGIDCT.inverseTransform(block, precision: precision)
                XCTAssertEqual(pixels.count, 64)
                XCTAssertTrue(pixels.allSatisfy { (0..<(1 << precision)).contains($0) })
            }
        }
    }

    func test_jpegSampling_refusesNonintegralRatios() {
        let plane = JPEGSamplePlane(componentId: 1, width: 3, height: 2, samples: [Int32](repeating: 0, count: 6))
        XCTAssertThrowsError(try JPEGPixelAssembler.upsampleNearest(plane, toWidth: 4, height: 4)) { error in
            XCTAssertEqual(error as? JPEGAssembleError, .unsupportedSamplingRatio)
        }
    }

    func test_jbrd_refusesShortExifAndXMPMarkers() {
        for kind: JBRDAppMarkerType in [.exif, .xmp] {
            for count in 0...2 {
                var box = JBRDBox(appData: [Data(count: count)], appMarkerType: [kind])
                XCTAssertThrowsError(try box.distributeBrotliPayload(Data()))
            }
        }
    }

    func test_lehmerConversion_handlesLargeIdentityAndReverseOrders() {
        XCTAssertEqual(lehmerCodeToPermutation([2, 0, 1, 0]), [2, 0, 3, 1])
        let count = 65_536
        XCTAssertEqual(lehmerCodeToPermutation([UInt32](repeating: 0, count: count)), Array(0..<count))
        XCTAssertEqual(lehmerCodeToPermutation((0..<count).reversed().map(UInt32.init)), Array((0..<count).reversed()))
    }

    func test_rct_allVariantsMatchTheScalarInverse() throws {
        let original: [[Int32]] = [[0, 7, -9, .max], [20, -15, 1, .min], [-5, 8, -2, 123]]
        for type: UInt32 in 0..<42 {
            let permutation = Int(type / 7)
            let custom = Int(type % 7)
            var expected = original
            for i in original[0].indices {
                var a = original[0][i], b = original[1][i], c = original[2][i]
                if custom == 6 {
                    let tmp = a &- (c >> 1)
                    let blue = tmp &- (b >> 1)
                    a = blue &+ b; b = c &+ tmp; c = blue
                } else {
                    if custom & 1 != 0 { c = c &+ a }
                    if custom >> 1 == 1 { b = b &+ a }
                    if custom >> 1 == 2 { b = b &+ ((a &+ c) >> 1) }
                }
                expected[permutation % 3][i] = a
                expected[(permutation + 1 + permutation / 3) % 3][i] = b
                expected[(permutation + 2 - permutation / 3) % 3][i] = c
            }
            var a = original[0], b = original[1], c = original[2]
            try SpecRCT.inverse(rctType: type, channel0: &a, channel1: &b, channel2: &c)
            XCTAssertEqual([a, b, c], expected, "RCT \(type)")
        }
    }
}
