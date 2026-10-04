import Foundation

/// An ordered Accept for a retrieve: media ranges from the most to the least preferred.
///
/// `headerValue` sends every range, the first without `q` (1) and each next one with a lower `q`. Some servers read
/// only the first range, or refuse it instead of moving to the next. So when a retrieve is answered with one of
/// `fallbackStatuses` (by default 406 and 500), the client asks again without the first range, then without the
/// second, until the list ends; the error of the last attempt keeps every Accept sent in
/// `DicomWebError.attemptedAccepts`. An empty `fallbackStatuses` sends the list once. A body already handed to the
/// sink is never asked for again.
///
/// Orthanc and dcm4chee answer 500, not 406, to a transfer syntax they cannot convert to, and Orthanc reads only the
/// first range. A 500 is also an ordinary server failure, so it moves on at most once per retrieve, and only when the
/// refused first range names a transfer syntax: after `transfer-syntax=*`, a range without one, or a second 500, the
/// retrieve ends with that error.
public struct DicomWebAcceptList: Equatable, Sendable {
    /// The most ranges a list holds: `q` has three decimals, so 1000 ranges are the most that keep it decreasing.
    public static let maximumRangeCount = 1000

    public let ranges: [DicomWebMediaType]
    /// Statuses after which a retrieve asks again with the ranges that follow; 500 under the limits above.
    public var fallbackStatuses: Set<Int>

    /// Throws `DicomWebError` `.badRequest` for an empty list or one longer than `maximumRangeCount`. A `q` given
    /// in a range is replaced by the one its place in the list gives.
    public init(_ ranges: [DicomWebMediaType], fallbackStatuses: Set<Int> = [406, 500]) throws {
        guard !ranges.isEmpty, ranges.count <= Self.maximumRangeCount else { throw DicomWebError(kind: .badRequest) }
        self.ranges = ranges.map { DicomWebMediaType(type: $0.type, parameters: $0.parameters.filter { $0.key != "q" }) }
        self.fallbackStatuses = fallbackStatuses
    }

    /// Every range, separated by commas, with `q` lowered by 0.1 per place, or by less when there are more than ten.
    public var headerValue: String { headerValue(droppingFirst: 0) }

    /// The Accept of the attempt that follows `count` refusals: the ranges after the first `count`.
    func headerValue(droppingFirst count: Int) -> String {
        let remaining = ranges.dropFirst(count)
        let step = remaining.count <= 10 ? 100 : Self.maximumRangeCount / remaining.count
        return remaining.enumerated().map { place, range in
            let thousandths = 1000 - place * step
            guard thousandths < 1000 else { return range.headerValue }
            var weight = String(format: "0.%03d", thousandths)
            while weight.hasSuffix("0") { weight.removeLast() }
            return range.headerValue + "; q=" + weight
        }.joined(separator: ", ")
    }
}
