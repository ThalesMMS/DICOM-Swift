//
//  DicomAnonymizer.swift
//  DicomCore
//
//  Safe Part 10 rewrite and anonymization (issue #1236): a policy-driven
//  engine that removes, replaces, keeps, and remaps elements; traverses
//  nested sequences; preserves the transfer syntax and file meta
//  consistency on write; carries encapsulated Pixel Data byte-for-byte
//  (Basic/Extended Offset Tables included, since the fragment layout is
//  untouched); remaps UIDs deterministically so study/series/instance
//  relationships stay consistent; and emits an audit that never records
//  original PHI values.
//

import Foundation

/// Per-tag rewrite policy.
public struct DicomRewritePolicy: Sendable {
    public enum Action: Equatable, Sendable {
        /// Keep the element untouched.
        case keep
        /// Delete the element.
        case remove
        /// Replace the value with a fixed replacement string.
        case replace(String)
        /// Deterministically remap the UID value (relationships preserved).
        case remapUID
    }

    /// Explicit per-tag actions (applied at every nesting level).
    public var actions: [Int: Action]

    /// Remove private elements (odd group numbers), including creators.
    public var removePrivateTags: Bool

    /// Remove every element in the repeating Overlay Plane groups
    /// (6000-601E, even groups). Overlay graphics may contain identifying
    /// text or annotations even when the image pixels themselves are kept.
    public var removeOverlayPlanes: Bool

    /// Remove every DA, DT, and TM element that has no explicit per-tag action.
    ///
    /// PS3.15 Table E.1-1 is extensible; applying the rule by VR prevents newly
    /// standardized temporal attributes from silently retaining identifiers.
    public var removeTemporalAttributes: Bool

    /// Exact replacements for the original UID found at each top-level tag.
    ///
    /// The source values seed the shared UID map before recursive rewriting, so
    /// references encountered earlier in the dataset receive the same catalog UID.
    public var uidReplacementsByTag: [Int: String]

    /// Exact UID-value replacements applied to every UI element, including
    /// values nested inside sequences.
    ///
    /// Unlike `.remapUID`, this map never invents a replacement for a value it
    /// does not contain. It is intended for transactional catalog re-keying,
    /// where internal study/series/instance relationships must move while SOP
    /// Class, coding-scheme, tracking, dimension-organization, and external
    /// reference UIDs remain byte-for-byte equivalent as values.
    public var uidValueReplacements: [String: String]

    /// Values written to De-identification Method (0012,0063). A non-nil value
    /// also records Patient Identity Removed (0012,0062) as YES.
    public var deidentificationMethod: [String]?

    /// Root prefix for remapped UIDs.
    ///
    /// Remapped UIDs are `"\(uidRoot).\(first).\(second)"` with two
    /// `UInt64` components of up to 20 decimal digits each, so the root
    /// must fit `maximumUIDRootLength` to keep every output inside the
    /// DICOM 64-character UI limit. Length is the only validated
    /// property; supplying a well-formed UID prefix (digits and dots)
    /// remains the caller's responsibility.
    public var uidRoot: String

    /// Longest `uidRoot` that keeps remapped UIDs within the DICOM
    /// 64-character maximum: 64 − 2 separators − 2 × 20-digit components.
    public static let maximumUIDRootLength = 22

    public init(
        actions: [Int: Action],
        removePrivateTags: Bool,
        removeOverlayPlanes: Bool = false,
        removeTemporalAttributes: Bool = false,
        uidReplacementsByTag: [Int: String] = [:],
        uidValueReplacements: [String: String] = [:],
        deidentificationMethod: [String]? = nil,
        uidRoot: String = "2.25"
    ) {
        self.actions = actions
        self.removePrivateTags = removePrivateTags
        self.removeOverlayPlanes = removeOverlayPlanes
        self.removeTemporalAttributes = removeTemporalAttributes
        self.uidReplacementsByTag = uidReplacementsByTag
        self.uidValueReplacements = uidValueReplacements
        self.deidentificationMethod = deidentificationMethod
        self.uidRoot = uidRoot
    }

