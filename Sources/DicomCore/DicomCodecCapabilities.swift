//
//  DicomCodecCapabilities.swift
//  DicomCore
//
//  Release-deterministic codec backend reporting (issue #1230). One API
//  answers, per optional native codec runtime: which backend is active,
//  which version, loaded from where (environment override vs default
//  search path), what bit depths the decode pipeline supports, and the
//  deterministic reason when the backend is unusable.
//
//  Loading strategy of record: JLSwift is a package-linked JPEG-LS candidate;
//  CharLS (JPEG-LS production/fallback) and OpenJPEG (JPEG 2000)
//  are SYSTEM dependencies loaded dynamically at runtime — default
//  Homebrew/usr-local candidates, overridable per runtime with
//  DICOM_DECODER_<RUNTIME>_LIBRARY_PATH. They are not bundled package
//  artifacts. Decode paths fail typed when a runtime is absent or
//  version-incompatible, and the release gate
//  (`Scripts/test_gates.sh release`) requires both runtimes before a
//  release candidate is accepted (DICOM_REQUIRE_CHARLS /
//  DICOM_REQUIRE_OPENJPEG fail the preflight fast when missing).
//

import Darwin
import Foundation

/// Where the active backend library was resolved from.
public enum DicomCodecBackendSource: String, Codable, Sendable {
    /// Implemented by code linked into DicomCore or another package target.
    case packageLinked = "package-linked"
    /// Implemented by an Apple system framework such as ImageIO.
    case systemFramework = "system-framework"
    /// Loaded from the path in DICOM_DECODER_<RUNTIME>_LIBRARY_PATH.
    case environmentOverride = "environment-override"
    /// Loaded from the default Homebrew//usr/local candidate list.
    case defaultSearchPath = "default-search-path"
    /// No usable backend library.
    case unavailable
}

/// Capability report for one codec backend.
public struct DicomCodecCapability: Equatable, Sendable {
    /// Optional dynamic runtime represented by this report.
    public let runtime: DicomCodecRuntime
    /// Transfer syntax UIDs this backend decodes.
    public let transferSyntaxUIDs: [String]
    /// True when decode calls will use this backend.
    public let isAvailable: Bool
    /// Backend version string reported by the library (for example
    /// "2.4.2"), nil when the library or its version symbol is absent.
    public let version: String?
    /// Resolved library path, nil when unavailable.
    public let libraryPath: String?
    /// How the codec runtime was resolved for this process.
    public let source: DicomCodecBackendSource
    /// Grayscale stored-bit depths the decode pipeline accepts.
    public let supportedGrayscaleBitDepths: ClosedRange<Int>
    /// Color (3-sample) stored-bit depths the decode pipeline accepts.
    public let supportedColorBitDepths: ClosedRange<Int>
    /// Deterministic reason when `isAvailable` is false.
    public let unsupportedReason: String?
}

/// Public diagnostic projection of one compressed-frame backend.
public struct DicomCodecBackendStatus: Equatable, Sendable {
    /// Stable backend identifier used in rollout diagnostics.
    public let identifier: String
    /// Linked or runtime-reported backend version.
    public let version: String?
    /// How the backend implementation enters the process.
    public let source: DicomCodecBackendSource
    /// Whether calls can select the backend in this process.
    public let isAvailable: Bool
    /// Transfer syntaxes qualified for decode.
    public let decodeTransferSyntaxUIDs: [String]
    /// Transfer syntaxes qualified for encode.
    public let encodeTransferSyntaxUIDs: [String]
    /// Qualified operation names (`decode` and/or `encode`).
    public let operations: [String]
    /// Qualified grayscale stored-bit depths.
    public let supportedGrayscaleBitDepths: ClosedRange<Int>
    /// Qualified multi-component stored-bit depths.
    public let supportedColorBitDepths: ClosedRange<Int>
    /// Deterministic reason when the backend is unavailable.
    public let unsupportedReason: String?
}

/// Single entry point for codec backend capability reporting.
public enum DicomCodecCapabilities {
    /// Supported major version of each runtime's C API. The required
    /// symbol sets are major-version specific, so a loadable library with
    /// a different major is rejected as version-incompatible.
    static let supportedMajorVersion = 2

