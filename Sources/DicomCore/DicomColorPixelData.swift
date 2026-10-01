import Foundation

public enum DicomPhotometricInterpretation: Equatable, Hashable, Sendable {
    case monochrome1
    case monochrome2
    case rgb
    case paletteColor
    case ybrFull
    case ybrFull422
    case ybrPartial420
    case ybrRCT
    case ybrICT
    case unknown(String)

    public init(_ value: String) {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        switch normalized {
        case "MONOCHROME1":
            self = .monochrome1
        case "MONOCHROME2", "":
            self = .monochrome2
        case "RGB":
            self = .rgb
        case "PALETTE COLOR":
            self = .paletteColor
        case "YBR_FULL":
            self = .ybrFull
        case "YBR_FULL_422":
            self = .ybrFull422
        case "YBR_PARTIAL_420":
            self = .ybrPartial420
        case "YBR_RCT":
            self = .ybrRCT
        case "YBR_ICT":
            self = .ybrICT
        default:
            self = .unknown(normalized)
        }
    }

    public var rawValue: String {
        switch self {
        case .monochrome1:
            return "MONOCHROME1"
        case .monochrome2:
            return "MONOCHROME2"
        case .rgb:
            return "RGB"
        case .paletteColor:
            return "PALETTE COLOR"
        case .ybrFull:
            return "YBR_FULL"
        case .ybrFull422:
            return "YBR_FULL_422"
        case .ybrPartial420:
            return "YBR_PARTIAL_420"
        case .ybrRCT:
            return "YBR_RCT"
        case .ybrICT:
            return "YBR_ICT"
        case .unknown(let value):
            return value
        }
    }
}

/// Display conversion status for a DICOM photometric interpretation row.
public enum DicomColorDisplayConversionStatus: String, Codable, Equatable, Sendable {
    /// DicomCore can produce an interleaved 8-bit RGB display buffer.
    case displayRGB = "display-rgb"

    /// DicomCore recognizes the photometric interpretation but does not convert it for display.
    case unsupported
}

/// One row in the DicomCore color display conversion matrix.
public struct DicomColorDisplayConversionSupport: Equatable, Sendable {
    /// Photometric interpretation covered by the row.
    public let photometricInterpretation: DicomPhotometricInterpretation

    /// Display conversion status for this photometric interpretation.
    public let status: DicomColorDisplayConversionStatus

    /// Accepted Samples per Pixel values.
    public let supportedSamplesPerPixel: [Int]

    /// True when the Planar Configuration tag may be absent.
    public let allowsAbsentPlanarConfiguration: Bool

    /// Accepted Planar Configuration values when the tag is present.
    public let supportedPlanarConfigurations: [Int]

    /// Accepted Bits Allocated values.
    public let supportedBitsAllocated: [Int]

    /// True when PALETTE COLOR conversion requires RGB lookup tables.
    public let requiresPaletteColorLookupTable: Bool

    /// True when ICC Profile metadata is carried through to the display buffer.
    public let preservesICCProfile: Bool

    /// Stable diagnostic for unsupported or constrained conversion rows.
    public let diagnostic: String

    /// True when this row can produce display RGB data.
    public var supportsDisplayRGB: Bool {
        status == .displayRGB
    }

    /// Creates a color display conversion matrix row.
    public init(
        photometricInterpretation: DicomPhotometricInterpretation,
        status: DicomColorDisplayConversionStatus,
        supportedSamplesPerPixel: [Int],
        allowsAbsentPlanarConfiguration: Bool,
        supportedPlanarConfigurations: [Int],
        supportedBitsAllocated: [Int],
        requiresPaletteColorLookupTable: Bool,
        preservesICCProfile: Bool,
        diagnostic: String
    ) {
        self.photometricInterpretation = photometricInterpretation
        self.status = status
        self.supportedSamplesPerPixel = supportedSamplesPerPixel
        self.allowsAbsentPlanarConfiguration = allowsAbsentPlanarConfiguration
        self.supportedPlanarConfigurations = supportedPlanarConfigurations
        self.supportedBitsAllocated = supportedBitsAllocated
        self.requiresPaletteColorLookupTable = requiresPaletteColorLookupTable
        self.preservesICCProfile = preservesICCProfile
        self.diagnostic = diagnostic
    }

    /// Returns true when the row accepts the supplied Planar Configuration value.
    public func supports(planarConfiguration: Int?) -> Bool {
        guard let planarConfiguration else {
            return allowsAbsentPlanarConfiguration
        }
        return supportedPlanarConfigurations.contains(planarConfiguration)
    }
}

