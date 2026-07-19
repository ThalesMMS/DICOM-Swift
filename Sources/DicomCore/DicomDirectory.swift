import Foundation

public struct DicomDirectory: Equatable, Sendable {
    public var fileSetID: String?
    public var patients: [DicomDirectoryPatient]

    public init(fileSetID: String? = nil, patients: [DicomDirectoryPatient]) {
        self.fileSetID = fileSetID
        self.patients = patients
    }
}

public struct DicomDirectoryPatient: Equatable, Sendable {
    public var patientID: String?
    public var patientName: String?
    public var studies: [DicomDirectoryStudy]

    public init(patientID: String? = nil, patientName: String? = nil, studies: [DicomDirectoryStudy]) {
        self.patientID = patientID
        self.patientName = patientName
        self.studies = studies
    }
}

public struct DicomDirectoryStudy: Equatable, Sendable {
    public var studyInstanceUID: String?
    public var studyID: String?
    public var studyDate: String?
    public var series: [DicomDirectorySeries]

    public init(studyInstanceUID: String? = nil,
                studyID: String? = nil,
                studyDate: String? = nil,
                series: [DicomDirectorySeries]) {
        self.studyInstanceUID = studyInstanceUID
        self.studyID = studyID
        self.studyDate = studyDate
        self.series = series
    }
}

public struct DicomDirectorySeries: Equatable, Sendable {
    public var seriesInstanceUID: String?
    public var modality: String?
    public var seriesNumber: Int?
    public var images: [DicomDirectoryImage]

    public init(seriesInstanceUID: String? = nil,
                modality: String? = nil,
                seriesNumber: Int? = nil,
                images: [DicomDirectoryImage]) {
        self.seriesInstanceUID = seriesInstanceUID
        self.modality = modality
        self.seriesNumber = seriesNumber
        self.images = images
    }
}

public struct DicomDirectoryImage: Equatable, Sendable {
    public var referencedFileID: [String]
    public var referencedSOPClassUID: String?
    public var referencedSOPInstanceUID: String?
    public var referencedTransferSyntaxUID: String?
    public var instanceNumber: Int?

    public init(referencedFileID: [String],
                referencedSOPClassUID: String? = nil,
                referencedSOPInstanceUID: String? = nil,
                referencedTransferSyntaxUID: String? = nil,
                instanceNumber: Int? = nil) {
        self.referencedFileID = referencedFileID
        self.referencedSOPClassUID = referencedSOPClassUID
        self.referencedSOPInstanceUID = referencedSOPInstanceUID
        self.referencedTransferSyntaxUID = referencedTransferSyntaxUID
        self.instanceNumber = instanceNumber
    }

    public func resolvedFileURL(relativeTo root: URL) throws -> URL {
        try DicomDirectoryPathResolver.resolve(referencedFileID, relativeTo: root)
    }
}

public enum DicomDirectoryError: Error, Equatable, Sendable {
    case invalidDICOMDIR(String)
    case unsafeReferencedFileID([String])
}

public enum DicomDirectoryPathResolver {
    public static func resolve(_ fileID: [String], relativeTo root: URL) throws -> URL {
        guard !fileID.isEmpty,
              fileID.allSatisfy({ isSafeComponent($0) }) else {
            throw DicomDirectoryError.unsafeReferencedFileID(fileID)
        }

        let rootURL = root.standardizedFileURL
        let candidate = fileID.reduce(rootURL) { url, component in
            url.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL

        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path == rootURL.path || candidate.path.hasPrefix(rootPath) else {
            throw DicomDirectoryError.unsafeReferencedFileID(fileID)
        }
        return candidate
    }

    private static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty &&
            component != "." &&
            component != ".." &&
            !component.contains("/") &&
            !component.contains("\\")
    }
}

