import Foundation

/// Safely edits Part 10 metadata while preserving transfer syntax, UID identity,
/// SOP Class, and Pixel Data. Every result is reopened and validated before return.
public struct DicomPart10Rewriter: Sendable {
    /// Creates a safe Part 10 metadata rewriter.
    public init() {}

    /// Inspects UID identity and reference values in a Part 10 file.
    public func inspectUIDs(contentsOf url: URL) throws -> DicomPart10UIDInspection {
        try inspectUIDs(in: DCMDecoder(contentsOf: url).dataSet)
    }

    /// Inspects UID identity and reference values in in-memory Part 10 bytes.
    public func inspectUIDs(_ data: Data) throws -> DicomPart10UIDInspection {
        try inspectUIDs(in: DCMDecoder(data: data).dataSet)
    }

    /// Inspects UID identity and reference values in a decoded dataset.
    public func inspectUIDs(in dataSet: DicomDataSet) -> DicomPart10UIDInspection {
        var allUIDValues = Set<String>()
        Self.collectUIDValues(in: dataSet, into: &allUIDValues)
        return DicomPart10UIDInspection(
            studyInstanceUID: dataSet.string(for: .studyInstanceUID),
            seriesInstanceUID: dataSet.string(for: .seriesInstanceUID),
            sopInstanceUID: dataSet.string(for: .sopInstanceUID),
            frameOfReferenceUIDs: Set(dataSet.element(for: .frameOfReferenceUID)?.stringValues ?? []),
            allUIDValues: allUIDValues
        )
    }

    /// Rewrites a Part 10 file, applying top-level elements and recursive exact UID replacements.
    public func rewrite(
        contentsOf url: URL,
        replacing elements: [DicomDataElement] = [],
        removing removedTags: Set<Int> = [],
        uidValueReplacements: [String: String] = [:]
    ) throws -> DicomPart10RewriteResult {
        try rewrite(
            decoder: DCMDecoder(contentsOf: url),
            replacing: elements,
            removing: removedTags,
            uidValueReplacements: uidValueReplacements
        )
    }

    /// Rewrites in-memory Part 10 bytes, applying top-level elements and recursive exact UID replacements.
    public func rewrite(
        _ data: Data,
        replacing elements: [DicomDataElement] = [],
        removing removedTags: Set<Int> = [],
        uidValueReplacements: [String: String] = [:]
    ) throws -> DicomPart10RewriteResult {
        try rewrite(
            decoder: DCMDecoder(data: data),
            replacing: elements,
            removing: removedTags,
            uidValueReplacements: uidValueReplacements
        )
    }

    /// Rewrites an already loaded decoder without parsing the source a second time.
    public func rewrite(
        decoder: DCMDecoder,
        replacing elements: [DicomDataElement] = [],
        removing removedTags: Set<Int> = [],
        uidValueReplacements: [String: String] = [:]
    ) throws -> DicomPart10RewriteResult {
        for element in elements where Self.disallowedEditTags.contains(element.tag)
            || element.group == 0x0002 || element.element == 0 {
            throw DicomPart10RewriteError.disallowedElement(tag: element.tag)
        }
        for tag in removedTags where Self.disallowedEditTags.contains(tag) || Self.disallowedRemovalTags.contains(tag)
            || tag >> 16 == 0x0002 || tag & 0xFFFF == 0 {
            throw DicomPart10RewriteError.disallowedElement(tag: tag)
        }
        let sourceTransferSyntaxUID = decoder.info(for: .transferSyntaxUID)
        guard let transferSyntax = DicomTransferSyntax(uid: sourceTransferSyntaxUID) else {
            throw DicomPart10RewriteError.unsupportedTransferSyntax(sourceTransferSyntaxUID)
        }

        let source = try DicomPart10PixelDataPreserver.dataSet(from: decoder)
        let sourcePixelBytes = source.element(for: .pixelData)?.bytesValue
        var rewritten = Self.rewriteUIDs(
            in: source,
            replacements: uidValueReplacements
        )
        for element in elements {
            rewritten.set(element)
        }
        for tag in removedTags where !elements.contains(where: { $0.tag == tag }) {
            rewritten.remove(tag)
        }

        let sourceImplementationClassUID = decoder.info(for: 0x0002_0012)
        let sourceImplementationVersionName = decoder.info(for: 0x0002_0013)
        let fileData = try DicomDataSetWriter.part10Data(
            from: rewritten,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: rewritten.string(for: .sopClassUID),
                mediaStorageSOPInstanceUID: rewritten.string(for: .sopInstanceUID),
                implementationClassUID: sourceImplementationClassUID.isEmpty
                    ? DicomDataSetWriter.defaultImplementationClassUID
                    : sourceImplementationClassUID,
                implementationVersionName: sourceImplementationVersionName.isEmpty
                    ? "DICOMCORE_1"
                    : sourceImplementationVersionName
            )
        )