/// DicomCore's explicit color display conversion support matrix.
public enum DicomColorDisplayConversionMatrix {
    /// Standard display conversion support rows for known photometric interpretations.
    public static let standard: [DicomColorDisplayConversionSupport] = [
        DicomColorDisplayConversionSupport(
            photometricInterpretation: .monochrome1,
            status: .displayRGB,
            supportedSamplesPerPixel: [1],
            allowsAbsentPlanarConfiguration: true,
            supportedPlanarConfigurations: [],
            supportedBitsAllocated: [8, 16],
            requiresPaletteColorLookupTable: false,
            preservesICCProfile: false,
            diagnostic: "MONOCHROME1 display conversion maps stored samples to inverted grayscale RGB."
        ),
        DicomColorDisplayConversionSupport(
            photometricInterpretation: .monochrome2,
            status: .displayRGB,
            supportedSamplesPerPixel: [1],
            allowsAbsentPlanarConfiguration: true,
            supportedPlanarConfigurations: [],
            supportedBitsAllocated: [8, 16],
            requiresPaletteColorLookupTable: false,
            preservesICCProfile: false,
            diagnostic: "MONOCHROME2 display conversion maps stored samples to grayscale RGB."
        ),
        DicomColorDisplayConversionSupport(
            photometricInterpretation: .rgb,
            status: .displayRGB,
            supportedSamplesPerPixel: [3],
            allowsAbsentPlanarConfiguration: true,
            supportedPlanarConfigurations: [0, 1],
            supportedBitsAllocated: [8, 16],
            requiresPaletteColorLookupTable: false,
            preservesICCProfile: true,
            diagnostic: "RGB display conversion supports 8-bit and 16-bit three-sample interleaved or planar "
                + "data; 16-bit samples scale to 8-bit display by Bits Stored, and "
                + "displayRGB48PixelBuffer preserves the full stored precision. Alpha and extra samples "
                + "are unsupported."
        ),
        DicomColorDisplayConversionSupport(
            photometricInterpretation: .paletteColor,
            status: .displayRGB,
            supportedSamplesPerPixel: [1],
            allowsAbsentPlanarConfiguration: true,
            supportedPlanarConfigurations: [],
            supportedBitsAllocated: [8, 16],
            requiresPaletteColorLookupTable: true,
            preservesICCProfile: true,
            diagnostic: "PALETTE COLOR display conversion requires red, green, and blue lookup tables."
        ),
        DicomColorDisplayConversionSupport(
            photometricInterpretation: .ybrFull,
            status: .displayRGB,
            supportedSamplesPerPixel: [3],
            allowsAbsentPlanarConfiguration: true,
            supportedPlanarConfigurations: [0, 1],
            supportedBitsAllocated: [8],
            requiresPaletteColorLookupTable: false,
            preservesICCProfile: true,
            diagnostic: "YBR_FULL display conversion supports 8-bit three-sample interleaved or planar data."
        ),
        DicomColorDisplayConversionSupport(
            photometricInterpretation: .ybrFull422,
            status: .displayRGB,
            supportedSamplesPerPixel: [3],
            allowsAbsentPlanarConfiguration: true,
            supportedPlanarConfigurations: [0],
            supportedBitsAllocated: [8],
            requiresPaletteColorLookupTable: false,
            preservesICCProfile: true,
            diagnostic: "YBR_FULL_422 display conversion supports packed 4:2:2 data with absent or zero "
                + "Planar Configuration."
        ),
        DicomColorDisplayConversionSupport(
            photometricInterpretation: .ybrPartial420,
            status: .unsupported,
            supportedSamplesPerPixel: [3],
            allowsAbsentPlanarConfiguration: true,
            supportedPlanarConfigurations: [0],
            supportedBitsAllocated: [8],
            requiresPaletteColorLookupTable: false,
            preservesICCProfile: false,
            diagnostic: "YBR_PARTIAL_420 display conversion is not implemented; convert to RGB or YBR_FULL "
                + "before display."
        ),
        DicomColorDisplayConversionSupport(
            photometricInterpretation: .ybrRCT,
            status: .unsupported,
            supportedSamplesPerPixel: [3],
            allowsAbsentPlanarConfiguration: true,
            supportedPlanarConfigurations: [0],
            supportedBitsAllocated: [8],
            requiresPaletteColorLookupTable: false,
            preservesICCProfile: false,
            diagnostic: "YBR_RCT applies to JPEG 2000 codestreams: the OpenJPEG backend reverses the "
                + "transform and outputs RGB through the decoded-frame path (DicomDecodedFrameReader). "
                + "Native uncompressed YBR_RCT display conversion is rejected."
        ),
        DicomColorDisplayConversionSupport(
            photometricInterpretation: .ybrICT,
            status: .unsupported,
            supportedSamplesPerPixel: [3],
            allowsAbsentPlanarConfiguration: true,
            supportedPlanarConfigurations: [0],
            supportedBitsAllocated: [8],
            requiresPaletteColorLookupTable: false,
            preservesICCProfile: false,
            diagnostic: "YBR_ICT applies to lossy JPEG 2000 codestreams: the OpenJPEG backend reverses "
                + "the transform and outputs RGB through the decoded-frame path (DicomDecodedFrameReader). "
                + "Native uncompressed YBR_ICT display conversion is rejected."
        )
    ]

    /// Returns the matrix row for a photometric interpretation.
    public static func support(
        for photometricInterpretation: DicomPhotometricInterpretation
    ) -> DicomColorDisplayConversionSupport {
        if let support = standard.first(where: { $0.photometricInterpretation == photometricInterpretation }) {
            return support
        }
        return DicomColorDisplayConversionSupport(
            photometricInterpretation: photometricInterpretation,
            status: .unsupported,
            supportedSamplesPerPixel: [],
            allowsAbsentPlanarConfiguration: true,
            supportedPlanarConfigurations: [],
            supportedBitsAllocated: [],
            requiresPaletteColorLookupTable: false,
            preservesICCProfile: false,
            diagnostic: "\(photometricInterpretation.rawValue) display conversion is not implemented."
        )
    }
}

