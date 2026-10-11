import DicomJPEG2000
import Foundation
import XCTest
@testable import DicomCore

/// Issue #3040: JPEG 2000 `.90/.91` multiframe objects with an empty Basic Offset Table, no Extended Offset Table
/// and more fragments than frames, indexed over `DicomByteSource` by incremental codestream framing. The independent
/// codestreams are the OpenJPEG 2.5.4 JPIP fixtures (`Tests/Fixtures/JPIP`, lossless, source formula in
/// `Scripts/interop/README.md`) and the OpenJPEG 2.5.0 lossy codestream of the coherence corpus with its
/// `opj_decompress` 2.5.4 reference; provenance and hashes are in `Docs/QA/SelectiveFrameSessions.md`.
@MainActor
final class DicomJ2KFrameBoundaryScannerTests: XCTestCase {
    private struct Image {
        let rows: Int
        let columns: Int
        let samples: Int
        let photometric: String

        static let jpip = Image(rows: 64, columns: 64, samples: 3, photometric: "YBR_RCT")
        static let own = Image(rows: 29, columns: 37, samples: 1, photometric: "MONOCHROME2")
        static let lossy = Image(rows: 32, columns: 32, samples: 1, photometric: "MONOCHROME2")
    }

    private static let orders = ["LRCP", "RLCP", "RPCL", "PCRL", "CPRL"]

    // MARK: - Session, order, bytes and metadata

    func test_emptyBOTFragmentedJPEG2000_previouslyRefusedNowServesFirstMiddleLastFrames() async throws {
        for (syntax, lossless) in [(DicomTransferSyntax.jpeg2000Lossless, true), (.jpeg2000, false)] {
            let (codestreams, pixels) = try await ownCodestreams(count: 5, lossless: lossless)
            let frames = codestreams.map { fragments($0, sizes: [6, 2, 10, 4]) }
            let part10 = try part10Data(frames, image: .own, syntax: syntax)
            let source = DicomByteSource(data: part10)
            let session = try await DicomSourceFrameSession.open(source: source)
            let layout = try XCTUnwrap(session.index.encapsulatedLayout)
            XCTAssertTrue(layout.basicOffsetTable.isEmpty)
            XCTAssertNil(layout.extendedOffsetTable)
            XCTAssertGreaterThan(layout.fragments.count, 5)

            // The JPEG/JPEG-LS scanner that indexed this branch before refuses the same fragments.
            do {
                _ = try await DicomJPEGFrameBoundaryScanner.map(
                    source: source, fragments: layout.fragments, numberOfFrames: 5, syntax: syntax,
                    maximumScanBytes: .max)
                XCTFail("Previous refusal not reproduced for \(syntax)")
            } catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .ambiguousFrameBoundaries) }

