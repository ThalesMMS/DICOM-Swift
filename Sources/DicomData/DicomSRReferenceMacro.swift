import Foundation

/// Included attribute rules for PS3.3 Tables C.17-3/3a/3c and 10-11/17.
/// Identity resolution, URI semantics and MAC/signature verification are not attribute checks.
enum DicomSRReferenceMacro {
    static func uid(_ dataSet: DicomDataSet, tag: Int) -> String? {
        guard let element = dataSet[tag], element.vr == .UI, case .strings(let values) = element.value,
              values.count == 1, values[0].utf8.count <= 64 else { return nil }
        let value = values[0]
        guard !value.isEmpty else { return nil }
        do {
            try DicomTextValueValidator.validate(value, vr: .UI, characterSet: .defaultCharacterSet,
                                                purpose: .instance, includesPadding: false)
        } catch { return nil }
        return value
    }

    static let sopRules: [DicomAttributeRule] = [
        .init(tag: 0x00081150, requirement: .type1), .init(tag: 0x00081155, requirement: .type1)
    ]

    static func hierarchicalRules(codeRules: [DicomAttributeRule]) -> [DicomAttributeRule] {
        let reference = sopRules + [
            .init(tag: 0x0040A170, requirement: .type3, itemRules: codeRules),
            .init(tag: 0x04000402, requirement: .type3, itemRules: [
                .init(tag: 0x04000100, requirement: .type1), .init(tag: 0x04000120, requirement: .type1)
            ]),
            .init(tag: 0x04000403, requirement: .type3, itemRules: [
                .init(tag: 0x04000010, requirement: .type1), .init(tag: 0x04000015, requirement: .type1),
                .init(tag: 0x04000020, requirement: .type1), .init(tag: 0x04000404, requirement: .type1)
            ], constraints: [.itemCount(1...1)])
        ]
        return [
            .init(tag: 0x0020000D, requirement: .type1),
            .init(tag: 0x00081115, requirement: .type1, itemRules: [
                .init(tag: 0x0020000E, requirement: .type1),
                .init(tag: 0x00081199, requirement: .type1, itemRules: reference)
            ])
        ]
    }

    static func requestRules(codeRules: [DicomAttributeRule]) -> [DicomAttributeRule] {
        let issuer: [DicomAttributeRule] = [
            .init(tag: 0x00400031, requirement: .type1C, condition: .not(.present(0x00400032)), mayBePresentOtherwise: true),
            .init(tag: 0x00400032, requirement: .type1C, condition: .not(.present(0x00400031)), mayBePresentOtherwise: true),
            .init(tag: 0x00400033, requirement: .type1C, condition: .present(0x00400032),
                  constraints: [.strings(["DNS", "EUI64", "ISO", "URI", "UUID", "X400", "X500"])])
        ]
        return [
            .init(tag: 0x0020000D, requirement: .type1),
            .init(tag: 0x00081110, requirement: .type2, itemRules: sopRules, constraints: [.itemCount(0...1)]),
            .init(tag: 0x00080050, requirement: .type2),
            .init(tag: 0x00402016, requirement: .type2), .init(tag: 0x00402017, requirement: .type2),
            .init(tag: 0x00401001, requirement: .type2), .init(tag: 0x00321060, requirement: .type2),
            .init(tag: 0x00321064, requirement: .type2, itemRules: codeRules, constraints: [.itemCount(0...1)]),
            .init(tag: 0x0040100A, requirement: .type3, itemRules: codeRules)
        ] + [0x00080051, 0x00400026, 0x00400027].map {
            .init(tag: $0, requirement: .type3, itemRules: issuer, constraints: [.itemCount(1...1)])
        }
    }
}
