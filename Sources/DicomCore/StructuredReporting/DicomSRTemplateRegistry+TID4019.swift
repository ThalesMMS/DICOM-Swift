import Foundation

// PS3.16, TID 4019: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid4019 = DicomSRTemplateDefinition(identifier: "4019", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "111001", codingSchemeDesignator: "DCM", codeMeaning: "Algorithm Name")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "1b",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "111001", codingSchemeDesignator: "DCM", codeMeaning: "Algorithm Name")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "111003", codingSchemeDesignator: "DCM", codeMeaning: "Algorithm Version")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "2b",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "122405", codingSchemeDesignator: "DCM", codeMeaning: "Algorithm Manufacturer")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "111002", codingSchemeDesignator: "DCM", codeMeaning: "Algorithm Parameters")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "111000", codingSchemeDesignator: "DCM", codeMeaning: "Algorithm Family")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
