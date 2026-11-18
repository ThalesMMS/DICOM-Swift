//
//  DicomSeriesLoaderCancellationTests.swift
//  DicomCoreTests
//
//  IsiX-DICOM-Viewer #3220: a host that builds a volume on a thread outside any task stops the load
//  through `shouldCancel`, within one slice per worker, and caps the workers that parse and decode
//  with `maxWorkers`.
//
//  Thales Matheus Mendonça Santos — November 2026
//

import Foundation
import XCTest
@testable import DicomCore
import DicomTestSupport

final class DicomSeriesLoaderCancellationTests: XCTestCase {
    private static let side = 4

    // MARK: - Single-frame series

    func test_parallelDecode_shouldCancelMidDecode_throwsCancellation_andDecodesAtMostOneSlicePerWorker() throws {
        let depth = 64
        let workers = 3
        let directory = try Self.makeSeriesDirectory(depth: depth)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = DecodeProbe(signalAfterDecodes: 5)

        XCTAssertThrowsError(try Self.loader(probe: probe, maxWorkers: workers).loadSeries(in: directory)) {
            XCTAssertTrue($0 is CancellationError, "got \($0)")
        }

        XCTAssertGreaterThanOrEqual(probe.decodes, 5)
        XCTAssertLessThanOrEqual(probe.decodesAfterSignal, workers, "each worker finishes at most the slice it holds")
        XCTAssertLessThan(probe.decodes, depth)
    }

    func test_sequentialDecode_shouldCancelMidDecode_stopsAfterTheCurrentSlice() throws {
        let depth = 16
        let directory = try Self.makeSeriesDirectory(depth: depth)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = DecodeProbe(signalAfterDecodes: 3)

        // A progress callback makes the decode sequential.
        XCTAssertThrowsError(try Self.loader(probe: probe).loadSeries(in: directory) { _, _, _, _ in }) {
            XCTAssertTrue($0 is CancellationError, "got \($0)")
        }

        XCTAssertEqual(probe.decodes, 3)
        XCTAssertEqual(probe.decodesAfterSignal, 0)
    }

    func test_concurrentParse_shouldCancelMidParse_throwsCancellation_beforeAnySliceDecodes() throws {
        let depth = 64
        let workers = 2
        let directory = try Self.makeSeriesDirectory(depth: depth)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = DecodeProbe(signalAfterParses: 4)

        XCTAssertThrowsError(try Self.loader(probe: probe, maxWorkers: workers).loadSeries(in: directory)) {
            XCTAssertTrue($0 is CancellationError, "got \($0)")
        }

        XCTAssertLessThanOrEqual(probe.parsesAfterSignal, workers, "each worker finishes at most the file it holds")
        XCTAssertLessThan(probe.parses, depth)
        XCTAssertEqual(probe.decodes, 0)
    }

    func test_maxWorkers_capsConcurrentParsesAndDecodes() throws {
        let depth = 32
        let directory = try Self.makeSeriesDirectory(depth: depth)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = DecodeProbe(holdEachCall: 0.005)

        let volume = try Self.loader(probe: probe, maxWorkers: 2).loadSeries(in: directory)

        XCTAssertEqual(volume.depth, depth)
        XCTAssertEqual(Self.voxels(of: volume), (0..<depth).flatMap { Self.slicePixels($0).map { Int16($0) } })
        XCTAssertLessThanOrEqual(probe.peakConcurrentParses, 2)
        XCTAssertLessThanOrEqual(probe.peakConcurrentDecodes, 2)
        if ProcessInfo.processInfo.activeProcessorCount >= 2 {
            XCTAssertEqual(probe.peakConcurrentDecodes, 2, "a cap of two still decodes two slices at once")
        }
    }

    func test_withoutShouldCancelOrCap_theLoadIsUnchanged() throws {
        let depth = 12
        let directory = try Self.makeSeriesDirectory(depth: depth)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = DecodeProbe()

        let volume = try DicomSeriesLoader(
            decoderFactory: { path in probe.makeDecoder(path: path) },
            logger: DicomLogger.make(subsystem: "com.dicomcore.tests", category: "cancellation")
        ).loadSeries(in: directory)

        XCTAssertEqual(Self.voxels(of: volume), (0..<depth).flatMap { Self.slicePixels($0).map { Int16($0) } })
        XCTAssertEqual(probe.decodes, depth)
    }

    // MARK: - Multi-frame objects

    func test_classicMultiframe_shouldCancelMidDecode_stopsBeforeTheNextFrame() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("classic-cancel-\(UUID()).dcm")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 8
        try Self.classicNuclearMedicineFile(frames: frames).write(to: url)
        XCTAssertEqual(try DicomSeriesLoader().loadClassicMultiframeVolume(at: url).depth, frames)
        let checks = CallCounter()

