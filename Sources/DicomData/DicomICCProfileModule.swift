import Foundation

/// Declared C.11.15 ICC Profile module. Checks the ICC header constraints of C.11.15.1
/// (input device class, RGB input, CIE PCS) and the agreement between Color Space and
/// the profile description. Colorimetric correctness of the transform is not evaluated.
public enum DicomICCProfileModule {
    public static func applies(to dataSet: DicomDataSet) -> Bool {
        dataSet.contains(0x00282000) || dataSet.contains(0x00282002)
    }

    public static func validate(_ dataSet: DicomDataSet, limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        guard applies(to: dataSet) else { return .init() }
        var report = DicomAttributeValidator.validate(dataSet, rules: [
            .init(tag: 0x00282000, requirement: .type1),
            .init(tag: 0x00282002, requirement: .type3, constraints: [.valueCount(1...1)])
        ], limits: limits)
        guard !report.diagnostics.contains(where: { $0.severity == .error || $0.code == .evaluationLimitReached }) else { return report }
        guard let element = dataSet[0x00282000], element.vr == .OB, case .bytes(let bytes) = element.value else {
            return report.merging(.init(diagnostics: [.init(code: .valueUnavailable, severity: .limitation,
                layer: .pixelsAndGeometry, path: [.tag(0x00282000)])]))
        }
        var diagnostics: [DicomValidationReport.Diagnostic] = []
        func record(_ code: DicomValidationReport.Code, tag: Int = 0x00282000, severity: DicomValidationReport.Severity = .error) {
            diagnostics.append(.init(code: code, severity: severity, layer: .pixelsAndGeometry, path: [.tag(tag)]))
        }
        if let header = Header(bytes) {
            // Trailing NULL padding to an even value length is not part of the profile.
            if header.size != bytes.count && !(header.size + 1 == bytes.count && bytes.last == 0) { record(.invalidBinaryLength) }
            if header.signature != "acsp" || header.tagTableEnd > min(header.size, bytes.count) { record(.attributeValueNotAllowed) }
            if header.deviceClass != "scnr" || header.colorSpace != "RGB " || !["XYZ ", "Lab "].contains(header.connectionSpace) {
                record(.attributeValueContradiction)
            }
            if let label = colorSpaceLabel(dataSet[0x00282002]) {
                let agreement = header.description(in: bytes).flatMap { agrees(label: label, description: $0) }
                if agreement == false { record(.attributeValueContradiction, tag: 0x00282002) }
                if agreement == nil { record(.valueUnavailable, tag: 0x00282002, severity: .limitation) }
            }
        } else {
            record(.invalidBinaryLength)
        }
        report = report.merging(.init(evaluatedLayers: [.pixelsAndGeometry], diagnostics: diagnostics))
        return report
    }

    private static func colorSpaceLabel(_ element: DicomDataElement?) -> String? {
        guard let element, element.vr == .CS, case .strings(let values) = element.value, values.count == 1 else { return nil }
        let value = values[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
        return value.isEmpty ? nil : value
    }

    /// Well-known labels of C.11.15.1.2 are matched against the profile's own description;
    /// other Defined Terms cannot be confirmed from the description alone.
    private static func agrees(label: String, description: String) -> Bool? {
        let text = description.lowercased()
        switch label {
        case "SRGB": return text.contains("srgb")
        case "ADOBERGB": return text.contains("adobe rgb")
        case "ROMMRGB": return text.contains("romm") || text.contains("prophoto")
        default: return nil
        }
    }

    private struct Header {
        let size: Int
        let deviceClass: String
        let colorSpace: String
        let connectionSpace: String
        let signature: String
        let tagCount: Int
        var tagTableEnd: Int { 132 + tagCount * 12 }

        init?(_ bytes: Data) {
            guard bytes.count >= 132 else { return nil }
            size = Int(Header.u32(bytes, 0))
            deviceClass = Header.ascii(bytes, 12)
            colorSpace = Header.ascii(bytes, 16)
            connectionSpace = Header.ascii(bytes, 20)
            signature = Header.ascii(bytes, 36)
            tagCount = min(Int(Header.u32(bytes, 128)), 4096)
        }

        func description(in bytes: Data) -> String? {
            guard tagTableEnd <= bytes.count else { return nil }
            for index in 0..<tagCount {
                let entry = 132 + index * 12
                guard Header.ascii(bytes, entry) == "desc" else { continue }
                let offset = Int(Header.u32(bytes, entry + 4)), length = Int(Header.u32(bytes, entry + 8))
                guard length >= 12, offset <= bytes.count - length else { return nil }
                switch Header.ascii(bytes, offset) {
                case "desc":
                    let count = Int(Header.u32(bytes, offset + 8))
                    guard count >= 1, count <= length - 12 else { return nil }
                    return String(decoding: bytes[bytes.startIndex + offset + 12 ..< bytes.startIndex + offset + 12 + count - 1], as: UTF8.self)
                case "mluc":
                    guard length >= 28, Header.u32(bytes, offset + 8) >= 1 else { return nil }
                    let textLength = Int(Header.u32(bytes, offset + 20)), textOffset = Int(Header.u32(bytes, offset + 24))
                    guard textLength.isMultiple(of: 2), textOffset >= 28, textOffset <= length - textLength else { return nil }
                    let start = bytes.startIndex + offset + textOffset
                    let units = stride(from: start, to: start + textLength, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
                    return String(decoding: units, as: UTF16.self)
                default:
                    return nil
                }
            }
            return nil
        }

        private static func u32(_ bytes: Data, _ offset: Int) -> UInt32 {
            let base = bytes.startIndex + offset
            return UInt32(bytes[base]) << 24 | UInt32(bytes[base + 1]) << 16 | UInt32(bytes[base + 2]) << 8 | UInt32(bytes[base + 3])
        }

        private static func ascii(_ bytes: Data, _ offset: Int) -> String {
            String(decoding: bytes[bytes.startIndex + offset ..< bytes.startIndex + offset + 4], as: UTF8.self)
        }
    }
}
