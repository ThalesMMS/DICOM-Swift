import Foundation

// PS3.16, TID 1604: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1604 = DicomSRTemplateDefinition(identifier: "1604", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "111026", codingSchemeDesignator: "DCM", codeMeaning: "Horizontal Pixel Spacing")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"))
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "111066", codingSchemeDesignator: "DCM", codeMeaning: "Vertical Pixel Spacing")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"))
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "112226", codingSchemeDesignator: "DCM", codeMeaning: "Spacing between slices")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"))
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "112225", codingSchemeDesignator: "DCM", codeMeaning: "Slice Thickness")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"))
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110901", codingSchemeDesignator: "DCM", codeMeaning: "Image Position (Patient) X")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"))
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110902", codingSchemeDesignator: "DCM", codeMeaning: "Image Position (Patient) Y")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"))
        ),
        .init(
            id: "7",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110903", codingSchemeDesignator: "DCM", codeMeaning: "Image Position (Patient) Z")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"))
        ),
        .init(
            id: "8",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110904", codingSchemeDesignator: "DCM", codeMeaning: "Image Orientation (Patient) Row X")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{-1:1}", codingSchemeDesignator: "UCUM", codeMeaning: "{-1:1}"))
        ),
        .init(
            id: "9",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110905", codingSchemeDesignator: "DCM", codeMeaning: "Image Orientation (Patient) Row Y")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{-1:1}", codingSchemeDesignator: "UCUM", codeMeaning: "{-1:1}"))
        ),
        .init(
            id: "10",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110906", codingSchemeDesignator: "DCM", codeMeaning: "Image Orientation (Patient) Row Z")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{-1:1}", codingSchemeDesignator: "UCUM", codeMeaning: "{-1:1}"))
        ),
        .init(
            id: "11",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110907", codingSchemeDesignator: "DCM", codeMeaning: "Image Orientation (Patient) Column X")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{-1:1}", codingSchemeDesignator: "UCUM", codeMeaning: "{-1:1}"))
        ),
        .init(
            id: "12",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110908", codingSchemeDesignator: "DCM", codeMeaning: "Image Orientation (Patient) Column Y")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{-1:1}", codingSchemeDesignator: "UCUM", codeMeaning: "{-1:1}"))
        ),
        .init(
            id: "13",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110909", codingSchemeDesignator: "DCM", codeMeaning: "Image Orientation (Patient) Column Z")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{-1:1}", codingSchemeDesignator: "UCUM", codeMeaning: "{-1:1}"))
        )
    ])
}