        // Frames decode one at a time, each after one check: the third check stops the load after two frames.
        let loader = DicomSeriesLoader(allocateVoxelData: { Data(count: $0) },
                                       shouldCancel: { checks.increment() >= 3 })
        XCTAssertThrowsError(try loader.loadClassicMultiframeVolume(at: url)) {
            XCTAssertTrue($0 is CancellationError, "got \($0)")
        }
        XCTAssertEqual(checks.count, 3, "no frame is checked, so none is decoded, after the signal")
    }

    func test_enhancedMultiframe_shouldCancelMidDecode_stopsBeforeTheNextFrame() throws {
        let frames = 6
        let url = try DicomEnhancedMultiframeVolumeTests.writeEnhancedObject(
            zPositions: (0..<frames).map(Double.init),
            frameIntercepts: Array(repeating: "0", count: frames),
            framePixelValues: (0..<frames).map { Array(repeating: Int16($0 + 1), count: 4) }
        )
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url).depth, frames)
        let checks = CallCounter()

        let loader = DicomSeriesLoader(allocateVoxelData: { Data(count: $0) },
                                       shouldCancel: { checks.increment() >= 3 })
        XCTAssertThrowsError(try loader.loadEnhancedMultiframeVolume(at: url)) {
            XCTAssertTrue($0 is CancellationError, "got \($0)")
        }
        XCTAssertEqual(checks.count, 3, "no frame is checked, so none is decoded, after the signal")
    }

    func test_enhancedMultiframeSelection_shouldCancelAfterAHostDecode_decodesNoFurtherFrame() throws {
        let frames = 6
        // One stack declared through a Dimension Organization, which a selection needs.
        let url = try DicomEnhancedMultiframeVolumeTests.writeEnhancedObject(
            zPositions: (0..<frames).map(Double.init),
            frameIntercepts: Array(repeating: "0", count: frames),
            framePixelValues: (0..<frames).map { Array(repeating: Int16($0 + 1), count: 4) },
            stackIDs: Array(repeating: "A", count: frames),
            frameDimensionIndexValues: (0..<frames).map { [1, UInt($0 + 1)] },
            inStackPositionNumbers: Array(1...frames)
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let groups = try XCTUnwrap(DCMDecoder(contentsOf: url).enhancedMultiframeFunctionalGroups)
        let selection = try XCTUnwrap(DicomEnhancedFramePartition.resolve(groups).first?.selection)
        let decodes = CallCounter()
        let signalled = LockedFlag()

        let loader = DicomSeriesLoader(allocateVoxelData: { Data(count: $0) },
                                       shouldCancel: { signalled.value })
        XCTAssertThrowsError(try loader.loadEnhancedMultiframeVolume(
            at: [url], selection: selection,
            decodeStoredFrame: { decoder, frameIndex in
                if decodes.increment() == 2 { signalled.set() }
                return try XCTUnwrap(decoder.getFrame(frameIndex)?.data)
            }
        )) {
            XCTAssertTrue($0 is CancellationError, "got \($0)")
        }
        XCTAssertEqual(decodes.count, 2, "the frame decoded when the signal came is the last one")
    }

    // MARK: - Fixtures

    private static func loader(probe: DecodeProbe, maxWorkers: Int? = nil) -> DicomSeriesLoader {
        DicomSeriesLoader(
            decoderFactory: { path in probe.makeDecoder(path: path) },
            logger: DicomLogger.make(subsystem: "com.dicomcore.tests", category: "cancellation"),
            shouldCancel: { probe.isSignalled },
            maxWorkers: maxWorkers
        )
    }

    /// Empty `.dcm` files: the probe's mock decoders stand for their contents, slice by file name.
    private static func makeSeriesDirectory(depth: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("series-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0..<depth {
            try Data().write(to: directory.appendingPathComponent(String(format: "slice%03d.dcm", index)))
        }
        return directory
    }

    fileprivate static func slicePixels(_ sliceIndex: Int) -> [UInt16] {
        (0..<(side * side)).map { UInt16(1 + sliceIndex * 100 + $0) }
    }

    fileprivate static func sliceIndex(of path: String) -> Int {
        Int(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.dropFirst("slice".count)) ?? 0
    }

    fileprivate static func mockSlice(_ sliceIndex: Int) -> MockDicomDecoder {
        let decoder = MockDicomDecoder()
        decoder.width = side
        decoder.height = side
        decoder.bitDepth = 16
        decoder.imagePosition = SIMD3(0, 0, Double(sliceIndex))
        decoder.imageOrientation = (row: SIMD3(1, 0, 0), column: SIMD3(0, 1, 0))
        decoder.setTag(DicomTag.modality.rawValue, value: "CT")
        decoder.setTag(DicomTag.sopInstanceUID.rawValue, value: "2.25.3220\(sliceIndex + 1)")
        decoder.setPixels16(slicePixels(sliceIndex))
        return decoder
    }

    private static func voxels(of volume: DicomSeriesVolume) -> [Int16] {
        volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// One NM object of 2×2 8-bit frames, which the classic multi-frame loader assembles in stored order.
    private static func classicNuclearMedicineFile(frames: Int) throws -> Data {
        let sopClass = DicomSOPClassGeometry.nuclearMedicineSOPClassUID
        func text(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement {
            .init(tag: tag.rawValue, vr: vr, value: .strings([value]))
        }
        func short(_ tag: DicomTag, _ value: UInt) -> DicomDataElement {
            .init(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value]))
        }
        let pixels = Data((0..<(frames * 4)).map { UInt8($0 + 1) })
        return try DicomDataSetWriter.part10Data(from: .init(elements: [
            text(.sopClassUID, .UI, sopClass), text(.sopInstanceUID, .UI, "2.25.32200001"),
            text(.numberOfFrames, .IS, "\(frames)"), text(.photometricInterpretation, .CS, "MONOCHROME2"),
            short(.rows, 2), short(.columns, 2), short(.samplesPerPixel, 1), short(.bitsAllocated, 8),
            short(.bitsStored, 8), short(.highBit, 7), short(.pixelRepresentation, 0),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(pixels))
        ]), options: .init(transferSyntax: .explicitVRLittleEndian, mediaStorageSOPClassUID: sopClass,
                           mediaStorageSOPInstanceUID: "2.25.32200001"))
    }
}

