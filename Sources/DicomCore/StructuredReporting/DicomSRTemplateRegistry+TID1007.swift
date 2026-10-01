import Foundation

// PS3.16, TID 1007: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1007 = DicomSRTemplateDefinition(identifier: "1007", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "121028", codingSchemeDesignator: "DCM", codeMeaning: "Subject UID")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("PNAME"),
            concept: .enumerated(.init(codeValue: "121029", codingSchemeDesignator: "DCM", codeMeaning: "Subject Name")),
            vm: .one,
            requirement: .mandatoryConditional(.custom("Required if not inherited.")),
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121030", codingSchemeDesignator: "DCM", codeMeaning: "Subject ID")),
            vm: .one,
            requirement: .mandatoryConditional(.custom("Required if not inherited.")),
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("DATE"),
            concept: .enumerated(.init(codeValue: "121031", codingSchemeDesignator: "DCM", codeMeaning: "Subject Birth Date")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121032", codingSchemeDesignator: "DCM", codeMeaning: "Subject Sex")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("7455")
        ),
        .init(
            id: "5a",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "131233", codingSchemeDesignator: "DCM", codeMeaning: "Subject Sex Parameters for Clinical Use Category")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .contextGroup("7459")
        ),
        .init(
            id: "5b",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "131234", codingSchemeDesignator: "DCM", codeMeaning: "Subject Sex Parameters for Clinical Use Category Comment")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5c",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "131235", codingSchemeDesignator: "DCM", codeMeaning: "Subject Sex Parameters for Clinical Use Category Reference")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "121033", codingSchemeDesignator: "DCM", codeMeaning: "Subject Age")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("7456")
        ),
        .init(
            id: "7",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121034", codingSchemeDesignator: "DCM", codeMeaning: "Subject Species")),
            vm: .one,
            requirement: .mandatoryConditional(.custom("Required if not inherited.")),
            valueSet: .contextGroup("7454")
        ),
        .init(
            id: "8",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121035", codingSchemeDesignator: "DCM", codeMeaning: "Subject Breed")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("7480")
        ),
        .init(
            id: "9",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "415229000", codingSchemeDesignator: "SCT", codeMeaning: "Racial group")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .contextGroup("6099")
        )
    ])
}
