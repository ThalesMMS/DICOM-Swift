import Foundation

// PS3.16, TID 1411: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1411 = DicomSRTemplateDefinition(identifier: "1411", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CONTAINER"),
            concept: .enumerated(.init(codeValue: "125007", codingSchemeDesignator: "DCM", codeMeaning: "Measurement Group")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "1b",
            nestingLevel: 1,
            relationship: "HAS OBS CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "C67447", codingSchemeDesignator: "NCIt", codeMeaning: "Activity Session")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 1,
            relationship: "HAS OBS CONTEXT",
            valueType: .value("TEXT"),
            concept: .definedTerm(.init(codeValue: "112039", codingSchemeDesignator: "DCM", codeMeaning: "Tracking Identifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("TrackingID")
        ),
        .init(
            id: "3",
            nestingLevel: 1,
            relationship: "HAS OBS CONTEXT",
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "112040", codingSchemeDesignator: "DCM", codeMeaning: "Tracking Unique Identifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("TrackingUID")
        ),
        .init(
            id: "3a",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "276214006", codingSchemeDesignator: "SCT", codeMeaning: "Finding category")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("FindingCategory")
        ),
        .init(
            id: "3b",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121071", codingSchemeDesignator: "DCM", codeMeaning: "Finding")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("FindingType")
        ),
        .init(
            id: "3c",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "130400", codingSchemeDesignator: "DCM", codeMeaning: "Geometric purpose of region")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("219")
        ),
        .init(
            id: "4",
            nestingLevel: 1,
            relationship: "HAS OBS CONTEXT",
            valueType: .include("1502"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("SCOORD"),
            concept: .enumerated(.init(codeValue: "111030", codingSchemeDesignator: "DCM", codeMeaning: "Image Region")),
            vm: .oneOrMore,
            requirement: .mandatoryConditional(.xor(["7", "10", "12b"])),
            valueSet: .none
        ),
        .init(
            id: "6",
            nestingLevel: 2,
            relationship: "SELECTED FROM",
            valueType: .value("IMAGE"),
            concept: .any,
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "7",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("IMAGE"),
            concept: .enumerated(.init(codeValue: "121191", codingSchemeDesignator: "DCM", codeMeaning: "Referenced Segment")),
            vm: .one,
            requirement: .mandatoryConditional(.xor(["5", "10", "12b"])),
            valueSet: .none
        ),
        .init(
            id: "10",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("SCOORD3D"),
            concept: .enumerated(.init(codeValue: "121231", codingSchemeDesignator: "DCM", codeMeaning: "Volume Surface")),
            vm: .oneOrMore,
            requirement: .mandatoryConditional(.xor(["5", "7", "12b"])),
            valueSet: .none
        ),
        .init(
            id: "11",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("IMAGE"),
            concept: .enumerated(.init(codeValue: "121233", codingSchemeDesignator: "DCM", codeMeaning: "Source image for segmentation")),
            vm: .oneOrMore,
            requirement: .mandatoryConditional(.all([.xor(["12"]), .ifRowsAnyPresent(["7", "10"])])),
            valueSet: .none
        ),
        .init(
            id: "12",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "121232", codingSchemeDesignator: "DCM", codeMeaning: "Source series for segmentation")),
            vm: .one,
            requirement: .mandatoryConditional(.all([.xor(["11"]), .ifRowsAnyPresent(["7", "10"])])),
            valueSet: .none
        ),
        .init(
            id: "12b",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("COMPOSITE"),
            concept: .enumerated(.init(codeValue: "130488", codingSchemeDesignator: "DCM", codeMeaning: "Region in Space")),
            vm: .one,
            requirement: .mandatoryConditional(.xor(["5", "7", "10"])),
            valueSet: .none
        ),
        .init(
            id: "12c",
            nestingLevel: 2,
            relationship: "HAS PROPERTIES",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "130489", codingSchemeDesignator: "DCM", codeMeaning: "Referenced Region of Interest Identifier")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "13",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("IMAGE"),
            concept: .enumerated(.init(codeValue: "121200", codingSchemeDesignator: "DCM", codeMeaning: "Illustration of ROI")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "13b",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("IMAGE"),
            concept: .enumerated(.init(codeValue: "130401", codingSchemeDesignator: "DCM", codeMeaning: "Visual explanation")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "14",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("COMPOSITE"),
            concept: .enumerated(.init(codeValue: "126100", codingSchemeDesignator: "DCM", codeMeaning: "Real World Value Map used for measurement")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "15",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .include("1419"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["Measurement": .parameter("Measurement"), "Units": .parameter("Units"), "ModType": .parameter("ModType"), "ModValue": .parameter("ModValue"), "Method": .parameter("Method"), "Derivation": .parameter("Derivation"), "TargetSite": .parameter("TargetSite"), "TargetSiteMod": .parameter("TargetSiteMod"), "Equation": .parameter("Equation"), "RefAuthority": .parameter("RefAuthority"), "RangeAuthority": .parameter("RangeAuthority"), "DerivationParameter": .parameter("DerivationParameter"), "DerivationParameterUnits": .parameter("DerivationParameterUnits")]
        ),
        .init(
            id: "16",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("CODE"),
            concept: .parameter("QualType"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .parameter("QualValue")
        ),
        .init(
            id: "16b",
            nestingLevel: 2,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .parameter("QualModType"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .parameter("QualModValue")
        ),
        .init(
            id: "17",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("TEXT"),
            concept: .parameter("QualType"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
