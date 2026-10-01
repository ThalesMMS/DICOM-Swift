//
//  DicomInstanceMerger.swift
//
//  Merges classic single-frame CT/MR instances into one Legacy Converted Enhanced CT/MR multi-frame instance,
//  keeping geometry, per-frame attributes and provenance, and checking the result frame by frame.
//

import Foundation

/// Classic CT Image / MR Image Storage instances of one series and frame of reference, in one spatial stack,
/// become a Legacy Converted Enhanced CT/MR Image Storage instance (PS3.3 A.35.13 / A.35.14, C.7.6.16).
///
/// Attributes shared by every source stay at the top level; attributes that differ per source go to the
/// Unassigned Per-Frame Converted Attributes functional group, geometry and value transformations go to the
/// standard functional groups, and every frame records its source instance in the Conversion Source functional
/// group. Frames are ordered along the stack normal; combinations that are not representable (mixed
/// identities, pixel structures, orientations, compressed pixels, duplicate positions) are rejected with a
/// specific reason. Sources are never modified and receive no new attributes.
public struct DicomInstanceMerger: Sendable {
    public static let legacyConvertedCTSOPClassUID = "1.2.840.10008.5.1.4.1.1.2.2"
    public static let legacyConvertedMRSOPClassUID = "1.2.840.10008.5.1.4.1.1.4.4"
    static let ctImageStorage = "1.2.840.10008.5.1.4.1.1.2"
    static let mrImageStorage = "1.2.840.10008.5.1.4.1.1.4"

    public struct Identifiers: Equatable, Sendable {
        public let seriesInstanceUID: String
        public let sopInstanceUID: String
        public let dimensionOrganizationUID: String

        public init(seriesInstanceUID: String, sopInstanceUID: String, dimensionOrganizationUID: String) {
            self.seriesInstanceUID = seriesInstanceUID
            self.sopInstanceUID = sopInstanceUID
            self.dimensionOrganizationUID = dimensionOrganizationUID
        }
    }

    public struct Result: Equatable, Sendable {
        public let part10Data: Data
        public let sopClassUID: String
        public let sopInstanceUID: String
        public let seriesInstanceUID: String
        public let frameCount: Int
        /// Source SOP Instance UIDs in frame order (frame 1 first).
        public let sourceSOPInstanceUIDs: [String]
        /// Tags moved to the Unassigned Per-Frame Converted Attributes functional group because they differ per source.
        public let perFrameTags: [Int]
    }

    public enum MergeError: Error, Equatable, Sendable, CustomStringConvertible {
        case tooFewInstances(Int)
        case notPart10(index: Int)
        case unreadable(index: Int, reason: String)
        case unsupportedSOPClass(String)
        case mixedSOPClasses([String])
        case multiframeSource(sopInstanceUID: String)
        case encapsulatedPixelData(sopInstanceUID: String)
        case mixedTransferSyntax([String])
        case unsupportedTransferSyntax(String)
        case identityDiffers(attribute: String, values: [String])
        case duplicateSOPInstanceUID(String)
        case pixelStructureDiffers(attribute: String)
        case unsupportedPixelFormat(String)
        case missingGeometry(sopInstanceUID: String)
        case orientationDiffers(sopInstanceUID: String)
        case pixelSpacingDiffers(sopInstanceUID: String)
        case duplicatePosition(sopInstanceUIDs: [String])
        case pixelDataSizeMismatch(sopInstanceUID: String, expected: Int, actual: Int)
        case invalidIdentifier(String)
        case roundTripFailed(String)