    /// Capability reports for every optional codec runtime.
    public static func all(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [DicomCodecCapability] {
        DicomCodecRuntime.allCases.map { capability(for: $0, environment: environment) }
    }

    /// Reports package-linked, system-framework, and dynamic codec backends
    /// through a stable diagnostic surface suitable for preflight tooling.
    public static func backendStatuses(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [DicomCodecBackendStatus] {
        frameBackends(environment: environment).map { capability in
            DicomCodecBackendStatus(
                identifier: capability.identifier.rawValue,
                version: capability.version,
                source: capability.source,
                isAvailable: capability.isAvailable,
                decodeTransferSyntaxUIDs: capability.transferSyntaxUIDs.sorted(),
                encodeTransferSyntaxUIDs: capability.encodeTransferSyntaxUIDs.sorted(),
                operations: capability.operations.map(\.rawValue).sorted(),
                supportedGrayscaleBitDepths: capability.supportedGrayscaleBitDepths,
                supportedColorBitDepths: capability.supportedColorBitDepths,
                unsupportedReason: capability.unsupportedReason
            )
        }
    }

    /// Capability reports for every compressed-frame backend currently linked
    /// or discoverable at runtime, including native Swift and ImageIO paths.
    static func frameBackends(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [DicomFrameCodecCapabilities] {
        DicomCompressedPixelBackendRegistry.capabilities(environment: environment)
    }

    /// Capability report for one codec runtime.
    public static func capability(
        for runtime: DicomCodecRuntime,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DicomCodecCapability {
        let status = DicomCodecRuntimePreflight.status(for: runtime, environment: environment)
        return capability(for: runtime, status: status, environment: environment)
    }

    /// Builds the report from an already-computed preflight status (lets
    /// tests exercise every availability category deterministically).
    internal static func capability(
        for runtime: DicomCodecRuntime,
        status: DicomCodecRuntimeStatus,
        environment: [String: String]
    ) -> DicomCodecCapability {
        let overrideConfigured = environment[runtime.libraryPathEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false

        guard status.isAvailable, let libraryPath = status.libraryPath else {
            return DicomCodecCapability(
                runtime: runtime,
                transferSyntaxUIDs: transferSyntaxUIDs(for: runtime),
                isAvailable: false,
                version: nil,
                libraryPath: status.libraryPath,
                source: .unavailable,
                supportedGrayscaleBitDepths: grayscaleBitDepths(for: runtime),
                supportedColorBitDepths: colorBitDepths(for: runtime),
                unsupportedReason: status.message
            )
        }

        let version = loadVersion(for: runtime, at: libraryPath)
        let source: DicomCodecBackendSource = overrideConfigured ? .environmentOverride : .defaultSearchPath
        if let version, let major = majorVersion(of: version), major != supportedMajorVersion {
            return DicomCodecCapability(
                runtime: runtime,
                transferSyntaxUIDs: transferSyntaxUIDs(for: runtime),
                isAvailable: false,
                version: version,
                libraryPath: libraryPath,
                source: source,
                supportedGrayscaleBitDepths: grayscaleBitDepths(for: runtime),
                supportedColorBitDepths: colorBitDepths(for: runtime),
                unsupportedReason: "\(runtime.displayName) \(version) at \(libraryPath) is not the supported"
                    + " major version \(supportedMajorVersion)."
            )
        }

        return DicomCodecCapability(
            runtime: runtime,
            transferSyntaxUIDs: transferSyntaxUIDs(for: runtime),
            isAvailable: true,
            version: version,
            libraryPath: libraryPath,
            source: source,
            supportedGrayscaleBitDepths: grayscaleBitDepths(for: runtime),
            supportedColorBitDepths: colorBitDepths(for: runtime),
            unsupportedReason: nil
        )
    }

    // MARK: - Pipeline limits and identity

    private static func transferSyntaxUIDs(for runtime: DicomCodecRuntime) -> [String] {
        switch runtime {
        case .charLS:
            return [
                DicomTransferSyntax.jpegLSLossless.rawValue,
                DicomTransferSyntax.jpegLSNearLossless.rawValue
            ]
        case .openJPEG:
            return [
                DicomTransferSyntax.jpeg2000Lossless.rawValue,
                DicomTransferSyntax.jpeg2000.rawValue,
                DicomTransferSyntax.jpeg2000Part2MulticomponentLossless.rawValue,
                DicomTransferSyntax.jpeg2000Part2Multicomponent.rawValue
            ]
        }
    }

    private static func grayscaleBitDepths(for runtime: DicomCodecRuntime) -> ClosedRange<Int> {
        switch runtime {
        case .charLS:
            return 2...16
        case .openJPEG:
            return 1...16
        }
    }

    private static func colorBitDepths(for runtime: DicomCodecRuntime) -> ClosedRange<Int> {
        // The shared pixel pipeline materializes color as 8-bit interleaved
        // RGB; the backend resolver rejects deeper color output.
        switch runtime {
        case .charLS:
            return 2...8
        case .openJPEG:
            return 1...8
        }
    }

    // MARK: - Version reporting

    static func versionSymbolName(for runtime: DicomCodecRuntime) -> String {
        switch runtime {
        case .charLS:
            return "charls_get_version_string"
        case .openJPEG:
            return "opj_version"
        }
    }

    static func majorVersion(of version: String) -> Int? {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.split(separator: ".").first else { return nil }
        return Int(first)
    }

    private static func loadVersion(for runtime: DicomCodecRuntime, at path: String) -> String? {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            return nil
        }
        defer { dlclose(handle) }
        return version(fromHandle: handle, runtime: runtime)
    }

    /// Reads the version string from an already-open library handle.
    internal static func version(
        fromHandle handle: UnsafeMutableRawPointer,
        runtime: DicomCodecRuntime
    ) -> String? {
        guard let symbol = dlsym(handle, versionSymbolName(for: runtime)) else {
            return nil
        }
        typealias VersionFunction = @convention(c) () -> UnsafePointer<CChar>?
        let function = unsafeBitCast(symbol, to: VersionFunction.self)
        return function().map { String(cString: $0) }
    }
}
