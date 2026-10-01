import Foundation

public enum DicomSRTemplateRegistry {
    public static let definitions: [String: DicomSRTemplateDefinition] = Dictionary(
        uniqueKeysWithValues: [
            tid300,
            tid320,
            tid1001,
            tid1002,
            tid1003,
            tid1004,
            tid1005,
            tid1006,
            tid1007,
            tid1008,
            tid1204,
            tid1410,
            tid1411,
            tid1420,
            tid1500,
            tid1501,
            tid1502,
            tid1600,
            tid1601,
            tid1602,
            tid2010,
            tid4019,
            tid301,
            tid310,
            tid1009,
            tid1010,
            tid1015,
            tid1419,
            tid1603,
            tid1604,
            tid1605,
            tid1606,
            tid4108
        ].map { ($0.identifier, $0) })

    public static func definition(for identifier: String) -> DicomSRTemplateDefinition? {
        definitions[identifier]
    }
}