public enum DicomDirectoryReader {
    public static func read(from url: URL) throws -> DicomDirectory {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    public static func read(data: Data) throws -> DicomDirectory {
        let parsed = try DicomDirectoryDataSetParser.parsePart10DataWithDirectoryRecordOffsets(data)
        return try directory(from: parsed.dataSet, recordItemOffsets: parsed.directoryRecordItemOffsets)
    }

    private static func directory(from dataSet: DicomDataSet, recordItemOffsets: [Int]) throws -> DicomDirectory {
        let recordItems = dataSet.sequenceItems(for: DicomDirectoryTags.directoryRecordSequence)
        let records = recordItems.enumerated().map { index, item in
            DicomDirectoryRecord(
                dataSet: item.dataSet,
                itemOffset: recordItemOffsets.indices.contains(index) ? recordItemOffsets[index] : nil
            )
        }
        guard !records.isEmpty else {
            throw DicomDirectoryError.invalidDICOMDIR("Directory Record Sequence is missing or empty")
        }

        if let patients = offsetLinkedHierarchy(from: dataSet, records: records), !patients.isEmpty {
            return DicomDirectory(fileSetID: dataSet.string(for: DicomDirectoryTags.fileSetID),
                                  patients: patients)
        }

        let patients = flatHierarchy(from: records)
        return DicomDirectory(fileSetID: dataSet.string(for: DicomDirectoryTags.fileSetID),
                              patients: patients)
    }

    private static func offsetLinkedHierarchy(from dataSet: DicomDataSet,
                                              records: [DicomDirectoryRecord]) -> [DicomDirectoryPatient]? {
        guard let firstRootOffset = dataSet.int(for: DicomDirectoryTags.offsetOfFirstRootRecord),
              firstRootOffset > 0 else {
            return nil
        }

        let recordsByOffset = Dictionary(uniqueKeysWithValues: records.compactMap { record -> (Int, DicomDirectoryRecord)? in
            guard let itemOffset = record.itemOffset else { return nil }
            return (itemOffset, record)
        })
        guard !recordsByOffset.isEmpty else { return nil }

        func siblingRecords(startingAt offset: Int) -> [DicomDirectoryRecord] {
            var siblings: [DicomDirectoryRecord] = []
            var visitedOffsets: Set<Int> = []
            var currentOffset = offset

            while currentOffset > 0,
                  !visitedOffsets.contains(currentOffset),
                  let record = recordsByOffset[currentOffset] {
                visitedOffsets.insert(currentOffset)
                siblings.append(record)
                currentOffset = record.nextRecordOffset
            }
            return siblings
        }

        return siblingRecords(startingAt: firstRootOffset).compactMap { patientRecord in
            guard patientRecord.recordType == "PATIENT" else { return nil }
            let studies = siblingRecords(startingAt: patientRecord.lowerRecordOffset).compactMap { studyRecord -> DicomDirectoryStudy? in
                guard studyRecord.recordType == "STUDY" else { return nil }
                let series = siblingRecords(startingAt: studyRecord.lowerRecordOffset).compactMap { seriesRecord -> DicomDirectorySeries? in
                    guard seriesRecord.recordType == "SERIES" else { return nil }
                    let images = siblingRecords(startingAt: seriesRecord.lowerRecordOffset).compactMap { imageRecord -> DicomDirectoryImage? in
                        guard imageRecord.recordType == "IMAGE" else { return nil }
                        return image(from: imageRecord)
                    }
                    return DicomDirectorySeries(
                        seriesInstanceUID: seriesRecord.dataSet.string(for: DicomTag.seriesInstanceUID),
                        modality: seriesRecord.dataSet.string(for: DicomTag.modality),
                        seriesNumber: seriesRecord.dataSet.integerString(for: DicomTag.seriesNumber),
                        images: images
                    )
                }
                return DicomDirectoryStudy(
                    studyInstanceUID: studyRecord.dataSet.string(for: DicomTag.studyInstanceUID),
                    studyID: studyRecord.dataSet.string(for: DicomTag.studyID),
                    studyDate: studyRecord.dataSet.string(for: DicomTag.studyDate),
                    series: series
                )
            }
            return DicomDirectoryPatient(
                patientID: patientRecord.dataSet.string(for: DicomTag.patientID),
                patientName: patientRecord.dataSet.string(for: DicomTag.patientName),
                studies: studies
            )
        }
    }

    private static func flatHierarchy(from records: [DicomDirectoryRecord]) -> [DicomDirectoryPatient] {
        var patients: [DicomDirectoryPatient] = []
        var currentPatient: DicomDirectoryPatient?
        var currentStudy: DicomDirectoryStudy?
        var currentSeries: DicomDirectorySeries?

        func flushSeries() {
            guard let series = currentSeries else { return }
            currentStudy?.series.append(series)
            currentSeries = nil
        }

        func flushStudy() {
            flushSeries()
            guard let study = currentStudy else { return }
            currentPatient?.studies.append(study)
            currentStudy = nil
        }

        func flushPatient() {
            flushStudy()
            guard let patient = currentPatient else { return }
            patients.append(patient)
            currentPatient = nil
        }

        for record in records {
            switch record.recordType {
            case "PATIENT":
                flushPatient()
                currentPatient = DicomDirectoryPatient(
                    patientID: record.dataSet.string(for: DicomTag.patientID),
                    patientName: record.dataSet.string(for: DicomTag.patientName),
                    studies: []
                )
            case "STUDY":
                if currentPatient == nil {
                    currentPatient = DicomDirectoryPatient(studies: [])
                }
                flushStudy()
                currentStudy = DicomDirectoryStudy(
                    studyInstanceUID: record.dataSet.string(for: DicomTag.studyInstanceUID),
                    studyID: record.dataSet.string(for: DicomTag.studyID),
                    studyDate: record.dataSet.string(for: DicomTag.studyDate),
                    series: []
                )
            case "SERIES":
                if currentPatient == nil {
                    currentPatient = DicomDirectoryPatient(studies: [])
                }
                if currentStudy == nil {
                    currentStudy = DicomDirectoryStudy(series: [])
                }
                flushSeries()
                currentSeries = DicomDirectorySeries(
                    seriesInstanceUID: record.dataSet.string(for: DicomTag.seriesInstanceUID),
                    modality: record.dataSet.string(for: DicomTag.modality),
                    seriesNumber: record.dataSet.integerString(for: DicomTag.seriesNumber),
                    images: []
                )
            case "IMAGE":
                if currentPatient == nil {
                    currentPatient = DicomDirectoryPatient(studies: [])
                }
                if currentStudy == nil {
                    currentStudy = DicomDirectoryStudy(series: [])
                }
                if currentSeries == nil {
                    currentSeries = DicomDirectorySeries(images: [])
                }
                currentSeries?.images.append(image(from: record))
            default:
                continue
            }
        }
        flushPatient()

        return patients
    }

    private static func image(from record: DicomDirectoryRecord) -> DicomDirectoryImage {
        DicomDirectoryImage(
            referencedFileID: record.referencedFileID,
            referencedSOPClassUID: record.dataSet.string(for: DicomDirectoryTags.referencedSOPClassUIDInFile),
            referencedSOPInstanceUID: record.dataSet.string(for: DicomDirectoryTags.referencedSOPInstanceUIDInFile),
            referencedTransferSyntaxUID: record.dataSet.string(for: DicomDirectoryTags.referencedTransferSyntaxUIDInFile),
            instanceNumber: record.dataSet.integerString(for: DicomTag.instanceNumber)
        )
    }
}

public enum DicomDirectoryWriter {
    public static let mediaStorageDirectoryStorageSOPClassUID = "1.2.840.10008.1.3.10"

