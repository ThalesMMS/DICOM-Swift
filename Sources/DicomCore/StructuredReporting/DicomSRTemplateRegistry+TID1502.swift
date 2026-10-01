import Foundation

// PS3.16, TID 1502: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1502 = DicomSRTemplateDefinition(identifier: "1502", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "126070", codingSchemeDesignator: "DCM", codeMeaning: "Subject Time Point Identifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "126071", codingSchemeDesignator: "DCM", codeMeaning: "Protocol Time Point Identifier")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "C2348792", codingSchemeDesignator: "UMLS", codeMeaning: "Time Point")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "126072", codingSchemeDesignator: "DCM", codeMeaning: "Time Point Type")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .contextGroup("6146")
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "126073", codingSchemeDesignator: "DCM", codeMeaning: "Time Point Order")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "1", codingSchemeDesignator: "UCUM", codeMeaning: "no units"))
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: "HAS OBS CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "128740", codingSchemeDesignator: "DCM", codeMeaning: "Longitudinal Temporal Offset from Event")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .definedTerms([.init(codeValue: "d", codingSchemeDesignator: "UCUM", codeMeaning: "days")])
        ),
        .init(
            id: "7",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "128741", codingSchemeDesignator: "DCM", codeMeaning: "Longitudinal Temporal Event Type")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .contextGroup("280")
        )
    ])
}
