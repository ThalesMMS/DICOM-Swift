import XCTest
@testable import DicomCore

final class DicomColorPixelDataTests: XCTestCase {
    func test_decodedPaletteIndices_ignoreSourceByteOrder() throws {
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "PALETTE COLOR", samplesPerPixel: 1, width: 3, height: 1,
            bitsAllocated: 16, pixelBytes: [0, 0, 1, 0, 2, 0], paletteDescriptor: [3, 0, 16],
            redPalette: [0, 32768, 65535], greenPalette: [65535, 0, 32768], bluePalette: [0, 65535, 32768])
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)
        let metadata = try DicomDecodedFrameReader(decoder: decoder).frame(at: 0).metadata
        let frame = DicomDecodedFrame(index: 0, pixels: .gray16([0, 1, 2]), metadata: metadata)
        let expected = try decoder.displayRGBPixelBuffer().rgbData
        // Palette metadata is already parsed. A big-endian source still produces little-endian decoded samples.
        decoder.littleEndian = false
        XCTAssertEqual(try decoder.displayRGB8(decodedFrame: frame), expected)
    }

    func test_segmentedPaletteColor2x2_rendersExactRGBBytes() throws {
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)
        appendUS(&data, group: 0x0028, element: 0x0002, value: 1)
        appendCS(&data, group: 0x0028, element: 0x0004, value: "PALETTE COLOR")
        appendUS(&data, group: 0x0028, element: 0x0010, value: 2)
        appendUS(&data, group: 0x0028, element: 0x0011, value: 2)
        appendUS(&data, group: 0x0028, element: 0x0100, value: 8)
        appendUS(&data, group: 0x0028, element: 0x0101, value: 8)
        appendUS(&data, group: 0x0028, element: 0x0102, value: 7)
        appendUS(&data, group: 0x0028, element: 0x0103, value: 0)
        for tag: UInt16 in [0x1101, 0x1102, 0x1103] {
            appendUSValues(&data, group: 0x0028, element: tag, values: [4, 0, 16])
        }
        appendOWValues(&data, group: 0x0028, element: 0x1221, values: [0, 1, 0, 1, 3, 65535])
        appendOWValues(&data, group: 0x0028, element: 0x1222, values: [0, 1, 65535, 1, 3, 0])
        appendOWValues(&data, group: 0x0028, element: 0x1223, values: [0, 2, 0, 65535, 2, 1, 0, 0])
        appendBinary(&data, group: 0x7FE0, element: 0x0010, vr: "OB", bytes: [0, 1, 2, 3])
        let buffer = try DCMDecoder(data: data).displayRGBPixelBuffer()
        XCTAssertEqual(buffer.width, 2)
        XCTAssertEqual(buffer.height, 2)
        XCTAssertEqual(buffer.rgbData, Data([0, 255, 0, 85, 170, 255, 170, 85, 0, 255, 0, 255]))
    }

    func testDisplayConversionMatrixDocumentsSupportedAndUnsupportedPhotometricRows() throws {
        let rows = Dictionary(
            uniqueKeysWithValues: DicomColorDisplayConversionMatrix.standard.map {
                ($0.photometricInterpretation, $0)
            }
        )

        XCTAssertEqual(Set(rows.keys), Set([
            .monochrome1,
            .monochrome2,
            .rgb,
            .paletteColor,
            .ybrFull,
            .ybrFull422,
            .ybrPartial420,
            .ybrRCT,
            .ybrICT
        ]))

        let monochrome1 = try XCTUnwrap(rows[.monochrome1])
        XCTAssertEqual(monochrome1.status, .displayRGB)
        XCTAssertEqual(monochrome1.supportedSamplesPerPixel, [1])
        XCTAssertEqual(monochrome1.supportedBitsAllocated, [8, 16])
        XCTAssertTrue(monochrome1.supports(planarConfiguration: nil))

        let rgb = try XCTUnwrap(rows[.rgb])
        XCTAssertEqual(rgb.status, .displayRGB)
        XCTAssertEqual(rgb.supportedSamplesPerPixel, [3])
        XCTAssertEqual(rgb.supportedBitsAllocated, [8, 16])
        XCTAssertTrue(rgb.supports(planarConfiguration: nil))
        XCTAssertTrue(rgb.supports(planarConfiguration: 0))
        XCTAssertTrue(rgb.supports(planarConfiguration: 1))
        XCTAssertTrue(rgb.preservesICCProfile)

        let paletteColor = try XCTUnwrap(rows[.paletteColor])
        XCTAssertEqual(paletteColor.status, .displayRGB)
        XCTAssertTrue(paletteColor.requiresPaletteColorLookupTable)
        XCTAssertEqual(paletteColor.supportedSamplesPerPixel, [1])

        let ybrFull422 = try XCTUnwrap(rows[.ybrFull422])
        XCTAssertTrue(ybrFull422.supports(planarConfiguration: nil))
        XCTAssertTrue(ybrFull422.supports(planarConfiguration: 0))
        XCTAssertFalse(ybrFull422.supports(planarConfiguration: 1))

        XCTAssertEqual(rows[.ybrPartial420]?.status, .unsupported)
        XCTAssertEqual(rows[.ybrRCT]?.status, .unsupported)
        XCTAssertEqual(rows[.ybrICT]?.status, .unsupported)
    }

    func testMonochromeDisplayConversionsProduceExpectedRGB() throws {
        let monochrome2URL = try makeTemporaryDICOM(
            photometricInterpretation: "MONOCHROME2",
            samplesPerPixel: 1,
            width: 2,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: [0, 255]
        )
        defer { try? FileManager.default.removeItem(at: monochrome2URL) }

        let monochrome1URL = try makeTemporaryDICOM(
            photometricInterpretation: "MONOCHROME1",
            samplesPerPixel: 1,
            width: 2,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: [0, 255]
        )
        defer { try? FileManager.default.removeItem(at: monochrome1URL) }

        let monochrome2 = try DCMDecoder(contentsOf: monochrome2URL).displayRGBPixelBuffer()
        let monochrome1 = try DCMDecoder(contentsOf: monochrome1URL).displayRGBPixelBuffer()

        XCTAssertEqual(monochrome2.rgbData, Data([
            0, 0, 0,
            255, 255, 255
        ]))
        XCTAssertEqual(monochrome1.rgbData, Data([
            255, 255, 255,
            0, 0, 0
        ]))
    }

    func testRGBInterleavedAndICCProfileExposeDisplayBufferAndMetadata() throws {
        let iccProfile = Data([0x01, 0x02, 0x03, 0x04])
        let pixelBytes: [UInt8] = [255, 0, 0, 0, 128, 255]
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "RGB",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 2,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: pixelBytes,
            iccProfile: iccProfile
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let metadata = decoder.nativeColorMetadata

        XCTAssertEqual(metadata.photometricInterpretation, .rgb)
        XCTAssertEqual(metadata.samplesPerPixel, 3)
        XCTAssertEqual(metadata.planarConfiguration, 0)
        XCTAssertEqual(metadata.iccProfile, iccProfile)

        let display = try decoder.displayRGBPixelBuffer()
        XCTAssertEqual(display.width, 2)
        XCTAssertEqual(display.height, 1)
        XCTAssertEqual(display.bytesPerPixel, 3)
        XCTAssertEqual(display.rgbData, Data(pixelBytes))
        XCTAssertEqual(display.iccProfile, iccProfile)
    }

    func testRGBPlanarConvertsToInterleavedDisplayBuffer() throws {
        let pixelBytes: [UInt8] = [10, 40, 20, 50, 30, 60]
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "RGB",
            samplesPerPixel: 3,
            planarConfiguration: 1,
            width: 2,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let display = try decoder.displayRGBPixelBuffer()

        XCTAssertEqual(display.rgbData, Data([10, 20, 30, 40, 50, 60]))
    }

    func testPaletteColorConvertsToRGBUsingLookupTables() throws {
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "PALETTE COLOR",
            samplesPerPixel: 1,
            width: 3,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: [0, 1, 2],
            paletteDescriptor: [3, 0, 16],
            redPalette: [0x0000, 0x8000, 0xFFFF],
            greenPalette: [0xFFFF, 0x0000, 0x8000],
            bluePalette: [0x0000, 0xFFFF, 0x8000]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let metadata = decoder.nativeColorMetadata
        let palette = try XCTUnwrap(metadata.paletteColorLookupTable)

        XCTAssertEqual(metadata.photometricInterpretation, .paletteColor)
        XCTAssertEqual(palette.redDescriptor.entryCount, 3)
        XCTAssertEqual(palette.redDescriptor.firstMappedValue, 0)
        XCTAssertEqual(palette.redDescriptor.bitsPerEntry, 16)
        XCTAssertEqual(palette.red, [0, 128, 255])
        XCTAssertEqual(palette.green, [255, 0, 128])
        XCTAssertEqual(palette.blue, [0, 255, 128])

        let display = try decoder.displayRGBPixelBuffer()
        XCTAssertEqual(display.rgbData, Data([
            0, 255, 0,
            128, 0, 255,
            255, 128, 128
        ]))
    }

    func testYBRFullConvertsToRGB() throws {
        let pixelBytes: [UInt8] = [
            128, 128, 128,
            76, 85, 255
        ]
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "YBR_FULL",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 2,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let display = try decoder.displayRGBPixelBuffer()

        XCTAssertEqual(display.rgbData, Data([
            128, 128, 128,
            254, 0, 0
        ]))
    }

    func testYBRFull422UsesSubsampledFrameLayoutAndConvertsToRGB() throws {
        let pixelBytes: [UInt8] = [10, 20, 128, 128]
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "YBR_FULL_422",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 2,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let descriptor = try XCTUnwrap(decoder.pixelDataDescriptor)
        let display = try decoder.displayRGBPixelBuffer()

        XCTAssertEqual(descriptor.bytesPerFrame, 4)
        XCTAssertEqual(descriptor.totalPixelBytes, 4)
        XCTAssertEqual(display.rgbData, Data([
            10, 10, 10,
            20, 20, 20
        ]))
    }

    func testUnsupportedColorCombinationThrowsDocumentedError() throws {
        // 16-bit RGB is supported since #1232; 16-bit YBR_FULL stays the
        // documented unsupported depth combination.
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "YBR_FULL",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 1,
            height: 1,
            bitsAllocated: 16,
            pixelBytes: [0, 0, 0, 0, 0, 0]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertThrowsError(try decoder.displayRGBPixelBuffer()) { error in
            assertUnsupportedColorPath(
                error,
                photometricInterpretation: "YBR_FULL",
                samplesPerPixel: 3,
                planarConfiguration: 0,
                bitsAllocated: 16,
                reasonContains: "only 8-bit"
            )
        }
    }

    func testUnsupportedYBRPartial420ReportsStableDisplayContext() throws {
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "YBR_PARTIAL_420",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 2,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: [0, 0, 0, 0, 0, 0]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertThrowsError(try decoder.displayRGBPixelBuffer()) { error in
            assertUnsupportedColorPath(
                error,
                photometricInterpretation: "YBR_PARTIAL_420",
                samplesPerPixel: 3,
                planarConfiguration: 0,
                bitsAllocated: 8,
                reasonContains: "not implemented"
            )
        }
    }

    func testRGBAlphaSamplesReportStableDisplayContext() throws {
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "RGB",
            samplesPerPixel: 4,
            planarConfiguration: 0,
            width: 1,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: [10, 20, 30, 255]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertThrowsError(try decoder.displayRGBPixelBuffer()) { error in
            assertUnsupportedColorPath(
                error,
                photometricInterpretation: "RGB",
                samplesPerPixel: 4,
                planarConfiguration: 0,
                bitsAllocated: 8,
                reasonContains: "alpha and extra samples"
            )
        }
    }

    func testYBRFull422PlanarConfigurationReportsStableDisplayContext() throws {
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "YBR_FULL_422",
            samplesPerPixel: 3,
            planarConfiguration: 1,
            width: 2,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: [10, 20, 128, 128]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)

        XCTAssertThrowsError(try decoder.displayRGBPixelBuffer()) { error in
            assertUnsupportedColorPath(
                error,
                photometricInterpretation: "YBR_FULL_422",
                samplesPerPixel: 3,
                planarConfiguration: 1,
                bitsAllocated: 8,
                reasonContains: "Planar Configuration"
            )
        }
    }

    // MARK: - High-bit-depth color and YBR fixture coverage (issue #1232)

    func testHighBitDepthRGBInterleavedScalesToDisplayByBitsStored() throws {
        var pixelBytes = [UInt8]()
        for value in [UInt16(0), 32768, 65535] {
            pixelBytes.append(UInt8(value & 0xFF))
            pixelBytes.append(UInt8(value >> 8))
        }
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "RGB",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 1,
            height: 1,
            bitsAllocated: 16,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let display = try DCMDecoder(contentsOf: url).displayRGBPixelBuffer()
        XCTAssertEqual(display.rgbData, Data([0, 128, 255]))
    }

    func testHighBitDepthRGBTwelveBitsStoredScalesByStoredRange() throws {
        var pixelBytes = [UInt8]()
        for value in [UInt16(0), 2048, 4095] {
            pixelBytes.append(UInt8(value & 0xFF))
            pixelBytes.append(UInt8(value >> 8))
        }
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "RGB",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 1,
            height: 1,
            bitsAllocated: 16,
            bitsStored: 12,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let display = try DCMDecoder(contentsOf: url).displayRGBPixelBuffer()
        XCTAssertEqual(display.rgbData, Data([0, 128, 255]),
                       "12-bit stored samples must scale by the 4095 stored maximum, not by 65535")
    }

    func testHighBitDepthRGBPlanarPreservesPlanarSemantics() throws {
        // Planes: R=[1000, 2000], G=[3000, 4000], B=[5000, 6000].
        var pixelBytes = [UInt8]()
        for value in [UInt16(1000), 2000, 3000, 4000, 5000, 6000] {
            pixelBytes.append(UInt8(value & 0xFF))
            pixelBytes.append(UInt8(value >> 8))
        }
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "RGB",
            samplesPerPixel: 3,
            planarConfiguration: 1,
            width: 2,
            height: 1,
            bitsAllocated: 16,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let display = try DCMDecoder(contentsOf: url).displayRGBPixelBuffer()
        XCTAssertEqual(display.rgbData, Data([4, 12, 19, 8, 16, 23]))
    }

    func testDisplayRGB48PreservesStoredPrecision() throws {
        let stored: [UInt16] = [1234, 40000, 65535]
        var pixelBytes = [UInt8]()
        for value in stored {
            pixelBytes.append(UInt8(value & 0xFF))
            pixelBytes.append(UInt8(value >> 8))
        }
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "RGB",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 1,
            height: 1,
            bitsAllocated: 16,
            pixelBytes: pixelBytes
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let buffer = try DCMDecoder(contentsOf: url).displayRGB48PixelBuffer()
        XCTAssertEqual(buffer.bitsStored, 16)
        XCTAssertEqual(buffer.bytesPerPixel, 6)
        XCTAssertEqual(buffer.rgb48Data, Data(pixelBytes), "stored 16-bit samples must pass through unscaled")
    }

    func testDisplayRGB48WidensEightBitSamplesToTheFullRange() throws {
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "RGB",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 1,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: [10, 128, 255]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let buffer = try DCMDecoder(contentsOf: url).displayRGB48PixelBuffer()
        XCTAssertEqual(buffer.bitsStored, 16)
        var expected = Data()
        for value in [UInt16(2570), 32896, 65535] { // v * 257
            expected.append(UInt8(value & 0xFF))
            expected.append(UInt8(value >> 8))
        }
        XCTAssertEqual(buffer.rgb48Data, expected)
    }

    func testDisplayRGB48RejectsNonRGBPhotometricInterpretations() throws {
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "YBR_FULL",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 1,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: [128, 128, 128]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DCMDecoder(contentsOf: url).displayRGB48PixelBuffer()) { error in
            guard case DicomColorConversionError.unsupportedColorPath(_, let reason) = error else {
                return XCTFail("expected unsupportedColorPath, got \(error)")
            }
            XCTAssertTrue(reason.contains("RGB48"), reason)
        }
    }

    func testPaletteDescriptorFirstMappedValueOffsetAndClamping() throws {
        // Descriptor [3, 100, 16]: three entries mapped from stored value 100.
        let url = try makeTemporaryDICOM(
            photometricInterpretation: "PALETTE COLOR",
            samplesPerPixel: 1,
            width: 4,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: [50, 100, 102, 200],
            paletteDescriptor: [3, 100, 16],
            redPalette: [0x1000, 0x8000, 0xF000],
            greenPalette: [0x2000, 0x9000, 0xE000],
            bluePalette: [0x3000, 0xA000, 0xD000]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let display = try DCMDecoder(contentsOf: url).displayRGBPixelBuffer()
        XCTAssertEqual(display.rgbData, Data([
            0x10, 0x20, 0x30, // 50 below the first mapped value clamps to entry 0
            0x10, 0x20, 0x30, // 100 maps to entry 0
            0xF0, 0xE0, 0xD0, // 102 maps to entry 2
            0xF0, 0xE0, 0xD0  // 200 above the range clamps to the last entry
        ]))
    }

    /// Native (uncompressed) data labeled with the JPEG 2000 color
    /// transforms must reject display conversion and point at the codec
    /// path that actually owns those photometric interpretations.
    func testNativeRCTAndICTLabelsRejectDisplayConversionTyped() throws {
        for photometric in ["YBR_RCT", "YBR_ICT"] {
            let url = try makeTemporaryDICOM(
                photometricInterpretation: photometric,
                samplesPerPixel: 3,
                planarConfiguration: 0,
                width: 1,
                height: 1,
                bitsAllocated: 8,
                pixelBytes: [1, 2, 3]
            )
            defer { try? FileManager.default.removeItem(at: url) }

            XCTAssertThrowsError(try DCMDecoder(contentsOf: url).displayRGBPixelBuffer()) { error in
                guard case DicomColorConversionError.unsupportedColorPath(let context, let reason) = error else {
                    return XCTFail("expected unsupportedColorPath for \(photometric), got \(error)")
                }
                XCTAssertEqual(context.photometricInterpretation, photometric)
                XCTAssertTrue(reason.contains("JPEG 2000"), reason)
            }
        }
    }

    /// Color images must never surface as successful grayscale buffers.
    func testColorImagesNeverDecodeAsGrayscaleBuffers() throws {
        let rgbURL = try makeTemporaryDICOM(
            photometricInterpretation: "RGB",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 2,
            height: 1,
            bitsAllocated: 8,
            pixelBytes: [1, 2, 3, 4, 5, 6]
        )
        defer { try? FileManager.default.removeItem(at: rgbURL) }
        let rgbDecoder = try DCMDecoder(contentsOf: rgbURL)
        XCTAssertNil(rgbDecoder.getPixels8(), "RGB must not surface as 8-bit grayscale")
        XCTAssertNil(rgbDecoder.getPixels16(), "RGB must not surface as 16-bit grayscale")
        XCTAssertNotNil(rgbDecoder.getPixels24())

        let partialURL = try makeTemporaryDICOM(
            photometricInterpretation: "YBR_PARTIAL_420",
            samplesPerPixel: 3,
            planarConfiguration: 0,
            width: 2,
            height: 2,
            bitsAllocated: 8,
            pixelBytes: [UInt8](repeating: 64, count: 12)
        )
        defer { try? FileManager.default.removeItem(at: partialURL) }
        let partialDecoder = try DCMDecoder(contentsOf: partialURL)
        XCTAssertNil(partialDecoder.getPixels8(), "YBR_PARTIAL_420 must not surface as grayscale")
        XCTAssertNil(partialDecoder.getPixels16(), "YBR_PARTIAL_420 must not surface as grayscale")
        XCTAssertThrowsError(try partialDecoder.displayRGBPixelBuffer()) { error in
            guard case DicomColorConversionError.unsupportedColorPath = error else {
                return XCTFail("expected unsupportedColorPath, got \(error)")
            }
        }
    }

    private func makeTemporaryDICOM(
        photometricInterpretation: String,
        samplesPerPixel: UInt16,
        planarConfiguration: UInt16? = nil,
        width: UInt16,
        height: UInt16,
        bitsAllocated: UInt16,
        bitsStored: UInt16? = nil,
        pixelBytes: [UInt8],
        paletteDescriptor: [UInt16]? = nil,
        redPalette: [UInt16]? = nil,
        greenPalette: [UInt16]? = nil,
        bluePalette: [UInt16]? = nil,
        iccProfile: Data? = nil
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("color_pixel_\(UUID().uuidString).dcm")
        var data = Data()
        data.append(Data(count: 128))
        data.append(contentsOf: "DICM".utf8)

        let storedBits = bitsStored ?? bitsAllocated
        appendUS(&data, group: 0x0028, element: 0x0010, value: height)
        appendUS(&data, group: 0x0028, element: 0x0011, value: width)
        appendUS(&data, group: 0x0028, element: 0x0002, value: samplesPerPixel)
        appendCS(&data, group: 0x0028, element: 0x0004, value: photometricInterpretation)
        if let planarConfiguration {
            appendUS(&data, group: 0x0028, element: 0x0006, value: planarConfiguration)
        }
        appendUS(&data, group: 0x0028, element: 0x0100, value: bitsAllocated)
        appendUS(&data, group: 0x0028, element: 0x0101, value: storedBits)
        appendUS(&data, group: 0x0028, element: 0x0102, value: storedBits - 1)
        appendUS(&data, group: 0x0028, element: 0x0103, value: 0)

        if let paletteDescriptor {
            appendUSValues(&data, group: 0x0028, element: 0x1101, values: paletteDescriptor)
            appendUSValues(&data, group: 0x0028, element: 0x1102, values: paletteDescriptor)
            appendUSValues(&data, group: 0x0028, element: 0x1103, values: paletteDescriptor)
        }
        if let redPalette {
            appendOWValues(&data, group: 0x0028, element: 0x1201, values: redPalette)
        }
        if let greenPalette {
            appendOWValues(&data, group: 0x0028, element: 0x1202, values: greenPalette)
        }
        if let bluePalette {
            appendOWValues(&data, group: 0x0028, element: 0x1203, values: bluePalette)
        }
        if let iccProfile {
            appendBinary(&data, group: 0x0028, element: 0x2000, vr: "OB", bytes: Array(iccProfile))
        }

        appendBinary(
            &data,
            group: 0x7FE0,
            element: 0x0010,
            vr: bitsAllocated == 8 ? "OB" : "OW",
            bytes: pixelBytes
        )

        try data.write(to: url)
        return url
    }

    private func appendUS(_ data: inout Data, group: UInt16, element: UInt16, value: UInt16) {
        appendUSValues(&data, group: group, element: element, values: [value])
    }

    private func appendUSValues(_ data: inout Data, group: UInt16, element: UInt16, values: [UInt16]) {
        data.append(contentsOf: withUnsafeBytes(of: group.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: element.littleEndian) { Array($0) })
        data.append(contentsOf: "US".utf8)
        data.append(UInt8((values.count * 2) & 0xFF))
        data.append(UInt8(((values.count * 2) >> 8) & 0xFF))
        for value in values {
            data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
        }
    }

    private func appendCS(_ data: inout Data, group: UInt16, element: UInt16, value: String) {
        var bytes = Array(value.utf8)
        if bytes.count % 2 != 0 {
            bytes.append(0x20)
        }
        data.append(contentsOf: withUnsafeBytes(of: group.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: element.littleEndian) { Array($0) })
        data.append(contentsOf: "CS".utf8)
        data.append(UInt8(bytes.count & 0xFF))
        data.append(UInt8((bytes.count >> 8) & 0xFF))
        data.append(contentsOf: bytes)
    }

    private func appendOWValues(_ data: inout Data, group: UInt16, element: UInt16, values: [UInt16]) {
        let bytes = values.flatMap { value in
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }
        appendBinary(&data, group: group, element: element, vr: "OW", bytes: bytes)
    }

    private func appendBinary(
        _ data: inout Data,
        group: UInt16,
        element: UInt16,
        vr: String,
        bytes: [UInt8]
    ) {
        var padded = bytes
        if padded.count % 2 != 0 {
            padded.append(0)
        }
        data.append(contentsOf: withUnsafeBytes(of: group.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: element.littleEndian) { Array($0) })
        data.append(contentsOf: vr.utf8)
        data.append(contentsOf: [0x00, 0x00])
        data.append(contentsOf: withUnsafeBytes(of: UInt32(padded.count).littleEndian) { Array($0) })
        data.append(contentsOf: padded)
    }

    private func assertUnsupportedColorPath(
        _ error: Error,
        photometricInterpretation: String,
        samplesPerPixel: Int,
        planarConfiguration: Int?,
        bitsAllocated: Int,
        reasonContains: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let DicomColorConversionError.unsupportedColorPath(context, reason) = error else {
            return XCTFail("Expected unsupportedColorPath, got \(error)", file: file, line: line)
        }

        XCTAssertEqual(context.photometricInterpretation, photometricInterpretation, file: file, line: line)
        XCTAssertEqual(context.samplesPerPixel, samplesPerPixel, file: file, line: line)
        XCTAssertEqual(context.planarConfiguration, planarConfiguration, file: file, line: line)
        XCTAssertEqual(context.bitsAllocated, bitsAllocated, file: file, line: line)
        XCTAssertEqual(
            context.transferSyntaxUID,
            DicomTransferSyntax.explicitVRLittleEndian.rawValue,
            file: file,
            line: line
        )
        XCTAssertTrue(reason.contains(reasonContains), reason, file: file, line: line)

        let description = (error as? LocalizedError)?.errorDescription ?? ""
        XCTAssertTrue(description.contains("Photometric Interpretation=\(photometricInterpretation)"), description)
        XCTAssertTrue(description.contains("Samples per Pixel=\(samplesPerPixel)"), description)
        XCTAssertTrue(
            description.contains("Transfer Syntax=\(DicomTransferSyntax.explicitVRLittleEndian.rawValue)"),
            description
        )
    }
}
