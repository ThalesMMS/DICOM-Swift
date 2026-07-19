import Darwin
import Foundation

internal enum DicomJPEGLSCodec {
    struct DecodedFrame {
        let bytes: Data
        let width: Int
        let height: Int
        let bitsPerSample: Int
        let componentCount: Int
        let nearLossless: Int
    }

    static var isAvailable: Bool {
        CharLSLibrary.shared.isAvailable
    }

    static func decode(_ data: Data) throws -> DecodedFrame {
        let library = try CharLSLibrary.shared.require()
        guard let decoder = library.decoderCreate() else {
            throw DICOMError.imageProcessingFailed(operation: "JPEG-LS decode", reason: "CharLS decoder allocation failed")
        }
        defer { library.decoderDestroy(decoder) }

        try data.withUnsafeBytes { sourceBytes in
            guard let sourceAddress = sourceBytes.baseAddress else {
                throw DICOMError.invalidPixelData(reason: "JPEG-LS frame is empty")
            }
            try library.check(
                library.decoderSetSourceBuffer(decoder, sourceAddress, sourceBytes.count),
                operation: "set JPEG-LS source buffer"
            )
        }
        try library.check(library.decoderReadHeader(decoder), operation: "read JPEG-LS header")

        var frameInfo = CharLSFrameInfo()
        try withUnsafeMutablePointer(to: &frameInfo) { frameInfoPointer in
            try library.check(
                library.decoderGetFrameInfo(decoder, UnsafeMutableRawPointer(frameInfoPointer)),
                operation: "read JPEG-LS frame info"
            )
        }

        var nearLossless: Int32 = 0
        try library.check(library.decoderGetNearLossless(decoder, 0, &nearLossless), operation: "read JPEG-LS NEAR parameter")
        var interleaveMode: Int32 = 0
        try library.check(
            library.decoderGetInterleaveMode(decoder, &interleaveMode),
            operation: "read JPEG-LS interleave mode"
        )

        var destinationSize = 0
        try library.check(
            library.decoderGetDestinationSize(decoder, 0, &destinationSize),
            operation: "read JPEG-LS destination size"
        )
        guard destinationSize > 0 else {
            throw DICOMError.invalidPixelData(reason: "JPEG-LS decoder reported an empty destination buffer")
        }

        var decoded = Data(count: destinationSize)
        try decoded.withUnsafeMutableBytes { destinationBytes in
            guard let destinationAddress = destinationBytes.baseAddress else {
                throw DICOMError.memoryAllocationFailed(requestedSize: Int64(destinationSize))
            }
            try library.check(
                library.decoderDecodeToBuffer(decoder, destinationAddress, destinationSize, 0),
                operation: "decode JPEG-LS frame"
            )
        }

        return DecodedFrame(
            bytes: try normalizedColorBytes(
                decoded,
                frameInfo: frameInfo,
                interleaveMode: interleaveMode
            ),
            width: Int(frameInfo.width),
            height: Int(frameInfo.height),
            bitsPerSample: Int(frameInfo.bitsPerSample),
            componentCount: Int(frameInfo.componentCount),
            nearLossless: Int(nearLossless)
        )
    }

