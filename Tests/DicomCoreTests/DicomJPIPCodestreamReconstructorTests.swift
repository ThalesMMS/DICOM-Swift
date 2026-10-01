import Foundation
import XCTest
@testable import DicomCore

final class DicomJPIPCodestreamReconstructorTests: XCTestCase {
    static func fixture(htj2k: Bool = false) async throws -> (main: Data, tile: Data, pixels: Data) {
        let pixels = Data((0..<256).map { UInt8(($0 * 7) & 255) })
        let descriptor = DicomCompressedFrameDescriptor(transferSyntaxUID: htj2k ? "1.2.840.10008.1.2.4.201" : DicomTransferSyntax.jpeg2000Lossless.rawValue,
            rows: 16, columns: 16, bitsAllocated: 8, bitsStored: 8, highBit: 7, pixelRepresentation: 0,
            samplesPerPixel: 1, photometricInterpretation: "MONOCHROME2", planarConfiguration: nil)
        let frame = DicomCodecDecodedFrame(buffer: .owned(pixels), width: 16, height: 16,
                                          bitsPerSample: 8, componentCount: 1)
        let stream = try await DicomJ2KSwiftBackend().encode(DicomFrameEncodeRequest(frame: frame,
            descriptor: descriptor, targetTransferSyntaxUID: descriptor.transferSyntaxUID))
        var at = 2
        while at + 4 <= stream.count {
            if stream[at] == 255 && stream[at + 1] == 144 {
                return (stream.subdata(in: 0..<at), stream.subdata(in: at..<stream.count - 2), pixels)
            }
            at += 2 + Int(stream[at + 2]) * 256 + Int(stream[at + 3])
        }
        throw DicomJPIPReconstructionError.malformedCodestream
    }

    func test_JPT_slicedLocalCodestream_reconstructsExactPixels() async throws {
        let fixture = try await Self.fixture()
        var cache = DicomJPIPDatabinCache()
        try cache.insert(.init(classID: 6, codestream: 0, binID: 0, offset: 0, isComplete: true, body: fixture.main))
        let split = fixture.tile.count / 2
        try cache.insert(.init(classID: 4, codestream: 0, binID: 0, offset: split, isComplete: true,
                               body: Data(fixture.tile.dropFirst(split))))
        let partial = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
        XCTAssertEqual(partial.info.completeness, .partial)
        XCTAssertLessThan(partial.info.fractionComplete, 1)
        try cache.insert(.init(classID: 4, codestream: 0, binID: 0, offset: 0, body: Data(fixture.tile.prefix(split))))
        let full = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
        XCTAssertEqual(full.info.completeness, .full)
        XCTAssertEqual(try DicomJPEG2000Codec.decode(full.data).bytes, fixture.pixels)
    }

    func test_malformedMainHeader_failsWithoutCrash() throws {
        for bytes in [Data(), Data([255, 79]), Data([255, 79, 255, 81, 0, 41])] {
            var cache = DicomJPIPDatabinCache()
            try cache.insert(.init(classID: 6, codestream: 0, binID: 0, offset: 0, isComplete: true, body: bytes))
            XCTAssertThrowsError(try DicomJPIPCodestreamReconstructor().reconstruct(cache))
        }
    }
    static let fixtureDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/JPIP")

    struct IndexedFixture {
        let main: Data
        let header: Data
        let packets: [Int: [Data]]
    }

