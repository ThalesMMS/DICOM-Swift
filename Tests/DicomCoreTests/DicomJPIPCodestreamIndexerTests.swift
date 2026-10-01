import Foundation
import XCTest
@testable import DicomCore

final class DicomJPIPCodestreamIndexerTests: XCTestCase {
    static func source(_ order: String = "RPCL") throws -> Data {
        try Data(contentsOf: DicomJPIPCodestreamReconstructorTests.fixtureDirectory.appendingPathComponent(order + ".j2k"))
    }
    static func withoutPLT(_ data: Data) throws -> Data {
        let index = try DicomJPIPCodestreamIndexer().index(data)
        var result = Data(data[index.mainHeader])
        for part in index.tileParts {
            var header = Data(data[part.header.lowerBound..<part.header.lowerBound + 12])
            var at = part.header.lowerBound + 12
            while at < part.header.upperBound - 2 {
                let length = Int(data[at + 2]) * 256 + Int(data[at + 3]) + 2
                if data[at + 1] != 0x58 { header.append(data[at..<at + length]) }
                at += length
            }
            header.append(contentsOf: [255, 147])
            let size = header.count + part.bytes.upperBound - part.header.upperBound
            for n in 0..<4 { header[6 + n] = UInt8((size >> (24 - n * 8)) & 255) }
            result.append(header); result.append(data[part.header.upperBound..<part.bytes.upperBound])
        }
        result.append(contentsOf: [255, 217]); return result
    }
    func test_allProgressions_PLTAndTier2_matchIndependentPacketRanges() throws {
        for order in ["LRCP", "RLCP", "RPCL", "PCRL", "CPRL"] {
            let source = try Self.source(order), expected = try DicomJPIPCodestreamReconstructorTests.indexed(order)
            for data in [source, try Self.withoutPLT(source)] {
                let index = try DicomJPIPCodestreamIndexer().index(data)
                XCTAssertEqual(index.progression, order)
                XCTAssertEqual(index.precincts.count, 60)
                for precinct in index.precincts {
                    XCTAssertEqual(precinct.packets.map { Data(data[$0]) }, expected.packets[precinct.binID], order)
                }
            }
        }
    }
    func test_truncatedAndBudget_failClosed() throws {
        let source = try Self.source()
        for count in [0, 1, 20, source.count - 1] {
            XCTAssertThrowsError(try DicomJPIPCodestreamIndexer().index(Data(source.prefix(count))))
        }
        XCTAssertThrowsError(try DicomJPIPCodestreamIndexer(maximumIndexBytes: 128).index(source))
        XCTAssertThrowsError(try DicomJPIPCodestreamIndexer(maximumPackets: 1).index(source))
    }
}