    private static func normalizedColorBytes(
        _ decoded: Data,
        frameInfo: CharLSFrameInfo,
        interleaveMode: Int32
    ) throws -> Data {
        let componentCount = Int(frameInfo.componentCount)
        guard componentCount > 1 else { return decoded }
        guard componentCount == 3, (0...2).contains(interleaveMode) else {
            throw DICOMError.invalidPixelData(
                reason: "JPEG-LS color output has unsupported interleave mode \(interleaveMode)"
            )
        }
        // CharLS materializes line- and sample-interleaved scans as RGBRGB.
        // Only non-interleaved scans retain three contiguous component planes.
        guard interleaveMode == 0 else { return decoded }
        let width = Int(frameInfo.width)
        let height = Int(frameInfo.height)
        let pixelCountResult = width.multipliedReportingOverflow(by: height)
        let bytesPerSample = Int(frameInfo.bitsPerSample) <= 8 ? 1 : 2
        let sampleCountResult = pixelCountResult.partialValue.multipliedReportingOverflow(by: componentCount)
        let byteCountResult = sampleCountResult.partialValue.multipliedReportingOverflow(by: bytesPerSample)
        guard !pixelCountResult.overflow,
              !sampleCountResult.overflow,
              !byteCountResult.overflow,
              decoded.count == byteCountResult.partialValue else {
            throw DICOMError.invalidPixelData(reason: "JPEG-LS color output size does not match its frame header")
        }

        let source = [UInt8](decoded)
        var destination = [UInt8](repeating: 0, count: source.count)
        let pixelCount = pixelCountResult.partialValue
        for pixel in 0..<pixelCount {
            for component in 0..<componentCount {
                let sourceSample = component * pixelCount + pixel
                let destinationSample = pixel * componentCount + component
                for byte in 0..<bytesPerSample {
                    destination[destinationSample * bytesPerSample + byte] = source[sourceSample * bytesPerSample + byte]
                }
            }
        }
        return Data(destination)
    }

    static func encodeForTesting(
        bytes: Data,
        width: Int,
        height: Int,
        bitsPerSample: Int,
        componentCount: Int = 1,
        nearLossless: Int = 0
    ) throws -> Data {
        try encode(
            bytes: bytes,
            width: width,
            height: height,
            bitsPerSample: bitsPerSample,
            componentCount: componentCount,
            nearLossless: nearLossless
        )
    }

    /// Encodes one frame as a JPEG-LS codestream through the preflighted
    /// CharLS runtime (used by the #1237 transcoding route).
    static func encode(
        bytes: Data,
        width: Int,
        height: Int,
        bitsPerSample: Int,
        componentCount: Int = 1,
        nearLossless: Int = 0
    ) throws -> Data {
        let library = try CharLSLibrary.shared.require()
        guard let encoder = library.encoderCreate() else {
            throw DICOMError.imageProcessingFailed(operation: "JPEG-LS encode", reason: "CharLS encoder allocation failed")
        }
        defer { library.encoderDestroy(encoder) }

        var frameInfo = CharLSFrameInfo(
            width: UInt32(width),
            height: UInt32(height),
            bitsPerSample: Int32(bitsPerSample),
            componentCount: Int32(componentCount)
        )
        try withUnsafePointer(to: &frameInfo) { frameInfoPointer in
            try library.check(
                library.encoderSetFrameInfo(encoder, UnsafeRawPointer(frameInfoPointer)),
                operation: "set JPEG-LS frame info"
            )
        }
        try library.check(library.encoderSetNearLossless(encoder, Int32(nearLossless)), operation: "set JPEG-LS NEAR parameter")
        try library.check(library.encoderSetInterleaveMode(encoder, componentCount == 1 ? 0 : 2), operation: "set JPEG-LS interleave mode")

        var estimatedSize = 0
        try library.check(library.encoderGetEstimatedDestinationSize(encoder, &estimatedSize), operation: "estimate JPEG-LS size")
        guard estimatedSize > 0 else {
            throw DICOMError.invalidPixelData(reason: "CharLS estimated an empty JPEG-LS output")
        }

        var encoded = Data(count: estimatedSize)
        try encoded.withUnsafeMutableBytes { destinationBytes in
            guard let destinationAddress = destinationBytes.baseAddress else {
                throw DICOMError.memoryAllocationFailed(requestedSize: Int64(estimatedSize))
            }
            try library.check(
                library.encoderSetDestinationBuffer(encoder, destinationAddress, estimatedSize),
                operation: "set JPEG-LS destination buffer"
            )
        }

        try bytes.withUnsafeBytes { sourceBytes in
            guard let sourceAddress = sourceBytes.baseAddress else {
                throw DICOMError.invalidPixelData(reason: "JPEG-LS source pixels are empty")
            }
            try library.check(
                library.encoderEncodeFromBuffer(encoder, sourceAddress, sourceBytes.count, 0),
                operation: "encode JPEG-LS frame"
            )
        }

        var bytesWritten = 0
        try library.check(library.encoderGetBytesWritten(encoder, &bytesWritten), operation: "read JPEG-LS encoded size")
        guard bytesWritten > 0, bytesWritten <= encoded.count else {
            throw DICOMError.invalidPixelData(reason: "CharLS returned invalid encoded size \(bytesWritten)")
        }
        encoded.removeSubrange(bytesWritten..<encoded.count)
        return encoded
    }
}

