//
//  DicomSeriesLoaderDecoderReleaseTests.swift
//  DicomCoreTests
//
//  Issue #3092: the full build kept every slice's decoder, with the file bytes it read and the pixel cache
//  `getPixels16()` fills, until the volume was returned, about two extra volumes on an uncompressed series. Each
//  decoder must now be released once its slice is copied, in the parallel build and in the sequential one, and the
//  loader's decoders map their files instead of copying them to the heap.
//

import Foundation
import ObjectiveC
import XCTest
@testable import DicomCore

final class DicomSeriesLoaderDecoderReleaseTests: XCTestCase {
    private static let side = 8

    func test_parallelFullBuild_releasesEachSliceDecoderBeforeTheVolumeIsComplete() throws {
        let depth = max(16, 4 * ProcessInfo.processInfo.activeProcessorCount)
        let directory = try Self.makeUnsignedSeries(depth: depth)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracker = DecoderLifetimeTracker(sliceSamples: Self.side * Self.side, depth: depth)

        let volume = try Self.loader(tracker: tracker).loadSeries(in: directory)

        XCTAssertEqual(Self.voxels(of: volume), Self.expectedVoxels(depth: depth))
        XCTAssertEqual(tracker.liveDecoders, 0)
        // A decoder kept until the end dies once every slice is written; one released after its own copy dies
        // while slices claimed later are still empty.
        XCTAssertGreaterThan(tracker.mostUnwrittenSlicesAtARelease, 0)
    }

    func test_sequentialFullBuild_releasesEachSliceDecoderOnceCopied() throws {
        let depth = 16
        let directory = try Self.makeUnsignedSeries(depth: depth)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracker = DecoderLifetimeTracker(sliceSamples: Self.side * Self.side, depth: depth)
        let liveAtProgress = LockedValues()

        let volume = try Self.loader(tracker: tracker).loadSeries(in: directory) { _, _, _, _ in
            liveAtProgress.append(tracker.liveDecoders)
        }

        XCTAssertEqual(Self.voxels(of: volume), Self.expectedVoxels(depth: depth))
        // After slice k is copied only the decoders of the slices still to decode remain.
        XCTAssertEqual(liveAtProgress.values, (0..<depth).map { depth - 1 - $0 })
    }

    func test_mappedSliceDecoder_readsWhatAHeapCopyReads() throws {
        let directory = try Self.makeUnsignedSeries(depth: 1)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("slice000.dcm").path

        let mapped = try DCMDecoder(mappingContentsOfFile: path)
        let copied = try DCMDecoder(contentsOfFile: path)

        XCTAssertEqual(mapped.getPixels16(), copied.getPixels16())
        XCTAssertEqual(mapped.info(for: .sopInstanceUID), copied.info(for: .sopInstanceUID))
        XCTAssertEqual(mapped.rescaleParametersV2, copied.rescaleParametersV2)
        XCTAssertThrowsError(try DCMDecoder(mappingContentsOfFile: path + ".missing"))
    }

    // MARK: - Fixtures

    private static func loader(tracker: DecoderLifetimeTracker) -> DicomSeriesLoader {
        DicomSeriesLoader(
            decoderFactory: { path in
                let decoder = try DCMDecoder(contentsOfFile: path)
                tracker.track(decoder)
                return decoder
            },
            logger: DicomLogger.make(subsystem: "com.dicomcore.tests", category: "decoder-release"),
            allocateVoxelData: { count in tracker.allocateVolume(byteCount: count) }
        )
    }