            var first = 0
            for (frame, fragmentsOfFrame) in frames.enumerated() {
                XCTAssertEqual(layout.frameFragmentIndexes[frame], Array(first..<(first + fragmentsOfFrame.count)))
                first += fragmentsOfFrame.count
            }
            XCTAssertEqual(session.index.frameCount, 5)
            XCTAssertEqual(session.index.metadata.transferSyntax, syntax)
            // Full own decode of the same codestreams, one fragment per frame. (The in-memory parser's marker
            // grouping does not see an EOC split across fragments, as `[6, 2, 10, 4]` produces here.)
            let whole = try part10Data(codestreams.map { fragments($0, sizes: [1 << 20]) }, image: .own, syntax: syntax)
            let reference = try DicomDecodedFrameReader(decoder: DCMDecoder(data: whole))
            for frame in [4, 0, 2] {
                let raw = try await session.frameData(at: frame)
                XCTAssertEqual(raw, frames[frame].reduce(Data(), +), "\(syntax) frame \(frame)")
                let decoded = try await session.frame(at: frame)
                let full = try await reference.frame(at: frame)
                XCTAssertEqual(decoded.index, frame)
                XCTAssertEqual(decoded.metadata.frameCount, 5)
                XCTAssertEqual(decoded.metadata.width, 37)
                XCTAssertEqual(decoded.metadata.height, 29)
                XCTAssertEqual(decoded.metadata.transferSyntaxUID, syntax.rawValue)
                XCTAssertEqual(decoded.pixels, full.pixels, "\(syntax) frame \(frame) differs from the full own decode")
                if lossless { XCTAssertEqual(decoded.pixels, .gray8(pixels[frame])) }
            }
            await session.close()
        }
    }

    // MARK: - Independent references

    func test_independentOpenJPEGCodestreams_decodeLosslessToTheirSourceInEveryFrame() async throws {
        let codestreams = try Self.orders.map(jpip)
        let expected = jpipPixels()
        for syntax in [DicomTransferSyntax.jpeg2000Lossless, .jpeg2000] {
            let frames = codestreams.map { fragments($0, sizes: [1000, 2, 334]) }
            let part10 = try part10Data(frames, image: .jpip, syntax: syntax)
            let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: part10))
            let reference = try DicomDecodedFrameReader(decoder: DCMDecoder(data: part10))
            for frame in 0..<5 {
                let raw = try await session.frameData(at: frame)
                XCTAssertEqual(raw, frames[frame].reduce(Data(), +))
                let decoded = try await session.frame(at: frame)
                XCTAssertEqual(decoded.pixels, .rgb8(interleaved: expected), "\(syntax) \(Self.orders[frame])")
                let full = try await reference.frame(at: frame)
                XCTAssertEqual(decoded.pixels, full.pixels)
                // The own codec itself, not an OpenJPEG fallback, reproduces the source samples.
                let own = try await DicomJ2KSwiftBackend().decode(request(raw, image: .jpip, syntax: syntax))
                XCTAssertEqual(Array(own.buffer.data), expected, "\(syntax) \(Self.orders[frame])")
            }
            await session.close()
        }
    }

    func test_independentLossyCodestream_ownDecodeStaysWithinApprovedLossyGateOfOpenJPEG() async throws {
        let codestream = try corpusFile("j2k-mono8-lossy.j2k")
        let openJPEG = try pgmSamples(corpusFile("j2k-mono8-lossy.openjpeg-2.5.4.pgm"))
        XCTAssertEqual(openJPEG.count, 32 * 32)
        let frames = (0..<3).map { _ in fragments(codestream, sizes: [64, 2]) }
        let part10 = try part10Data(frames, image: .lossy, syntax: .jpeg2000)
        let session = try await DicomSourceFrameSession.open(source: DicomByteSource(data: part10))
        let reference = try DicomDecodedFrameReader(decoder: DCMDecoder(data: part10))
        for frame in 0..<3 {
            let raw = try await session.frameData(at: frame)
            let own = try await DicomJ2KSwiftBackend().decode(request(raw, image: .lossy, syntax: .jpeg2000))
            let decoded = try await session.frame(at: frame)
            let full = try await reference.frame(at: frame)
            XCTAssertEqual(decoded.pixels, full.pixels)
            XCTAssertEqual(decoded.pixels, .gray8(Array(own.buffer.data)))
            // DICOMSwiftLossyDecodeGate, JPEG 2000 irreversible: largest difference 2, RMSE 0.5 (issue #2811).
            let differences = zip(own.buffer.data, openJPEG).map { abs(Int($0) - Int($1)) }
            XCTAssertLessThanOrEqual(differences.max() ?? .max, 2)
            let rmse = (Double(differences.reduce(0) { $0 + $1 * $1 }) / Double(differences.count)).squareRoot()
            XCTAssertLessThanOrEqual(rmse, 0.5)
        }
        await session.close()
    }

    // MARK: - Chunks, fragments and apparent markers

    func test_chunkAndFragmentBoundaries_skipApparentMarkersInsideLengthDelimitedPayloads() async throws {
        let codestreams = try ["LRCP", "RPCL", "CPRL"].map { try withComments(jpip($0)) }
        for sizes in [[2], [4, 10, 6], [7882]] {
            let frames = codestreams.map { fragments($0, sizes: sizes) }
            let encapsulated = encapsulated(frames)
            for readLimit in [8, 9, 13, 256, 65536] {
                let source = DicomByteSource(data: encapsulated, limits: .init(maximumReadBytes: readLimit))
                let layout = try await parse(source, frames: 3, syntax: .jpeg2000Lossless)
                var first = 0
                for (frame, fragmentsOfFrame) in frames.enumerated() {
                    XCTAssertEqual(layout.frameFragmentIndexes[frame], Array(first..<(first + fragmentsOfFrame.count)),
                                   "sizes \(sizes), read limit \(readLimit)")
                    first += fragmentsOfFrame.count
                }
            }
        }
        // The commented codestreams still decode to the source samples.
        let frames = codestreams.map { fragments($0, sizes: [1000]) }
        let session = try await DicomSourceFrameSession.open(
            source: DicomByteSource(data: part10Data(frames, image: .jpip, syntax: .jpeg2000Lossless)))
        for frame in 0..<3 {
            let decoded = try await session.frame(at: frame)
            XCTAssertEqual(decoded.pixels, .rgb8(interleaved: jpipPixels()))
        }
        await session.close()

        // Delimiters inside a segment payload and inside Psot-delimited tile data are never read as markers.
        let fake: [UInt8] = [0xFF, 0xD9, 0xFF, 0x4F, 0xFF, 0x90, 0, 10, 0xFF, 0x93, 0xFF, 0x51]
        let synthetic = syntheticCodestream(tileData: [fake, fake + [1, 2]])
        let source = DicomByteSource(data: encapsulated([synthetic, synthetic].map { fragments($0, sizes: [2]) }))
        let layout = try await parse(source, frames: 2, syntax: .jpeg2000)
        XCTAssertEqual(layout.frameFragmentIndexes.map(\.count), [(synthetic.count + 1) / 2, (synthetic.count + 1) / 2])
    }

    func test_zeroPsotLastTilePart_isScannedToEOCThroughSOPAndEPH() async throws {
        let (codestreams, pixels) = try await ownCodestreams(count: 3, lossless: true)
        let zeroed = try codestreams.map(withZeroLastPsot)
        let frames = zeroed.map { fragments($0, sizes: [10, 2]) }
        let session = try await DicomSourceFrameSession.open(
            source: DicomByteSource(data: part10Data(frames, image: .own, syntax: .jpeg2000Lossless)))
        for frame in [2, 0, 1] {
            let decoded = try await session.frame(at: frame)
            XCTAssertEqual(decoded.pixels, .gray8(pixels[frame]))
        }
        await session.close()

        // Nsop 0xFFD9 and EPH inside the scanned data do not end the frame.
        let stream: [UInt8] = [1, 0xFF, 0x7F, 0xFF, 0x91, 0, 4, 0xFF, 0xD9, 2, 0xFF, 0x92, 3]
        let synthetic = syntheticCodestream(tileData: [[9, 9], stream], zeroLastPsot: true)
        let source = DicomByteSource(data: encapsulated([synthetic, synthetic].map { fragments($0, sizes: [4]) }))
        let layout = try await parse(source, frames: 2, syntax: .jpeg2000)
        XCTAssertEqual(layout.frameFragmentIndexes.count, 2)
        // A later tile-part or a marker that packet data cannot hold is ambiguous after Psot 0.
        for bad: [UInt8] in [[1, 0xFF, 0x90, 0], [1, 0xFF, 0xFF, 0], [1, 0xFF, 0x93, 0]] {
            let invalid = syntheticCodestream(tileData: [bad], zeroLastPsot: true)
            try await assertRefused(encapsulated([invalid, invalid].map { fragments($0, sizes: [4]) }), frames: 2,
                                    .ambiguousFrameBoundaries)
        }
    }

    // MARK: - Typed refusals

    func test_truncationCountAndPadding_failTypedWithoutPublishingFrames() async throws {
        let synthetic = syntheticCodestream(tileData: [[1, 2, 3], [4, 5, 6, 7, 8]])
        for cut in 0..<synthetic.count {
            let frames = [synthetic, synthetic, synthetic.prefix(cut)].map { fragments(Data($0), sizes: [4]) }
            try await assertRefused(encapsulated(frames.filter { !$0.isEmpty }), frames: 3, nil, "cut \(cut)")
        }
        let valid = encapsulated([synthetic, synthetic, synthetic].map { fragments($0, sizes: [4]) })
        for count in [2, 4] { try await assertRefused(valid, frames: count, .ambiguousFrameBoundaries) }

        // One pad byte of any value completes an odd codestream; more is refused.
        XCTAssertEqual(synthetic.count % 2, 1)
        for pad in [UInt8(0), 0xFF, 0x5A] {
            let padded = encapsulated([fragments(synthetic, sizes: [6], pad: pad), fragments(synthetic, sizes: [6])])
            let layout = try await parse(DicomByteSource(data: padded), frames: 2, syntax: .jpeg2000Lossless)
            XCTAssertEqual(layout.frameFragmentIndexes.count, 2)
        }
        let even = syntheticCodestream(tileData: [[1, 2, 3]])
        XCTAssertEqual(even.count % 2, 0)
        try await assertRefused(encapsulated([fragments(even + Data([0, 0]), sizes: [4]), fragments(even, sizes: [4])]),
                                frames: 2, .invalidPadding)
        // Two codestreams sharing one fragment, or a trailing fragment after the last frame.
        try await assertRefused(encapsulated([[even + even]]), frames: 2, .invalidPadding)
        try await assertRefused(encapsulated([[even], [even], [Data([0, 0])]]), frames: 2, .ambiguousFrameBoundaries)

        // Psot shorter than SOT plus SOD, shorter or longer than its tile-part, or running past the frame.
        for psot in [UInt32(13), 14, 16, 18, 200] {
            var patched = [UInt8](even)
            let sot = try XCTUnwrap(tileParts(Data(patched)).first).sot
            patched.replaceSubrange((sot + 6)..<(sot + 10), with: bigEndian(psot))
            try await assertRefused(encapsulated([fragments(Data(patched), sizes: [4]), fragments(even, sizes: [4])]),
                                    frames: 2, nil, "Psot \(psot)")
        }

        // Session level: a truncated real codestream opens no session, so no frame is published.
        let (codestreams, _) = try await ownCodestreams(count: 3, lossless: true)
        let truncated = [codestreams[0], codestreams[1], codestreams[2].prefix(codestreams[2].count - 40)]
        let part10 = try part10Data(truncated.map { fragments(Data($0), sizes: [8]) }, image: .own,
                                    syntax: .jpeg2000Lossless)
        do {
            _ = try await DicomSourceFrameSession.open(source: DicomByteSource(data: part10))
            XCTFail("Truncated codestream indexed")
        } catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .ambiguousFrameBoundaries) }
        let mismatched = try part10Data(codestreams.map { fragments($0, sizes: [8]) }, image: .own,
                                        syntax: .jpeg2000Lossless, numberOfFrames: 4)
        do {
            _ = try await DicomSourceFrameSession.open(source: DicomByteSource(data: mismatched))
            XCTFail("Divergent NumberOfFrames indexed")
        } catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .ambiguousFrameBoundaries) }
    }

    // MARK: - Instrumented source

    func test_instrumentedSource_scansOnlyHeadersWithinBudgetsThenReadsOnlyRequestedFragments() async throws {
        let codestreams = try Self.orders.map(jpip)
        let frames = codestreams.map { fragments($0, sizes: [1024, 2, 512]) }
        let part10 = try part10Data(frames, image: .jpip, syntax: .jpeg2000Lossless)
        let log = ReadLog()
        let limits = DicomByteSource.Limits(maximumReadBytes: 4096)
        let source = try recordingSource(part10, log: log, limits: limits)
        let session = try await DicomSourceFrameSession.open(source: source)
        let layout = try XCTUnwrap(session.index.encapsulatedLayout)
        let pixelRange = try XCTUnwrap(session.index.metadata.pixelDataRange)
        let opened = await log.ranges
        XCTAssertTrue(opened.allSatisfy { $0.count <= limits.maximumReadBytes })
        let scanned = opened.reduce(0) { total, range in
            total + layout.fragments.reduce(0) { $0 + $1.valueRange.clamped(to: range).count }
        }
        let payload = layout.fragments.reduce(0) { $0 + $1.length }
        // Documented in Docs/QA/SelectiveFrameSessions.md: per frame, 256 bytes from SOC (main header, SOT and the
        // start of PLT), 4 at SOD and 3 at EOC plus pad; the other 7,587 bytes of each frame are skipped by length.
        XCTAssertEqual(payload, 39_250)
        XCTAssertEqual(scanned, 5 * (256 + 4 + 3))
        let scanReads = opened.filter { range in layout.fragments.contains { $0.valueRange.overlaps(range) } }
        XCTAssertEqual(scanReads.count, 5 * 3)
        // Besides those, the pixel element is read only as 8-byte item headers (by the metadata pass and the index).
        let itemReads = opened.filter { $0.overlaps(pixelRange) && !scanReads.contains($0) }
        XCTAssertTrue(itemReads.allSatisfy { $0.count == 8 })
        XCTAssertEqual(itemReads.count, 2 * (layout.fragments.count + 2))

        let metadata = session.index.metadata
        let exact = try await DicomSourceFrameIndex.build(from: source, metadata: metadata, maximumBoundaryScanBytes: scanned)
        XCTAssertEqual(exact.encapsulatedLayout?.frameFragmentIndexes, layout.frameFragmentIndexes)
        do {
            _ = try await DicomSourceFrameIndex.build(from: source, metadata: metadata, maximumBoundaryScanBytes: scanned - 1)
            XCTFail("Scan budget ignored")
        } catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .boundaryScanLimit) }
        do {
            _ = try await DicomSourceFrameIndex.build(from: source, metadata: metadata,
                                                      maximumIndexBytes: 256 * (layout.fragments.count - 1))
            XCTFail("Index budget ignored")
        } catch { XCTAssertEqual(error as? DicomSourceFrameIndex.Failure, .indexLimit) }

        let before = await log.ranges.count
        let frame = try await session.frameData(at: 3)
        XCTAssertEqual(frame, frames[3].reduce(Data(), +))
        let requested = await log.ranges.dropFirst(before)
        let allowed = layout.frameFragmentIndexes[3].map { layout.fragments[$0].valueRange }
        XCTAssertEqual(Array(requested), allowed)
        await session.close()

        // The per-source total read budget also bounds the scan.
        let budgeted = await source.metrics.budgetedBytes
        XCTAssertGreaterThan(budgeted, 0)
        let firstOpen = opened.reduce(0) { $0 + $1.count }
        let limited = try recordingSource(part10, log: ReadLog(),
                                          limits: .init(maximumReadBytes: 4096, maximumTotalReadBytes: firstOpen - 1))
        do {
            _ = try await DicomSourceFrameSession.open(source: limited)
            XCTFail("Total read budget ignored")
        } catch { XCTAssertEqual(error as? DicomByteSource.Failure, .totalReadLimit) }
    }

    func test_cancellationDuringBoundaryScan_stopsWithoutFurtherReads() async throws {
        let frames = try Self.orders.map { fragments(try jpip($0), sizes: [1024, 2, 512]) }
        let part10 = try part10Data(frames, image: .jpip, syntax: .jpeg2000Lossless)
        let probe = try await DicomSourceFrameSession.open(source: DicomByteSource(data: part10))
        let layout = try XCTUnwrap(probe.index.encapsulatedLayout)
        let thirdFrame = layout.fragments[layout.frameFragmentIndexes[2][0]].valueRange
        await probe.close()
        let gate = Gate()
        let log = ReadLog()
        let transport = DicomByteRangeTransport { request in
            await log.append(request.range)
            if request.range.overlaps(thirdFrame) { await gate.enter() }
            return .init(status: 206, contentRange: "bytes \(request.range.lowerBound)-\(request.range.upperBound - 1)/\(part10.count)",
                         entityTag: "\"fixture\"", body: part10.subdata(in: request.range))
        }
        let source = try DicomByteSource(remote: transport, count: part10.count, entityTag: "\"fixture\"")
        let task = Task { try await DicomSourceFrameSession.open(source: source) }
        await gate.waitUntilEntered()
        let reads = await log.ranges.count
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled scan published an index") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let after = await log.ranges.count
        XCTAssertEqual(after, reads)
    }

    func test_revisionChange_invalidatesScanAndIndexesOfAnotherRevision() async throws {
        let frames = try Self.orders.map { fragments(try jpip($0), sizes: [1024, 2, 512]) }
        let part10 = try part10Data(frames, image: .jpip, syntax: .jpeg2000Lossless)
        let probe = DicomByteSource(data: part10)
        let session = try await DicomSourceFrameSession.open(source: probe)
        let layout = try XCTUnwrap(session.index.encapsulatedLayout)
        let secondFrame = layout.fragments[layout.frameFragmentIndexes[1][0]].valueRange

        // The remote entity changes while the scan reads the second frame's headers.
        let transport = DicomByteRangeTransport { request in
            let tag = request.range.lowerBound >= secondFrame.lowerBound ? "\"v2\"" : "\"v1\""
            return .init(status: 206, contentRange: "bytes \(request.range.lowerBound)-\(request.range.upperBound - 1)/\(part10.count)",
                         entityTag: tag, body: part10.subdata(in: request.range))
        }
        let changing = try DicomByteSource(remote: transport, count: part10.count, entityTag: "\"v1\"")
        do { _ = try await DicomSourceFrameSession.open(source: changing); XCTFail("Changed source indexed") }
        catch { XCTAssertEqual(error as? DicomByteSource.Failure, .changed) }
        do { _ = try await changing.read(0..<1); XCTFail("Changed source stayed open") }
        catch { XCTAssertEqual(error as? DicomByteSource.Failure, .closed) }

        // An index stays bound to the revision it was built from.
        let other = DicomByteSource(data: part10)
        do { _ = try await session.index.frameData(at: 1, from: other); XCTFail("Other revision read") }
        catch { XCTAssertEqual(error as? DicomByteSource.Failure, .changed) }
        XCTAssertThrowsError(try DicomSourceFrameSession(source: other, index: session.index)) {
            XCTAssertEqual($0 as? DicomByteSource.Failure, .changed)
        }
        await session.close()
    }

    // MARK: - Fixtures

    private func jpip(_ order: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/JPIP/\(order).j2k"))
    }

    private func corpusFile(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Codestreams/\(name)"))
    }

    /// The 64 × 64 RGB source of the JPIP fixtures, `(x*7+y*11+c*37+(x*y%19))%256`.
    private func jpipPixels() -> [UInt8] {
        var pixels: [UInt8] = []
        for y in 0..<64 {
            for x in 0..<64 {
                for c in 0..<3 { pixels.append(UInt8((x * 7 + y * 11 + c * 37 + (x * y % 19)) % 256)) }
            }
        }
        return pixels
    }

    private func pgmSamples(_ data: Data) throws -> [UInt8] {
        // "P5", comment, "32 32", "255", each line ended by LF.
        let bytes = [UInt8](data)
        var lines = 0
        var start = 0
        while lines < 4, start < bytes.count {
            if bytes[start] == 0x0A { lines += 1 }
            start += 1
        }
        return Array(bytes[start...])
    }

    /// Own encoder, 37 × 29 grey in four 19 × 17 tiles, so every frame has four tile-parts.
    private func ownCodestreams(count: Int, lossless: Bool) async throws -> (codestreams: [Data], pixels: [[UInt8]]) {
        var configuration = J2KEncodingConfiguration(quality: lossless ? 1 : 0.5, lossless: lossless,
                                                     decompositionLevels: 2, qualityLayers: 1, progressionOrder: .lrcp)
        configuration.tileSize = (19, 17)
        var codestreams: [Data] = []
        var pixels: [[UInt8]] = []
        for frame in 0..<count {
            let samples = (0..<(29 * 37)).map { UInt8((($0 % 37) * 3 + ($0 / 37) * 5 + frame * 41) % 256) }
            let image = J2KImage(width: 37, height: 29, components: [
                J2KComponent(index: 0, bitDepth: 8, signed: false, width: 37, height: 29, data: Data(samples))
            ], colorSpace: .grayscale)
            codestreams.append(Data(try await J2KEncoder(encodingConfiguration: configuration).encode(image)))
            pixels.append(samples)
        }
        return (codestreams, pixels)
    }

    /// SOC, a one-component SIZ, an opaque QCD whose payload holds FFD9, then Psot-delimited tile-parts and EOC.
    private func syntheticCodestream(tileData: [[UInt8]], zeroLastPsot: Bool = false) -> Data {
        var bytes: [UInt8] = [0xFF, 0x4F, 0xFF, 0x51, 0, 41, 0, 0]
        for value in [UInt32(8), 8, 0, 0, 8, 8, 0, 0] { bytes += bigEndian(value) }
        bytes += [0, 1, 7, 1, 1]
        bytes += [0xFF, 0x5C, 0, 4, 0xFF, 0xD9]
        for (index, data) in tileData.enumerated() {
            let psot = zeroLastPsot && index == tileData.count - 1 ? 0 : UInt32(14 + data.count)
            bytes += [0xFF, 0x90, 0, 10, 0, 0] + bigEndian(psot) + [UInt8(index), UInt8(tileData.count)]
            bytes += [0xFF, 0x93] + data
        }
        return Data(bytes + [0xFF, 0xD9])
    }

    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
    }

    private func tileParts(_ codestream: Data) throws -> [(sot: Int, psot: Int)] {
        let bytes = [UInt8](codestream)
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        var at = 2
        while u16(at) != 0xFF90 { at += 2 + u16(at + 2) }
        var parts: [(Int, Int)] = []
        while u16(at) == 0xFF90 {
            let psot = bytes[(at + 6)..<(at + 10)].reduce(0) { $0 << 8 | Int($1) }
            parts.append((at, psot))
            guard psot > 0 else { break }
            at += psot
        }
        return parts
    }

    /// A COM holding delimiter bytes in the main header and in every tile-part header (Psot grows to cover it).
    private func withComments(_ codestream: Data) throws -> Data {
        let comment: [UInt8] = [0xFF, 0x64, 0, 14, 0, 1, 0xFF, 0xD9, 0xFF, 0x4F, 0xFF, 0x90, 0xFF, 0x93, 0xFF, 0x51]
        var bytes = [UInt8](codestream)
        let parts = try tileParts(codestream)
        for part in parts.reversed() {
            bytes.replaceSubrange((part.sot + 6)..<(part.sot + 10), with: bigEndian(UInt32(part.psot + comment.count)))
            bytes.insert(contentsOf: comment, at: part.sot + 12)
        }
        bytes.insert(contentsOf: comment, at: try XCTUnwrap(parts.first).sot)
        return Data(bytes)
    }

    private func withZeroLastPsot(_ codestream: Data) throws -> Data {
        var bytes = [UInt8](codestream)
        let last = try XCTUnwrap(tileParts(codestream).last)
        bytes.replaceSubrange((last.sot + 6)..<(last.sot + 10), with: [0, 0, 0, 0])
        return Data(bytes)
    }

    /// Pads an odd codestream with one byte, then cuts it into fragments of the given even sizes, cyclically.
    private func fragments(_ codestream: Data, sizes: [Int], pad: UInt8 = 0) -> [Data] {
        var value = [UInt8](codestream)
        if value.count % 2 == 1 { value.append(pad) }
        var result: [Data] = []
        var offset = 0
        while offset < value.count {
            let size = min(sizes[result.count % sizes.count], value.count - offset)
            result.append(Data(value[offset..<(offset + size)]))
            offset += size
        }
        return result
    }

    private func encapsulated(_ frames: [[Data]]) -> Data {
        var data = Data([0xFE, 0xFF, 0x00, 0xE0, 0, 0, 0, 0])
        for fragment in frames.joined() {
            let length = UInt32(fragment.count)
            data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0, UInt8(length & 0xFF), UInt8((length >> 8) & 0xFF),
                                     UInt8((length >> 16) & 0xFF), UInt8(length >> 24)])
            data.append(fragment)
        }
        data.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
        return data
    }

    private func part10Data(_ frames: [[Data]], image: Image, syntax: DicomTransferSyntax,
                            numberOfFrames: Int? = nil) throws -> Data {
        var elements: [DicomDataElement] = [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.3040"])),
            .init(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([UInt(image.samples)])),
            .init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([image.photometric]))
        ]
        if image.samples == 3 {
            elements.append(.init(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0])))
        }
        elements += [
            .init(tag: DicomTag.numberOfFrames.rawValue, vr: .IS, value: .strings([String(numberOfFrames ?? frames.count)])),
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([UInt(image.rows)])),
            .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([UInt(image.columns)])),
            .init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            .init(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0]))
        ]
        var encoded = try DicomDataSetWriter.dataSetData(from: DicomDataSet(elements: elements))
        encoded.append(contentsOf: [0xE0, 0x7F, 0x10, 0, 0x4F, 0x42, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        encoded.append(encapsulated(frames))
        return try DicomDataSetWriter.part10Data(fromEncodedDataSet: encoded, transferSyntax: syntax,
                                                 mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.7",
                                                 mediaStorageSOPInstanceUID: "2.25.3040")
    }

    private func request(_ codestream: Data, image: Image, syntax: DicomTransferSyntax) -> DicomFrameDecodeRequest {
        DicomFrameDecodeRequest(frameData: codestream, descriptor: DicomCompressedFrameDescriptor(
            transferSyntaxUID: syntax.rawValue, rows: image.rows, columns: image.columns, bitsAllocated: 8,
            bitsStored: 8, highBit: 7, pixelRepresentation: 0, samplesPerPixel: image.samples,
            photometricInterpretation: image.photometric, planarConfiguration: image.samples == 3 ? 0 : nil
        ), frameIndex: 0)
    }

    private func parse(_ source: DicomByteSource, frames: Int,
                       syntax: DicomTransferSyntax) async throws -> DicomEncapsulatedPixelDataDescriptor {
        try await DicomEncapsulatedPixelDataParser().parse(source: source, pixelDataRange: 0..<source.count,
                                                           numberOfFrames: frames, transferSyntax: syntax)
    }

    /// Refusal with a typed index failure (`expected` when given); the parse publishes no descriptor.
    private func assertRefused(_ encapsulated: Data, frames: Int, _ expected: DicomSourceFrameIndex.Failure?,
                               _ message: String = "") async throws {
        do {
            _ = try await parse(DicomByteSource(data: encapsulated), frames: frames, syntax: .jpeg2000Lossless)
            XCTFail("Indexed: \(message)")
        } catch let failure as DicomSourceFrameIndex.Failure {
            if let expected { XCTAssertEqual(failure, expected, message) }
        }
    }

    private func recordingSource(_ bytes: Data, log: ReadLog, limits: DicomByteSource.Limits) throws -> DicomByteSource {
        let transport = DicomByteRangeTransport { request in
            await log.append(request.range)
            return .init(status: 206, contentRange: "bytes \(request.range.lowerBound)-\(request.range.upperBound - 1)/\(bytes.count)",
                         entityTag: "\"fixture\"", body: bytes.subdata(in: request.range))
        }
        return try DicomByteSource(remote: transport, count: bytes.count, entityTag: "\"fixture\"", limits: limits)
    }

    private actor ReadLog {
        private(set) var ranges: [Range<Int>] = []

        func append(_ range: Range<Int>) { ranges.append(range) }
    }

    private actor Gate {
        private var entered: CheckedContinuation<Void, Never>?
        private var response: CheckedContinuation<Void, Never>?
        private var released = false
        private var calls = 0

        func enter() async {
            calls += 1
            entered?.resume()
            entered = nil
            if !released { await withCheckedContinuation { response = $0 } }
        }

        func waitUntilEntered() async {
            if calls == 0 { await withCheckedContinuation { entered = $0 } }
        }

        func release() {
            released = true
            response?.resume()
            response = nil
        }
    }
}
