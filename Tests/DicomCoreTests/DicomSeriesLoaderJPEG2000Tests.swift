//
//  DicomSeriesLoaderJPEG2000Tests.swift
//  DicomCoreTests
//
//  Issue #3050: the full volume build decodes JPEG 2000 (.90/.91) and HTJ2K (.201) slices above 8 bits through the
//  stream's backend selection (the own DicomJPEG2000 codec), with the OpenJPEG runtime made unavailable through
//  DICOM_DECODER_OPENJPEG_LIBRARY_PATH. Voxels equal the samples written and the async frame reader's output.
//

import Darwin
import Foundation
import XCTest
@testable import DicomCore

final class DicomSeriesLoaderJPEG2000Tests: XCTestCase {
    private static let openJPEGPathKey = "DICOM_DECODER_OPENJPEG_LIBRARY_PATH"
    private static let rolloutKey = "DICOM_J2KSWIFT_MODE"
    private static let width = 16
    private static let height = 12
    private static let depth = 3

    private var savedEnvironment: [String: String?] = [:]

    override func setUp() {
        super.setUp()
        let environment = ProcessInfo.processInfo.environment
        savedEnvironment = [Self.openJPEGPathKey: environment[Self.openJPEGPathKey], Self.rolloutKey: environment[Self.rolloutKey]]
        setenv(Self.openJPEGPathKey, "/nonexistent/isis-3050-openjpeg.dylib", 1)
        unsetenv(Self.rolloutKey)
    }

    override func tearDown() {
        for (key, value) in savedEnvironment {
            if let value { setenv(key, value, 1) } else { unsetenv(key) }
        }
        super.tearDown()
    }

    func test_jpeg2000Lossless12BitSignedSeries_withoutOpenJPEG_equalsWrittenSamplesAndStream() async throws {
        try await assertFullBuild(syntax: .jpeg2000Lossless, precision: 12, signed: true, intent: .reversible, lossless: true)
    }

    func test_jpeg2000Reversible16BitSeries_withoutOpenJPEG_equalsWrittenSamplesAndStream() async throws {
        try await assertFullBuild(syntax: .jpeg2000, precision: 16, signed: false, intent: .reversible, lossless: true)
    }

    func test_jpeg2000Irreversible16BitSeries_withoutOpenJPEG_equalsStream() async throws {
        try await assertFullBuild(syntax: .jpeg2000, precision: 16, signed: false, intent: .irreversible(quality: 0.9),
                                  lossless: false)
    }

    func test_htj2kLossless12BitSignedSeries_withoutOpenJPEG_equalsWrittenSamplesAndStream() async throws {
        try await assertFullBuild(syntax: .htj2kLossless, precision: 12, signed: true, intent: .reversible, lossless: true)
    }

    func test_htj2kLossless16BitSeries_withoutOpenJPEG_equalsWrittenSamplesAndStream() async throws {
        try await assertFullBuild(syntax: .htj2kLossless, precision: 16, signed: false, intent: .reversible, lossless: true)
    }

    // MARK: - Assertion

    private func assertFullBuild(syntax: DicomTransferSyntax, precision: Int, signed: Bool, intent: DicomEncodingIntent,
                                 lossless: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertFalse(DicomCodecRuntimePreflight.status(for: .openJPEG).isAvailable,
                       "the override must leave the OpenJPEG runtime unavailable", file: file, line: line)
        let openJPEGImagesBefore = Self.loadedOpenJPEGImages()
        let (directory, written) = try await Self.makeSeries(syntax: syntax, precision: precision, signed: signed, intent: intent)
        defer { try? FileManager.default.removeItem(at: directory) }

        let volume = try Self.fullBuild(directory)
        let voxels = volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        XCTAssertEqual(volume.width, Self.width, file: file, line: line)
        XCTAssertEqual(volume.height, Self.height, file: file, line: line)
        XCTAssertEqual(volume.depth, Self.depth, file: file, line: line)
        XCTAssertEqual(volume.isSignedPixel, signed, file: file, line: line)

        var streamed = [Int16]()
        for slice in 0..<Self.depth {
            let url = directory.appendingPathComponent(Self.fileName(slice))
            let frame = try await DicomDecodedFrameReader(contentsOf: url).frame(at: 0)
            guard case .gray16(let pixels) = frame.pixels else {
                return XCTFail("\(syntax.rawValue): the stream decoded \(frame.pixels), expected 16-bit grey", file: file, line: line)
            }
            streamed += pixels.map { signed ? Int16(truncatingIfNeeded: Int32($0) + Int32(Int16.min)) : Int16(bitPattern: $0) }
        }
        XCTAssertEqual(voxels, streamed, "\(syntax.rawValue): the full build must equal the stream", file: file, line: line)
        if lossless {
            XCTAssertEqual(voxels, written.map { Int16(truncatingIfNeeded: $0) },
                           "\(syntax.rawValue): the full build must equal the samples written", file: file, line: line)
        } else {
            XCTAssertNotEqual(voxels, [Int16](repeating: 0, count: voxels.count), file: file, line: line)
        }
        XCTAssertEqual(Self.loadedOpenJPEGImages(), openJPEGImagesBefore,
                       "\(syntax.rawValue): the build must not load libopenjp2", file: file, line: line)
    }