    /// Unsigned 12-of-16-bit Explicit VR Little Endian slices, as the Incisix CT stores them; no sample is zero, so
    /// an unwritten slice of the volume reads as zero.
    private static func makeUnsignedSeries(depth: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("series-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for sliceIndex in 0..<depth {
            var pixelData = Data()
            for value in sliceValues(sliceIndex) {
                pixelData.append(UInt8(truncatingIfNeeded: value))
                pixelData.append(UInt8(truncatingIfNeeded: value >> 8))
            }
            var dataSet = EncapsulatedFixtureFactory.makeDataSet(
                transferSyntax: .explicitVRLittleEndian, fragments: [], declaredFrames: 1,
                rows: side, columns: side, bitsAllocated: 16, bitsStored: 12, highBit: 11, pixelRepresentation: 0
            )
            dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixelData)))
            let uid = "2.25.3092000\(sliceIndex + 1)"
            dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([uid])))
            dataSet.set(DicomDataElement(tag: DicomTag.instanceNumber.rawValue, vr: .IS,
                                         value: .strings(["\(sliceIndex + 1)"])))
            dataSet.set(DicomDataElement(tag: DicomTag.imagePositionPatient.rawValue, vr: .DS,
                                         value: .strings(["0", "0", "\(sliceIndex)"])))
            dataSet.set(DicomDataElement(tag: DicomTag.imageOrientationPatient.rawValue, vr: .DS,
                                         value: .strings(["1", "0", "0", "0", "1", "0"])))
            dataSet.set(DicomDataElement(tag: DicomTag.pixelSpacing.rawValue, vr: .DS, value: .strings(["0.5", "0.5"])))
            dataSet.set(DicomDataElement(tag: DicomTag.rescaleIntercept.rawValue, vr: .DS, value: .strings(["-1024"])))
            dataSet.set(DicomDataElement(tag: DicomTag.rescaleSlope.rawValue, vr: .DS, value: .strings(["1"])))
            dataSet.set(DicomDataElement(tag: DicomTag.modality.rawValue, vr: .CS, value: .strings(["CT"])))
            let data = try DicomDataSetWriter.part10Data(
                from: dataSet,
                options: DicomPart10WriterOptions(
                    transferSyntax: .explicitVRLittleEndian,
                    mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                    mediaStorageSOPInstanceUID: uid
                )
            )
            try data.write(to: directory.appendingPathComponent(String(format: "slice%03d.dcm", sliceIndex)))
        }
        return directory
    }

    private static func sliceValues(_ sliceIndex: Int) -> [Int] {
        (0..<(side * side)).map { 1 + (sliceIndex * 37 + $0 * 11) % 4_095 }
    }

    private static func expectedVoxels(depth: Int) -> [Int16] {
        (0..<depth).flatMap { sliceValues($0).map(Int16.init) }
    }

    private static func voxels(of volume: DicomSeriesVolume) -> [Int16] {
        volume.voxels.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}

/// Counts the decoders the factory made that are still alive, and when one dies, how many slices of the volume the
/// loader writes are still empty.
private final class DecoderLifetimeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let sliceSamples: Int
    private let depth: Int
    private var live = 0
    private var mostUnwritten = 0
    private var volume: UnsafeMutablePointer<Int16>?
    nonisolated(unsafe) private static var sentinelKey: UInt8 = 0

    init(sliceSamples: Int, depth: Int) {
        self.sliceSamples = sliceSamples
        self.depth = depth
    }

    var liveDecoders: Int { lock.withLock { live } }
    var mostUnwrittenSlicesAtARelease: Int { lock.withLock { mostUnwritten } }

    func track(_ decoder: DCMDecoder) {
        lock.withLock { live += 1 }
        objc_setAssociatedObject(decoder, &Self.sentinelKey, ReleaseSentinel { [weak self] in self?.released() },
                                 .OBJC_ASSOCIATION_RETAIN)
    }

    func allocateVolume(byteCount: Int) -> Data {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: MemoryLayout<Int16>.alignment)
        pointer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        lock.withLock { volume = pointer.assumingMemoryBound(to: Int16.self) }
        return Data(bytesNoCopy: pointer, count: byteCount, deallocator: .custom { pointer, _ in pointer.deallocate() })
    }

    private func released() {
        lock.withLock {
            live -= 1
            guard let volume else { return }
            // Each slice's first sample is non-zero once written; the workers write whole slices.
            let unwritten = (0..<depth).filter { volume[$0 * sliceSamples] == 0 }.count
            mostUnwritten = max(mostUnwritten, unwritten)
        }
    }
}

private final class ReleaseSentinel {
    private let onRelease: () -> Void

    init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }

    deinit { onRelease() }
}

private final class LockedValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] { lock.withLock { storage } }

    func append(_ value: Int) { lock.withLock { storage.append(value) } }
}
