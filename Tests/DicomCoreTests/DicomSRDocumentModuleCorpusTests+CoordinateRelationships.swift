import Foundation
import XCTest
@testable import DicomCore

extension DicomSRDocumentModuleCorpusTests {
    func test_coordinateRelationshipCorpus_requiresResolvedCompatibleSelections() throws {
        let base = try fixture(suffix: "33")
        let image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
        let pair = try XCTUnwrap(image.sequenceItems(for: .referencedSOPSequence).first?.dataSet)
        let concept = try XCTUnwrap(image.sequenceItems(for: .conceptNameCodeSequence).first?.dataSet)
        let selectedImage = image.setting(text(0x0040A010, "SELECTED FROM", .CS))
        let spatial = image.removing(0x00081199).setting(text(0x0040A040, "SCOORD", .CS))
            .setting(text(0x00700023, "POINT", .CS)).setting(.init(tag: 0x00700022, vr: .FL, value: .floats([1, 1])))
        let temporal = image.removing(0x00081199).setting(text(0x0040A040, "TCOORD", .CS))
            .setting(text(0x0040A130, "POINT", .CS)).setting(text(0x0040A138, "0", .DS))
        let selectedText = image.removing(0x00081199).setting(text(0x0040A040, "TEXT", .CS))
            .setting(text(0x0040A010, "SELECTED FROM", .CS)).setting(text(0x0040A160, "SYNTHETIC", .UT))
        let modifier = image.removing(0x00081199).setting(text(0x0040A040, "CODE", .CS))
            .setting(text(0x0040A010, "HAS CONCEPT MOD", .CS)).setting(sequence(0x0040A168, [concept]))
        let wavePair = pair.setting(text(0x00081150, "1.2.840.10008.5.1.4.1.1.9.1.1", .UI))
            .setting(text(0x00081155, "2.25.23220007", .UI))
        let waveform = image.setting(text(0x0040A040, "WAVEFORM", .CS)).setting(text(0x0040A010, "SELECTED FROM", .CS))
            .setting(sequence(0x00081199, [wavePair]))
        func reference(_ identifier: [UInt]) -> DicomDataSet {
            .init(elements: [text(0x0040A010, "SELECTED FROM", .CS), .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers(identifier))])
        }
        let cases: [(String, DicomDataSet, DicomValidationReport.Outcome)] = [
            ("spatial-missing", spatial, .failed), ("spatial-empty", spatial.setting(sequence(0x0040A730, [])), .failed),
            ("spatial-unrelated", spatial.setting(sequence(0x0040A730, [modifier])), .failed),
            ("spatial-wrong-relationship", spatial.setting(sequence(0x0040A730, [image.setting(text(0x0040A010, "HAS PROPERTIES", .CS))])), .failed),
            ("spatial-wrong-target", spatial.setting(sequence(0x0040A730, [selectedText])), .failed),
            ("spatial-by-value", spatial.setting(sequence(0x0040A730, [selectedImage])), .passed),
            ("spatial-backward", spatial.setting(sequence(0x0040A730, [reference([1, 1])])), .passed),
            ("spatial-forward", spatial.setting(sequence(0x0040A730, [reference([1, 2])])), .passed),
            ("spatial-multiple", spatial.setting(sequence(0x0040A730, [selectedImage, selectedImage])), .passed),
            ("spatial-target-missing", spatial.setting(sequence(0x0040A730, [reference([1, 99])])), .failed),
            ("spatial-identifier-invalid", spatial.setting(sequence(0x0040A730, [reference([0])])), .failed),
            ("temporal-missing", temporal, .failed), ("temporal-empty", temporal.setting(sequence(0x0040A730, [])), .failed),
            ("temporal-image", temporal.setting(sequence(0x0040A730, [selectedImage])), .passed),
            ("temporal-waveform", temporal.setting(sequence(0x0040A730, [waveform])), .passed),
            ("temporal-spatial", temporal.setting(sequence(0x0040A730, [spatial.setting(text(0x0040A010, "SELECTED FROM", .CS))
                .setting(sequence(0x0040A730, [selectedImage]))])), .passed),
            ("temporal-backward", temporal.setting(sequence(0x0040A730, [reference([1, 1])])), .passed),
            ("temporal-wrong-target", temporal.setting(sequence(0x0040A730, [selectedText])), .failed)
        ]
        for (name, coordinate, expected) in cases {
            let children = name == "spatial-forward" ? [coordinate, image] : [image, coordinate]
            var source = base.setting(sequence(0x0040A730, children))
            if name == "temporal-waveform" {
                let series = DicomDataSet(elements: [text(0x0020000E, "2.25.23212002", .UI), sequence(0x00081199, [pair, wavePair])])
                let study = DicomDataSet(elements: [text(0x0020000D, "2.25.23212001", .UI), sequence(0x00081115, [series])])
                source = source.setting(sequence(0x0040A375, [study]))
            }
            let read = try DicomEncodedDataSetValidator.validate(DicomDataSetWriter.dataSetData(from: source, purpose: .instance))
            XCTAssertEqual(read.report.outcome(requiring: [.structure, .vrAndVM]), .passed, name)
            let graph = DicomSRRelationshipValidator.validate(try XCTUnwrap(read.dataSet))
            XCTAssertEqual(graph[.references], expected, name)
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_COORDINATE_RELATIONSHIP_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                try DicomDataSetWriter.part10Data(from: source, options: .init(validationPurpose: .instance))
                    .write(to: path.appendingPathExtension("dcm"))
                try JSONSerialization.data(withJSONObject: ["relationships": graph[.references].rawValue,
                    "diagnostics": graph.diagnostics.map { $0.code.rawValue }, "structureAndVRVM": "passed"])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }
}