    /// UID attributes assigned the `U` action by PS3.15 Table E.1-1 (2026c).
    /// SOP Class and coding-scheme UIDs are intentionally not included.
    public static let basicConfidentialityUIDTags: Set<Int> = [
        0x0008_0017, // Acquisition UID
        0x0020_9161, // Concatenation UID
        0x3010_0006, // Conceptual Volume UID
        0x3010_0013, // Constituent Conceptual Volume UID
        0x0018_1002, // Device UID
        0x0400_0100, // Digital Signature UID
        0x0020_9164, // Dimension Organization UID
        0x300A_0013, // Dose Reference UID
        0x3010_006E, // Dosimetric Objective UID
        0x0008_0058, // Failed SOP Instance UID List
        0x0070_031A, // Fiducial UID
        DicomTag.frameOfReferenceUID.rawValue,
        0x0008_0014, // Instance Creator UID
        0x0008_3010, // Irradiation Event UID
        0x0028_1214, // Large Palette Color Lookup Table UID
        0x0018_100B, // Manufacturer's Device Class UID
        0x0002_0003, // Media Storage SOP Instance UID
        0x003A_0310, // Multiplex Group UID
        0x0040_A402, // Observation Subject UID (Trial)
        0x0040_A171, // Observation UID
        0x0028_1199, // Palette Color Lookup Table UID
        0x300A_0650, // Patient Setup UID
        0x0070_1101, // Presentation Display Collection UID
        0x0070_1102, // Presentation Sequence Collection UID
        0x0008_0019, // Pyramid UID
        0x3010_000B, // Referenced Conceptual Volume UID
        0x300A_0083, // Referenced Dose Reference UID
        0x3010_006F, // Referenced Dosimetric Objective UID
        0x3010_0031, // Referenced Fiducials UID
        0x3006_0024, // Referenced Frame of Reference UID
        0x0040_4023, // Referenced General Purpose SPS Transaction UID
        0x0040_A172, // Referenced Observation UID (Trial)
        DicomTag.referencedSOPInstanceUID.rawValue,
        0x0004_1511, // Referenced SOP Instance UID in File
        0x300A_0785, // Referenced Treatment Position Group UID
        0x3006_00C2, // Related Frame of Reference UID
        0x0000_1001, // Requested SOP Instance UID
        0x3010_003B, // RT Treatment Phase UID
        DicomTag.seriesInstanceUID.rawValue,
        DicomTag.sopInstanceUID.rawValue,
        0x3010_0015, // Source Conceptual Volume UID
        0x0064_0003, // Source Frame of Reference UID
        0x0040_0554, // Specimen UID
        0x0088_0140, // Storage Media File-set UID
        DicomTag.studyInstanceUID.rawValue,
        0x0020_0200, // Synchronization Frame of Reference UID
        0x300A_0054, // Table Top Position Alignment UID
        0x0018_2042, // Target UID
        0x0040_DB0D, // Template Extension Creator UID
        0x0040_DB0C, // Template Extension Organization UID
        0x0062_0021, // Tracking UID
        0x0008_1195, // Transaction UID
        0x300A_0609, // Treatment Position Group UID
        0x300A_0700, // Treatment Session UID
        0x0040_A124 // UID content item
    ]

