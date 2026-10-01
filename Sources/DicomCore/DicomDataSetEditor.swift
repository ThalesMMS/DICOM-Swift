//
//  DicomDataSetEditor.swift
//
//  Path-addressed attribute and sequence edits with identity-aware UID replacement, applied to a data set
//  or to a Part 10 file through the validated rewriter.
//

import Foundation

/// A reusable edit plan: attribute/sequence changes by path plus identity changes that update every reference.
///
/// A UID is never "just a string": replacing one rewrites every UI value equal to it at every nesting level, so a
/// Referenced SOP Instance UID or a Frame of Reference UID inside a sequence follows the top-level change.
/// Regenerating an identity scope derives the replacement from the data set and records it so the caller can
/// apply the same mapping to sibling instances (a series or study renamed consistently across files).
public struct DicomDataSetEdit: Equatable, Sendable {
    public enum IdentityScope: String, Equatable, Sendable, CaseIterable {
        case instance, series, study, frameOfReference

        var tag: DicomTag {
            switch self {
            case .instance: return .sopInstanceUID
            case .series: return .seriesInstanceUID
            case .study: return .studyInstanceUID
            case .frameOfReference: return .frameOfReferenceUID
            }
        }
    }

    public enum Operation: Equatable, Sendable {
        /// Sets the element at the path (VR and value from the element; the tag comes from the path).
        case set(DicomTagPath, DicomDataElement)
        /// Removes the element (or sequence item) at the path.
        case remove(DicomTagPath)
        /// Replaces one UID everywhere it appears, references included.
        case replaceUID(old: String, new: String)
        /// Replaces the identity UID of the scope with a freshly generated one, references included.
        case regenerateUID(IdentityScope)
    }

    public var operations: [Operation]
    /// Missing intermediate sequence items are created when a `set` path points at the next index.
    public var createsItems: Bool

    public init(operations: [Operation] = [], createsItems: Bool = false) {
        self.operations = operations
        self.createsItems = createsItems
    }
}

public enum DicomDataSetEditError: Error, Equatable, Sendable, CustomStringConvertible {
    /// File meta, group-length and pixel-structure elements are owned by the writer and the pixel path.
    case protectedElement(DicomTagPath)
    /// Identity UIDs are replaced through `replaceUID`/`regenerateUID`, never set or removed directly.
    case identityRequiresReplacement(DicomTagPath)
    /// The text cannot be encoded in the data set's Specific Character Set.
    case unrepresentableText(DicomTagPath)
    /// The UID to replace does not occur in the data set.
    case uidNotPresent(String)
    /// The replacement is not a valid UID or collides with another UID already in the data set.
    case invalidReplacementUID(String)
    /// The identity scope has no UID in the data set.
    case identityScopeMissing(DicomDataSetEdit.IdentityScope)
    case path(DicomTagPathError)

    public var description: String {
        switch self {
        case .protectedElement(let path): return "\(path) is owned by the file meta or the pixel structure"
        case .identityRequiresReplacement(let path): return "\(path) is an identity UID; use replaceUID/regenerateUID so references follow"
        case .unrepresentableText(let path): return "\(path): value is not representable in the data set's Specific Character Set"
        case .uidNotPresent(let uid): return "UID \(uid) does not occur in the data set"
        case .invalidReplacementUID(let uid): return "\(uid) is not a valid replacement UID or already identifies something else"
        case .identityScopeMissing(let scope): return "the data set has no \(scope.rawValue) UID to regenerate"
        case .path(let error): return "\(error)"
        }
    }
}

/// Result of applying an edit plan in memory.
public struct DicomDataSetEditResult: Equatable, Sendable {
    public let dataSet: DicomDataSet
    /// Every UID replacement performed (old → new), for propagation to related instances.
    public let uidReplacements: [String: String]
    /// The recursive difference between source and result.
    public let diff: DicomDataSetDiff
}