    public static func part10Data(from directory: DicomDirectory) throws -> Data {
        let records = makeRecords(from: directory)
        let dataSet = DicomDataSet(elements: [
            DicomDataElement(tag: DicomDirectoryTags.fileSetID, vr: .CS, value: directory.fileSetID.map { .strings([$0]) } ?? .empty),
            DicomDataElement(tag: DicomDirectoryTags.offsetOfFirstRootRecord, vr: .UL, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomDirectoryTags.offsetOfLastRootRecord, vr: .UL, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomDirectoryTags.fileSetConsistencyFlag, vr: .US, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomDirectoryTags.directoryRecordSequence,
                             vr: .SQ,
                             value: .sequence(records.map { DicomSequenceItem(dataSet: $0.dataSet) }))
        ])

        var data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: mediaStorageDirectoryStorageSOPClassUID,
                mediaStorageSOPInstanceUID: mediaStorageSOPInstanceUID(for: directory)
            )
        )
        try patchRecordOffsets(records: records, in: &data)
        return data
    }

    public static func write(_ directory: DicomDirectory, to url: URL) throws {
        try part10Data(from: directory).write(to: url, options: [.atomic])
    }

    private static func makeRecords(from directory: DicomDirectory) -> [WritableDicomDirectoryRecord] {
        var records: [WritableDicomDirectoryRecord] = []
        var previousPatientIndex: Int?

        for patient in directory.patients {
            let patientIndex = records.count
            if let previousPatientIndex {
                records[previousPatientIndex].nextRecordIndex = patientIndex
            }
            previousPatientIndex = patientIndex
            records.append(.patient(patient))

            var previousStudyIndex: Int?
            for study in patient.studies {
                let studyIndex = records.count
                records[patientIndex].lowerRecordIndex = records[patientIndex].lowerRecordIndex ?? studyIndex
                if let previousStudyIndex {
                    records[previousStudyIndex].nextRecordIndex = studyIndex
                }
                previousStudyIndex = studyIndex
                records.append(.study(study))

                var previousSeriesIndex: Int?
                for series in study.series {
                    let seriesIndex = records.count
                    records[studyIndex].lowerRecordIndex = records[studyIndex].lowerRecordIndex ?? seriesIndex
                    if let previousSeriesIndex {
                        records[previousSeriesIndex].nextRecordIndex = seriesIndex
                    }
                    previousSeriesIndex = seriesIndex
                    records.append(.series(series))

                    var previousImageIndex: Int?
                    for image in series.images {
                        let imageIndex = records.count
                        records[seriesIndex].lowerRecordIndex = records[seriesIndex].lowerRecordIndex ?? imageIndex
                        if let previousImageIndex {
                            records[previousImageIndex].nextRecordIndex = imageIndex
                        }
                        previousImageIndex = imageIndex
                        records.append(.image(image))
                    }
                }
            }
        }
        return records
    }

    private static func mediaStorageSOPInstanceUID(for directory: DicomDirectory) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037

        func append(_ value: String?) {
            for byte in (value ?? "").utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xFF
            hash &*= 1_099_511_628_211
        }

        append(directory.fileSetID)
        for patient in directory.patients {
            append(patient.patientID)
            append(patient.patientName)
            for study in patient.studies {
                append(study.studyInstanceUID)
                append(study.studyID)
                append(study.studyDate)
                for series in study.series {
                    append(series.seriesInstanceUID)
                    append(series.modality)
                    append(series.seriesNumber.map(String.init))
                    for image in series.images {
                        image.referencedFileID.forEach { append($0) }
                        append(image.referencedSOPClassUID)
                        append(image.referencedSOPInstanceUID)
                        append(image.referencedTransferSyntaxUID)
                        append(image.instanceNumber.map(String.init))
                    }
                }
            }
        }

        return "2.25.\(hash)"
    }

    private static func patchRecordOffsets(records: [WritableDicomDirectoryRecord], in data: inout Data) throws {
        let itemOffsets = findDirectoryRecordItemOffsets(in: data)
        guard itemOffsets.count == records.count else {
            throw DicomDirectoryError.invalidDICOMDIR("Unable to locate encoded directory record items")
        }

        for (index, record) in records.enumerated() {
            let itemStart = itemOffsets[index].itemStart
            let itemEnd = itemOffsets[index].itemEnd
            let nextOffset = record.nextRecordIndex.map { UInt32(itemOffsets[$0].itemStart) } ?? 0
            let lowerOffset = record.lowerRecordIndex.map { UInt32(itemOffsets[$0].itemStart) } ?? 0
            try patchUL(tag: DicomDirectoryTags.offsetOfNextDirectoryRecord,
                        value: nextOffset,
                        in: &data,
                        range: itemStart..<itemEnd)
            try patchUL(tag: DicomDirectoryTags.offsetOfLowerLevelDirectoryEntity,
                        value: lowerOffset,
                        in: &data,
                        range: itemStart..<itemEnd)
        }

        let rootRecordIndices = records.indices.filter {
            records[$0].dataSet.string(for: DicomDirectoryTags.directoryRecordType) == "PATIENT"
        }
        let firstRootOffset = rootRecordIndices.first.map { UInt32(itemOffsets[$0].itemStart) } ?? 0
        let lastRootOffset = rootRecordIndices.last.map { UInt32(itemOffsets[$0].itemStart) } ?? 0
        try patchUL(tag: DicomDirectoryTags.offsetOfFirstRootRecord,
                    value: firstRootOffset,
                    in: &data,
                    range: 0..<data.count)
        try patchUL(tag: DicomDirectoryTags.offsetOfLastRootRecord,
                    value: lastRootOffset,
                    in: &data,
                    range: 0..<data.count)
    }

    private static func findDirectoryRecordItemOffsets(in data: Data) -> [(itemStart: Int, itemEnd: Int)] {
        var offsets: [(Int, Int)] = []
        var searchOffset = 0
        let itemTag = Data([0xFE, 0xFF, 0x00, 0xE0])
        while let range = data[searchOffset..<data.count].range(of: itemTag) {
            let itemStart = range.lowerBound
            guard itemStart + 8 <= data.count else { break }
            guard let encodedLength = data.dicomIntegerIfPresent(
                at: itemStart + 4,
                as: UInt32.self,
                littleEndian: true
            ) else { break }
            let length = Int(encodedLength)
            let itemEnd = itemStart + 8 + length
            guard itemEnd <= data.count else { break }
            offsets.append((itemStart, itemEnd))
            searchOffset = itemEnd
        }
        return offsets
    }

    private static func patchUL(tag: Int, value: UInt32, in data: inout Data, range: Range<Int>) throws {
        let group = UInt16((tag >> 16) & 0xFFFF)
        let element = UInt16(tag & 0xFFFF)
        let header = Data([
            UInt8(group & 0x00FF), UInt8(group >> 8),
            UInt8(element & 0x00FF), UInt8(element >> 8),
            0x55, 0x4C, 0x04, 0x00
        ])
        guard let headerRange = data[range].range(of: header) else {
            throw DicomDirectoryError.invalidDICOMDIR("Unable to patch directory record offset")
        }
        writeUInt32LittleEndian(value, to: &data, at: headerRange.upperBound)
    }

    private static func writeUInt32LittleEndian(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(value & 0x000000FF)
        data[offset + 1] = UInt8((value >> 8) & 0x000000FF)
        data[offset + 2] = UInt8((value >> 16) & 0x000000FF)
        data[offset + 3] = UInt8(value >> 24)
    }
}