public struct DicomPaletteColorLookupTable: Equatable, Sendable {
    public let redDescriptor: DicomLUTDescriptor
    public let greenDescriptor: DicomLUTDescriptor
    public let blueDescriptor: DicomLUTDescriptor
    public let red: [UInt8]
    public let green: [UInt8]
    public let blue: [UInt8]

    public init(redDescriptor: DicomLUTDescriptor,
                greenDescriptor: DicomLUTDescriptor,
                blueDescriptor: DicomLUTDescriptor,
                red: [UInt8],
                green: [UInt8],
                blue: [UInt8]) {
        self.redDescriptor = redDescriptor
        self.greenDescriptor = greenDescriptor
        self.blueDescriptor = blueDescriptor
        self.red = red
        self.green = green
        self.blue = blue
    }
}

public struct DicomNativeColorMetadata: Equatable, Sendable {
    public let photometricInterpretation: DicomPhotometricInterpretation
    public let samplesPerPixel: Int
    public let planarConfiguration: Int?
    public let bitsAllocated: Int
    public let bitsStored: Int
    public let highBit: Int
    public let pixelRepresentation: Int
    public let paletteColorLookupTable: DicomPaletteColorLookupTable?
    public let iccProfile: Data?

    public init(photometricInterpretation: DicomPhotometricInterpretation,
                samplesPerPixel: Int,
                planarConfiguration: Int?,
                bitsAllocated: Int,
                bitsStored: Int,
                highBit: Int,
                pixelRepresentation: Int,
                paletteColorLookupTable: DicomPaletteColorLookupTable?,
                iccProfile: Data?) {
        self.photometricInterpretation = photometricInterpretation
        self.samplesPerPixel = samplesPerPixel
        self.planarConfiguration = planarConfiguration
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.pixelRepresentation = pixelRepresentation
        self.paletteColorLookupTable = paletteColorLookupTable
        self.iccProfile = iccProfile
    }

    public static let empty = DicomNativeColorMetadata(
        photometricInterpretation: .monochrome2,
        samplesPerPixel: 0,
        planarConfiguration: nil,
        bitsAllocated: 0,
        bitsStored: 0,
        highBit: 0,
        pixelRepresentation: 0,
        paletteColorLookupTable: nil,
        iccProfile: nil
    )
}

public struct DicomDisplayPixelBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let frameIndex: Int
    public let photometricInterpretation: DicomPhotometricInterpretation
    public let rgbData: Data
    public let iccProfile: Data?

    public var bytesPerPixel: Int { 3 }

    public init(width: Int,
                height: Int,
                frameIndex: Int,
                photometricInterpretation: DicomPhotometricInterpretation,
                rgbData: Data,
                iccProfile: Data?) {
        self.width = width
        self.height = height
        self.frameIndex = frameIndex
        self.photometricInterpretation = photometricInterpretation
        self.rgbData = rgbData
        self.iccProfile = iccProfile
    }
}

/// Precision-preserving display buffer for high-bit-depth color frames:
/// interleaved 16-bit little-endian R,G,B samples carrying the stored
/// values (no scaling to 8 bits).
public struct DicomDisplayRGB48PixelBuffer: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let frameIndex: Int
    public let photometricInterpretation: DicomPhotometricInterpretation
    /// Bits Stored of the source samples (values occupy 0...2^bitsStored-1).
    public let bitsStored: Int
    /// Interleaved 16-bit little-endian R,G,B samples.
    public let rgb48Data: Data
    public let iccProfile: Data?

    public var bytesPerPixel: Int { 6 }

    public init(width: Int,
                height: Int,
                frameIndex: Int,
                photometricInterpretation: DicomPhotometricInterpretation,
                bitsStored: Int,
                rgb48Data: Data,
                iccProfile: Data?) {
        self.width = width
        self.height = height
        self.frameIndex = frameIndex
        self.photometricInterpretation = photometricInterpretation
        self.bitsStored = bitsStored
        self.rgb48Data = rgb48Data
        self.iccProfile = iccProfile
    }
}

public enum DicomColorConversionError: Error, Equatable, LocalizedError, Sendable {
    case missingPixelDataFrame(Int)
    case unsupportedPhotometricInterpretation(String)
    case unsupportedSamplesPerPixel(Int)
    case unsupportedBitsAllocated(Int)
    case unsupportedPlanarConfiguration(Int?)
    case unsupportedColorPath(context: DicomColorConversionContext, reason: String)
    case missingPaletteColorLookupTable
    case invalidPixelData(String)

    public var errorDescription: String? {
        switch self {
        case .missingPixelDataFrame(let frame):
            return "Missing native Pixel Data frame \(frame)."
        case .unsupportedPhotometricInterpretation(let value):
            return "Unsupported Photometric Interpretation: \(value)."
        case .unsupportedSamplesPerPixel(let value):
            return "Unsupported Samples per Pixel: \(value)."
        case .unsupportedBitsAllocated(let value):
            return "Unsupported Bits Allocated for color conversion: \(value)."
        case .unsupportedPlanarConfiguration(let value):
            let text = value.map(String.init) ?? "absent"
            return "Unsupported Planar Configuration: \(text)."
        case .unsupportedColorPath(let context, let reason):
            return "Unsupported color display conversion: \(reason) (\(context.diagnosticDescription))."
        case .missingPaletteColorLookupTable:
            return "PALETTE COLOR conversion requires red, green, and blue lookup tables."
        case .invalidPixelData(let reason):
            return "Invalid Pixel Data: \(reason)."
        }
    }
}

