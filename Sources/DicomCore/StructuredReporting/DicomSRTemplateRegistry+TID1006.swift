import Foundation

// PS3.16, TID 1006: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1006 = DicomSRTemplateDefinition(identifier: "1006", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("CODE"),
            concept: .enumerated(.init(codeValue: "121024", codingSchemeDesignator: "DCM", codeMeaning: "Subject Class")),
            vm: .one,
            requirement: .mandatoryConditional(.not(.any([.ifRowAbsent("1"), .ifRowValue("1", .init(codeValue: "121025", codingSchemeDesignator: "DCM", codeMeaning: "Patient"))]))),
            valueSet: .contextGroup("271")
        ),
        .init(
            id: "2",
            nestingLevel: 0,
            relationship: nil,
            valueType: .include("1007"),
            concept: .any,
            vm: .one,
            requirement: .userConditional(.any([.ifRowValue("1", .init(codeValue: "121025", codingSchemeDesignator: "DCM", codeMeaning: "Patient")), .ifRowAbsent("1")])),
            valueSet: .none
        ),
        .init(
            id: "3",
            nestingLevel: 0,
            relationship: nil,
            valueType: .include("1008"),
            concept: .any,
            vm: .one,
            requirement: .userConditional(.ifRowValue("1", .init(codeValue: "121026", codingSchemeDesignator: "DCM", codeMeaning: "Fetus"))),
            valueSet: .none
        ),
        .init(
            id: "4",
            nestingLevel: 0,
            relationship: nil,
            valueType: .include("1009"),
            concept: .any,
            vm: .one,
            requirement: .userConditional(.ifRowValue("1", .init(codeValue: "121027", codingSchemeDesignator: "DCM", codeMeaning: "Specimen"))),
            valueSet: .none
        ),
        .init(
            id: "5",
            nestingLevel: 0,
            relationship: nil,
            valueType: .include("1010"),
            concept: .any,
            vm: .one,
            requirement: .userConditional(.ifRowValue("1", .init(codeValue: "121192", codingSchemeDesignator: "DCM", codeMeaning: "Device Subject"))),
            valueSet: .none
        )
    ])
}