        let reopened = try DCMDecoder(data: fileData)
        try Self.validate(
            source: source,
            intended: rewritten,
            reopened: reopened,
            sourceTransferSyntaxUID: sourceTransferSyntaxUID,
            sourcePixelBytes: sourcePixelBytes,
            edits: elements,
            removedTags: removedTags,
            uidValueReplacements: uidValueReplacements
        )
        return DicomPart10RewriteResult(
            fileData: fileData,
            dataSet: reopened.dataSet,
            transferSyntax: transferSyntax
        )
    }

    /// Identity elements a rewrite may replace but never drop.
    private static let disallowedRemovalTags: Set<Int> = [
        DicomTag.sopInstanceUID.rawValue,
        DicomTag.studyInstanceUID.rawValue,
        DicomTag.seriesInstanceUID.rawValue,
        DicomTag.transferSyntaxUID.rawValue
    ]

    private static let disallowedEditTags: Set<Int> = [
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

    private static func rewriteUIDs(
        in dataSet: DicomDataSet,
        replacements: [String: String]
    ) -> DicomDataSet {
        var result = DicomDataSet()
        for element in dataSet.elements {
            if element.group == 0x0002 || element.element == 0 {
                continue
            }
            if case .sequence(let items) = element.value {
                result.set(DicomDataElement(
                    tag: element.tag,
                    vr: element.vr,
                    value: .sequence(items.map {
                        DicomSequenceItem(dataSet: rewriteUIDs(in: $0.dataSet, replacements: replacements))
                    }),
                    name: element.name
                ))
            } else if element.vr == .UI {
                result.set(DicomDataElement(
                    tag: element.tag,
                    vr: element.vr,
                    value: .strings(element.stringValues.map { replacements[$0] ?? $0 }),
                    name: element.name
                ))
            } else {
                result.set(element)
            }
        }
        return result
    }

    private static func validate(
        source: DicomDataSet,
        intended: DicomDataSet,
        reopened: DCMDecoder,
        sourceTransferSyntaxUID: String,
        sourcePixelBytes: Data?,
        edits: [DicomDataElement],
        removedTags: Set<Int>,
        uidValueReplacements: [String: String]
    ) throws {
        var preservationFailures = [DicomPart10PreservationFailure]()
        if reopened.info(for: .transferSyntaxUID) != sourceTransferSyntaxUID {
            preservationFailures.append(.transferSyntax)
        }
        let editedTags = Set(edits.map(\.tag))
        if !editedTags.contains(DicomTag.sopClassUID.rawValue),
           reopened.dataSet.string(for: .sopClassUID) != source.string(for: .sopClassUID) {
            preservationFailures.append(.sopClassUID)
        }
        if reopened.info(for: 0x0002_0002) != intended.string(for: .sopClassUID) {
            preservationFailures.append(.mediaStorageSOPClassUID)
        }
        if reopened.info(for: 0x0002_0003) != intended.string(for: .sopInstanceUID) {
            preservationFailures.append(.mediaStorageSOPInstanceUID)
        }
        let reopenedPixels = try DicomPart10PixelDataPreserver.dataSet(from: reopened)
            .element(for: .pixelData)?.bytesValue
        if reopenedPixels != sourcePixelBytes {
            preservationFailures.append(.pixelData(
                beforeByteCount: sourcePixelBytes?.count,
                afterByteCount: reopenedPixels?.count
            ))
        }
        guard preservationFailures.isEmpty else {
            throw DicomPart10RewriteError.preservationFailed(preservationFailures)
        }

        guard uidValuesByPath(in: reopened.dataSet) == uidValuesByPath(in: intended) else {
            throw DicomPart10RewriteError.uidRoundTripFailed
        }
        let reopenedUIDValues = collectUIDValueSet(in: reopened.dataSet)
        let replacementUIDValues = Set(uidValueReplacements.values)
        for (original, replacement) in uidValueReplacements where
            replacement != original
            && !replacementUIDValues.contains(original)
            && reopenedUIDValues.contains(original) {
            throw DicomPart10RewriteError.replacedUIDRemains
        }
        for edit in edits {
            guard let actual = reopened.dataSet.element(for: edit.tag),
                  actual.vr == edit.vr, actual.value == edit.value else {
                throw DicomPart10RewriteError.editRoundTripFailed(tag: edit.tag)
            }
        }
        for tag in removedTags where !editedTags.contains(tag) && reopened.dataSet.contains(tag) {
            throw DicomPart10RewriteError.editRoundTripFailed(tag: tag)
        }
    }

    private static func uidValuesByPath(in dataSet: DicomDataSet, path: String = "") -> [String: [String]] {
        var values = [String: [String]]()
        for element in dataSet.elements where element.group != 0x0002 {
            let elementPath = path + String(format: "/%08X", element.tag)
            if element.vr == .UI {
                values[elementPath] = element.stringValues
            }
            if case .sequence(let items) = element.value {
                for (index, item) in items.enumerated() {
                    values.merge(uidValuesByPath(in: item.dataSet, path: "\(elementPath)[\(index)]")) {
                        _, new in new
                    }
                }
            }
        }
        return values
    }

    private static func collectUIDValueSet(in dataSet: DicomDataSet) -> Set<String> {
        var values = Set<String>()
        collectUIDValues(in: dataSet, into: &values)
        return values
    }

    private static func collectUIDValues(in dataSet: DicomDataSet, into values: inout Set<String>) {
        for element in dataSet.elements {
            if element.vr == .UI {
                values.formUnion(element.stringValues)
            }
            if case .sequence(let items) = element.value {
                for item in items {
                    collectUIDValues(in: item.dataSet, into: &values)
                }
            }
        }
    }
}
