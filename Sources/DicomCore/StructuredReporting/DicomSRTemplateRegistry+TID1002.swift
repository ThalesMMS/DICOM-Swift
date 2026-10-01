import Foundation

// PS3.16, TID 1002: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1002 = DicomSRTemplateDefinition(identifier: "1002", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121005", codingSchemeDesignator: "DCM", codeMeaning: "Observer Type")),
            vm: .one,
            requirement: .mandatoryConditional(.ifRowValue("1", .init(codeValue: "121007", codingSchemeDesignator: "DCM", codeMeaning: "Device"))),
            valueSet: .contextGroup("270")
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .include("1003"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.any([.ifRowValue("1", .init(codeValue: "121006", codingSchemeDesignator: "DCM", codeMeaning: "Person")), .ifRowAbsent("1")])),
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .include("1004"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.ifRowValue("1", .init(codeValue: "121007", codingSchemeDesignator: "DCM", codeMeaning: "Device"))),
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .include("1015"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
