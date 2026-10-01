//
//  DicomJ2KSwiftBackend.swift
//  DicomCore
//
//  Own JPEG 2000 backend on the vendored DicomJPEG2000 target (J2KSwift 11.0.2 J2KCore/J2KCodec CPU paths, #2329).
//  GPU (Metal), NEON, MJ2 and JP3D layers are not carried; codec types stay behind the neutral frame contract.
//

import Foundation
import DicomJPEG2000

extension DicomCodecBackendIdentifier {
    static let j2kSwiftCPU: Self = "j2kswift-cpu"
    static let openJPEGCPU: Self = "openjpeg-cpu"
}

struct DicomJ2KSwiftBackend: DicomFrameCodecBackend {
    static let version = "11.0.2-vendored"
    /// Version string reported by the vendored J2KSwift core itself (`getVersion()`).
    static let coreVersion = "11.0.2"
    static let allFrameTransferSyntaxes: Set<String> = [
        DicomTransferSyntax.jpeg2000Lossless.rawValue,
        DicomTransferSyntax.jpeg2000.rawValue,
        DicomTransferSyntax.htj2kLossless.rawValue,
        DicomTransferSyntax.htj2kLosslessRPCL.rawValue,
        DicomTransferSyntax.htj2k.rawValue
    ]
    /// Decode qualification covers the same five syntaxes as encode since #2330 (HT decode was OpenJPEG-only before).
    static let qualifiedTransferSyntaxes: Set<String> = allFrameTransferSyntaxes
    /// JPEG 2000 Part 2 Multi-component syntaxes (#2331): decoded and encoded as component collections
    /// (`decodeCollection`/`encodeCollection`), advertised as experimental because no independent Part 2 decoder is
    /// available locally (OpenJPEG rejects SGcod 2; the coded components and the marker semantics are cross-checked separately).
    static let part2TransferSyntaxes: Set<String> = DicomJ2KPart2Profile.syntaxUIDs

    let capabilities = DicomFrameCodecCapabilities(
        identifier: .j2kSwiftCPU,
        families: [.jpeg2000, .htj2k],
        transferSyntaxUIDs: qualifiedTransferSyntaxes.union(part2TransferSyntaxes),
        encodeTransferSyntaxUIDs: allFrameTransferSyntaxes.union(part2TransferSyntaxes),
        operations: [.decode, .encode],
        supportedGrayscaleBitDepths: 1...16,
        supportedColorBitDepths: 1...8,
        maximumComponents: 3,
        supportsSignedSamples: true,
        partialDecode: DicomPartialDecodeCapabilities(
            supportsRegionOfInterest: true,
            supportsResolutionLevels: true,
            supportsQualityLayers: true,
            supportsCombinedRegionAndResolution: true,
            supportsQualityWithSpatialReduction: true
        ),
        executionClass: .cpu,
        source: .packageLinked,
        version: version
    )

