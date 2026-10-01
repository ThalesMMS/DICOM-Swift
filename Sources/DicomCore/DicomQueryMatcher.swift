import Foundation

/// Pure PS3.4 C.2.2 matching. PN is literal and case-sensitive; DS/IS compare numerically.
/// Key classification belongs to the information-model backend, not to a storage policy here.
public struct DicomQueryMatcher: Sendable {
    public var requiredKeys: Set<Int>
    public var emptyValueMatching: Bool
    public var multipleValueMatching: Bool
    public var dateTimeMatching: Bool

    public init(requiredKeys: Set<Int> = [], emptyValueMatching: Bool = false,
                multipleValueMatching: Bool = false, dateTimeMatching: Bool = false) {
        self.requiredKeys = requiredKeys
        self.emptyValueMatching = emptyValueMatching
        self.multipleValueMatching = multipleValueMatching
        self.dateTimeMatching = dateTimeMatching
    }

    public func matches(_ candidate: DicomDataSet, identifier: DicomDataSet) throws -> Bool {
        var combined: Set<Int> = []
        if dateTimeMatching {
            for (date, time) in [(0x00080020, 0x00080030), (0x00080021, 0x00080031),
                                 (0x00080022, 0x00080032), (0x00080023, 0x00080033)] {
                guard let da = identifier[date]?.stringValue, let tm = identifier[time]?.stringValue,
                      da.contains("-"), tm.contains("-") else { continue }
                let dates = da.components(separatedBy: "-")
                let times = tm.components(separatedBy: "-")
                guard dates.count == 2, times.count == 2,
                      zip(dates, times).allSatisfy({ $0.isEmpty == $1.isEmpty }) else { throw invalidKey() }
                let query = zip(dates, times).map { $0 + $1 }.joined(separator: "-")
                let value = (candidate.string(for: date) ?? "") + (candidate.string(for: time) ?? "")
                guard try temporalMatch(value, query: query, vr: .DT) else { return false }
                combined.formUnion([date, time])
            }
        }
        for key in identifier.elements where !combined.contains(key.tag) {
            // Character set describes encoding, and Query/Retrieve Level selects the entity.
            if key.tag == 0x00080005 || key.tag == 0x00080052 { continue }
            guard try matches(candidate[key.tag], key: key) else { return false }
        }
        return true
    }

    private func matches(_ candidate: DicomDataElement?, key: DicomDataElement) throws -> Bool {
        if key.vr == .SQ {
            let items = key.sequenceItems
            guard items.count <= 1 else { throw invalidKey() }
            guard let query = items.first?.dataSet, !query.isEmpty else { return true }
            for item in candidate?.sequenceItems ?? [] {
                if try matches(item.dataSet, identifier: query) { return true }
            }
            return false
        }
        if case .bytes(let bytes) = key.value {
            return bytes.isEmpty || candidate?.value == key.value
        }
        let queries = key.stringValues.flatMap { $0.components(separatedBy: "\\") }.map(trim)
        if queries.isEmpty || queries == [""] { return true }
        let values = candidate?.stringValues.flatMap { $0.components(separatedBy: "\\") }.map(trim) ?? []
        let textual: Set<DicomVR> = [.AE, .CS, .LO, .LT, .PN, .SH, .ST, .UC, .UR, .UT]
        let temporal: Set<DicomVR> = [.DA, .TM, .DT]
        if emptyValueMatching && queries == ["\"\""] && (textual.contains(key.vr) || temporal.contains(key.vr)) {
            return values.isEmpty || values.allSatisfy(\.isEmpty)
        }
        if requiredKeys.contains(key.tag) && (values.isEmpty || values.allSatisfy(\.isEmpty)) { return true }
        if key.vr == .UI { return queries.contains { values.contains($0) } }
        if queries.count > 1 {
            guard multipleValueMatching, [.AE, .AS, .AT, .CS, .LO, .PN, .SH, .UC].contains(key.vr),
                  queries.allSatisfy({ !$0.contains("*") && !$0.contains("?") }) else { throw invalidKey() }
            return queries.allSatisfy { values.contains($0) }
        }
        let query = queries[0]
        if textual.contains(key.vr) && query == "*" { return true }
        for value in values {
            if temporal.contains(key.vr) {
                if try temporalMatch(value, query: query, vr: key.vr) { return true }
            } else if textual.contains(key.vr) && (query.contains("*") || query.contains("?")) {
                if wildcard(value, pattern: query) { return true }
            } else if key.vr == .DS || key.vr == .IS {
                if let lhs = Decimal(string: value), let rhs = Decimal(string: query), lhs == rhs { return true }
            } else if value == query { return true }
        }
        return false
    }

