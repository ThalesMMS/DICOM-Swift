//
//  DicomFrameCodecBackend.swift
//  DicomCore
//
//  Codec-neutral compressed-frame boundary. Concrete codec package types
//  stay behind adapters that implement DicomFrameCodecBackend.
//

import Foundation

struct DicomCodecBackendIdentifier: RawRepresentable, Hashable, Codable, Sendable,
    ExpressibleByStringLiteral {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

enum DicomCodecFamily: String, CaseIterable, Codable, Hashable, Sendable {
    case rle
    case jpeg
    case jpegLS = "jpeg-ls"
    case jpeg2000 = "jpeg-2000"
    case htj2k
    case jpegXL = "jpeg-xl"

    static func family(for transferSyntax: DicomTransferSyntax) -> DicomCodecFamily? {
        switch transferSyntax {
        case .rleLossless:
            return .rle
        case .jpegBaseline, .jpegExtended, .jpegLossless, .jpegLosslessFirstOrder:
            return .jpeg
        case .jpegLSLossless, .jpegLSNearLossless:
            return .jpegLS
        case .jpeg2000Lossless, .jpeg2000,
             .jpeg2000Part2MulticomponentLossless, .jpeg2000Part2Multicomponent:
            return .jpeg2000
        case .htj2kLossless, .htj2kLosslessRPCL, .htj2k:
            return .htj2k
        case .jpegXLLossless, .jpegXLJPEGRecompression, .jpegXL:
            return .jpegXL
        case .implicitVRLittleEndian, .explicitVRLittleEndian, .deflatedExplicitVRLittleEndian,
             .explicitVRBigEndian, .jpipReferenced, .jpipReferencedDeflate,
             .mpeg2MainProfileMainLevel, .mpeg2MainProfileMainLevelFragmentable,
             .mpeg2MainProfileHighLevel, .mpeg2MainProfileHighLevelFragmentable,
             .mpeg4AVCH264HighProfileLevel41, .mpeg4AVCH264HighProfileLevel41Fragmentable,
             .mpeg4AVCH264BDCompatibleHighProfileLevel41,
             .mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable,
             .mpeg4AVCH264HighProfileLevel42For2DVideo,
             .mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable,
             .mpeg4AVCH264HighProfileLevel42For3DVideo,
             .mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable,
             .mpeg4AVCH264StereoHighProfileLevel42,
             .mpeg4AVCH264StereoHighProfileLevel42Fragmentable,
             .hevcH265MainProfileLevel51, .hevcH265Main10ProfileLevel51:
            return nil
        }
    }
}

enum DicomCodecOperation: String, Codable, Hashable, Sendable {
    case decode
    case encode
}

enum DicomCodecExecutionClass: String, Codable, Hashable, Sendable {
    case cpu
    case metal
}

enum DicomCodecOutputOwnership: String, Codable, Hashable, Sendable {
    case ownedData = "owned-data"
    case sharedBuffer = "shared-buffer"
}

struct DicomPartialDecodeCapabilities: Equatable, Codable, Sendable {
    let supportsRegionOfInterest: Bool
    let supportsResolutionLevels: Bool
    let supportsQualityLayers: Bool
    let supportsCombinedRegionAndResolution: Bool
    let supportsQualityWithSpatialReduction: Bool

    init(
        supportsRegionOfInterest: Bool = false,
        supportsResolutionLevels: Bool = false,
        supportsQualityLayers: Bool = false,
        supportsCombinedRegionAndResolution: Bool = false,
        supportsQualityWithSpatialReduction: Bool = false
    ) {
        self.supportsRegionOfInterest = supportsRegionOfInterest
        self.supportsResolutionLevels = supportsResolutionLevels
        self.supportsQualityLayers = supportsQualityLayers
        self.supportsCombinedRegionAndResolution = supportsCombinedRegionAndResolution
        self.supportsQualityWithSpatialReduction = supportsQualityWithSpatialReduction
    }

    static let none = DicomPartialDecodeCapabilities()
}

struct DicomFrameCodecCapabilities: Equatable, Sendable {
    let identifier: DicomCodecBackendIdentifier
    let families: Set<DicomCodecFamily>
    let transferSyntaxUIDs: Set<String>
    let encodeTransferSyntaxUIDs: Set<String>
    let operations: Set<DicomCodecOperation>
    let supportedGrayscaleBitDepths: ClosedRange<Int>
    let supportedColorBitDepths: ClosedRange<Int>
    let maximumComponents: Int
    let supportsSignedSamples: Bool
    let partialDecode: DicomPartialDecodeCapabilities
    let executionClass: DicomCodecExecutionClass
    let outputOwnership: DicomCodecOutputOwnership
    let source: DicomCodecBackendSource
    let version: String?
    let isAvailable: Bool
    let unsupportedReason: String?

    init(
        identifier: DicomCodecBackendIdentifier,
        families: Set<DicomCodecFamily>,
        transferSyntaxUIDs: Set<String>,
        encodeTransferSyntaxUIDs: Set<String> = [],
        operations: Set<DicomCodecOperation> = [.decode],
        supportedGrayscaleBitDepths: ClosedRange<Int>,
        supportedColorBitDepths: ClosedRange<Int> = 1...8,
        maximumComponents: Int = 3,
        supportsSignedSamples: Bool = true,
        partialDecode: DicomPartialDecodeCapabilities = .none,
        executionClass: DicomCodecExecutionClass,
        outputOwnership: DicomCodecOutputOwnership = .ownedData,
        source: DicomCodecBackendSource,
        version: String? = nil,
        isAvailable: Bool = true,
        unsupportedReason: String? = nil
    ) {
        self.identifier = identifier
        self.families = families
        self.transferSyntaxUIDs = transferSyntaxUIDs
        self.encodeTransferSyntaxUIDs = encodeTransferSyntaxUIDs
        self.operations = operations
        self.supportedGrayscaleBitDepths = supportedGrayscaleBitDepths
        self.supportedColorBitDepths = supportedColorBitDepths
        self.maximumComponents = maximumComponents
        self.supportsSignedSamples = supportsSignedSamples
        self.partialDecode = partialDecode
        self.executionClass = executionClass
        self.outputOwnership = outputOwnership
        self.source = source
        self.version = version
        self.isAvailable = isAvailable
        self.unsupportedReason = unsupportedReason
    }

    func unsupportedReason(for descriptor: DicomCompressedFrameDescriptor) -> String? {
        unsupportedReason(for: descriptor, operation: .decode)
    }

    func unsupportedReason(
        for descriptor: DicomCompressedFrameDescriptor,
        operation: DicomCodecOperation
    ) -> String? {
        guard isAvailable else {
            return unsupportedReason ?? "Backend \(identifier.rawValue) is unavailable."
        }
        guard operations.contains(operation) else {
            return "Backend \(identifier.rawValue) does not support \(operation.rawValue)."
        }
        let syntaxUIDs = operation == .encode ? encodeTransferSyntaxUIDs : transferSyntaxUIDs
        guard syntaxUIDs.contains(descriptor.transferSyntaxUID) else {
            return "Backend \(identifier.rawValue) does not support \(operation.rawValue) for transfer syntax "
                + "\(descriptor.transferSyntaxUID)."
        }
        guard descriptor.samplesPerPixel <= maximumComponents else {
            return "Backend \(identifier.rawValue) supports at most \(maximumComponents) components."
        }
        let supportedDepths = descriptor.samplesPerPixel > 1
            ? supportedColorBitDepths
            : supportedGrayscaleBitDepths
        guard supportedDepths.contains(descriptor.bitsStored) else {
            return "Backend \(identifier.rawValue) does not support \(descriptor.bitsStored)-bit output."
        }
        guard descriptor.pixelRepresentation != 1 || supportsSignedSamples else {
            return "Backend \(identifier.rawValue) does not support signed samples."
        }
        return nil
    }

    func unsupportedReason(for request: DicomFrameDecodeRequest) -> String? {
        if let reason = unsupportedReason(for: request.descriptor) {
            return reason
        }
        guard let partialRequest = request.partialRequest else { return nil }
        if partialRequest.region != nil, !partialDecode.supportsRegionOfInterest {
            return "Backend \(identifier.rawValue) does not support ROI decode."
        }
        if partialRequest.resolutionLevel != nil, !partialDecode.supportsResolutionLevels {
            return "Backend \(identifier.rawValue) does not support resolution-level decode."
        }
        if partialRequest.maximumQualityLayer != nil, !partialDecode.supportsQualityLayers {
            return "Backend \(identifier.rawValue) does not support quality-layer decode."
        }
        let hasRegion = partialRequest.region != nil
        let hasResolution = partialRequest.resolutionLevel != nil
        if hasRegion, hasResolution, !partialDecode.supportsCombinedRegionAndResolution {
            return "Backend \(identifier.rawValue) does not combine ROI and resolution-level decode."
        }
        if partialRequest.maximumQualityLayer != nil,
           (hasRegion || hasResolution),
           !partialDecode.supportsQualityWithSpatialReduction {
            return "Backend \(identifier.rawValue) does not combine quality and spatial partial decode."
        }
        return nil
    }
}

struct DicomCompressedFrameDescriptor: Equatable, Sendable {
    let transferSyntaxUID: String
    let rows: Int
    let columns: Int
    let bitsAllocated: Int
    let bitsStored: Int
    let highBit: Int
    let pixelRepresentation: Int
    let samplesPerPixel: Int
    let photometricInterpretation: String
    let planarConfiguration: Int?

    init(
        transferSyntaxUID: String,
        rows: Int,
        columns: Int,
        bitsAllocated: Int,
        bitsStored: Int,
        highBit: Int,
        pixelRepresentation: Int,
        samplesPerPixel: Int,
        photometricInterpretation: String,
        planarConfiguration: Int?
    ) {
        self.transferSyntaxUID = transferSyntaxUID
        self.rows = rows
        self.columns = columns
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.pixelRepresentation = pixelRepresentation
        self.samplesPerPixel = samplesPerPixel
        self.photometricInterpretation = photometricInterpretation
        self.planarConfiguration = planarConfiguration
    }
}

struct DicomPartialDecodeRequest: Equatable, Sendable {
    struct Region: Equatable, Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    let region: Region?
    let resolutionLevel: Int?
    let maximumQualityLayer: Int?

    init(region: Region? = nil, resolutionLevel: Int? = nil, maximumQualityLayer: Int? = nil) {
        self.region = region
        self.resolutionLevel = resolutionLevel
        self.maximumQualityLayer = maximumQualityLayer
    }
}

enum DicomCodecBackendPreference: Equatable, Sendable {
    case automatic
    case preferred(DicomCodecBackendIdentifier, allowsFallback: Bool)
}

struct DicomFrameDecodeRequest: Sendable {
    let frameData: Data
    let descriptor: DicomCompressedFrameDescriptor
    let frameIndex: Int
    let partialRequest: DicomPartialDecodeRequest?
    let backendPreference: DicomCodecBackendPreference

    init(
        frameData: Data,
        descriptor: DicomCompressedFrameDescriptor,
        frameIndex: Int,
        partialRequest: DicomPartialDecodeRequest? = nil,
        backendPreference: DicomCodecBackendPreference = .automatic
    ) {
        self.frameData = frameData
        self.descriptor = descriptor
        self.frameIndex = frameIndex
        self.partialRequest = partialRequest
        self.backendPreference = backendPreference
    }
}

final class DicomSharedFrameBuffer: @unchecked Sendable {
    let data: Data

    init(data: Data) {
        self.data = data
    }
}

enum DicomCodecFrameBuffer: Sendable {
    case owned(Data)
    case shared(DicomSharedFrameBuffer)

    var data: Data {
        switch self {
        case .owned(let data): return data
        case .shared(let buffer): return buffer.data
        }
    }
}

struct DicomCodecDecodedFrame: Sendable {
    let buffer: DicomCodecFrameBuffer
    let width: Int
    let height: Int
    let bitsPerSample: Int
    let componentCount: Int

    init(
        buffer: DicomCodecFrameBuffer,
        width: Int,
        height: Int,
        bitsPerSample: Int,
        componentCount: Int
    ) {
        self.buffer = buffer
        self.width = width
        self.height = height
        self.bitsPerSample = bitsPerSample
        self.componentCount = componentCount
    }
}

struct DicomFrameEncodeRequest: Sendable {
    let frame: DicomCodecDecodedFrame
    let descriptor: DicomCompressedFrameDescriptor
    let targetTransferSyntaxUID: String
    let intent: DicomEncodingIntent
    let tileSize: (width: Int, height: Int)?

    init(
        frame: DicomCodecDecodedFrame,
        descriptor: DicomCompressedFrameDescriptor,
        targetTransferSyntaxUID: String,
        intent: DicomEncodingIntent = .reversible,
        tileSize: (width: Int, height: Int)? = nil
    ) {
        self.frame = frame
        self.descriptor = descriptor
        self.targetTransferSyntaxUID = targetTransferSyntaxUID
        self.intent = intent
        self.tileSize = tileSize
    }
}

enum DicomFrameCodecBackendError: Error, Equatable, LocalizedError, Sendable {
    case encodeUnsupported(backend: DicomCodecBackendIdentifier)

    var errorDescription: String? {
        switch self {
        case .encodeUnsupported(let backend):
            return "Codec backend \(backend.rawValue) does not support encoding."
        }
    }
}

protocol DicomFrameCodecBackend: Sendable {
    var capabilities: DicomFrameCodecCapabilities { get }
    func decode(_ request: DicomFrameDecodeRequest) async throws -> DicomCodecDecodedFrame
    func encode(_ request: DicomFrameEncodeRequest) async throws -> Data
}

extension DicomFrameCodecBackend {
    func encode(_ request: DicomFrameEncodeRequest) async throws -> Data {
        throw DicomFrameCodecBackendError.encodeUnsupported(backend: capabilities.identifier)
    }
}

struct DicomCodecShadowPolicy: Sendable {
    let candidatesByFamily: [DicomCodecFamily: DicomCodecBackendIdentifier]

    init(candidatesByFamily: [DicomCodecFamily: DicomCodecBackendIdentifier] = [:]) {
        self.candidatesByFamily = candidatesByFamily
    }

    static let disabled = DicomCodecShadowPolicy()
}

struct DicomCodecSelectionDiagnostics: Equatable, Sendable {
    let selectedBackend: DicomCodecBackendIdentifier
    let selectedSource: DicomCodecBackendSource
    let selectedVersion: String?
    let fallbackReason: String?
    let shadowBackend: DicomCodecBackendIdentifier?

    init(
        selectedBackend: DicomCodecBackendIdentifier,
        selectedSource: DicomCodecBackendSource,
        selectedVersion: String?,
        fallbackReason: String?,
        shadowBackend: DicomCodecBackendIdentifier?
    ) {
        self.selectedBackend = selectedBackend
        self.selectedSource = selectedSource
        self.selectedVersion = selectedVersion
        self.fallbackReason = fallbackReason
        self.shadowBackend = shadowBackend
    }
}

struct DicomFrameCodecSelection: Sendable {
    let production: any DicomFrameCodecBackend
    let shadow: (any DicomFrameCodecBackend)?
    let diagnostics: DicomCodecSelectionDiagnostics
}

enum DicomCodecSelectionError: Error, Equatable, LocalizedError, Sendable {
    case unsupported(transferSyntaxUID: String, reasons: [String])

    var errorDescription: String? {
        switch self {
        case .unsupported(let uid, let reasons):
            return "No codec backend supports transfer syntax \(uid): \(reasons.joined(separator: " "))"
        }
    }
}

struct DicomFrameCodecRegistry: Sendable {
    private let backends: [any DicomFrameCodecBackend]

    init(backends: [any DicomFrameCodecBackend]) {
        self.backends = backends
    }

    var capabilities: [DicomFrameCodecCapabilities] {
        backends.map(\.capabilities)
    }

    func select(
        for request: DicomFrameDecodeRequest,
        shadowPolicy: DicomCodecShadowPolicy = .disabled
    ) throws -> DicomFrameCodecSelection {
        let evaluations = backends.map { backend in
            (backend, backend.capabilities.unsupportedReason(for: request))
        }
        let eligible = evaluations.filter { $0.1 == nil }.map(\.0)
        let production: any DicomFrameCodecBackend
        var fallbackReason: String?

        switch request.backendPreference {
        case .automatic:
            guard let first = eligible.first else {
                throw unsupportedError(for: request, evaluations: evaluations)
            }
            production = first
        case .preferred(let identifier, let allowsFallback):
            if let preferred = eligible.first(where: { $0.capabilities.identifier == identifier }) {
                production = preferred
            } else if allowsFallback, let first = eligible.first {
                production = first
                let reason = evaluations.first { $0.0.capabilities.identifier == identifier }?.1
                    ?? "Requested backend \(identifier.rawValue) is not registered."
                fallbackReason = reason
            } else {
                throw unsupportedError(for: request, evaluations: evaluations)
            }
        }

        let family = DicomTransferSyntax(uid: request.descriptor.transferSyntaxUID)
            .flatMap(DicomCodecFamily.family(for:))
        let shadowIdentifier = family.flatMap { shadowPolicy.candidatesByFamily[$0] }
        let shadow = shadowIdentifier.flatMap { identifier in
            eligible.first {
                $0.capabilities.identifier == identifier
                    && $0.capabilities.identifier != production.capabilities.identifier
            }
        }
        let capability = production.capabilities
        return DicomFrameCodecSelection(
            production: production,
            shadow: shadow,
            diagnostics: DicomCodecSelectionDiagnostics(
                selectedBackend: capability.identifier,
                selectedSource: capability.source,
                selectedVersion: capability.version,
                fallbackReason: fallbackReason,
                shadowBackend: shadow?.capabilities.identifier
            )
        )
    }

    private func unsupportedError(
        for request: DicomFrameDecodeRequest,
        evaluations: [(any DicomFrameCodecBackend, String?)]
    ) -> DicomCodecSelectionError {
        let reasons = evaluations.compactMap { backend, reason in
            reason.map { "\(backend.capabilities.identifier.rawValue): \($0)" }
        }
        return .unsupported(
            transferSyntaxUID: request.descriptor.transferSyntaxUID,
            reasons: reasons.isEmpty ? ["No backends are registered."] : reasons
        )
    }
}

struct DicomCodecShadowComparison: Equatable, Sendable {
    enum Result: Equatable, Sendable {
        case matched
        case mismatched
        case failed(String)
    }

    let productionBackend: DicomCodecBackendIdentifier
    let shadowBackend: DicomCodecBackendIdentifier
    let result: Result
}

struct DicomFrameCodecExecutor: Sendable {
    typealias ShadowReporter = @Sendable (DicomCodecShadowComparison) -> Void

    private let reportShadowComparison: ShadowReporter

    init(reportShadowComparison: @escaping ShadowReporter = { _ in }) {
        self.reportShadowComparison = reportShadowComparison
    }

    func decode(
        _ request: DicomFrameDecodeRequest,
        selection: DicomFrameCodecSelection
    ) async throws -> DicomCodecDecodedFrame {
        let production = try await selection.production.decode(request)
        guard let shadow = selection.shadow else { return production }

        let result: DicomCodecShadowComparison.Result
        do {
            let candidate = try await shadow.decode(request)
            result = Self.framesMatch(production, candidate) ? .matched : .mismatched
        } catch {
            result = .failed(error.localizedDescription)
        }
        reportShadowComparison(
            DicomCodecShadowComparison(
                productionBackend: selection.production.capabilities.identifier,
                shadowBackend: shadow.capabilities.identifier,
                result: result
            )
        )
        return production
    }

    private static func framesMatch(_ lhs: DicomCodecDecodedFrame, _ rhs: DicomCodecDecodedFrame) -> Bool {
        lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.bitsPerSample == rhs.bitsPerSample
            && lhs.componentCount == rhs.componentCount
            && lhs.buffer.data == rhs.buffer.data
    }
}
