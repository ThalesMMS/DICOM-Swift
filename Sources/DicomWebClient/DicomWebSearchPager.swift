import Foundation
import DicomData

public struct DicomWebSearchPage: Sendable {
    public let dataSets: [DicomDataSet]
    public let statusCode: Int
    public let contentType: String?
    public let warning: String?
    public let offset: Int
    public let limit: Int?
    public var hasMore: Bool {
        guard let warning else { return false }
        let lower = warning.lowercased()
        return lower.contains("299") && (lower.contains("additional results") || lower.contains("truncat"))
    }
}

public struct DicomWebSearchPager: AsyncSequence, Sendable {
    public typealias Element = DicomWebSearchPage
    let client: DicomWebClient
    let parameters: DicomWebSearchParameters
    let continuesOnFullPage: Bool
    public func makeAsyncIterator() -> AsyncIterator { .init(client: client, parameters: parameters, continuesOnFullPage: continuesOnFullPage) }

    public struct AsyncIterator: AsyncIteratorProtocol {
        let client: DicomWebClient
        var parameters: DicomWebSearchParameters
        let continuesOnFullPage: Bool
        var finished = false
        public mutating func next() async throws -> DicomWebSearchPage? {
            try Task.checkCancellation()
            guard !finished else { return nil }
            let page = try await client.search(parameters: parameters)
            let fullPage = continuesOnFullPage && parameters.limit.map { $0 > 0 && page.dataSets.count == $0 } == true
            finished = (!page.hasMore && !fullPage) || page.dataSets.isEmpty || parameters.limit == 0
            let nextOffset = page.offset.addingReportingOverflow(page.dataSets.count)
            guard !nextOffset.overflow else { throw DicomWebError(kind: .badRequest) }
            parameters.offset = nextOffset.partialValue
            return page
        }
    }
}
