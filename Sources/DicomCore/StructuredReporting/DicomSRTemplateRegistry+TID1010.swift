import Foundation

// PS3.16, TID 1010: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1010 = DicomSRTemplateDefinition(identifier: "1010", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121193", codingSchemeDesignator: "DCM", codeMeaning: "Device Subject Name")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "121198", codingSchemeDesignator: "DCM", codeMeaning: "Device Subject UID")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121194", codingSchemeDesignator: "DCM", codeMeaning: "Device Subject Manufacturer")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121195", codingSchemeDesignator: "DCM", codeMeaning: "Device Subject Model Name")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121196", codingSchemeDesignator: "DCM", codeMeaning: "Device Subject Serial Number")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121197", codingSchemeDesignator: "DCM", codeMeaning: "Device Subject Physical Location during observation")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
