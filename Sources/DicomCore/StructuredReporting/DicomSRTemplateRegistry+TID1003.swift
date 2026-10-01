import Foundation

// PS3.16, TID 1003: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1003 = DicomSRTemplateDefinition(identifier: "1003", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("PNAME"),
            concept: .enumerated(.init(codeValue: "121008", codingSchemeDesignator: "DCM", codeMeaning: "Person Observer Name")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "1a",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "128774", codingSchemeDesignator: "DCM", codeMeaning: "Person Observer's Login Name")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121009", codingSchemeDesignator: "DCM", codeMeaning: "Person Observer's Organization Name")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121010", codingSchemeDesignator: "DCM", codeMeaning: "Person Observer's Role in the Organization")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("7452")
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121011", codingSchemeDesignator: "DCM", codeMeaning: "Person Observer's Role in this Procedure")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("7453")
        ),
        .init(
            id: "5",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "128775", codingSchemeDesignator: "DCM", codeMeaning: "Identifier within Person Observer's Role")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
