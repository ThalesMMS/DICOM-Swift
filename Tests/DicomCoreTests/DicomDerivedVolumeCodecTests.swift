import CryptoKit
import Foundation
import XCTest
@testable import DicomCore

/// #2337: the own derived-volume container (per-slice reversible JPEG 2000 codestreams with Z-delta residuals).
final class DicomDerivedVolumeCodecTests: XCTestCase {
    func test_encodeSliceOfData_roundTripsEveryVoxel() async throws {
        let descriptor = DicomDerivedVolumeDescriptor(width: 4, height: 4, depth: 3, isSigned: true)
        let voxels = Self.volume(width: 4, height: 4, depth: 3, signed: true, noise: 1)
        let sliced = (Data(repeating: 99, count: 13) + voxels).dropFirst(13)
        XCTAssertEqual(sliced.startIndex, 13)
        let encoded = try await DicomDerivedVolumeCodec.encode(voxels: sliced, descriptor: descriptor)
        let decoded = try await DicomDerivedVolumeCodec.decode(encoded.data, expecting: descriptor)
        XCTAssertEqual(decoded, voxels)
    }

    func test_inspect_rejectsDimensionProductsThatOverflow() async throws {
        let descriptor = DicomDerivedVolumeDescriptor(width: 4, height: 4, depth: 5, isSigned: false)
        let encoded = try await DicomDerivedVolumeCodec.encode(
            voxels: Self.volume(width: 4, height: 4, depth: 5, signed: false, noise: 0), descriptor: descriptor)
        // Overflow the area, voxel count and byte count, respectively, without allocating those volumes.
        let dimensions: [(UInt32, UInt32)] = [(.max, .max), (1 << 31, 1 << 30), (1 << 30, 1 << 30)]
        for (width, height) in dimensions {
            var body = Data(encoded.data.dropLast(32))
            for (offset, value) in [(14, width), (18, height)] {
                body.replaceSubrange(offset..<(offset + 4), with: (0..<4).map {
                    UInt8(truncatingIfNeeded: value >> ($0 * 8))
                })
            }
            let hostile = body + Data(SHA256.hash(data: body))
            XCTAssertThrowsError(try DicomDerivedVolumeCodec.inspect(hostile)) { error in
                guard case DicomDerivedVolumeError.malformedContainer = error else { return XCTFail("\(error)") }
            }
        }
    }

    func test_containerSlice_roundTripsWithIndependentIndicesAndBoundedConcurrency() async throws {
        let descriptor = DicomDerivedVolumeDescriptor(width: 16, height: 16, depth: 3, isSigned: true)
        let voxels = Self.volume(width: 16, height: 16, depth: 3, signed: true, noise: 1)
        let encoded = try await DicomDerivedVolumeCodec.encode(voxels: voxels, descriptor: descriptor)
        let slice = (Data(repeating: 7, count: 13) + encoded.data).dropFirst(13)
        let streams = try DicomDerivedVolumeCodec.sliceCodestreams(slice)
        XCTAssertEqual(streams.map(\.codestream), try DicomDerivedVolumeCodec.sliceCodestreams(encoded.data).map(\.codestream))
        let decoded = try await DicomDerivedVolumeCodec.decode(slice, expecting: descriptor, maximumConcurrency: .max)
        XCTAssertEqual(decoded, voxels)
        XCTAssertEqual(DicomDerivedVolumeCodec.decodeWindowSliceCount(sliceByteCount: 32 * 1_024 * 1_024, depth: 100), 2)
        XCTAssertEqual(DicomDerivedVolumeCodec.decodeWindowSliceCount(sliceByteCount: 128 * 1_024 * 1_024, depth: 100), 1)
        XCTAssertEqual(DicomDerivedVolumeCodec.decodeWindowSliceCount(sliceByteCount: 2, depth: 3), 3)

        // A correctly signed tiny container must not reserve a hostile slice count.
        let headerLength = try XCTUnwrap(DicomDerivedVolumeCodec.parse(encoded.data).slices.first).range.lowerBound
        var body = Data(encoded.data.dropLast(32))
        for offset in [22, headerLength - descriptor.depth * 9 - 4] {
            body.replaceSubrange(offset..<(offset + 4), with: [UInt8](repeating: 255, count: 4))
        }
        let hostile = body + Data(SHA256.hash(data: body))
        XCTAssertThrowsError(try DicomDerivedVolumeCodec.inspect(hostile)) { error in
            guard case DicomDerivedVolumeError.malformedContainer = error else { return XCTFail("\(error)") }
        }
    }