    func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame {
        try Task.checkCancellation()
        guard !Self.part2TransferSyntaxes.contains(request.descriptor.transferSyntaxUID) else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reason: "Part 2 component collections are decoded through the collection API (every frame is a component)"
            )
        }
        if request.partialRequest != nil,
           let reason = capabilities.unsupportedReason(for: request) {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reason: reason
            )
        }

        let decoder = J2KDecoder(sampleByteOrder: .littleEndian)
        // Frames wrapped in a JP2/JPX/JPH container decode from their contiguous codestream box; the validator reports
        // the wrapper separately (PS3.5 A.4.4 requires the raw codestream).
        let frameData: Data
        do { frameData = try DicomJ2KCodestreamInspector.unwrap(request.frameData).codestream } catch {
            throw DicomJ2KSwiftBackendError.unsupportedShape(transferSyntaxUID: request.descriptor.transferSyntaxUID,
                                                             reason: "the frame carries a malformed JPEG 2000 file-format wrapper")
        }
        // The declared syntax and the codestream capabilities must agree (Part 15 for .201–.203, Part 1 for .90/.91,
        // reversible coding for the lossless-only syntaxes). The .202 progressive options are validator diagnostics.
        let uid = request.descriptor.transferSyntaxUID
        guard let inspection = try? DicomJ2KCodestreamInspector.inspect(frameData) else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid, reason: "the frame is not a parseable JPEG 2000 codestream")
        }
        if let violation = DicomHTJ2KProfile.violation(of: uid, inspection: inspection, strictRPCLOptions: false) {
            throw DicomJ2KSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: violation)
        }
        // The SIZ must describe the dataset's frame before the decoder allocates for it (#2901).
        try Self.checkSIZ(inspection, descriptor: request.descriptor, partial: request.partialRequest != nil)
        let image: J2KImage
        var codecBytesAvoided: Int?
        if let partial = request.partialRequest,
           partial.region != nil || partial.resolutionLevel != nil || partial.maximumQualityLayer != nil {
            // Region, resolution and quality layer combine in one partial decode (issue #2382); the report
            // carries the packet bytes the quality limit kept out of the entropy decoder.
            let region = partial.region.map {
                J2KRegion(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            let result = try await decoder.decodePartialReporting(
                frameData,
                options: J2KPartialDecodingOptions(
                    maxLayer: partial.maximumQualityLayer,
                    maxResolutionLevel: partial.resolutionLevel,
                    region: region
                )
            )
            image = result.image
            codecBytesAvoided = partial.maximumQualityLayer == nil ? nil : result.report.skippedPacketBytes
        } else {
            image = try await decoder.decode(frameData)
        }
        try Task.checkCancellation()
        return try Self.normalizedFrame(
            from: image,
            descriptor: request.descriptor,
            allowsPartialDimensions: request.partialRequest != nil,
            codecBytesAvoided: codecBytesAvoided
        )
    }

    func encode(_ request: DicomFrameEncodeRequest) async throws -> Data {
        let descriptor = request.descriptor
        guard !Self.part2TransferSyntaxes.contains(request.targetTransferSyntaxUID) else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: "Part 2 component collections are encoded through the collection API (every frame is a component)"
            )
        }
        if let reason = capabilities.unsupportedReason(for: descriptor, operation: .encode) {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: reason
            )
        }
        try Self.validateEncoding(
            descriptor: descriptor,
            targetTransferSyntaxUID: request.targetTransferSyntaxUID,
            intent: request.intent
        )
        if let tileSize = request.tileSize {
            guard tileSize.width > 0, tileSize.height > 0 else {
                throw DicomJ2KSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: request.targetTransferSyntaxUID, reason: "tile dimensions must be positive")
            }
            // Tiles share one main-header QCD; the irreversible path derives adaptive step sizes per tile, so only
            // reversible encodes are tiled. PS3.5 10.18.1 recommends a single tile for the .202 progressive syntax.
            guard !request.intent.isLossy else {
                throw DicomJ2KSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: request.targetTransferSyntaxUID,
                    reason: "tiling is qualified for reversible encodes only")
            }
            guard request.targetTransferSyntaxUID != DicomTransferSyntax.htj2kLosslessRPCL.rawValue else {
                throw DicomJ2KSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: request.targetTransferSyntaxUID,
                    reason: "the HTJ2K Lossless RPCL syntax is written as a single tile (PS3.5 10.18.1)")
            }
        }
        try Task.checkCancellation()
        let options = try request.jpeg2000Options?.resolved(descriptor: descriptor, intent: request.intent)
        if options != nil, request.tileSize != nil {
            throw DicomJPEG2000EncodingError.unsupportedConfiguration(reason: "explicit resolution layers require a single untiled frame")
        }
        let image = try Self.image(from: request)
        let configuration = Self.encodingConfiguration(for: request, options: options)
        let encoder = J2KEncoder(encodingConfiguration: configuration)
        let encoded: Data
        if options == nil {
            encoded = try await encoder.encode(image)
        } else {
            encoded = try await encoder.encodeResolutionLayers(image)
        }
        // The output must satisfy every constraint of the destination syntax before it is encapsulated.
        if let violation = DicomHTJ2KProfile.violation(of: request.targetTransferSyntaxUID, in: encoded) {
            throw DicomJ2KSwiftBackendError.metadataMismatch(transferSyntaxUID: request.targetTransferSyntaxUID,
                                                             reason: "the encoder output violates the syntax: \(violation)")
        }
        return encoded
    }

    static func validateEncoding(
        descriptor: DicomCompressedFrameDescriptor,
        targetTransferSyntaxUID: String,
        intent: DicomEncodingIntent
    ) throws {
        guard targetTransferSyntaxUID == descriptor.transferSyntaxUID else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "the request descriptor names transfer syntax \(descriptor.transferSyntaxUID)"
            )
        }
        if targetTransferSyntaxUID == DicomTransferSyntax.htj2kLosslessRPCL.rawValue {
            let linkedVersion = getVersion()
            guard linkedVersion == Self.coreVersion else {
                throw DicomJ2KSwiftBackendError.codecVersionMismatch(
                    expected: Self.coreVersion,
                    actual: linkedVersion
                )
            }
        }
        try validateEncodingIntent(intent, transferSyntaxUID: targetTransferSyntaxUID)
        guard descriptor.rows > 0, descriptor.columns > 0 else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "Rows and Columns must both be positive"
            )
        }
        guard descriptor.bitsAllocated == 8 || descriptor.bitsAllocated == 16,
              descriptor.bitsStored > 0,
              descriptor.bitsStored <= descriptor.bitsAllocated,
              descriptor.highBit == descriptor.bitsStored - 1 else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "Bits Allocated/Stored/High Bit are outside the qualified layout"
            )
        }
        let pixels = descriptor.rows.multipliedReportingOverflow(by: descriptor.columns)
        let samples = pixels.partialValue.multipliedReportingOverflow(by: descriptor.samplesPerPixel)
        let bytes = samples.partialValue.multipliedReportingOverflow(by: descriptor.bitsAllocated / 8)
        guard !pixels.overflow, !samples.overflow, !bytes.overflow else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "The declared frame shape exceeds the addressable byte range"
            )
        }
        let photometric = descriptor.photometricInterpretation.uppercased()
        let supportedPhotometric = descriptor.samplesPerPixel == 1
            ? photometric.isEmpty || photometric == "MONOCHROME1" || photometric == "MONOCHROME2"
            : descriptor.samplesPerPixel == 3
                && descriptor.bitsAllocated == 8
                && descriptor.bitsStored == 8
                && descriptor.pixelRepresentation == 0
                && photometric == "RGB"
        guard supportedPhotometric else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: targetTransferSyntaxUID,
                reason: "color encoding is qualified only for unsigned 8-bit RGB"
            )
        }
    }

    static func validateFullFrameDecoding(_ descriptor: DicomCompressedFrameDescriptor) throws {
        guard allFrameTransferSyntaxes.contains(descriptor.transferSyntaxUID)
            || part2TransferSyntaxes.contains(descriptor.transferSyntaxUID) else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "the transfer syntax is not a JPEG 2000 or HTJ2K frame syntax"
            )
        }
        guard descriptor.rows > 0,
              descriptor.columns > 0,
              descriptor.bitsAllocated == 8 || descriptor.bitsAllocated == 16,
              descriptor.bitsStored > 0,
              descriptor.bitsStored <= descriptor.bitsAllocated,
              descriptor.highBit == descriptor.bitsStored - 1,
              descriptor.samplesPerPixel == 1
                || descriptor.samplesPerPixel == 3
                    && descriptor.bitsAllocated == 8
                    && descriptor.bitsStored <= 8 else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: descriptor.transferSyntaxUID,
                reason: "the declared frame shape is outside the full-frame decoder limits"
            )
        }
    }

    private static func validateEncodingIntent(
        _ intent: DicomEncodingIntent,
        transferSyntaxUID: String
    ) throws {
        if case .jpegLSNearLossless = intent {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: transferSyntaxUID,
                reason: "JPEG-LS NEAR intent cannot be used for JPEG 2000 or HTJ2K"
            )
        }
        if case .jpegLossless = intent {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: transferSyntaxUID,
                reason: "JPEG lossless predictor options cannot be used for JPEG 2000 or HTJ2K"
            )
        }
        if case .jpegLS = intent {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: transferSyntaxUID,
                reason: "JPEG-LS options cannot be used for JPEG 2000 or HTJ2K"
            )
        }
        let losslessOnly = Set([
            DicomTransferSyntax.jpeg2000Lossless.rawValue,
            DicomTransferSyntax.htj2kLossless.rawValue,
            DicomTransferSyntax.htj2kLosslessRPCL.rawValue,
            DicomTransferSyntax.jpeg2000Part2MulticomponentLossless.rawValue
        ])
        if case .irreversible(let quality) = intent {
            guard !losslessOnly.contains(transferSyntaxUID) else {
                throw DicomJ2KSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: transferSyntaxUID,
                    reason: "an irreversible request cannot use a lossless-only transfer syntax"
                )
            }
            guard quality > 0, quality < 1, quality.isFinite else {
                throw DicomJ2KSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: transferSyntaxUID,
                    reason: "irreversible quality must be finite and strictly between zero and one"
                )
            }
        }
    }

    private static func image(from request: DicomFrameEncodeRequest) throws -> J2KImage {
        let frame = request.frame
        let descriptor = request.descriptor
        let uid = request.targetTransferSyntaxUID
        guard frame.width == descriptor.columns, frame.height == descriptor.rows else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "input frame is \(frame.width)x\(frame.height), expected "
                    + "\(descriptor.columns)x\(descriptor.rows)"
            )
        }
        guard frame.componentCount == descriptor.samplesPerPixel else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "input frame has \(frame.componentCount) components, expected "
                    + "\(descriptor.samplesPerPixel)"
            )
        }
        guard descriptor.bitsAllocated == 8 || descriptor.bitsAllocated == 16,
              descriptor.bitsStored <= descriptor.bitsAllocated,
              descriptor.highBit == descriptor.bitsStored - 1 else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "Bits Allocated/Stored/High Bit must be an aligned 8- or 16-bit integer layout"
            )
        }
        guard descriptor.rows > 0, descriptor.columns > 0 else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "Rows and Columns must both be positive"
            )
        }

        let pixelCountResult = descriptor.rows.multipliedReportingOverflow(by: descriptor.columns)
        guard !pixelCountResult.overflow else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "Rows and Columns exceed the addressable frame range"
            )
        }
        let pixelCount = pixelCountResult.partialValue
        let bytesPerSample = descriptor.bitsAllocated / 8
        let sampleCountResult = pixelCount.multipliedReportingOverflow(by: descriptor.samplesPerPixel)
        let expectedBytesResult = sampleCountResult.partialValue.multipliedReportingOverflow(by: bytesPerSample)
        guard !sampleCountResult.overflow, !expectedBytesResult.overflow else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "The declared frame shape exceeds the addressable byte range"
            )
        }
        let expectedBytes = expectedBytesResult.partialValue
        let bytes = frame.buffer.data
        guard bytes.count == expectedBytes else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "input frame contains \(bytes.count) bytes, expected \(expectedBytes)"
            )
        }

        let photometric = descriptor.photometricInterpretation.uppercased()
        let componentData: [Data]
        let colorSpace: J2KColorSpace
        if descriptor.samplesPerPixel == 1 {
            guard photometric.isEmpty || photometric == "MONOCHROME1" || photometric == "MONOCHROME2" else {
                throw DicomJ2KSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "single-component encoding does not accept \(descriptor.photometricInterpretation)"
                )
            }
            componentData = [bytes]
            colorSpace = .grayscale
        } else {
            guard descriptor.samplesPerPixel == 3,
                  descriptor.bitsAllocated == 8,
                  descriptor.bitsStored == 8,
                  descriptor.pixelRepresentation == 0,
                  photometric == "RGB" else {
                throw DicomJ2KSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "color encoding is qualified only for unsigned 8-bit RGB"
                )
            }
            var planes = Array(repeating: Data(count: pixelCount), count: 3)
            for pixelIndex in 0..<pixelCount {
                for componentIndex in 0..<3 {
                    planes[componentIndex][pixelIndex] = bytes[pixelIndex * 3 + componentIndex]
                }
            }
            componentData = planes
            colorSpace = .sRGB
        }

        let components = componentData.enumerated().map { index, data in
            J2KComponent(
                index: index,
                bitDepth: descriptor.bitsStored,
                signed: descriptor.pixelRepresentation == 1,
                width: descriptor.columns,
                height: descriptor.rows,
                data: data,
                sampleByteOrder: bytesPerSample == 2 ? .littleEndian : nil
            )
        }
        return J2KImage(
            width: descriptor.columns,
            height: descriptor.rows,
            components: components,
            colorSpace: colorSpace
        )
    }

    private static func encodingConfiguration(
        for request: DicomFrameEncodeRequest, options: DicomJPEG2000EncodingOptions?
    ) -> J2KEncodingConfiguration {
        let intent = request.intent
        let lossless = !intent.isLossy
        let quality: Double
        if case .irreversible(let requestedQuality) = intent {
            quality = requestedQuality
        } else {
            quality = 1
        }
        let uid = request.targetTransferSyntaxUID
        let useHTJ2K = uid == DicomTransferSyntax.htj2kLossless.rawValue
            || uid == DicomTransferSyntax.htj2kLosslessRPCL.rawValue
            || uid == DicomTransferSyntax.htj2k.rawValue
        let rpcl = uid == DicomTransferSyntax.htj2kLosslessRPCL.rawValue
        let shortestSide = max(1, min(request.descriptor.rows, request.descriptor.columns))
        // PS3.5 10.18.1 (.202): RPCL order, TLM marker and a base resolution of at most 64 samples; the other
        // syntaxes keep up to five levels bounded by the shortest side.
        let decompositionLevels = rpcl
            ? DicomHTJ2KProfile.rpclDecompositionLevels(rows: request.descriptor.rows, columns: request.descriptor.columns)
            : max(0, min(5, Int(log2(Double(shortestSide)))))
        return J2KEncodingConfiguration(
            quality: quality,
            lossless: lossless,
            decompositionLevels: options?.decompositionLevels ?? decompositionLevels,
            qualityLayers: options?.qualityLayers ?? 1,
            progressionOrder: options?.progression == .rlcp ? .rlcp : (rpcl ? .rpcl : .lrcp),
            tileSize: request.tileSize.map { (width: $0.width, height: $0.height) } ?? (0, 0),
            bitrateMode: lossless
                ? .lossless
                : .fixedQstep(qstep: max(0.0001, (1 - quality) * 0.05)),
            maxThreads: 0,
            useHTJ2K: useHTJ2K,
            useReversibleFilter: lossless,
            writeTLMMarker: rpcl
        )
    }

    /// Most decoded samples a frame may declare: the decoder holds 32-bit coefficients and output samples per
    /// sample, so 2^30 keeps a frame's working set within the addressable budget of the smallest supported device.
    static let maximumDecodedSamples = 1 << 30

    /// Refuses a SIZ that disagrees with Rows, Columns or Samples per Pixel, or that would overflow the sample count,
    /// before any allocation. A partial decode keeps its own geometry rules and only gets the size limit.
    static func checkSIZ(_ inspection: DicomJ2KCodestreamInspector.Inspection,
                         descriptor: DicomCompressedFrameDescriptor, partial: Bool) throws {
        let uid = descriptor.transferSyntaxUID
        if !partial {
            guard inspection.width == descriptor.columns, inspection.height == descriptor.rows else {
                throw DicomJ2KSwiftBackendError.metadataMismatch(
                    transferSyntaxUID: uid, reason: "the SIZ declares \(inspection.width)x\(inspection.height), "
                        + "expected \(descriptor.columns)x\(descriptor.rows)")
            }
            guard inspection.components.count == descriptor.samplesPerPixel else {
                throw DicomJ2KSwiftBackendError.metadataMismatch(
                    transferSyntaxUID: uid, reason: "the SIZ declares \(inspection.components.count) components, "
                        + "expected \(descriptor.samplesPerPixel)")
            }
        }
        let area = inspection.width.multipliedReportingOverflow(by: inspection.height)
        let samples = area.partialValue.multipliedReportingOverflow(by: inspection.components.count)
        guard !area.overflow, !samples.overflow, samples.partialValue <= maximumDecodedSamples else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid, reason: "the SIZ declares more than \(maximumDecodedSamples) samples")
        }
    }

    private static func normalizedFrame(
        from image: J2KImage,
        descriptor: DicomCompressedFrameDescriptor,
        allowsPartialDimensions: Bool = false,
        codecBytesAvoided: Int? = nil
    ) throws -> DicomCodecDecodedFrame {
        let uid = descriptor.transferSyntaxUID
        let dimensionsMatch = image.width == descriptor.columns && image.height == descriptor.rows
        let partialDimensionsAreValid = allowsPartialDimensions
            && image.width > 0 && image.height > 0
            && image.width <= descriptor.columns && image.height <= descriptor.rows
        guard dimensionsMatch || partialDimensionsAreValid else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "decoded \(image.width)x\(image.height), expected \(descriptor.columns)x\(descriptor.rows)"
            )
        }
        guard image.components.count == descriptor.samplesPerPixel else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: uid,
                reason: "decoded \(image.components.count) components, expected \(descriptor.samplesPerPixel)"
            )
        }
        guard image.components.count == 1 || image.components.count == 3 else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: uid,
                reason: "\(image.components.count) components are not representable as gray or RGB"
            )
        }

        for component in image.components {
            guard component.width == image.width, component.height == image.height,
                  component.subsamplingX == 1, component.subsamplingY == 1 else {
                throw DicomJ2KSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "component \(component.index) has subsampled or mismatched dimensions"
                )
            }
            let requiresExactPrecision = descriptor.transferSyntaxUID
                == DicomTransferSyntax.jpeg2000Lossless.rawValue
                || descriptor.transferSyntaxUID == DicomTransferSyntax.htj2kLossless.rawValue
            let precisionMatches = requiresExactPrecision
                ? component.bitDepth == descriptor.bitsStored
                : (1...descriptor.bitsStored).contains(component.bitDepth)
            // A codestream more precise than Bits Stored that still fits Bits Allocated keeps its own precision, as
            // GDCM reads it (`Osirix10vs8BitsStored`: 10-bit samples under Bits Stored 8, issue #2854).
            let exceedsBitsStoredWithinAllocation = component.bitDepth > descriptor.bitsStored
                && component.bitDepth <= descriptor.bitsAllocated
            // An 8-bit codestream under a 16-bit declaration is delivered as 8-bit samples, the pixel format GDCM
            // gives it (`SC16BitsAllocated_8BitsStoredJ2K`, issue #2856).
            let narrowsToBytes = component.bitDepth <= 8 && descriptor.bitsAllocated > 8
            guard precisionMatches || exceedsBitsStoredWithinAllocation || narrowsToBytes else {
                throw DicomJ2KSwiftBackendError.metadataMismatch(
                    transferSyntaxUID: uid,
                    reason: "component \(component.index) is \(component.bitDepth)-bit,"
                        + " incompatible with \(descriptor.bitsStored) stored bits"
                )
            }
            // A codestream whose Ssiz signedness contradicts Pixel Representation (0028,0103) is not refused:
            // the samples are reconstructed as the codestream declares them (DC level shift included) and the
            // Bits Stored bit pattern is then read under the DICOM attribute by the frame normaliser, which is
            // what GDCM, DCMTK and pydicom do (`J2K_pixelrep_mismatch`). The validator reports the
            // contradiction as `pixelMetadataContradiction` on (0028,0103).
        }

        let bitsPerSample = image.components[0].bitDepth
        let bytes: Data
        if image.components.count == 1 {
            bytes = try reinterpreted(
                normalizedGrayscaleBytes(image.components[0], transferSyntaxUID: uid),
                bitsStored: bitsPerSample,
                codestreamIsSigned: image.components[0].signed,
                pixelRepresentation: descriptor.pixelRepresentation
            )
        } else {
            guard bitsPerSample <= 8 else {
                throw DicomJ2KSwiftBackendError.unsupportedShape(
                    transferSyntaxUID: uid,
                    reason: "color output above 8 bits per component is not qualified"
                )
            }
            bytes = try interleavedColorBytes(
                image.components,
                pixelCount: image.width * image.height,
                transferSyntaxUID: uid
            )
        }

        return DicomCodecDecodedFrame(
            buffer: .owned(bytes),
            width: image.width,
            height: image.height,
            bitsPerSample: bitsPerSample,
            componentCount: image.components.count,
            codecBytesAvoided: codecBytesAvoided
        )
    }

    /// Reconciles a codestream whose Ssiz signedness contradicts Pixel Representation (0028,0103): the
    /// reconstructed sample keeps the bit pattern of its codestream precision (equal to Bits Stored for the
    /// lossless syntaxes the reader promotes) and is read under the DICOM attribute, so an
    /// unsigned codestream under Pixel Representation 1 becomes two's complement and a signed codestream under
    /// Pixel Representation 0 becomes the unsigned pattern. This is the convention of GDCM, DCMTK and pydicom
    /// (pydicom's `J2K_pixelrep_mismatch`); `DicomJ2KFrameValidator` reports the contradiction separately.
    /// Consistent objects are returned untouched.
    private static func reinterpreted(
        _ bytes: Data,
        bitsStored: Int,
        codestreamIsSigned: Bool,
        pixelRepresentation: Int
    ) -> Data {
        let declaredSigned = pixelRepresentation == 1
        guard codestreamIsSigned != declaredSigned, bitsStored >= 1, bitsStored <= 16 else { return bytes }
        let mask = (1 << bitsStored) - 1
        let signBit = 1 << (bitsStored - 1)
        func stored(_ value: Int) -> Int {
            let pattern = value & mask
            return declaredSigned && pattern & signBit != 0 ? pattern - (1 << bitsStored) : pattern
        }
        if bitsStored <= 8 {
            return Data(bytes.map { UInt8(bitPattern: Int8(truncatingIfNeeded: stored(Int($0)))) })
        }
        var output = Data(count: bytes.count)
        for index in stride(from: 0, to: bytes.count - bytes.count % 2, by: 2) {
            let raw = Int(bytes[bytes.startIndex + index]) | (Int(bytes[bytes.startIndex + index + 1]) << 8)
            let word = UInt16(bitPattern: Int16(truncatingIfNeeded: stored(raw)))
            output[index] = UInt8(word & 0xFF)
            output[index + 1] = UInt8(word >> 8)
        }
        return output
    }

    private static func normalizedGrayscaleBytes(
        _ component: J2KComponent,
        transferSyntaxUID: String
    ) throws -> Data {
        let pixelCount = component.width * component.height
        if component.bitDepth <= 8 {
            guard component.data.count == pixelCount else {
                throw DicomJ2KSwiftBackendError.metadataMismatch(
                    transferSyntaxUID: transferSyntaxUID,
                    reason: "8-bit component contains \(component.data.count) bytes for \(pixelCount) pixels"
                )
            }
            return component.data
        }

        guard component.data.count == pixelCount * 2 else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: transferSyntaxUID,
                reason: "high-bit component contains \(component.data.count) bytes for \(pixelCount) pixels"
            )
        }
        guard let sampleByteOrder = component.sampleByteOrder else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: transferSyntaxUID,
                reason: "high-bit component does not declare its sample byte order"
            )
        }
        if case .littleEndian = sampleByteOrder {
            return component.data
        }

        // The backend's decoders write little-endian (#2902); a big-endian component
        // still converts, since DICOM decoded frame buffers use little-endian bytes.
        var littleEndian = Data(count: component.data.count)
        for index in 0..<pixelCount {
            littleEndian[index * 2] = component.data[index * 2 + 1]
            littleEndian[index * 2 + 1] = component.data[index * 2]
        }
        return littleEndian
    }

    private static func interleavedColorBytes(
        _ components: [J2KComponent],
        pixelCount: Int,
        transferSyntaxUID: String
    ) throws -> Data {
        guard components.allSatisfy({ $0.data.count == pixelCount }) else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: transferSyntaxUID,
                reason: "8-bit color component byte counts do not match the image dimensions"
            )
        }
        var output = Data(count: pixelCount * 3)
        for pixelIndex in 0..<pixelCount {
            for componentIndex in 0..<3 {
                output[pixelIndex * 3 + componentIndex] = components[componentIndex].data[pixelIndex]
            }
        }
        return output
    }
}

