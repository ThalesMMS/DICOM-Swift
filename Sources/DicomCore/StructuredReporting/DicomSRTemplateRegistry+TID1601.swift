import Foundation

// PS3.16, TID 1601: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1601 = DicomSRTemplateDefinition(identifier: "1601", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("IMAGE"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.xor(["3", "5"])),
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 1,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1602"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("COMPOSITE"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.xor(["1", "5"])),
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 1,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1602"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("WAVEFORM"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.xor(["1", "3"])),
            valueSet: .none
        ),
        .init(
            id: "6",
            nestingLevel: 1,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1602"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
