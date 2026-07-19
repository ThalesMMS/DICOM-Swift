import Darwin
import Foundation

/// Optional native codec runtimes that DicomCore can load dynamically.
public enum DicomCodecRuntime: String, CaseIterable, Sendable {
    /// CharLS runtime used for JPEG-LS lossless and near-lossless decoding.
    case charLS

    /// OpenJPEG runtime used for JPEG 2000 and JPEG 2000 Part 2 decoding.
    case openJPEG

    /// Human-readable runtime name for diagnostics.
    public var displayName: String {
        switch self {
        case .charLS:
            return "CharLS"
        case .openJPEG:
            return "OpenJPEG"
        }
    }

    /// Environment variable that overrides the dynamic-library path for this runtime.
    public var libraryPathEnvironmentVariable: String {
        switch self {
        case .charLS:
            return "DICOM_DECODER_CHARLS_LIBRARY_PATH"
        case .openJPEG:
            return "DICOM_DECODER_OPENJPEG_LIBRARY_PATH"
        }
    }

    internal var defaultLibraryCandidates: [String] {
        switch self {
        case .charLS:
            return [
                "/opt/homebrew/lib/libcharls.2.dylib",
                "/opt/homebrew/lib/libcharls.dylib",
                "/usr/local/lib/libcharls.2.dylib",
                "/usr/local/lib/libcharls.dylib",
                "libcharls.2.dylib",
                "libcharls.dylib"
            ]
        case .openJPEG:
            return [
                "/opt/homebrew/lib/libopenjp2.7.dylib",
                "/opt/homebrew/lib/libopenjp2.dylib",
                "/usr/local/lib/libopenjp2.7.dylib",
                "/usr/local/lib/libopenjp2.dylib",
                "libopenjp2.7.dylib",
                "libopenjp2.dylib"
            ]
        }
    }

    internal var requiredSymbols: [String] {
        switch self {
        case .charLS:
            return [
                "charls_jpegls_decoder_create",
                "charls_jpegls_decoder_destroy",
                "charls_jpegls_decoder_set_source_buffer",
                "charls_jpegls_decoder_read_header",
                "charls_jpegls_decoder_get_frame_info",
                "charls_jpegls_decoder_get_near_lossless",
                "charls_jpegls_decoder_get_interleave_mode",
                "charls_jpegls_decoder_get_destination_size",
                "charls_jpegls_decoder_decode_to_buffer",
                "charls_jpegls_encoder_create",
                "charls_jpegls_encoder_destroy",
                "charls_jpegls_encoder_set_frame_info",
                "charls_jpegls_encoder_set_near_lossless",
                "charls_jpegls_encoder_set_interleave_mode",
                "charls_jpegls_encoder_get_estimated_destination_size",
                "charls_jpegls_encoder_set_destination_buffer",
                "charls_jpegls_encoder_encode_from_buffer",
                "charls_jpegls_encoder_get_bytes_written",
                "charls_get_error_message"
            ]
        case .openJPEG:
            return [
                "opj_create_decompress",
                "opj_destroy_codec",
                "opj_set_default_decoder_parameters",
                "opj_setup_decoder",
                "opj_stream_create_default_file_stream",
                "opj_stream_destroy",
                "opj_read_header",
                "opj_decode",
                "opj_end_decompress",
                "opj_image_destroy"
            ]
        }
    }
}

/// Result category for a native codec runtime preflight.
public enum DicomCodecRuntimeAvailability: String, Codable, Sendable {
    /// The runtime library loaded and exported all required symbols.
    case available

    /// No runtime library was found through the default search path.
    case missingLibrary = "missing-library"

    /// A configured runtime path was provided but could not be loaded.
    case invalidLibraryPath = "invalid-library-path"

    /// The runtime library loaded but does not export all required symbols.
    case missingSymbols = "missing-symbols"
}

/// Preflight result for one optional native codec runtime.
public struct DicomCodecRuntimeStatus: Equatable, Sendable {
    /// Runtime that was checked.
    public let runtime: DicomCodecRuntime

    /// Availability category.
    public let availability: DicomCodecRuntimeAvailability

    /// Library candidate that produced the result, when applicable.
    public let libraryPath: String?

    /// Required symbols that were absent from the loaded library.
    public let missingSymbols: [String]

    /// Human-readable diagnostic suitable for logs, test skips, and unsupported codec errors.
    public let message: String

    /// Whether the runtime can be used for codec decoding.
    public var isAvailable: Bool {
        availability == .available
    }
}

