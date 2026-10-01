import XCTest
@testable import DicomCore

final class DicomStructuredReportStackSafetyTests: XCTestCase {
    func test_semanticValidator_deepChain_preservesLeafPathWithoutRecursiveStackGrowth() {
        let depth = 5_000
        let document = report(root: deepRoot(depth: depth, leafText: nil))

        let result = DicomSRSemanticValidator.validate(document)

        XCTAssertEqual(
            result.errors,
            [.missingValue(path: "root" + String(repeating: "/0", count: depth - 1), valueType: "TEXT")]
        )
    }

    func test_semanticValidator_wideTree_preservesSiblingErrorOrder() {
        let width = 5_000
        let children = (0..<width).map { _ in
            DicomSRContentItem(
                relationshipType: "CONTAINS",
                valueType: "TEXT",
                conceptName: observationConcept
            )
        }
        let document = report(root: reportRoot(children: children))

        let result = DicomSRSemanticValidator.validate(document)

        XCTAssertEqual(
            result.errors,
            (0..<width).map {
                .missingValue(path: "root/\($0)", valueType: "TEXT")
            }
        )
    }

    func test_semanticValidator_asymmetricTree_preservesDocumentPreorderAndEvidenceErrorOrder() {
        let invalidUnits = DicomCodedConcept(
            codeValue: "1",
            codingSchemeDesignator: "99UNITS",
            codeMeaning: "unsupported units"
        )
        let invalidEvidence = DicomKeyObjectReference(
            referencedSOPClassUID: nil,
            referencedSOPInstanceUID: nil
        )
        let root = DicomSRContentItem(
            valueType: "CONTAINER",
            conceptName: DicomCodedConcept(
                codeValue: "999999",
                codingSchemeDesignator: "DCM",
                codeMeaning: "Wrong report title"
            ),
            children: [
                DicomSRContentItem(
                    relationshipType: "HAS OBS CONTEXT",
                    valueType: "NUM",
                    numericValue: nil,
                    measurementUnits: invalidUnits,
                    children: [
                        DicomSRContentItem(
                            valueType: "IMAGE",
                            conceptName: observationConcept
                        )
                    ]
                ),
                DicomSRContentItem(
                    relationshipType: "R-CONTAINS",
                    valueType: "TEXT"
                )
            ]
        )
        let document = DicomSRDocument(
            sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            templateIdentifier: "9999",
            root: root,
            evidenceReferences: [invalidEvidence]
        )

        let result = DicomSRSemanticValidator.validate(document)

        XCTAssertEqual(result.errors, [
            .unsupportedTemplateIdentifier(
                "9999",
                sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID
            ),
            .unsupportedRootConcept(path: "root", codeValue: "999999", codingSchemeDesignator: "DCM"),
            .unsupportedValueType(path: "root/0", valueType: "NUM"),
            .missingConceptName(path: "root/0.conceptName"),
            .missingNumericValue(path: "root/0"),
            .unsupportedCodingScheme(path: "root/0.measurementUnits", codingSchemeDesignator: "99UNITS"),
            .unsupportedMeasurementUnit(path: "root/0", codingSchemeDesignator: "99UNITS"),
            .missingRelationshipType(path: "root/0/0"),
            .missingReferencedSOP(path: "root/0/0"),
            .unsupportedByReferenceRelationship(path: "root/1", relationshipType: "R-CONTAINS"),
            .missingConceptName(path: "root/1.conceptName"),
            .missingValue(path: "root/1", valueType: "TEXT"),
            .missingReferencedSOP(path: "evidence[0]")
        ])
    }

    private var reportTitleConcept: DicomCodedConcept {
        DicomCodedConcept(
            codeValue: "126000",
            codingSchemeDesignator: "DCM",
            codeMeaning: "Imaging Measurement Report"
        )
    }

    private var observationConcept: DicomCodedConcept {
        DicomCodedConcept(
            codeValue: "121071",
            codingSchemeDesignator: "DCM",
            codeMeaning: "Finding"
        )
    }

    private func report(root: DicomSRContentItem) -> DicomSRDocument {
        DicomSRDocument(
            sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            templateIdentifier: "1500",
            root: root
        )
    }

    private func reportRoot(children: [DicomSRContentItem]) -> DicomSRContentItem {
        DicomSRContentItem(
            valueType: "CONTAINER",
            conceptName: reportTitleConcept,
            children: children
        )
    }

    private func deepRoot(depth: Int, leafText: String?) -> DicomSRContentItem {
        precondition(depth >= 1)
        if depth == 1 {
            return DicomSRContentItem(
                valueType: "TEXT",
                conceptName: observationConcept,
                textValue: leafText
            )
        }

        var item = DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "TEXT",
            conceptName: observationConcept,
            textValue: leafText
        )
        for _ in 0..<(depth - 2) {
            item = DicomSRContentItem(
                relationshipType: "CONTAINS",
                valueType: "CONTAINER",
                conceptName: observationConcept,
                children: [item]
            )
        }
        return reportRoot(children: [item])
    }
}
