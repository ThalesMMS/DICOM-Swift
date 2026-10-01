import Foundation

// PS3.16, TID 1005: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1005 = DicomSRTemplateDefinition(identifier: "1005", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "121018", codingSchemeDesignator: "DCM", codeMeaning: "Procedure Study Instance UID")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "121019", codingSchemeDesignator: "DCM", codeMeaning: "Procedure Study Component UID")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121020", codingSchemeDesignator: "DCM", codeMeaning: "Placer Number")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "110190", codingSchemeDesignator: "DCM", codeMeaning: "Issuer of Identifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121021", codingSchemeDesignator: "DCM", codeMeaning: "Filler Number")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "6",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "110190", codingSchemeDesignator: "DCM", codeMeaning: "Issuer of Identifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "7",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121022", codingSchemeDesignator: "DCM", codeMeaning: "Accession Number")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "8",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "110190", codingSchemeDesignator: "DCM", codeMeaning: "Issuer of Identifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "9",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121023", codingSchemeDesignator: "DCM", codeMeaning: "Procedure Code")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
