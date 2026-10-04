import Foundation
import DicomData

public struct DicomWebSearchPage: Sendable {
    public let dataSets: [DicomDataSet]
    public let statusCode: Int
    public let contentType: String?
    public let warning: String?
    public let offset: Int
    public let limit: Int?
    /// Set on the last page a pager returns when it stopped before the server said its results were complete.
    public internal(set) var stopReason: DicomWebSearchStopReason? = nil
    /// A `299` warning value (RFC 7234 warn-code) that announces further or truncated results. Other `299`
    /// warnings, such as unsupported fuzzy matching, do not; the full text stays in `warning`.
    public var hasMore: Bool {
        guard let warning else { return false }
        return Self.warningValues(warning).contains { code, text in
            let lower = text.lowercased()
            return code == 299 && (lower.contains("additional results") || lower.contains("truncat"))
        }
    }

    /// Splits a Warning field into its values; a comma starts a new value only before a three-digit warn-code.
    static func warningValues(_ field: String) -> [(code: Int, text: String)] {
        var values: [(code: Int, text: String)] = []
        for piece in field.split(separator: ",", omittingEmptySubsequences: false) {
            let trimmed = piece.drop { $0 == " " || $0 == "\t" }
            let digits = trimmed.prefix(3)
            if digits.count == 3, digits.allSatisfy({ ("0"..."9").contains($0) }), let code = Int(digits),
               trimmed.dropFirst(3).first.map({ $0 == " " || $0 == "\t" }) ?? true {
                values.append((code, String(trimmed.dropFirst(3))))
            } else if !values.isEmpty {
                values[values.count - 1].text += "," + piece
            }
        }
        return values
    }
}

/// Why a pager stopped before the server reported the end of its results.
public enum DicomWebSearchStopReason: String, Sendable, Equatable {
    /// A page that should have advanced repeated results already returned and brought none new, as when a server
    /// ignores `offset`. Results without the UID of the search level cannot be told apart, so they never count as new.
    case repeatedPage
    /// The pager reached `DicomWebSearchPagingLimits.maximumPages`.
    case pageLimitReached
    /// The pager reached `DicomWebSearchPagingLimits.maximumResults`; that page holds only the results within it.
    case resultLimitReached
}

/// Ceilings on the requests and results of one paged search.
public struct DicomWebSearchPagingLimits: Sendable, Equatable {
    public var maximumPages: Int
    public var maximumResults: Int
    public init(maximumPages: Int = 10_000, maximumResults: Int = 100_000) {
        self.maximumPages = maximumPages
        self.maximumResults = maximumResults
    }
}

/// Pages a QIDO search by `offset`. Each result is returned once, keyed by the UID of the search level; results
/// without that UID pass through, and only the page limit bounds them. The pager stops, saying why on the last page,
/// when a page repeats results without bringing any new one, or a limit is reached.
public struct DicomWebSearchPager: AsyncSequence, Sendable {
    public typealias Element = DicomWebSearchPage
    let client: DicomWebClient
    let parameters: DicomWebSearchParameters
    let continuesOnFullPage: Bool
    var limits = DicomWebSearchPagingLimits()
    public func makeAsyncIterator() -> AsyncIterator {
        .init(client: client, parameters: parameters, continuesOnFullPage: continuesOnFullPage, limits: limits)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let client: DicomWebClient
        var parameters: DicomWebSearchParameters
        let continuesOnFullPage: Bool
        let limits: DicomWebSearchPagingLimits
        var finished = false
        var pageCount = 0
        var resultCount = 0
        var seen = Set<String>()
        public mutating func next() async throws -> DicomWebSearchPage? {
            try Task.checkCancellation()
            guard !finished else { return nil }
            let page = try await client.search(parameters: parameters)
            let fullPage = continuesOnFullPage && parameters.limit.map { $0 > 0 && page.dataSets.count == $0 } == true
            finished = (!page.hasMore && !fullPage) || page.dataSets.isEmpty || parameters.limit == 0
            let nextOffset = page.offset.addingReportingOverflow(page.dataSets.count)
            guard !nextOffset.overflow else { throw DicomWebError(kind: .badRequest) }
            parameters.offset = nextOffset.partialValue
            pageCount += 1

            let tag: DicomTag = switch parameters.level {
            case .study: .studyInstanceUID
            case .series: .seriesInstanceUID
            case .instance: .sopInstanceUID
            }
            var newUIDs = 0
            var repeats = 0
            var dataSets = page.dataSets.filter { dataSet in
                guard let uid = dataSet.string(for: tag) else { return true }
                if seen.insert(uid).inserted { newUIDs += 1; return true }
                repeats += 1
                return false
            }
            let room = Swift.max(0, limits.maximumResults - resultCount)
            var stopReason: DicomWebSearchStopReason?
            if dataSets.count > room || (dataSets.count == room && !finished) {
                dataSets = Array(dataSets.prefix(room))
                stopReason = .resultLimitReached
            } else if !finished && newUIDs == 0 && repeats > 0 {
                stopReason = .repeatedPage
            } else if !finished && pageCount >= limits.maximumPages {
                stopReason = .pageLimitReached
            }
            if stopReason != nil { finished = true }
            resultCount += dataSets.count
            return DicomWebSearchPage(dataSets: dataSets, statusCode: page.statusCode, contentType: page.contentType,
                                      warning: page.warning, offset: page.offset, limit: page.limit, stopReason: stopReason)
        }
    }
}
