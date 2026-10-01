import Foundation
import XCTest
@testable import DicomData

enum DicomImageModuleCorpus {
    static func export(_ module: DicomDataSet, modality: String, name: String,
                       outcome: DicomValidationReport.Outcome) throws {
        let sopClass = "1.2.840.10008.5.1.4.1.1." + (modality == "CT" ? "2" : "4")
        let common = DicomDataSet(elements: [
            text(0x00080016, sopClass, .UI), text(0x00080018, "2.25.23210001", .UI),
            text(0x00100010, "SYNTHETIC^CORPUS", .PN), text(0x00100020, "SYNTHETIC2321", .LO),
            text(0x00100030, "", .DA), text(0x00100040, "", .CS),
            text(0x0020000D, "2.25.23210002", .UI), text(0x0020000E, "2.25.23210003", .UI),
            text(0x00080020, "20260908", .DA), text(0x00080030, "120000", .TM),
            text(0x00080090, "", .PN), text(0x00200010, "1", .SH), text(0x00080050, "", .SH),
            text(0x00080060, modality, .CS), text(0x00200011, "1", .IS), text(0x00200013, "1", .IS),
            text(0x00185100, "HFS", .CS), text(0x00200052, "2.25.23210004", .UI),
            text(0x00201040, "", .LO), text(0x00080070, "SYNTHETIC", .LO),
            .init(tag: 0x00200032, vr: .DS, value: .strings(["0", "0", "0"])),
            .init(tag: 0x00200037, vr: .DS, value: .strings(["1", "0", "0", "0", "1", "0"])),
            .init(tag: 0x00280030, vr: .DS, value: .strings(["1", "1"])),
            text(0x00180050, "1", .DS), text(0x00282110, "00", .CS),
            .init(tag: 0x00280010, vr: .US, value: .unsignedIntegers([2])),
            .init(tag: 0x00280011, vr: .US, value: .unsignedIntegers([2])),
            .init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([0])),
            .init(tag: 0x7FE00010, vr: .OW, value: .bytes(Data(repeating: 0, count: 8)))
        ])
        let dataSet = DicomDataSet(elements: common.elements + module.elements)
        let encoded = try DicomDataSetWriter.dataSetData(from: dataSet, purpose: .instance)
        let validation = try DicomEncodedDataSetValidator.validate(encoded)
        let parsed = try XCTUnwrap(validation.dataSet)
        let attributes = modality == "CT" ? DicomCTImageModule.validate(parsed) : DicomMRImageModule.validate(parsed)
        let composed = validation.report.merging(attributes)
        XCTAssertEqual(composed[.structure], .passed)
        XCTAssertEqual(composed[.vrAndVM], .incomplete) // Omitted pixels are not verified values.
        XCTAssertEqual(composed[.attributes], outcome)
        // Even negative IOD cases must have valid encodings and dictionary VR/VM.
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(validationPurpose: .instance))
        guard let directory = ProcessInfo.processInfo.environment["DICOM_IOD_CORPUS_DIRECTORY"] else { return }
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let filename = modality.lowercased() + "-" + name
        try bytes.write(to: folder.appendingPathComponent(filename + ".dcm"))
        let metadata = ["module": modality == "CT" ? "CT Image" : "MR Image", "expectedAttributes": outcome.rawValue]
        try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            .write(to: folder.appendingPathComponent(filename + ".json"))
    }

    private static func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }
}