private struct DicomDirectoryRecord {
    let dataSet: DicomDataSet
    let itemOffset: Int?

    var recordType: String {
        dataSet.string(for: DicomDirectoryTags.directoryRecordType) ?? ""
    }

    var referencedFileID: [String] {
        dataSet.strings(for: DicomDirectoryTags.referencedFileID)
    }

    var nextRecordOffset: Int {
        dataSet.int(for: DicomDirectoryTags.offsetOfNextDirectoryRecord) ?? 0
    }

    var lowerRecordOffset: Int {
        dataSet.int(for: DicomDirectoryTags.offsetOfLowerLevelDirectoryEntity) ?? 0
    }
}

private struct WritableDicomDirectoryRecord {
    var dataSet: DicomDataSet
    var nextRecordIndex: Int?
    var lowerRecordIndex: Int?

    static func patient(_ patient: DicomDirectoryPatient) -> WritableDicomDirectoryRecord {
        WritableDicomDirectoryRecord(dataSet: DicomDataSet(elements: baseElements(type: "PATIENT") + [
            optionalString(DicomTag.patientID.rawValue, .LO, patient.patientID),
            optionalString(DicomTag.patientName.rawValue, .PN, patient.patientName)
        ].compactMap { $0 }))
    }

    static func study(_ study: DicomDirectoryStudy) -> WritableDicomDirectoryRecord {
        WritableDicomDirectoryRecord(dataSet: DicomDataSet(elements: baseElements(type: "STUDY") + [
            optionalString(DicomTag.studyInstanceUID.rawValue, .UI, study.studyInstanceUID),
            optionalString(DicomTag.studyID.rawValue, .SH, study.studyID),
            optionalString(DicomTag.studyDate.rawValue, .DA, study.studyDate)
        ].compactMap { $0 }))
    }

