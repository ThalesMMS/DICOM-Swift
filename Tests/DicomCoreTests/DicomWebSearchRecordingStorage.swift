import Foundation
@testable import DicomCore

actor DicomWebSearchRecordingStorage: DicomWebStorageProviding {
    let count: Int
    var requests: [DicomWebSearchParameters] = []
    var returnedCount = 0

    init(count: Int = 100) { self.count = count }

    static func dataSet(_ index: Int) -> DicomDataSet {
        let study = "2.25.\(index + 100_000)"
        return DicomWebServerAuthorizationTests.dataSet(study, instance: study + ".3")
    }

    func searchStudies(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] { page(parameters) }
    func searchSeries(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] { page(parameters) }
    func searchInstances(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] { page(parameters) }

    private func page(_ parameters: DicomWebSearchParameters) -> [DicomDataSet] {
        requests.append(parameters)
        let offset = min(parameters.offset ?? 0, count)
        let size = min(parameters.limit ?? count, count - offset)
        returnedCount += size
        return (offset..<(offset + size)).map(Self.dataSet)
    }

    func metadata(study: String, series: String?, instance: String?) async throws -> [DicomDataSet] { [] }
    func instance(study: String, series: String, instance: String) async throws -> DicomWebStoredInstance {
        throw DicomWebServerFailure(404, "Instance not found.")
    }
    func bulkData(uri: String) async throws -> Data { throw DicomWebServerFailure(404, "Bulk data not found.") }
    func store(instances: [DicomWebStoredInstance]) async throws -> [DicomWebStorageResult] { [] }
}
