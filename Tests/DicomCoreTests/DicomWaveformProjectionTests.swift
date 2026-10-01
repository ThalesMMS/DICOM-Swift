import XCTest
@testable import DicomCore

final class DicomWaveformProjectionTests: XCTestCase {
    func test_envelope_preservesExtremaEndpointsPaddingAndTime() throws {
        let series = DicomWaveformTimeSeries(startTime: 10, samplingFrequency: 2,
            physicalSamples: [1, 100, -50, 2, nil, nil, 3, 4], units: "mV")
        let projection = try DicomWaveformProjection(series: series, bucketCount: 2, sensitivity: 0.5)
        XCTAssertEqual(projection.buckets.map(\.min), [-50, 3])
        XCTAssertEqual(projection.buckets.map(\.max), [100, 4])
        XCTAssertEqual(projection.buckets.map(\.first), [1, nil])
        XCTAssertEqual(projection.buckets.map(\.last), [2, 4])
        XCTAssertEqual(projection.buckets.map(\.startTime), [10, 12])
        XCTAssertEqual(projection.buckets.map(\.endTime), [12, 14])
        XCTAssertEqual(projection.units, "mV")
        XCTAssertEqual(projection.sensitivity, 0.5)
        XCTAssertEqual(try DicomWaveformProjection(series: series, bucketCount: 2, sensitivity: 0.5), projection)
        let exact = try DicomWaveformProjection(series: series, bucketCount: Int.max)
        XCTAssertEqual(exact.buckets.count, 8)
        XCTAssertEqual(exact.buckets.map(\.first), series.physicalSamples)
        XCTAssertEqual(exact.buckets.map(\.last), series.physicalSamples)
        XCTAssertEqual(exact.buckets.map(\.min), series.physicalSamples)
    }

    func test_emptyInvalidAndChannelRange_areBounded() throws {
        let empty = DicomWaveformTimeSeries(startTime: 0, samplingFrequency: 1, physicalSamples: [], units: nil)
        XCTAssertEqual(try DicomWaveformProjection(series: empty, bucketCount: 10).buckets.count, 0)
        XCTAssertThrowsError(try DicomWaveformProjection(series: empty, bucketCount: 0))
        let channel = DicomWaveformChannel(sensitivity: 2, samples: [1, 2, 100, 3])
        let p = try DicomWaveformProjection(channel: channel, sampleRange: 1..<4, samplingFrequency: 2, bucketCount: 1)
        XCTAssertEqual(p.buckets[0].min, 4)
        XCTAssertEqual(p.buckets[0].max, 200)
        XCTAssertEqual(p.buckets[0].startTime, 0.5)
        XCTAssertThrowsError(try DicomWaveformProjection(channel: channel, sampleRange: 1..<5, samplingFrequency: 2, bucketCount: 1))
    }
}
