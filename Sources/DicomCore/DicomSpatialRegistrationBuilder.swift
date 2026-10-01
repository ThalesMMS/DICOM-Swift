import Foundation

/// Patient/study metadata and the actual study/series hierarchy of referenced instances.
public struct DicomRegistrationBuildOptions: Sendable {
    public var patientName = ""
    public var patientID = ""
    public var patientBirthDate = ""
    public var patientSex = ""
    public var studyDate = ""
    public var studyTime = ""
    public var referringPhysicianName = ""
    public var studyID = ""
    public var accessionNumber = ""
    public var seriesNumber = 1
    public var manufacturer = "DICOM-Swift"
    public var manufacturerModelName = "Registration Builder"
    public var deviceSerialNumber = "SOFTWARE"
    public var softwareVersions = "1"
    public var referencedStudies: [String: [String: [DicomSOPReference]]] = [:]
    public init() {}
}

public enum DicomSpatialRegistrationBuilder {
    public enum BuildError: Error, Equatable, Sendable {
        case invalidDocument, incompleteReferenceHierarchy
    }

    public static func dataSet(from document: DicomSpatialRegistrationDocument,
                               studyInstanceUID: String, seriesInstanceUID: String,
                               options: DicomRegistrationBuildOptions = .init()) throws -> DicomDataSet {
        let c = DicomRegistrationCoding.self
        var data = try c.common(sopClass: DicomSpatialRegistrationDocument.storageSOPClassUID,
            sop: document.sopInstanceUID, frame: document.registeredFrameOfReferenceUID,
            date: document.contentDate, time: document.contentTime, number: document.instanceNumber,
            label: document.contentLabel, description: document.contentDescription, creator: document.contentCreatorName,
            study: studyInstanceUID, series: seriesInstanceUID, options: options)
        var references: [DicomSOPReference] = []
        let items = document.registrations.map { item -> DicomDataSet in
            var matrixRegistration = DicomDataSet(elements: [
                c.sequence(0x0070030A, item.matrices.map(c.matrix)),
                c.sequence(0x0070030D, item.registrationTypeCode.map { [c.code($0)] } ?? [])])
            if let comment = item.transformationComment { matrixRegistration = matrixRegistration.setting(c.text(0x300600C8, .LO, comment)) }
            var data = DicomDataSet(elements: [c.sequence(0x00700309, [matrixRegistration])])
            if let frame = item.sourceFrameOfReferenceUID { data = data.setting(c.text(0x00200052, .UI, frame)) }
            if !item.referencedImages.isEmpty { data = data.setting(c.sequence(0x00081140, item.referencedImages.map(c.imageData))) }
            references += item.referencedImages.map { .init(sopClassUID: $0.referencedSOPClassUID ?? "", sopInstanceUID: $0.referencedSOPInstanceUID ?? "") }
            references += item.usedFiducials.map(\.reference) + item.usedSegments.map(\.reference) + item.usedROIs.map(\.reference)
            if !item.usedFiducials.isEmpty { data = data.setting(c.sequence(0x00700314, item.usedFiducials.map(c.fiducialData))) }
            if !item.usedSegments.isEmpty {
                data = data.setting(c.sequence(0x00620012, item.usedSegments.map {
                    c.reference($0.reference).setting(.init(tag: 0x0062000B, vr: .US, value: .unsignedIntegers([UInt(max(0, $0.segmentNumber))])))
                }))
            }
            if !item.usedROIs.isEmpty {
                data = data.setting(c.sequence(0x00700315, item.usedROIs.map {
                    c.reference($0.reference).setting(c.text(0x30060084, .IS, String($0.roiNumber)))
                }))
            }
            return data
        }
        guard !items.isEmpty, document.registrations.allSatisfy({
            Set($0.referencedSOPInstanceUIDs) == Set($0.referencedImages.compactMap(\.referencedSOPInstanceUID)) &&
            !$0.matrices.isEmpty && $0.usedSegments.allSatisfy { $0.segmentNumber > 0 && $0.segmentNumber <= 65535 }
        }) else { throw BuildError.invalidDocument }
        data = data.setting(c.sequence(0x00700308, items))
        guard DicomSpatialRegistrationParser.parse(dataSet: data) != nil,
              DicomSpatialRegistrationParser.diagnostics(dataSet: data).isEmpty else { throw BuildError.invalidDocument }
        return try c.hierarchy(data, references: references, study: studyInstanceUID, options: options)
    }
}