// MARK: - JPEG 2000 Part 2 component collections (#2331)

extension DicomJ2KSwiftBackend {
    /// Decodes one component collection of a `.92/.93` object: the codestream must satisfy the syntax rules
    /// (`DicomJ2KPart2Profile`), use only array-based Annex J transformations, and stay within the component and
    /// byte bounds. Every component becomes one stored-pixel frame.
    func decodeCollection(_ codestream: Data, transferSyntaxUID: String) async throws -> DicomJ2KDecodedCollection {
        try Task.checkCancellation()
        let inspection: DicomJ2KCodestreamInspector.Inspection
        do { inspection = try DicomJ2KCodestreamInspector.inspect(codestream) } catch {
            throw DicomJ2KSwiftBackendError.unsupportedShape(transferSyntaxUID: transferSyntaxUID,
                                                             reason: "the collection is not a parseable JPEG 2000 codestream")
        }
        // A plain multi-component Part 1 codestream (no Annex J transformation, no Part 2 capabilities) is not
        // conformant to .92/.93, but it decodes unambiguously (identity transformation): the validator reports the
        // profile mismatch while the samples stay available. Every other violation is refused typed.
        let plain = !inspection.usesPart2Extensions && inspection.annexJ == nil && !inspection.usesMultipleComponentTransform
        if !plain, let violation = DicomJ2KPart2Profile.violation(of: transferSyntaxUID, in: inspection) {
            throw DicomJ2KSwiftBackendError.metadataMismatch(transferSyntaxUID: transferSyntaxUID, reason: violation)
        }
        if let reason = DicomJ2KPart2Profile.unsupportedReason(inspection) {
            throw DicomJ2KSwiftBackendError.unsupportedShape(transferSyntaxUID: transferSyntaxUID, reason: reason)
        }
        if inspection.usesMultipleComponentTransform {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the Annex G RCT/ICT (SGcod 1) cannot be applied across the frames of a .92/.93 collection")
        }
        let outputs = inspection.annexJ?.outputComponents ?? inspection.components
        guard let first = outputs.first, outputs.allSatisfy({ $0.precision == first.precision && $0.isSigned == first.isSigned }),
              first.precision >= 1, first.precision <= 16 else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(transferSyntaxUID: transferSyntaxUID,
                                                             reason: "the reconstructed components must share one 1–16-bit depth and sign")
        }
        let bytesPerSample = first.precision > 8 ? 2 : 1
        let byteCount = inspection.width.multipliedReportingOverflow(by: inspection.height)
        let total = byteCount.partialValue.multipliedReportingOverflow(by: outputs.count * bytesPerSample)
        guard !byteCount.overflow, !total.overflow, total.partialValue <= DicomJ2KPart2Profile.maximumCollectionBytes else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the collection would decode to more than \(DicomJ2KPart2Profile.maximumCollectionBytes) bytes")
        }
        let image = try await J2KDecoder(sampleByteOrder: .littleEndian).decode(codestream)
        try Task.checkCancellation()
        guard image.width == inspection.width, image.height == inspection.height, image.components.count == outputs.count else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(transferSyntaxUID: transferSyntaxUID,
                                                             reason: "decoded \(image.components.count) components of \(image.width)x\(image.height), expected \(outputs.count) of \(inspection.width)x\(inspection.height)")
        }
        var frames: [Data] = []
        frames.reserveCapacity(outputs.count)
        for component in image.components {
            guard component.bitDepth == first.precision, component.signed == first.isSigned else {
                throw DicomJ2KSwiftBackendError.metadataMismatch(transferSyntaxUID: transferSyntaxUID,
                                                                 reason: "component \(component.index) is \(component.bitDepth)-bit, expected \(first.precision)")
            }
            frames.append(try Self.normalizedGrayscaleBytes(component, transferSyntaxUID: transferSyntaxUID))
        }
        return DicomJ2KDecodedCollection(width: image.width, height: image.height, bitsPerSample: first.precision,
                                         isSigned: first.isSigned, frames: frames)
    }

    /// Encodes `frames` (stored-pixel buffers of one grayscale descriptor) as one component collection: the frames
    /// become the components of a single codestream and the own difference matrix is applied across them
    /// (reversible integer transformation; `.93` with an irreversible intent adds the 9-7 filter and quantisation).
    func encodeCollection(
        frames: [Data],
        descriptor: DicomCompressedFrameDescriptor,
        targetTransferSyntaxUID uid: String,
        intent: DicomEncodingIntent
    ) async throws -> Data {
        guard Self.part2TransferSyntaxes.contains(uid), uid == descriptor.transferSyntaxUID else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "the descriptor names transfer syntax \(descriptor.transferSyntaxUID)")
        }
        guard (1...DicomJ2KPart2Profile.maximumCollectionComponents).contains(frames.count) else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(uid: uid, reason: "a collection holds 1–\(DicomJ2KPart2Profile.maximumCollectionComponents) frames")
        }
        guard descriptor.samplesPerPixel == 1 else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(uid: uid, reason: "frames-as-components requires single-sample (grayscale) frames")
        }
        try Self.validateEncodingIntent(intent, transferSyntaxUID: uid)
        guard descriptor.rows > 0, descriptor.columns > 0, descriptor.bitsAllocated == 8 || descriptor.bitsAllocated == 16,
              descriptor.bitsStored > 0, descriptor.bitsStored <= descriptor.bitsAllocated, descriptor.highBit == descriptor.bitsStored - 1 else {
            throw DicomJ2KSwiftBackendError.unsupportedShape(uid: uid, reason: "Bits Allocated/Stored/High Bit are outside the qualified layout")
        }
        let bytesPerSample = descriptor.bitsAllocated / 8
        let expected = descriptor.rows * descriptor.columns * bytesPerSample
        let components = try frames.enumerated().map { index, frame -> J2KComponent in
            guard frame.count == expected else {
                throw DicomJ2KSwiftBackendError.unsupportedShape(uid: uid, reason: "frame \(index) holds \(frame.count) bytes, expected \(expected)")
            }
            return J2KComponent(index: index, bitDepth: descriptor.bitsStored, signed: descriptor.pixelRepresentation == 1,
                                width: descriptor.columns, height: descriptor.rows, data: frame,
                                sampleByteOrder: bytesPerSample == 2 ? .littleEndian : nil)
        }
        let lossless = !intent.isLossy
        var quality = 1.0
        if case .irreversible(let requested) = intent { quality = requested }
        let configuration = J2KEncodingConfiguration(
            quality: quality,
            lossless: lossless,
            decompositionLevels: max(0, min(5, Int(log2(Double(max(1, min(descriptor.rows, descriptor.columns))))))),
            qualityLayers: 1,
            progressionOrder: .lrcp,
            bitrateMode: lossless ? .lossless : .fixedQstep(qstep: max(0.0001, (1 - quality) * 0.05)),
            maxThreads: 0,
            useHTJ2K: false,
            useReversibleFilter: lossless,
            mctConfiguration: J2KMCTEncodingConfiguration(mode: .arrayBased(try DicomJ2KPart2Profile.differenceMatrix(count: frames.count)))
        )
        let image = J2KImage(width: descriptor.columns, height: descriptor.rows, components: components, colorSpace: .grayscale)
        let encoded = try await J2KEncoder(encodingConfiguration: configuration).encode(image)
        let inspection = try DicomJ2KCodestreamInspector.inspect(encoded)
        if let violation = DicomJ2KPart2Profile.violation(of: uid, in: inspection) {
            throw DicomJ2KSwiftBackendError.metadataMismatch(transferSyntaxUID: uid, reason: "the encoder output violates the syntax: \(violation)")
        }
        return encoded
    }
}