    static func series(_ series: DicomDirectorySeries) -> WritableDicomDirectoryRecord {
        WritableDicomDirectoryRecord(dataSet: DicomDataSet(elements: baseElements(type: "SERIES") + [
            optionalString(DicomTag.seriesInstanceUID.rawValue, .UI, series.seriesInstanceUID),
            optionalString(DicomTag.modality.rawValue, .CS, series.modality),
            series.seriesNumber.map { DicomDataElement(tag: DicomTag.seriesNumber.rawValue, vr: .IS, value: .signedIntegers([$0])) }
        ].compactMap { $0 }))
    }

    static func image(_ image: DicomDirectoryImage) -> WritableDicomDirectoryRecord {
        WritableDicomDirectoryRecord(dataSet: DicomDataSet(elements: baseElements(type: "IMAGE") + [
            DicomDataElement(tag: DicomDirectoryTags.referencedFileID, vr: .CS, value: .strings(image.referencedFileID)),
            optionalString(DicomDirectoryTags.referencedSOPClassUIDInFile, .UI, image.referencedSOPClassUID),
            optionalString(DicomDirectoryTags.referencedSOPInstanceUIDInFile, .UI, image.referencedSOPInstanceUID),
            optionalString(DicomDirectoryTags.referencedTransferSyntaxUIDInFile, .UI, image.referencedTransferSyntaxUID),
            image.instanceNumber.map { DicomDataElement(tag: DicomTag.instanceNumber.rawValue, vr: .IS, value: .signedIntegers([$0])) }
        ].compactMap { $0 }))
    }

