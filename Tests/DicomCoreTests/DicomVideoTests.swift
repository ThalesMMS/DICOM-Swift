import XCTest
@testable import DicomCore

final class DicomVideoTests: XCTestCase {
    func testSyntheticH264VideoRoundTripsStreamMetadataAndFramePayloads() throws {
        let firstFrame = Data([0x00, 0x00, 0x01, 0x65])
        let secondFrame = Data([0x00, 0x00, 0x01, 0x41])
        let sourceReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9710",
            referencedFrameNumbers: [1]
        )
        let pixelData = try DicomVideoPixelData(
            fragments: [firstFrame, secondFrame],
            transferSyntax: .mpeg4AVCH264HighProfileLevel41Fragmentable,
            columns: 640,
            rows: 480,
            numberOfFrames: 2,
            frameTimeMilliseconds: 33.333,
            cineRate: 30,
            recommendedDisplayFrameRate: 30
        )

        let decoder = try open(
            video: pixelData,
            options: DicomVideoBuildOptions(
                kind: .endoscopic,
                sopInstanceUID: "2.25.9700",
                studyInstanceUID: "2.25.9701",
                seriesInstanceUID: "2.25.9702",
                patientName: "Video^Patient",
                patientID: "VID-1",
                studyID: "VID-STUDY",
                studyDate: "20260529",
                studyTime: "120000",
                seriesNumber: 4,
                instanceNumber: 1,
                seriesDate: "20260529",
                seriesTime: "120100",
                seriesDescription: "Synthetic Video",
                contentDate: "20260529",
                contentTime: "120200",
                sourceImageReferences: [sourceReference]
            )
        )
        let video = try XCTUnwrap(decoder.video)

