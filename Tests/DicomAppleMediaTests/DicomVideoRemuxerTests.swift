@preconcurrency import AVFoundation
@testable import DicomAppleMedia
import DicomCore
import Foundation
import Synchronization
import XCTest

final class DicomVideoRemuxerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicom-video-remuxer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func test_writePlayableContainer_h264Stream_writesPlayableMP4AndCapturesFrame() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("h264.mp4")
        let video = try makeVideo(
            fixtureBase64: Self.h264FixtureBase64,
            transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            width: 16,
            height: 16
        )

        try await DicomVideoRemuxer.writePlayableContainer(for: video, frameRate: 2, to: outputURL)

        try await assertPlayable(outputURL, expectedWidth: 16, expectedHeight: 16)
    }

    func test_writePlayableContainer_hevcStream_writesPlayableMP4AndCapturesFrame() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("hevc.mp4")
        let video = try makeVideo(
            fixtureBase64: Self.hevcFixtureBase64,
            transferSyntax: .hevcH265MainProfileLevel51,
            width: 64,
            height: 64
        )

        try await DicomVideoRemuxer.writePlayableContainer(for: video, frameRate: 2, to: outputURL)

        try await assertPlayable(outputURL, expectedWidth: 64, expectedHeight: 64)
    }

    func test_writePlayableContainer_mpeg2Stream_writesPlayableTransportStream() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("mpeg2.ts")
        let video = try makeVideo(
            fixtureBase64: Self.mpeg2FixtureBase64,
            transferSyntax: .mpeg2MainProfileMainLevel,
            width: 64,
            height: 64
        )

        try await DicomVideoRemuxer.writePlayableContainer(for: video, frameRate: 25, to: outputURL)

        let asset = AVURLAsset(url: outputURL)
        let isPlayable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(isPlayable)
        XCTAssertEqual(tracks.count, 1)
    }

    func test_writePlayableContainer_twoMPEG2AccessUnitsWithOutOfRangeFrameDurations_throwsInvalidFrameRate() async throws {
        let video = try makeVideo(
            fixtureBase64: Self.mpeg2FixtureBase64,
            transferSyntax: .mpeg2MainProfileMainLevel,
            width: 64,
            height: 64
        )

        for frameDuration in [UInt64(1) << 33, UInt64(1) << 63] {
            do {
                try await DicomVideoRemuxer.writePlayableContainer(
                    for: video,
                    frameRate: 90_000 / Double(frameDuration),
                    to: temporaryDirectory.appendingPathComponent("invalid-mpeg-duration.ts")
                )
                XCTFail("Expected invalidFrameRate for MPEG frame duration \(frameDuration)")
            } catch let error as DicomVideoRemuxError {
                XCTAssertEqual(error, .invalidFrameRate)
            }
        }
    }

    func test_writePlayableContainer_isoBaseMediaFile_preservesBytesExactly() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("passthrough.mp4")
        let container = Data([0, 0, 0, 12]) + Data("ftypisom".utf8)
        let video = makeVideo(
            stream: container,
            transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            width: 16,
            height: 16
        )

        try await DicomVideoRemuxer.writePlayableContainer(for: video, frameRate: 2, to: outputURL)

        XCTAssertEqual(try Data(contentsOf: outputURL), container)
    }

    func test_writePlayableContainer_nonFiniteOrNonPositiveFrameRate_throwsTypedError() async throws {
        let video = makeVideo(
            stream: Data([0, 0, 0, 12]) + Data("ftypisom".utf8),
            transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            width: 16,
            height: 16
        )

        for frameRate in [Double.nan, .infinity, 0, -1] {
            do {
                try await DicomVideoRemuxer.writePlayableContainer(
                    for: video,
                    frameRate: frameRate,
                    to: temporaryDirectory.appendingPathComponent("invalid-rate.mp4")
                )
                XCTFail("Expected invalidFrameRate for \(frameRate)")
            } catch let error as DicomVideoRemuxError {
                XCTAssertEqual(error, .invalidFrameRate)
            }
        }
    }

    func test_writePlayableContainer_frameRateOutsideMPEGClockRange_throwsTypedError() async throws {
        let video = makeVideo(
            stream: Data([0x00]),
            transferSyntax: .mpeg2MainProfileMainLevel,
            width: 16,
            height: 16
        )

        for frameRate in [Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude] {
            do {
                try await DicomVideoRemuxer.writePlayableContainer(
                    for: video,
                    frameRate: frameRate,
                    to: temporaryDirectory.appendingPathComponent("invalid-mpeg-rate.ts")
                )
                XCTFail("Expected invalidFrameRate for \(frameRate)")
            } catch let error as DicomVideoRemuxError {
                XCTAssertEqual(error, .invalidFrameRate)
            }
        }
    }

    func test_writePlayableContainer_malformedH264Stream_throwsTypedError() async throws {
        let video = makeVideo(
            stream: Data([0x01, 0x02, 0x03]),
            transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            width: 16,
            height: 16
        )

        do {
            try await DicomVideoRemuxer.writePlayableContainer(
                for: video,
                frameRate: 2,
                to: temporaryDirectory.appendingPathComponent("malformed.mp4")
            )
            XCTFail("Expected malformedElementaryStream")
        } catch let error as DicomVideoRemuxError {
            XCTAssertEqual(error, .malformedElementaryStream(codec: .h264))
        }
    }

    func test_writePlayableContainer_h264WithoutParameterSets_throwsTypedError() async throws {
        let video = makeVideo(
            stream: Data([0, 0, 0, 1, 0x65, 0x88]),
            transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            width: 16,
            height: 16
        )

        do {
            try await DicomVideoRemuxer.writePlayableContainer(
                for: video,
                frameRate: 2,
                to: temporaryDirectory.appendingPathComponent("missing-parameter-sets.mp4")
            )
            XCTFail("Expected missingParameterSets")
        } catch let error as DicomVideoRemuxError {
            XCTAssertEqual(error, .missingParameterSets(codec: .h264))
        }
    }

    func test_writePlayableContainer_h264BFrame_throwsTypedReorderingError() async throws {
        var bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: Self.h264FixtureBase64)))
        let sliceHeader = try XCTUnwrap(firstH264SliceHeader(in: bytes))
        bytes[sliceHeader] = (bytes[sliceHeader] & 0x60) | 0x01
        bytes[sliceHeader + 1] = 0xA0 // first_mb_in_slice = 0, slice_type = B
        let video = makeVideo(
            stream: Data(bytes),
            transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            width: 16,
            height: 16
        )

        do {
            try await DicomVideoRemuxer.writePlayableContainer(
                for: video,
                frameRate: 2,
                to: temporaryDirectory.appendingPathComponent("b-frame.mp4")
            )
            XCTFail("Expected frameReorderingUnsupported")
        } catch let error as DicomVideoRemuxError {
            XCTAssertEqual(error, .frameReorderingUnsupported(codec: .h264))
        }
    }

    func test_writePlayableContainer_hevcBFrame_throwsTypedReorderingError() async throws {
        var bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: Self.hevcFixtureBase64)))
        let sliceHeader = try XCTUnwrap(firstHEVCSliceHeader(in: bytes))
        bytes[sliceHeader] = 0x02 // Non-IRAP VCL NAL unit type 1.
        bytes[sliceHeader + 1] = 0x01
        bytes[sliceHeader + 2] = 0xE0 // first_slice = 1, pps_id = 0, slice_type = B.
        let video = makeVideo(
            stream: Data(bytes),
            transferSyntax: .hevcH265MainProfileLevel51,
            width: 64,
            height: 64
        )

        do {
            try await DicomVideoRemuxer.writePlayableContainer(
                for: video,
                frameRate: 2,
                to: temporaryDirectory.appendingPathComponent("hevc-b-frame.mp4")
            )
            XCTFail("Expected frameReorderingUnsupported")
        } catch let error as DicomVideoRemuxError {
            XCTAssertEqual(error, .frameReorderingUnsupported(codec: .hevc))
        }
    }

    func test_writePlayableContainer_mpeg2BPicture_throwsTypedReorderingError() async throws {
        var bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: Self.mpeg2FixtureBase64)))
        let pictureStart = try XCTUnwrap(firstMPEG2PictureStart(in: bytes))
        bytes[pictureStart + 5] = (bytes[pictureStart + 5] & 0xC7) | 0x18
        let video = makeVideo(
            stream: Data(bytes),
            transferSyntax: .mpeg2MainProfileMainLevel,
            width: 64,
            height: 64
        )

        do {
            try await DicomVideoRemuxer.writePlayableContainer(
                for: video,
                frameRate: 25,
                to: temporaryDirectory.appendingPathComponent("mpeg2-b-picture.ts")
            )
            XCTFail("Expected frameReorderingUnsupported")
        } catch let error as DicomVideoRemuxError {
            XCTAssertEqual(error, .frameReorderingUnsupported(codec: .mpeg2))
        }
    }

    func test_outputBudget_rejectsEveryContainerAndRemovesPartialOutput() async throws {
        for (index, video) in try budgetVideos().enumerated() {
            let output = temporaryDirectory.appendingPathComponent("limited-\(index)")
            do {
                try await DicomVideoRemuxer.writePlayableContainer(
                    for: video, frameRate: 2, to: output, maximumOutputBytes: 1)
                XCTFail("The limit must apply to every container path")
            } catch {
                XCTAssertEqual(error as? DicomVideoRemuxError, .outputBudgetExceeded(maximumBytes: 1))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func test_outputReservation_precedesWritesAndAbortsOnRejection() async throws {
        for (index, video) in try budgetVideos().enumerated() {
            let output = temporaryDirectory.appendingPathComponent("reservation-\(index)")
            let calls = Mutex(0)
            do {
                try await DicomVideoRemuxer.writePlayableContainer(
                    for: video, frameRate: 2, to: output, reserveOutputBytes: { bytes in
                        calls.withLock { $0 += 1 }
                        XCTAssertGreaterThan(bytes, 0)
                        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, 0,
                                       "The first reservation must run before any bytes reach disk")
                        throw DicomVideoRemuxError.writerFailed("reservation rejected")
                    })
                XCTFail("A rejected reservation must abort generation")
            } catch {
                XCTAssertEqual(error as? DicomVideoRemuxError, .writerFailed("reservation rejected"))
            }
            XCTAssertEqual(calls.withLock { $0 }, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    func test_outputBudget_exactSizeAllowsEveryContainerAndAccountsEveryWrite() async throws {
        for (index, video) in try budgetVideos().enumerated() {
            let baseline = temporaryDirectory.appendingPathComponent("baseline-\(index)")
            try await DicomVideoRemuxer.writePlayableContainer(for: video, frameRate: 2, to: baseline)
            let size = Int64(try Data(contentsOf: baseline).count)
            let output = temporaryDirectory.appendingPathComponent("exact-\(index)")
            let reserved = Mutex(Int64(0))
            try await DicomVideoRemuxer.writePlayableContainer(
                for: video, frameRate: 2, to: output, maximumOutputBytes: size, reserveOutputBytes: { bytes in
                    try reserved.withLock { total in
                        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
                        XCTAssertEqual((attributes[.size] as? NSNumber)?.int64Value, total)
                        total += bytes
                    }
                })
            XCTAssertEqual(Int64(try Data(contentsOf: output).count), size)
            XCTAssertEqual(reserved.withLock { $0 }, size)
        }
    }

    func test_outputBudget_removesPartiallyWrittenContainersWithoutExceedingLimit() async throws {
        for (index, video) in try budgetVideos().enumerated() {
            let baseline = temporaryDirectory.appendingPathComponent("partial-baseline-\(index)")
            try await DicomVideoRemuxer.writePlayableContainer(for: video, frameRate: 2, to: baseline)
            let limit = Int64(try Data(contentsOf: baseline).count) - 1
            let output = temporaryDirectory.appendingPathComponent("partial-\(index)")
            let reserved = Mutex(Int64(0))
            do {
                try await DicomVideoRemuxer.writePlayableContainer(
                    for: video, frameRate: 2, to: output, maximumOutputBytes: limit, reserveOutputBytes: { bytes in
                        reserved.withLock { total in
                            total += bytes
                            XCTAssertLessThanOrEqual(total, limit)
                        }
                    })
                XCTFail("The last block must be rejected before writing")
            } catch {
                XCTAssertEqual(error as? DicomVideoRemuxError, .outputBudgetExceeded(maximumBytes: limit))
            }
            if index > 0 { XCTAssertGreaterThan(reserved.withLock { $0 }, 0, "Exercise partial output cleanup") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }

    private func budgetVideos() throws -> [DicomVideo] {
        try [
            makeVideo(stream: Data([0, 0, 0, 12]) + Data("ftypisom".utf8),
                      transferSyntax: .mpeg4AVCH264HighProfileLevel41, width: 16, height: 16),
            makeVideo(fixtureBase64: Self.h264FixtureBase64,
                      transferSyntax: .mpeg4AVCH264HighProfileLevel41, width: 16, height: 16),
            makeVideo(fixtureBase64: Self.hevcFixtureBase64,
                      transferSyntax: .hevcH265MainProfileLevel51, width: 64, height: 64),
            makeVideo(fixtureBase64: Self.mpeg2FixtureBase64,
                      transferSyntax: .mpeg2MainProfileMainLevel, width: 64, height: 64)
        ]
    }

    private func firstH264SliceHeader(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 6 else { return nil }
        for index in 0...(bytes.count - 6) {
            let headerIndex: Int
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                headerIndex = index + 3
            } else if bytes[index] == 0,
                      bytes[index + 1] == 0,
                      bytes[index + 2] == 0,
                      bytes[index + 3] == 1 {
                headerIndex = index + 4
            } else {
                continue
            }
            let type = Int(bytes[headerIndex] & 0x1F)
            if (1...5).contains(type) {
                return headerIndex
            }
        }
        return nil
    }

    private func firstHEVCSliceHeader(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 7 else { return nil }
        for index in 0...(bytes.count - 7) {
            let headerIndex: Int
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                headerIndex = index + 3
            } else if bytes[index] == 0,
                      bytes[index + 1] == 0,
                      bytes[index + 2] == 0,
                      bytes[index + 3] == 1 {
                headerIndex = index + 4
            } else {
                continue
            }
            let type = Int((bytes[headerIndex] >> 1) & 0x3F)
            if (0...31).contains(type) {
                return headerIndex
            }
        }
        return nil
    }

    private func firstMPEG2PictureStart(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 6 else { return nil }
        for index in 0...(bytes.count - 6) where
            bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 && bytes[index + 3] == 0 {
            return index
        }
        return nil
    }

    private func makeVideo(
        fixtureBase64: String,
        transferSyntax: DicomTransferSyntax,
        width: Int,
        height: Int
    ) throws -> DicomVideo {
        makeVideo(
            stream: try XCTUnwrap(Data(base64Encoded: fixtureBase64)),
            transferSyntax: transferSyntax,
            width: width,
            height: height
        )
    }

    private func makeVideo(
        stream: Data,
        transferSyntax: DicomTransferSyntax,
        width: Int,
        height: Int
    ) -> DicomVideo {
        DicomVideo(
            sopClassUID: DicomVideo.videoEndoscopicImageStorageSOPClassUID,
            transferSyntaxUID: transferSyntax.rawValue,
            transferSyntax: transferSyntax,
            columns: width,
            rows: height,
            numberOfFrames: 2,
            streamData: stream,
            encapsulatedPixelDataDescriptor: DicomEncapsulatedPixelDataDescriptor(
                pixelDataOffset: 0,
                numberOfFrames: 2,
                basicOffsetTable: DicomBasicOffsetTable(offsets: [], byteRange: 0..<0),
                extendedOffsetTable: nil,
                fragments: [],
                frameFragmentIndexes: [],
                diagnostics: []
            )
        )
    }

    private func assertPlayable(_ outputURL: URL, expectedWidth: Int, expectedHeight: Int) async throws {
        let asset = AVURLAsset(url: outputURL)
        let isPlayable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(isPlayable)
        XCTAssertEqual(tracks.count, 1)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await generator.image(at: .zero)
        XCTAssertEqual(result.image.width, expectedWidth)
        XCTAssertEqual(result.image.height, expectedHeight)
    }

    private static let h264FixtureBase64 = [
        "AAAAAWdCwArd7ARAAAADAEAAAAMBI8SJ4AAAAAFozg8sgAAAAQYF//9a3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3Jl",
        "IDE2NSByMzIyMiBiMzU2MDVhIC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyNSAtIGh0",
        "dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0xOjA6",
        "MCBhbmFseXNlPTB4MToweDExMSBtZT1oZXggc3VibWU9NyBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0w",
        "IG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MSA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0",
        "X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0tMiB0aHJlYWRzPTEgbG9va2FoZWFkX3RocmVhZHM9MSBzbGljZWRfdGhy",
        "ZWFkcz0wIG5yPTAgZGVjaW1hdGU9MSBpbnRlcmxhY2VkPTAgYmx1cmF5X2NvbXBhdD0wIGNvbnN0cmFpbmVkX2ludHJh",
        "PTAgYmZyYW1lcz0wIHdlaWdodHA9MCBrZXlpbnQ9MSBrZXlpbnRfbWluPTEgc2NlbmVjdXQ9NDAgaW50cmFfcmVmcmVz",
        "aD0wIHJjPWNyZiBtYnRyZWU9MCBjcmY9MjMuMCBxY29tcD0wLjYwIHFwbWluPTAgcXBtYXg9NjkgcXBzdGVwPTQgaXBf",
        "cmF0aW89MS40MCBhcT0xOjEuMDAAgAAAAWWIhAS8RigACovHAAEo2OAAL62AAAAAAWdCwArd7ARAAAADAEAAAAMBI8SJ4",
        "AAAAAFozg8sgAAAAWWIggF/EYoAAyixwABOhjgADYNg"
    ].joined()

    private static let hevcFixtureBase64 = [
        "AAAAAUABDAH//wQIAAADAJ+oAAADAAAeugJAAAAAAUIBAQQIAAADAJ+oAAADAAAeoCCBBZbqSTK8BaAgAAADACAAAAMAQQAAA",
        "AFEAcFysCJAAAABKAGveOsCAf/t0f/2ZI/0N1RUecAAAAABQAEMAf//BAgAAAMAn6gAAAMAAB66AkAAAAABQgEBBAgAAAMAn6",
        "gAAAMAAB6gIIEFlupJMrwFoCAAAAMAIAAAAwBBAAAAAUQBwXKwIkAAAAEoAa8EeDwSmnn87f///te///4l5mWiWYj8"
    ].joined()

    private static let mpeg2FixtureBase64 = [
        "AAABswQAQBP//+AYAAABtRSKAAEAAAAAAbgACABAAAABAAAP//gAAAG1j//zQYAAAAEBE/lFKUv3C825SlIi5SlIi5SlIiAA",
        "AAECE/lFKUv3C825SlIi5SlIi5SlIiAAAAEDE/lFKUv3C825SlIi5SlIi5SlIiAAAAEEE/lFKUv3C825SlIi5SlIi5SlIiAA",
        "AAGzBABAE///4BgAAAG1FIoAAQAAAAABuAAIAMAAAAEAAA//+AAAAbWP//NBgAAAAQET+UUpS/cLzblKUiLlKUiLlKUiIAAAA",
        "QIT+UUpS/cLzblKUiLlKUiLlKUiIAAAAQMT+UUpS/cLzblKUiLlKUiLlKUiIAAAAQQT+UUpS/cLzblKUiLlKUiLlKUiIA=="
    ].joined()
}

// MARK: - MPEG-2 Program Stream and PES (issue #3013)

extension DicomVideoRemuxerTests {
    /// A PES packet with the MPEG-2 header (`10` marker) and an optional PTS; `unbounded` writes length 0.
    private func pes(_ streamID: UInt8, _ payload: [UInt8], pts: UInt64? = nil, unbounded: Bool = false) -> [UInt8] {
        var header: [UInt8] = [0x80, pts == nil ? 0x00 : 0x80, pts == nil ? 0 : 5]
        if let pts {
            header += [UInt8(0x21 | (pts >> 29) & 0x0E), UInt8((pts >> 22) & 0xFF), UInt8(((pts >> 14) & 0xFE) | 1),
                       UInt8((pts >> 7) & 0xFF), UInt8(((pts << 1) & 0xFE) | 1)]
        }
        let length = unbounded ? 0 : header.count + payload.count
        return [0, 0, 1, streamID, UInt8(length >> 8), UInt8(length & 0xFF)] + header + payload
    }

    /// An MPEG-2 pack header with two stuffing bytes.
    private var pack: [UInt8] { [0, 0, 1, 0xBA, 0x44, 0x00, 0x04, 0x00, 0x04, 0x01, 0x01, 0x89, 0xC3, 0xFA, 0xFF, 0xFF] }

    private func mpeg2Chunks() throws -> (stream: [UInt8], chunks: [[UInt8]]) {
        let stream = [UInt8](try XCTUnwrap(Data(base64Encoded: Self.mpeg2FixtureBase64)))
        let first = stream.count / 3, second = 2 * stream.count / 3
        return (stream, [Array(stream[..<first]), Array(stream[first..<second]), Array(stream[second...])])
    }

    func test_mpeg2ProgramStream_isDemuxedToItsVideoElementaryStreamAndPlays() async throws {
        let (stream, chunks) = try mpeg2Chunks()
        let systemHeader: [UInt8] = [0, 0, 1, 0xBB, 0, 9, 0x80, 0x00, 0x01, 0x04, 0xE1, 0xFF, 0xE0, 0xE0, 0x2E]
        // Audio carries a sequence header start code, and a second video stream another payload: both are dropped.
        let program = pack + systemHeader + pes(0xE0, chunks[0], pts: 3600)
            + pes(0xC0, [0, 0, 1, 0xB3, 0xAA, 0xBB], pts: 3600) + pes(0xBE, [UInt8](repeating: 0xFF, count: 8))
            + pack + pes(0xE0, chunks[1], pts: 7200) + pes(0xE1, [0, 0, 1, 0xB3, 0x01]) + pes(0xE0, chunks[2])
            + [0, 0, 1, 0xB9]
        XCTAssertEqual(try DicomMPEG2SystemsDemuxer.videoElementaryStream(from: Data(program)), Data(stream))

        let outputURL = temporaryDirectory.appendingPathComponent("mpeg2-ps.ts")
        let video = makeVideo(stream: Data(program), transferSyntax: .mpeg2MainProfileMainLevel, width: 64, height: 64)
        try await DicomVideoRemuxer.writePlayableContainer(for: video, frameRate: 25, to: outputURL)
        try await assertMPEG2TransportStreamPlays(outputURL, elementaryStream: Data(stream))
    }

    func test_mpeg2PESPackets_areDemuxedIncludingMPEG1HeadersAndAnUnboundedLastPacket() async throws {
        let (stream, chunks) = try mpeg2Chunks()
        // MPEG-1 PES header: two stuffing bytes, then 0x0F (no PTS or DTS).
        let mpeg1Header: [UInt8] = [0xFF, 0xFF, 0x0F]
        let mpeg1 = [0, 0, 1, 0xE0, UInt8((mpeg1Header.count + chunks[1].count) >> 8),
                     UInt8((mpeg1Header.count + chunks[1].count) & 0xFF)] + mpeg1Header + chunks[1]
        let packets = pes(0xE0, chunks[0], pts: 3600) + mpeg1 + pes(0xE0, chunks[2], unbounded: true)
        XCTAssertEqual(try DicomMPEG2SystemsDemuxer.videoElementaryStream(from: Data(packets)), Data(stream))

        let outputURL = temporaryDirectory.appendingPathComponent("mpeg2-pes.ts")
        let video = makeVideo(stream: Data(packets), transferSyntax: .mpeg2MainProfileMainLevel, width: 64, height: 64)
        try await DicomVideoRemuxer.writePlayableContainer(for: video, frameRate: 25, to: outputURL)
        try await assertMPEG2TransportStreamPlays(outputURL, elementaryStream: Data(stream))
    }

    func test_mpeg2SystemsStream_elementaryStreamsPassAndMalformedContainersFailTyped() throws {
        let (stream, chunks) = try mpeg2Chunks()
        XCTAssertNil(try DicomMPEG2SystemsDemuxer.videoElementaryStream(from: Data(stream)), "an elementary stream is unchanged")
        let truncated = Array(pes(0xE0, chunks[0]).dropLast(4))
        XCTAssertThrowsError(try DicomMPEG2SystemsDemuxer.videoElementaryStream(from: Data(truncated))) {
            XCTAssertEqual($0 as? DicomVideoRemuxError, .malformedSystemsStream)
        }
        XCTAssertThrowsError(try DicomMPEG2SystemsDemuxer.videoElementaryStream(from: Data(pack + pes(0xC0, [1, 2]) + [0, 0, 1, 0xB9]))) {
            XCTAssertEqual($0 as? DicomVideoRemuxError, .noVideoFrames(codec: .mpeg2))
        }
    }

    /// The remuxed Transport Stream plays and decodes a frame, so no packet header reached the access units.
    private func assertMPEG2TransportStreamPlays(_ outputURL: URL, elementaryStream: Data) async throws {
        let asset = AVURLAsset(url: outputURL)
        let isPlayable = try await asset.load(.isPlayable)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertTrue(isPlayable)
        XCTAssertEqual(tracks.count, 1)
        let expectedURL = temporaryDirectory.appendingPathComponent("expected-\(UUID().uuidString).ts")
        try await DicomVideoRemuxer.writePlayableContainer(
            for: makeVideo(stream: elementaryStream, transferSyntax: .mpeg2MainProfileMainLevel, width: 64, height: 64),
            frameRate: 25, to: expectedURL)
        XCTAssertEqual(try Data(contentsOf: outputURL), try Data(contentsOf: expectedURL),
                       "the container remuxes exactly like its elementary stream")
    }
}
