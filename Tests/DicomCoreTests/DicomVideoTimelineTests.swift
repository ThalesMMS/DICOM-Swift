import Foundation
import XCTest
@testable import DicomCore

final class DicomVideoTimelineTests: XCTestCase {
    func test_cineUnsignedShorts_rejectNegativeAndOverflowValues() throws {
        for value in [-1, 65536] {
            var cine = DicomVideoCine()
            cine.preferredPlaybackSequencing = value
            XCTAssertThrowsError(try cine.applying(to: .init())) {
                XCTAssertEqual($0 as? DicomVideoError, .invalidFrameTiming)
            }
            cine.preferredPlaybackSequencing = nil
            cine.multiplexedAudioChannels = [.init(identificationCode: value, mode: "MONO", source: .init())]
            XCTAssertThrowsError(try cine.applying(to: .init())) {
                XCTAssertEqual($0 as? DicomVideoError, .invalidFrameTiming)
            }
        }
        for value in [0, 65535] {
            var cine = DicomVideoCine()
            cine.preferredPlaybackSequencing = value
            cine.multiplexedAudioChannels = [.init(identificationCode: value, mode: "MONO", source: .init())]
            XCTAssertEqual(DicomVideoCine(dataSet: try cine.applying(to: .init())), cine)
        }
    }

    static func video(_ name: String = "known-bframes.h264", timing: Double? = 1000 / 12) throws -> DicomVideo {
        let pixels = try DicomVideoPixelData(streamData: DicomVideoStreamInspectorTests.fixture(name),
            columns: 128, rows: 64, numberOfFrames: 96, frameTimeMilliseconds: timing)
        return try XCTUnwrap(DCMDecoder(data: DicomVideoBuilder.part10Data(video: pixels)).video)
    }

    func test_temporalRead_includesPrecedingIDRAndDecodePrefix() throws {
        let timeline = try DicomVideoTimeline(video: Self.video())
        let window = try timeline.timeRange(forFrames: 13..<15)
        let units = try timeline.temporalRead(range: window)
        XCTAssertEqual(units.first?.accessUnit.decodeIndex, 0)
        XCTAssertTrue(units.first!.leadIn)
        XCTAssertEqual(units.filter { !$0.leadIn }.compactMap { $0.accessUnit.presentationIndex }.sorted(), [13, 14])
        XCTAssertTrue(units.allSatisfy { $0.accessUnit.fragmentIndexes == [0] })
    }

    func test_temporalRead_slicedStreamPreservesAccessUnitBytes() throws {
        let original = try Self.video()
        var padded = Data([0xFF, 0xFE, 0xFD])
        padded.append(original.streamData)
        let slice = padded.dropFirst(3)
        XCTAssertEqual(slice.startIndex, 3)
        let video = DicomVideo(sopClassUID: original.sopClassUID,
            transferSyntaxUID: original.transferSyntaxUID, transferSyntax: original.transferSyntax,
            columns: original.columns, rows: original.rows, numberOfFrames: original.numberOfFrames,
            streamData: slice, encapsulatedPixelDataDescriptor: original.encapsulatedPixelDataDescriptor,
            cine: original.cine)
        XCTAssertEqual(video.streamData, original.streamData)
        XCTAssertEqual(video.streamData.startIndex, 0)
        // Check the index contract before performing zero-based reads that could trap.
        guard video.streamData.startIndex == 0 else { return }
        let expected = try DicomVideoTimeline(video: original)
        let timeline = try DicomVideoTimeline(video: video)
        let window = try expected.timeRange(forFrames: 13..<15)
        XCTAssertEqual(try timeline.temporalRead(range: window), try expected.temporalRead(range: window))
    }