/// Shared registration value coding; no RT authoring helpers are used.
enum DicomRegistrationCoding {
    static func text(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }
    static func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
    static func decimals(_ tag: Int, _ values: [Double]) -> DicomDataElement {
        .init(tag: tag, vr: .DS, value: .strings(values.map { String(format: "%.10g", locale: Locale(identifier: "en_US_POSIX"), $0) }))
    }
    static func reference(_ ref: DicomSOPReference) -> DicomDataSet {
        .init(elements: [text(0x00081150, .UI, ref.sopClassUID), text(0x00081155, .UI, ref.sopInstanceUID)])
    }
    static func image(_ data: DicomDataSet) -> DicomSourceImageReference {
        .init(referencedSOPClassUID: data.string(for: 0x00081150), referencedSOPInstanceUID: data.string(for: 0x00081155),
              referencedFrameNumbers: data.ints(for: 0x00081160))
    }
    static func imageData(_ ref: DicomSourceImageReference) -> DicomDataSet {
        var data = reference(.init(sopClassUID: ref.referencedSOPClassUID ?? "", sopInstanceUID: ref.referencedSOPInstanceUID ?? ""))
        if !ref.referencedFrameNumbers.isEmpty {
            data = data.setting(.init(tag: 0x00081160, vr: .IS, value: .strings(ref.referencedFrameNumbers.map(String.init))))
        }
        return data
    }
    static func fiducials(_ data: DicomDataSet) -> [DicomRegistrationUsedFiducial] {
        data.sequenceItems(for: 0x00700314).compactMap {
            guard let ref = DicomSOPReference(data: $0.dataSet), let uid = $0.dataSet.string(for: 0x0070031A) else { return nil }
            return .init(reference: ref, fiducialUID: uid)
        }
    }
    static func fiducialData(_ value: DicomRegistrationUsedFiducial) -> DicomDataSet {
        reference(value.reference).setting(text(0x0070031A, .UI, value.fiducialUID))
    }
    static func code(_ value: DicomCodedConcept) -> DicomDataSet {
        var data = DicomDataSet(elements: [text(0x00080100, .SH, value.codeValue),
            text(0x00080102, .SH, value.codingSchemeDesignator), text(0x00080104, .LO, value.codeMeaning ?? "")])
        if let version = value.codingSchemeVersion { data = data.setting(text(0x00080103, .SH, version)) }
        return data
    }
    static func matrix(_ value: DicomSpatialRegistrationMatrix) -> DicomDataSet {
        .init(elements: [decimals(0x300600C6, value.rowMajorValues), text(0x0070030C, .CS, value.type)])
    }
    static func readMatrix(_ data: DicomDataSet) -> DicomSpatialRegistrationMatrix {
        .init(type: data.string(for: 0x0070030C) ?? "", rowMajorValues: data.decimalStrings(for: 0x300600C6))
    }
    static func matrixDiagnostics(_ data: DicomDataSet, item: Int, matrix: Int? = nil) -> [DicomSpatialRegistrationDiagnostic] {
        let value = readMatrix(data)
        var codes: [DicomSpatialRegistrationDiagnostic.Code] = []
        if value.rowMajorValues.count != 16 { codes.append(.matrixValueCount) }
        if !value.rowMajorValues.allSatisfy(\.isFinite) { codes.append(.nonFiniteMatrix) }
        if value.rowMajorValues.count == 16 && Array(value.rowMajorValues[12...15]) != [0, 0, 0, 1] { codes.append(.invalidLastRow) }
        if case .other = value.matrixType { codes.append(.unknownMatrixType) }
        return codes.map { .init(code: $0, itemIndex: item, matrixIndex: matrix) }
    }
    static func common(sopClass: String, sop: String?, frame: String, date: String?, time: String?, number: Int,
                       label: String, description: String?, creator: String?, study: String, series: String,
                       options: DicomRegistrationBuildOptions) throws -> DicomDataSet {
        guard let sop, !sop.isEmpty, !frame.isEmpty, let date, !date.isEmpty, let time, !time.isEmpty,
              !label.isEmpty, !study.isEmpty, !series.isEmpty else { throw DicomSpatialRegistrationBuilder.BuildError.invalidDocument }
        return .init(elements: [text(0x00080016, .UI, sopClass), text(0x00080018, .UI, sop),
            text(0x0020000D, .UI, study), text(0x0020000E, .UI, series), text(0x00080060, .CS, "REG"),
            text(0x00100010, .PN, options.patientName), text(0x00100020, .LO, options.patientID),
            text(0x00100030, .DA, options.patientBirthDate), text(0x00100040, .CS, options.patientSex),
            text(0x00080020, .DA, options.studyDate), text(0x00080030, .TM, options.studyTime),
            text(0x00080090, .PN, options.referringPhysicianName), text(0x00200010, .SH, options.studyID),
            text(0x00080050, .SH, options.accessionNumber), text(0x00200011, .IS, String(options.seriesNumber)),
            text(0x00200052, .UI, frame), text(0x00201040, .LO, ""), text(0x00080070, .LO, options.manufacturer),
            text(0x00080023, .DA, date), text(0x00080033, .TM, time), text(0x00200013, .IS, String(number)),
            text(0x00700080, .CS, label), text(0x00700081, .LO, description ?? ""), text(0x00700084, .PN, creator ?? "")])
    }
    static func hierarchy(_ data: DicomDataSet, references: [DicomSOPReference], study: String,
                          options: DicomRegistrationBuildOptions) throws -> DicomDataSet {
        let listed = options.referencedStudies.values.flatMap { $0.values.flatMap { $0 } }
        guard references.allSatisfy({ ref in !ref.sopClassUID.isEmpty && !ref.sopInstanceUID.isEmpty && listed.contains(ref) })
        else { throw DicomSpatialRegistrationBuilder.BuildError.incompleteReferenceHierarchy }
        func seriesData(_ series: [String: [DicomSOPReference]]) -> [DicomDataSet] {
            series.keys.sorted().map { uid in .init(elements: [text(0x0020000E, .UI, uid), sequence(0x0008114A, series[uid]!.map(reference))]) }
        }
        var result = data
        if let series = options.referencedStudies[study], !series.isEmpty { result = result.setting(sequence(0x00081115, seriesData(series))) }
        let other = options.referencedStudies.keys.filter { $0 != study }.sorted().map { uid in
            DicomDataSet(elements: [text(0x0020000D, .UI, uid), sequence(0x00081115, seriesData(options.referencedStudies[uid]!))])
        }
        if !other.isEmpty { result = result.setting(sequence(0x00081200, other)) }
        return result
    }
}
