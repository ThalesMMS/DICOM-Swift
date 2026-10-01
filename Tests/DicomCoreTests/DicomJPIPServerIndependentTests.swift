import Foundation
import XCTest
import DicomWebHTTP
@testable import DicomCore

final class DicomJPIPServerIndependentTests: XCTestCase {
    /// Qualifies the mandated oracle before server selection is involved: exact PLT-indexed
    /// source packets, all precincts, no ROI filtering, and no packet truncation.
    func test_RPCL_sourcePacketPrefixes_matchEveryLayerGolden() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let binaries = environment["DICOM_JPIP_OPENJPIP_BIN"] else {
            if environment["DICOM_REQUIRE_OPENJPIP"] == "1" {
                XCTFail("DICOM_REQUIRE_OPENJPIP=1 requires DICOM_JPIP_OPENJPIP_BIN")
                return
            }
            throw XCTSkip("DICOM_JPIP_OPENJPIP_BIN is unset")
        }
        let modern = URL(fileURLWithPath: binaries).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("openjpip/build/bin/opj_decompress")
        let fixture = try DicomJPIPCodestreamReconstructorTests.indexed("RPCL")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jpip-a2-oracle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = DicomJPIPCodestreamReconstructorTests.fixtureDirectory.appendingPathComponent("RPCL.j2k")
        let writer = DicomJPIPMessageWriter()
        func run(_ binary: URL, _ arguments: [String], _ label: String) throws -> Int32 {
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            let log = directory.appendingPathComponent(label + ".log")
            XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        for layer in [3, 1, 2] {
            var messages = [
                DicomJPIPMessage(classID: 6, codestream: 0, binID: 0, offset: 0, isComplete: true, body: fixture.main),
                DicomJPIPMessage(classID: 2, codestream: 0, binID: 0, offset: 0, isComplete: true, body: Data(fixture.header.dropFirst(2)))
            ]
            for id in fixture.packets.keys.sorted() {
                let packets = try XCTUnwrap(fixture.packets[id])
                var offset = 0
                for index in 0..<layer {
                    messages.append(.init(classID: 0, codestream: 0, binID: id, offset: offset,
                                          isComplete: index == packets.count - 1, body: packets[index]))
                    offset += packets[index].count
                }
            }
            var wire = Data()
            var cache = DicomJPIPDatabinCache()
            for message in messages { wire.append(try writer.encode(message)); try cache.insert(message) }
            let wireURL = directory.appendingPathComponent("layer\(layer).jpp")
            let oracle = directory.appendingPathComponent("layer\(layer)-oracle.j2k")
            let golden = directory.appendingPathComponent("layer\(layer)-golden.ppm")
            let decoded = directory.appendingPathComponent("layer\(layer)-oracle.ppm")
            try wire.write(to: wireURL)
            XCTAssertEqual(try run(modern, ["-i", source.path, "-o", golden.path, "-l", String(layer)], "golden\(layer)"), 0)
            let goldenPixels = Data(try Data(contentsOf: golden).suffix(64 * 64 * 3))
            let reconstructed = try DicomJPIPCodestreamReconstructor().reconstruct(cache)
            XCTAssertEqual(try DicomJPEG2000Codec.decode(reconstructed.data).bytes, goldenPixels,
                           "A1 reconstruction versus independent source layer \(layer)")
            let rebuilt = directory.appendingPathComponent("layer\(layer)-a1.j2k")
            let rebuiltPixels = directory.appendingPathComponent("layer\(layer)-a1.ppm")
            try reconstructed.data.write(to: rebuilt)
            XCTAssertEqual(try run(modern, ["-i", rebuilt.path, "-o", rebuiltPixels.path], "a1\(layer)"), 0)
            XCTAssertEqual(Data(try Data(contentsOf: rebuiltPixels).suffix(64 * 64 * 3)), goldenPixels)
            for (version, transcoder) in [
                ("1.5.2", URL(fileURLWithPath: binaries).appendingPathComponent("jpip_to_j2k")),
                ("2.5.4", modern.deletingLastPathComponent().appendingPathComponent("opj_jpip_transcode"))
            ] {
                XCTAssertEqual(try run(transcoder, [wireURL.path, oracle.path], "transcode\(version)-\(layer)"), 0)
                let label = "decode\(version)-\(layer)"
                let status = try run(modern, ["-i", oracle.path, "-o", decoded.path], label)
                if layer < 3 {
                    let log = try String(contentsOf: directory.appendingPathComponent(label + ".log"), encoding: .utf8)
                    XCTAssertTrue(log.lowercased().contains("segment too long"), log)
                    XCTExpectFailure("OpenJPIP \(version) exact source layer \(layer) prefix: segment too long; tool-versus-tool divergence") {
                        XCTAssertEqual(status, 0)
                    }
                } else {
                    XCTAssertEqual(status, 0)
                    XCTAssertEqual(Data(try Data(contentsOf: decoded).suffix(64 * 64 * 3)), goldenPixels)
                }
            }
        }
        print("A2 oracle qualification evidence: \(directory.path)")
    }
}