    /// Baseline de-identification aligned with the high-risk categories in
    /// PS3.15 Table E.1-1: identity and common descriptor fields are removed or
    /// replaced, temporal VRs are removed, U-action UID chains are remapped, and
    /// private tags and repeating Overlay Plane groups are removed.
    ///
    /// This remains a baseline, not a claim of full Basic Application Level
    /// Confidentiality Profile conformance. In particular, it does not clean
    /// Pixel Data, recognizable visual features, graphics beyond 60xx Overlay
    /// Planes, structured content, descriptors generally, or safe private
    /// attributes.
    public static var defaultAnonymization: DicomRewritePolicy {
        var actions: [Int: Action] = [
            DicomTag.patientName.rawValue: .replace("ANONYMIZED"),
            DicomTag.patientID.rawValue: .replace("ANON"),
            0x0010_0030: .remove, // Patient Birth Date
            0x0010_0032: .remove, // Patient Birth Time
            0x0010_1001: .remove, // Other Patient Names
            0x0010_1002: .remove, // Other Patient IDs Sequence
            0x0010_1040: .remove, // Patient Address
            0x0010_2154: .remove, // Patient Telephone Numbers
            0x0008_0050: .replace(""), // Accession Number (type 2)
            DicomTag.studyID.rawValue: .replace(""), // Study ID (type 2)
            DicomTag.studyDescription.rawValue: .remove,
            DicomTag.seriesDescription.rawValue: .remove,
            0x0008_1010: .remove, // Station Name
            0x0008_0081: .remove, // Institution Address
            0x0008_1040: .remove, // Institutional Department Name
            0x0008_1048: .remove, // Physician(s) of Record
            0x0008_1050: .remove, // Performing Physician's Name
            0x0008_1060: .remove, // Name of Physician(s) Reading Study
            0x0008_1070: .remove, // Operators' Name
            0x0018_1000: .remove, // Device Serial Number
            0x0018_1030: .remove, // Protocol Name
            0x0008_0201: .remove, // Timezone Offset From UTC
            0x0010_21B0: .remove, // Additional Patient History
            0x0020_4000: .remove, // Image Comments
            0x0038_4000: .remove, // Visit Comments
            0x0040_1400: .remove, // Requested Procedure Comments
            0x0040_1001: .remove, // Requested Procedure ID
            0x0040_A027: .remove, // Verifying Organization
            0x0040_A075: .remove, // Verifying Observer Name
            0x0040_A123: .remove, // Person Name content item
            0x0040_A160: .replace("REDACTED"), // Text Value content item
            0x0070_0006: .replace("REDACTED"), // Unformatted Text Value
            DicomTag.referringPhysicianName.rawValue: .remove,
            DicomTag.institutionName.rawValue: .remove
        ]
        for tag in basicConfidentialityUIDTags {
            actions[tag] = .remapUID
        }
        return DicomRewritePolicy(
            actions: actions,
            removePrivateTags: true,
            removeOverlayPlanes: true,
            removeTemporalAttributes: true,
            deidentificationMethod: [
                "Isis DICOM Viewer PS3.15 Basic Confidentiality baseline",
                "Overlay Plane groups 6000-601E removed",
                "No Clean Pixel Data or Clean Structured Content options"
            ]
        )
    }
}

/// Policy misconfiguration detected before any rewrite output is produced.
public enum DicomRewritePolicyError: Error, Equatable, LocalizedError, Sendable {
    /// The UID root would push remapped UIDs past the DICOM 64-character
    /// maximum.
    case uidRootTooLong(root: String, maximumLength: Int)

    public var errorDescription: String? {
        switch self {
        case .uidRootTooLong(let root, let maximumLength):
            return "The UID root '\(root)' (\(root.count) characters) exceeds the "
                + "\(maximumLength)-character budget that keeps remapped UIDs within "
                + "the DICOM 64-character maximum."
        }
    }
}

/// One audited rewrite decision. Notes never carry original PHI values.
public struct DicomRewriteAuditEntry: Equatable, Sendable {
    public enum Disposition: String, Equatable, Sendable {
        case changed
        case removed
        case kept
        case blocked
        case unsupported
        case remapped
    }

    /// Element path, for example `(0010,0010)` or `(0008,1140)[0]/(0008,1155)`.
    public let path: String
    public let tag: Int
    public let disposition: Disposition
    public let note: String?