    func test_terminalFrameRange_usesKnownCadenceAndRefusesUnknownVectorEndpoint() throws {
        // Synthetic MPEG-2 headers without codec cadence; this only tests Cine timing fallback.
        let stream = Data([0, 0, 1, 0xB3, 0x08, 0, 0x40, 0x10, 0, 0, 0x40,
                           0, 0, 1, 0, 0, 0x08, 0, 0, 1, 0, 0, 0x48])
        for scalar in [40.0, nil] as [Double?] {
            let pixels = try DicomVideoPixelData(streamData: stream, transferSyntax: .mpeg2MainProfileMainLevel,
                columns: 128, rows: 64, numberOfFrames: 2, frameTimeMilliseconds: scalar,
                frameTimeVectorMilliseconds: scalar == nil ? [0, 40] : [])
            let video = try XCTUnwrap(DCMDecoder(data: DicomVideoBuilder.part10Data(video: pixels)).video)
            let timeline = try DicomVideoTimeline(video: video)
            XCTAssertEqual(try timeline.timeRange(forFrames: 0..<1), 0..<40_000)
            if scalar != nil {
                XCTAssertEqual(try timeline.timeRange(forFrames: 0..<2), 0..<80_000)
                XCTAssertEqual(try timeline.timeRange(forFrames: 1..<2), 40_000..<80_000)
            } else {
                XCTAssertThrowsError(try timeline.timeRange(forFrames: 0..<2)) {
                    XCTAssertEqual($0 as? DicomVideoInspectionError, .unknownTiming)
                }
            }
        }
    }

    func test_openGOP_refusesTemporalRead() throws {
        let timeline = try DicomVideoTimeline(video: Self.video("unsupported-open-gop.h264"))
        XCTAssertThrowsError(try timeline.temporalRead(range: 0..<1)) {
            XCTAssertEqual($0 as? DicomVideoInspectionError, .openGOPDependencies)
        }
    }

    func test_fullCine_roundTripsAudioDescriptionAndVectorPointer() throws {
        var cine = DicomVideoCine()
        cine.frameTimeVectorMilliseconds = [0, 40, 50]
        cine.startTrim = 1; cine.stopTrim = 3
        cine.frameDelayMilliseconds = 12; cine.imageTriggerDelayMilliseconds = 4
        cine.effectiveDurationSeconds = 0.09; cine.actualFrameDurationMilliseconds = 40
        cine.preferredPlaybackSequencing = 1; cine.cineRate = 25; cine.recommendedDisplayFrameRate = 20
        cine.multiplexedAudioChannels = [.init(identificationCode: 1, mode: "MONO", source: .init(elements: []))]
        let data = try cine.applying(to: .init(elements: []))
        XCTAssertEqual(DicomVideoCine(dataSet: data), cine)
        XCTAssertEqual(data.ints(for: 0x00280009), [0x00181065])
    }

    func test_explicitCine_replacesLegacyTimingAndPointer() throws {
        let pixels = try DicomVideoPixelData(streamData: Data([0, 0, 1, 0x65]), columns: 16, rows: 16,
            numberOfFrames: 3, frameTimeMilliseconds: 40, frameTimeVectorMilliseconds: [0, 40, 40])
        var cine = DicomVideoCine()
        cine.frameTimeMilliseconds = 50
        let constant = try DicomVideoBuilder.dataSet(video: pixels, cine: cine)
        XCTAssertEqual(constant.float(for: 0x00181063), 50)
        XCTAssertFalse(constant.contains(0x00181065))
        XCTAssertEqual(constant.ints(for: 0x00280009), [0x00181063])
        cine.frameTimeMilliseconds = nil
        cine.frameTimeVectorMilliseconds = [0, 50, 60]
        let vector = try DicomVideoBuilder.dataSet(video: pixels, cine: cine)
        XCTAssertFalse(vector.contains(0x00181063))
        XCTAssertEqual(vector.floats(for: 0x00181065), [0, 50, 60])
        XCTAssertEqual(vector.ints(for: 0x00280009), [0x00181065])
        let unchanged = try DicomVideoBuilder.dataSet(video: pixels, cine: .init())
        XCTAssertEqual(unchanged.float(for: 0x00181063), 40)
        XCTAssertEqual(unchanged.floats(for: 0x00181065), [0, 40, 40])
        XCTAssertEqual(unchanged.ints(for: 0x00280009), [0x00181065])
    }

    func test_cineWithoutTiming_preservesVideoTimingAndPointer() throws {
        for vector in [[], [0.0, 40, 50]] {
            let pixels = try DicomVideoPixelData(streamData: Data([0, 0, 1, 0x65]), columns: 16, rows: 16,
                numberOfFrames: 3, frameTimeMilliseconds: 40, frameTimeVectorMilliseconds: vector)
            var cine = DicomVideoCine()
            cine.startTrim = 2
            let data = try DicomVideoBuilder.dataSet(video: pixels, cine: cine)
            XCTAssertEqual(data.float(for: 0x00181063), 40)
            XCTAssertEqual(data.floats(for: 0x00181065), vector)
            XCTAssertEqual(data.ints(for: 0x00280009), [vector.isEmpty ? 0x00181063 : 0x00181065])
            XCTAssertEqual(data.int(for: 0x00082142), 2)
        }
    }