/// Diagnostic context included when a color display path is rejected.
public struct DicomColorConversionContext: Equatable, Sendable {
    /// DICOM Photometric Interpretation value used for display conversion.
    public let photometricInterpretation: String

    /// DICOM Samples per Pixel value.
    public let samplesPerPixel: Int

    /// DICOM Planar Configuration value, or nil when absent.
    public let planarConfiguration: Int?

    /// DICOM Bits Allocated value.
    public let bitsAllocated: Int

    /// DICOM Transfer Syntax UID used when reading the pixel data.
    public let transferSyntaxUID: String

    /// Stable single-line description for logs and tests.
    public var diagnosticDescription: String {
        let planar = planarConfiguration.map(String.init) ?? "absent"
        return "Photometric Interpretation=\(photometricInterpretation), "
            + "Samples per Pixel=\(samplesPerPixel), "
            + "Planar Configuration=\(planar), "
            + "Bits Allocated=\(bitsAllocated), "
            + "Transfer Syntax=\(transferSyntaxUID)"
    }

    /// Creates color conversion diagnostic context.
    public init(
        photometricInterpretation: String,
        samplesPerPixel: Int,
        planarConfiguration: Int?,
        bitsAllocated: Int,
        transferSyntaxUID: String
    ) {
        self.photometricInterpretation = photometricInterpretation
        self.samplesPerPixel = samplesPerPixel
        self.planarConfiguration = planarConfiguration
        self.bitsAllocated = bitsAllocated
        self.transferSyntaxUID = transferSyntaxUID
    }
}

extension DCMDecoder {
    public var nativeColorMetadata: DicomNativeColorMetadata {
        synchronized {
            let descriptor = pixelDataDescriptor
            return makeNativeColorMetadataUnsafe(descriptor: descriptor)
        }
    }

    public func displayRGBPixelBuffer(frame frameIndex: Int = 0) throws -> DicomDisplayPixelBuffer {
        try synchronized {
            guard let descriptor = pixelDataDescriptor,
                  let frame = getFrame(frameIndex) else {
                throw DicomColorConversionError.missingPixelDataFrame(frameIndex)
            }

            let metadata = makeNativeColorMetadataUnsafe(descriptor: descriptor)
            let context = makeColorConversionContextUnsafe(metadata: metadata)
            let rgbData: Data
            switch metadata.photometricInterpretation {
            case .monochrome1, .monochrome2:
                rgbData = try makeMonochromeDisplayRGB(frame: frame, metadata: metadata, context: context)
            case .rgb:
                rgbData = try makeRGBDisplayData(frame: frame, context: context)
            case .paletteColor:
                rgbData = try makePaletteDisplayRGB(frame: frame, metadata: metadata, context: context)
            case .ybrFull:
                rgbData = try makeYBRFullDisplayRGB(frame: frame, context: context)
            case .ybrFull422:
                rgbData = try makeYBRFull422DisplayRGB(frame: frame, context: context)
            case .ybrPartial420, .ybrRCT, .ybrICT:
                let support = DicomColorDisplayConversionMatrix.support(for: metadata.photometricInterpretation)
                throw DicomColorConversionError.unsupportedColorPath(context: context, reason: support.diagnostic)
            case .unknown(let value):
                throw DicomColorConversionError.unsupportedColorPath(
                    context: context,
                    reason: "\(value) display conversion is not implemented."
                )
            }

            return DicomDisplayPixelBuffer(
                width: descriptor.columns,
                height: descriptor.rows,
                frameIndex: frameIndex,
                photometricInterpretation: metadata.photometricInterpretation,
                rgbData: rgbData,
                iccProfile: metadata.iccProfile
            )
        }
    }

    /// RGB8 display samples of a frame already decoded to interleaved stored samples (issue #2821): PALETTE COLOR
    /// indices through the object's palette (segmented palettes included), YBR_FULL and YBR_FULL_422 through the
    /// same YBR conversion as native frames, RGB as it is. A decoded YBR_FULL_422 frame carries a full sample triplet
    /// per pixel, so it converts like YBR_FULL.
    public func displayRGB8(decodedFrame: DicomDecodedFrame) throws -> Data {
        try synchronized {
            let stored = decodedFrame.storedSampleData()
            let metadata = makeNativeColorMetadataUnsafe(descriptor: nil)
            let context = makeColorConversionContextUnsafe(metadata: metadata)
            let photometric: String
            switch metadata.photometricInterpretation {
            case .paletteColor: photometric = "PALETTE COLOR"
            case .ybrFull, .ybrFull422: photometric = "YBR_FULL"
            case .rgb:
                if case .rgb8 = decodedFrame.pixels { return stored }
                photometric = "RGB"
            default:
                throw DicomColorConversionError.unsupportedColorPath(
                    context: context, reason: "\(metadata.photometricInterpretation.rawValue) is not a colour frame.")
            }
            let samples = photometric == "PALETTE COLOR" ? 1 : 3
            let bitsAllocated: Int
            switch decodedFrame.pixels {
            case .gray16: bitsAllocated = 16
            case .gray8, .rgb8: bitsAllocated = 8
            }
            guard let descriptor = DicomPixelDataDescriptor(
                rows: decodedFrame.metadata.height, columns: decodedFrame.metadata.width, numberOfFrames: 1,
                bitsAllocated: bitsAllocated, bitsStored: min(metadata.bitsStored, bitsAllocated),
                highBit: min(metadata.bitsStored, bitsAllocated) - 1, pixelRepresentation: 0,
                samplesPerPixel: samples, planarConfiguration: samples == 3 ? 0 : nil,
                photometricInterpretation: photometric, pixelDataOffset: 0
            ) else {
                throw DicomColorConversionError.invalidPixelData("The decoded frame has no valid layout.")
            }
            let frame = DicomPixelFrame(index: decodedFrame.index, byteRange: 0..<stored.count, data: stored,
                                        descriptor: descriptor)
            if photometric == "PALETTE COLOR" {
                return try makePaletteDisplayRGB(frame: frame, metadata: metadata, context: context, littleEndian: true)
            }
            if photometric == "RGB" { return try makeRGBDisplayData(frame: frame, context: context, littleEndian: true) }
            return try makeYBRFullDisplayRGB(frame: frame, context: context)
        }
    }