    private static func baseElements(type: String) -> [DicomDataElement] {
        [
            DicomDataElement(tag: DicomDirectoryTags.offsetOfNextDirectoryRecord, vr: .UL, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomDirectoryTags.recordInUseFlag, vr: .US, value: .unsignedIntegers([0xFFFF])),
            DicomDataElement(tag: DicomDirectoryTags.offsetOfLowerLevelDirectoryEntity, vr: .UL, value: .unsignedIntegers([0])),
            DicomDataElement(tag: DicomDirectoryTags.directoryRecordType, vr: .CS, value: .strings([type]))
        ]
    }

    private static func optionalString(_ tag: Int, _ vr: DicomVR, _ value: String?) -> DicomDataElement? {
        guard let value, !value.isEmpty else { return nil }
        return DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }
}

private enum DicomDirectoryTags {
    static let fileSetID = 0x00041130
    static let offsetOfFirstRootRecord = 0x00041200
    static let offsetOfLastRootRecord = 0x00041202
    static let fileSetConsistencyFlag = 0x00041212
    static let directoryRecordSequence = 0x00041220
    static let offsetOfNextDirectoryRecord = 0x00041400
    static let recordInUseFlag = 0x00041410
    static let offsetOfLowerLevelDirectoryEntity = 0x00041420
    static let directoryRecordType = 0x00041430
    static let referencedFileID = 0x00041500
    static let referencedSOPClassUIDInFile = 0x00041510
    static let referencedSOPInstanceUIDInFile = 0x00041511
    static let referencedTransferSyntaxUIDInFile = 0x00041512
}