public enum DicomDataSetEditor {
    static let protectedTags: Set<Int> = [
        DicomTag.sopClassUID.rawValue, DicomTag.rows.rawValue, DicomTag.columns.rawValue, DicomTag.bitsAllocated.rawValue,
        DicomTag.bitsStored.rawValue, DicomTag.highBit.rawValue, DicomTag.pixelRepresentation.rawValue,
        DicomTag.samplesPerPixel.rawValue, DicomTag.photometricInterpretation.rawValue, DicomTag.numberOfFrames.rawValue,
        DicomTag.pixelData.rawValue, DicomTag.transferSyntaxUID.rawValue
    ]
    static let identityTags: Set<Int> = Set(DicomDataSetEdit.IdentityScope.allCases.map(\.tag.rawValue))

    /// Applies the plan to a data set; `makeUID` supplies replacements for regenerated scopes.
    public static func apply(_ edit: DicomDataSetEdit, to source: DicomDataSet,
                             makeUID: () -> String = DicomDataSetWriter.makeUID) throws -> DicomDataSetEditResult {
        var dataSet = source
        var replacements: [String: String] = [:]
        for operation in edit.operations {
            let characterSet = DicomSpecificCharacterSet(dataSet.string(for: .specificCharacterSet))
            switch operation {
            case .set(let path, let element):
                guard let last = path.last else { continue }
                try checkEditable(path, tag: last.tag, dataSet: dataSet)
                if path.isTopLevel, identityTags.contains(last.tag) {
                    throw DicomDataSetEditError.identityRequiresReplacement(path)
                }
                if case .strings(let values) = element.value, element.vr != .UI {
                    for value in values where (try? characterSet.encodeValidated(value, vr: element.vr)) == nil {
                        throw DicomDataSetEditError.unrepresentableText(path)
                    }
                }
                do { dataSet = try dataSet.setting(element, at: path, creatingItems: edit.createsItems) } catch let error as DicomTagPathError {
                    throw DicomDataSetEditError.path(error)
                }
            case .remove(let path):
                guard let last = path.last else { continue }
                try checkEditable(path, tag: last.tag, dataSet: dataSet)
                if path.isTopLevel, identityTags.contains(last.tag) { throw DicomDataSetEditError.identityRequiresReplacement(path) }
                do { dataSet = try dataSet.removing(at: path) } catch let error as DicomTagPathError {
                    throw DicomDataSetEditError.path(error)
                }
            case .replaceUID(let old, let new):
                try replace(old, with: new, in: &dataSet, replacements: &replacements)
            case .regenerateUID(let scope):
                guard let old = dataSet.string(for: scope.tag), !old.isEmpty else { throw DicomDataSetEditError.identityScopeMissing(scope) }
                try replace(old, with: makeUID(), in: &dataSet, replacements: &replacements)
            }
        }
        return DicomDataSetEditResult(dataSet: dataSet, uidReplacements: replacements,
                                      diff: DicomDataSetDiff.compare(source, dataSet, options: .init(ignoresFileMeta: true, normalizesText: false)))
    }

