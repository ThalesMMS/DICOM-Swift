import Foundation

/// PS3.3 C.17.2.4 identified-person/device attribute conditions.
enum DicomSRObserverMacro {
    static func rules(codeRules: [DicomAttributeRule]) -> [DicomAttributeRule] {
        let person = DicomAttributeRule.Condition.stringEquals(0x0040A084, "PSN")
        let device = DicomAttributeRule.Condition.stringEquals(0x0040A084, "DEV")
        return [
            .init(tag: 0x0040A084, requirement: .type1, constraints: [.strings(["PSN", "DEV"])]),
            .init(tag: 0x0040A123, requirement: .type1C, condition: person),
            .init(tag: 0x00401101, requirement: .type2C, condition: person,
                  itemRules: codeRules, constraints: [.itemCount(0...1)]),
            .init(tag: 0x0044010A, requirement: .type3, itemRules: codeRules),
            .init(tag: 0x00081010, requirement: .type2C, condition: device),
            .init(tag: 0x00181002, requirement: .type1C, condition: device),
            .init(tag: 0x00080070, requirement: .type1C, condition: device),
            .init(tag: 0x00081090, requirement: .type1C, condition: device),
            .init(tag: 0x00080080, requirement: .type2),
            .init(tag: 0x00080082, requirement: .type2, itemRules: codeRules, constraints: [.itemCount(0...1)]),
            .init(tag: 0x00081041, requirement: .type3, itemRules: codeRules, constraints: [.itemCount(1...1)])
        ]
    }
}
