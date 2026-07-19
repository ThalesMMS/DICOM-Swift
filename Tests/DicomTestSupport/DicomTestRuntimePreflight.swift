import Foundation
import XCTest
#if canImport(Metal)
import Metal
#endif
@testable import DicomCore

public enum DicomRuntimeCapability: String, CaseIterable, Codable {
    case bundledSyntheticFixtures
    case largeDicomFixtures
    case jpegLosslessConformanceFixtures
    case charLS
    case openJPEG
    case opjCompress
    case libjxlTools
    case metalDevice
    case networkSecurityTLS
    case networkInteropSmoke

    public var manifestID: String {
        switch self {
        case .bundledSyntheticFixtures:
            return "bundled-synthetic-fixtures"
        case .largeDicomFixtures:
            return "large-dicom-fixtures"
        case .jpegLosslessConformanceFixtures:
            return "jpeg-lossless-conformance-fixtures"
        case .charLS:
            return "charls-runtime"
        case .openJPEG:
            return "openjpeg-runtime"
        case .opjCompress:
            return "opj-compress-tool"
        case .libjxlTools:
            return "libjxl-tools"
        case .metalDevice:
            return "metal-device"
        case .networkSecurityTLS:
            return "network-security-tls"
        case .networkInteropSmoke:
            return "network-interop-smoke"
        }
    }

    public var label: String {
        switch self {
        case .bundledSyntheticFixtures:
            return "Bundled synthetic DICOM fixtures"
        case .largeDicomFixtures:
            return "Large DICOM fixtures"
        case .jpegLosslessConformanceFixtures:
            return "JPEG Lossless conformance fixtures"
        case .charLS:
            return "CharLS runtime"
        case .openJPEG:
            return "OpenJPEG runtime"
        case .opjCompress:
            return "opj_compress tool"
        case .libjxlTools:
            return "cjxl/djxl tools"
        case .metalDevice:
            return "Metal device"
        case .networkSecurityTLS:
            return "Network/Security TLS runtime"
        case .networkInteropSmoke:
            return "DICOM interop smoke endpoints"
        }
    }

    public var requiredEnvironmentVariable: String {
        switch self {
        case .bundledSyntheticFixtures:
            return "DICOM_REQUIRE_BUNDLED_SYNTHETIC_FIXTURES"
        case .largeDicomFixtures:
            return "DICOM_REQUIRE_LARGE_DICOM_FIXTURES"
        case .jpegLosslessConformanceFixtures:
            return "DICOM_REQUIRE_JPEG_LOSSLESS_CONFORMANCE_FIXTURES"
        case .charLS:
            return "DICOM_REQUIRE_CHARLS"
        case .openJPEG:
            return "DICOM_REQUIRE_OPENJPEG"
        case .opjCompress:
            return "DICOM_REQUIRE_OPJ_COMPRESS"
        case .libjxlTools:
            return "DICOM_REQUIRE_LIBJXL_TOOLS"
        case .metalDevice:
            return "DICOM_REQUIRE_METAL"
        case .networkSecurityTLS:
            return "DICOM_REQUIRE_NETWORK_SECURITY_TLS"
        case .networkInteropSmoke:
            return "DICOM_REQUIRE_NETWORK_INTEROP_SMOKE"
        }
    }

    public var isRequiredInDefaultCI: Bool {
        switch self {
        case .bundledSyntheticFixtures:
            return true
        case .largeDicomFixtures, .jpegLosslessConformanceFixtures, .charLS, .openJPEG, .opjCompress,
             .libjxlTools,
             .metalDevice, .networkSecurityTLS, .networkInteropSmoke:
            return false
        }
    }
}

public enum DicomRuntimeStatusKind: String, Codable {
    case available
    case missingOptionalRuntime = "missing-optional-runtime"
    case regression
    case unsupportedFeature = "unsupported-feature"
}

public struct DicomRuntimeStatus: Equatable {
    public let capability: DicomRuntimeCapability
    public let kind: DicomRuntimeStatusKind
    public let message: String

