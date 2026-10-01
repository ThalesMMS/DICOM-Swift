import Foundation

/// Envelope checks are distinct from qualified IOD validation and from bounded content plausibility.
/// A plausible signature is neither format validation nor a guarantee that content can be rendered.
public enum DicomEncapsulatedDocumentEnvelopeValidator {
    public enum Plausibility: String, Equatable, Sendable { case plausible, implausible, notChecked }
    public struct ContentPlausibility: Equatable, Sendable {
        public let verdict: Plausibility
        public let reason: String
    }
    public struct Result: Equatable, Sendable {
        public let diagnostics: [DicomEncapsulatedDocumentDiagnostic]
        public let contentPlausibility: ContentPlausibility
        /// Only the envelope rules implemented here, not full IOD or content conformance.
        public var isValid: Bool { diagnostics.isEmpty }
        public let limitations: [String]
    }

    /// Supply known embedded subcomponent types; external OBJ material references are not embedded components.
    /// nil means the condition cannot be established from envelope metadata alone.
    public static func validate(_ document: DicomEncapsulatedDocument, embeddedMIMETypes: [String]? = nil,
                                checkContent: Bool = true) -> Result {
        var diagnostics = document.diagnostics
        func issue(_ code: DicomEncapsulatedDocumentDiagnostic.Code, _ reason: String) {
            if !diagnostics.contains(where: { $0.code == code }) { diagnostics.append(.init(code: code, reason: reason)) }
        }
        let kind = document.kind
        if kind == nil || document.mimeType.lowercased() != kind?.defaultMIMEType.lowercased() {
            issue(.mimeMismatch, "MIME type does not match the SOP Class enumerated value (C.24.2.1, A.45, A.85).")
        }
        if let length = document.declaredDocumentLength {
            let rawCount = document.encodedValueLength ?? document.documentData.count
            if length < 0 || !(length == rawCount ||
                (length % 2 == 1 && rawCount == length + 1 && document.documentData.count == length)) {
                issue(.lengthMismatch, "Declared document length does not agree with the encoded value and padding.")
            }
        }
        if let embeddedMIMETypes {
            let required = Set(embeddedMIMETypes.map { $0.lowercased() }).subtracting([document.mimeType.lowercased()])
            if !required.isSubset(of: Set(document.listOfMIMETypes.map { $0.lowercased() })) {
                issue(.missingMIMEList, "C.24.2 requires List of MIME Types for embedded subcomponents of different MIME types.")
            }
        }
        if kind == .cda, document.hl7InstanceIdentifier?.isEmpty != false {
            issue(.missingHL7Identifier, "CDA requires HL7 Instance Identifier (0040,E001).")
        }
        if kind == .stl || kind == .obj || kind == .mtl {
            if document.modality != "M3D" { issue(.modalityMismatch, "Manufacturing models require Modality M3D.") }
            if document.manufacturing3DModel?.measurementUnits == nil && document.measurementUnits == nil {
                issue(.missingModelUnits, "Manufacturing 3D Model requires Measurement Units Code Sequence.")
            }
            if kind != .mtl, document.frameOfReferenceUID?.isEmpty != false {
                issue(.missingFrameOfReference, "STL and OBJ require Frame of Reference UID.")
            }
            if [document.manufacturer, document.manufacturerModelName, document.deviceSerialNumber,
                document.softwareVersions].contains(where: { $0?.isEmpty != false }) {
                issue(.missingEquipment, "Enhanced General Equipment requires manufacturer, model, serial number and software versions.")
            }
        }
        for reference in document.referencedImages + document.referencedInstances {
            if let uri = reference.relativeURIReference, !validRelativeURI(uri) {
                issue(.invalidRelativeURI, "Relative URI violates C.24.2.4 restrictions.")
            }
        }
        return .init(diagnostics: diagnostics,
                     contentPlausibility: checkContent ? sniff(document) : .init(verdict: .notChecked, reason: "Disabled by caller."),
                     limitations: embeddedMIMETypes == nil ? ["Embedded MIME list condition requires content knowledge supplied by caller."] : [])
    }

    static func lengthDiagnostics(declared: Int?, raw: Data) -> [DicomEncapsulatedDocumentDiagnostic] {
        guard let declared else { return [] }
        guard declared >= 0, declared == raw.count ||
                (declared % 2 == 1 && raw.count == declared + 1 && raw.last == 0) else {
            return [.init(code: .lengthMismatch, reason: "Length mismatch; the complete encoded payload was preserved.")]
        }
        return []
    }

    public static func validRelativeURI(_ uri: String) -> Bool {
        guard !uri.isEmpty, !uri.hasPrefix("/"), !uri.contains("\\"),
              !uri.contains(where: { $0.isWhitespace }), let components = URLComponents(string: uri),
              components.scheme == nil, components.host == nil,
              let decoded = uri.removingPercentEncoding, !decoded.contains("\\"),
              !decoded.hasPrefix("/"), !decoded.contains(where: { $0.isWhitespace }),
              !decoded.split(separator: "/").contains("..") else { return false }
        let ext = (components.path as NSString).pathExtension.lowercased()
        return !["exe", "dll", "com", "bat", "cmd", "sh", "app", "msi", "scr"].contains(ext)
    }

    private static func sniff(_ document: DicomEncapsulatedDocument) -> ContentPlausibility {
        let data = document.documentData
        let lead = String(decoding: data.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let plausible: Bool
        let reason: String
        switch document.kind {
        case .pdf:
            plausible = data.starts(with: Data("%PDF-".utf8)); reason = "PDF %PDF- prefix."
        case .cda:
            plausible = lead.hasPrefix("<?xml") || lead.hasPrefix("<ClinicalDocument")
            reason = "XML declaration or ClinicalDocument lead; no CDA R2 validation."
        case .stl:
            let count = data.count >= 84 ? data.dropFirst(80).prefix(4).enumerated().reduce(UInt64(0)) {
                $0 | (UInt64($1.element) << (8 * $1.offset))
            } : 0
            let binary = data.count >= 84 && UInt64(data.count) == 84 + 50 * count
            plausible = binary || lead.hasPrefix("solid")
            reason = binary ? "Binary STL header and facet count agree." : "ASCII solid lead; ASCII is not the A.85.1 binary STL content constraint."
        case .obj:
            plausible = lead.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("v ") || $0.hasPrefix("f ") || $0.hasPrefix("mtllib ") }
            reason = "OBJ v/f/mtllib text lead heuristic."
        case .mtl:
            plausible = lead.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("newmtl ") }
            reason = "MTL newmtl text lead heuristic."
        case nil: return .init(verdict: .notChecked, reason: "Unknown SOP Class.")
        }
        return .init(verdict: plausible ? .plausible : .implausible,
                     reason: plausible ? reason : "Expected signature absent or inconsistent: " + reason)
    }
}
