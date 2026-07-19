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
        for diagnostic in report.diagnostics {
            lines.append("diagnostic: \(diagnostic.severity.rawValue) \(diagnostic.code) \(diagnostic.message)")
        }
        return lines.joined(separator: "\n")
    }
}
