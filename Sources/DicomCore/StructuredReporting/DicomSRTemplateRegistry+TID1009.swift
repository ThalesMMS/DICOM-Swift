import Foundation

// PS3.16, TID 1009: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1009 = DicomSRTemplateDefinition(identifier: "1009", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "121039", codingSchemeDesignator: "DCM", codeMeaning: "Specimen UID")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .include("1007"),
            concept: .any,
            vm: .one,
            requirement: .userConditional(.custom("IFF the source of the specimen is a human or animal patient")),
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "121041", codingSchemeDesignator: "DCM", codeMeaning: "Specimen Identifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "111724", codingSchemeDesignator: "DCM", codeMeaning: "Issuer of Specimen Identifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "371439000", codingSchemeDesignator: "SCT", codeMeaning: "Specimen Type")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("8103")
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "111700", codingSchemeDesignator: "DCM", codeMeaning: "Specimen Container Identifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
