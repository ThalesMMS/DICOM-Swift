import Foundation
import XCTest
@testable import DicomCore

final class DicomSRContentValidatorTests: XCTestCase {
    func test_imageReferenceIcon_rejectsOversizeMetadataAtItsOriginalPath() throws {
        let icon = DicomDataSet(elements: [.init(tag: 0x00280010, vr: .US, value: .unsignedIntegers([129]))])
        let pair = DicomDataSet(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.2.1", .UI),
            text(0x00081155, "2.25.23214004", .UI), sequence(0x00880200, [icon])])
        let image = container().setting(text(0x0040A040, "IMAGE", .CS)).setting(sequence(0x00081199, [pair]))
        let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [image])))
        XCTAssertTrue(report.diagnostics.contains { $0.code == .attributeValueNotAllowed &&
            $0.path == [.tag(0x0040A730), .item(0), .tag(0x00081199), .item(0), .tag(0x00880200), .item(0), .tag(0x00280010)] })
    }

    func test_referenceConditions_applyToOriginalNestedContentIndex() throws {
        let pair = DicomDataSet(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.2.1", .UI),
            text(0x00081155, "2.25.23214004", .UI)])
        let image = container().setting(text(0x0040A040, "IMAGE", .CS)).setting(sequence(0x00081199, [pair]))
        var subset = DicomContentReferenceMacro.Conditions()
        subset.isMultiframeImage = .satisfied
        subset.isSegmentation = .unsatisfied
        subset.appliesToAllFrames = .unsatisfied
        let tree = container().setting(sequence(0x0040A730, [image, image]))
        let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [.init(), tree])),
            referenceConditions: [[1, 1]: subset])
        let missing = report.diagnostics.filter { $0.code == .requiredAttributeMissing && $0.path.last == .tag(0x00081160) }
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.path, [.tag(0x0040A730), .item(1), .tag(0x0040A730), .item(1),
            .tag(0x00081199), .item(0), .tag(0x00081160)])
    }

    func test_referenceSelectors_withoutExternalFactsAreNotRequiredBecauseAbsenceDenotesTheWholeObject() throws {
        let pair = DicomDataSet(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.2.1", .UI),
            text(0x00081155, "2.25.23214004", .UI)])
        let image = container().setting(text(0x0040A040, "IMAGE", .CS)).setting(sequence(0x00081199, [pair]))
        let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [image])))
        for tag in [0x00081160, 0x0062000B] {
            XCTAssertFalse(report.diagnostics.contains {
                $0.path == [.tag(0x0040A730), .item(0), .tag(0x00081199), .item(0), .tag(tag)] })
        }
    }

    func test_accompanyingReference_requiresOneCompleteSOPPair() throws {
        let pair = DicomDataSet(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.2.1", .UI),
            text(0x00081155, "2.25.23214004", .UI)])
        for tag in [0x00081199, 0x0008114B] {
            let image = container().setting(text(0x0040A040, "IMAGE", .CS))
                .setting(sequence(0x00081199, [pair.setting(sequence(tag, [.init()]))]))
            let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [image])))
            XCTAssertEqual(report[.attributes], .failed)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing &&
                $0.path == [.tag(0x0040A730), .item(0), .tag(0x00081199), .item(0), .tag(tag), .item(0), .tag(0x00081155)] })
        }
    }

    func test_supportedDocument_reusesSemanticValidatorWithoutClaimingFullContentConformance() throws {
        let dataSet = try fixture()
        let report = DicomSRContentValidator.validate(dataSet)
        XCTAssertEqual(report[.operation], .passed)
        XCTAssertEqual(report[.attributes], .incomplete)
        XCTAssertEqual(report[.references], .notEvaluated)
        // Incompleteness comes from unstated facts (observation time, root template), not a blanket marker.
        XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable })
        XCTAssertTrue(report.diagnostics.contains { $0.code == .conditionUndetermined })
        let decoded = try XCTUnwrap(DCMDecoder(data: DicomDataSetWriter.part10Data(from: dataSet)).structuredReport)
        XCTAssertTrue(DicomSRSemanticValidator.validate(decoded).isValid)
    }

    func test_missingRootAndChildValueTypes_cannotBeRepairedByParserDefaults() throws {
        let baseline = try fixture()
        let rootMissing = baseline.removing(0x0040A040)
        let childMissing = baseline.setting(sequence(0x0040A730, [container().removing(0x0040A040)]))
        for dataSet in [rootMissing, childMissing] {
            let report = DicomSRContentValidator.validate(dataSet)
            XCTAssertEqual(report[.attributes], .failed)
            XCTAssertNotEqual(report[.operation], .passed)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path.last == .tag(0x0040A040) })
        }
    }

    func test_emptySibling_doesNotShiftLaterRawGraphicDiagnosticPath() throws {
        let badGraphic = DicomDataSet(elements: [text(0x0040A040, "SCOORD", .CS), text(0x0040A010, "CONTAINS", .CS),
            sequence(0x0040A043, [code()]), text(0x00700023, "POINT", .CS),
            .init(tag: 0x00700022, vr: .FL, value: .floats([1, 2, 3]))])
        let dataSet = try fixture().setting(sequence(0x0040A730, [DicomDataSet(), badGraphic]))
        let report = DicomSRContentValidator.validate(dataSet)
        XCTAssertEqual(report[.attributes], .failed)
        XCTAssertEqual(report[.operation], .incomplete)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .invalidMultiplicity && $0.path == [.tag(0x0040A730), .item(1), .tag(0x00700022)]
        })
        XCTAssertFalse(report.diagnostics.contains {
            $0.code == .invalidMultiplicity && $0.path == [.tag(0x0040A730), .item(0), .tag(0x00700022)]
        })
    }

    func test_negativeAndNonfiniteCoordinates_failLegacyAndRawAttributeValidation() throws {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            let child = DicomDataSet(elements: [text(0x0040A040, "SCOORD", .CS), text(0x0040A010, "CONTAINS", .CS),
                sequence(0x0040A043, [code()]), text(0x00700023, "POINT", .CS),
                .init(tag: 0x00700022, vr: .FL, value: .floats([value, 1]))])
            let dataSet = try fixture().setting(sequence(0x0040A730, [child]))
            let decoded = try XCTUnwrap(DCMDecoder(data: DicomDataSetWriter.part10Data(from: dataSet)).structuredReport)
            XCTAssertTrue(DicomSRSemanticValidator.validate(decoded).errors.contains {
                if case .invalidGraphicData = $0 { return true }
                return false
            })
            let report = DicomSRContentValidator.validate(dataSet)
            XCTAssertEqual(report[.attributes], .failed)
            XCTAssertTrue(report.diagnostics.contains { $0.code == .attributeValueNotAllowed &&
                $0.path == [.tag(0x0040A730), .item(0), .tag(0x00700022)] })
            XCTAssertTrue(report.diagnostics.contains { $0.code == .semanticProjectionUnavailable })
        }
    }

    func test_numericFallback_cannotHideMissingMeasuredValueSequence() throws {
        let number = DicomDataSet(elements: [text(0x0040A040, "NUM", .CS), text(0x0040A010, "CONTAINS", .CS),
            sequence(0x0040A043, [code()]), text(0x0040A30A, "42", .DS)])
        let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [number])))
        XCTAssertEqual(report[.attributes], .failed)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .requiredAttributeMissing && $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040A300)]
        })
        XCTAssertTrue(report.diagnostics.contains { $0.code == .semanticProjectionUnavailable })
    }

    func test_emptyMeasuredValue_isNotMisreportedAsMissingType2Sequence() throws {
        let qualifier = code().setting(text(0x00080100, "114007", .SH))
            .setting(text(0x00080104, "Measurement not attempted", .LO))
        let number = DicomDataSet(elements: [text(0x0040A040, "NUM", .CS), text(0x0040A010, "CONTAINS", .CS),
            sequence(0x0040A043, [code()]), sequence(0x0040A300, []), sequence(0x0040A301, [qualifier])])
        let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [number])))
        XCTAssertEqual(report[.attributes], .incomplete) // Full terminology/template rules remain pending.
        XCTAssertEqual(report[.operation], .failed) // Existing application scope requires a usable measurement.
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .semanticValueMissing && $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040A300)]
        })
        XCTAssertFalse(report.diagnostics.contains { $0.path.contains(.tag(0x0040A300)) && $0.path.last == .item(0) })
    }

    func test_unsupportedUnitScheme_retainsExactNestedPathAndNoInstanceText() throws {
        let units = code(scheme: "PRIVATE_SENTINEL")
        let number = DicomDataSet(elements: [text(0x0040A040, "NUM", .CS), text(0x0040A010, "CONTAINS", .CS),
            sequence(0x0040A043, [code()]), sequence(0x0040A300, [.init(elements: [text(0x0040A30A, "42", .DS),
                sequence(0x004008EA, [units])])])])
        let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [number])))
        XCTAssertEqual(report[.operation], .incomplete)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .semanticScopeUnavailable && $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040A300),
                .item(0), .tag(0x004008EA), .item(0), .tag(0x00080102)]
        })
        let json = String(decoding: try JSONEncoder().encode(report.diagnostics), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE_SENTINEL"))
        XCTAssertFalse(json.contains("2.25.232140"))
    }

    func test_opaqueCodes_cannotBecomeFalseMissingConceptErrors() throws {
        let dataSet = try fixture().setting(.init(tag: 0x0040A043, vr: .UN, value: .bytes(Data([1, 2]))))
        let report = DicomSRContentValidator.validate(dataSet)
        XCTAssertEqual(report[.operation], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .semanticProjectionUnavailable })
        XCTAssertFalse(report.diagnostics.contains { $0.code == .semanticValueMissing })
    }

    func test_longCodeRepresentation_isUnprojectableRatherThanMissing() throws {
        let longCode = code().removing(0x00080100).setting(text(0x00080119, "SYNTHETIC LONG CODE VALUE", .UC))
        let child = DicomDataSet(elements: [text(0x0040A040, "CODE", .CS), text(0x0040A010, "CONTAINS", .CS),
            sequence(0x0040A043, [code()]), sequence(0x0040A168, [longCode])])
        let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [child])))
        XCTAssertEqual(report[.operation], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .semanticProjectionUnavailable &&
            $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040A168), .item(0), .tag(0x00080119)] })
        XCTAssertFalse(report.diagnostics.contains { $0.code == .semanticValueMissing })
    }

    func test_numericPrecisionFacts_applyToOriginalContentItemIndex() throws {
        let units = code(scheme: "UCUM").setting(text(0x00080100, "mm", .SH))
        let number = DicomDataSet(elements: [text(0x0040A040, "NUM", .CS), text(0x0040A010, "CONTAINS", .CS),
            sequence(0x0040A043, [code()]), sequence(0x0040A300, [.init(elements: [text(0x0040A30A, "42", .DS),
                sequence(0x004008EA, [units])])])])
        let dataSet = try fixture().setting(sequence(0x0040A730, [number, number]))
        let report = DicomSRContentValidator.validate(dataSet, numericPrecisionRequirements: [
            [1]: .init(floatingPoint: .satisfied, rational: .unsatisfied)
        ])
        let missing = report.diagnostics.filter { $0.code == .requiredAttributeMissing && $0.path.last == .tag(0x0040A161) }
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.path, [.tag(0x0040A730), .item(1), .tag(0x0040A300), .item(0), .tag(0x0040A161)])
    }

    func test_realByReferenceEncoding_isUnsupportedWithoutDroppingSiblingPositions() throws {
        let byReference = DicomDataSet(elements: [text(0x0040A010, "INFERRED FROM", .CS),
            .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1, 1]))])
        let unknown = container().setting(text(0x0040A040, "FUTURE", .CS))
        let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [byReference, unknown])))
        XCTAssertEqual(report[.operation], .incomplete)
        XCTAssertTrue(report.diagnostics.contains { $0.path == [.tag(0x0040A730), .item(0), .tag(0x0040DB73)] })
        XCTAssertTrue(report.diagnostics.contains { $0.path == [.tag(0x0040A730), .item(1), .tag(0x0040A040)] })
    }

    func test_sharedWorkAndDiagnosticLimits_doNotApproveEitherInterruptedLayer() throws {
        for limit in [0, 1, 10] {
            let report = DicomSRContentValidator.validate(try fixture(),
                limits: .init(maximumRuleEvaluations: limit, maximumDiagnostics: 2))
            XCTAssertNotEqual(report[.attributes], .passed)
            XCTAssertNotEqual(report[.operation], .passed)
            XCTAssertLessThanOrEqual(report.diagnostics.count, 4)
        }
        let children = Array(repeating: DicomDataSet(), count: 30)
        let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, children)),
            limits: .init(maximumDiagnostics: 4))
        XCTAssertEqual(report[.attributes], .failed)
        XCTAssertLessThanOrEqual(report.diagnostics.count, 6)
        XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached && $0.layer == .operation })
    }

    func test_byReferenceItem_rejectsByValueContentAndNonpositiveIdentifiers() throws {
        let reference = DicomDataSet(elements: [text(0x0040A010, "INFERRED FROM", .CS),
            .init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1, 1]))])
        let mixed = reference.setting(text(0x0040A040, "TEXT", .CS)).setting(text(0x0040A160, "Synthetic", .UT))
        let zero = reference.setting(.init(tag: 0x0040DB73, vr: .UL, value: .unsignedIntegers([1, 0])))
        for item in [mixed, zero] {
            let report = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [item])))
            XCTAssertEqual(report[.attributes], .failed)
            XCTAssertEqual(report[.operation], .incomplete)
        }
    }

    func test_nestedCodeWorkAndGraphics_areChargedToOneTraversalBudget() throws {
        let codes = Array(repeating: code(), count: 100)
        let item = container().setting(sequence(0x0040A043, codes))
        let dataSet = try fixture().setting(sequence(0x0040A730, [item, container()]))
        let report = DicomSRContentValidator.validate(dataSet, limits: .init(maximumRuleEvaluations: 100))
        XCTAssertTrue(report.diagnostics.contains { $0.code == .evaluationLimitReached })
        let graphic = container().removing(0x0040A050).setting(text(0x0040A040, "SCOORD", .CS)).setting(text(0x00700023, "POLYLINE", .CS))
            .setting(.init(tag: 0x00700022, vr: .FL, value: .floats(Array(repeating: 1, count: 500))))
        let graphicReport = DicomSRContentValidator.validate(try fixture().setting(sequence(0x0040A730, [graphic])),
            limits: .init(maximumRuleEvaluations: 200))
        XCTAssertTrue(graphicReport.diagnostics.contains { $0.code == .evaluationLimitReached && $0.path.last == .tag(0x00700022) })
    }

    private func fixture() throws -> DicomDataSet {
        let title = DicomCodedConcept(codeValue: "126000", codingSchemeDesignator: "DCM", codeMeaning: "Imaging Measurement Report")
        let document = DicomSRDocument(sopClassUID: DicomSRDocument.enhancedSRStorageSOPClassUID,
            completionFlag: "COMPLETE", verificationFlag: "UNVERIFIED", templateIdentifier: "1500",
            root: .init(valueType: "CONTAINER", conceptName: title, continuityOfContent: "SEPARATE", children: [
                .init(relationshipType: "CONTAINS", valueType: "TEXT", conceptName: title, textValue: "Synthetic finding")
            ]))
        return try DicomStructuredReportBuilder.validatedDataSet(from: document,
            studyInstanceUID: "2.25.23214001", seriesInstanceUID: "2.25.23214002", sopInstanceUID: "2.25.23214003")
    }

    private func container() -> DicomDataSet {
        .init(elements: [text(0x0040A040, "CONTAINER", .CS), text(0x0040A010, "CONTAINS", .CS),
            sequence(0x0040A043, [code()]), text(0x0040A050, "SEPARATE", .CS)])
    }

    private func code(scheme: String = "DCM") -> DicomDataSet {
        .init(elements: [text(0x00080100, "126000", .SH), text(0x00080102, scheme, .SH), text(0x00080104, "Synthetic", .LO)])
    }

    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings([value]))
    }

    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}