    /// Precision-preserving color output (issue #1232): returns the RGB
    /// frame as interleaved 16-bit samples carrying the stored values.
    /// Supported for native RGB frames with 8 or 16 Bits Allocated (8-bit
    /// samples widen by 257 to fill the 16-bit range); every other
    /// photometric interpretation is rejected typed.
    public func displayRGB48PixelBuffer(frame frameIndex: Int = 0) throws -> DicomDisplayRGB48PixelBuffer {
        try synchronized {
            guard let descriptor = pixelDataDescriptor,
                  let frame = getFrame(frameIndex) else {
                throw DicomColorConversionError.missingPixelDataFrame(frameIndex)
            }

            let metadata = makeNativeColorMetadataUnsafe(descriptor: descriptor)
            let context = makeColorConversionContextUnsafe(metadata: metadata)
            guard metadata.photometricInterpretation == .rgb else {
                throw DicomColorConversionError.unsupportedColorPath(
                    context: context,
                    reason: "Precision-preserving RGB48 output supports Photometric Interpretation RGB only."
                )
            }
            try validateThreeSampleFrame(frame, context: context, colorSpaceName: "RGB", allowedBitsAllocated: [8, 16])

            let pixelsPerFrame = descriptor.rows * descriptor.columns
            var output = [UInt8](repeating: 0, count: pixelsPerFrame * 6)
            let widensEightBit = descriptor.bitsAllocated == 8
            for pixelIndex in 0..<pixelsPerFrame {
                for sample in 0..<3 {
                    guard let storedValue = storedSampleValue(
                        frameData: frame.data,
                        pixelIndex: pixelIndex,
                        sample: sample,
                        descriptor: descriptor
                    ) else {
                        throw DicomColorConversionError.invalidPixelData("Missing RGB sample at pixel \(pixelIndex).")
                    }
                    let value = widensEightBit
                        ? UInt16(clamping: storedValue) &* 257
                        : UInt16(clamping: storedValue)
                    let base = (pixelIndex * 3 + sample) * 2
                    output[base] = UInt8(value & 0xFF)
                    output[base + 1] = UInt8(value >> 8)
                }
            }

            return DicomDisplayRGB48PixelBuffer(
                width: descriptor.columns,
                height: descriptor.rows,
                frameIndex: frameIndex,
                photometricInterpretation: metadata.photometricInterpretation,
                bitsStored: widensEightBit ? 16 : descriptor.bitsStored,
                rgb48Data: Data(output),
                iccProfile: metadata.iccProfile
            )
        }
    }

    private func makeNativeColorMetadataUnsafe(
        descriptor: DicomPixelDataDescriptor?
    ) -> DicomNativeColorMetadata {
        let photometric = descriptor?.photometricInterpretation
            ?? (photometricInterpretation.isEmpty ? "MONOCHROME2" : photometricInterpretation)
        let dataSet = self.dataSet
        return DicomNativeColorMetadata(
            photometricInterpretation: DicomPhotometricInterpretation(photometric),
            samplesPerPixel: descriptor?.samplesPerPixel ?? samplesPerPixel,
            planarConfiguration: descriptor?.planarConfiguration ?? intValue(for: .planarConfiguration),
            bitsAllocated: descriptor?.bitsAllocated ?? bitDepth,
            bitsStored: descriptor?.bitsStored ?? intValue(for: .bitsStored) ?? bitDepth,
            highBit: descriptor?.highBit ?? intValue(for: .highBit) ?? max(0, bitDepth - 1),
            pixelRepresentation: descriptor?.pixelRepresentation ?? pixelRepresentation,
            paletteColorLookupTable: makePaletteColorLookupTableUnsafe(),
            iccProfile: dataSet.element(for: .iccProfile)?.bytesValue
        )
    }

    private func makeColorConversionContextUnsafe(
        metadata: DicomNativeColorMetadata
    ) -> DicomColorConversionContext {
        let transferSyntax = transferSyntaxUID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DicomColorConversionContext(
            photometricInterpretation: metadata.photometricInterpretation.rawValue,
            samplesPerPixel: metadata.samplesPerPixel,
            planarConfiguration: metadata.planarConfiguration,
            bitsAllocated: metadata.bitsAllocated,
            transferSyntaxUID: transferSyntax.isEmpty
                ? DicomTransferSyntax.explicitVRLittleEndian.rawValue
                : transferSyntax
        )
    }

