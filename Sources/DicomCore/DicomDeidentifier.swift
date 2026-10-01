//
//  DicomDeidentifier.swift
//
//  PS3.15 Annex E de-identification driven by the versioned Table E.1-1 / E.3.10-1 resource: explicit
//  action per attribute and context, recursive over sequences and structured content, cohort-consistent
//  UID and date handling through a session, dry-run reports without PHI, and honest classification.
//

import Foundation

/// The Basic Application Level Confidentiality Profile plus the options a caller enables, with the
/// policies the Standard leaves to the implementation stated explicitly.
public struct DicomDeidentificationProfile: Equatable, Sendable {
    public typealias Option = DicomDeidentificationTable.Option

    /// What to do when Pixel Data may carry identifying text that this toolkit does not clean.
    public enum BurnedInPolicy: String, Equatable, Sendable, CaseIterable {
        /// Refuse the instance (default when Burned In Annotation says YES).
        case reject
        /// Produce the instance and classify it as incomplete.
        case flag
        /// Produce the instance; the caller asserts that pixels were reviewed.
        case accept
    }

    /// Caller overrides for individual attributes (applied at every nesting level after the table).
    public enum Override: Equatable, Sendable {
        case keep
        case remove
        case replace(String)
    }

    public var options: Set<Option>
    /// Burned In Annotation (0028,0301) = YES.
    public var burnedInAnnotationPolicy: BurnedInPolicy
    /// Pixel Data present and Burned In Annotation absent or not NO.
    public var unknownBurnedInPolicy: BurnedInPolicy
    /// Private elements not covered by the Retain Safe Private Option: removed unless the caller keeps them.
    public var keepsUnlistedPrivateElements: Bool
    /// DA/DT/TM elements Table E.1-1 does not list: removed, shifted with the modified-dates option or kept
    /// with the full-dates option, so an attribute added to the Standard after the table cannot leak a date.
    public var removesUnlistedTemporalAttributes: Bool
    public var overrides: [Int: Override]
    /// Free text recorded in De-identification Method (0012,0063) besides the profile and option names.
    public var methodDescription: String?

    public init(options: Set<Option> = [], burnedInAnnotationPolicy: BurnedInPolicy = .reject, unknownBurnedInPolicy: BurnedInPolicy = .flag,
                keepsUnlistedPrivateElements: Bool = false, removesUnlistedTemporalAttributes: Bool = true,
                overrides: [Int: Override] = [:], methodDescription: String? = nil) {
        self.options = options
        self.burnedInAnnotationPolicy = burnedInAnnotationPolicy
        self.unknownBurnedInPolicy = unknownBurnedInPolicy
        self.keepsUnlistedPrivateElements = keepsUnlistedPrivateElements
        self.removesUnlistedTemporalAttributes = removesUnlistedTemporalAttributes
        self.overrides = overrides
        self.methodDescription = methodDescription
    }

    /// Basic profile, no options.
    public static let basic = DicomDeidentificationProfile()

    /// Option combinations the Standard does not allow together.
    public func validate() throws {
        if options.contains(.retainLongitudinalFullDates), options.contains(.retainLongitudinalModifiedDates) {
            throw DicomDeidentificationError.conflictingOptions([.retainLongitudinalFullDates, .retainLongitudinalModifiedDates])
        }
        for tag in overrides.keys where tag >> 16 == 0x0002 || DicomDeidentifier.structuralTags.contains(tag) {
            throw DicomDeidentificationError.overrideNotAllowed(tag: tag)
        }
    }
}

public enum DicomDeidentificationError: Error, Equatable, Sendable, CustomStringConvertible {
    case conflictingOptions([DicomDeidentificationTable.Option])
    case overrideNotAllowed(tag: Int)
    case invalidUIDRoot
    case tableUnavailable
    case notPart10
    case unreadable(String)
    case rejected(DicomDeidentificationReport.Rejection)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .conflictingOptions(let options): return "options cannot be combined: \(options.map(\.rawValue).joined(separator: ", "))"
        case .overrideNotAllowed(let tag): return String(format: "override of (%04X,%04X) is not allowed", tag >> 16 & 0xFFFF, tag & 0xFFFF)
        case .invalidUIDRoot: return "UID root must contain non-empty numeric components without leading zeros"
        case .tableUnavailable: return "the PS3.15 table resource is unavailable"
        case .notPart10: return "input is not a Part 10 file"
        case .unreadable(let reason): return "input could not be decoded: \(reason)"
        case .rejected(let rejection): return "instance rejected: \(rejection.rawValue)"
        case .writeFailed(let reason): return "de-identified instance could not be written: \(reason)"
        }
    }
}

