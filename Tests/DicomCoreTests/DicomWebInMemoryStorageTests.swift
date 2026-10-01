import Foundation
import XCTest
@testable import DicomCore

final class DicomWebInMemoryStorageTests: XCTestCase {
    func test_search_indexesEveryInsertionPathAndIgnoresDuplicates() async throws {
        let fixtures = DicomWebInMemoryStorage()
        let instances = try (0..<4).map { index in
            var set = DicomWebSearchRecordingStorage.dataSet(index)
            set.set(.init(tag: 0x0020000D, vr: .UI, value: .strings(["2.25.1"])))
            set.set(.init(tag: 0x0020000E, vr: .UI, value: .strings([index < 2 ? "2.25.11" : "2.25.12"])))
            set.set(.init(tag: 0x00080060, vr: .CS, value: .strings([index < 2 ? "CT" : "MR"])))
            return try fixtures.add(dataSet: set)
        }
        let storage = DicomWebInMemoryStorage(instances: [instances[2]])
        try storage.add(part10Data: instances[0].part10Data)
        try storage.add(dataSet: instances[3].dataSet)
        _ = try await storage.store(instances: [instances[1], instances[0]])
        var conflict = instances[0]
        conflict.part10Data.append(0)
        let results = try await storage.store(instances: [conflict])
        XCTAssertNil(results.first?.failureReason)
        XCTAssertEqual(results.first?.warningReason, 0xB000)
        let studies = try await storage.searchStudies(parameters: .init(limit: 1))
        XCTAssertEqual(studies.first?.string(for: 0x00201206), "2")
        XCTAssertEqual(studies.first?.string(for: 0x00201208), "4")
        XCTAssertEqual(studies.first?.strings(for: .modalitiesInStudy), ["CT", "MR"])
        let series = try await storage.searchSeries(parameters: .init(limit: 1, offset: 1))
        XCTAssertEqual(series.first?.string(for: .seriesInstanceUID), "2.25.12")
        XCTAssertEqual(series.first?.string(for: 0x00201209), "2")
    }

    func test_search_appliesProviderPaginationAtEveryLevel() async throws {
        let storage = DicomWebInMemoryStorage()
        for index in (0..<6).reversed() { try storage.add(dataSet: DicomWebSearchRecordingStorage.dataSet(index)) }
        let parameters = DicomWebSearchParameters(limit: 2, offset: 2)
        let pages = [
            try await storage.searchStudies(parameters: parameters),
            try await storage.searchSeries(parameters: parameters),
            try await storage.searchInstances(parameters: parameters)
        ]
        for page in pages {
            XCTAssertEqual(page.map { $0.string(for: .studyInstanceUID) }, ["2.25.100002", "2.25.100003"])
        }
    }

    func test_search_snapshotCountsRemainScopedToStudyAndSeries() async throws {
        let storage = DicomWebInMemoryStorage()
        for (study, series, instance, modality) in [
            ("1", "11", "111", "CT"), ("1", "11", "112", "CT"),
            ("1", "12", "121", "MR"), ("2", "21", "211", "US")
        ] {
            try storage.add(dataSet: .init(elements: [
                .init(tag: 0x0020000D, vr: .UI, value: .strings(["2.25." + study])),
                .init(tag: 0x0020000E, vr: .UI, value: .strings(["2.25." + series])),
                .init(tag: 0x00080018, vr: .UI, value: .strings(["2.25." + instance])),
                .init(tag: 0x00080060, vr: .CS, value: .strings([modality]))
            ]))
        }
        let studies = try await storage.searchStudies(parameters: .init())
        XCTAssertEqual(studies.count, 2)
        let first = try XCTUnwrap(studies.first { $0.string(for: 0x0020000D) == "2.25.1" })
        XCTAssertEqual(first.string(for: 0x00201206), "2")
        XCTAssertEqual(first.string(for: 0x00201208), "3")
        let second = try XCTUnwrap(studies.first { $0.string(for: 0x0020000D) == "2.25.2" })
        XCTAssertEqual(second.string(for: 0x00201206), "1")
        XCTAssertEqual(second.string(for: 0x00201208), "1")
        var parameters = DicomWebSearchParameters()
        parameters.studyInstanceUID = "2.25.1"
        let series = try await storage.searchSeries(parameters: parameters)
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series.first { $0.string(for: 0x0020000E) == "2.25.11" }?.string(for: 0x00201209), "2")
        XCTAssertEqual(series.first { $0.string(for: 0x0020000E) == "2.25.12" }?.string(for: 0x00201209), "1")
    }
}
