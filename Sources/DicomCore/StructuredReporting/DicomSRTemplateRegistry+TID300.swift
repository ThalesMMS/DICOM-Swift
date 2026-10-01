import Foundation

// PS3.16, TID 300: table order and row labels retained.
extension DicomSRTemplateRegistry {
    static let tid300 = DicomSRTemplateDefinition(identifier: "300", isExtensible: true, rows: [
        .init(
            id: "1",
            nestingLevel: 0,
            relationship: nil,
            valueType: .value("NUM"),
            concept: .parameter("Measurement"),
            vm: .one,
            requirement: .mandatory,
            valueSet: .unitsParameter("Units")
        ),
        .init(
            id: "1b",
            nestingLevel: 1,
            relationship: nil,
            valueType: .include("301"),
            concept: .any,
            vm: .one,
            requirement: .mandatory,
            valueSet: .none,
            bindings: ["ModType": .parameter("ModType"), "ModValue": .parameter("ModValue"), "Method": .parameter("Method"), "Derivation": .parameter("Derivation"), "TargetSite": .parameter("TargetSite"), "TargetSiteLaterality": .parameter("TargetSiteLaterality"), "TargetSiteMod": .parameter("TargetSiteMod"), "Equation": .parameter("Equation"), "ImagePurpose": .parameter("ImagePurpose"), "WavePurpose": .parameter("WavePurpose"), "RefAuthority": .parameter("RefAuthority"), "RangeAuthority": .parameter("RangeAuthority"), "DerivationParameter": .parameter("DerivationParameter"), "DerivationParameterUnits": .parameter("DerivationParameterUnits"), "PrecoordinatedMeasurementMeaning": .parameter("PrecoordinatedMeasurementMeaning")]
        )
    ])
}
