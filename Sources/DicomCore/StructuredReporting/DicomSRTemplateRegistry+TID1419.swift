import Foundation

// PS3.16, TID 1419: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1419 = DicomSRTemplateDefinition(identifier: "1419", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "370129005", codingSchemeDesignator: "SCT", codeMeaning: "Measurement Method")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("Method")
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "363698007", codingSchemeDesignator: "SCT", codeMeaning: "Finding Site")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .parameter("TargetSite")
        ),
        .init(
            id: "3",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "272741003", codingSchemeDesignator: "SCT", codeMeaning: "Laterality")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("244")
        ),
        .init(
            id: "4",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .definedTerm(.init(codeValue: "106233006", codingSchemeDesignator: "SCT", codeMeaning: "Topographical modifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("TargetSiteMod")
        ),
        .init(
            id: "4b",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .include("4019"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("NUM"),
            concept: .parameter("Measurement"),
            vm: .oneOrMore,
            requirement: .mandatory,
            valueSet: .unitsParameter("Units")
        ),
        .init(
            id: "6",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .parameter("ModType"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .parameter("ModValue")
        ),
        .init(
            id: "7",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "370129005", codingSchemeDesignator: "SCT", codeMeaning: "Measurement Method")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("Method")
        ),
        .init(
            id: "8",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121401", codingSchemeDesignator: "DCM", codeMeaning: "Derivation")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("Derivation")
        ),
        .init(
            id: "9",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "363698007", codingSchemeDesignator: "SCT", codeMeaning: "Finding Site")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .parameter("TargetSite")
        ),
        .init(
            id: "10",
            nestingLevel: 2,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "272741003", codingSchemeDesignator: "SCT", codeMeaning: "Laterality")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("244")
        ),
        .init(
            id: "11",
            nestingLevel: 2,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .definedTerm(.init(codeValue: "106233006", codingSchemeDesignator: "SCT", codeMeaning: "Topographical modifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .parameter("TargetSiteMod")
        ),
        .init(
            id: "12",
            nestingLevel: 1,
            relationship: "HAS PROPERTIES",
            valueType: .include("310"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["RefAuthority": .parameter("RefAuthority"), "RangeAuthority": .parameter("RangeAuthority")]
        ),
        .init(
            id: "13",
            nestingLevel: 1,
            relationship: "INFERRED FROM",
            valueType: .value("NUM"),
            concept: .parameter("DerivationParameter"),
            vm: .oneOrMore,
            requirement: .userConditional(.xor(["14"])),
            valueSet: .parameter("DerivationParameterUnits")
        ),
        .init(
            id: "14",
            nestingLevel: 1,
            relationship: "R-INFERRED FROM",
            valueType: .value("NUM"),
            concept: .parameter("DerivationParameter"),
            vm: .oneOrMore,
            requirement: .userConditional(.xor(["13"])),
            valueSet: .parameter("DerivationParameterUnits")
        ),
        .init(
            id: "14b",
            nestingLevel: 1,
            relationship: "INFERRED FROM",
            valueType: .value("CODE"),
            concept: .parameter("DerivationParameter"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "14c",
            nestingLevel: 1,
            relationship: "INFERRED FROM",
            valueType: .value("TEXT"),
            concept: .parameter("DerivationParameter"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "15",
            nestingLevel: 1,
            relationship: "INFERRED FROM",
            valueType: .include("315"),
            concept: .any,
            vm: .one,
            requirement: .userConditional(.xor(["16"])),
            valueSet: .none,
            bindings: ["Equation": .parameter("Equation")]
        ),
        .init(
            id: "16",
            nestingLevel: 1,
            relationship: "INFERRED FROM",
            valueType: .value("TEXT"),
            concept: .contextGroup("228"),
            vm: .one,
            requirement: .userConditional(.xor(["15"])),
            valueSet: .none
        ),
        .init(
            id: "17",
            nestingLevel: 1,
            relationship: nil,
            valueType: .include("1000"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "18",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121050", codingSchemeDesignator: "DCM", codeMeaning: "Equivalent Meaning of Concept Name")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "19",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("COMPOSITE"),
            concept: .enumerated(.init(codeValue: "126100", codingSchemeDesignator: "DCM", codeMeaning: "Real World Value Map used for measurement")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "20",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .include("4019"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
