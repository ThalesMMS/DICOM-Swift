import Foundation

// PS3.16, TID 301: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid301 = DicomSRTemplateDefinition(identifier: "301", isExtensible: true, rows: [
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .parameter("ModType"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .parameter("ModValue")
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "370129005", codingSchemeDesignator: "SCT", codeMeaning: "Measurement Method")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("Method")
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121401", codingSchemeDesignator: "DCM", codeMeaning: "Derivation")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("Derivation")
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "363698007", codingSchemeDesignator: "SCT", codeMeaning: "Finding Site")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .parameter("TargetSite")
        ),
        .init(
            id: "6",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "272741003", codingSchemeDesignator: "SCT", codeMeaning: "Laterality")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("244")
        ),
        .init(
            id: "7",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .definedTerm(.init(codeValue: "106233006", codingSchemeDesignator: "SCT", codeMeaning: "Topographical modifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("TargetSiteMod")
        ),
        .init(
            id: "8",
            nestingLevel: 0,
            relationship: "HAS PROPERTIES",
            valueType: .include("310"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["RefAuthority": .parameter("RefAuthority"), "PopulationIndex": .parameter("PopulationIndex"), "RangeAuthority": .parameter("RangeAuthority")]
        ),
        .init(
            id: "9",
            nestingLevel: 0,
            relationship: "INFERRED FROM",
            valueType: .value("NUM"),
            concept: .parameter("DerivationParameter"),
            vm: .oneOrMore,
            requirement: .userConditional(.xor(["10"])),
            valueSet: .unitsParameter("DerivationParameterUnits")
        ),
        .init(
            id: "10",
            nestingLevel: 0,
            relationship: "R-INFERRED FROM",
            valueType: .value("NUM"),
            concept: .parameter("DerivationParameter"),
            vm: .oneOrMore,
            requirement: .userConditional(.xor(["9"])),
            valueSet: .unitsParameter("DerivationParameterUnits")
        ),
        .init(
            id: "11",
            nestingLevel: 0,
            relationship: "INFERRED FROM",
            valueType: .include("315"),
            concept: .any,
            vm: .one,
            requirement: .userConditional(.xor(["12"])),
            valueSet: .none,
            bindings: ["Equation": .parameter("Equation")]
        ),
        .init(
            id: "12",
            nestingLevel: 0,
            relationship: "INFERRED FROM",
            valueType: .value("TEXT"),
            concept: .contextGroup("228"),
            vm: .one,
            requirement: .userConditional(.xor(["11"])),
            valueSet: .none
        ),
        .init(
            id: "13",
            nestingLevel: 0,
            relationship: nil,
            valueType: .include("320"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["Purpose": .parameter("ImagePurpose")]
        ),
        .init(
            id: "14",
            nestingLevel: 0,
            relationship: nil,
            valueType: .include("321"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["Purpose": .parameter("WavePurpose")]
        ),
        .init(
            id: "15",
            nestingLevel: 0,
            relationship: nil,
            valueType: .include("1000"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "16",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121050", codingSchemeDesignator: "DCM", codeMeaning: "Equivalent Meaning of Concept Name")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "16b",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121050", codingSchemeDesignator: "DCM", codeMeaning: "Equivalent Meaning of Concept Name")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("PrecoordinatedMeasurementMeaning")
        ),
        .init(
            id: "17",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .include("4108"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "18",
            nestingLevel: 0,
            relationship: "INFERRED FROM",
            valueType: .value("COMPOSITE"),
            concept: .enumerated(.init(codeValue: "126100", codingSchemeDesignator: "DCM", codeMeaning: "Real World Value Map used for measurement")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "19",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .include("4019"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
