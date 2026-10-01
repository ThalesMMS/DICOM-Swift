import Foundation

// PS3.16, TID 1008: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1008 = DicomSRTemplateDefinition(identifier: "1008", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("PNAME"),
            concept: .enumerated(.init(codeValue: "121036", codingSchemeDesignator: "DCM", codeMeaning: "Mother of fetus")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "121028", codingSchemeDesignator: "DCM", codeMeaning: "Subject UID")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121030", codingSchemeDesignator: "DCM", codeMeaning: "Subject ID")),
            vm: .one,
            requirement: .mandatoryConditional(.all([.ifRowAbsent("4")])),
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "11951-1", codingSchemeDesignator: "LN", codeMeaning: "Fetus ID")),
            vm: .one,
            requirement: .mandatoryConditional(.all([.ifRowAbsent("3")])),
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "11878-6", codingSchemeDesignator: "LN", codeMeaning: "Number of Fetuses by US")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "1", codingSchemeDesignator: "UCUM", codeMeaning: "no units"))
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "55281-0", codingSchemeDesignator: "LN", codeMeaning: "Number of Fetuses")),
            vm: .one,
            requirement: .userConditional(.xor(["5"])),
            valueSet: .units(.init(codeValue: "1", codingSchemeDesignator: "UCUM", codeMeaning: "no units"))
        )
    ])
}
