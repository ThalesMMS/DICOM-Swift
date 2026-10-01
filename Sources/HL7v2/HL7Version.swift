import Foundation

/// Manual RawRepresentable/CaseIterable retain unknown version identifiers without losing them.
public enum HL7Version: RawRepresentable, CaseIterable, Equatable, Sendable {
    case v2_1, v2_2, v2_3, v2_3_1, v2_4, v2_5, v2_5_1, v2_6
    case v2_7, v2_7_1, v2_8, v2_8_1, v2_8_2, v2_9
    case unknown(String)

    public static let allCases: [Self] = [ .v2_1, .v2_2, .v2_3, .v2_3_1, .v2_4, .v2_5, .v2_5_1,
        .v2_6, .v2_7, .v2_7_1, .v2_8, .v2_8_1, .v2_8_2, .v2_9 ]
    public init(rawValue: String) {
        self = Self.allCases.first { $0.rawValue == rawValue } ?? .unknown(rawValue)
    }
    public var rawValue: String {
        switch self {
        case .v2_1: "2.1"
        case .v2_2: "2.2"
        case .v2_3: "2.3"
        case .v2_3_1: "2.3.1"
        case .v2_4: "2.4"
        case .v2_5: "2.5"
        case .v2_5_1: "2.5.1"
        case .v2_6: "2.6"
        case .v2_7: "2.7"
        case .v2_7_1: "2.7.1"
        case .v2_8: "2.8"
        case .v2_8_1: "2.8.1"
        case .v2_8_2: "2.8.2"
        case .v2_9: "2.9"
        case .unknown(let value): value
        }
    }
}
