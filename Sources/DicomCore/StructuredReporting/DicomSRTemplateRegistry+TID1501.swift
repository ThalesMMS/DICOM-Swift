import Foundation

// PS3.16, TID 1501: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1501 = DicomSRTemplateDefinition(identifier: "1501", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "CONTAINS",
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
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "370129005", codingSchemeDesignator: "SCT", codeMeaning: "Measurement Method")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("Method")
        ),
        .init(
            id: "6",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "363698007", codingSchemeDesignator: "SCT", codeMeaning: "Finding Site")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .parameter("TargetSite")
        ),
        .init(
            id: "7",
            nestingLevel: 2,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "272741003", codingSchemeDesignator: "SCT", codeMeaning: "Laterality")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("244")
        ),
        .init(
            id: "8",
            nestingLevel: 2,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .definedTerm(.init(codeValue: "106233006", codingSchemeDesignator: "SCT", codeMeaning: "Topographical modifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("TargetSiteMod")
        ),
        .init(
            id: "9",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("COMPOSITE"),
            concept: .enumerated(.init(codeValue: "126100", codingSchemeDesignator: "DCM", codeMeaning: "Real World Value Map used for measurement")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "9b",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .include("4019"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "9c",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("IMAGE"),
            concept: .enumerated(.init(codeValue: "121200", codingSchemeDesignator: "DCM", codeMeaning: "Illustration of ROI")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "9d",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("IMAGE"),
            concept: .enumerated(.init(codeValue: "130401", codingSchemeDesignator: "DCM", codeMeaning: "Visual explanation")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "10",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .include("300"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["Measurement": .parameter("Measurement"), "Units": .parameter("Units"), "ModType": .parameter("ModType"), "ModValue": .parameter("ModValue"), "Method": .parameter("Method"), "Derivation": .parameter("Derivation"), "TargetSite": .parameter("TargetSite"), "TargetSiteMod": .parameter("TargetSiteMod"), "Equation": .parameter("Equation"), "ImagePurpose": .parameter("ImagePurpose"), "WavePurpose": .parameter("WavePurpose"), "RefAuthority": .parameter("RefAuthority"), "RangeAuthority": .parameter("RangeAuthority"), "DerivationParameter": .parameter("DerivationParameter"), "DerivationParameterUnits": .parameter("DerivationParameterUnits")]
        ),
        .init(
            id: "10b",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("IMAGE"),
            concept: .parameter("ImagePurpose"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "10c",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("SCOORD"),
            concept: .parameter("ImagePurpose"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "10d",
            nestingLevel: 2,
            relationship: "SELECTED FROM",
            valueType: .value("IMAGE"),
            concept: .any,
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "10e",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("SCOORD3D"),
            concept: .parameter("ImagePurpose"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "10f",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("WAVEFORM"),
            concept: .parameter("WavePurpose"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "10g",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("TCOORD"),
            concept: .parameter("WavePurpose"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "10h",
            nestingLevel: 2,
            relationship: "SELECTED FROM",
            valueType: .value("WAVEFORM"),
            concept: .any,
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "11",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("CODE"),
            concept: .parameter("QualType"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .parameter("QualValue")
        ),
        .init(
            id: "11b",
            nestingLevel: 2,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .parameter("QualModType"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .parameter("QualModValue")
        ),
        .init(
            id: "12",
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