    public init(path: String, tag: Int, disposition: Disposition, note: String? = nil) {
        self.path = path
        self.tag = tag
        self.disposition = disposition
        self.note = note
    }
}

/// Pixel-data risks that the metadata-only anonymizer cannot resolve.
public enum DicomRewriteWarning: String, Equatable, Sendable {
    /// Burned In Annotation (0028,0301) explicitly says identifying text is present.
    case burnedInAnnotationPresent
    /// Pixel Data exists, but Burned In Annotation is absent or not a recognized value.
    case burnedInAnnotationUnknown
}

/// Result of one safe rewrite operation.
public struct DicomRewriteResult: Sendable {
    /// The rewritten Part 10 file bytes.
    public let fileData: Data
    /// The rewritten dataset (pixel data bytes included).
    public let dataSet: DicomDataSet
    /// Audit of every policy decision.
    public let audit: [DicomRewriteAuditEntry]
    /// Deterministic original-UID to remapped-UID mapping.
    public let uidMap: [String: String]
    /// Risks that require operator review because Pixel Data is preserved.
    public let warnings: [DicomRewriteWarning]
}

/// Safe Part 10 rewrite / anonymization engine.
public struct DicomAnonymizer {
    /// Pixel-structure tags the policy is never allowed to alter.
    static let structuralTags: Set<Int> = [
        DicomTag.sopClassUID.rawValue,
        DicomTag.rows.rawValue,
        DicomTag.columns.rawValue,
        DicomTag.bitsAllocated.rawValue,
        DicomTag.bitsStored.rawValue,
        DicomTag.highBit.rawValue,
        DicomTag.pixelRepresentation.rawValue,
        DicomTag.samplesPerPixel.rawValue,
        DicomTag.photometricInterpretation.rawValue,
        DicomTag.numberOfFrames.rawValue,
        DicomTag.pixelData.rawValue
    ]

    public let policy: DicomRewritePolicy

    public init(policy: DicomRewritePolicy = .defaultAnonymization) {
        self.policy = policy
    }

    /// Rewrites a Part 10 file on disk.
    public func rewrite(contentsOf url: URL, fallbackSOPClassUID: String? = nil) throws -> DicomRewriteResult {
        let decoder = try DCMDecoder(contentsOf: url)
        return try rewrite(decoder: decoder, fallbackSOPClassUID: fallbackSOPClassUID)
    }

    /// Rewrites in-memory Part 10 bytes.
    public func rewrite(_ data: Data) throws -> DicomRewriteResult {
        let decoder = try DCMDecoder(data: data)
        return try rewrite(decoder: decoder, fallbackSOPClassUID: nil)
    }