        public var description: String {
            switch self {
            case .tooFewInstances(let count): return "merging needs at least two instances (\(count) given)"
            case .notPart10(let index): return "input \(index + 1) is not a Part 10 file"
            case .unreadable(let index, let reason): return "input \(index + 1) could not be decoded: \(reason)"
            case .unsupportedSOPClass(let uid): return "SOP Class \(uid) is not classic CT or MR Image Storage"
            case .mixedSOPClasses(let uids): return "inputs mix SOP Classes \(uids.joined(separator: ", "))"
            case .multiframeSource(let uid): return "\(uid) is already multi-frame"
            case .encapsulatedPixelData(let uid): return "\(uid) carries encapsulated (compressed) Pixel Data; merging keeps native pixels only"
            case .mixedTransferSyntax(let uids): return "inputs mix transfer syntaxes \(uids.joined(separator: ", "))"
            case .unsupportedTransferSyntax(let uid): return "transfer syntax \(uid) is outside the native merge profile"
            case .identityDiffers(let attribute, let values): return "\(attribute) differs between inputs: \(values.joined(separator: ", "))"
            case .duplicateSOPInstanceUID(let uid): return "SOP Instance UID \(uid) appears more than once"
            case .pixelStructureDiffers(let attribute): return "\(attribute) differs between inputs"
            case .unsupportedPixelFormat(let reason): return "unsupported pixel format: \(reason)"
            case .missingGeometry(let uid): return "\(uid) lacks Image Position/Orientation (Patient) or Pixel Spacing"
            case .orientationDiffers(let uid): return "\(uid) has a different Image Orientation (Patient); one stack only"
            case .pixelSpacingDiffers(let uid): return "\(uid) has a different Pixel Spacing"
            case .duplicatePosition(let uids): return "instances share one Image Position (Patient): \(uids.joined(separator: ", ")); temporal stacks are not merged"
            case .pixelDataSizeMismatch(let uid, let expected, let actual): return "\(uid) carries \(actual) pixel bytes, expected \(expected)"
            case .invalidIdentifier(let reason): return "invalid identifiers: \(reason)"
            case .roundTripFailed(let reason): return "merged instance failed verification: \(reason)"
            }
        }
    }

    public init() {}

    public func merge(contentsOf urls: [URL], identifiers: Identifiers? = nil) throws -> Result {
        try merge(try urls.map { try Data(contentsOf: $0, options: .mappedIfSafe) }, identifiers: identifiers)
    }