    public init(capability: DicomRuntimeCapability, kind: DicomRuntimeStatusKind, message: String) {
        self.capability = capability
        self.kind = kind
        self.message = message
    }

    public var isAvailable: Bool {
        kind == .available
    }
}

public struct DicomRuntimeRequirementError: Error, CustomStringConvertible {
    public let status: DicomRuntimeStatus

    public init(status: DicomRuntimeStatus) {
        self.status = status
    }

    public var description: String {
        DicomTestRuntimePreflight.failureMessage(for: status)
    }
}

public enum DicomTestRuntimePreflight {
    public static let requireAllOptionalRuntimesEnvironmentVariable = "DICOM_REQUIRE_OPTIONAL_RUNTIMES"

    public static func status(
        for capability: DicomRuntimeCapability,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DicomRuntimeStatus {
        switch capability {
        case .bundledSyntheticFixtures:
            let requiredFixturePaths = [
                "CT/ct_synthetic.dcm",
                "MR/mr_synthetic.dcm",
                "US/us_synthetic.dcm",
                "XR/xr_synthetic.dcm",
                "Compressed/jpeg_baseline_synthetic.dcm"
            ]
            let missing = requiredFixturePaths.filter {
                !FileManager.default.fileExists(atPath: fixturesDirectory.appendingPathComponent($0).path)
            }
            if missing.isEmpty {
                return status(capability, .available, "All bundled synthetic fixtures are present.")
            }
            return status(capability, .regression, "Missing bundled synthetic fixtures: \(missing.joined(separator: ", ")).")

        case .largeDicomFixtures:
            guard let files = FileManager.default.enumerator(at: fixturesDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
                return status(capability, .missingOptionalRuntime, "Fixtures directory is absent.")
            }
            for case let fileURL as URL in files where fileURL.pathExtension.lowercased() == "dcm" {
                let fileSize = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if (fileSize ?? 0) > 1_000_000 {
                    return status(capability, .available, "Found large fixture \(fileURL.lastPathComponent).")
                }
            }
            return status(capability, .missingOptionalRuntime, "No DICOM fixture larger than 1 MB is installed.")

        case .jpegLosslessConformanceFixtures:
            let directory = fixturesDirectory.appendingPathComponent("Compressed", isDirectory: true)
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return status(capability, .missingOptionalRuntime, "Fixtures/Compressed is absent.")
            }
            let losslessFiles = files.filter { url in
                guard url.pathExtension.lowercased() == "dcm" else {
                    return false
                }
                if url.lastPathComponent.lowercased().contains("lossless") {
                    return true
                }
                guard let decoder = try? DCMDecoder(contentsOf: url) else {
                    return false
                }
                let transferSyntax = decoder.info(for: .transferSyntaxUID)
                return transferSyntax.contains("1.2.840.10008.1.2.4.70")
                    || transferSyntax.contains("1.2.840.10008.1.2.4.57")
            }
            if losslessFiles.isEmpty {
                return status(capability, .missingOptionalRuntime, "No JPEG Lossless conformance DICOM files are installed.")
            }
            return status(capability, .available, "Found \(losslessFiles.count) JPEG Lossless conformance fixture(s).")

        case .charLS:
            let runtimeStatus = DicomCodecRuntimePreflight.status(for: .charLS, environment: environment)
            return runtimeStatus.isAvailable
                ? status(capability, .available, runtimeStatus.message)
                : status(capability, .missingOptionalRuntime, runtimeStatus.message)

        case .openJPEG:
            let runtimeStatus = DicomCodecRuntimePreflight.status(for: .openJPEG, environment: environment)
            return runtimeStatus.isAvailable
                ? status(capability, .available, runtimeStatus.message)
                : status(capability, .missingOptionalRuntime, runtimeStatus.message)

        case .opjCompress:
            if let path = executablePath(named: "opj_compress", environment: environment) {
                return status(capability, .available, "Found opj_compress at \(path).")
            }
            return status(capability, .missingOptionalRuntime, "opj_compress was not found in PATH or common Homebrew locations.")

        case .libjxlTools:
            let cjxl = executablePath(named: "cjxl", environment: environment)
            let djxl = executablePath(named: "djxl", environment: environment)
            if let cjxl, let djxl {
                return status(capability, .available, "Found cjxl at \(cjxl) and djxl at \(djxl).")
            }
            return status(
                capability,
                .missingOptionalRuntime,
                "cjxl and djxl were not both found in PATH or common Homebrew locations."
            )

        case .metalDevice:
            #if canImport(Metal)
            return MTLCreateSystemDefaultDevice() != nil
                ? status(capability, .available, "Metal device is available.")
                : status(capability, .missingOptionalRuntime, "No Metal device is available on this host.")
            #else
            return status(capability, .unsupportedFeature, "Metal framework is unavailable on this platform.")
            #endif

        case .networkSecurityTLS:
            #if canImport(Network) && canImport(Security)
            return status(capability, .available, "Network and Security frameworks are available.")
            #else
            return status(capability, .unsupportedFeature, "Network/Security TLS frameworks are unavailable on this platform.")
            #endif

        case .networkInteropSmoke:
            #if canImport(Network)
            return environment["DICOM_INTEROP_SMOKE"] == "1"
                ? status(capability, .available, "DICOM_INTEROP_SMOKE=1; network smoke tests are enabled.")
                : status(capability, .missingOptionalRuntime, "DICOM_INTEROP_SMOKE is not set to 1.")
            #else
            return status(capability, .unsupportedFeature, "Network framework is unavailable on this platform.")
            #endif
        }
    }

