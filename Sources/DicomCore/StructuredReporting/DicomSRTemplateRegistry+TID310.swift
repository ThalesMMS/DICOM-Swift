import Foundation

// PS3.16, TID 310: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid310 = DicomSRTemplateDefinition(identifier: "310", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121402", codingSchemeDesignator: "DCM", codeMeaning: "Normality")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("222")
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .include("311"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["RefAuthority": .parameter("RefAuthority")]
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .include("312"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["RangeAuthority": .parameter("RangeAuthority")]
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121403", codingSchemeDesignator: "DCM", codeMeaning: "Level of Significance")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("220")
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("NUM"),
            concept: .contextGroup("225"),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121404", codingSchemeDesignator: "DCM", codeMeaning: "Selection Status")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("224")
        )
    ])
}