extension DicomJPIPCodestreamIndexerTests {
    func test_generatedMultiCodeBlockTagTrees_allProgressionsSOPAndEPH() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binaries = environment["DICOM_JPIP_OPENJPIP_BIN"] else {
            if environment["DICOM_REQUIRE_OPENJPIP"] == "1" {
                XCTFail("DICOM_REQUIRE_OPENJPIP=1 requires DICOM_JPIP_OPENJPIP_BIN")
                return
            }
            throw XCTSkip("DICOM_JPIP_OPENJPIP_BIN is unset")
        }
        let old = URL(fileURLWithPath: binaries)
        let modern = old.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("openjpip/build/bin")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jpip-a2-index-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let image = directory.appendingPathComponent("source.pgm")
        var pixels: [UInt8] = []
        for n in 0..<4096 {
            let row: Int = n / 64
            let value: Int = n * 17 + row * 31
            pixels.append(UInt8(value & 255))
        }
        let pgm = Data("P5\n64 64\n255\n".utf8) + Data(pixels)
        try pgm.write(to: image)
        for order in ["LRCP", "RLCP", "RPCL", "PCRL", "CPRL"] {
            let withPLT = directory.appendingPathComponent(order + "-plt.j2k")
            let without = directory.appendingPathComponent(order + ".j2k")
            let arguments = ["-i", image.path, "-n", "3", "-r", "10,3,1", "-p", order, "-c", "[16,16],[16,16],[16,16]", "-b", "4,4", "-SOP", "-EPH"]
            _ = try await DicomJPIPServerIndependentTests.run(modern.appendingPathComponent("opj_compress"), arguments + ["-o", withPLT.path, "-PLT"])
            _ = try await DicomJPIPServerIndependentTests.run(modern.appendingPathComponent("opj_compress"), arguments + ["-o", without.path])
            let a = try DicomJPIPCodestreamIndexer().index(Data(contentsOf: withPLT))
            let b = try DicomJPIPCodestreamIndexer().index(Data(contentsOf: without))
            XCTAssertEqual(a.precincts.count, b.precincts.count)
            for (p, q) in zip(a.precincts, b.precincts) {
                XCTAssertEqual(p.packets.map(\.count), q.packets.map(\.count), order)
                XCTAssertEqual(p.packets.map { Data(a.data[$0]) }, q.packets.map { Data(b.data[$0]) }, order)
            }
            let dump = try await DicomJPIPServerIndependentTests.run(modern.appendingPathComponent("opj_dump"), ["-i", withPLT.path])
            XCTAssertTrue(dump.contains("numlayers=3")); XCTAssertTrue(dump.contains("numresolutions=3"))
        }
        let legacy = directory.appendingPathComponent("legacy.jp2")
        _ = try await DicomJPIPServerIndependentTests.run(old.appendingPathComponent("image_to_j2k"),
            ["-i", image.path, "-o", legacy.path, "-n", "3", "-r", "10,3,1", "-p", "RPCL", "-jpip"])
        let target = try await DicomJPIPDirectoryTargetProvider(directory: directory).target(named: "legacy.jp2", maximumBytes: 1_048_576)
        let index = try DicomJPIPCodestreamIndexer().index(target.codestreams[0])
        XCTAssertTrue(index.supportsJPP); XCTAssertEqual(index.layers, 3)
        print("A2 generated index evidence: \(directory.path)")
    }
    func test_HTCapabilityWithPLT_preservesOpaquePacketRanges() async throws {
        let ht = try await DicomJPIPCodestreamReconstructorTests.fixture(htj2k: true)
        let marker = try XCTUnwrap(ht.main.range(of: Data([255, 80])))
        let length = Int(ht.main[marker.lowerBound + 2]) * 256 + Int(ht.main[marker.lowerBound + 3]) + 2
        let cap = ht.main.subdata(in: marker.lowerBound..<marker.lowerBound + length)
        let source = try Self.source()
        let tagged = Data(source.prefix(2)) + cap + source.dropFirst(2)
        let index = try DicomJPIPCodestreamIndexer().index(tagged)
        XCTAssertTrue(index.isHTJ2K); XCTAssertTrue(index.supportsJPP); XCTAssertTrue(index.usesPLT)
        XCTAssertEqual(index.precincts.reduce(0) { $0 + $1.packets.count }, 180)

        // A later opaque HT tile-part must not leave partially indexed precincts usable.
        let part = try XCTUnwrap(index.tileParts.first)
        let packet = try XCTUnwrap(index.precincts.flatMap(\.packets).min { $0.lowerBound < $1.lowerBound })
        func tilePart(number: UInt8, payload: Data, lengths: [UInt8]) -> Data {
            let plt = lengths.isEmpty ? Data() : Data([255, 88, 0, UInt8(3 + lengths.count), 0] + lengths)
            let size = 14 + plt.count + payload.count
            let sizeBytes = (0..<4).reversed().map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) }
            return Data([255, 144, 0, 10, 0, 0] + sizeBytes + [number, 2]) + plt + Data([255, 147]) + payload
        }
        var packetLength = packet.count, encodedLength = [UInt8(packet.count & 127)]
        while packetLength >= 128 { packetLength >>= 7; encodedLength.insert(UInt8(packetLength & 127) | 128, at: 0) }
        let first = tilePart(number: 0, payload: Data(index.data[packet]), lengths: encodedLength)
        let second = tilePart(number: 1, payload: Data(index.data[packet.upperBound..<part.bytes.upperBound]), lengths: [])
        let incomplete = Data(index.data[index.mainHeader]) + first + second + Data([255, 217])
        XCTAssertThrowsError(try DicomJPIPCodestreamIndexer().index(incomplete)) {
            XCTAssertEqual($0 as? DicomJPIPServerError, .malformedCodestream)
        }
    }
}

extension DicomJPIPCodestreamIndexerTests {
    func test_realHTRPCL_singlePacketPLT_indexesAndDecodes() async throws {
        let pixels = Data((0..<256).map { UInt8($0 & 255) })
        let descriptor = DicomCompressedFrameDescriptor(transferSyntaxUID: "1.2.840.10008.1.2.4.202",
            rows: 16, columns: 16, bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0,
            samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
        let frame = DicomCodecDecodedFrame(buffer: .owned(pixels), width: 16, height: 16, bitsPerSample: 8, componentCount: 1)
        let data = try await DicomJ2KSwiftBackend().encode(.init(frame: frame, descriptor: descriptor,
            targetTransferSyntaxUID: descriptor.transferSyntaxUID))
        let original = try DicomJPIPCodestreamIndexer().index(data)
        XCTAssertEqual(original.decompositions, 0); XCTAssertEqual(original.layers, 1)
        let part = try XCTUnwrap(original.tileParts.first)
        let length = DicomJPIPMessageWriter.vbas(part.bytes.upperBound - part.header.upperBound)
        let marker = Data([255, 88, 0, UInt8(length.count + 3), 0]) + length
        var header = Data(data[part.header].dropLast(2)) + marker + Data([255, 147])
        let size = part.bytes.count + marker.count
        for n in 0..<4 { header[6 + n] = UInt8((size >> (24 - n * 8)) & 255) }
        let indexedData = Data(data[original.mainHeader]) + header + data[part.header.upperBound..<part.bytes.upperBound] + Data([255, 217])
        let index = try DicomJPIPCodestreamIndexer().index(indexedData)
        XCTAssertTrue(index.isHTJ2K); XCTAssertTrue(index.supportsJPP)
        XCTAssertEqual(index.precincts.count, 1); XCTAssertEqual(index.precincts.first?.packets.count, 1)
        let server = DicomJPIPServer(provider: DicomJPIPServerTests.Provider(frames: [indexedData]))
        let (_, messages, _) = try await DicomJPIPServerTests.collect(await server.handle(DicomJPIPServerTests.request("target=test")))
        var cache = DicomJPIPDatabinCache()
        for message in messages { try cache.insert(message) }
        let reconstructed = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
        XCTAssertEqual(try DicomJPEG2000Codec.decode(reconstructed.data).bytes, pixels)
    }
}
