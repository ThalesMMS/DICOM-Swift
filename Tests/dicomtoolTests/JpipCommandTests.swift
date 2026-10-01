import XCTest
import Foundation
@testable import DicomCore
import DicomWebHTTP
import ArgumentParser
@testable import dicomtool

final class JpipCommandTests: XCTestCase {
    func test_commandsAndWindow_parse() throws {
        _ = try DicomTool.parseAsRoot(["jpip", "serve", "--dir", "/tmp", "--port", "0"])
        _ = try DicomTool.parseAsRoot(["jpip", "index", "image.j2k"])
        _ = try DicomTool.parseAsRoot(["jpip", "inspect", "stream.jpp"])
        _ = try DicomTool.parseAsRoot(["jpip", "fetch", "http://localhost/jpip?target=test", "--session", "--out", "/tmp/out.j2k"])
        let window = try JpipCommand.parsedWindow("fsiz=64,64,roff=16,16,rsiz=32,32,layers=2,comps=0-2,stream=2", type: "jpp")
        XCTAssertEqual(window.layers, 2); XCTAssertEqual(window.fsiz?.width, 64); XCTAssertEqual(window.stream, 2)
        XCTAssertThrowsError(try JpipCommand.parsedWindow("fsiz=-1,2", type: "raw"))
    }
}

extension JpipCommandTests {
    func test_indexInspectAndFetch_executeAgainstListener() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = package.appendingPathComponent("Tests/Fixtures/JPIP/RPCL.j2k")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jpip-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = DicomJPIPServer(provider: DicomJPIPDirectoryTargetProvider(directory: fixture.deletingLastPathComponent()))
        let listener = DicomWebHTTPListener { request, _ in await server.handle(request) }
        let root = try await listener.start()
        do {
            var index = try JpipCommand.Index.parse([fixture.path]); try await index.run()
            let output = directory.appendingPathComponent("fetched.j2k")
            var fetch = try JpipCommand.Fetch.parse([root.absoluteString + "/jpip?target=RPCL.j2k", "--window", "layers=3", "--session", "--out", output.path])
            try await fetch.run()
            XCTAssertEqual(try DicomJPEG2000Codec.decode(Data(contentsOf: output)).bytes,
                           try DicomJPEG2000Codec.decode(Data(contentsOf: fixture)).bytes)
            let response = await server.handle(.init(method: .get, url: URL(string: root.absoluteString + "/jpip?target=RPCL.j2k")!))
            var wire = Data()
            for try await chunk in response.body { wire.append(chunk) }
            let stream = directory.appendingPathComponent("response.jpp"); try wire.write(to: stream)
            var inspect = try JpipCommand.Inspect.parse([stream.path]); try await inspect.run()
        } catch { await listener.stop(); throw error }
        await listener.stop()
    }
}