private struct CharLSFrameInfo {
    var width: UInt32 = 0
    var height: UInt32 = 0
    var bitsPerSample: Int32 = 0
    var componentCount: Int32 = 0
}

private final class CharLSLibrary {
    static let shared = CharLSLibrary()

    typealias DecoderCreate = @convention(c) () -> OpaquePointer?
    typealias DecoderDestroy = @convention(c) (OpaquePointer?) -> Void
    typealias DecoderSetSourceBuffer = @convention(c) (OpaquePointer, UnsafeRawPointer?, Int) -> Int32
    typealias DecoderReadHeader = @convention(c) (OpaquePointer) -> Int32
    typealias DecoderGetFrameInfo = @convention(c) (OpaquePointer, UnsafeMutableRawPointer?) -> Int32
    typealias DecoderGetNearLossless = @convention(c) (OpaquePointer, Int32, UnsafeMutablePointer<Int32>) -> Int32
    typealias DecoderGetInterleaveMode = @convention(c) (OpaquePointer, UnsafeMutablePointer<Int32>) -> Int32
    typealias DecoderGetDestinationSize = @convention(c) (OpaquePointer, UInt32, UnsafeMutablePointer<Int>) -> Int32
    typealias DecoderDecodeToBuffer = @convention(c) (OpaquePointer, UnsafeMutableRawPointer?, Int, UInt32) -> Int32

    typealias EncoderCreate = @convention(c) () -> OpaquePointer?
    typealias EncoderDestroy = @convention(c) (OpaquePointer?) -> Void
    typealias EncoderSetFrameInfo = @convention(c) (OpaquePointer, UnsafeRawPointer?) -> Int32
    typealias EncoderSetNearLossless = @convention(c) (OpaquePointer, Int32) -> Int32
    typealias EncoderSetInterleaveMode = @convention(c) (OpaquePointer, Int32) -> Int32
    typealias EncoderGetEstimatedDestinationSize = @convention(c) (OpaquePointer, UnsafeMutablePointer<Int>) -> Int32
    typealias EncoderSetDestinationBuffer = @convention(c) (OpaquePointer, UnsafeMutableRawPointer?, Int) -> Int32
    typealias EncoderEncodeFromBuffer = @convention(c) (OpaquePointer, UnsafeRawPointer?, Int, UInt32) -> Int32
    typealias EncoderGetBytesWritten = @convention(c) (OpaquePointer, UnsafeMutablePointer<Int>) -> Int32
    typealias GetErrorMessage = @convention(c) (Int32) -> UnsafePointer<CChar>?

    let handle: UnsafeMutableRawPointer?
    let runtimeStatus: DicomCodecRuntimeStatus
    let missingSymbols: [String]
    let version: String?

    let decoderCreate: DecoderCreate
    let decoderDestroy: DecoderDestroy
    let decoderSetSourceBuffer: DecoderSetSourceBuffer
    let decoderReadHeader: DecoderReadHeader
    let decoderGetFrameInfo: DecoderGetFrameInfo
    let decoderGetNearLossless: DecoderGetNearLossless
    let decoderGetInterleaveMode: DecoderGetInterleaveMode
    let decoderGetDestinationSize: DecoderGetDestinationSize
    let decoderDecodeToBuffer: DecoderDecodeToBuffer

    let encoderCreate: EncoderCreate
    let encoderDestroy: EncoderDestroy
    let encoderSetFrameInfo: EncoderSetFrameInfo
    let encoderSetNearLossless: EncoderSetNearLossless
    let encoderSetInterleaveMode: EncoderSetInterleaveMode
    let encoderGetEstimatedDestinationSize: EncoderGetEstimatedDestinationSize
    let encoderSetDestinationBuffer: EncoderSetDestinationBuffer
    let encoderEncodeFromBuffer: EncoderEncodeFromBuffer
    let encoderGetBytesWritten: EncoderGetBytesWritten
    let getErrorMessage: GetErrorMessage

