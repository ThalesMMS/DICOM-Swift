@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
@testable import DicomAppleMedia
import DicomCore
import XCTest

@MainActor
final class DicomH264ReorderingTests: XCTestCase {
    func test_closedGOPBFrames_preserveVisualOrderDurationSeekAndCapture() async throws {
        try await verifyPlayback(fixtureName: "known-bframes")
    }

    func test_highProfileBFrames_preserveVisualOrderDurationSeekAndCapture() async throws {
        try await verifyPlayback(fixtureName: "known-high-bframes")
    }

    func test_pFrames_preserveVisualOrderAndIndependentSeekPoints() async throws {
        try await verifyPlayback(fixtureName: "known-pframes")
    }

    func test_unqualifiedProfiles_failExplicitlyBeforeWriting() async throws {
        for name in ["unsupported-b-pyramid", "unsupported-weighted", "unsupported-interlaced", "unsupported-multislice", "unsupported-open-gop"] {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("unsupported-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try await DicomVideoRemuxer.writePlayableContainer(for: makeVideo(fixtureName: name), frameRate: 12, to: output)
                XCTFail("Unqualified profile was accepted: \(name)")
            } catch let error as DicomVideoRemuxError {
                XCTAssertEqual(error, .frameReorderingUnsupported(codec: .h264), name)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), name)
        }
    }

    private func makeVideo(fixtureName: String) throws -> DicomVideo {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: fixtureName, withExtension: "h264", subdirectory: "Fixtures"))
        return DicomVideo(
            sopClassUID: DicomVideo.videoEndoscopicImageStorageSOPClassUID,
            transferSyntaxUID: DicomTransferSyntax.mpeg4AVCH264HighProfileLevel41.rawValue,
            transferSyntax: .mpeg4AVCH264HighProfileLevel41, columns: 128, rows: 64, numberOfFrames: 96,
            streamData: try Data(contentsOf: fixture),
            encapsulatedPixelDataDescriptor: DicomEncapsulatedPixelDataDescriptor(
                pixelDataOffset: 0, numberOfFrames: 96,
                basicOffsetTable: DicomBasicOffsetTable(offsets: [], byteRange: 0..<0), extendedOffsetTable: nil,
                fragments: [], frameFragmentIndexes: [], diagnostics: []
            )
        )
    }

    private func verifyPlayback(fixtureName: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("h264-order-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = try makeVideo(fixtureName: fixtureName)
        let output = directory.appendingPathComponent("ordered.mp4")
        try await DicomVideoRemuxer.writePlayableContainer(for: video, frameRate: 12, to: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 8, accuracy: 0.001)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let packetReader = try AVAssetReader(asset: asset)
        let packets = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        packetReader.add(packets)
        XCTAssertTrue(packetReader.startReading())
        var syncFrames: [Int] = []
        var packetIndex = 0
        var encodedPictures: [Data] = []
        var previousDTS = -Double.infinity
        while let packet = packets.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(packet) > 0 else { continue }
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(packet))
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = try bytes.withUnsafeMutableBytes { destination in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: destination.count,
                                          destination: try XCTUnwrap(destination.baseAddress))
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            var offset = 0
            while offset + 4 <= bytes.count {
                let length = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
                offset += 4
                XCTAssertGreaterThan(length, 0)
                XCTAssertLessThanOrEqual(offset + length, bytes.count)
                guard length > 0, offset + length <= bytes.count else { break }
                let nal = bytes.subdata(in: offset..<(offset + length))
                if [1, 5].contains(Int(nal[0] & 31)) { encodedPictures.append(nal) }
                offset += length
            }
            let dts = CMSampleBufferGetDecodeTimeStamp(packet).seconds
            if dts.isFinite {
                XCTAssertGreaterThan(dts, previousDTS)
                previousDTS = dts
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(packet, createIfNecessary: false) as? [[String: Any]]
            if attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool != true {
                syncFrames.append(packetIndex)
            }
            packetIndex += CMSampleBufferGetNumSamples(packet)
        }
        XCTAssertEqual(packetIndex, 96)
        XCTAssertEqual(encodedPictures, annexBPictures(video.streamData), "Compressed picture bytes must not be re-encoded")
        XCTAssertEqual(syncFrames, [0, 48], "Only IDR pictures support independent random access")
        let reader = try AVAssetReader(asset: asset)
        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(decoded)
        XCTAssertTrue(reader.startReading())
        var frames: [Int] = []
        while let sample = decoded.copyNextSampleBuffer() {
            let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, Double(frames.count) / 12, accuracy: 0.001)
            frames.append(try barcode(pixels))
        }
        XCTAssertEqual(reader.status, .completed, String(describing: reader.error))
        XCTAssertEqual(frames, Array(0..<96), "Includes multiple POC wraps and the second IDR/GOP")

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for index in [95, 0, 1, 2, 3, 15, 16, 17, 47, 48, 49, 94] {
            let capture = try await generator.image(at: CMTime(value: Int64(index), timescale: 12))
            XCTAssertEqual(capture.actualTime.seconds, Double(index) / 12, accuracy: 0.001)
            XCTAssertEqual(try barcode(capture.image), index, "Exact random seek and adjacent-frame capture")
        }
    }

    private func annexBPictures(_ stream: Data) -> [Data] {
        let bytes = [UInt8](stream)
        var starts: [(Int, Int)] = []
        var offset = 0
        while offset + 3 <= bytes.count {
            if offset + 4 <= bytes.count, Array(bytes[offset..<(offset + 4)]) == [0, 0, 0, 1] {
                starts.append((offset, 4))
                offset += 4
            } else if Array(bytes[offset..<(offset + 3)]) == [0, 0, 1] {
                starts.append((offset, 3))
                offset += 3
            } else {
                offset += 1
            }
        }
        return starts.enumerated().compactMap { index, start in
            let begin = start.0 + start.1
            var end = index + 1 < starts.count ? starts[index + 1].0 : bytes.count
            while end > begin, bytes[end - 1] == 0 { end -= 1 } // Annex-B trailing_zero_8bits.
            guard end > begin, [1, 5].contains(Int(bytes[begin] & 31)) else { return nil }
            return Data(bytes[begin..<end])
        }
    }

    private func barcode(_ pixels: CVPixelBuffer) throws -> Int {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        XCTAssertEqual(CVPixelBufferGetWidth(pixels), 128)
        XCTAssertEqual(CVPixelBufferGetHeight(pixels), 64)
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        return (0..<8).reduce(0) { result, bit in
            result | (bytes[32 * stride + (bit * 16 + 8) * 4] > 128 ? 1 << bit : 0)
        }
    }

    private func barcode(_ image: CGImage) throws -> Int {
        var rgba = [UInt8](repeating: 0, count: 128 * 64 * 4)
        let valid = rgba.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: 128, height: 64, bitsPerComponent: 8,
                                          bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 64))
            return true
        }
        XCTAssertTrue(valid)
        return (0..<8).reduce(0) { result, bit in
            result | (rgba[32 * 128 * 4 + (bit * 16 + 8) * 4] > 128 ? 1 << bit : 0)
        }
    }
}