    private func makePaletteColorLookupTableUnsafe() -> DicomPaletteColorLookupTable? {
        guard let reds, let greens, let blues else {
            return nil
        }

        let count = min(reds.count, greens.count, blues.count)
        guard count > 0 else { return nil }
        let defaultDescriptor = DicomLUTDescriptor(
            storedEntryCount: count,
            firstMappedValue: 0,
            bitsPerEntry: 8
        )!

        return DicomPaletteColorLookupTable(
            redDescriptor: redPaletteDescriptor ?? defaultDescriptor,
            greenDescriptor: greenPaletteDescriptor ?? defaultDescriptor,
            blueDescriptor: bluePaletteDescriptor ?? defaultDescriptor,
            red: Array(reds.prefix(count)),
            green: Array(greens.prefix(count)),
            blue: Array(blues.prefix(count))
        )
    }

    private func makeMonochromeDisplayRGB(
        frame: DicomPixelFrame,
        metadata: DicomNativeColorMetadata,
        context: DicomColorConversionContext
    ) throws -> Data {
        guard frame.descriptor.samplesPerPixel == 1 else {
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: "\(metadata.photometricInterpretation.rawValue) display conversion requires "
                    + "Samples per Pixel 1."
            )
        }
        guard frame.descriptor.bytesPerSample <= 2 else {
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: "\(metadata.photometricInterpretation.rawValue) display conversion supports only "
                    + "8-bit or 16-bit samples."
            )
        }

        let pixelsPerFrame = frame.descriptor.rows * frame.descriptor.columns
        let profile = displayTransformProfile
        var output = [UInt8](repeating: 0, count: pixelsPerFrame * 3)

        for pixelIndex in 0..<pixelsPerFrame {
            guard let storedValue = storedSampleValue(
                frameData: frame.data,
                pixelIndex: pixelIndex,
                sample: 0,
                descriptor: frame.descriptor
            ) else {
                throw DicomColorConversionError.invalidPixelData("Missing monochrome sample at pixel \(pixelIndex).")
            }

            let fallback = scaledDisplayByte(storedValue: storedValue, metadata: metadata)
            let gray = profile.displayValue(forStoredPixelValue: Double(storedValue)) ?? fallback
            let base = pixelIndex * 3
            output[base] = gray
            output[base + 1] = gray
            output[base + 2] = gray
        }

        return Data(output)
    }

    private func makeRGBDisplayData(
        frame: DicomPixelFrame,
        context: DicomColorConversionContext,
        littleEndian: Bool? = nil
    ) throws -> Data {
        try validateThreeSampleFrame(frame, context: context, colorSpaceName: "RGB", allowedBitsAllocated: [8, 16])
        if frame.descriptor.bitsAllocated == 16 {
            return try makeHighBitDepthRGBDisplayData(frame: frame, context: context, littleEndian: littleEndian)
        }
        return try makeThreeSampleDisplayRGB(frame: frame) { red, green, blue in
            (red, green, blue)
        }
    }

    /// Scales 16-bit-allocated RGB samples to 8-bit display by Bits Stored
    /// (the decode path preserved the stored precision; only the display
    /// mapping reduces it).
    private func makeHighBitDepthRGBDisplayData(
        frame: DicomPixelFrame,
        context: DicomColorConversionContext,
        littleEndian: Bool? = nil
    ) throws -> Data {
        let descriptor = frame.descriptor
        let pixelsPerFrame = descriptor.rows * descriptor.columns
        let maxStored = max(1, (1 << min(max(descriptor.bitsStored, 1), 16)) - 1)
        var output = [UInt8](repeating: 0, count: pixelsPerFrame * 3)

        for pixelIndex in 0..<pixelsPerFrame {
            for sample in 0..<3 {
                guard let storedValue = storedSampleValue(
                    frameData: frame.data,
                    pixelIndex: pixelIndex,
                    sample: sample,
                    descriptor: descriptor,
                    littleEndian: littleEndian
                ) else {
                    throw DicomColorConversionError.invalidPixelData("Missing RGB sample at pixel \(pixelIndex).")
                }
                let clamped = max(0, min(maxStored, storedValue))
                output[pixelIndex * 3 + sample] =
                    UInt8((Double(clamped) * 255.0 / Double(maxStored)).rounded())
            }
        }

        return Data(output)
    }

    private func makeYBRFullDisplayRGB(
        frame: DicomPixelFrame,
        context: DicomColorConversionContext
    ) throws -> Data {
        try validateThreeSampleFrame(frame, context: context, colorSpaceName: "YBR_FULL", allowedBitsAllocated: [8])
        return try makeThreeSampleDisplayRGB(frame: frame) { y, cb, cr in
            Self.ybrToRgb(y: y, cb: cb, cr: cr)
        }
    }

    private func makeYBRFull422DisplayRGB(
        frame: DicomPixelFrame,
        context: DicomColorConversionContext
    ) throws -> Data {
        let descriptor = frame.descriptor
        guard descriptor.samplesPerPixel == 3 else {
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: "YBR_FULL_422 display conversion requires Samples per Pixel 3."
            )
        }
        guard descriptor.bitsAllocated == 8 else {
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: "YBR_FULL_422 display conversion supports only 8-bit samples."
            )
        }
        guard descriptor.planarConfiguration == nil || descriptor.planarConfiguration == 0 else {
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: "YBR_FULL_422 display conversion supports absent or zero Planar Configuration."
            )
        }
        guard descriptor.columns % 2 == 0 else {
            throw DicomColorConversionError.invalidPixelData("YBR_FULL_422 requires an even column count.")
        }

        let pixelsPerFrame = descriptor.rows * descriptor.columns
        let expectedBytes = descriptor.rows * (descriptor.columns / 2) * 4
        guard frame.data.count >= expectedBytes else {
            throw DicomColorConversionError.invalidPixelData("YBR_FULL_422 frame is shorter than expected.")
        }

        var output = [UInt8](repeating: 0, count: pixelsPerFrame * 3)
        var inputOffset = 0
        for row in 0..<descriptor.rows {
            for columnPair in stride(from: 0, to: descriptor.columns, by: 2) {
                let y1 = frame.data[inputOffset]
                let y2 = frame.data[inputOffset + 1]
                let cb = frame.data[inputOffset + 2]
                let cr = frame.data[inputOffset + 3]
                inputOffset += 4

                let pixelIndex = row * descriptor.columns + columnPair
                writeRGB(Self.ybrToRgb(y: y1, cb: cb, cr: cr), to: &output, pixelIndex: pixelIndex)
                writeRGB(Self.ybrToRgb(y: y2, cb: cb, cr: cr), to: &output, pixelIndex: pixelIndex + 1)
            }
        }

        return Data(output)
    }

    private func makePaletteDisplayRGB(
        frame: DicomPixelFrame,
        metadata: DicomNativeColorMetadata,
        context: DicomColorConversionContext,
        littleEndian: Bool? = nil
    ) throws -> Data {
        let descriptor = frame.descriptor
        guard descriptor.samplesPerPixel == 1 else {
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: "PALETTE COLOR display conversion requires Samples per Pixel 1."
            )
        }
        guard descriptor.bytesPerSample <= 2 else {
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: "PALETTE COLOR display conversion supports only 8-bit or 16-bit palette indexes."
            )
        }
        guard let palette = metadata.paletteColorLookupTable else {
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: "PALETTE COLOR display conversion requires red, green, and blue lookup tables."
            )
        }

        let pixelsPerFrame = descriptor.rows * descriptor.columns
        var output = [UInt8](repeating: 0, count: pixelsPerFrame * 3)

        for pixelIndex in 0..<pixelsPerFrame {
            guard let storedValue = storedSampleValue(
                frameData: frame.data,
                pixelIndex: pixelIndex,
                sample: 0,
                descriptor: descriptor,
                littleEndian: littleEndian
            ) else {
                throw DicomColorConversionError.invalidPixelData("Missing palette index at pixel \(pixelIndex).")
            }
            guard let redIndex = palette.redDescriptor.clampedIndex(
                for: storedValue,
                availableEntryCount: palette.red.count
            ),
                  let greenIndex = palette.greenDescriptor.clampedIndex(
                    for: storedValue,
                    availableEntryCount: palette.green.count
                  ),
                  let blueIndex = palette.blueDescriptor.clampedIndex(
                    for: storedValue,
                    availableEntryCount: palette.blue.count
                  ) else {
                throw DicomColorConversionError.unsupportedColorPath(
                    context: context,
                    reason: "PALETTE COLOR display conversion requires valid red, green, and blue lookup table entries."
                )
            }

            let base = pixelIndex * 3
            output[base] = palette.red[redIndex]
            output[base + 1] = palette.green[greenIndex]
            output[base + 2] = palette.blue[blueIndex]
        }

        return Data(output)
    }

    private func validateThreeSampleFrame(
        _ frame: DicomPixelFrame,
        context: DicomColorConversionContext,
        colorSpaceName: String,
        allowedBitsAllocated: [Int]
    ) throws {
        let descriptor = frame.descriptor
        guard descriptor.samplesPerPixel == 3 else {
            let reason = descriptor.samplesPerPixel > 3
                ? "\(colorSpaceName) display conversion supports exactly 3 samples; "
                    + "alpha and extra samples are unsupported."
                : "\(colorSpaceName) display conversion requires Samples per Pixel 3."
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: reason
            )
        }
        guard allowedBitsAllocated.contains(descriptor.bitsAllocated) else {
            let depths = allowedBitsAllocated.map(String.init).joined(separator: "-bit or ")
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: "\(colorSpaceName) display conversion supports only \(depths)-bit samples."
            )
        }
        guard descriptor.planarConfiguration == nil
                || descriptor.planarConfiguration == 0
                || descriptor.planarConfiguration == 1 else {
            throw DicomColorConversionError.unsupportedColorPath(
                context: context,
                reason: "\(colorSpaceName) display conversion supports absent, zero, or one Planar Configuration."
            )
        }
    }

    private func makeThreeSampleDisplayRGB(
        frame: DicomPixelFrame,
        transform: (UInt8, UInt8, UInt8) -> (UInt8, UInt8, UInt8)
    ) throws -> Data {
        let descriptor = frame.descriptor
        let pixelsPerFrame = descriptor.rows * descriptor.columns
        var output = [UInt8](repeating: 0, count: pixelsPerFrame * 3)

        for pixelIndex in 0..<pixelsPerFrame {
            guard let first = storedSampleValue(
                frameData: frame.data,
                pixelIndex: pixelIndex,
                sample: 0,
                descriptor: descriptor
            ),
                  let second = storedSampleValue(
                    frameData: frame.data,
                    pixelIndex: pixelIndex,
                    sample: 1,
                    descriptor: descriptor
                  ),
                  let third = storedSampleValue(
                    frameData: frame.data,
                    pixelIndex: pixelIndex,
                    sample: 2,
                    descriptor: descriptor
                  ) else {
                throw DicomColorConversionError.invalidPixelData("Missing RGB/YBR sample at pixel \(pixelIndex).")
            }

            let rgb = transform(UInt8(clamping: first), UInt8(clamping: second), UInt8(clamping: third))
            writeRGB(rgb, to: &output, pixelIndex: pixelIndex)
        }

        return Data(output)
    }

    private func storedSampleValue(
        frameData: Data,
        pixelIndex: Int,
        sample: Int,
        descriptor: DicomPixelDataDescriptor,
        littleEndian: Bool? = nil
    ) -> Int? {
        guard pixelIndex >= 0,
              sample >= 0,
              sample < descriptor.samplesPerPixel,
              descriptor.bytesPerSample <= 2 else {
            return nil
        }

        let pixelsPerFrame = descriptor.rows * descriptor.columns
        guard pixelIndex < pixelsPerFrame else { return nil }

        let sampleIndex: Int
        if descriptor.planarConfiguration == 1 && descriptor.samplesPerPixel > 1 {
            sampleIndex = sample * pixelsPerFrame + pixelIndex
        } else {
            sampleIndex = pixelIndex * descriptor.samplesPerPixel + sample
        }

        let byteOffset = sampleIndex * descriptor.bytesPerSample
        guard byteOffset >= 0,
              byteOffset + descriptor.bytesPerSample <= frameData.count else {
            return nil
        }

        let rawValue: Int
        switch descriptor.bytesPerSample {
        case 1:
            rawValue = Int(frameData[byteOffset])
        case 2:
            rawValue = Int(frameData.readUInt16(at: byteOffset, littleEndian: littleEndian ?? currentLittleEndian()))
        default:
            return nil
        }

        let shift = max(0, descriptor.highBit - descriptor.bitsStored + 1)
        let mask = (1 << descriptor.bitsStored) - 1
        let storedBits = (rawValue >> shift) & mask

        guard descriptor.isSigned else {
            return storedBits
        }

        let signBit = 1 << (descriptor.bitsStored - 1)
        return (storedBits & signBit) != 0
            ? storedBits - (1 << descriptor.bitsStored)
            : storedBits
    }

    private func scaledDisplayByte(
        storedValue: Int,
        metadata: DicomNativeColorMetadata
    ) -> UInt8 {
        let maximum = max(1, (1 << min(max(metadata.bitsStored, 1), 16)) - 1)
        let normalized = Double(max(0, min(maximum, storedValue))) / Double(maximum)
        let display = metadata.photometricInterpretation == .monochrome1 ? 1.0 - normalized : normalized
        return UInt8(max(0, min(255, Int((display * 255.0).rounded()))))
    }

    private func writeRGB(
        _ rgb: (UInt8, UInt8, UInt8),
        to output: inout [UInt8],
        pixelIndex: Int
    ) {
        let base = pixelIndex * 3
        output[base] = rgb.0
        output[base + 1] = rgb.1
        output[base + 2] = rgb.2
    }

    static func ybrToRgb(y: UInt8, cb: UInt8, cr: UInt8) -> (UInt8, UInt8, UInt8) {
        let luminance = Double(y)
        let cbShift = Double(cb) - 128.0
        let crShift = Double(cr) - 128.0
        let red = luminance + 1.402 * crShift
        let green = luminance - 0.344136 * cbShift - 0.714136 * crShift
        let blue = luminance + 1.772 * cbShift
        return (clampedByte(red), clampedByte(green), clampedByte(blue))
    }

    private static func clampedByte(_ value: Double) -> UInt8 {
        UInt8(max(0, min(255, Int(value.rounded()))))
    }
}

