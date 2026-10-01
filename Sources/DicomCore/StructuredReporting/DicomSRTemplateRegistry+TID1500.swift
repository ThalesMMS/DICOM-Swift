import Foundation

// PS3.16, TID 1500: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1500 = DicomSRTemplateDefinition(identifier: "1500", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CONTAINER"),
            concept: .contextGroup("7021"),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .include("1204"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 1,
            relationship: "HAS OBS CONTEXT",
            valueType: .include("1001"),
            concept: .any,
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121058", codingSchemeDesignator: "DCM", codeMeaning: "Procedure reported")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .contextGroup("100")
        ),
        .init(
            id: "5",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .include("1600"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "6",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("CONTAINER"),
            concept: .enumerated(.init(codeValue: "126010", codingSchemeDesignator: "DCM", codeMeaning: "Imaging Measurements")),
            vm: .one,
            requirement: .mandatoryConditional(.all([.ifRowAbsent("10"), .ifRowAbsent("12")])),
            valueSet: .none
        ),
        .init(
            id: "6b",
            nestingLevel: 2,
            relationship: "HAS CONCEPT MOD",
            valueType: .include("4019"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "7",
            nestingLevel: 2,
            relationship: "CONTAINS",
            valueType: .include("1410"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["Measurement": .contextGroup("218"), "Units": .contextGroup("7181"), "Derivation": .contextGroup("7464"), "Method": .contextGroup("6147"), "QualModType": .contextGroup("210"), "QualModValue": .contextGroup("211")]
        ),
        .init(
            id: "8",
            nestingLevel: 2,
            relationship: "CONTAINS",
            valueType: .include("1411"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["Measurement": .contextGroup("218"), "Units": .contextGroup("7181"), "Derivation": .contextGroup("7464"), "Method": .contextGroup("6147"), "QualModType": .contextGroup("210"), "QualModValue": .contextGroup("211")]
        ),
        .init(
            id: "9",
            nestingLevel: 2,
            relationship: "CONTAINS",
            valueType: .include("1501"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["Measurement": .contextGroup("218"), "ImagePurpose": .contextGroup("7551"), "Units": .contextGroup("7181"), "Derivation": .contextGroup("7464"), "Method": .contextGroup("6147"), "QualModType": .contextGroup("210"), "QualModValue": .contextGroup("211")]
        ),
        .init(
            id: "10",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("CONTAINER"),
            concept: .enumerated(.init(codeValue: "126011", codingSchemeDesignator: "DCM", codeMeaning: "Derived Imaging Measurements")),
            vm: .one,
            requirement: .mandatoryConditional(.all([.ifRowAbsent("6"), .ifRowAbsent("12")])),
            valueSet: .none
        ),
        .init(
            id: "10b",
            nestingLevel: 2,
            relationship: "HAS CONCEPT MOD",
            valueType: .include("4019"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "11",
            nestingLevel: 2,
            relationship: "CONTAINS",
            valueType: .include("1420"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "12",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("CONTAINER"),
            concept: .enumerated(.init(codeValue: "C0034375", codingSchemeDesignator: "UMLS", codeMeaning: "Qualitative Evaluations")),
            vm: .one,
            requirement: .mandatoryConditional(.all([.ifRowAbsent("6"), .ifRowAbsent("10")])),
            valueSet: .none
        ),
        .init(
            id: "12b",
            nestingLevel: 2,
            relationship: "HAS CONCEPT MOD",
            valueType: .include("4019"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "13",
            nestingLevel: 2,
            relationship: "CONTAINS",
            valueType: .value("CODE"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "13b",
            nestingLevel: 3,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .contextGroup("210"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .contextGroup("211")
        ),
        .init(
            id: "14",
            nestingLevel: 2,
            relationship: "CONTAINS",
            valueType: .value("TEXT"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
