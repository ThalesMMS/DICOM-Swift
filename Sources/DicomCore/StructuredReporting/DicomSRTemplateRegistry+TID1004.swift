import Foundation

// PS3.16, TID 1004: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1004 = DicomSRTemplateDefinition(identifier: "1004", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "121012", codingSchemeDesignator: "DCM", codeMeaning: "Device Observer UID")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121013", codingSchemeDesignator: "DCM", codeMeaning: "Device Observer Name")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121014", codingSchemeDesignator: "DCM", codeMeaning: "Device Observer Manufacturer")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121015", codingSchemeDesignator: "DCM", codeMeaning: "Device Observer Model Name")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121016", codingSchemeDesignator: "DCM", codeMeaning: "Device Observer Serial Number")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121017", codingSchemeDesignator: "DCM", codeMeaning: "Device Observer Physical Location During Observation")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "7",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "113876", codingSchemeDesignator: "DCM", codeMeaning: "Device Role in Procedure")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .contextGroup("7445")
        ),
        .init(
            id: "8",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "110119", codingSchemeDesignator: "DCM", codeMeaning: "Station AE Title")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "9",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "121061", codingSchemeDesignator: "DCM", codeMeaning: "Device Observer Manufacturer Class UID")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "10",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CONTAINER"),
            concept: .enumerated(.init(codeValue: "121000", codingSchemeDesignator: "DCM", codeMeaning: "Unique Device Identifiers")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "11",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "74711-3", codingSchemeDesignator: "LN", codeMeaning: "Unique Device Identifier")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "12",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "120999", codingSchemeDesignator: "DCM", codeMeaning: "Device Description")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
