import Foundation

/// Validates lexical dates/times, including precision and UTC suffixes. It does
/// not perform query matching, timezone negotiation or leap-second scheduling.
package enum DicomTemporalValueValidator {
    package static func valid(_ value: String, vr: DicomVR, query: Bool) -> Bool {
        var text = value
        while text.last == " " { text.removeLast() }
        let maximum = vr == .DA ? 8 : (vr == .TM ? 14 : 26)
        guard text.utf8.count <= (query ? 2 * maximum + 1 : maximum) else { return false }
        if validSingle(text, vr: vr) { return true }
        guard query else { return false }
        // A minus sign may be a DT timezone suffix, so test complete endpoints
        // instead of splitting every sign or silently discarding an offset.
        for delimiter in text.indices where text[delimiter] == "-" {
            let first = String(text[..<delimiter])
            let second = String(text[text.index(after: delimiter)...])
            if (!first.isEmpty || !second.isEmpty),
               (first.isEmpty || validSingle(first, vr: vr)),
               (second.isEmpty || validSingle(second, vr: vr)) { return true }
        }
        return false
    }

    private static func validSingle(_ value: String, vr: DicomVR) -> Bool {
        var bytes = Array(value.utf8)
        if vr == .DA { return bytes.count == 8 && validDate(bytes) }
        if vr == .DT, bytes.count >= 5 {
            let suffix = bytes.count - 5
            if bytes[suffix] == 0x2B || bytes[suffix] == 0x2D {
                guard let hours = number(bytes, suffix + 1, 2), let minutes = number(bytes, suffix + 3, 2),
                      minutes <= 59 else { return false }
                let offset = hours * 60 + minutes
                guard bytes[suffix] == 0x2B ? offset <= 14 * 60 : (offset > 0 && offset <= 12 * 60) else { return false }
                bytes.removeLast(5)
            }
        }
        let fractionStart = bytes.firstIndex(of: 0x2E)
        if let fractionStart {
            let expected = vr == .TM ? 6 : 14
            guard fractionStart == expected, (1...6).contains(bytes.count - fractionStart - 1),
                  number(bytes, fractionStart + 1, bytes.count - fractionStart - 1) != nil else { return false }
            bytes.removeSubrange(fractionStart...)
        }
        if vr == .TM { return validTime(bytes) }
        guard [4, 6, 8, 10, 12, 14].contains(bytes.count), validDate(Array(bytes.prefix(8))) else { return false }
        return bytes.count <= 8 || validTime(Array(bytes.dropFirst(8)))
    }

    private static func validDate(_ bytes: [UInt8]) -> Bool {
        guard [4, 6, 8].contains(bytes.count), let year = number(bytes, 0, 4), year > 0 else { return false }
        if bytes.count == 4 { return true }
        guard let month = number(bytes, 4, 2), (1...12).contains(month) else { return false }
        if bytes.count == 6 { return true }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard let day = number(bytes, 6, 2) else { return false }
        return (1...days[month - 1]).contains(day)
    }

    private static func validTime(_ bytes: [UInt8]) -> Bool {
        guard [2, 4, 6].contains(bytes.count), let hour = number(bytes, 0, 2), hour <= 23 else { return false }
        if bytes.count == 2 { return true }
        guard let minute = number(bytes, 2, 2), minute <= 59 else { return false }
        if bytes.count == 4 { return true }
        guard let second = number(bytes, 4, 2) else { return false }
        return second <= 60
    }

    private static func number(_ bytes: [UInt8], _ start: Int, _ count: Int) -> Int? {
        guard start >= 0, count > 0, start <= bytes.count, count <= bytes.count - start else { return nil }
        var result = 0
        for byte in bytes[start..<(start + count)] {
            guard (0x30...0x39).contains(byte) else { return nil }
            result = result * 10 + Int(byte - 0x30)
        }
        return result
    }
}