public extension DicomDecoderProtocol {
    var nativeColorMetadata: DicomNativeColorMetadata {
        .empty
    }

    func displayRGBPixelBuffer(frame: Int) throws -> DicomDisplayPixelBuffer {
        let photometric = DicomPhotometricInterpretation(
            photometricInterpretation.isEmpty ? "MONOCHROME2" : photometricInterpretation
        )
        let transferSyntax = info(for: .transferSyntaxUID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let context = DicomColorConversionContext(
            photometricInterpretation: photometric.rawValue,
            samplesPerPixel: samplesPerPixel,
            planarConfiguration: nil,
            bitsAllocated: bitDepth,
            transferSyntaxUID: transferSyntax.isEmpty
                ? DicomTransferSyntax.explicitVRLittleEndian.rawValue
                : transferSyntax
        )
        throw DicomColorConversionError.unsupportedColorPath(
            context: context,
            reason: "\(photometric.rawValue) display conversion is not implemented by this decoder."
        )
    }

    func displayRGBPixelBuffer() throws -> DicomDisplayPixelBuffer {
        try displayRGBPixelBuffer(frame: 0)
    }
}

private extension Data {
    func readUInt16(at offset: Int, littleEndian: Bool) -> UInt16 {
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1])
        return littleEndian ? (b1 << 8 | b0) : (b0 << 8 | b1)
    }
}
