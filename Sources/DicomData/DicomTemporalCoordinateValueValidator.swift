import Foundation

/// Value count follows the temporal extent in C.18.7.1.1; this does not infer acquisition times or target sample counts.
enum DicomTemporalCoordinateValueValidator {
    static func validate(_ element: DicomDataElement, dataSet: DicomDataSet)
        -> (code: DicomValidationReport.Code, severity: DicomValidationReport.Severity)? {
        guard let range = dataSet[0x0040A130], range.vr == .CS, case .strings(let types) = range.value,
              types.count == 1, types[0].utf8.count <= 16 else { return (.valueUnavailable, .limitation) }
        let count = element.vm.count
        let validCount: Bool
        switch types[0].trimmingCharacters(in: CharacterSet(charactersIn: " ")) {
        case "POINT", "BEGIN", "END": validCount = count == 1
        case "SEGMENT": validCount = count == 2
        case "MULTIPOINT": validCount = count >= 2
        case "MULTISEGMENT": validCount = count >= 4 && count.isMultiple(of: 2)
        default: return (.valueUnavailable, .limitation)
        }
        guard validCount else { return (.invalidMultiplicity, .error) }
        switch element.tag {
        case 0x0040A132:
            guard element.vr == .UL, case .unsignedIntegers(let values) = element.value else { return (.valueUnavailable, .limitation) }
            return values.allSatisfy { $0 >= 1 && $0 <= UInt32.max } ? nil : (.attributeValueNotAllowed, .error)
        case 0x0040A138:
            guard element.vr == .DS, case .strings(let values) = element.value else { return (.valueUnavailable, .limitation) }
            for value in values {
                guard value.utf8.count <= 16,
                      let number = Double(value.trimmingCharacters(in: CharacterSet(charactersIn: " "))), number.isFinite else {
                    return (.attributeValueNotAllowed, .error)
                }
            }
            return nil // Signed offsets are preserved; no additional acquisition-bound assumption is made here.
        case 0x0040A13A:
            guard element.vr == .DT, case .strings(let values) = element.value else { return (.valueUnavailable, .limitation) }
            return values.allSatisfy { $0.utf8.count <= 26 && DicomTemporalValueValidator.valid($0, vr: .DT, query: false) } ?
                nil : (.attributeValueNotAllowed, .error)
        default: return (.valueUnavailable, .limitation)
        }
    }
}