    var isAvailable: Bool {
        runtimeStatus.isAvailable && missingSymbols.isEmpty
    }

    private init() {
        let resolution = DicomCodecRuntimePreflight.resolve(for: .charLS, retainHandle: true)
        handle = resolution.handle
        runtimeStatus = resolution.status
        var unresolvedSymbols: [String] = []

        decoderCreate = Self.load(
            "charls_jpegls_decoder_create",
            from: handle,
            as: DecoderCreate.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableDecoderCreate
        )
        decoderDestroy = Self.load(
            "charls_jpegls_decoder_destroy",
            from: handle,
            as: DecoderDestroy.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableDecoderDestroy
        )
        decoderSetSourceBuffer = Self.load(
            "charls_jpegls_decoder_set_source_buffer",
            from: handle,
            as: DecoderSetSourceBuffer.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableDecoderSetSourceBuffer
        )
        decoderReadHeader = Self.load(
            "charls_jpegls_decoder_read_header",
            from: handle,
            as: DecoderReadHeader.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableDecoderReadHeader
        )
        decoderGetFrameInfo = Self.load(
            "charls_jpegls_decoder_get_frame_info",
            from: handle,
            as: DecoderGetFrameInfo.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableDecoderGetFrameInfo
        )
        decoderGetNearLossless = Self.load(
            "charls_jpegls_decoder_get_near_lossless",
            from: handle,
            as: DecoderGetNearLossless.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableDecoderGetNearLossless
        )
        decoderGetInterleaveMode = Self.load(
            "charls_jpegls_decoder_get_interleave_mode",
            from: handle,
            as: DecoderGetInterleaveMode.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableDecoderGetInterleaveMode
        )
        decoderGetDestinationSize = Self.load(
            "charls_jpegls_decoder_get_destination_size",
            from: handle,
            as: DecoderGetDestinationSize.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableDecoderGetDestinationSize
        )
        decoderDecodeToBuffer = Self.load(
            "charls_jpegls_decoder_decode_to_buffer",
            from: handle,
            as: DecoderDecodeToBuffer.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableDecoderDecodeToBuffer
        )

        encoderCreate = Self.load(
            "charls_jpegls_encoder_create",
            from: handle,
            as: EncoderCreate.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableEncoderCreate
        )
        encoderDestroy = Self.load(
            "charls_jpegls_encoder_destroy",
            from: handle,
            as: EncoderDestroy.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableEncoderDestroy
        )
        encoderSetFrameInfo = Self.load(
            "charls_jpegls_encoder_set_frame_info",
            from: handle,
            as: EncoderSetFrameInfo.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableEncoderSetFrameInfo
        )
        encoderSetNearLossless = Self.load(
            "charls_jpegls_encoder_set_near_lossless",
            from: handle,
            as: EncoderSetNearLossless.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableEncoderSetNearLossless
        )
        encoderSetInterleaveMode = Self.load(
            "charls_jpegls_encoder_set_interleave_mode",
            from: handle,
            as: EncoderSetInterleaveMode.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableEncoderSetInterleaveMode
        )
        encoderGetEstimatedDestinationSize = Self.load(
            "charls_jpegls_encoder_get_estimated_destination_size",
            from: handle,
            as: EncoderGetEstimatedDestinationSize.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableEncoderGetEstimatedDestinationSize
        )
        encoderSetDestinationBuffer = Self.load(
            "charls_jpegls_encoder_set_destination_buffer",
            from: handle,
            as: EncoderSetDestinationBuffer.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableEncoderSetDestinationBuffer
        )
        encoderEncodeFromBuffer = Self.load(
            "charls_jpegls_encoder_encode_from_buffer",
            from: handle,
            as: EncoderEncodeFromBuffer.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableEncoderEncodeFromBuffer
        )
        encoderGetBytesWritten = Self.load(
            "charls_jpegls_encoder_get_bytes_written",
            from: handle,
            as: EncoderGetBytesWritten.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableEncoderGetBytesWritten
        )
        getErrorMessage = Self.load(
            "charls_get_error_message",
            from: handle,
            as: GetErrorMessage.self,
            missingSymbols: &unresolvedSymbols,
            fallback: Self.unavailableGetErrorMessage
        )
        missingSymbols = Array(Set(runtimeStatus.missingSymbols + unresolvedSymbols)).sorted()
        version = handle.flatMap { DicomCodecCapabilities.version(fromHandle: $0, runtime: .charLS) }
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }

