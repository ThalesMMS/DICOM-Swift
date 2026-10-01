import Foundation

// PS3.16, TID 1015: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1015 = DicomSRTemplateDefinition(identifier: "1015", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "128003", codingSchemeDesignator: "DCM", codeMeaning: "Reader Specialty")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .contextGroup("7449")
        ),
        .init(
            id: "2",
            nestingLevel: 1,
            relationship: "HAS PROPERTIES",
            valueType: .value("NUM"),
            concept: .enumerated(.init(codeValue: "C54627", codingSchemeDesignator: "NCIt", codeMeaning: "Experience")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .units(.init(codeValue: "a", codingSchemeDesignator: "UCUM", codeMeaning: "Year"))
        )
    ])
}