    public static func require(
        _ capability: DicomRuntimeCapability,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let currentStatus = status(for: capability, environment: environment)
        guard !currentStatus.isAvailable else {
            return
        }
        if isRequired(capability, environment: environment) {
            throw DicomRuntimeRequirementError(status: currentStatus)
        }
        throw XCTSkip(skipMessage(for: currentStatus))
    }

    public static func requireExecutable(
        _ capability: DicomRuntimeCapability,
        named executableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        try require(capability, environment: environment)
        guard let path = executablePath(named: executableName, environment: environment) else {
            throw DicomRuntimeRequirementError(status: status(
                capability,
                .missingOptionalRuntime,
                "\(executableName) disappeared after preflight."
            ))
        }
        return path
    }

    public static func skip(_ capability: DicomRuntimeCapability, detail: String) -> XCTSkip {
        let currentStatus = status(
            capability,
            .missingOptionalRuntime,
            detail
        )
        return XCTSkip(skipMessage(for: currentStatus))
    }

    public static func skipMessage(for status: DicomRuntimeStatus) -> String {
        "\(status.capability.label) unavailable [capability=\(status.capability.manifestID), "
            + "classification=\(status.kind.rawValue), requireEnv=\(status.capability.requiredEnvironmentVariable)]. "
            + "\(status.message) See Tests/DicomCoreTests/Resources/ReleaseGates/OptionalRuntimeFixtureManifest.json."
    }

    public static func failureMessage(for status: DicomRuntimeStatus) -> String {
        "\(status.capability.label) is required but unavailable [capability=\(status.capability.manifestID), "
            + "classification=\(status.kind.rawValue), requireEnv=\(status.capability.requiredEnvironmentVariable)]. "
            + "\(status.message)"
    }

    public static func isRequired(
        _ capability: DicomRuntimeCapability,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if capability.isRequiredInDefaultCI {
            return true
        }
        return environment[capability.requiredEnvironmentVariable] == "1"
            || environment[requireAllOptionalRuntimesEnvironmentVariable] == "1"
    }

    public static func executablePath(
        named executableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidates = (pathDirectories + ["/opt/homebrew/bin", "/usr/local/bin"])
            .map { URL(fileURLWithPath: $0).appendingPathComponent(executableName).path }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DicomCoreTests")
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private static func status(
        _ capability: DicomRuntimeCapability,
        _ kind: DicomRuntimeStatusKind,
        _ message: String
    ) -> DicomRuntimeStatus {
        DicomRuntimeStatus(capability: capability, kind: kind, message: message)
    }
}
