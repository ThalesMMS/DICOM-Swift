import Foundation

// PS3.16, TID 1420: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid1420 = DicomSRTemplateDefinition(identifier: "1420", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("NUM"),
            concept: .contextGroup("7465"),
            vm: .oneOrMore,
            requirement: .mandatory,
            valueSet: .none
        ),
        .init(
            id: "1b",
            nestingLevel: 1,
            relationship: "HAS CONCEPT MOD",
            valueType: .include("4019"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none
        ),
        .init(
            id: "2",
            nestingLevel: 1,
            relationship: "R-INFERRED FROM",
            valueType: .include("1410"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .mandatoryConditional(.xor(["3"])),
            valueSet: .none,
            bindings: ["Measurement": .parameter("Measurement"), "Units": .parameter("MeasurementUnits"), "ModType": .parameter("ModType"), "ModValue": .parameter("ModValue"), "Method": .parameter("Method"), "Derivation": .parameter("Derivation"), "TargetSite": .parameter("TargetSite"), "TargetSiteMod": .parameter("TargetSiteMod"), "Equation": .parameter("Equation"), "RefAuthority": .parameter("RefAuthority"), "RangeAuthority": .parameter("RangeAuthority"), "DerivationParameter": .parameter("DerivationParameter"), "DerivationParameterUnits": .parameter("DerivationParameterUnits")]
        ),
        .init(
            id: "3",
            nestingLevel: 1,
            relationship: "R-INFERRED FROM",
            valueType: .include("1411"),
            concept: .any,
            vm: .oneOrMore,
            requirement: .mandatoryConditional(.xor(["2"])),
            valueSet: .none,
            bindings: ["Measurement": .parameter("Measurement"), "Units": .parameter("MeasurementUnits"), "ModType": .parameter("ModType"), "ModValue": .parameter("ModValue"), "Method": .parameter("Method"), "Derivation": .parameter("Derivation"), "TargetSite": .parameter("TargetSite"), "TargetSiteMod": .parameter("TargetSiteMod"), "Equation": .parameter("Equation"), "RefAuthority": .parameter("RefAuthority"), "RangeAuthority": .parameter("RangeAuthority"), "DerivationParameter": .parameter("DerivationParameter"), "DerivationParameterUnits": .parameter("DerivationParameterUnits")]
        ),
        .init(
            id: "4",
            nestingLevel: 1,
            relationship: "HAS PROPERTIES",
            valueType: .include("310"),
            concept: .any,
            vm: .one,
            requirement: .userOptional,
            valueSet: .none,
            bindings: ["RefAuthority": .parameter("RefAuthority"), "RangeAuthority": .parameter("RangeAuthority")]
        )
    ])
}
