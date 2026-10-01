import Foundation

// PS3.16, TID 2010: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid2010 = DicomSRTemplateDefinition(identifier: "2010", isExtensible: false, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CONTAINER"),
            concept: .contextGroup("7010"),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "113011", codingSchemeDesignator: "DCM", codeMeaning: "Document Title Modifier")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "113011", codingSchemeDesignator: "DCM", codeMeaning: "Document Title Modifier")),
            vm: .one,
            requirement: .userConditional(.any([.ifRowConcept("1", .init(codeValue: "113001", codingSchemeDesignator: "DCM", codeMeaning: "Rejected for Quality Reasons")), .ifRowConcept("1", .init(codeValue: "113010", codingSchemeDesignator: "DCM", codeMeaning: "Quality Issue"))])),
            valueSet: .contextGroup("7011")
        ),
        .init(
            id: "4",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "113011", codingSchemeDesignator: "DCM", codeMeaning: "Document Title Modifier")),
            vm: .one,
            requirement: .mandatoryConditional(.any([.ifRowConcept("1", .init(codeValue: "113013", codingSchemeDesignator: "DCM", codeMeaning: "Best In Set"))])),
            valueSet: .contextGroup("7012")
        ),
        .init(
            id: "4b",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121023", codingSchemeDesignator: "DCM", codeMeaning: "Procedure Code")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .include("1204"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "6",
            nestingLevel: 1,
            relationship: "HAS OBS CONTEXT",
            valueType: .include("1002"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "7",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "113012", codingSchemeDesignator: "DCM", codeMeaning: "Key Object Description")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "8",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("IMAGE"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .mandatoryConditional(.not(.ifRowsAnyPresent(["9", "10"]))),
            valueSet: .none
        ),
        .init(
            id: "9",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("WAVEFORM"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .mandatoryConditional(.not(.ifRowsAnyPresent(["8", "10"]))),
            valueSet: .none
        ),
        .init(
            id: "10",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("COMPOSITE"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .mandatoryConditional(.not(.ifRowsAnyPresent(["8", "9"]))),
            valueSet: .none
        ),
        .init(
            id: "11",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .include("1600"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.any([.ifRowConcept("1", .init(codeValue: "131560", codingSchemeDesignator: "DCM", codeMeaning: "Manifest with Description"))])),
            valueSet: .none
        )
    ])
}