    // Independent test index: fixed 64x64 RGB, two resolutions, 16x16 precincts, three layers.
    // PLT supplies packet boundaries; the ordering below is expressed as normative sort keys.
    static func indexed(_ order: String) throws -> IndexedFixture {
        let source = try Data(contentsOf: fixtureDirectory.appendingPathComponent("\(order).j2k"))
        func u16(_ at: Int) -> Int { Int(source[at]) * 256 + Int(source[at + 1]) }
        var at = 2
        while u16(at) != 0xff90 { at += 2 + u16(at + 2) }
        let main = source.subdata(in: 0..<at)
        let tileStart = at
        at += 12
        var lengths: [Int] = []
        while u16(at) != 0xff93 {
            let length = u16(at + 2)
            if u16(at) == 0xff58 {
                var value = 0
                for byte in source[at + 5..<at + length + 2] {
                    value = value * 128 + Int(byte & 127)
                    if byte & 128 == 0 { lengths.append(value); value = 0 }
                }
                XCTAssertEqual(value, 0)
            }
            at += length + 2
        }
        at += 2
        let header = source.subdata(in: tileStart..<at)
        var entries: [(id: Int, key: [Int])] = []
        for layer in 0..<3 {
            for component in 0..<3 {
                for resolution in 0..<2 {
                    let side = resolution == 0 ? 2 : 4
                    let spacing = resolution == 0 ? 32 : 16
                    for y in 0..<side {
                        for x in 0..<side {
                            let id = component + 3 * ((resolution == 0 ? 0 : 4) + y * side + x)
                            let px = x * spacing, py = y * spacing
                            let key: [Int]
                            switch order {
                            case "LRCP": key = [layer, resolution, component, py, px]
                            case "RLCP": key = [resolution, layer, component, py, px]
                            case "RPCL": key = [resolution, py, px, component, layer]
                            case "PCRL": key = [py, px, component, resolution, layer]
                            default: key = [component, py, px, resolution, layer]
                            }
                            entries.append((id, key))
                        }
                    }
                }
            }
        }
        entries.sort { $0.key.lexicographicallyPrecedes($1.key) }
        XCTAssertEqual(lengths.count, entries.count)
        var packets: [Int: [Data]] = [:]
        for (entry, length) in zip(entries, lengths) {
            packets[entry.id, default: []].append(source.subdata(in: at..<at + length))
            at += length
        }
        XCTAssertEqual(at, source.count - 2)
        return .init(main: main, header: header, packets: packets)
    }

    func test_allProgressions_PLTPartialPacketLimitsAndGoldenPixels() throws {
        for order in ["LRCP", "RLCP", "RPCL", "PCRL", "CPRL"] {
            let fixture = try Self.indexed(order)
            var cache = DicomJPIPDatabinCache()
            try cache.insert(.init(classID: 6, codestream: 0, binID: 0, offset: 0, isComplete: true, body: fixture.main))
            try cache.insert(.init(classID: 2, codestream: 0, binID: 0, offset: 0, isComplete: true, body: fixture.header))
            for (id, packets) in fixture.packets {
                let prefix = packets[0] + packets[1].prefix(packets[1].count / 2)
                try cache.insert(.init(classID: 0, codestream: 0, binID: id, offset: 0, body: prefix))
            }
            let partial = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
            XCTAssertEqual(partial.info.layersUsed, 1, order)
            XCTAssertEqual(partial.info.completeness, .partial, order)
            let golden = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("\(order)-layer1.rgb"))
            XCTAssertEqual(try DicomJPEG2000Codec.decode(partial.data).bytes, golden, order)
            for (id, packets) in fixture.packets {
                try cache.insert(.init(classID: 0, codestream: 0, binID: id, offset: 0, isComplete: true,
                    body: packets.reduce(into: Data()) { $0.append($1) }))
            }
            let final = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
            let original = try Data(contentsOf: Self.fixtureDirectory.appendingPathComponent("\(order).j2k"))
            XCTAssertEqual(final.info.completeness, .full, order)
            XCTAssertEqual(try DicomJPEG2000Codec.decode(final.data).bytes,
                           try DicomJPEG2000Codec.decode(original).bytes, order)
        }
    }

    func test_HTJ2K_JPTPassthrough_preservesCapabilityMarkersAndPixels() async throws {
        let fixture = try await Self.fixture(htj2k: true)
        XCTAssertNotNil(fixture.main.range(of: Data([255, 80])), "HTJ2K CAP marker")
        var cache = DicomJPIPDatabinCache()
        try cache.insert(.init(classID: 6, codestream: 0, binID: 0, offset: 0, isComplete: true, body: fixture.main))
        try cache.insert(.init(classID: 4, codestream: 0, binID: 0, offset: 0, isComplete: true, body: fixture.tile))
        let result = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
        XCTAssertEqual(result.data, fixture.main + fixture.tile + Data([255, 217]))
        XCTAssertEqual(try DicomJPEG2000Codec.decode(result.data).bytes, fixture.pixels)
    }

}
