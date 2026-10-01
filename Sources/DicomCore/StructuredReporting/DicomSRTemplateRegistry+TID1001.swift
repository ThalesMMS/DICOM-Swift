import Foundation

// PS3.16, TID 1001: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1001 = DicomSRTemplateDefinition(identifier: "1001", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .include("1002"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .mandatoryConditional(.custom("Required if all aspects of observer context are not inherited.")),
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .include("1005"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.custom("Required if all aspects of procedure context are not inherited.")),
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .include("1006"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.custom("Required if all aspects of observation subject context are not inherited.")),
            valueSet: .none
        )
    ])
}
