import Foundation

// PS3.16, TID 1605: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1605 = DicomSRTemplateDefinition(identifier: "1605", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "113820", codingSchemeDesignator: "DCM", codeMeaning: "CT Acquisition Type")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("10013")
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: "HAS ACQ CONTEXT",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "113961", codingSchemeDesignator: "DCM", codeMeaning: "Reconstruction Algorithm")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("10033")
        )
    ])
}