    private func wildcard(_ value: String, pattern: String) -> Bool {
        let input = Array(value), pattern = Array(pattern)
        var previous = [Bool](repeating: false, count: input.count + 1)
        previous[0] = true
        for character in pattern {
            var next = [Bool](repeating: false, count: input.count + 1)
            next[0] = character == "*" && previous[0]
            for index in input.indices {
                next[index + 1] = character == "*" ? previous[index + 1] || next[index]
                    : previous[index] && (character == "?" || character == input[index])
            }
            previous = next
        }
        return previous[input.count]
    }

    private func temporalMatch(_ value: String, query: String, vr: DicomVR) throws -> Bool {
        guard query != "-" else { throw invalidKey() }
        guard let candidate = temporalInterval(value, vr: vr) else { return false }
        if !query.contains("-") {
            guard let requested = temporalInterval(query, vr: vr) else { throw invalidKey() }
            return candidate.lowerBound <= requested.upperBound && requested.lowerBound <= candidate.upperBound
        }
        // A DT negative UTC offset belongs to an endpoint. Try every separator and
        // retain the split whose endpoints are valid DICOM temporal values.
        for index in query.indices where query[index] == "-" {
            let left = trim(String(query[..<index]))
            let right = trim(String(query[query.index(after: index)...]))
            let lower = left.isEmpty ? -Double.infinity : temporalInterval(left, vr: vr)?.lowerBound
            let upper = right.isEmpty ? Double.infinity : temporalInterval(right, vr: vr)?.upperBound
            if let lower, let upper, lower <= upper {
                return candidate.lowerBound <= upper && lower <= candidate.upperBound
            }
        }
        throw invalidKey()
    }

    private func temporalInterval(_ text: String, vr: DicomVR) -> ClosedRange<Double>? {
        var value = trim(text)
        var offset = 0
        if vr == .DT, value.count >= 9 {
            let suffix = String(value.suffix(5))
            if let sign = suffix.first, sign == "+" || sign == "-" {
                guard let hours = Int(suffix.dropFirst().prefix(2)), let minutes = Int(suffix.suffix(2)),
                      hours <= 14, minutes < 60 else { return nil }
                offset = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
                value.removeLast(5)
            }
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let digits = parts.first, digits.allSatisfy(\.isNumber) else { return nil }
        let count = digits.count
        let allowed = vr == .TM ? [2, 4, 6] : vr == .DA ? [8] : [4, 6, 8, 10, 12, 14]
        guard allowed.contains(count) else { return nil }
        if parts.count == 2 && (count != (vr == .TM ? 6 : 14) || parts[1].isEmpty
            || parts[1].count > 6 || !parts[1].allSatisfy(\.isNumber)) { return nil }
        func number(_ start: Int, _ length: Int, fallback: Int) -> Int {
            guard count >= start + length else { return fallback }
            return Int(digits.dropFirst(start).prefix(length)) ?? fallback
        }
        let base = vr == .TM ? 0 : 8
        let hour = number(base, 2, fallback: 0)
        let minute = number(base + 2, 2, fallback: 0)
        let second = number(base + 4, 2, fallback: 0)
        guard hour < 24, minute < 60, second <= 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: vr == .TM ? 2000 : number(0, 4, fallback: 2000),
            month: vr == .TM ? 1 : number(4, 2, fallback: 1),
            day: vr == .TM ? 1 : number(6, 2, fallback: 1), hour: hour, minute: minute, second: min(second, 59))
        guard let date = calendar.date(from: components),
              calendar.component(.month, from: date) == components.month,
              calendar.component(.day, from: date) == components.day else { return nil }
        let fraction = parts.count == 2 ? Double("0." + parts[1]) ?? 0 : 0
        let lower = date.timeIntervalSince1970 - Double(offset) + fraction + (second == 60 ? 1 : 0)
        let unit: Calendar.Component = count <= 4 && vr != .TM ? .year
            : count == 6 && vr != .TM ? .month : count == 8 && vr != .TM ? .day
            : count == base + 2 ? .hour : count == base + 4 ? .minute : .second
        let width = parts.count == 2 ? pow(10, -Double(parts[1].count))
            : calendar.date(byAdding: unit, value: 1, to: date)!.timeIntervalSince(date)
        return lower...(lower + width - 0.000001)
    }

    private func trim(_ value: String) -> String { value.trimmingCharacters(in: CharacterSet(charactersIn: " \0")) }
    private func invalidKey() -> DicomDIMSEProviderError {
        DicomDIMSEProviderError(status: 0xA900, errorComment: "Invalid matching key")
    }
}