    func test_cineOnlyInitializer_synchronizesLegacyTimingAccessors() throws {
        let source = try Self.video()
        var cine = DicomVideoCine()
        cine.frameTimeMilliseconds = 50
        cine.frameTimeVectorMilliseconds = [0, 50, 60]
        cine.cineRate = 20
        cine.recommendedDisplayFrameRate = 10
        let video = DicomVideo(sopClassUID: source.sopClassUID, transferSyntaxUID: source.transferSyntaxUID,
            transferSyntax: source.transferSyntax, columns: 128, rows: 64, numberOfFrames: 3,
            frameTimeMilliseconds: 40, cineRate: 25, streamData: source.streamData,
            encapsulatedPixelDataDescriptor: source.encapsulatedPixelDataDescriptor, cine: cine)
        XCTAssertEqual(video.frameTimeMilliseconds, 50)
        XCTAssertEqual(video.frameTimeVectorMilliseconds, [0, 50, 60])
        XCTAssertEqual(video.cineRate, 20)
        XCTAssertEqual(video.recommendedDisplayFrameRate, 10)
        XCTAssertEqual(video.frameRate, 10)
        XCTAssertEqual(try XCTUnwrap(video.durationSeconds), 0.11, accuracy: 1e-12)
    }

    func test_frameTimeVector_requiresOneIncrementPerFrameDuringAuthoring() throws {
        let stream = Data([0, 0, 1, 0x65])
        let pixels = try DicomVideoPixelData(streamData: stream, columns: 16, rows: 16, numberOfFrames: 3)
        for vector in [[0.0, 40], [0, 40, 50, 60]] {
            XCTAssertThrowsError(try DicomVideoPixelData(streamData: stream, columns: 16, rows: 16,
                numberOfFrames: 3, frameTimeVectorMilliseconds: vector)) {
                XCTAssertEqual($0 as? DicomVideoError, .invalidFrameTiming)
            }
            var cine = DicomVideoCine()
            cine.frameTimeVectorMilliseconds = vector
            XCTAssertThrowsError(try DicomVideoBuilder.dataSet(video: pixels, cine: cine)) {
                XCTAssertEqual($0 as? DicomVideoError, .invalidFrameTiming)
            }
        }
    }

    func test_explicitCine_rejectsNonpositiveMultiframeTimingButAllowsSingleFrameZero() throws {
        let stream = Data([0, 0, 1, 0x65])
        let pixels = try DicomVideoPixelData(streamData: stream, columns: 16, rows: 16, numberOfFrames: 3)
        for value in [0.0, -40] {
            var cine = DicomVideoCine()
            cine.frameTimeMilliseconds = value
            XCTAssertThrowsError(try DicomVideoBuilder.dataSet(video: pixels, cine: cine)) {
                XCTAssertEqual($0 as? DicomVideoError, .invalidFrameTiming)
            }
        }
        let single = try DicomVideoPixelData(streamData: stream, columns: 16, rows: 16, numberOfFrames: 1)
        var cine = DicomVideoCine()
        cine.frameTimeMilliseconds = 0
        let data = try DicomVideoBuilder.dataSet(video: single, cine: cine)
        XCTAssertEqual(data.float(for: 0x00181063), 0)
        XCTAssertEqual(data.ints(for: 0x00280009), [0x00181063])
    }

    func test_cineIntegerStrings_rejectValuesOutsideSigned32BitRange() throws {
        let paths: [WritableKeyPath<DicomVideoCine, Int?>] = [\.startTrim, \.stopTrim,
            \.recommendedDisplayFrameRate, \.cineRate, \.actualFrameDurationMilliseconds]
        for path in paths {
            for value in [Int(Int32.min) - 1, Int(Int32.max) + 1] {
                var cine = DicomVideoCine()
                cine[keyPath: path] = value
                XCTAssertThrowsError(try cine.applying(to: .init(elements: []))) {
                    XCTAssertEqual($0 as? DicomVideoError, .invalidFrameTiming)
                }
            }
        }
        var cine = DicomVideoCine()
        cine.startTrim = Int(Int32.min)
        cine.stopTrim = Int(Int32.max)
        let data = try cine.applying(to: .init(elements: []))
        XCTAssertEqual(data.string(for: 0x00082142), "-2147483648")
        XCTAssertEqual(data.string(for: 0x00082143), "2147483647")
    }
}