        XCTAssertEqual(video.kind, .endoscopic)
        XCTAssertEqual(video.sopClassUID, DicomVideo.videoEndoscopicImageStorageSOPClassUID)
        XCTAssertEqual(video.sopInstanceUID, "2.25.9700")
        XCTAssertEqual(video.studyInstanceUID, "2.25.9701")
        XCTAssertEqual(video.seriesInstanceUID, "2.25.9702")
        XCTAssertEqual(video.modality, "ES")
        XCTAssertEqual(video.patientName?.familyName, "Video")
        XCTAssertEqual(video.patientID, "VID-1")
        XCTAssertEqual(video.transferSyntax, .mpeg4AVCH264HighProfileLevel41Fragmentable)
        XCTAssertEqual(video.codec, .h264)
        XCTAssertEqual(video.columns, 640)
        XCTAssertEqual(video.rows, 480)
        XCTAssertEqual(video.numberOfFrames, 2)
        XCTAssertEqual(video.frameTimeMilliseconds, 33.333)
        XCTAssertEqual(video.cineRate, 30)
        XCTAssertEqual(video.recommendedDisplayFrameRate, 30)
        XCTAssertEqual(video.frameRate, 30)
        XCTAssertEqual(try XCTUnwrap(video.durationSeconds), 0.066666, accuracy: 0.00001)
        XCTAssertEqual(video.streamData, firstFrame + secondFrame)
        XCTAssertEqual(video.framePayload(at: 0), firstFrame)
        XCTAssertEqual(video.framePayload(at: 1), secondFrame)
        XCTAssertEqual(try video.encodedFramePayload(at: 0), firstFrame)
        XCTAssertEqual(video.sourceImageReferences, [sourceReference])
        XCTAssertEqual(video.lossyImageCompression, "01")
        XCTAssertEqual(video.lossyImageCompressionMethod, "ISO_14496_10")
    }

    func testStreamOnlyVideoPreservesLargeMultiFragmentStreamWithoutRetainingFrameCopies() throws {
        let fragments = (0..<64).map { index in
            Data(repeating: UInt8(index), count: 64 * 1_024)
        }
        let pixelData = try DicomVideoPixelData(
            fragments: fragments,
            transferSyntax: .mpeg4AVCH264HighProfileLevel41Fragmentable,
            columns: 1_920,
            rows: 1_080,
            numberOfFrames: fragments.count,
            recommendedDisplayFrameRate: 30
        )
        let decoder = try open(
            video: pixelData,
            options: DicomVideoBuildOptions(kind: .endoscopic)
        )

        let indexedVideo = try XCTUnwrap(decoder.video)
        let explicitIndexedVideo = try XCTUnwrap(decoder.video(payloadMode: .indexedFrames))
        let streamOnlyVideo = try XCTUnwrap(decoder.video(payloadMode: .streamOnly))
        let expectedStream = fragments.reduce(into: Data()) { $0.append($1) }

        XCTAssertEqual(indexedVideo, explicitIndexedVideo)
        XCTAssertEqual(streamOnlyVideo.streamData, expectedStream)
        XCTAssertEqual(streamOnlyVideo.streamData, indexedVideo.streamData)
        XCTAssertEqual(indexedVideo.indexedFramePayloads, fragments)
        XCTAssertEqual(streamOnlyVideo.indexedFramePayloads, [])
        XCTAssertEqual(
            streamOnlyVideo.encapsulatedPixelDataDescriptor,
            indexedVideo.encapsulatedPixelDataDescriptor
        )

        let indexedPayloadBytes = indexedVideo.streamData.count + indexedVideo.indexedFramePayloads.reduce(0) {
            $0 + $1.count
        }
        let streamOnlyPayloadBytes = streamOnlyVideo.streamData.count
        XCTAssertEqual(indexedPayloadBytes - streamOnlyPayloadBytes, expectedStream.count)
        XCTAssertThrowsError(try streamOnlyVideo.encodedFramePayload(at: 0)) { error in
            XCTAssertEqual(error as? DicomVideoError, .nativeFrameDecodeUnsupported(codec: "H.264"))
        }
    }

    func testHEVCVideoRoundTripsAsForwardableStreamWhenFramesAreNotIndividuallyIndexed() throws {
        let stream = Data([0x00, 0x00, 0x01, 0x40, 0x00, 0x00, 0x01, 0x26])
        let pixelData = try DicomVideoPixelData(
            streamData: stream,
            transferSyntax: .hevcH265MainProfileLevel51,
            columns: 1920,
            rows: 1080,
            numberOfFrames: 8,
            recommendedDisplayFrameRate: 24
        )

        let video = try XCTUnwrap(open(video: pixelData, options: DicomVideoBuildOptions(kind: .photographic)).video)

        XCTAssertEqual(video.kind, .photographic)
        XCTAssertEqual(video.codec, .hevc)
        XCTAssertEqual(video.streamData, stream)
        XCTAssertEqual(video.indexedFramePayloads, [])
        XCTAssertEqual(video.frameRate, 24)
        XCTAssertEqual(try XCTUnwrap(video.durationSeconds), 8.0 / 24.0, accuracy: 0.00001)
    }

    func testBuilderRejectsUnsupportedTransferSyntax() throws {
        XCTAssertThrowsError(
            try DicomVideoPixelData(
                streamData: Data([0x01]),
                transferSyntax: .jpegBaseline,
                columns: 2,
                rows: 2,
                numberOfFrames: 1
            )
        ) { error in
            XCTAssertEqual(error as? DicomVideoError, .unsupportedTransferSyntax(DicomTransferSyntax.jpegBaseline.rawValue))
        }
    }

    func testVideoScopeDistinguishesStreamForwardingDecodeTranscodeAndRenderedFrames() throws {
        let stream = Data([0x00, 0x00, 0x01, 0x65])
        let pixelData = try DicomVideoPixelData(
            streamData: stream,
            transferSyntax: .mpeg4AVCH264HighProfileLevel41,
            columns: 640,
            rows: 480,
            numberOfFrames: 1,
            recommendedDisplayFrameRate: 30
        )
        let video = try XCTUnwrap(open(video: pixelData, options: DicomVideoBuildOptions(kind: .endoscopic)).video)

        XCTAssertEqual(video.streamData, stream)
        XCTAssertEqual(try video.transcodeStream(to: .mpeg4AVCH264HighProfileLevel41), stream)
        XCTAssertThrowsError(try video.decodedFrame(at: 0)) { error in
            XCTAssertEqual(error as? DicomVideoError, .nativeFrameDecodeUnsupported(codec: "H.264"))
        }
        XCTAssertThrowsError(try video.encodedFramePayload(at: 3)) { error in
            XCTAssertEqual(error as? DicomVideoError, .invalidFrameIndex(index: 3, frameCount: 1))
        }
        XCTAssertThrowsError(try video.transcodeStream(to: .hevcH265MainProfileLevel51)) { error in
            XCTAssertEqual(
                error as? DicomVideoError,
                .transcodingUnsupported(
                    source: DicomTransferSyntax.mpeg4AVCH264HighProfileLevel41.rawValue,
                    destination: DicomTransferSyntax.hevcH265MainProfileLevel51.rawValue
                )
            )
        }

        let row = try XCTUnwrap(DicomExportSupportMatrix.packageDefault.row(feature: "Video"))
        XCTAssertTrue(row.payloadRules.contains("player handoff"))
        XCTAssertTrue(row.unsupportedCases.contains("server-side DICOMweb rendered frames"))
        XCTAssertTrue(row.typedFailure.contains("DICOMWEB_RENDERED_FRAME_UNSUPPORTED"))
    }

    func testVideoWriterUsesUndefinedLengthEncapsulatedPixelData() throws {
        let pixelData = try DicomVideoPixelData(
            streamData: Data([0x00, 0x00, 0x01, 0xB3]),
            transferSyntax: .mpeg2MainProfileMainLevel,
            columns: 320,
            rows: 240,
            numberOfFrames: 1
        )
        let data = try DicomVideoBuilder.part10Data(video: pixelData)
        let pixelDataHeader = Data([0xE0, 0x7F, 0x10, 0x00, 0x4F, 0x42, 0x00, 0x00])
        let range = try XCTUnwrap(data.range(of: pixelDataHeader))
        let lengthOffset = range.upperBound

        XCTAssertEqual(readUInt32LittleEndian(data, at: lengthOffset), UInt32.max)
        XCTAssertEqual(Array(data[(lengthOffset + 4)..<(lengthOffset + 8)]), [0xFE, 0xFF, 0x00, 0xE0])
        XCTAssertNotNil(data.range(of: Data(DicomTransferSyntax.mpeg2MainProfileMainLevel.rawValue.utf8)))
    }

    func testSeriesLoaderSkipsVideoAsNonImageVolumeInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("video_series_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("video.dcm")
        let pixelData = try DicomVideoPixelData(
            streamData: Data([0x00, 0x00, 0x01, 0x65]),
            columns: 64,
            rows: 64,
            numberOfFrames: 1
        )
        try DicomVideoBuilder.write(video: pixelData, to: url)

        XCTAssertThrowsError(try DicomSeriesLoader().loadSeries(in: directory)) { error in
            guard case DicomSeriesLoaderError.noDicomFiles = error else {
                return XCTFail("Expected noDicomFiles after skipping Video, got \(error)")
            }
        }
    }

    func testTransferSyntaxRegistryClassifiesVideoCodecs() throws {
        let registry = DicomTransferSyntaxRegistry.standard
        let mpeg2 = try XCTUnwrap(registry.entry(for: .mpeg2MainProfileMainLevel))
        let h264 = try XCTUnwrap(registry.entry(for: .mpeg4AVCH264HighProfileLevel41))
        let hevc = try XCTUnwrap(registry.entry(for: .hevcH265Main10ProfileLevel51))

        XCTAssertEqual(mpeg2.codec, .mpeg2)
        XCTAssertEqual(h264.codec, .h264)
        XCTAssertEqual(hevc.codec, .hevc)
        XCTAssertTrue(mpeg2.isEncapsulated)
        XCTAssertTrue(h264.syntax.isVideoTransferSyntax)
        XCTAssertTrue(hevc.isLossy)
    }

    private func open(
        video: DicomVideoPixelData,
        options: DicomVideoBuildOptions
    ) throws -> DCMDecoder {
        let data = try DicomVideoBuilder.part10Data(video: video, options: options)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("video_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func readUInt32LittleEndian(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }
}
