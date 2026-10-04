import Foundation
import XCTest
@testable import DicomWebClient

/// Retrieves with a list against a loopback server that refuses Accepts with 406 or 500.
final class DicomWebAcceptFallbackTests: XCTestCase {
    private var server: ScriptedHTTPServer!
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        server = ScriptedHTTPServer()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(memoryCapacity: 1024 * 1024, diskCapacity: 0)
        session = URLSession(configuration: configuration)
    }

    override func tearDown() async throws {
        session.invalidateAndCancel()
        server.stop()
        try await super.tearDown()
    }

    private func client() async throws -> DicomWebClient {
        DicomWebClient(configuration: .init(baseURL: try await server.start(), timeout: 10),
                       transport: URLSessionDicomWebHTTPTransport(session: session))
    }

    private static let accept = try! DicomWebMediaTypeNegotiator.instanceAccept(
        transferSyntaxUIDs: ["1.2.840.10008.1.2.4.90", "1.2.840.10008.1.2.1"])
    private static let notAcceptable = ScriptedHTTPServer.Action.respond(406, [:], "cannot transcode")

    func test_406ToTheFirstRange_isAskedAgainWithTheNextAndCompletes() async throws {
        server.script = [Self.notAcceptable, .respond(200, ["Content-Type": "application/dicom"], "DICM")]
        let client = try await client()
        let sink = DicomWebMemoryRetrieveSink()
        let status = try await client.retrieveSeries(studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2",
                                                     accept: Self.accept, sink: sink)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(server.acceptHeaders, [Self.accept.headerValue, Self.accept.headerValue(droppingFirst: 1)])
        XCTAssertEqual(server.acceptHeaders.last,
                       "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.1")
        let parts = await sink.result()
        XCTAssertEqual(parts.map(\.body), [Data("DICM".utf8)])
    }

    func test_exhaustedList_ends406WithEveryAcceptTried() async throws {
        server.script = [Self.notAcceptable, Self.notAcceptable]
        let client = try await client()
        do {
            _ = try await client.retrieveInstance(studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2",
                                                  sopInstanceUID: "2.25.3", accept: Self.accept,
                                                  sink: DicomWebMemoryRetrieveSink())
            XCTFail("a list refused to its end was reported as a success")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.statusCode, 406)
            XCTAssertEqual(error.attemptedAccepts, server.acceptHeaders)
            XCTAssertEqual(error.attemptedAccepts?.count, 2)
            XCTAssertEqual(error.bodyPreview, "cannot transcode")
            XCTAssertTrue(String(describing: error).contains("transfer-syntax=1.2.840.10008.1.2.4.90"))
        }
        XCTAssertEqual(server.requestCount, 2)
    }

    func test_withoutFallbackStatusesOrOnAnotherStatus_asksOnce() async throws {
        var once = Self.accept
        once.fallbackStatuses = []
        for (accept, status) in [(once, 406), (Self.accept, 404)] {
            server.script = [.respond(status, [:], ""), .respond(200, ["Content-Type": "application/dicom"], "DICM")]
            let before = server.requestCount
            let client = try await client()
            do {
                _ = try await client.retrieveStudy(studyInstanceUID: "2.25.1", accept: accept, sink: DicomWebMemoryRetrieveSink())
                XCTFail("HTTP \(status) was asked again")
            } catch let error as DicomWebError {
                XCTAssertEqual(error.statusCode, status)
                XCTAssertNil(error.attemptedAccepts)
            }
            XCTAssertEqual(server.requestCount - before, 1)
            _ = try await client.retrieveStudy(studyInstanceUID: "2.25.1", accept: accept, sink: DicomWebMemoryRetrieveSink())
        }
    }

    private static let jpegBaseline = "1.2.840.10008.1.2.4.50"
    private static let explicitVRLittleEndian = "1.2.840.10008.1.2.1"
    private static let serverError = ScriptedHTTPServer.Action.respond(500, [:], "Error encountered within the plugin engine")
    private static let multipart = "multipart/related; type=\"application/dicom\"; boundary=b"

    /// Orthanc answers 500, before any part, to a first range it cannot convert to, and ignores the next range.
    func test_500ToASpecificFirstRange_isAskedAgainWithoutItAndCompletes() async throws {
        let accept = try DicomWebMediaTypeNegotiator.instanceAccept(
            transferSyntaxUIDs: [Self.jpegBaseline, Self.explicitVRLittleEndian])
        server.script = [Self.serverError,
                         .respond(200, ["Content-Type": Self.multipart],
                                  "--b\r\nContent-Type: application/dicom\r\n\r\nDICM\r\n--b--\r\n")]
        let client = try await client()
        let sink = DicomWebMemoryRetrieveSink()
        let status = try await client.retrieveStudy(studyInstanceUID: "2.25.1", accept: accept, sink: sink)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(server.acceptHeaders, [accept.headerValue, accept.headerValue(droppingFirst: 1)])
        XCTAssertEqual(server.acceptHeaders.last,
                       "multipart/related; type=\"application/dicom\"; transfer-syntax=1.2.840.10008.1.2.1")
        let parts = await sink.result()
        XCTAssertEqual(parts.map(\.body), [Data("DICM".utf8)])
    }

    /// A 500 moves on once per retrieve: a second 500 ends it, though ranges remain, with the server's status and text.
    func test_500ToTheSecondRequest_endsWithThat500() async throws {
        let accept = try DicomWebMediaTypeNegotiator.instanceAccept(
            transferSyntaxUIDs: [Self.jpegBaseline, "1.2.840.10008.1.2.4.90", Self.explicitVRLittleEndian])
        server.script = [Self.serverError, Self.serverError, .respond(200, ["Content-Type": "application/dicom"], "DICM")]
        let client = try await client()
        do {
            _ = try await client.retrieveSeries(studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2", accept: accept,
                                                sink: DicomWebMemoryRetrieveSink())
            XCTFail("a second 500 was asked again")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.statusCode, 500)
            XCTAssertEqual(error.bodyPreview, "Error encountered within the plugin engine")
            XCTAssertEqual(error.attemptedAccepts, server.acceptHeaders)
        }
        XCTAssertEqual(server.requestCount, 2)
    }

    /// A failure after a part has reached the sink is never asked again, whatever the status list holds.
    func test_failureAfterAPart_isNotAskedAgain() async throws {
        let accept = try DicomWebMediaTypeNegotiator.instanceAccept(
            transferSyntaxUIDs: [Self.jpegBaseline, Self.explicitVRLittleEndian])
        server.script = [.respond(200, ["Content-Type": Self.multipart],
                                  "--b\r\nContent-Type: application/dicom\r\n\r\nDICM\r\n--b\r\nContent-Type: appl"),
                         .respond(200, ["Content-Type": "application/dicom"], "DICM")]
        let client = try await client()
        let sink = DicomWebMemoryRetrieveSink()
        do {
            _ = try await client.retrieveStudy(studyInstanceUID: "2.25.1", accept: accept, sink: sink)
            XCTFail("a cut multipart was reported as a success")
        } catch {}
        XCTAssertEqual(server.requestCount, 1)
        let parts = await sink.result()
        XCTAssertEqual(parts.first?.body, Data("DICM".utf8))
    }

    /// After `transfer-syntax=*`, or a range without a transfer syntax, a 500 is the server's failure and ends the retrieve.
    func test_500ToARangeWithoutASpecificSyntax_isNotAskedAgain() async throws {
        let stored = try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUIDs: ["*", Self.explicitVRLittleEndian])
        let unnamed = try DicomWebAcceptList([DicomWebMediaType("multipart/related; type=\"application/dicom\""),
                                              DicomWebMediaType("application/dicom")])
        for accept in [stored, unnamed] {
            server.script = [Self.serverError, .respond(200, ["Content-Type": "application/dicom"], "DICM")]
            let before = server.requestCount
            let client = try await client()
            do {
                _ = try await client.retrieveStudy(studyInstanceUID: "2.25.1", accept: accept, sink: DicomWebMemoryRetrieveSink())
                XCTFail("a 500 to \(accept.headerValue) was asked again")
            } catch let error as DicomWebError {
                XCTAssertEqual(error.statusCode, 500)
                XCTAssertEqual(error.bodyPreview, "Error encountered within the plugin engine")
            }
            XCTAssertEqual(server.requestCount - before, 1)
            server.script = []
        }
    }

    /// dcm4chee gives every representation of an instance the same ETag and no `Vary: Accept`, and answers a
    /// conditional request with 304 whatever the Accept. Revalidating from the URL cache would then hand back the
    /// representation retrieved earlier instead of the server's refusal of the one now asked for.
    func test_aSecondAccept_isAskedOfTheServerAndNotAnsweredFromTheURLCache() async throws {
        server.script = [
            .respond(200, ["Content-Type": "application/dicom", "ETag": "\"1\"",
                           "Last-Modified": "Sun, 04 Oct 2026 19:38:00 GMT"], "DICM"),
            .respond(304, ["ETag": "\"1\""], "")
        ]
        let client = try await client()
        let stored = try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUIDs: ["*"])
        let unknown = try DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUIDs: ["2.25.2810999"])
        _ = try await client.retrieveInstance(studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2",
                                              sopInstanceUID: "2.25.3", accept: stored,
                                              sink: DicomWebMemoryRetrieveSink())
        do {
            let sink = DicomWebMemoryRetrieveSink()
            _ = try await client.retrieveInstance(studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2",
                                                  sopInstanceUID: "2.25.3", accept: unknown, sink: sink)
            XCTFail("the representation retrieved first was returned for another Accept: \(await sink.result())")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.statusCode, 304)
        }
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertFalse(server.requestHeads.last?.lowercased().contains("if-none-match") ?? true)
        XCTAssertFalse(server.requestHeads.last?.lowercased().contains("if-modified-since") ?? true)
    }
}