    public func merge(_ inputs: [Data], identifiers: Identifiers? = nil) throws -> Result {
        guard inputs.count >= 2 else { throw MergeError.tooFewInstances(inputs.count) }
        var sources: [Source] = []
        for (index, data) in inputs.enumerated() {
            guard DicomPart10FileMetaParser.hasPart10Prefix(data) else { throw MergeError.notPart10(index: index) }
            do { sources.append(try Source(decoder: try DCMDecoder(data: data))) } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MergeError.unreadable(index: index, reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            }
        }
        let sopClasses = Array(Set(sources.map(\.sopClassUID))).sorted()
        guard sopClasses.count == 1 else { throw MergeError.mixedSOPClasses(sopClasses) }
        let outputSOPClass: String
        switch sopClasses[0] {
        case Self.ctImageStorage: outputSOPClass = Self.legacyConvertedCTSOPClassUID
        case Self.mrImageStorage: outputSOPClass = Self.legacyConvertedMRSOPClassUID
        default: throw MergeError.unsupportedSOPClass(sopClasses[0])
        }
        for source in sources where source.frameCount != 1 { throw MergeError.multiframeSource(sopInstanceUID: source.sopInstanceUID) }
        for source in sources where source.encapsulated { throw MergeError.encapsulatedPixelData(sopInstanceUID: source.sopInstanceUID) }
        let syntaxes = Array(Set(sources.map(\.transferSyntaxUID))).sorted()
        guard syntaxes.count == 1 else { throw MergeError.mixedTransferSyntax(syntaxes) }
        guard let syntax = DicomTransferSyntax(uid: syntaxes[0]), [.explicitVRLittleEndian, .implicitVRLittleEndian].contains(syntax) else {
            throw MergeError.unsupportedTransferSyntax(syntaxes[0])
        }
        for (name, tag) in [("Study Instance UID", DicomTag.studyInstanceUID), ("Series Instance UID", .seriesInstanceUID),
                            ("Frame of Reference UID", .frameOfReferenceUID), ("Patient ID", .patientID)] {
            let values = Array(Set(sources.map { $0.dataSet.string(for: tag) ?? "" })).sorted()
            guard values.count == 1, tag == .patientID || !values[0].isEmpty else { throw MergeError.identityDiffers(attribute: name, values: values) }
        }
        var seen: Set<String> = []
        for source in sources where !seen.insert(source.sopInstanceUID).inserted { throw MergeError.duplicateSOPInstanceUID(source.sopInstanceUID) }
        for (name, tag) in [("Rows", DicomTag.rows), ("Columns", .columns), ("Bits Allocated", .bitsAllocated), ("Bits Stored", .bitsStored),
                            ("High Bit", .highBit), ("Pixel Representation", .pixelRepresentation), ("Samples per Pixel", .samplesPerPixel),
                            ("Photometric Interpretation", .photometricInterpretation)] {
            guard Set(sources.map { $0.dataSet.string(for: tag) ?? "" }).count == 1 else { throw MergeError.pixelStructureDiffers(attribute: name) }
        }
        let first = sources[0]
        guard first.dataSet.int(for: .samplesPerPixel) == 1, ["MONOCHROME1", "MONOCHROME2"].contains(first.dataSet.string(for: .photometricInterpretation) ?? ""),
              [8, 16].contains(first.dataSet.int(for: .bitsAllocated) ?? 0) else {
            throw MergeError.unsupportedPixelFormat("one MONOCHROME1/MONOCHROME2 sample of 8 or 16 bits per pixel")
        }
        let rows = first.dataSet.int(for: .rows) ?? 0, columns = first.dataSet.int(for: .columns) ?? 0, bitsAllocated = first.dataSet.int(for: .bitsAllocated) ?? 0
        let frameBytes = rows * columns * bitsAllocated / 8
        for source in sources where source.pixelBytes.count != frameBytes {
            throw MergeError.pixelDataSizeMismatch(sopInstanceUID: source.sopInstanceUID, expected: frameBytes, actual: source.pixelBytes.count)
        }
        // Geometry: one orientation, one spacing, distinct positions ordered along the normal.
        for source in sources where source.position == nil || source.orientation == nil || source.spacing == nil {
            throw MergeError.missingGeometry(sopInstanceUID: source.sopInstanceUID)
        }
        let orientation = first.orientation!, spacing = first.spacing!
        for source in sources.dropFirst() {
            guard Self.close(source.orientation!, orientation) else { throw MergeError.orientationDiffers(sopInstanceUID: source.sopInstanceUID) }
            guard Self.close(source.spacing!, spacing) else { throw MergeError.pixelSpacingDiffers(sopInstanceUID: source.sopInstanceUID) }
        }
        let normal = Self.cross(Array(orientation[0..<3]), Array(orientation[3..<6]))
        struct Ordered { let index: Int; let source: Source; let projection: Double }
        var ordered: [Ordered] = []
        for (index, source) in sources.enumerated() {
            ordered.append(Ordered(index: index, source: source, projection: Self.dot(source.position!, normal)))
        }
        ordered.sort { lhs, rhs in
            if lhs.projection == rhs.projection { return lhs.index < rhs.index }
            return lhs.projection < rhs.projection
        }
        for first in ordered.indices {
            for second in ordered.index(after: first)..<ordered.endIndex {
                guard abs(ordered[first].projection - ordered[second].projection) < 1e-4 else { break }
                if Self.close(ordered[first].source.position!, ordered[second].source.position!) {
                    throw MergeError.duplicatePosition(sopInstanceUIDs: [ordered[first].source.sopInstanceUID, ordered[second].source.sopInstanceUID])
                }
            }
        }
        let frames: [Source] = ordered.map { $0.source }

        let ids = try Self.validated(identifiers ?? Identifiers(seriesInstanceUID: DicomDataSetWriter.makeUID(), sopInstanceUID: DicomDataSetWriter.makeUID(),
                                                                dimensionOrganizationUID: DicomDataSetWriter.makeUID()), sources: sources)
        let (dataSet, perFrameTags) = Self.compose(frames: frames, sopClassUID: outputSOPClass, identifiers: ids, frameBytes: frameBytes)
        let part10 = try DicomDataSetWriter.part10Data(from: dataSet, options: DicomPart10WriterOptions(
            transferSyntax: .explicitVRLittleEndian, mediaStorageSOPClassUID: outputSOPClass, mediaStorageSOPInstanceUID: ids.sopInstanceUID))
        try Self.verify(part10, frames: frames, frameBytes: frameBytes, sopClassUID: outputSOPClass, identifiers: ids)
        return Result(part10Data: part10, sopClassUID: outputSOPClass, sopInstanceUID: ids.sopInstanceUID, seriesInstanceUID: ids.seriesInstanceUID,
                      frameCount: frames.count, sourceSOPInstanceUIDs: frames.map { $0.sopInstanceUID }, perFrameTags: perFrameTags)
    }