    /// Applies the plan to a Part 10 file: the source is decoded with Pixel Data preserved, the plan is applied in
    /// memory, and the changed top-level elements plus UID replacements go through the validated rewriter so the
    /// transfer syntax, pixel bytes and every UID round-trip are checked on the reopened output.
    public static func apply(_ edit: DicomDataSetEdit, toPart10 data: Data,
                             makeUID: () -> String = DicomDataSetWriter.makeUID) throws -> (result: DicomPart10RewriteResult, edit: DicomDataSetEditResult) {
        let decoder = try DCMDecoder(data: data)
        let source = try DicomPart10PixelDataPreserver.dataSet(from: decoder)
        let edited = try apply(edit, to: source, makeUID: makeUID)
        // Top-level elements whose subtree changed are replaced whole; UID replacements are applied recursively by
        // the rewriter itself so the same mapping reaches every nested reference it validates.
        var replaced: [DicomDataElement] = []
        var removed: Set<Int> = []
        let sourceAfterUIDs = try apply(DicomDataSetEdit(operations: edited.uidReplacements.map { .replaceUID(old: $0.key, new: $0.value) }), to: source).dataSet
        for change in DicomDataSetDiff.compare(sourceAfterUIDs, edited.dataSet, options: .init(ignoresFileMeta: true, normalizesText: false)).changes {
            guard let top = change.path.components.first else { continue }
            if change.kind == .removed, change.path.isTopLevel { removed.insert(top.tag); continue }
            if let element = edited.dataSet[top.tag] { replaced.append(element) }
        }
        var seen: Set<Int> = []
        replaced = replaced.filter { seen.insert($0.tag).inserted }
        let result = try DicomPart10Rewriter().rewrite(decoder: decoder, replacing: replaced, removing: removed,
                                                       uidValueReplacements: edited.uidReplacements)
        return (result, edited)
    }

    public static func apply(_ edit: DicomDataSetEdit, toPart10At url: URL,
                             makeUID: () -> String = DicomDataSetWriter.makeUID) throws -> (result: DicomPart10RewriteResult, edit: DicomDataSetEditResult) {
        try apply(edit, toPart10: try Data(contentsOf: url, options: .mappedIfSafe), makeUID: makeUID)
    }

    private static func checkEditable(_ path: DicomTagPath, tag: Int, dataSet: DicomDataSet) throws {
        if tag >> 16 == 0x0002 || tag & 0xFFFF == 0 || (path.isTopLevel && protectedTags.contains(tag)) {
            throw DicomDataSetEditError.protectedElement(path)
        }
    }

    private static func replace(_ old: String, with new: String, in dataSet: inout DicomDataSet, replacements: inout [String: String]) throws {
        let present = uidValues(in: dataSet)
        guard present.contains(old) else { throw DicomDataSetEditError.uidNotPresent(old) }
        guard isValidUID(new), new != old, !present.contains(new), replacements[new] == nil, !replacements.values.contains(new) else {
            throw DicomDataSetEditError.invalidReplacementUID(new)
        }
        dataSet = rewriting(dataSet, old: old, new: new)
        // A UID replaced twice in one plan maps the original to the final value.
        if let original = replacements.first(where: { $0.value == old })?.key {
            replacements[original] = new
        } else {
            replacements[old] = new
        }
    }

    /// PS3.5 9.1: dot-separated decimal components without leading zeros, at most 64 characters.
    public static func isValidUID(_ uid: String) -> Bool {
        dicomIsValidUID(uid)
    }

    /// Every UID value in the data set proper (file meta excluded), at every nesting level.
    public static func uidValues(in dataSet: DicomDataSet) -> Set<String> {
        var values: Set<String> = []
        for element in dataSet.elements where element.group != 0x0002 {
            if element.vr == .UI { values.formUnion(element.stringValues.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }) }
            if case .sequence(let items) = element.value { items.forEach { values.formUnion(uidValues(in: $0.dataSet)) } }
        }
        return values
    }

    private static func rewriting(_ dataSet: DicomDataSet, old: String, new: String) -> DicomDataSet {
        var result = DicomDataSet()
        for element in dataSet.elements {
            if case .sequence(let items) = element.value {
                result.set(DicomDataElement(tag: element.tag, vr: element.vr, value: .sequence(items.map { DicomSequenceItem(dataSet: rewriting($0.dataSet, old: old, new: new)) }), name: element.name))
            } else if element.vr == .UI, element.group != 0x0002 {
                result.set(DicomDataElement(tag: element.tag, vr: element.vr,
                                            value: .strings(element.stringValues.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) == old ? new : $0 }), name: element.name))
            } else {
                result.set(element)
            }
        }
        return result
    }
}