extension DicomJPIPServerIndependentTests {
    static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = executable; process.arguments = arguments
            process.standardOutput = pipe; process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "JPIPOracle", code: Int(process.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: String(decoding: output, as: UTF8.self)])
            }
            return String(decoding: output, as: UTF8.self)
        }.value
    }
    func test_requestsHTTPBodies_independentPixelsSessionsAndErrors() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let pythonPath = env["DICOM_SWIFT_PYNETDICOM_PYTHON"],
              let binaries = env["DICOM_JPIP_OPENJPIP_BIN"] else {
            if env["DICOM_REQUIRE_OPENJPIP"] == "1" {
                XCTFail("DICOM_REQUIRE_OPENJPIP=1 requires DICOM_JPIP_OPENJPIP_BIN and DICOM_SWIFT_PYNETDICOM_PYTHON")
                return
            }
            throw XCTSkip("DICOM_JPIP_OPENJPIP_BIN or DICOM_SWIFT_PYNETDICOM_PYTHON is unset")
        }
        let python = URL(fileURLWithPath: pythonPath)
        let old = URL(fileURLWithPath: binaries)
        let modern = old.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("openjpip/build/bin")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jpip-a2-http-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let server = try DicomJPIPServerTests.server()
        let listener = DicomWebHTTPListener { request, _ in await server.handle(request) }
        let root = try await listener.start()
        do {
            let script = #"""
import requests, sys, pathlib
root, directory = sys.argv[1:]
url = root + '/jpip'
out = pathlib.Path(directory)
for label, params in [('full', {}), ('noplt', {'stream':3}), ('jpt', {'type':'jpt-stream'}), ('layer1', {'layers':1}), ('layer2', {'layers':2}), ('layer3', {'layers':3}), ('roi', {'fsiz':'64,64','roff':'16,16','rsiz':'32,32'}), ('resolution', {'fsiz':'32,32'})]:
    r = requests.get(url, params={'target':'test', **params}, timeout=20)
    assert r.status_code == 200, (label, r.status_code, r.text)
    assert r.headers['Content-Type'] in ['image/jpp-stream','image/jpt-stream']
    assert r.headers['Transfer-Encoding'] == 'chunked'
    assert r.content[-3:] in [b'\0\1\0', b'\0\2\0']
    assert r.headers['JPIP-stream'] == str(params.get('stream', 1))
    assert r.headers['JPIP-layers'] == str(params.get('layers', 3))
    (out / (label + '.jpp')).write_bytes(r.content)
r = requests.get(url, params={'target':'test','cnew':'http'}, timeout=20)
cid = r.headers['JPIP-cnew'].split(',')[0].split('=')[1]
assert len(cid) == 16
second = requests.get(url, params={'cid':cid, 'tid':r.headers['JPIP-tid']}, timeout=20)
assert second.status_code == 200 and len(second.content) == 3
closed = requests.get(url, params={'cclose':cid}, timeout=20)
assert closed.headers['JPIP-cclose'] == cid
assert requests.get(url, params={'cid':cid}, timeout=20).status_code == 400
for params, status in [({'layers':'-1'},400), ({'type':'raw'},415), ({'stream':'0'},400), ({'!required':'x'},400)]:
    r = requests.get(url, params={'target':'test', **params}, timeout=20)
    assert r.status_code == status
    assert not any(k.lower().startswith('jpip-') for k in r.headers)
r = requests.get(url, params={'target':'test', 'len':100}, timeout=20)
assert len(r.content) <= 100 and r.content[-3:] == b'\0\4\0'
cached = requests.get(url, params={'target':'test', 'model':'Hm,H*,P*'}, timeout=20)
assert cached.content == b'\0\1\0'
needed = requests.get(url, params={'target':'test', 'need':'Hm'}, timeout=20)
assert 3 < len(needed.content) < len((out/'full.jpp').read_bytes())
print('requests: 8 pixel bodies, session continuity/close, 4 errors, len/EOR, chunked headers passed')
"""#
            print(try await Self.run(python, ["-c", script, root.absoluteString, directory.path]))
            let source = directory.appendingPathComponent("source.j2k")
            try DicomJPIPCodestreamIndexerTests.source().write(to: source)
            for label in ["full", "noplt", "jpt", "layer1", "layer2", "layer3", "roi", "resolution"] {
                let body = directory.appendingPathComponent(label + ".jpp")
                var parser = DicomJPIPMessageParser(), cache = DicomJPIPDatabinCache()
                for message in try parser.feed(Data(contentsOf: body)) { try cache.insert(message) }
                try parser.finish()
                let rebuilt = try DicomJPIPCodestreamReconstructor().reconstruct(cache, codestream: label == "noplt" ? 2 : 0).data
                let rebuiltURL = directory.appendingPathComponent(label + ".j2k")
                try rebuilt.write(to: rebuiltURL)
                let decoded = directory.appendingPathComponent(label + ".ppm")
                let golden = directory.appendingPathComponent(label + "-golden.ppm")
                _ = try await Self.run(modern.appendingPathComponent("opj_decompress"), ["-i", rebuiltURL.path, "-o", decoded.path])
                var options = ["-i", source.path, "-o", golden.path]
                if label.hasPrefix("layer") { options += ["-l", String(label.last!)] }
                if label == "resolution" { options += ["-r", "1"] }
                _ = try await Self.run(modern.appendingPathComponent("opj_decompress"), options)
                let size = label == "resolution" ? 32 : 64
                let actual = Data(try Data(contentsOf: decoded).suffix(size * size * 3))
                let expected = Data(try Data(contentsOf: golden).suffix(size * size * 3))
                XCTAssertEqual(try DicomJPEG2000Codec.decode(rebuilt).bytes, actual, label)
                if label == "roi" {
                    for y in 16..<48 { XCTAssertEqual(actual[y * 64 * 3 + 16 * 3..<y * 64 * 3 + 48 * 3], expected[y * 64 * 3 + 16 * 3..<y * 64 * 3 + 48 * 3]) }
                } else { XCTAssertEqual(actual, expected, label) }
                if ["full", "noplt", "jpt", "layer3", "resolution"].contains(label) {
                    for (version, transcoder) in [("old", old.appendingPathComponent("jpip_to_j2k")), ("modern", modern.appendingPathComponent("opj_jpip_transcode"))] {
                        let output = directory.appendingPathComponent(label + "-" + version + ".j2k")
                        _ = try await Self.run(transcoder, [body.path, output.path])
                        _ = try await Self.run(modern.appendingPathComponent("opj_decompress"), ["-i", output.path, "-o", decoded.path])
                        XCTAssertEqual(Data(try Data(contentsOf: decoded).suffix(size * size * 3)), expected, label + version)
                    }
                }
            }
        } catch { await listener.stop(); throw error }
        await listener.stop()
        print("A2 requests pixel evidence: \(directory.path)")
    }
}