    // MARK: - Sources

    struct Source {
        let dataSet: DicomDataSet
        let sopClassUID: String
        let sopInstanceUID: String
        let transferSyntaxUID: String
        let frameCount: Int
        let encapsulated: Bool
        let pixelBytes: Data
        let position: [Double]?
        let orientation: [Double]?
        let spacing: [Double]?

        init(decoder: DCMDecoder) throws {
            encapsulated = decoder.compressedImage
            frameCount = max(decoder.nImages, Int(decoder.info(for: .numberOfFrames).trimmingCharacters(in: .whitespaces)) ?? 1)
            // Pixel bytes are recovered only for the single-frame native sources the merge accepts.
            dataSet = encapsulated || frameCount != 1 ? decoder.dataSet : try DicomPart10PixelDataPreserver.dataSet(from: decoder)
            sopClassUID = decoder.info(for: .sopClassUID)
            sopInstanceUID = decoder.info(for: .sopInstanceUID)
            transferSyntaxUID = decoder.info(for: .transferSyntaxUID)
            pixelBytes = encapsulated || frameCount != 1 ? Data() : (dataSet.element(for: .pixelData)?.bytesValue ?? Data())
            let position = dataSet.decimalStrings(for: .imagePositionPatient), orientation = dataSet.decimalStrings(for: .imageOrientationPatient)
            let spacing = dataSet.decimalStrings(for: .pixelSpacing)
            self.position = position.count == 3 ? position : nil
            self.orientation = orientation.count == 6 ? orientation : nil
            self.spacing = spacing.count == 2 ? spacing : nil
        }
    }

    private static func validated(_ identifiers: Identifiers, sources: [Source]) throws -> Identifiers {
        let outputs = [identifiers.seriesInstanceUID, identifiers.sopInstanceUID, identifiers.dimensionOrganizationUID]
        guard outputs.allSatisfy(DicomDataSetEditor.isValidUID) else { throw MergeError.invalidIdentifier("malformed UID") }
        guard Set(outputs).count == 3 else { throw MergeError.invalidIdentifier("output UIDs must be unique") }
        let existing = sources.reduce(into: Set<String>()) { $0.formUnion(DicomDataSetEditor.uidValues(in: $1.dataSet)) }
        guard existing.isDisjoint(with: outputs) else { throw MergeError.invalidIdentifier("output UIDs must differ from every UID in the sources") }
        return identifiers
    }

    // MARK: - Composition

    /// Top-level elements that move into functional groups or are owned by the multi-frame object.
    static let mappedTags: Set<Int> = [
        DicomTag.sopClassUID.rawValue, DicomTag.sopInstanceUID.rawValue, DicomTag.seriesInstanceUID.rawValue, DicomTag.instanceNumber.rawValue,
        DicomTag.pixelData.rawValue, DicomTag.numberOfFrames.rawValue, DicomTag.imageType.rawValue,
        DicomTag.imagePositionPatient.rawValue, DicomTag.imageOrientationPatient.rawValue, DicomTag.pixelSpacing.rawValue,
        DicomTag.sliceThickness.rawValue, DicomTag.sliceSpacing.rawValue,
        DicomTag.rescaleIntercept.rawValue, DicomTag.rescaleSlope.rawValue, DicomTag.rescaleType.rawValue,
        DicomTag.windowCenter.rawValue, DicomTag.windowWidth.rawValue, DicomTag.windowCenterWidthExplanation.rawValue, DicomTag.voiLUTFunction.rawValue,
        DicomTag.contentDate.rawValue, DicomTag.contentTime.rawValue, DicomTag.specificCharacterSet.rawValue
    ]

