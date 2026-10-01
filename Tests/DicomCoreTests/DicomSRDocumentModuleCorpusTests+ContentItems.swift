import Foundation
import XCTest
@testable import DicomCore

extension DicomSRDocumentModuleCorpusTests {
    func test_contentItemCorpus_preservesConditionalRequirementsAndTextSyntax() throws {
        let base = try fixture(suffix: "33")
        let image = try XCTUnwrap(base.sequenceItems(for: .contentSequence).first?.dataSet)
        let code = try XCTUnwrap(image.sequenceItems(for: .conceptNameCodeSequence).first?.dataSet)
        let textItem = image.removing(0x00081199).setting(text(0x0040A040, "TEXT", .CS)).setting(text(0x0040A160, "SYNTHETIC", .UT))
        let container = textItem.removing(0x0040A160).setting(text(0x0040A040, "CONTAINER", .CS)).setting(text(0x0040A050, "SEPARATE", .CS))
        var known = DicomSRContentItemMacro.Conditions()
        known.containerHasHeading = .satisfied
        known.referencePurposeInConceptName = .satisfied
        known.observationTimeDiffers = .unsatisfied
        known.identifyingTemplateRequired = .unsatisfied
        var cases: [(String, DicomDataSet, DicomSRContentItemMacro.Conditions, DicomValidationReport.Outcome)] = [
            ("text-valid", textItem, known, .passed),
            ("text-crlf", textItem.setting(text(0x0040A160, "LINE ONE\r\nLINE TWO", .UT)), known, .passed),
            ("text-missing", textItem.removing(0x0040A160), known, .failed),
            ("text-empty", textItem.setting(text(0x0040A160, "", .UT)), known, .failed)
        ]
        for (name, value) in [("text-tab", "A\tB"), ("text-formfeed", "A\u{000C}B"), ("text-lf", "A\nB"), ("text-cr", "A\rB")] {
            cases.append((name, textItem.setting(text(0x0040A160, value, .UT)), known, .failed))
        }
        for (type, tag, vr, value) in [("DATE", 0x0040A121, DicomVR.DA, "20260908"), ("TIME", 0x0040A122, .TM, "140000"),
                                      ("DATETIME", 0x0040A120, .DT, "20260908140000"), ("PNAME", 0x0040A123, .PN, "SYNTHETIC^OBSERVER"),
                                      ("UIDREF", 0x0040A124, .UI, "2.25.23219001")] {
            cases.append((type.lowercased() + "-valid", textItem.removing(0x0040A160).setting(text(0x0040A040, type, .CS))
                .setting(text(tag, value, vr)), known, .passed))
        }
        cases += [("text-with-date", textItem.setting(text(0x0040A121, "20260908", .DA)), known, .failed),
                  ("date-with-text", textItem.setting(text(0x0040A040, "DATE", .CS)).setting(text(0x0040A121, "20260908", .DA)), known, .failed)]
        // C.17.3: a heading is evidenced by the concept name itself and reference items may carry a
        // generic concept name, so presence is never forbidden and absence needs no external fact.
        for (prefix, item) in [("heading", container), ("purpose", image)] {
            cases.append((prefix + "-required-missing", item.removing(0x0040A043), known, .failed))
            cases.append((prefix + "-required-present", item, known, .passed))
            var absent = known
            absent.containerHasHeading = .unsatisfied
            absent.referencePurposeInConceptName = .unsatisfied
            cases.append((prefix + "-not-required-absent", item.removing(0x0040A043), absent, .passed))
            cases.append((prefix + "-not-required-present", item, absent, .passed))
            absent.containerHasHeading = .undetermined
            absent.referencePurposeInConceptName = .undetermined
            cases.append((prefix + "-unknown", item.removing(0x0040A043), absent, .passed))
        }
        var observed = known
        observed.observationTimeDiffers = .satisfied
        cases += [("observation-required-missing", textItem, observed, .failed),
                  ("observation-required-present", textItem.setting(text(0x0040A032, "20260908130000", .DT)), observed, .passed),
                  ("observation-required-empty", textItem.setting(text(0x0040A032, "", .DT)), observed, .failed),
                  ("observation-optional-present", textItem.setting(text(0x0040A032, "20260908120000", .DT)), known, .passed)]
        observed.observationTimeDiffers = .undetermined
        cases.append(("observation-unknown", textItem, observed, .incomplete))
        var templateRequired = known
        templateRequired.identifyingTemplateRequired = .satisfied
        let template = DicomDataSet(elements: [text(0x00080105, "DCMR", .CS), text(0x0040DB00, "1500", .CS)])
        let identified = container.setting(sequence(0x0040A504, [template]))
        cases += [("template-required-missing", container, templateRequired, .failed),
                  ("template-valid", identified, templateRequired, .passed),
                  ("template-not-required-present", identified, known, .failed)]
        var templateUnknown = known
        templateUnknown.identifyingTemplateRequired = .undetermined
        cases.append(("template-unknown", container, templateUnknown, .passed))
        for (name, item) in [("template-leading-zero", template.setting(text(0x0040DB00, "01500", .CS))),
                             ("template-prefixed", template.setting(text(0x0040DB00, "TID 1500", .CS))),
                             ("template-missing-resource", template.removing(0x00080105)),
                             ("template-missing-id", template.removing(0x0040DB00))] {
            cases.append((name, container.setting(sequence(0x0040A504, [item])), templateRequired, .failed))
        }
        cases += [("template-empty", container.setting(sequence(0x0040A504, [])), templateRequired, .failed),
                  ("template-multiple", container.setting(sequence(0x0040A504, [template, template])), templateRequired, .failed)]
        let byReference = DicomDataSet(elements: [text(0x0040A010, "INFERRED FROM", .CS),
            .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1, 1]))])
        for (name, element) in [("byref-temporal", text(0x0040A130, "POINT", .CS)),
                               ("byref-spatial", text(0x30060024, "2.25.23219001", .UI)),
                               ("byref-table", sequence(0x0040A801, [.init(elements: [sequence(0x0040A043, [code])])]))] {
            cases.append((name, byReference.setting(element), known, .failed))
        }
        XCTAssertEqual(cases.count, 43)
        for (name, item, facts, expected) in cases {
            let byReference = name.hasPrefix("byref-")
            let source = base.setting(sequence(0x0040A730, byReference ? [image, textItem.setting(sequence(0x0040A730, [item]))] : [item]))
            let wire = try DicomDataSetWriter.dataSetData(from: source, purpose: .instance)
            let read = try DicomEncodedDataSetValidator.validate(wire)
            XCTAssertEqual(read.report.outcome(requiring: [.structure, .vrAndVM]), .passed, name)
            let parsed = try XCTUnwrap(read.dataSet)
            let children = parsed.sequenceItems(for: .contentSequence)
            let child = try XCTUnwrap(byReference ? children[1].dataSet.sequenceItems(for: .contentSequence).first?.dataSet : children.first?.dataSet)
            let macro = DicomSRContentItemMacro.validate(child, conditions: facts, versionRequirements: ["DCM": .unsatisfied])
            XCTAssertEqual(macro[.attributes], expected, name)
            let fullContent = DicomSRContentValidator.validate(parsed, contentConditions: [byReference ? [1, 0] : [0]: facts])
            if expected == .failed { XCTAssertEqual(fullContent[.attributes], .failed, name) }
            if let directory = ProcessInfo.processInfo.environment["DICOM_SR_CONTENT_ITEM_CORPUS_DIRECTORY"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let path = folder.appendingPathComponent(name)
                try DicomDataSetWriter.part10Data(from: source, options: .init(validationPurpose: .instance))
                    .write(to: path.appendingPathExtension("dcm"))
                let conditions = ["heading": String(describing: facts.containerHasHeading), "purpose": String(describing: facts.referencePurposeInConceptName),
                    "observationDiffers": String(describing: facts.observationTimeDiffers), "templateRequired": String(describing: facts.identifyingTemplateRequired)]
                try JSONSerialization.data(withJSONObject: ["attributes": macro[.attributes].rawValue, "conditions": conditions,
                    "schemeVersionRequired": ["DCM": false], "structureAndVRVM": "passed",
                    "diagnostics": macro.diagnostics.map { ["code": $0.code.rawValue, "requirement": $0.requirement?.rawValue ?? ""] }])
                    .write(to: path.appendingPathExtension("json"))
            }
        }
    }
}
