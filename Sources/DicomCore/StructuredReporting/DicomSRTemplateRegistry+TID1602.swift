import Foundation

// PS3.16, TID 1602: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1602 = DicomSRTemplateDefinition(identifier: "1602", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121139", codingSchemeDesignator: "DCM", codeMeaning: "Modality")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("33")
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "123014", codingSchemeDesignator: "DCM", codeMeaning: "Target Region")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("4031")
        ),
        .init(
            id: "2b",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "123014", codingSchemeDesignator: "DCM", codeMeaning: "Target Region")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "111027", codingSchemeDesignator: "DCM", codeMeaning: "Image Laterality")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("244")
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("DATE"),
            concept: .enumerated(.init(codeValue: "111060", codingSchemeDesignator: "DCM", codeMeaning: "Study Date")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TIME"),
            concept: .enumerated(.init(codeValue: "111061", codingSchemeDesignator: "DCM", codeMeaning: "Study Time")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5a",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "112002", codingSchemeDesignator: "DCM", codeMeaning: "Series Instance UID")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5b",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "113607", codingSchemeDesignator: "DCM", codeMeaning: "Series Number")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5c",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "131563", codingSchemeDesignator: "DCM", codeMeaning: "Series Description")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5d",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "131563", codingSchemeDesignator: "DCM", codeMeaning: "Series Description")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5e",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("DATE"),
            concept: .enumerated(.init(codeValue: "131561", codingSchemeDesignator: "DCM", codeMeaning: "Series Date")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5f",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TIME"),
            concept: .enumerated(.init(codeValue: "131562", codingSchemeDesignator: "DCM", codeMeaning: "Series Time")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "5g",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "131564", codingSchemeDesignator: "DCM", codeMeaning: "Number of Series Related Instances")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{instances}", codingSchemeDesignator: "UCUM", codeMeaning: "instances"))
        ),
        .init(
            id: "6",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("DATE"),
            concept: .enumerated(.init(codeValue: "111018", codingSchemeDesignator: "DCM", codeMeaning: "Content Date")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "7",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TIME"),
            concept: .enumerated(.init(codeValue: "111019", codingSchemeDesignator: "DCM", codeMeaning: "Content Time")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "8",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("DATE"),
            concept: .enumerated(.init(codeValue: "126201", codingSchemeDesignator: "DCM", codeMeaning: "Acquisition Date")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "9",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TIME"),
            concept: .enumerated(.init(codeValue: "126202", codingSchemeDesignator: "DCM", codeMeaning: "Acquisition Time")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "10",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("UIDREF"),
            concept: .enumerated(.init(codeValue: "112227", codingSchemeDesignator: "DCM", codeMeaning: "Frame of Reference UID")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "11",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110910", codingSchemeDesignator: "DCM", codeMeaning: "Pixel Data Rows")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{pixels}", codingSchemeDesignator: "UCUM", codeMeaning: "pixels"))
        ),
        .init(
            id: "12",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "110911", codingSchemeDesignator: "DCM", codeMeaning: "Pixel Data Columns")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{pixels}", codingSchemeDesignator: "UCUM", codeMeaning: "pixels"))
        ),
        .init(
            id: "12a",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("TEXT"),
            concept: .enumerated(.init(codeValue: "113609", codingSchemeDesignator: "DCM", codeMeaning: "Instance Number")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "12b",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "121140", codingSchemeDesignator: "DCM", codeMeaning: "Number of Frames")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .units(.init(codeValue: "{frames}", codingSchemeDesignator: "UCUM", codeMeaning: "frames"))
        ),
        .init(
            id: "13",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1603"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.any([.ifRowValue("1", .init(codeValue: "CR", codingSchemeDesignator: "DCM", codeMeaning: "CR")), .ifRowValue("1", .init(codeValue: "DX", codingSchemeDesignator: "DCM", codeMeaning: "DX")), .ifRowValue("1", .init(codeValue: "IO", codingSchemeDesignator: "DCM", codeMeaning: "IO")), .ifRowValue("1", .init(codeValue: "MG", codingSchemeDesignator: "DCM", codeMeaning: "MG")), .ifRowValue("1", .init(codeValue: "PX", codingSchemeDesignator: "DCM", codeMeaning: "PX")), .ifRowValue("1", .init(codeValue: "RF", codingSchemeDesignator: "DCM", codeMeaning: "RF")), .ifRowValue("1", .init(codeValue: "RG", codingSchemeDesignator: "DCM", codeMeaning: "RG")), .ifRowValue("1", .init(codeValue: "XA", codingSchemeDesignator: "DCM", codeMeaning: "XA"))])),
            valueSet: .none
        ),
        .init(
            id: "14",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1604"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.any([.ifRowValue("1", .init(codeValue: "CT", codingSchemeDesignator: "DCM", codeMeaning: "CT")), .ifRowValue("1", .init(codeValue: "MR", codingSchemeDesignator: "DCM", codeMeaning: "MR")), .ifRowValue("1", .init(codeValue: "PT", codingSchemeDesignator: "DCM", codeMeaning: "PT"))])),
            valueSet: .none
        ),
        .init(
            id: "15",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1605"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.any([.ifRowValue("1", .init(codeValue: "CT", codingSchemeDesignator: "DCM", codeMeaning: "CT"))])),
            valueSet: .none
        ),
        .init(
            id: "16",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1606"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.any([.ifRowValue("1", .init(codeValue: "MR", codingSchemeDesignator: "DCM", codeMeaning: "MR"))])),
            valueSet: .none
        ),
        .init(
            id: "17",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1607"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.any([.ifRowValue("1", .init(codeValue: "PT", codingSchemeDesignator: "DCM", codeMeaning: "PT"))])),
            valueSet: .none
        ),
        .init(
            id: "18",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .include("1609"),
            concept: .any,
            vm: .one,
            requirement: .mandatoryConditional(.any([.ifRowValue("1", .init(codeValue: "KO", codingSchemeDesignator: "DCM", codeMeaning: "KO"))])),
            valueSet: .none
        )
    ])
}