/// Counts the parses (decoder factory calls) and slice decodes (`getPixels16()` calls) a load makes, how many ran at
/// once, and how many began after the cancellation signal it raises once a set number have finished.
private final class DecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let signalAfterDecodes: Int?
    private let signalAfterParses: Int?
    private let holdEachCall: TimeInterval
    private var signalled = false
    private var parseCount = 0
    private var decodeCount = 0
    private var parsesStartedAfterSignal = 0
    private var decodesStartedAfterSignal = 0
    private var parsesInFlight = 0
    private var decodesInFlight = 0
    private var peakParses = 0
    private var peakDecodes = 0

    init(signalAfterDecodes: Int? = nil, signalAfterParses: Int? = nil, holdEachCall: TimeInterval = 0.002) {
        self.signalAfterDecodes = signalAfterDecodes
        self.signalAfterParses = signalAfterParses
        self.holdEachCall = holdEachCall
    }

    var isSignalled: Bool { lock.withLock { signalled } }
    var parses: Int { lock.withLock { parseCount } }
    var decodes: Int { lock.withLock { decodeCount } }
    var parsesAfterSignal: Int { lock.withLock { parsesStartedAfterSignal } }
    var decodesAfterSignal: Int { lock.withLock { decodesStartedAfterSignal } }
    var peakConcurrentParses: Int { lock.withLock { peakParses } }
    var peakConcurrentDecodes: Int { lock.withLock { peakDecodes } }

    func makeDecoder(path: String) -> MockDicomDecoder {
        lock.withLock {
            if signalled { parsesStartedAfterSignal += 1 }
            parsesInFlight += 1
            peakParses = max(peakParses, parsesInFlight)
        }
        Thread.sleep(forTimeInterval: holdEachCall)
        let decoder = DicomSeriesLoaderCancellationTests.mockSlice(DicomSeriesLoaderCancellationTests.sliceIndex(of: path))
        decoder.setPixels16AccessHandler { [self] in decode() }
        lock.withLock {
            parsesInFlight -= 1
            parseCount += 1
            if let signalAfterParses, parseCount >= signalAfterParses { signalled = true }
        }
        return decoder
    }

    private func decode() {
        lock.withLock {
            if signalled { decodesStartedAfterSignal += 1 }
            decodesInFlight += 1
            peakDecodes = max(peakDecodes, decodesInFlight)
        }
        Thread.sleep(forTimeInterval: holdEachCall)
        lock.withLock {
            decodesInFlight -= 1
            decodeCount += 1
            if let signalAfterDecodes, decodeCount >= signalAfterDecodes { signalled = true }
        }
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    /// Counts one more call and returns the count.
    func increment() -> Int {
        lock.withLock {
            calls += 1
            return calls
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool { lock.withLock { flag } }

    func set() { lock.withLock { flag = true } }
}