private struct ParsedDicomDirectoryDataSet {
    let dataSet: DicomDataSet
    let directoryRecordItemOffsets: [Int]
}

private enum DicomDirectoryDataSetParser {
    static func parsePart10Data(_ data: Data) throws -> DicomDataSet {
        try parsePart10DataWithDirectoryRecordOffsets(data).dataSet
    }

    static func parsePart10DataWithDirectoryRecordOffsets(_ data: Data) throws -> ParsedDicomDirectoryDataSet {
        guard data.count >= 132,
              String(data: data[128..<132], encoding: .ascii) == "DICM" else {
            throw DicomDirectoryError.invalidDICOMDIR("Missing DICM marker")
        }

        var offset = 132
        var directoryRecordItemOffsets: [Int] = []
        let dataSet = try parseDataSet(
            data,
            offset: &offset,
            end: data.count,
            littleEndian: true,
            inheritedCharacterSet: .defaultCharacterSet,
            directoryRecordItemOffsets: &directoryRecordItemOffsets
        )
        return ParsedDicomDirectoryDataSet(dataSet: dataSet,
                                           directoryRecordItemOffsets: directoryRecordItemOffsets)
    }

    private static func parseDataSet(_ data: Data,
                                     offset: inout Int,
                                     end: Int,
                                     littleEndian: Bool,
                                     inheritedCharacterSet: DicomSpecificCharacterSet,
                                     directoryRecordItemOffsets: inout [Int]) throws -> DicomDataSet {
        var elements: [DicomDataElement] = []
        var characterSet = inheritedCharacterSet
        while offset + 8 <= end {
            let tag = try readTag(data, offset: &offset, littleEndian: littleEndian)
            if tag == 0xFFFEE00D || tag == 0xFFFEE0DD {
                break
            }
            let vrCode = try readASCII(data, offset: &offset, length: 2)
            guard let vr = DicomVR(code: vrCode) else {
                throw DicomDirectoryError.invalidDICOMDIR("Unsupported explicit VR \(vrCode)")
            }

            let length: Int
            if vr.uses32BitLength {
                offset += 2
                length = Int(try readUInt32(data, offset: &offset, littleEndian: littleEndian))
            } else {
                length = Int(try readUInt16(data, offset: &offset, littleEndian: littleEndian))
            }
            guard offset + length <= end else {
                throw DicomDirectoryError.invalidDICOMDIR("Element length exceeds DICOMDIR size")
            }

            if vr == .SQ {
                let sequenceEnd = offset + length
                let items = try parseSequenceItems(
                    data,
                    offset: &offset,
                    end: sequenceEnd,
                    littleEndian: littleEndian,
                    characterSet: characterSet,
                    captureItemOffsets: tag == DicomDirectoryTags.directoryRecordSequence,
                    directoryRecordItemOffsets: &directoryRecordItemOffsets
                )
                elements.append(DicomDataElement(tag: tag, vr: vr, value: .sequence(items)))
            } else {
                let value = data[offset..<(offset + length)]
                offset += length
                let decodedValue = valueData(
                    vr: vr,
                    data: Data(value),
                    littleEndian: littleEndian,
                    characterSet: characterSet
                )
                elements.append(DicomDataElement(tag: tag, vr: vr, value: decodedValue))
                if tag == DicomTag.specificCharacterSet.rawValue,
                   case .strings(let terms) = decodedValue {
                    characterSet = DicomSpecificCharacterSet(terms.joined(separator: "\\"))
                }
            }
        }
        return DicomDataSet(elements: elements)
    }