    private static func volume(width: Int, height: Int, depth: Int, signed: Bool, noise: Int, seed: UInt32 = 9, extreme: Bool = false) -> Data {
        var state = seed
        var data = Data(capacity: width * height * depth * 2)
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    let jitter = noise > 0 ? Int(state >> 8) % noise - noise / 2 : 0
                    var value: Int
                    if extreme {
                        // Alternating extremes so slice differences overflow Int16.
                        value = (x + y + z) % 2 == 0 ? (signed ? -32768 : 0) : (signed ? 32767 : 65535)
                    } else {
                        // Anatomy-like content: a fixed in-plane texture (large, hard to compress) shared by every
                        // slice, plus a small slice-dependent drift and jitter, so residual coding has something to win.
                        var texture = UInt32(truncatingIfNeeded: x &* 73_856_093) ^ UInt32(truncatingIfNeeded: y &* 19_349_663) ^ seed
                        texture = texture &* 2_654_435_761
                        let base = signed ? -1024 : 100
                        value = base + Int(texture >> 8) % 1800 + z * 3 + jitter
                    }
                    let pattern = UInt16(truncatingIfNeeded: value)
                    data.append(UInt8(pattern & 0xFF))
                    data.append(UInt8(pattern >> 8))
                }
            }
        }
        return data
    }

    func test_roundTrip_correlatedVolumesUseResidualsAndReproduceEveryVoxel() async throws {
        let signed = DicomDerivedVolumeDescriptor(width: 300, height: 200, depth: 6, isSigned: true)
        let voxels = Self.volume(width: 300, height: 200, depth: 6, signed: true, noise: 6)
        let fingerprint = Data("series:7;transform:hu;instances:6".utf8)
        let encoded = try await DicomDerivedVolumeCodec.encode(voxels: voxels, descriptor: signed, sourceFingerprint: fingerprint)
        XCTAssertLessThan(encoded.data.count, voxels.count / 2, "real compression, not a byte copy")
        XCTAssertGreaterThan(encoded.info.residualSliceCount, 0, "correlated slices are coded as residuals under .auto")
        XCTAssertEqual(encoded.info.sliceCount, 6)
        XCTAssertEqual(encoded.info.sourceFingerprint, fingerprint)
        XCTAssertEqual(encoded.info.contentDigest, Data(SHA256.hash(data: voxels)))
        XCTAssertEqual(encoded.info.codecIdentifier, "dicom-swift.j2k-slice-stack")
        XCTAssertTrue(encoded.encoderConfiguration.contains("jpeg2000-part1-reversible-5/3"))
        let decoded = try await DicomDerivedVolumeCodec.decode(encoded.data, expecting: signed, sourceFingerprint: fingerprint)
        XCTAssertEqual(decoded, voxels)
        XCTAssertEqual(try DicomDerivedVolumeCodec.inspect(encoded.data), encoded.info)
        // Small slices stay raw under .auto, .always forces the probe, .never disables it; all bit exact.
        let small = DicomDerivedVolumeDescriptor(width: 33, height: 21, depth: 4, isSigned: false)
        let smallVoxels = Self.volume(width: 33, height: 21, depth: 4, signed: false, noise: 3)
        for (mode, expectResiduals) in [(DicomDerivedVolumeZDeltaMode.auto, false), (.always, true), (.never, false)] {
            let result = try await DicomDerivedVolumeCodec.encode(voxels: smallVoxels, descriptor: small, options: .init(zDelta: mode))
            XCTAssertEqual(result.info.residualSliceCount > 0, expectResiduals, "\(mode)")
            let result1 = try await DicomDerivedVolumeCodec.decode(result.data, expecting: small)
            XCTAssertEqual(result1, smallVoxels, "\(mode)")
        }
    }

    func test_shapesFallbacksAndSingleSliceVolumes() async throws {
        // Residuals that do not fit Int16 fall back to raw coding per slice, unconditionally lossless.
        let extremes = DicomDerivedVolumeDescriptor(width: 40, height: 30, depth: 5, isSigned: true)
        let extremeVoxels = Self.volume(width: 40, height: 30, depth: 5, signed: true, noise: 0, extreme: true)
        let forced = try await DicomDerivedVolumeCodec.encode(voxels: extremeVoxels, descriptor: extremes, options: .init(zDelta: .always))
        XCTAssertEqual(forced.info.residualSliceCount, 0)
        let result2 = try await DicomDerivedVolumeCodec.decode(forced.data, expecting: extremes)
        XCTAssertEqual(result2, extremeVoxels)
        let unsignedExtremes = DicomDerivedVolumeDescriptor(width: 40, height: 30, depth: 3, isSigned: false)
        let unsignedVoxels = Self.volume(width: 40, height: 30, depth: 3, signed: false, noise: 0, extreme: true)
        let unsignedForced = try await DicomDerivedVolumeCodec.encode(voxels: unsignedVoxels, descriptor: unsignedExtremes, options: .init(zDelta: .always))
        let result3 = try await DicomDerivedVolumeCodec.decode(unsignedForced.data, expecting: unsignedExtremes)
        XCTAssertEqual(result3, unsignedVoxels)
        // A single slice, odd dimensions, unsigned noisy content.
        let single = DicomDerivedVolumeDescriptor(width: 17, height: 9, depth: 1, isSigned: false)
        let singleVoxels = Self.volume(width: 17, height: 9, depth: 1, signed: false, noise: 4000)
        let encoded = try await DicomDerivedVolumeCodec.encode(voxels: singleVoxels, descriptor: single)
        let result4 = try await DicomDerivedVolumeCodec.decode(encoded.data, expecting: single)
        XCTAssertEqual(result4, singleVoxels)
        XCTAssertEqual(try DicomDerivedVolumeCodec.sliceCodestreams(encoded.data).count, 1)
        // Every slice codestream is a plain JPEG 2000 Part 1 codestream (SOC + SIZ), never a wrapper.
        for slice in try DicomDerivedVolumeCodec.sliceCodestreams(forced.data) {
            XCTAssertEqual(Array(slice.codestream.prefix(4)), [0xFF, 0x4F, 0xFF, 0x51])
        }
        // Declared shape must match the caller's expectation.
        do {
            _ = try await DicomDerivedVolumeCodec.encode(voxels: singleVoxels.dropLast(2), descriptor: single)
            XCTFail("a short buffer must be refused")
        } catch {
            guard case DicomDerivedVolumeError.unsupportedVolume = error else { return XCTFail("\(error)") }
        }
    }

    func test_corruptionVersionFingerprintAndDescriptorMismatchesFailTyped() async throws {
        let descriptor = DicomDerivedVolumeDescriptor(width: 48, height: 40, depth: 3, isSigned: true)
        let voxels = Self.volume(width: 48, height: 40, depth: 3, signed: true, noise: 2)
        let fingerprint = Data([1, 2, 3, 4])
        let encoded = try await DicomDerivedVolumeCodec.encode(voxels: voxels, descriptor: descriptor, sourceFingerprint: fingerprint,
                                                               options: .init(zDelta: .always))
        func resigned(_ data: Data) -> Data {
            let body = data.prefix(data.count - 32)
            return body + Data(SHA256.hash(data: body))
        }
        func failure(_ data: Data, expecting: DicomDerivedVolumeDescriptor = descriptor, fingerprint: Data? = nil) async -> DicomDerivedVolumeError? {
            do { _ = try await DicomDerivedVolumeCodec.decode(data, expecting: expecting, sourceFingerprint: fingerprint); return nil }
            catch let error as DicomDerivedVolumeError { return error }
            catch { return nil }
        }
        // A flipped payload byte breaks the container digest; with a re-signed trailer the slice CRC catches it.
        var flipped = encoded.data
        let payloadOffset = try DicomDerivedVolumeCodec.parse(encoded.data).slices[1].range.lowerBound + 40
        flipped[payloadOffset] ^= 0x5A
        let result5 = await failure(flipped)
        XCTAssertEqual(result5, .integrityFailure("container digest mismatch"))
        let result6 = await failure(resigned(flipped))
        XCTAssertEqual(result6, .integrityFailure("slice 1 CRC-32 mismatch"))
        // Truncation, a foreign version, garbage.
        // Truncation is caught by the container digest before any structure is trusted.
        let result7 = await failure(Data(encoded.data.prefix(encoded.data.count / 2)))
        XCTAssertEqual(result7, .integrityFailure("container digest mismatch"))
        let truncatedButResigned = await failure(resigned(Data(encoded.data.prefix(encoded.data.count / 2))))
        guard case .malformedContainer = truncatedButResigned else { return XCTFail("truncated: \(String(describing: truncatedButResigned))") }
        var versioned = encoded.data
        versioned[4] = 2
        let result8 = await failure(resigned(versioned))
        XCTAssertEqual(result8, .incompatibleContainerVersion(2))
        let result9 = await failure(Data(repeating: 0x41, count: 200))
        guard case .malformedContainer = result9 else { return XCTFail("garbage") }
        // Descriptor and fingerprint disagreements are refused before any slice is decoded.
        let mismatch = await failure(encoded.data, expecting: DicomDerivedVolumeDescriptor(width: 48, height: 40, depth: 3, isSigned: false))
        guard case .descriptorMismatch = mismatch else { return XCTFail("descriptor") }
        let result10 = await failure(encoded.data, fingerprint: Data([9]))
        XCTAssertEqual(result10, .fingerprintMismatch)
        let intact = try await DicomDerivedVolumeCodec.decode(encoded.data, expecting: descriptor, sourceFingerprint: fingerprint)
        XCTAssertEqual(intact, voxels)
        // A re-signed container whose content digest was altered fails on reconstruction, never returning voxels.
        var digestTampered = encoded.data
        let info = try DicomDerivedVolumeCodec.inspect(encoded.data)
        let digestRange = try XCTUnwrap(encoded.data.range(of: info.contentDigest))
        digestTampered[digestRange.lowerBound] ^= 0xFF
        let result11 = await failure(resigned(digestTampered))
        XCTAssertEqual(result11, .integrityFailure("reconstructed voxels do not match the container's content digest"))
        XCTAssertEqual(DicomDerivedVolumeError.fingerprintMismatch.errorDescription, "the derived volume was built from other sources or transformations")
    }

    func test_cancellationPropagatesFromEncodeAndDecode() async throws {
        let descriptor = DicomDerivedVolumeDescriptor(width: 256, height: 256, depth: 8, isSigned: true)
        let voxels = Self.volume(width: 256, height: 256, depth: 8, signed: true, noise: 50)
        let encodeTask = Task<Data, Error> { try await DicomDerivedVolumeCodec.encode(voxels: voxels, descriptor: descriptor).data }
        encodeTask.cancel()
        do {
            _ = try await encodeTask.value
            XCTFail("Cancelled encoding unexpectedly succeeded")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let encoded = try await DicomDerivedVolumeCodec.encode(voxels: voxels, descriptor: descriptor)
        let container = encoded.data
        let decodeTask = Task<Data, Error> { try await DicomDerivedVolumeCodec.decode(container, expecting: descriptor) }
        decodeTask.cancel()
        do {
            _ = try await decodeTask.value
            XCTFail("Cancelled decoding unexpectedly succeeded")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func test_openJPEGDecodesEverySliceCodestreamToTheSameSamples() async throws {
        let opj = URL(fileURLWithPath: "/opt/homebrew/bin/opj_decompress")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: opj.path), "opj_decompress is not installed")
        let descriptor = DicomDerivedVolumeDescriptor(width: 96, height: 80, depth: 4, isSigned: true)
        let voxels = Self.volume(width: 96, height: 80, depth: 4, signed: true, noise: 5)
        let encoded = try await DicomDerivedVolumeCodec.encode(voxels: voxels, descriptor: descriptor, options: .init(zDelta: .always))
        XCTAssertGreaterThan(encoded.info.residualSliceCount, 0)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("derived-volume-opj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sliceBytes = descriptor.sliceByteCount
        for (index, slice) in try DicomDerivedVolumeCodec.sliceCodestreams(encoded.data).enumerated() {
            let input = directory.appendingPathComponent("slice-\(index).j2k")
            let output = directory.appendingPathComponent("slice-\(index).rawl")
            try slice.codestream.write(to: input)
            let process = Process()
            process.executableURL = opj
            process.arguments = ["-i", input.path, "-o", output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "opj_decompress rejected slice \(index)")
            let decodedByOpenJPEG = try Data(contentsOf: output)
            let current = voxels.subdata(in: (index * sliceBytes)..<((index + 1) * sliceBytes))
            let expected: Data
            if slice.isResidual {
                let previous = voxels.subdata(in: ((index - 1) * sliceBytes)..<(index * sliceBytes))
                expected = try XCTUnwrap(DicomDerivedVolumeCodec.residualSlice(current: current, previous: previous, signed: true))
            } else {
                expected = current
            }
            XCTAssertEqual(decodedByOpenJPEG, expected, "slice \(index) (\(slice.isResidual ? "residual" : "raw")) differs in OpenJPEG")
        }
    }
}