    /// The synchronous full build (the async overload is a different entry point).
    private static func fullBuild(_ directory: URL) throws -> DicomSeriesVolume {
        try DicomSeriesLoader().loadSeries(in: directory)
    }

    // MARK: - Synthetic series (non-PHI)

    private static func fileName(_ slice: Int) -> String { String(format: "slice%03d.dcm", slice) }

    /// Writes a three-slice series and returns the stored samples in slice order.
    private static func makeSeries(syntax: DicomTransferSyntax, precision: Int, signed: Bool,
                                   intent: DicomEncodingIntent) async throws -> (URL, [Int]) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("series-3050-\(syntax.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = DicomCompressedFrameDescriptor(
            transferSyntaxUID: syntax.rawValue, rows: height, columns: width, bitsAllocated: 16, bitsStored: precision,
            highBit: precision - 1, pixelRepresentation: signed ? 1 : 0, samplesPerPixel: 1,
            photometricInterpretation: "MONOCHROME2", planarConfiguration: nil
        )
        let minimum = signed ? -(1 << (precision - 1)) : 0
        let maximum = signed ? (1 << (precision - 1)) - 1 : (1 << precision) - 1
        var written = [Int]()
        for slice in 0..<depth {
            let samples = (0..<(width * height)).map { index -> Int in
                let x = index % width, y = index / width
                let value = minimum + (x * 977 + y * 4093 + slice * 7919) % (maximum - minimum + 1)
                return min(max(value, minimum), maximum)
            }
            written += samples
            var stored = Data(capacity: samples.count * 2)
            for value in samples {
                let word = UInt16(truncatingIfNeeded: value)
                stored.append(UInt8(word & 0xFF))
                stored.append(UInt8(word >> 8))
            }
            let frame = DicomCodecDecodedFrame(buffer: .owned(stored), width: width, height: height,
                                               bitsPerSample: precision, componentCount: 1)
            let codestream = try await DicomJ2KSwiftBackend().encode(DicomFrameEncodeRequest(
                frame: frame, descriptor: descriptor, targetTransferSyntaxUID: syntax.rawValue, intent: intent
            ))
            var dataSet = EncapsulatedFixtureFactory.makeDataSet(
                transferSyntax: syntax, fragments: [codestream], declaredFrames: 1, rows: height, columns: width,
                bitsAllocated: 16, bitsStored: precision, highBit: precision - 1, pixelRepresentation: signed ? 1 : 0
            )
            let uid = "2.25.3050\(slice + 1)"
            dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([uid])))
            dataSet.set(DicomDataElement(tag: DicomTag.instanceNumber.rawValue, vr: .IS, value: .strings(["\(slice + 1)"])))
            dataSet.set(DicomDataElement(tag: DicomTag.imagePositionPatient.rawValue, vr: .DS,
                                         value: .strings(["0", "0", "\(slice * 2)"])))
            dataSet.set(DicomDataElement(tag: DicomTag.imageOrientationPatient.rawValue, vr: .DS,
                                         value: .strings(["1", "0", "0", "0", "1", "0"])))
            dataSet.set(DicomDataElement(tag: DicomTag.pixelSpacing.rawValue, vr: .DS, value: .strings(["0.5", "0.5"])))
            dataSet.set(DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["CT"])))
            let fileData = try DicomDataSetWriter.part10Data(from: dataSet, options: DicomPart10WriterOptions(
                transferSyntax: syntax,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: uid
            ))
            try fileData.write(to: directory.appendingPathComponent(fileName(slice)))
        }
        return (directory, written)
    }

    private static func loadedOpenJPEGImages() -> [String] {
        (0..<_dyld_image_count()).compactMap { index in
            _dyld_get_image_name(index).map { String(cString: $0) }
        }.filter { $0.contains("openjp2") }
    }
}