    func rewrite(decoder: DCMDecoder, fallbackSOPClassUID: String?) throws -> DicomRewriteResult {
        guard policy.uidRoot.count <= DicomRewritePolicy.maximumUIDRootLength else {
            throw DicomRewritePolicyError.uidRootTooLong(
                root: policy.uidRoot,
                maximumLength: DicomRewritePolicy.maximumUIDRootLength
            )
        }
        let source = try DicomPart10PixelDataPreserver.dataSet(from: decoder)
        let warnings = Self.pixelDataWarnings(in: source)

        var state = RewriteState(policy: policy, source: source)
        var rewritten = rewriteDataSet(source, path: "", state: &state)
        recordDeidentificationMarkers(in: &rewritten)

        let transferSyntax = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID))
            ?? .explicitVRLittleEndian
        let sopClassUID = decoder.info(for: .sopClassUID)
        let outputSOPClassUID = sopClassUID.isEmpty ? fallbackSOPClassUID : sopClassUID
        let outputSOPInstanceUID = rewritten.string(for: .sopInstanceUID)
            ?? decoder.info(for: .sopInstanceUID)
        let sourceImplementationClassUID = decoder.info(for: 0x0002_0012)
        let sourceImplementationVersionName = decoder.info(for: 0x0002_0013)

        let fileData = try DicomDataSetWriter.part10Data(
            from: rewritten,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: outputSOPClassUID,
                mediaStorageSOPInstanceUID: outputSOPInstanceUID,
                implementationClassUID: sourceImplementationClassUID.isEmpty
                    ? DicomDataSetWriter.defaultImplementationClassUID
                    : sourceImplementationClassUID,
                implementationVersionName: sourceImplementationVersionName.isEmpty
                    ? "DICOMCORE_1"
                    : sourceImplementationVersionName
            )
        )
        return DicomRewriteResult(
            fileData: fileData,
            dataSet: rewritten,
            audit: state.audit,
            uidMap: state.uidMap,
            warnings: warnings
        )
    }

    // MARK: - Recursive policy application

    private struct RewriteState {
        let policy: DicomRewritePolicy
        var audit: [DicomRewriteAuditEntry] = []
        var uidMap: [String: String] = [:]

        init(policy: DicomRewritePolicy, source: DicomDataSet) {
            self.policy = policy
            uidMap = policy.uidValueReplacements
            for (tag, replacement) in policy.uidReplacementsByTag {
                for original in source.element(for: tag)?.stringValues ?? [] {
                    uidMap[original] = replacement
                }
            }
        }

        mutating func remappedUID(for original: String) -> String {
            if let existing = uidMap[original] {
                return existing
            }
            let remapped = DicomAnonymizer.deterministicUID(for: original, root: policy.uidRoot)
            uidMap[original] = remapped
            return remapped
        }
    }

    private func rewriteDataSet(_ dataSet: DicomDataSet, path: String, state: inout RewriteState) -> DicomDataSet {
        var output = DicomDataSet()
        for element in dataSet.elements {
            // File meta (group 0002) and group-length elements are owned by
            // the writer; never copy them into the output dataset body.
            let group = element.tag >> 16
            if group == 0x0002 || (element.tag & 0xFFFF) == 0 {
                continue
            }

            let elementPath = path + Self.tagPathComponent(element.tag)

            if state.policy.removePrivateTags, group % 2 == 1 {
                state.audit.append(DicomRewriteAuditEntry(
                    path: elementPath, tag: element.tag, disposition: .removed, note: "private element"
                ))
                continue
            }

            if state.policy.removeOverlayPlanes,
               group >= 0x6000, group <= 0x601E, group % 2 == 0 {
                state.audit.append(DicomRewriteAuditEntry(
                    path: elementPath,
                    tag: element.tag,
                    disposition: .removed,
                    note: "overlay plane element"
                ))
                continue
            }

            let action = state.policy.actions[element.tag]
                ?? (state.policy.removeTemporalAttributes && Self.temporalVRs.contains(element.vr) ? .remove : .keep)

            if Self.structuralTags.contains(element.tag), action != .keep {
                state.audit.append(DicomRewriteAuditEntry(
                    path: elementPath, tag: element.tag, disposition: .blocked,
                    note: "structural element; the policy action was not applied"
                ))
                output.set(element)
                continue
            }

            switch action {
            case .keep:
                if case .sequence(let items) = element.value {
                    var rewrittenItems = [DicomSequenceItem]()
                    for (index, item) in items.enumerated() {
                        let itemPath = elementPath + "[\(index)]/"
                        rewrittenItems.append(DicomSequenceItem(
                            dataSet: rewriteDataSet(item.dataSet, path: itemPath, state: &state)
                        ))
                    }
                    output.set(DicomDataElement(
                        tag: element.tag, vr: element.vr, value: .sequence(rewrittenItems), name: element.name
                    ))
                } else if element.vr == .UI {
                    let originals = element.stringValues
                    let replacements = originals.map { state.policy.uidValueReplacements[$0] ?? $0 }
                    if replacements != originals {
                        output.set(DicomDataElement(
                            tag: element.tag,
                            vr: element.vr,
                            value: .strings(replacements),
                            name: element.name
                        ))
                        state.audit.append(DicomRewriteAuditEntry(
                            path: elementPath,
                            tag: element.tag,
                            disposition: .remapped,
                            note: "uid replaced from explicit value map"
                        ))
                    } else {
                        output.set(element)
                    }
                } else {
                    output.set(element)
                }

            case .remove:
                state.audit.append(DicomRewriteAuditEntry(
                    path: elementPath, tag: element.tag, disposition: .removed
                ))

            case .replace(let replacement):
                if case .sequence = element.value {
                    state.audit.append(DicomRewriteAuditEntry(
                        path: elementPath, tag: element.tag, disposition: .unsupported,
                        note: "replace is not defined for sequences; element kept"
                    ))
                    output.set(element)
                } else {
                    output.set(DicomDataElement(
                        tag: element.tag,
                        vr: element.vr,
                        value: replacement.isEmpty ? .empty : .strings([replacement]),
                        name: element.name
                    ))
                    state.audit.append(DicomRewriteAuditEntry(
                        path: elementPath, tag: element.tag, disposition: .changed,
                        note: "replaced with policy value"
                    ))
                }

            case .remapUID:
                let originals = element.stringValues
                guard !originals.isEmpty else {
                    state.audit.append(DicomRewriteAuditEntry(
                        path: elementPath, tag: element.tag, disposition: .unsupported,
                        note: "remapUID requires a UI string value; element kept"
                    ))
                    output.set(element)
                    continue
                }
                let remapped = originals.map { state.remappedUID(for: $0) }
                output.set(DicomDataElement(
                    tag: element.tag, vr: element.vr, value: .strings(remapped), name: element.name
                ))
                state.audit.append(DicomRewriteAuditEntry(
                    path: elementPath, tag: element.tag, disposition: .remapped,
                    note: "uid remapped deterministically"
                ))
            }
        }
        return output
    }

    private func recordDeidentificationMarkers(in dataSet: inout DicomDataSet) {
        guard let method = policy.deidentificationMethod else { return }
        dataSet.set(DicomDataElement(
            tag: 0x0012_0062,
            vr: .CS,
            value: .strings(["YES"]),
            name: "Patient Identity Removed"
        ))
        dataSet.set(DicomDataElement(
            tag: 0x0012_0063,
            vr: .LO,
            value: .strings(method),
            name: "De-identification Method"
        ))
        if policy.removeTemporalAttributes {
            dataSet.set(DicomDataElement(
                tag: 0x0028_0303,
                vr: .CS,
                value: .strings(["REMOVED"]),
                name: "Longitudinal Temporal Information Modified"
            ))
        }
    }

    // MARK: - Helpers

    private static let temporalVRs: Set<DicomVR> = [.DA, .DT, .TM]

    private static func pixelDataWarnings(in dataSet: DicomDataSet) -> [DicomRewriteWarning] {
        guard dataSet.element(for: DicomTag.pixelData.rawValue) != nil else { return [] }
        let annotation = dataSet.string(for: 0x0028_0301)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        switch annotation {
        case "NO":
            return []
        case "YES":
            return [.burnedInAnnotationPresent]
        default:
            return [.burnedInAnnotationUnknown]
        }
    }

    /// Deterministic replacement UID: stable for the same input across
    /// operations, so cross-file study/series relationships also hold.
    static func deterministicUID(for original: String, root: String) -> String {
        var first: UInt64 = 0xcbf29ce484222325
        for byte in original.utf8 {
            first ^= UInt64(byte)
            first = first &* 0x100000001b3
        }
        var second: UInt64 = 0x9e3779b97f4a7c15
        for byte in original.utf8 {
            second = (second &* 31) &+ UInt64(byte)
        }
        return "\(root).\(first).\(second)"
    }

    private static func tagPathComponent(_ tag: Int) -> String {
        String(format: "(%04X,%04X)", (tag >> 16) & 0xFFFF, tag & 0xFFFF)
    }
}