/// Cohort state shared by every instance of one de-identification operation: the UID map (every reference
/// to a remapped UID receives the same replacement across files) and the date shift. Mappings created while
/// processing an instance are committed only when that instance succeeds, so a failed or cancelled file
/// never leaves a mapping that a retry would reuse incorrectly.
/// The lock protects the map throughout each synchronous rewrite and commit, including concurrent callers.
public final class DicomDeidentificationSession: @unchecked Sendable {
    /// Exportable reversal material, produced only when the caller asks for it and never written into outputs.
    public struct ReversalKey: Codable, Equatable, Sendable {
        public var uidMap: [String: String]
        public var dateShiftDays: Int
        public var uidRoot: String
    }

    private let lock = NSLock()
    private var uidMap: [String: String]
    public let dateShiftDays: Int
    public let uidRoot: String

    /// A fresh session; the date shift is random in [-3650, -1] days unless given.
    public init(uidRoot: String = "2.25", dateShiftDays: Int? = nil) {
        self.uidRoot = uidRoot
        self.dateShiftDays = dateShiftDays ?? -Int.random(in: 1...3650)
        uidMap = [:]
    }

    /// Resumes a session from reversal material (same mappings, same shift).
    public init(reversalKey: ReversalKey) {
        uidRoot = reversalKey.uidRoot
        dateShiftDays = reversalKey.dateShiftDays
        uidMap = reversalKey.uidMap
    }

    /// Seeds mappings decided by the caller (for example catalog identities chosen before the rewrite).
    public func seed(_ replacements: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        uidMap.merge(replacements) { _, new in new }
    }

    public var mappingCount: Int { lock.lock(); defer { lock.unlock() }; return uidMap.count }

    public func replacement(for original: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return uidMap[original]
    }

    public func reversalKey() -> ReversalKey {
        lock.lock(); defer { lock.unlock() }
        return ReversalKey(uidMap: uidMap, dateShiftDays: dateShiftDays, uidRoot: uidRoot)
    }

    func withUIDMap<Result>(_ body: (inout [String: String]) throws -> Result) rethrows -> Result {
        lock.lock(); defer { lock.unlock() }
        return try body(&uidMap)
    }

    /// A fresh UID under the session root (2.25 UUID-derived, or the root plus the UUID digits).
    public func makeUID() throws -> String {
        guard uidRoot.count <= DicomRewritePolicy.maximumUIDRootLength else {
            throw DicomRewritePolicyError.uidRootTooLong(root: uidRoot, maximumLength: DicomRewritePolicy.maximumUIDRootLength)
        }
        let components = uidRoot.split(separator: ".", omittingEmptySubsequences: false)
        guard components.allSatisfy({ component in
            !component.isEmpty && component.utf8.allSatisfy { (0x30...0x39).contains($0) }
                && (component.count == 1 || component.first != "0")
        }) else { throw DicomDeidentificationError.invalidUIDRoot }
        let generated = DicomDataSetWriter.makeUID()
        return uidRoot == "2.25" ? generated : "\(uidRoot).\(generated.dropFirst(5))"
    }
}

/// What happened to one instance. Paths and tags only; original values never appear.
public struct DicomDeidentificationReport: Equatable, Sendable {
    public enum Classification: String, Equatable, Sendable {
        /// Every attribute received its profile action; nothing was left for review.
        case deidentifiedPerProfile
        /// The instance was produced but items remain that the toolkit could not process or verify.
        case incomplete
        /// The instance was not produced.
        case rejected
    }

    public enum Rejection: String, Equatable, Sendable {
        case burnedInAnnotation
        case unknownBurnedInAnnotation
    }

    /// Something the profile could not resolve by itself; listed for the operator.
    public struct Finding: Equatable, Sendable {
        public enum Kind: String, Equatable, Sendable {
            case burnedInAnnotation, unknownBurnedInAnnotation, descriptorRetained, encapsulatedDocumentReplaced
            case graphicsRemoved, privateRetained, unlistedTemporalRemoved, structuredContentReplaced
            case profileActionOverridden, temporalValueReplaced
        }

        public let kind: Kind
        public let path: String
        public let detail: String
    }

    public let sopClassUID: String
    public let classification: Classification
    public let rejection: Rejection?
    public let actions: [DicomRewriteAuditEntry]
    public let findings: [Finding]
    /// UID replacements this instance introduced or reused (original → replacement).
    public let uidReplacements: [String: String]
    public let dateShiftDays: Int?

    public var counts: [DicomRewriteAuditEntry.Disposition: Int] {
        Dictionary(actions.map { ($0.disposition, 1) }, uniquingKeysWith: +)
    }
}