    private static func parseSequenceItems(_ data: Data,
                                           offset: inout Int,
                                           end: Int,
                                           littleEndian: Bool,
                                           characterSet: DicomSpecificCharacterSet,
                                           captureItemOffsets: Bool,
                                           directoryRecordItemOffsets: inout [Int]) throws -> [DicomSequenceItem] {
        var items: [DicomSequenceItem] = []
        while offset + 8 <= end {
            let itemStart = offset
            let itemTag = try readTag(data, offset: &offset, littleEndian: littleEndian)
            let length = Int(try readUInt32(data, offset: &offset, littleEndian: littleEndian))
            guard itemTag == 0xFFFEE000,
                  offset + length <= end else {
                throw DicomDirectoryError.invalidDICOMDIR("Invalid sequence item")
            }
            if captureItemOffsets {
                directoryRecordItemOffsets.append(itemStart)
            }
            let itemEnd = offset + length
            let dataSet = try parseDataSet(
                data,
                offset: &offset,
                end: itemEnd,
                littleEndian: littleEndian,
                inheritedCharacterSet: characterSet,
                directoryRecordItemOffsets: &directoryRecordItemOffsets
            )
            items.append(DicomSequenceItem(dataSet: dataSet))
            offset = itemEnd
        }
        return items
    }

    private static func valueData(
        vr: DicomVR,
        data: Data,
        littleEndian: Bool,
        characterSet: DicomSpecificCharacterSet
    ) -> DicomDataValue {
        switch vr {
        case .US:
            return .unsignedIntegers(stride(from: 0, to: data.count - data.count % 2, by: 2).map {
                UInt(readUInt16Value(data, at: $0, littleEndian: littleEndian))
            })
        case .UL:
            return .unsignedIntegers(stride(from: 0, to: data.count - data.count % 4, by: 4).map {
                UInt(readUInt32Value(data, at: $0, littleEndian: littleEndian))
            })
        case .SS:
            return .signedIntegers(stride(from: 0, to: data.count - data.count % 2, by: 2).map {
                Int(Int16(bitPattern: readUInt16Value(data, at: $0, littleEndian: littleEndian)))
            })
        case .SL:
            return .signedIntegers(stride(from: 0, to: data.count - data.count % 4, by: 4).map {
                Int(Int32(bitPattern: readUInt32Value(data, at: $0, littleEndian: littleEndian)))
            })
        case .OB, .OW, .OV, .UN:
            return .bytes(data)
        default:
            let text = characterSet.decode(data)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            let values = text.split(separator: "\\", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
            }
            return values.isEmpty || (values.count == 1 && values[0].isEmpty) ? .empty : .strings(values)
        }
    }

    private static func readTag(_ data: Data, offset: inout Int, littleEndian: Bool) throws -> Int {
        let group = try readUInt16(data, offset: &offset, littleEndian: littleEndian)
        let element = try readUInt16(data, offset: &offset, littleEndian: littleEndian)
        return Int(group) << 16 | Int(element)
    }

    private static func readASCII(_ data: Data, offset: inout Int, length: Int) throws -> String {
        guard offset + length <= data.count else {
            throw DicomDirectoryError.invalidDICOMDIR("Unexpected end of DICOMDIR")
        }
        let value = String(data: data[offset..<(offset + length)], encoding: .ascii) ?? ""
        offset += length
        return value
    }

    private static func readUInt16(_ data: Data, offset: inout Int, littleEndian: Bool) throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw DicomDirectoryError.invalidDICOMDIR("Unexpected end of DICOMDIR")
        }
        let value = readUInt16Value(data, at: offset, littleEndian: littleEndian)
        offset += 2
        return value
    }

    private static func readUInt32(_ data: Data, offset: inout Int, littleEndian: Bool) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw DicomDirectoryError.invalidDICOMDIR("Unexpected end of DICOMDIR")
        }
        let value = readUInt32Value(data, at: offset, littleEndian: littleEndian)
        offset += 4
        return value
    }

    private static func readUInt16Value(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt16 {
        data.dicomIntegerIfPresent(at: offset, as: UInt16.self, littleEndian: littleEndian) ?? 0
    }

    private static func readUInt32Value(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
        data.dicomIntegerIfPresent(at: offset, as: UInt32.self, littleEndian: littleEndian) ?? 0
    }
}