/// Package-level preflight API for optional native codec runtimes.
public enum DicomCodecRuntimePreflight {
    /// Returns the current status for every optional native codec runtime.
    public static func statuses(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [DicomCodecRuntimeStatus] {
        DicomCodecRuntime.allCases.map { status(for: $0, environment: environment) }
    }

    /// Returns the current status for one optional native codec runtime.
    public static func status(
        for runtime: DicomCodecRuntime,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DicomCodecRuntimeStatus {
        resolve(
            for: runtime,
            environment: environment,
            requiredSymbols: runtime.requiredSymbols,
            retainHandle: false
        ).status
    }

    internal static func status(
        for runtime: DicomCodecRuntime,
        environment: [String: String],
        requiredSymbols: [String]
    ) -> DicomCodecRuntimeStatus {
        resolve(for: runtime, environment: environment, requiredSymbols: requiredSymbols, retainHandle: false).status
    }

    internal static func status(
        for runtime: DicomCodecRuntime,
        environment: [String: String],
        requiredSymbols: [String],
        libraryCandidates: [String],
        isExplicitOverride: Bool = false
    ) -> DicomCodecRuntimeStatus {
        resolve(
            for: runtime,
            environment: environment,
            requiredSymbols: requiredSymbols,
            retainHandle: false,
            candidateOverride: (libraryCandidates, isExplicitOverride)
        ).status
    }

    internal static func resolve(
        for runtime: DicomCodecRuntime,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        retainHandle: Bool
    ) -> DicomCodecRuntimeResolution {
        resolve(
            for: runtime,
            environment: environment,
            requiredSymbols: runtime.requiredSymbols,
            retainHandle: retainHandle
        )
    }

    private static func resolve(
        for runtime: DicomCodecRuntime,
        environment: [String: String],
        requiredSymbols: [String],
        retainHandle: Bool,
        candidateOverride: (paths: [String], isExplicitOverride: Bool)? = nil
    ) -> DicomCodecRuntimeResolution {
        let candidates = candidateOverride ?? libraryCandidates(for: runtime, environment: environment)
        var lastError: String?

        for candidate in candidates.paths {
            _ = dlerror()
            guard let handle = dlopen(candidate, RTLD_NOW | RTLD_LOCAL) else {
                lastError = currentDynamicLoaderError()
                if candidates.isExplicitOverride {
                    return DicomCodecRuntimeResolution(
                        status: status(
                            runtime: runtime,
                            availability: .invalidLibraryPath,
                            libraryPath: candidate,
                            missingSymbols: [],
                            message: "\(runtime.displayName) path from "
                                + "\(runtime.libraryPathEnvironmentVariable) is not loadable: "
                                + "\(lastError ?? "unknown dynamic loader error")."
                        ),
                        handle: nil
                    )
                }
                continue
            }

            let missingSymbols = requiredSymbols.filter { dlsym(handle, $0) == nil }
            if missingSymbols.isEmpty {
                let currentStatus = status(
                    runtime: runtime,
                    availability: .available,
                    libraryPath: candidate,
                    missingSymbols: [],
                    message: "\(runtime.displayName) runtime is available at \(candidate)."
                )
                if retainHandle {
                    return DicomCodecRuntimeResolution(status: currentStatus, handle: handle)
                }
                dlclose(handle)
                return DicomCodecRuntimeResolution(status: currentStatus, handle: nil)
            }

            let currentStatus = status(
                runtime: runtime,
                availability: .missingSymbols,
                libraryPath: candidate,
                missingSymbols: missingSymbols,
                message: "\(runtime.displayName) runtime at \(candidate) is missing required symbols: "
                    + "\(missingSymbols.joined(separator: ", "))."
            )
            if retainHandle {
                return DicomCodecRuntimeResolution(status: currentStatus, handle: handle)
            }
            dlclose(handle)
            return DicomCodecRuntimeResolution(status: currentStatus, handle: nil)
        }

        let details = lastError.map { " Last dynamic loader error: \($0)." } ?? ""
        return DicomCodecRuntimeResolution(
            status: status(
                runtime: runtime,
                availability: .missingLibrary,
                libraryPath: nil,
                missingSymbols: [],
                message: "\(runtime.displayName) runtime library is not loadable from default candidates: "
                    + "\(candidates.paths.joined(separator: ", ")).\(details)"
            ),
            handle: nil
        )
    }

    private static func libraryCandidates(
        for runtime: DicomCodecRuntime,
        environment: [String: String]
    ) -> (paths: [String], isExplicitOverride: Bool) {
        let configuredPath = environment[runtime.libraryPathEnvironmentVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let configuredPath, !configuredPath.isEmpty {
            return ([configuredPath], true)
        }
        return (runtime.defaultLibraryCandidates, false)
    }

    private static func status(
        runtime: DicomCodecRuntime,
        availability: DicomCodecRuntimeAvailability,
        libraryPath: String?,
        missingSymbols: [String],
        message: String
    ) -> DicomCodecRuntimeStatus {
        DicomCodecRuntimeStatus(
            runtime: runtime,
            availability: availability,
            libraryPath: libraryPath,
            missingSymbols: missingSymbols,
            message: message
        )
    }

    private static func currentDynamicLoaderError() -> String? {
        guard let error = dlerror() else {
            return nil
        }
        return String(cString: error)
    }
}

internal struct DicomCodecRuntimeResolution {
    let status: DicomCodecRuntimeStatus
    let handle: UnsafeMutableRawPointer?
}
