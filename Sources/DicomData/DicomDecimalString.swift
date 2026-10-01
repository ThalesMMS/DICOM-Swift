import Foundation

/// Exact bounded DS/IS conversion shared by image calibration and plane validation.
package enum DicomDecimalString {
    package enum Failure: Error { case invalid, unavailable }

    package static func parse(_ string: String, vr: DicomVR = .DS) throws -> Decimal {
        guard string.utf8.count <= (vr == .IS ? 12 : 16) else { throw Failure.invalid }
        let text = string.trimmingCharacters(in: CharacterSet(charactersIn: " "))
        let pattern = vr == .IS ? #"\A[+-]?[0-9]+\z"# : #"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[Ee][+-]?[0-9]+)?\z"#
        guard text.range(of: pattern, options: .regularExpression) != nil else { throw Failure.invalid }
        let parts = text.split(whereSeparator: { $0 == "e" || $0 == "E" })
        guard var value = Decimal(string: String(parts[0]), locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
            throw Failure.unavailable
        }
        if parts.count == 2 && value != 0 {
            guard let exponent = Int16(parts[1]) else { throw Failure.unavailable }
            var scaled = Decimal()
            guard NSDecimalMultiplyByPowerOf10(&scaled, &value, exponent, .plain) == .noError else { throw Failure.unavailable }
            value = scaled
        }
        return value
    }
}
