import Foundation
import XCTest
@testable import DicomCore

final class DicomSRTemplateValidatorTests: XCTestCase {
    private typealias Fixture = DicomSRMeasurementReportBuilderTests
    private typealias Builder = DicomSRMeasurementReportBuilder

    private func document(_ items: [DicomSRContentItem], tid: String = "1500", suffix: String = "34") -> DicomSRDocument {
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.88." + suffix, templateIdentifier: tid,
            root: .init(valueType: "CONTAINER", conceptName: Fixture.code("126000"), children: items))
    }

    func test_fullReport_roundTripsThroughValidatedBuilder() throws {
        let original = try Builder.build(Fixture.fullReport())
        let parsed = try XCTUnwrap(DCMDecoder(data: Fixture.fixtureData()).structuredReport)
        let result = DicomSRTemplateValidator.validate(parsed)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertTrue(result.limitations.allSatisfy {
            $0.kind == .contextGroupNotChecked || $0.kind == .customConditionNotEvaluated
        }, "\(result.limitations)")
        XCTAssertTrue(result.informational.isEmpty, "\(result.informational)")
        XCTAssertEqual(parsed.root, original.root)
        XCTAssertTrue(DicomSRSemanticValidator.validateWithTemplate(parsed).semantic.isValid)
    }

    func test_missingObservationContext_reportsMandatoryRow3() {
        let result = DicomSRTemplateValidator.validate(document([Builder.container("126010", "Imaging Measurements", children: [])]))
        XCTAssertTrue(result.errors.contains { $0.kind == .missingMandatory && $0.templateIdentifier == "1500" && $0.rowID == "3" })
    }

    func test_missingAllMeasurementContainers_reportsConditionViolation() {
        let result = DicomSRTemplateValidator.validate(document(Builder.observerItems([
            .init(kind: .device, deviceUID: "2.25.1")
        ])))
        XCTAssertTrue(result.errors.contains { $0.kind == .conditionViolated && $0.rowID == "6" })
    }

    func test_planarROIWithTwoRepresentations_reportsXORViolation() throws {
        let group = Fixture.fullReport().measurementGroups[1]
        let built = try Builder.groupItem(group)
        let extra = DicomSRContentItem(relationshipType: "CONTAINS", valueType: "IMAGE",
            conceptName: Fixture.code("121214"), referencedSOPs: [Fixture.image])
        let root = Builder.container("125007", "Measurement Group", children: built.children + [extra])
        let result = DicomSRTemplateValidator.validate(.init(root: root), template: "1410")
        XCTAssertTrue(result.errors.contains { $0.kind == .conditionViolated && $0.rowID == "5" })
    }

    func test_regionWithoutImage_reportsMissingSelectedFrom() {
        let root = Builder.container("125007", "Measurement Group", children: [
            .init(relationshipType: "CONTAINS", valueType: "SCOORD", conceptName: Fixture.code("111030"),
                  graphicType: "ELLIPSE", graphicData: [1, 4, 7, 4, 4, 2, 4, 6])
        ])
        let result = DicomSRTemplateValidator.validate(.init(root: root), template: "1410")
        XCTAssertTrue(result.errors.contains { $0.kind == .missingMandatory && $0.rowID == "6" })
    }

    func test_presentDescriptorsWithWrongEVUnits_reportUnitsMismatch() {
        for (tid, code) in [("1602", "110910"), ("1604", "111026")] {
            let bad = DicomSRContentItem(relationshipType: "HAS ACQ CONTEXT", valueType: "NUM",
                conceptName: Fixture.code(code), numericValue: 512,
                measurementUnits: tid == "1602" ? Fixture.mm : Fixture.code("mm", scheme: "99LOCAL"))
            let result = DicomSRTemplateValidator.validate(document([bad], tid: tid))
            XCTAssertTrue(result.errors.contains { $0.kind == .unitsMismatch }, "\(result)")
        }
    }

    func test_CTWithoutOptionalDescriptors_doesNotRequireIncludes() {
        let modality = Builder.item("CODE", "121139", "Modality", rel: "HAS ACQ CONTEXT", value: Fixture.code("CT"))
        let result = DicomSRTemplateValidator.validate(document([modality], tid: "1602"))
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
    }

    func test_TID1601WithTwoReferenceValues_reportsXORViolation() {
        let items: [DicomSRContentItem] = ["IMAGE", "COMPOSITE"].map {
            .init(relationshipType: "CONTAINS", valueType: $0, referencedSOPs: [Fixture.image])
        }
        let result = DicomSRTemplateValidator.validate(document(items, tid: "1601"))
        XCTAssertTrue(result.errors.contains { $0.kind == .conditionViolated })
    }

    func test_wrongEnumeratedConcept_reportsConceptMismatch() {
        let root = Builder.container("WRONG", "PARITY", children: [])
        let result = DicomSRTemplateValidator.validate(.init(root: root), template: "1600")
        XCTAssertTrue(result.errors.contains { $0.kind == .conceptMismatch })
    }

    func test_KOSRejectsExtraTextAndRequiresObject() {
        let extra = Builder.item("TEXT", "PARITY", "PARITY", text: "PARITY")
        let result = DicomSRTemplateValidator.validate(document([extra], tid: "2010", suffix: "59"))
        XCTAssertTrue(result.errors.contains { $0.kind == .notExtensibleExtraItem })
        XCTAssertTrue(result.errors.contains { $0.kind == .conditionViolated && ["8", "9", "10"].contains($0.rowID) })
    }

    func test_referencesRequireComprehensiveAndResolveIdentifiers() {
        let ref = DicomSRContentItem(relationshipType: "INFERRED FROM", valueType: "",
                                    referencedContentItemIdentifier: [1, 99])
        let result = DicomSRTemplateValidator.validate(document([ref], tid: "320", suffix: "22"))
        XCTAssertTrue(result.errors.contains { $0.kind == .byReferenceNotPermitted })
        XCTAssertTrue(result.errors.contains { $0.kind == .byReferenceUnresolved })
    }

    func test_includeBindsUnitsAndMissingTemplateIsLimited() {
        let definition = DicomSRTemplateDefinition(identifier: "TEST", rows: [
            .init(id: "1", relationship: "CONTAINS", valueType: .include("300"), requirement: .mandatory,
                  bindings: ["Units": .units(Fixture.mm)])
        ])
        let num = DicomSRContentItem(relationshipType: "CONTAINS", valueType: "NUM", conceptName: Fixture.code("PARITY"),
            numericValue: 1, measurementUnits: Fixture.code("cm", scheme: "UCUM"))
        let result = DicomSRTemplateValidator.validate(document([num]), definition: definition)
        XCTAssertTrue(result.errors.contains { $0.kind == .unitsMismatch && $0.templateIdentifier == "300" })
        let unknown = DicomSRTemplateValidator.validate(.init(root: .init(valueType: "CONTAINER")))
        XCTAssertEqual(unknown.limitations.map(\.kind), [.templateUnknown])
    }

    func test_registryRetainsNormativeRowsAndCustomConditions() {
        XCTAssertEqual(DicomSRTemplateRegistry.definitions.count, 33)
        XCTAssertEqual(DicomSRTemplateRegistry.definitions.values.reduce(0) { $0 + $1.rows.count }, 323)
        XCTAssertEqual(DicomSRTemplateRegistry.definition(for: "1602")?.rows.suffix(6).map(\.id),
                       ["13", "14", "15", "16", "17", "18"])
        XCTAssertFalse(DicomSRTemplateRegistry.definition(for: "2010")!.isExtensible)
        let custom = DicomSRTemplateValidator.validate(document([], tid: "1001"))
        XCTAssertTrue(custom.limitations.contains { $0.kind == .customConditionNotEvaluated })
    }
    func test_builtReport_hasNoTemplateErrorsOrUnclaimedItems() throws {
        let built = try Builder.build(Fixture.fullReport())
        let result = DicomSRTemplateValidator.validate(built)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertTrue(result.informational.isEmpty, "\(result.informational)")
    }

    func test_bestInSetKOS_requiresConditionalTitleModifier() {
        let title = Fixture.code("113013", "Best In Set")
        let image = DicomSRContentItem(relationshipType: "CONTAINS", valueType: "IMAGE", referencedSOPs: [Fixture.image])
        let modifier = Builder.item("CODE", "113011", "Document Title Modifier", rel: "HAS CONCEPT MOD", value: Fixture.code("PARITY"))
        let valid = DicomSRDocument(templateIdentifier: "2010",
            root: .init(valueType: "CONTAINER", conceptName: title, children: [modifier, image]))
        XCTAssertTrue(DicomSRTemplateValidator.validate(valid).errors.isEmpty)
        let invalid = DicomSRDocument(templateIdentifier: "2010",
            root: .init(valueType: "CONTAINER", conceptName: title, children: [image]))
        XCTAssertTrue(DicomSRTemplateValidator.validate(invalid).errors.contains { $0.rowID == "4" && $0.kind == .conditionViolated })
    }

    func test_fullReport_rawRoundTripPreservesTemplateTree() throws {
        let original = try Builder.build(Fixture.fullReport())
        let dataSet = DicomStructuredReportBuilder.dataSet(from: original,
            studyInstanceUID: "2.25.2345004", seriesInstanceUID: "2.25.2345005")
        let parsed = try XCTUnwrap(DCMDecoder(data: DicomDataSetWriter.part10Data(from: dataSet)).structuredReport)
        XCTAssertEqual(parsed.root, original.root)
        XCTAssertTrue(DicomSRTemplateValidator.validate(parsed).errors.isEmpty)
    }

}
