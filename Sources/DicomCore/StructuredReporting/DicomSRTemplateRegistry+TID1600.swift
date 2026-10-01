import Foundation

// PS3.16, TID 1600: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1600 = DicomSRTemplateDefinition(identifier: "1600", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CONTAINER"),
            concept: .enumerated(.init(codeValue: "111028", codingSchemeDesignator: "DCM", codeMeaning: "Image Library")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "1b",
            nestingLevel: 1,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121139", codingSchemeDesignator: "DCM", codeMeaning: "Modality")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .contextGroup("33")
        ),
        .init(
            id: "1c",
            nestingLevel: 1,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "110181", codingSchemeDesignator: "DCM", codeMeaning: "SOP Class UID")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "1d",
            nestingLevel: 1,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "123014", codingSchemeDesignator: "DCM", codeMeaning: "Target Region")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .contextGroup("4031")
        ),
        .init(
            id: "1e",
            nestingLevel: 1,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "123014", codingSchemeDesignator: "DCM", codeMeaning: "Target Region")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "1f",
            nestingLevel: 1,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "131565", codingSchemeDesignator: "DCM", codeMeaning: "Number of Study Related Series")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{series}", codingSchemeDesignator: "UCUM", codeMeaning: "series"))
        ),
        .init(
            id: "2",
            nestingLevel: 1,
            relationship: "CONTAINS",
            valueType: .value("CONTAINER"),
            concept: .enumerated(.init(codeValue: "126200", codingSchemeDesignator: "DCM", codeMeaning: "Image Library Group")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 2,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1602"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 2,
            relationship: "CONTAINS",
            valueType: .include("1601"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
