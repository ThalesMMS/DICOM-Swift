//
//  DicomJ2KSwiftBackend.swift
//  DicomCore
//
//  Direct-Data J2KSwift CPU adapter.
//

import Foundation
import J2KCodec
import J2KCore

extension DicomCodecBackendIdentifier {
    static let j2kSwiftCPU: Self = "j2kswift-cpu"
    static let openJPEGCPU: Self = "openjpeg-cpu"
}

struct DicomJ2KSwiftBackend: DicomFrameCodecBackend {
    static let version = "11.0.2"
    static let allFrameTransferSyntaxes: Set<String> = [
        DicomTransferSyntax.jpeg2000Lossless.rawValue,
        DicomTransferSyntax.jpeg2000.rawValue,
        DicomTransferSyntax.htj2kLossless.rawValue,
        DicomTransferSyntax.htj2kLosslessRPCL.rawValue,
        DicomTransferSyntax.htj2k.rawValue
    ]
    static let qualifiedTransferSyntaxes: Set<String> = [
        DicomTransferSyntax.jpeg2000Lossless.rawValue,
        DicomTransferSyntax.jpeg2000.rawValue
    ]

    let capabilities = DicomFrameCodecCapabilities(
        identifier: .j2kSwiftCPU,
        families: [.jpeg2000, .htj2k],
        transferSyntaxUIDs: qualifiedTransferSyntaxes,
        encodeTransferSyntaxUIDs: allFrameTransferSyntaxes,
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
            supportsQualityWithSpatialReduction: false
        ),
        executionClass: .cpu,
        source: .packageLinked,
        version: version
    )

    func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame {
        try Task.checkCancellation()
        if request.partialRequest != nil,
           let reason = capabilities.unsupportedReason(for: request) {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.descriptor.transferSyntaxUID,
                reason: reason
            )
        }

        let decoder = J2KDecoder()
        let image: J2KImage
        if let partial = request.partialRequest,
           partial.region != nil || partial.resolutionLevel != nil {
            let region = partial.region.map {
                J2KRegion(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            image = try await decoder.decodePartial(
                request.frameData,
                options: J2KPartialDecodingOptions(
                    maxResolutionLevel: partial.resolutionLevel,
                    region: region
                )
            )
        } else if let layer = request.partialRequest?.maximumQualityLayer {
            image = try await decoder.decodeQuality(
                request.frameData,
                options: J2KQualityDecodingOptions(layer: layer, cumulative: true)
            )
        } else {
            image = try await decoder.decode(request.frameData)
        }
        try Task.checkCancellation()
        return try Self.normalizedFrame(
            from: image,
            descriptor: request.descriptor,
            allowsPartialDimensions: request.partialRequest != nil
        )
    }

    func encode(_ request: DicomFrameEncodeRequest) async throws -> Data {
        let descriptor = request.descriptor
        guard request.targetTransferSyntaxUID == descriptor.transferSyntaxUID else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: "the request descriptor names transfer syntax \(descriptor.transferSyntaxUID)"
            )
        }
        if let reason = capabilities.unsupportedReason(for: descriptor, operation: .encode) {
            throw DicomJ2KSwiftBackendError.unsupportedShape(
                transferSyntaxUID: request.targetTransferSyntaxUID,
                reason: reason
            )
        }
        if request.targetTransferSyntaxUID == DicomTransferSyntax.htj2kLosslessRPCL.rawValue {
            let linkedVersion = getVersion()
            guard linkedVersion == Self.version else {
                throw DicomJ2KSwiftBackendError.codecVersionMismatch(
                    expected: Self.version,
                    actual: linkedVersion
                )
            }
        }
        try Self.validateEncodingIntent(request.intent, transferSyntaxUID: request.targetTransferSyntaxUID)
        let image = try Self.image(from: request)
        let configuration = Self.encodingConfiguration(for: request)
        let encoded = try await J2KEncoder(encodingConfiguration: configuration).encode(image)
        if request.targetTransferSyntaxUID == DicomTransferSyntax.htj2kLosslessRPCL.rawValue {
            return try Self.withRPCLProgression(encoded, transferSyntaxUID: request.targetTransferSyntaxUID)
        }
        return encoded
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
        let losslessOnly = Set([
            DicomTransferSyntax.jpeg2000Lossless.rawValue,
            DicomTransferSyntax.htj2kLossless.rawValue,
            DicomTransferSyntax.htj2kLosslessRPCL.rawValue
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
        for request: DicomFrameEncodeRequest
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
        let progressionOrder: J2KProgressionOrder = uid == DicomTransferSyntax.htj2kLosslessRPCL.rawValue
            ? .rpcl
            : .lrcp
        let shortestSide = max(1, min(request.descriptor.rows, request.descriptor.columns))
        let decompositionLevels = uid == DicomTransferSyntax.htj2kLosslessRPCL.rawValue
            ? 0
            : max(0, min(5, Int(log2(Double(shortestSide)))))
        let tileSize: (width: Int, height: Int)
        if uid == DicomTransferSyntax.htj2kLosslessRPCL.rawValue {
            // Keep every tile within the default 2^15 precinct so the
            // zero-decomposition .202 route has exactly one precinct.
            let requestedWidth = request.tileSize?.width ?? request.descriptor.columns
            let requestedHeight = request.tileSize?.height ?? request.descriptor.rows
            tileSize = (
                min(max(1, requestedWidth), 32_768),
                min(max(1, requestedHeight), 32_768)
            )
        } else {
            tileSize = request.tileSize ?? (0, 0)
        }
        return J2KEncodingConfiguration(
            quality: quality,
            lossless: lossless,
            decompositionLevels: decompositionLevels,
            qualityLayers: lossless ? 1 : 5,
            progressionOrder: progressionOrder,
            tileSize: tileSize,
            bitrateMode: lossless
                ? .lossless
                : .fixedQstep(qstep: max(0.0001, (1 - quality) * 0.05)),
            maxThreads: 0,
            useHTJ2K: useHTJ2K,
            useReversibleFilter: lossless,
            htj2kBlockFormat: .conformant
        )
    }

    /// J2KSwift 11.0.2 writes its primary encoder packets as LRCP even when
    /// the configuration requests RPCL. The .202 route deliberately uses one
    /// layer, zero decompositions, and the default single precinct, making the
    /// LRCP and RPCL packet sequence equivalent. Rewriting SGcod therefore
    /// records the exact DICOM-mandated RPCL progression without reordering or
    /// relabeling a different packet sequence.
    private static func withRPCLProgression(
        _ codestream: Data,
        transferSyntaxUID: String
    ) throws -> Data {
        guard codestream.count >= 6, codestream[0] == 0xFF, codestream[1] == 0x4F else {
            throw DicomJ2KSwiftBackendError.metadataMismatch(
                transferSyntaxUID: transferSyntaxUID,
                reason: "the encoder returned a codestream without an SOC marker"
            )
        }
        var offset = 2
        while offset + 4 <= codestream.count {
            guard codestream[offset] == 0xFF else { break }
            let marker = codestream[offset + 1]
            if marker == 0x52 {
                let length = Int(codestream[offset + 2]) << 8 | Int(codestream[offset + 3])
                guard length >= 7, offset + 2 + length <= codestream.count else { break }
                var rpcl = codestream
                rpcl[offset + 5] = 2
                return rpcl
            }
            if marker == 0x90 { break }
            let length = Int(codestream[offset + 2]) << 8 | Int(codestream[offset + 3])
            guard length >= 2, offset + 2 + length <= codestream.count else { break }
            offset += 2 + length
        }
        throw DicomJ2KSwiftBackendError.metadataMismatch(
            transferSyntaxUID: transferSyntaxUID,
            reason: "the encoder returned a codestream without a valid main-header COD marker"
        )
    }

    private static func normalizedFrame(
        from image: J2KImage,
        descriptor: DicomCompressedFrameDescriptor,
        allowsPartialDimensions: Bool = false
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
            guard precisionMatches else {
                throw DicomJ2KSwiftBackendError.metadataMismatch(
                    transferSyntaxUID: uid,
                    reason: "component \(component.index) is \(component.bitDepth)-bit,"
                        + " incompatible with \(descriptor.bitsStored) stored bits"
                )
            }
            guard component.signed == (descriptor.pixelRepresentation == 1) else {
                throw DicomJ2KSwiftBackendError.metadataMismatch(
                    transferSyntaxUID: uid,
                    reason: "component \(component.index) signedness differs from Pixel Representation"
                )
            }
        }

        let bitsPerSample = image.components[0].bitDepth
        let bytes: Data
        if image.components.count == 1 {
            bytes = try normalizedGrayscaleBytes(
                image.components[0],
                transferSyntaxUID: uid
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
            componentCount: image.components.count
        )
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

        // J2KSwift tags decoder-produced 16-bit components as big-endian;
        // DICOM decoded frame buffers use little-endian stored-value bytes.
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
