//
//  DicomCodecCanonicalRenderer.swift
//  DicomCore
//

import Foundation

/// Stable renderers used by every codec workflow adapter.
public enum DicomCodecCanonicalRenderer {
    /// Encodes a report as stable sorted-key JSON data.
    public static func jsonData(
        _ report: DicomCodecStructuredReport,
        prettyPrinted: Bool = true
    ) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        return try encoder.encode(report)
    }

    /// Encodes a report as a stable sorted-key JSON string.
    public static func jsonString(
        _ report: DicomCodecStructuredReport,
        prettyPrinted: Bool = true
    ) throws -> String {
        String(decoding: try jsonData(report, prettyPrinted: prettyPrinted), as: UTF8.self)
    }

    /// Renders a report as stable line-oriented human-readable text.
    public static func text(_ report: DicomCodecStructuredReport) -> String {
        var lines = [
            "operation: \(report.operation.rawValue)",
            "success: \(report.success)"
        ]
        if let source = report.sourceObject {
            lines.append("source-transfer-syntax: \(source.transferSyntaxUID)")
            lines.append("shape: \(source.columns)x\(source.rows)x\(source.frameCount)")
            lines.append(
                "pixels: bits=\(source.bitsStored)/\(source.bitsAllocated) signed=\(source.pixelRepresentation == 1) "
                    + "components=\(source.samplesPerPixel) photometric=\(source.photometricInterpretation)"
            )
        }
        if let target = report.targetTransferSyntaxUID {
            lines.append("target-transfer-syntax: \(target)")
        }
        if let route = report.transcodeRoute {
            lines.append("route: \(route)")
        }
        for backend in report.backends {
            lines.append(
                "backend: \(backend.role.rawValue) \(backend.identifier) selected=\(backend.selected) "
                    + "available=\(backend.available) source=\(backend.source) version=\(backend.version ?? "unknown")"
            )
            if let reason = backend.reason {
                lines.append("backend-reason: \(reason)")
            }
        }
        for frame in report.frames {
            lines.append(
                "frame: \(frame.index) \(frame.width)x\(frame.height) bits=\(frame.bitsPerSample) "
                    + "components=\(frame.componentCount) bytes=\(frame.pixelByteCount) hash=\(frame.pixelHash)"
            )
        }
        if let decisions = report.decisions {
            if let first = decisions.first {
                let profile = first.descriptor
                lines.append("capability-profile: \(profile.columns)x\(profile.rows) bits=\(profile.bitsStored)/\(profile.bitsAllocated) "
                    + "signed=\(profile.pixelRepresentation == 1) components=\(profile.samplesPerPixel) "
                    + "photometric=\(profile.photometricInterpretation) planar=\(profile.planarConfiguration.map(String.init) ?? "unspecified") "
                    + "intent=\(first.encodingIntent)")
            }
            lines.append("| UID | Operation | Executable | Backend | Qualification | Reason |")
            lines.append("| --- | --- | --- | --- | --- | --- |")
            for decision in decisions {
                lines.append("| \(decision.transferSyntaxUID) | \(decision.operation.rawValue) | \(decision.canExecute) | "
                    + "\(decision.backendIdentifier ?? "—") | \(decision.qualification.rawValue) | "
                    + "\(decision.reasonCode?.rawValue ?? "—") |")
            }
        }
        if let encapsulation = report.encapsulation {
            lines.append(
                "encapsulation: valid=\(encapsulation.valid) declared=\(encapsulation.declaredFrameCount) "
                    + "mapped=\(encapsulation.mappedFrameCount) fragments=\(encapsulation.fragmentCount) "
                    + "bot=\(encapsulation.basicOffsetCount) eot=\(encapsulation.extendedOffsetCount)"
            )
        }
        if let artifact = report.artifact {
            lines.append(
                "artifact: type=\(artifact.mediaType) bytes=\(artifact.byteCount) hash=\(artifact.contentHash) "
                    + "valid=\(artifact.validationPassed)"
            )
            if let comparison = artifact.comparisonPassed {
                lines.append("comparison: \(artifact.comparisonMode ?? "unspecified") passed=\(comparison)")
            }
        }
        if let conformance = report.conformance {
            for layer in DicomValidationReport.Layer.allCases {
                lines.append("conformance-\(layer.rawValue): \(conformance[layer].rawValue)")
            }
            for diagnostic in conformance.diagnostics {
                lines.append("conformance-diagnostic: \(diagnostic.severity.rawValue) \(diagnostic.code.rawValue) \(formatPath(diagnostic.path))")
            }
        }
        for diagnostic in report.diagnostics {
            lines.append("diagnostic: \(diagnostic.severity.rawValue) \(diagnostic.code) \(diagnostic.message)")
        }
        return lines.joined(separator: "\n")
    }

    private static func formatPath(_ path: [DicomValidationReport.PathComponent]) -> String {
        path.map { component in
            switch component {
            case .tag(let tag): return String(format: "tag:%08X", tag)
            case .item(let item): return "item:\(item)"
            case .frame(let frame): return "frame:\(frame)"
            }
        }.joined(separator: "/")
    }
}