/// Applies a `DicomDeidentificationProfile` to Part 10 instances through a shared session.
public struct DicomDeidentifier: Sendable {
    public typealias ActionCode = DicomDeidentificationTable.ActionCode

    static let structuralTags: Set<Int> = [
        DicomTag.sopClassUID.rawValue, DicomTag.rows.rawValue, DicomTag.columns.rawValue, DicomTag.bitsAllocated.rawValue,
        DicomTag.bitsStored.rawValue, DicomTag.highBit.rawValue, DicomTag.pixelRepresentation.rawValue, DicomTag.samplesPerPixel.rawValue,
        DicomTag.photometricInterpretation.rawValue, DicomTag.numberOfFrames.rawValue, DicomTag.pixelData.rawValue, DicomTag.transferSyntaxUID.rawValue,
        DicomTag.specificCharacterSet.rawValue, 0x0028_0006, 0x0028_0301
    ]
    static let temporalVRs: Set<DicomVR> = [.DA, .DT, .TM]
    static let textVRs: Set<DicomVR> = [.LO, .SH, .ST, .LT, .UT, .UC, .PN, .CS, .AE]

    public let profile: DicomDeidentificationProfile
    public let session: DicomDeidentificationSession
    public let table: DicomDeidentificationTable

    public init(profile: DicomDeidentificationProfile, session: DicomDeidentificationSession, table: DicomDeidentificationTable = .standard) throws {
        try profile.validate()
        guard !table.entries.isEmpty else { throw DicomDeidentificationError.tableUnavailable }
        self.profile = profile
        self.session = session
        self.table = table
    }

    /// Dry run: the report the instance would receive; the session is not changed.
    public func plan(_ data: Data) throws -> DicomDeidentificationReport {
        try process(data, commit: false).report
    }

    /// Produces the de-identified instance and commits new UID mappings to the session.
    public func apply(_ data: Data) throws -> (fileData: Data, report: DicomDeidentificationReport) {
        let outcome = try process(data, commit: true)
        guard let fileData = outcome.fileData else { throw DicomDeidentificationError.rejected(outcome.report.rejection ?? .burnedInAnnotation) }
        return (fileData, outcome.report)
    }

    public func apply(contentsOf url: URL) throws -> (fileData: Data, report: DicomDeidentificationReport) {
        try apply(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    // MARK: - Processing

    private struct State {
        var actions: [DicomRewriteAuditEntry] = []
        var findings: [DicomDeidentificationReport.Finding] = []
        var pendingUIDs: [String: String] = [:]
        var usedUIDs: [String: String] = [:]
        var known: [String: String]
    }

    private func process(_ data: Data, commit: Bool) throws -> (fileData: Data?, report: DicomDeidentificationReport) {
        try session.withUIDMap { known in
            try process(data, commit: commit, known: &known)
        }
    }

    private func process(_ data: Data, commit: Bool, known: inout [String: String]) throws -> (fileData: Data?, report: DicomDeidentificationReport) {
        guard DicomPart10FileMetaParser.hasPart10Prefix(data) else { throw DicomDeidentificationError.notPart10 }
        let decoder: DCMDecoder
        let source: DicomDataSet
        do {
            decoder = try DCMDecoder(data: data)
            source = try DicomPart10PixelDataPreserver.dataSet(from: decoder)
        } catch is CancellationError {
            throw CancellationError()
        } catch { throw DicomDeidentificationError.unreadable((error as? LocalizedError)?.errorDescription ?? "\(error)") }
        let sopClassUID = decoder.info(for: .sopClassUID)
        var state = State(known: known)
        var findings: [DicomDeidentificationReport.Finding] = []
        var rejection: DicomDeidentificationReport.Rejection?
        if source.contains(.pixelData) {
            let annotation = (source.string(for: 0x0028_0301) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
            if annotation == "YES" {
                if profile.burnedInAnnotationPolicy == .reject { rejection = .burnedInAnnotation }
                if profile.burnedInAnnotationPolicy != .accept { findings.append(.init(kind: .burnedInAnnotation, path: "(0028,0301)", detail: "Burned In Annotation is YES; pixels are not cleaned")) }
            } else if annotation != "NO" {
                if profile.unknownBurnedInPolicy == .reject { rejection = .unknownBurnedInAnnotation }
                if profile.unknownBurnedInPolicy != .accept { findings.append(.init(kind: .unknownBurnedInAnnotation, path: "(0028,0301)", detail: "Burned In Annotation absent or not NO; pixels are not verified")) }
            }
        }
        if let rejection {
            return (nil, DicomDeidentificationReport(sopClassUID: sopClassUID, classification: .rejected, rejection: rejection, actions: [], findings: findings,
                                                     uidReplacements: [:], dateShiftDays: nil))
        }
        try Task.checkCancellation()
        var output = try rewrite(source, path: "", state: &state, topLevel: true)
        record(in: &output, retainedByOverride: state.findings.contains { $0.kind == .profileActionOverridden })
        let transferSyntax = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID)) ?? .explicitVRLittleEndian
        let fileData: Data
        do {
            fileData = try DicomDataSetWriter.part10Data(from: output, options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax, mediaStorageSOPClassUID: output.string(for: .sopClassUID) ?? sopClassUID,
                mediaStorageSOPInstanceUID: output.string(for: .sopInstanceUID) ?? decoder.info(for: .sopInstanceUID)))
        } catch { throw DicomDeidentificationError.writeFailed("\(error)") }
        try verify(fileData, source: source, output: output, replacements: state.usedUIDs)
        try Task.checkCancellation()
        if commit { known.merge(state.pendingUIDs) { existing, _ in existing } }
        let allFindings = findings + state.findings
        let report = DicomDeidentificationReport(
            sopClassUID: sopClassUID,
            classification: allFindings.isEmpty ? .deidentifiedPerProfile : .incomplete,
            rejection: nil, actions: state.actions, findings: allFindings,
            uidReplacements: state.usedUIDs,
            dateShiftDays: profile.options.contains(.retainLongitudinalModifiedDates) ? session.dateShiftDays : nil)
        return (fileData, report)
    }

