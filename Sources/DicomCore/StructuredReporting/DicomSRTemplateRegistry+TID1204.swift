import Foundation

// PS3.16, TID 1204: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1204 = DicomSRTemplateDefinition(identifier: "1204", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121049", codingSchemeDesignator: "DCM", codeMeaning: "Language of Content Item and Descendants")),
            vm: .one,
            requirement: .mandatory,
            valueSet: .contextGroup("5000")
        ),
        .init(
            id: "2",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121046", codingSchemeDesignator: "DCM", codeMeaning: "Country of Language")),
            vm: .one,
            requirement: .userOptional,
            valueSet: .contextGroup("5001")
        )
    ])
}
