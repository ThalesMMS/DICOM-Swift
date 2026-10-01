import Foundation

// PS3.16, TID 1603: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1603 = DicomSRTemplateDefinition(identifier: "1603", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "111031", codingSchemeDesignator: "DCM", codeMeaning: "Image View")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "111032", codingSchemeDesignator: "DCM", codeMeaning: "Image View Modifier")),
            vm: .oneOrMore,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "111044", codingSchemeDesignator: "DCM", codeMeaning: "Patient Orientation Row")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "111043", codingSchemeDesignator: "DCM", codeMeaning: "Patient Orientation Column")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "111026", codingSchemeDesignator: "DCM", codeMeaning: "Horizontal Pixel Spacing")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"))
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "111066", codingSchemeDesignator: "DCM", codeMeaning: "Vertical Pixel Spacing")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"))
        ),
        .init(
            id: "7",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "112011", codingSchemeDesignator: "DCM", codeMeaning: "Positioner Primary Angle")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "deg", codingSchemeDesignator: "UCUM", codeMeaning: "deg"))
        ),
        .init(
            id: "8",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "112012", codingSchemeDesignator: "DCM", codeMeaning: "Positioner Secondary Angle")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "deg", codingSchemeDesignator: "UCUM", codeMeaning: "deg"))
        )
    ])
}
