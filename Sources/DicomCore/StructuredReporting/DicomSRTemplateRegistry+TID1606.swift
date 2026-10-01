import Foundation

// PS3.16, TID 1606: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1606 = DicomSRTemplateDefinition(identifier: "1606", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "128230", codingSchemeDesignator: "DCM", codeMeaning: "Pulse Sequence Name")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "130542", codingSchemeDesignator: "DCM", codeMeaning: "Magnetic field strength")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "T", codingSchemeDesignator: "UCUM", codeMeaning: "Tesla"))
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "RID10813", codingSchemeDesignator: "RADLEX", codeMeaning: "MR coil")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .contextGroup("6349")
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110852", codingSchemeDesignator: "DCM", codeMeaning: "MR signal intensity")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("6311")
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "130546", codingSchemeDesignator: "DCM", codeMeaning: "Cross-sectional scan plane orientation")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("6312")
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "113240", codingSchemeDesignator: "DCM", codeMeaning: "Source image diffusion b-value")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "s/mm2", codingSchemeDesignator: "UCUM", codeMeaning: "s/mm2"))
        ),
        .init(
            id: "7",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1608"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        )
    ])
}
