/// PS3.3 Table 10-1 required fields and code structure. Person identity, code
/// meaning (including optional PN encoding) and terminology remain unqualified.
public enum DicomPersonIdentificationMacro {
    public static func rules() -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.rules()
        return [
            .init(tag: 0x00401101, requirement: .type1, itemRules: codes,
                  constraints: [.itemCount(1...Int.max), .requiredCondition(.undetermined)]),
            .init(tag: 0x00080080, requirement: .type1C, condition: .not(.present(0x00080082)), mayBePresentOtherwise: true),
            .init(tag: 0x00080082, requirement: .type1C, condition: .not(.present(0x00080080)), mayBePresentOtherwise: true,
                  itemRules: codes, constraints: [.itemCount(1...1), .requiredCondition(.undetermined)]),
            .init(tag: 0x00081041, requirement: .type3, itemRules: codes,
                  constraints: [.itemCount(1...1), .requiredCondition(.undetermined)])
        ]
    }
}
