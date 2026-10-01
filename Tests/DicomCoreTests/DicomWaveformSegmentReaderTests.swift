import XCTest
@testable import DicomCore

final class DicomWaveformSegmentReaderTests: XCTestCase {
    func test_requestedWindow_readsOnlyItsInterleavedBytesAndMatchesFullParser() async throws {
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .implicitVRLittleEndian] {
            let samples = Array(0..<10_000)
            let group = DicomWaveformMultiplexGroup(samplingFrequency: 500, timeOffsetMilliseconds: 250,
                channels: [.init(sensitivity: 2, sensitivityCorrectionFactor: 3, baseline: 4,
                                 timeSkew: 0.002, samples: samples), .init(sensitivity: 1, samples: samples.map { -$0 })])
            let ds = try DicomWaveformBuilder.dataSet(multiplexGroups: [group])
            let bytes = try DicomDataSetWriter.part10Data(from: ds, options: .init(transferSyntax: syntax))
            let requests = WaveformRangeLog()
            let source = try DicomByteSource(remote: .init { request in
                await requests.append(request.range)
                return .init(status: 206,
                    contentRange: "bytes \(request.range.lowerBound)-\(request.range.upperBound - 1)/\(bytes.count)",
                    entityTag: "\"waveform\"", body: Data(bytes[request.range]))
            }, count: bytes.count, entityTag: "\"waveform\"")
            let reader = try await DicomWaveformSegmentReader.open(source: source)
            let before = await source.metrics
            let dataRange = reader.index.groups[0].dataRange
            let indexRanges = await requests.ranges
            XCTAssertTrue(indexRanges.allSatisfy { !$0.overlaps(dataRange) })
            XCTAssertLessThan(before.receivedBytes, bytes.count - dataRange.count + 100)
            let result = try await reader.samples(group: 1, channels: [1, 2], sampleRange: 2345..<2353)
            let after = await source.metrics
            XCTAssertEqual(after.readCount - before.readCount, 1)
            XCTAssertEqual(after.receivedBytes - before.receivedBytes, 8 * 2 * 2)
            let windowRanges = await requests.ranges
            XCTAssertEqual(Array(windowRanges.dropFirst(indexRanges.count)),
                [(dataRange.lowerBound + 2345 * 4)..<(dataRange.lowerBound + 2353 * 4)])
            let parsed = try XCTUnwrap(DCMDecoder(data: bytes).waveform)
            for channel in 0..<2 {
                XCTAssertEqual(result[channel].rawValues, Array(parsed.multiplexGroups[0].channels[channel].samples[2345..<2353]))
                XCTAssertEqual(result[channel].timeSeries.physicalSamples,
                               Array(parsed.multiplexGroups[0].channels[channel].physicalSamples()[2345..<2353]))
            }
            XCTAssertEqual(result[0].timeSeries.startTime, 0.252 + 2345.0 / 500, accuracy: 1e-12)
            let timed = try await reader.samples(group: 1, channels: [1, 2], timeRange: (0.25 + 2345.0 / 500)..<(0.25 + 2353.0 / 500))
            XCTAssertEqual(timed, result)
        }
    }

    func test_limitsAndClosedSource_throwBeforeReading() async throws {
        let bytes = try DicomWaveformBuilder.part10Data(multiplexGroups: [
            .init(samplingFrequency: 500, channels: [.init(samples: [1, 2, 3, 4])])])
        let source = DicomByteSource(data: bytes)
        let index = try await DicomWaveformSourceIndex.build(from: source)
        let reader = try DicomWaveformSegmentReader(source: source, index: index, maximumSampleCount: 2, maximumReadBytes: 2)
        let before = await source.metrics
        do { _ = try await reader.samples(group: 1, channels: [1], sampleRange: 0..<3); XCTFail() }
        catch { XCTAssertEqual(error as? DicomWaveformSegmentReader.Failure, .sampleLimit) }
        do { _ = try await reader.samples(group: 1, channels: [1], sampleRange: 0..<2); XCTFail() }
        catch { XCTAssertEqual(error as? DicomWaveformSegmentReader.Failure, .byteLimit) }
        do { _ = try await reader.samples(group: 2, channels: [1], sampleRange: 0..<1); XCTFail() }
        catch { XCTAssertEqual(error as? DicomWaveformSegmentReader.Failure, .unknownGroup) }
        do { _ = try await reader.samples(group: 1, channels: [2], sampleRange: 0..<1); XCTFail() }
        catch { XCTAssertEqual(error as? DicomWaveformSegmentReader.Failure, .unknownChannel) }
        do { _ = try await reader.samples(group: 1, channels: [1], sampleRange: 0..<5); XCTFail() }
        catch { XCTAssertEqual(error as? DicomWaveformSegmentReader.Failure, .invalidRange) }
        let after = await source.metrics
        XCTAssertEqual(before.readCount, after.readCount)
        await source.close()
        do { _ = try await reader.samples(group: 1, channels: [1], sampleRange: 0..<1); XCTFail() }
        catch { XCTAssertEqual(error as? DicomByteSource.Failure, .closed) }
    }

    func test_undefinedLengthWaveformSequence_indexesWithoutReadingPayload() async throws {
        let bytes = try DicomWaveformBuilder.part10Data(multiplexGroups: [
            .init(samplingFrequency: 500, channels: [.init(samples: [1, 2, 3, 4])])])
        // Replace the outer SQ and its single item lengths; preserve nested explicit-length SQs.
        var undefined = bytes
        let tag = Data([0, 0x54, 0, 1, 0x53, 0x51, 0, 0])
        let start = try XCTUnwrap(undefined.range(of: tag)).lowerBound
        let length = Int(undefined[start + 8]) | Int(undefined[start + 9]) << 8 | Int(undefined[start + 10]) << 16 | Int(undefined[start + 11]) << 24
        undefined.replaceSubrange((start + 8)..<(start + 12), with: [255,255,255,255])
        undefined.replaceSubrange((start + 16)..<(start + 20), with: [255,255,255,255])
        undefined.insert(contentsOf: [254,255,13,224,0,0,0,0,254,255,221,224,0,0,0,0], at: start + 12 + length)
        let reader = try await DicomWaveformSegmentReader.open(source: DicomByteSource(data: undefined))
        let samples = try await reader.samples(group: 1, channels: [1], sampleRange: 1..<3)
        XCTAssertEqual(samples[0].rawValues, [2, 3])
    }
}

private actor WaveformRangeLog {
    var ranges: [Range<Int>] = []
    func append(_ range: Range<Int>) { ranges.append(range) }
}