    /// Every UID that was remapped must be gone from the output; identity, pixel bytes and transfer syntax must survive.
    private func verify(_ fileData: Data, source: DicomDataSet, output: DicomDataSet, replacements: [String: String]) throws {
        let reopened: DCMDecoder
        let reread: DicomDataSet
        do {
            reopened = try DCMDecoder(data: fileData)
            reread = try DicomPart10PixelDataPreserver.dataSet(from: reopened)
        } catch is CancellationError {
            throw CancellationError()
        } catch { throw DicomDeidentificationError.writeFailed("reopen failed: \(error)") }
        let outputUIDs = DicomDataSetEditor.uidValues(in: reread)
        for original in replacements.keys where outputUIDs.contains(original) {
            throw DicomDeidentificationError.writeFailed("replaced UID still present")
        }
        guard reopened.info(for: 0x0002_0003) == output.string(for: .sopInstanceUID) else { throw DicomDeidentificationError.writeFailed("file meta identity differs") }
        guard reread.element(for: .pixelData)?.bytesValue == source.element(for: .pixelData)?.bytesValue else { throw DicomDeidentificationError.writeFailed("pixel bytes changed") }
        for element in reread.elements where element.group != 0x0002 && element.element != 0 && !Self.structuralTags.contains(element.tag) {
            guard let intended = output[element.tag], intended.vr == element.vr else { throw DicomDeidentificationError.writeFailed("element set differs after reopen") }
        }
    }

    // MARK: - Recursive rewrite

    private func rewrite(_ dataSet: DicomDataSet, path: String, state: inout State, topLevel: Bool) throws -> DicomDataSet {
        try Task.checkCancellation()
        var output = DicomDataSet()
        var privateCreators: [Int: DicomDataElement] = [:]
        for element in dataSet.elements {
            let group = element.group
            if group == 0x0002 || element.element == 0 { continue }
            let elementPath = path + Self.component(element.tag)
            // Private creators are decided after their block: kept only when a retained element needs them.
            if group.isMultiple(of: 2) == false, (0x0010...0x00FF).contains(element.element) {
                privateCreators[element.tag] = element
                continue
            }
            if let override = profile.overrides[element.tag] {
                apply(override: override, element, path: elementPath, into: &output, state: &state)
                continue
            }
            if Self.structuralTags.contains(element.tag) {
                output.set(element)
                state.actions.append(.init(path: elementPath, tag: element.tag, disposition: .kept, note: "structural"))
                continue
            }
            if group.isMultiple(of: 2) == false {
                try rewritePrivate(element, in: dataSet, path: elementPath, into: &output, state: &state)
                continue
            }
            let entry = table.entry(forTag: element.tag)
            let code = entry?.action(with: profile.options) ?? unlistedAction(for: element)
            try apply(code: code, entry: entry, element, path: elementPath, into: &output, state: &state)
        }
        let usedPrivateCreators = Set(output.elements.compactMap { element -> Int? in
            guard !element.group.isMultiple(of: 2), element.element >= 0x1000 else { return nil }
            return (element.tag & 0xFFFF_0000) | (element.element >> 8)
        })
        for (tag, creator) in privateCreators.sorted(by: { $0.key < $1.key }) {
            let block = tag & 0xFF
            if usedPrivateCreators.contains((tag & 0xFFFF_0000) | block) {
                output.set(creator)
                state.actions.append(.init(path: path + Self.component(tag), tag: tag, disposition: .kept, note: "private creator of retained elements"))
            } else {
                state.actions.append(.init(path: path + Self.component(tag), tag: tag, disposition: .removed, note: "private creator"))
            }
        }
        return output
    }