private extension DicomJ2KSwiftBackendError {
    static func unsupportedShape(uid: String, reason: String) -> DicomJ2KSwiftBackendError {
        .unsupportedShape(transferSyntaxUID: uid, reason: reason)
    }
}

extension DicomJ2KSwiftBackend {
    /// Synchronous entry for the frame reader's synchronous API and the transcoder's stored-frame path: the async
    /// collection decode runs on a detached task while the caller waits (callers are never on the cooperative pool).
    func decodeCollectionSynchronously(_ codestream: Data, transferSyntaxUID: String) throws -> DicomJ2KDecodedCollection {
        let box = DicomJ2KCollectionResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        let backend = self
        Task.detached(priority: .userInitiated) {
            do { box.store(.success(try await backend.decodeCollection(codestream, transferSyntaxUID: transferSyntaxUID))) }
            catch { box.store(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return try box.take().get()
    }
}

private final class DicomJ2KCollectionResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<DicomJ2KDecodedCollection, Error>?
    func store(_ value: Result<DicomJ2KDecodedCollection, Error>) { lock.lock(); result = value; lock.unlock() }
    func take() -> Result<DicomJ2KDecodedCollection, Error> {
        lock.lock(); defer { lock.unlock() }
        return result ?? .failure(DicomJ2KSwiftBackendError.unsupportedShape(transferSyntaxUID: "", reason: "the collection decode produced no result"))
    }
}