    private static func compose(frames: [Source], sopClassUID: String, identifiers: Identifiers, frameBytes: Int) -> (DicomDataSet, [Int]) {
        let first = frames[0].dataSet
        var top = DicomDataSet()
        var perFrameTags: [Int] = []
        // Shared: every element equal across all sources (file meta and group lengths excluded).
        for element in first.elements where element.group != 0x0002 && element.element != 0 && !mappedTags.contains(element.tag) {
            let same = frames.allSatisfy { $0.dataSet[element.tag].map { $0.vr == element.vr && $0.value == element.value } ?? false }
            if same { top.set(element) } else { perFrameTags.append(element.tag) }
        }
        for source in frames.dropFirst() {
            for element in source.dataSet.elements where element.group != 0x0002 && element.element != 0 && !mappedTags.contains(element.tag)
                && !top.contains(element.tag) && !perFrameTags.contains(element.tag) {
                perFrameTags.append(element.tag)
            }
        }
        perFrameTags.sort()
        if let charset = first[.specificCharacterSet] { top.set(charset) }
        func string(_ tag: DicomTag, _ vr: DicomVR, _ values: [String]) -> DicomDataElement { DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings(values)) }
        func decimals(_ values: [Double]) -> [String] { values.map { Self.decimal($0) } }
        top.set(string(.sopClassUID, .UI, [sopClassUID]))
        top.set(string(.sopInstanceUID, .UI, [identifiers.sopInstanceUID]))
        top.set(string(.seriesInstanceUID, .UI, [identifiers.seriesInstanceUID]))
        top.set(string(.instanceNumber, .IS, ["1"]))
        top.set(string(.numberOfFrames, .IS, [String(frames.count)]))
        let imageTypes = Set(frames.map { $0.dataSet.strings(for: .imageType) })
        var imageType = imageTypes.count == 1 ? frames[0].dataSet.strings(for: .imageType) : ["DERIVED", "PRIMARY"]
        if imageType.count < 2 { imageType = ["DERIVED", "PRIMARY"] }
        top.set(string(.imageType, .CS, imageType))
        let now = Date()
        let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.calendar = Calendar(identifier: .gregorian); dateFormatter.dateFormat = "yyyyMMdd"; dateFormatter.timeZone = .current
        let timeFormatter = DateFormatter(); timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.calendar = Calendar(identifier: .gregorian); timeFormatter.dateFormat = "HHmmss"; timeFormatter.timeZone = .current
        top.set(string(.contentDate, .DA, [Set(frames.map { $0.dataSet.string(for: .contentDate) ?? "" }).count == 1 ? (first.string(for: .contentDate) ?? dateFormatter.string(from: now)) : dateFormatter.string(from: now)]))
        top.set(string(.contentTime, .TM, [Set(frames.map { $0.dataSet.string(for: .contentTime) ?? "" }).count == 1 ? (first.string(for: .contentTime) ?? timeFormatter.string(from: now)) : timeFormatter.string(from: now)]))
        // Provenance at the top level: every source instance.
        top.set(DicomDataElement(tag: DicomTag.sourceImageSequence.rawValue, vr: .SQ, value: .sequence(frames.enumerated().map { index, source in
            DicomSequenceItem(dataSet: DicomDataSet(elements: [
                string(.referencedSOPClassUID, .UI, [source.sopClassUID]), string(.referencedSOPInstanceUID, .UI, [source.sopInstanceUID]),
                DicomDataElement(tag: 0x0008_1160, vr: .IS, value: .strings([String(index + 1)]))
            ]))
        })))
        top.set(string(.derivationDescription, .ST, ["Legacy conversion of \(frames.count) classic instances into one multi-frame instance"]))
        // Dimension organization: one stack, ordered by In-Stack Position Number.
        top.set(DicomDataElement(tag: DicomTag.dimensionOrganizationSequence.rawValue, vr: .SQ, value: .sequence([
            DicomSequenceItem(dataSet: DicomDataSet(elements: [string(.dimensionOrganizationUID, .UI, [identifiers.dimensionOrganizationUID])]))
        ])))
        top.set(DicomDataElement(tag: DicomTag.dimensionIndexSequence.rawValue, vr: .SQ, value: .sequence([DicomTag.stackID, DicomTag.inStackPositionNumber].map { pointer in
            DicomSequenceItem(dataSet: DicomDataSet(elements: [
                DicomDataElement(tag: DicomTag.dimensionIndexPointer.rawValue, vr: .AT, value: .unsignedIntegers([UInt(pointer.rawValue)])),
                DicomDataElement(tag: DicomTag.functionalGroupPointer.rawValue, vr: .AT, value: .unsignedIntegers([UInt(DicomTag.frameContentSequence.rawValue)])),
                string(.dimensionOrganizationUID, .UI, [identifiers.dimensionOrganizationUID])
            ]))
        })))
        // Shared functional groups.
        var shared: [DicomDataElement] = []
        var measures: [DicomDataElement] = [string(.pixelSpacing, .DS, decimals(frames[0].spacing!))]
        if let thickness = first[.sliceThickness], frames.allSatisfy({ $0.dataSet[.sliceThickness] == thickness }) { measures.append(thickness) }
        if frames.count > 1 {
            let normal = cross(Array(frames[0].orientation![0..<3]), Array(frames[0].orientation![3..<6]))
            let steps = zip(frames, frames.dropFirst()).map { dot($1.position!, normal) - dot($0.position!, normal) }
            if let step = steps.first, steps.allSatisfy({ abs($0 - step) < 1e-3 }) { measures.append(string(.sliceSpacing, .DS, [decimal(step)])) }
        }
        shared.append(DicomDataElement(tag: DicomTag.pixelMeasuresSequence.rawValue, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: measures))])))
        shared.append(DicomDataElement(tag: DicomTag.planeOrientationSequence.rawValue, vr: .SQ, value: .sequence([
            DicomSequenceItem(dataSet: DicomDataSet(elements: [string(.imageOrientationPatient, .DS, decimals(frames[0].orientation!))]))
        ])))
        func transformation(_ dataSet: DicomDataSet) -> DicomDataElement {
            var elements = [string(.rescaleIntercept, .DS, [decimal(dataSet.decimalString(for: .rescaleIntercept) ?? 0)]),
                            string(.rescaleSlope, .DS, [decimal(dataSet.decimalString(for: .rescaleSlope) ?? 1)])]
            if let type = dataSet[.rescaleType] { elements.append(type) }
            return DicomDataElement(tag: DicomTag.pixelValueTransformationSequence.rawValue, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: elements))]))
        }
        func voi(_ dataSet: DicomDataSet) -> DicomDataElement? {
            guard let centers = dataSet[.windowCenter], let widths = dataSet[.windowWidth] else { return nil }
            var elements = [centers, widths]
            if let explanation = dataSet[.windowCenterWidthExplanation] { elements.append(explanation) }
            if let function = dataSet[.voiLUTFunction] { elements.append(function) }
            return DicomDataElement(tag: DicomTag.frameVOILUTSequence.rawValue, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: elements))]))
        }
        let sharedTransformation = frames.allSatisfy { transformation($0.dataSet) == transformation(first) }
        let sharedVOI = frames.allSatisfy { voi($0.dataSet) == voi(first) }
        if sharedTransformation { shared.append(transformation(first)) }
        if sharedVOI, let element = voi(first) { shared.append(element) }
        top.set(DicomDataElement(tag: DicomTag.sharedFunctionalGroupsSequence.rawValue, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: shared))])))
        // Per-frame functional groups.
        var pixels = Data(capacity: frameBytes * frames.count)
        let perFrame = frames.enumerated().map { index, source -> DicomSequenceItem in
            pixels.append(source.pixelBytes)
            var groups: [DicomDataElement] = [
                DicomDataElement(tag: DicomTag.frameContentSequence.rawValue, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                    string(.stackID, .SH, ["1"]),
                    DicomDataElement(tag: DicomTag.inStackPositionNumber.rawValue, vr: .UL, value: .unsignedIntegers([UInt(index + 1)])),
                    DicomDataElement(tag: DicomTag.dimensionIndexValues.rawValue, vr: .UL, value: .unsignedIntegers([1, UInt(index + 1)]))
                ]))])),
                DicomDataElement(tag: DicomTag.planePositionSequence.rawValue, vr: .SQ, value: .sequence([
                    DicomSequenceItem(dataSet: DicomDataSet(elements: [string(.imagePositionPatient, .DS, decimals(source.position!))]))
                ])),
                DicomDataElement(tag: 0x0020_9172, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                    string(.referencedSOPClassUID, .UI, [source.sopClassUID]), string(.referencedSOPInstanceUID, .UI, [source.sopInstanceUID])
                ]))]))
            ]
            if !sharedTransformation { groups.append(transformation(source.dataSet)) }
            if !sharedVOI, let element = voi(source.dataSet) { groups.append(element) }
            let unassigned = perFrameTags.compactMap { source.dataSet[$0] }
            if !unassigned.isEmpty {
                groups.append(DicomDataElement(tag: 0x0020_9171, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: unassigned))])))
            }
            return DicomSequenceItem(dataSet: DicomDataSet(elements: groups))
        }
        top.set(DicomDataElement(tag: DicomTag.perFrameFunctionalGroupsSequence.rawValue, vr: .SQ, value: .sequence(perFrame)))
        top.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: (first.int(for: .bitsAllocated) ?? 16) > 8 ? .OW : .OB, value: .bytes(pixels)))
        return (top, perFrameTags)
    }

    // MARK: - Verification

    private static func verify(_ data: Data, frames: [Source], frameBytes: Int, sopClassUID: String, identifiers: Identifiers) throws {
        let decoder: DCMDecoder
        do { decoder = try DCMDecoder(data: data) } catch is CancellationError {
            throw CancellationError()
        } catch { throw MergeError.roundTripFailed("reopen failed: \(error)") }
        guard decoder.info(for: .sopClassUID) == sopClassUID, decoder.info(for: .sopInstanceUID) == identifiers.sopInstanceUID,
              decoder.info(for: 0x0002_0003) == identifiers.sopInstanceUID, decoder.nImages == frames.count else {
            throw MergeError.roundTripFailed("identity or frame count did not round-trip")
        }
        guard let groups = decoder.enhancedMultiframeFunctionalGroups, groups.perFrame.count == frames.count else {
            throw MergeError.roundTripFailed("functional groups did not round-trip")
        }
        let pixels = (try? DicomPart10PixelDataPreserver.dataSet(from: decoder))?.element(for: .pixelData)?.bytesValue ?? Data()
        guard pixels.count == frameBytes * frames.count else { throw MergeError.roundTripFailed("pixel bytes did not round-trip") }
        for (index, source) in frames.enumerated() {
            let start = pixels.startIndex + index * frameBytes
            guard pixels[start..<start + frameBytes] == source.pixelBytes else { throw MergeError.roundTripFailed("frame \(index + 1) pixel bytes differ") }
            guard let geometry = groups.geometry(forFrame: index), let position = geometry.imagePositionPatient,
                  close([position.x, position.y, position.z], source.position!) else {
                throw MergeError.roundTripFailed("frame \(index + 1) position did not round-trip")
            }
            let conversion = decoder.dataSet[.perFrameFunctionalGroupsSequence]?.sequenceItems[index][0x0020_9172]?.sequenceItems.first
            guard conversion?[.referencedSOPInstanceUID]?.stringValue == source.sopInstanceUID else {
                throw MergeError.roundTripFailed("frame \(index + 1) provenance did not round-trip")
            }
        }
    }

    // MARK: - Geometry helpers

    static func decimal(_ value: Double) -> String {
        var text = String(format: "%.10g", value)
        if text.count > 16 { text = String(format: "%.8g", value) }
        return text
    }

    static func cross(_ a: [Double], _ b: [Double]) -> [Double] {
        [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).map(*).reduce(0, +) }

    static func close(_ a: [Double], _ b: [Double], tolerance: Double = 1e-4) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
    }
}