    private func unlistedAction(for element: DicomDataElement) -> ActionCode {
        if Self.temporalVRs.contains(element.vr), profile.removesUnlistedTemporalAttributes {
            if profile.options.contains(.retainLongitudinalFullDates) { return .keep }
            if profile.options.contains(.retainLongitudinalModifiedDates) { return .clean }
            return .remove
        }
        return .keep
    }

    private func rewritePrivate(_ element: DicomDataElement, in dataSet: DicomDataSet, path: String, into output: inout DicomDataSet, state: inout State) throws {
        let creatorTag = element.tag & 0xFFFF_0000 | (element.element >> 8)
        let creator = dataSet[creatorTag]?.stringValue ?? ""
        if profile.options.contains(.retainSafePrivate), table.isSafePrivate(tag: element.tag, creator: creator) {
            output.set(element)
            state.actions.append(.init(path: path, tag: element.tag, disposition: .kept, note: "safe private attribute"))
            return
        }
        if profile.keepsUnlistedPrivateElements {
            if case .sequence(let items) = element.value {
                var rewritten: [DicomSequenceItem] = []
                for (index, item) in items.enumerated() { rewritten.append(DicomSequenceItem(dataSet: try rewrite(item.dataSet, path: path + "[\(index)]/", state: &state, topLevel: false))) }
                output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .sequence(rewritten), name: element.name))
            } else {
                output.set(element)
            }
            state.actions.append(.init(path: path, tag: element.tag, disposition: .kept, note: "private element kept by policy"))
            state.findings.append(.init(kind: .privateRetained, path: path, detail: "private element retained without a safe-private listing"))
            return
        }
        state.actions.append(.init(path: path, tag: element.tag, disposition: .removed, note: "private element"))
    }

    private func apply(override: DicomDeidentificationProfile.Override, _ element: DicomDataElement, path: String, into output: inout DicomDataSet, state: inout State) {
        let retainsOriginal: Bool
        switch override {
        case .keep: retainsOriginal = true
        case .remove: retainsOriginal = false
        case .replace(let value): retainsOriginal = !value.isEmpty && element.stringValues.contains(value)
        }
        let entry = element.group.isMultiple(of: 2) ? table.entry(forTag: element.tag) : table.privateEntry
        let required = entry?.action(with: profile.options) ?? unlistedAction(for: element)
        if retainsOriginal, required != .keep {
            state.findings.append(.init(kind: .profileActionOverridden, path: path,
                                       detail: "caller override retains an attribute requiring de-identification"))
        }
        switch override {
        case .keep:
            output.set(element)
            state.actions.append(.init(path: path, tag: element.tag, disposition: .kept, note: "caller override"))
        case .remove:
            state.actions.append(.init(path: path, tag: element.tag, disposition: .removed, note: "caller override"))
        case .replace(let value):
            if case .sequence = element.value {
                state.actions.append(.init(path: path, tag: element.tag, disposition: .removed, note: "caller override (sequence cannot take a text value)"))
            } else {
                output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: value.isEmpty ? .empty : .strings([value]), name: element.name))
                state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "caller override"))
            }
        }
    }

    private func apply(code: ActionCode, entry: DicomDeidentificationTable.Entry?, _ element: DicomDataElement, path: String,
                       into output: inout DicomDataSet, state: inout State) throws {
        switch code {
        case .keep:
            output.set(element)
            state.actions.append(.init(path: path, tag: element.tag, disposition: .kept, note: entry == nil ? "not listed" : "K"))
        case .remove:
            state.actions.append(.init(path: path, tag: element.tag, disposition: .removed, note: entry == nil ? "unlisted temporal attribute" : "X"))
            if entry == nil { state.findings.append(.init(kind: .unlistedTemporalRemoved, path: path, detail: "date/time attribute outside Table E.1-1 removed")) }
        case .zero, .removeOrZero:
            // X/Z: emptying never breaks a Type 2 attribute and carries no identifying value.
            output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .empty, name: element.name))
            state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: code.rawValue))
        case .dummy, .removeOrDummy, .zeroOrDummy, .removeOrZeroOrDummy:
            // Compound codes ending in D: a dummy satisfies Type 1 and Type 2 alike.
            if element.vr == .SQ, code == .dummy || code == .removeOrZeroOrDummy {
                output.set(DicomDataElement(tag: element.tag, vr: .SQ, value: .empty, name: element.name))
                state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "\(code.rawValue): items removed"))
                if element.tag == DicomTag.contentSequence.rawValue {
                    state.findings.append(.init(kind: .structuredContentReplaced, path: path, detail: "structured content removed; enable Clean Structured Content to keep cleaned items"))
                }
            } else if element.vr == .UI {
                try remap(element, path: path, into: &output, state: &state, note: code.rawValue)
            } else {
                output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: Self.dummyValue(for: element.vr), name: element.name))
                state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "\(code.rawValue): dummy"))
                if element.tag == 0x0042_0011 { state.findings.append(.init(kind: .encapsulatedDocumentReplaced, path: path, detail: "encapsulated document replaced by a dummy payload; documents are not cleaned")) }
            }
        case .replaceUID, .removeOrZeroOrUID:
            if element.vr == .UI {
                try remap(element, path: path, into: &output, state: &state, note: code.rawValue)
            } else if case .sequence(let items) = element.value {
                var rewritten: [DicomSequenceItem] = []
                for (index, item) in items.enumerated() { rewritten.append(DicomSequenceItem(dataSet: try rewrite(item.dataSet, path: path + "[\(index)]/", state: &state, topLevel: false))) }
                output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .sequence(rewritten), name: element.name))
                state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "\(code.rawValue): items rewritten"))
            } else {
                output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .empty, name: element.name))
                state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "\(code.rawValue): zeroed"))
            }
        case .clean:
            try clean(element, entry: entry, path: path, into: &output, state: &state)
        }
    }

    private func remap(_ element: DicomDataElement, path: String, into output: inout DicomDataSet, state: inout State, note: String) throws {
        let originals = element.stringValues.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\0 ")) }
        guard !originals.isEmpty, originals.contains(where: { !$0.isEmpty }) else {
            output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .empty, name: element.name))
            state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "\(note): empty UID"))
            return
        }
        let replaced = try originals.map { original -> String in
            if original.isEmpty { return original }
            if let known = state.known[original] { return known }
            if let pending = state.pendingUIDs[original] { return pending }
            let fresh = try session.makeUID()
            state.pendingUIDs[original] = fresh
            return fresh
        }
        for (original, replacement) in zip(originals, replaced) where !original.isEmpty {
            state.usedUIDs[original] = replacement
        }
        output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .strings(replaced), name: element.name))
        state.actions.append(.init(path: path, tag: element.tag, disposition: .remapped, note: "\(note): uid remapped"))
    }

    private func clean(_ element: DicomDataElement, entry: DicomDeidentificationTable.Entry?, path: String, into output: inout DicomDataSet, state: inout State) throws {
        if Self.temporalVRs.contains(element.vr) {
            guard profile.options.contains(.retainLongitudinalModifiedDates) else {
                // Clean Descriptors/Structured Content may name a date row; without the dates option a dummy applies.
                output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: Self.dummyValue(for: element.vr), name: element.name))
                state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "C: dummy date"))
                return
            }
            let shifted = element.stringValues.map { Self.shift($0, vr: element.vr, days: session.dateShiftDays) }
            guard shifted.allSatisfy({ $0 != nil }) else {
                output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: Self.dummyValue(for: element.vr), name: element.name))
                state.findings.append(.init(kind: .temporalValueReplaced, path: path,
                                           detail: "temporal value could not be shifted; replaced with a VR dummy"))
                state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "C: invalid date replaced"))
                return
            }
            let values = shifted.compactMap { $0 }
            output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: values.allSatisfy(\.isEmpty) ? .empty : .strings(values), name: element.name))
            state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "C: date shifted"))
            return
        }
        if case .sequence(let items) = element.value {
            if element.tag == DicomTag.contentSequence.rawValue {
                output.set(DicomDataElement(tag: element.tag, vr: .SQ, value: .sequence(try items.enumerated().map { index, item in
                    DicomSequenceItem(dataSet: try cleanContentItem(item.dataSet, path: path + "[\(index)]/", state: &state))
                }), name: element.name))
                state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "C: structured content cleaned"))
            } else {
                var rewritten: [DicomSequenceItem] = []
                for (index, item) in items.enumerated() { rewritten.append(DicomSequenceItem(dataSet: try rewrite(item.dataSet, path: path + "[\(index)]/", state: &state, topLevel: false))) }
                output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .sequence(rewritten), name: element.name))
                state.actions.append(.init(path: path, tag: element.tag, disposition: .changed, note: "C: items cleaned"))
            }
            return
        }
        if element.tag >> 16 >= 0x6000, element.tag >> 16 <= 0x601E {
            // Overlay bitmaps cannot be inspected for burned-in text; Clean Graphics removes them and says so.
            state.actions.append(.init(path: path, tag: element.tag, disposition: .removed, note: "C: overlay graphics removed"))
            state.findings.append(.init(kind: .graphicsRemoved, path: path, detail: "overlay data removed because bitmaps are not inspected"))
            return
        }
        if Self.textVRs.contains(element.vr) || element.vr == .UN {
            // Free text is kept for review: the toolkit does not detect identifiers inside descriptions.
            output.set(element)
            state.actions.append(.init(path: path, tag: element.tag, disposition: .kept, note: "C: retained for review"))
            state.findings.append(.init(kind: .descriptorRetained, path: path, detail: "descriptor retained; automated text cleaning is not performed"))
            return
        }
        output.set(element)
        state.actions.append(.init(path: path, tag: element.tag, disposition: .kept, note: "C: no identifying content for this VR"))
    }

    /// Clean Structured Content: identifying value types become dummies or shifted dates, codes and numerics
    /// stay, references are remapped, nested content is cleaned recursively.
    private func cleanContentItem(_ item: DicomDataSet, path: String, state: inout State) throws -> DicomDataSet {
        var output = DicomDataSet()
        let valueType = (item.string(for: .valueType) ?? "").uppercased()
        for element in item.elements {
            let elementPath = path + Self.component(element.tag)
            switch element.tag {
            case 0x0040_A160 where valueType == "TEXT":
                output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .strings(["REMOVED"]), name: element.name))
                state.actions.append(.init(path: elementPath, tag: element.tag, disposition: .changed, note: "C: text content item"))
            case 0x0040_A123:
                output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .strings(["ANONYMOUS"]), name: element.name))
                state.actions.append(.init(path: elementPath, tag: element.tag, disposition: .changed, note: "C: person name content item"))
            case 0x0040_A121, 0x0040_A122, 0x0040_A120:
                try apply(code: profile.options.contains(.retainLongitudinalModifiedDates) ? .clean : (profile.options.contains(.retainLongitudinalFullDates) ? .keep : .dummy),
                          entry: nil, element, path: elementPath, into: &output, state: &state)
            case 0x0040_A124:
                try remap(element, path: elementPath, into: &output, state: &state, note: "C")
            case DicomTag.contentSequence.rawValue:
                if case .sequence(let items) = element.value {
                    output.set(DicomDataElement(tag: element.tag, vr: .SQ, value: .sequence(try items.enumerated().map { index, child in
                        DicomSequenceItem(dataSet: try cleanContentItem(child.dataSet, path: elementPath + "[\(index)]/", state: &state))
                    }), name: element.name))
                }
            default:
                if element.group.isMultiple(of: 2) == false {
                    try rewritePrivate(element, in: item, path: elementPath, into: &output, state: &state)
                } else if let entry = table.entry(forTag: element.tag) {
                    try apply(code: entry.action(with: profile.options), entry: entry, element, path: elementPath, into: &output, state: &state)
                } else if case .sequence(let items) = element.value {
                    var rewritten: [DicomSequenceItem] = []
                    for (index, child) in items.enumerated() { rewritten.append(DicomSequenceItem(dataSet: try rewrite(child.dataSet, path: elementPath + "[\(index)]/", state: &state, topLevel: false))) }
                    output.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .sequence(rewritten), name: element.name))
                } else {
                    try apply(code: unlistedAction(for: element), entry: nil, element, path: elementPath, into: &output, state: &state)
                }
            }
        }
        return output
    }

    // MARK: - Markers

    private func record(in dataSet: inout DicomDataSet, retainedByOverride: Bool) {
        if retainedByOverride {
            var method = ["Incomplete de-identification: caller overrides retain attributes"]
            if let description = profile.methodDescription, !description.isEmpty { method.append(description) }
            dataSet.set(DicomDataElement(tag: 0x0012_0062, vr: .CS, value: .strings(["NO"])))
            dataSet.set(DicomDataElement(tag: 0x0012_0063, vr: .LO, value: .strings(method.map { String($0.prefix(64)) })))
            dataSet.remove(0x0012_0064)
            dataSet.remove(0x0028_0303)
            return
        }
        var method = ["PS3.15 Basic Application Level Confidentiality Profile (\(table.version))"]
        method += profile.options.sorted { $0.rawValue < $1.rawValue }.map(\.code.meaning)
        if let description = profile.methodDescription, !description.isEmpty { method.append(description) }
        dataSet.set(DicomDataElement(tag: 0x0012_0062, vr: .CS, value: .strings(["YES"])))
        dataSet.set(DicomDataElement(tag: 0x0012_0063, vr: .LO, value: .strings(method.map { String($0.prefix(64)) })))
        var codes: [(String, String)] = [("113100", "Basic Application Confidentiality Profile")]
        codes += profile.options.sorted { $0.rawValue < $1.rawValue }.map { ($0.code.value, $0.code.meaning) }
        dataSet.set(DicomDataElement(tag: 0x0012_0064, vr: .SQ, value: .sequence(codes.map { value, meaning in
            DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(tag: 0x0008_0100, vr: .SH, value: .strings([value])),
                DicomDataElement(tag: 0x0008_0102, vr: .SH, value: .strings(["DCM"])),
                DicomDataElement(tag: 0x0008_0104, vr: .LO, value: .strings([meaning]))
            ]))
        })))
        let temporal = profile.options.contains(.retainLongitudinalFullDates) ? "UNMODIFIED" : (profile.options.contains(.retainLongitudinalModifiedDates) ? "MODIFIED" : "REMOVED")
        dataSet.set(DicomDataElement(tag: 0x0028_0303, vr: .CS, value: .strings([temporal])))
    }

    // MARK: - Values

    static func dummyValue(for vr: DicomVR) -> DicomDataValue {
        switch vr {
        case .PN: return .strings(["ANONYMOUS"])
        case .DA: return .strings(["19000101"])
        case .TM: return .strings(["000000"])
        case .DT: return .strings(["19000101000000"])
        case .AS: return .strings(["000Y"])
        case .UI: return .strings([DicomDataSetWriter.makeUID()])
        case .IS, .DS: return .strings(["0"])
        case .CS: return .strings(["UNKNOWN"])
        case .US, .UL, .UV, .AT: return .unsignedIntegers([0])
        case .SS, .SL, .SV: return .signedIntegers([0])
        case .FL, .FD: return .floats([0])
        case .OB, .OW, .OD, .OF, .OL, .OV, .UN: return .bytes(Data([0, 0]))
        case .SQ: return .empty
        default: return .strings(["REMOVED"])
        }
    }

    /// Shifts a DA/DT value by whole days at its own precision (YYYY, YYYYMM, YYYYMMDD); TM is unchanged and
    /// the DT time zone offset is preserved, so intervals inside the cohort keep their meaning.
    static func shift(_ value: String, vr: DicomVR, days: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return value }
        switch vr {
        case .DA: return shiftDate(trimmed, days: days)
        case .DT:
            guard DicomTemporalValueValidator.valid(trimmed, vr: .DT, query: false) else { return nil }
            var body = trimmed
            var zone = ""
            if body.count >= 5, let sign = body.dropFirst(body.count - 5).first, sign == "+" || sign == "-" {
                zone = String(body.suffix(5)); body = String(body.dropLast(5))
            }
            let datePart = String(body.prefix(8)), rest = String(body.dropFirst(min(8, body.count)))
            guard let shifted = shiftDate(datePart, days: days) else { return nil }
            return shifted + rest + zone
        default: return trimmed
        }
    }

    private static func shiftDate(_ text: String, days: Int) -> String? {
        let digits = text
        guard [4, 6, 8].contains(digits.count),
              DicomTemporalValueValidator.valid(digits, vr: .DT, query: false),
              let year = Int(digits.prefix(4)) else { return nil }
        let month = digits.count >= 6 ? Int(digits.dropFirst(4).prefix(2)) ?? 1 : 1
        let day = digits.count == 8 ? Int(digits.suffix(2)) ?? 1 : 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              let shifted = calendar.date(byAdding: .day, value: days, to: date) else { return nil }
        let components = calendar.dateComponents([.era, .year, .month, .day], from: shifted)
        guard components.era == 1, let shiftedYear = components.year, (1...9999).contains(shiftedYear) else { return nil }
        switch digits.count {
        case 4: return String(format: "%04d", components.year ?? year)
        case 6: return String(format: "%04d%02d", components.year ?? year, components.month ?? month)
        default: return String(format: "%04d%02d%02d", components.year ?? year, components.month ?? month, components.day ?? day)
        }
    }

    static func component(_ tag: Int) -> String {
        String(format: "(%04X,%04X)", tag >> 16 & 0xFFFF, tag & 0xFFFF)
    }
}
