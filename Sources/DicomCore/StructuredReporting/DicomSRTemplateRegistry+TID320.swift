import Foundation

// PS3.16, TID 320: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid320 = DicomSRTemplateDefinition(identifier: "320", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "INFERRED FROM",
            valueType: .value("IMAGE"),
            concept: .parameter("Purpose"),
            vm: .one,
            requirement: .mandatoryConditional(.xor(["2", "3", "6"])),
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: "R-INFERRED FROM",
            valueType: .value("IMAGE"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.xor(["1", "3", "6"])),
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: "INFERRED FROM",
            valueType: .value("SCOORD"),
            concept: .parameter("Purpose"),
            vm: .one,
            requirement: .mandatoryConditional(.xor(["1", "2", "6"])),
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 1,
            relationship: "SELECTED FROM",
            valueType: .value("IMAGE"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.xor(["5"])),
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 1,
            relationship: "R-SELECTED FROM",
            valueType: .value("IMAGE"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.xor(["4"])),
            valueSet: .none
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: "INFERRED FROM",
            valueType: .value("SCOORD3D"),
            concept: .parameter("Purpose"),
            vm: .one,
            requirement: .mandatoryConditional(.xor(["1", "2", "3"])),
            valueSet: .none
        )
    ])
}
