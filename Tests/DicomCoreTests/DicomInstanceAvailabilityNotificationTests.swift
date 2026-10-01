import XCTest
@testable import DicomCore

func ianFixture() -> DicomInstanceAvailabilityNotification {
    .init(studyInstanceUID: "2.25.100", series: [.init(seriesInstanceUID: "2.25.101", instances: [
        .init(sopClassUID: DicomStorageSOPClassUIDs.secondaryCaptureImageStorage, sopInstanceUID: "2.25.102",
              availability: .online, retrieveAETitle: "ARCHIVE")])])
}
actor IANReceiver: DicomInstanceAvailabilityNotificationReceiving {
    var received: [DicomDataSet] = []
    func receive(sopInstanceUID: String, dataSet: DicomDataSet) { received.append(dataSet) }
}
final class DicomInstanceAvailabilityNotificationTests: XCTestCase {
    func test_builderPerInstanceValuesAndOptionalRetrievalAttributes() throws {
        var model = ianFixture()
        model.series[0].instances = DicomInstanceAvailability.allCases.enumerated().map { index, availability in
            .init(sopClassUID: "1.2.3", sopInstanceUID: "2.25.\(index)", availability: availability,
                  retrieveAETitle: "AE\(index)", retrieveLocationUID: "2.25.9", retrieveURI: "https://example.invalid/a",
                  retrieveURL: "https://example.invalid/b", storageMediaFileSetID: "MEDIA", storageMediaFileSetUID: "2.25.8")
        }
        let ds = try DicomInstanceAvailabilityNotificationBuilder.build(model)
        let instances = ds.sequenceItems(for: 0x00081115)[0].dataSet.sequenceItems(for: 0x00081199)
        XCTAssertEqual(instances.map { $0.dataSet.string(for: 0x00080056)! }, DicomInstanceAvailability.allCases.map(\.rawValue))
        XCTAssertEqual(instances.map { $0.dataSet.string(for: 0x00080054)! }, ["AE0", "AE1", "AE2", "AE3"])
        XCTAssertNotNil(ds[0x00081111]); XCTAssertTrue(ds.sequenceItems(for: 0x00081111).isEmpty)
    }
    func test_strictValidatorRejectsExtraTagsAtEveryLevel() throws {
        let ds = try DicomInstanceAvailabilityNotificationBuilder.build(ianFixture())
        XCTAssertThrowsError(try DicomInstanceAvailabilityNotification.validate(dataSet: ds.setting(upsString(0x00100010, "FORBIDDEN", .PN))))
        var series = ds.sequenceItems(for: 0x00081115)[0].dataSet
        XCTAssertThrowsError(try DicomInstanceAvailabilityNotification.validate(dataSet: ds.setting(upsSequence(0x00081115,
            [series.setting(upsString(0x00100020, "FORBIDDEN", .LO))]))))
        let instance = series.sequenceItems(for: 0x00081199)[0].dataSet
        series.set(upsSequence(0x00081199, [instance.setting(upsString(0x0020000D, "2.25.1", .UI))]))
        XCTAssertThrowsError(try DicomInstanceAvailabilityNotification.validate(dataSet: ds.setting(upsSequence(0x00081115, [series]))))
    }
    func test_requiredAttributesAndInvalidAvailability() throws {
        let ds = try DicomInstanceAvailabilityNotificationBuilder.build(ianFixture())
        for tag in [0x00081111, 0x00081115, 0x0020000D] {
            var invalid = ds; invalid.remove(tag)
            XCTAssertThrowsError(try DicomInstanceAvailabilityNotification.validate(dataSet: invalid))
        }
        let series = ds.sequenceItems(for: 0x00081115)[0].dataSet
        let instance = series.sequenceItems(for: 0x00081199)[0].dataSet
        for tag in [0x00081150, 0x00081155, 0x00080056, 0x00080054] {
            var invalid = instance; invalid.remove(tag)
            XCTAssertThrowsError(try DicomInstanceAvailabilityNotification.validate(dataSet: ds.setting(upsSequence(0x00081115,
                [series.setting(upsSequence(0x00081199, [invalid]))]))))
        }
        XCTAssertThrowsError(try DicomInstanceAvailabilityNotification.validate(dataSet: ds.setting(upsSequence(0x00081115,
            [series.setting(upsSequence(0x00081199, [instance.setting(upsString(0x00080056, "COMPLETE"))]))]))))
    }
}
