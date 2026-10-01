import Foundation

// PS3.16, TID 4108: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid4108 = DicomSRTemplateDefinition(identifier: "4108", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "112039", codingSchemeDesignator: "DCM", codeMeaning: "Tracking Identifier")),
            vm: .one,
            requirement: .mandatoryConditional(.not(.ifRowsAnyPresent(["2"]))),
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "112040", codingSchemeDesignator: "DCM", codeMeaning: "Tracking Unique Identifier")),
            vm: .one,
            requirement: .mandatoryConditional(.not(.ifRowsAnyPresent(["1"]))),
            valueSet: .none
        )
    ])
}