    func require() throws -> CharLSLibrary {
        guard handle != nil else {
            throw DICOMError.unsupportedTransferSyntax(syntax: runtimeStatus.message)
        }
        guard missingSymbols.isEmpty else {
            throw DICOMError.unsupportedTransferSyntax(
                syntax: "JPEG-LS CharLS runtime is missing required symbols: \(missingSymbols.joined(separator: ", "))"
            )
        }
        if let version,
           let major = DicomCodecCapabilities.majorVersion(of: version),
           major != DicomCodecCapabilities.supportedMajorVersion {
            throw DICOMError.unsupportedTransferSyntax(
                syntax: "JPEG-LS CharLS runtime version \(version) is incompatible; "
                    + "major version \(DicomCodecCapabilities.supportedMajorVersion) is required"
            )
        }
        return self
    }

    func check(_ code: Int32, operation: String) throws {
        guard code == 0 else {
            let message = getErrorMessage(code).map { String(cString: $0) } ?? "CharLS error \(code)"
            throw DICOMError.imageProcessingFailed(operation: operation, reason: message)
        }
    }

    private static func load<T>(
        _ name: String,
        from handle: UnsafeMutableRawPointer?,
        as type: T.Type,
        missingSymbols: inout [String],
        fallback: T
    ) -> T {
        guard let handle else {
            return fallback
        }
        guard let symbol = dlsym(handle, name) else {
            missingSymbols.append(name)
            return fallback
        }
        return unsafeBitCast(symbol, to: type)
    }

    private static let unavailableDecoderCreate: DecoderCreate = { nil }
    private static let unavailableDecoderDestroy: DecoderDestroy = { _ in }
    private static let unavailableDecoderSetSourceBuffer: DecoderSetSourceBuffer = { _, _, _ in -1 }
    private static let unavailableDecoderReadHeader: DecoderReadHeader = { _ in -1 }
    private static let unavailableDecoderGetFrameInfo: DecoderGetFrameInfo = { _, _ in -1 }
    private static let unavailableDecoderGetNearLossless: DecoderGetNearLossless = { _, _, _ in -1 }
    private static let unavailableDecoderGetInterleaveMode: DecoderGetInterleaveMode = { _, _ in -1 }
    private static let unavailableDecoderGetDestinationSize: DecoderGetDestinationSize = { _, _, _ in -1 }
    private static let unavailableDecoderDecodeToBuffer: DecoderDecodeToBuffer = { _, _, _, _ in -1 }
    private static let unavailableEncoderCreate: EncoderCreate = { nil }
    private static let unavailableEncoderDestroy: EncoderDestroy = { _ in }
    private static let unavailableEncoderSetFrameInfo: EncoderSetFrameInfo = { _, _ in -1 }
    private static let unavailableEncoderSetNearLossless: EncoderSetNearLossless = { _, _ in -1 }
    private static let unavailableEncoderSetInterleaveMode: EncoderSetInterleaveMode = { _, _ in -1 }
    private static let unavailableEncoderGetEstimatedDestinationSize: EncoderGetEstimatedDestinationSize = { _, _ in -1 }
    private static let unavailableEncoderSetDestinationBuffer: EncoderSetDestinationBuffer = { _, _, _ in -1 }
    private static let unavailableEncoderEncodeFromBuffer: EncoderEncodeFromBuffer = { _, _, _, _ in -1 }
    private static let unavailableEncoderGetBytesWritten: EncoderGetBytesWritten = { _, _ in -1 }
    private static let unavailableGetErrorMessage: GetErrorMessage = { _ in nil }
}
