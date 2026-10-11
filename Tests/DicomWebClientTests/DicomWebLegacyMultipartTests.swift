import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

final class DicomWebLegacyMultipartTests: XCTestCase {
    private let type = "multipart/related; type=\"application/dicom\"; boundary=sample"
    private let header = Data("Content-Type: application/dicom\r\n\r\n".utf8)

    private func number(_ value: UInt32, width: Int, little: Bool = true) -> Data {
        Data((0..<width).map { UInt8(truncatingIfNeeded: value >> (8 * (little ? $0 : width - $0 - 1))) })
    }
    private func element(_ tag: UInt32, _ vr: String, _ value: Data, little: Bool = true,
                         implicit: Bool = false, undefined: Bool = false) -> Data {
        var result = number(tag >> 16, width: 2, little: little) + number(tag & 0xffff, width: 2, little: little)
        let long = ["OB", "OW", "SQ", "UN", "UT"].contains(vr)
        if !implicit { result += Data(vr.utf8); if long { result += Data([0, 0]) } }
        result += number(undefined ? .max : UInt32(value.count), width: implicit || long ? 4 : 2, little: little)
        result += value
        return result
    }
    private func item(_ tag: UInt32, _ value: Data = Data(), undefined: Bool = false) -> Data {
        number(tag >> 16, width: 2) + number(tag & 0xffff, width: 2) + number(undefined ? .max : UInt32(value.count), width: 4) + value
    }
    private func uid(_ value: String) -> Data { Data((value.count % 2 == 0 ? value : value + "\0").utf8) }
    private func file(_ id: String, syntax: String = "1.2.840.10008.1.2.1", encapsulated: Bool = false,
                      pixel: Data? = nil, sequence: Bool = false) -> Data {
        let payload = pixel ?? Data("before\r\n--sample\r\nContent-Type: application/dicom\r\n\r\n--sample--\r\nafter!".utf8)
        var padded = payload
        if padded.count % 2 != 0 { padded.append(0) }
        var result = Data(repeating: 0, count: 128) + Data("DICM".utf8)
        result += element(0x00020002, "UI", uid("1.2.840.10008.5.1.4.1.1.2"))
        result += element(0x00020003, "UI", uid(id))
        result += element(0x00020010, "UI", uid(syntax))
        let little = syntax != "1.2.840.10008.1.2.2"
        let implicit = syntax == "1.2.840.10008.1.2"
        result += element(0x00080018, "UI", uid(id), little: little, implicit: implicit)
        if sequence {
            let nested = item(0xfffee000, element(0x0040a160, "UT", Data("text".utf8)), undefined: true)
                + item(0xfffee00d) + item(0xfffee0dd)
            result += element(0x0040a730, "SQ", nested, undefined: true)
        }
        if encapsulated {
            let fragments = item(0xfffee000) + item(0xfffee000, padded) + item(0xfffee0dd)
            result += element(0x7fe00010, "OB", fragments, undefined: true)
        } else { result += element(0x7fe00010, "OB", padded, little: little, implicit: implicit) }
        return result
    }
    private func wire(_ files: [Data], boundary: String = "sample", ending: String = "") -> Data {
        var result = Data()
        for (index, file) in files.enumerated() {
            if index > 0 { result += Data("--\(boundary)\r\n".utf8) }
            result += header + file
        }
        result += Data("--\(boundary)--\(ending)".utf8)
        return result
    }
    private func parse(_ data: Data, chunk: Int = 7, limits: DicomWebMultipartLimits = .init(),
                       contentType: String? = nil) throws -> [Data] {
        var parser = try DicomWebMultipartStreamParser(contentType: contentType ?? type, limits: limits,
                                                       compatibility: .pixeonLegacyFraming)
        var bodies: [Data] = []
        func receive(_ events: [DicomWebMultipartEvent]) {
            for event in events {
                switch event {
                case .partHeaders: bodies.append(Data())
                case .payload(let data): bodies[bodies.count - 1] += data
                default: break
                }
            }
        }
        for offset in stride(from: 0, to: data.count, by: chunk) {
            receive(try parser.feed(Data(data[offset..<min(data.count, offset + chunk)])))
        }
        receive(try parser.finish())
        return bodies
    }

    func test_twoInstancesAndSingleInstance_preserveBytesAtEveryChunkSize() throws {
        let first = file("2.25.101"), second = file("2.25.102")
        for files in [[first], [first, second]] {
            for ending in ["", "\r\n"] {
                let body = wire(files, ending: ending)
                XCTAssertThrowsError(try DicomWebMultipartStreamParser.parts(from: body, contentType: type))
                for size in [1, 2, 7, 31, 132, 8192, 65536] {
                    let decoded = try parse(body, chunk: size)
                    XCTAssertEqual(decoded, files)
                    XCTAssertEqual(try decoded.map { try DicomPart10FileMetaParser.parse($0).mediaStorageSOPInstanceUID },
                                   try files.map { try DicomPart10FileMetaParser.parse($0).mediaStorageSOPInstanceUID })
                }
            }
        }
    }
    func test_pixelFragmentsAndNestedSequences_cannotOpenMultipartParts() throws {
        let source = file("2.25.103", syntax: "1.2.840.10008.1.2.4.70", encapsulated: true, sequence: true)
        for size in 1...80 { XCTAssertEqual(try parse(wire([source]), chunk: size), [source]) }
    }
    func test_definedValuesAndBigEndian_preserveDelimiterLookingBytes() throws {
        for syntax in ["1.2.840.10008.1.2.1", "1.2.840.10008.1.2.2"] {
            let source = file("2.25.104", syntax: syntax, pixel: Data("--sample--\r\n".utf8))
            XCTAssertEqual(try parse(wire([source]), chunk: 1), [source])
        }
    }
    func test_validMIME_stillUsesStrictParser() throws {
        let body = Data("--sample\r\n".utf8) + header + Data("arbitrary payload\r\n--sample--\r\n".utf8)
        for size in 1...30 { XCTAssertEqual(try parse(body, chunk: size), [Data("arbitrary payload".utf8)]) }
    }
    func test_truncationAmbiguityAndTrailingData_areRejected() throws {
        let source = file("2.25.105")
        let body = wire([source])
        for count in 1...40 { XCTAssertThrowsError(try parse(Data(body.dropLast(count)), chunk: 1)) }
        XCTAssertThrowsError(try parse(body + Data("junk".utf8)))
        let ambiguous = wire([source], boundary: "abOB")
        XCTAssertThrowsError(try parse(ambiguous, contentType: "multipart/related; type=application/dicom; boundary=abOB")) {
            XCTAssertEqual($0 as? DicomWebMultipartStreamError, .unsafeLegacyFraming)
        }
        for syntax in ["1.2.840.10008.1.2", "1.2.840.10008.1.2.1.99"] {
            XCTAssertThrowsError(try parse(wire([file("2.25.106", syntax: syntax)])))
        }
        XCTAssertThrowsError(try parse(header + Data(repeating: 0, count: 200) + Data("--sample--".utf8)))
    }
    func test_invalidHeadersAndConflictingLengths_areRejected() throws {
        let source = file("2.25.107")
        for lines in ["Content-Type: application/octet-stream", "Content-Type: application/dicom\r\nContent-Type: application/dicom",
                      "Content-Type: application/dicom\r\nContent-Length: 1", "Content-Type: application/dicom\r\nContent-Length: -1",
                      "Content-Type: application/dicom\r\nContent-Transfer-Encoding: base64"] {
            let body = Data((lines + "\r\n\r\n").utf8) + source + Data("--sample--".utf8)
            XCTAssertThrowsError(try parse(body))
        }
        let valid = Data("Content-Type: application/dicom\r\nContent-Length: \(source.count)\r\n\r\n".utf8) + source + Data("--sample--".utf8)
        XCTAssertEqual(try parse(valid), [source])
    }
    func test_limitsAndServerIdentification_remainExplicit() throws {
        let body = wire([file("2.25.108")])
        for limits in [DicomWebMultipartLimits(maximumHeaderBytes: 10), .init(maximumPartBytes: 100),
                       .init(maximumPartCount: 0), .init(maximumTotalBytes: body.count - 1)] {
            XCTAssertThrowsError(try parse(body, limits: limits)) {
                guard case .limitExceeded = $0 as? DicomWebMultipartStreamError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertEqual(DicomWebClientConfiguration(baseURL: URL(string: "https://example.invalid")!).multipartCompatibility, .strict)
        XCTAssertEqual(DicomWebMultipartCompatibility.identifiedPixeonLegacyFraming.forResponse(headers: [:]), .strict)
        XCTAssertEqual(DicomWebMultipartCompatibility.identifiedPixeonLegacyFraming.forResponse(headers: ["Server": "other"]), .strict)
        XCTAssertEqual(DicomWebMultipartCompatibility.identifiedPixeonLegacyFraming.forResponse(headers: ["server": "DicomWebServices 20.2.0 c603f5b"]), .pixeonLegacyFraming)
    }
    func test_clientUsesCompatibilityOnlyForAnIdentifiedServer() async throws {
        struct Transport: DicomWebHTTPTransport {
            let body: Data
            let headers: [String: String]
            func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
                .init(statusCode: 200, headers: headers, body: body)
            }
        }
        let source = file("2.25.109")
        for server in ["", "OtherServer", "DicomWebServices 20.2.0 synthetic"] {
            var configuration = DicomWebClientConfiguration(baseURL: URL(string: "https://example.invalid")!)
            configuration.multipartCompatibility = .identifiedPixeonLegacyFraming
            let client = DicomWebClient(configuration: configuration,
                                       transport: Transport(body: wire([source]), headers: ["Content-Type": type, "Server": server]))
            let sink = DicomWebMemoryRetrieveSink()
            do {
                _ = try await client.retrieveSeries(studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2", sink: sink)
                XCTAssertTrue(server.hasPrefix("DicomWebServices "))
                let parts = await sink.result()
                XCTAssertEqual(parts.map(\.body), [source])
            } catch {
                XCTAssertFalse(server.hasPrefix("DicomWebServices "), "\(error)")
                XCTAssertEqual(error as? DicomWebMultipartStreamError, .missingFinalDelimiter)
            }
        }
        let contentType = type
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var parser = try DicomWebMultipartStreamParser(contentType: contentType, compatibility: .pixeonLegacyFraming)
            _ = try parser.feed(Data([1]))
        }
        do { try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
    }

    func test_deepSequencesAndLongHeaders_areBounded() throws {
        var nested = Data()
        for _ in 0..<40 {
            nested = element(0x0040a730, "SQ", item(0xfffee000, nested, undefined: true) + item(0xfffee00d) + item(0xfffee0dd), undefined: true)
        }
        XCTAssertThrowsError(try parse(wire([file("2.25.110") + nested]), chunk: 1)) {
            XCTAssertEqual($0 as? DicomWebMultipartStreamError, .limitExceeded("maximumDICOMDepth", limit: 64))
        }
        let longHeader = Data(("Content-Type: application/dicom\r\nX-Long: " + String(repeating: "a", count: 65537)).utf8)
        XCTAssertThrowsError(try parse(longHeader, chunk: 1)) {
            XCTAssertEqual($0 as? DicomWebMultipartStreamError, .limitExceeded("maximumHeaderBytes", limit: 65536))
        }
    }

    func test_largeValues_emitDeterministicBoundedPayloadBlocks() throws {
        var pixels = Data(repeating: 7, count: 65536)
        let marker = Data("\r\n--sample--\r\n".utf8)
        pixels.replaceSubrange(16380..<16380 + marker.count, with: marker)
        let source = file("2.25.111", pixel: pixels)
        let body = wire([source])
        var reference: [DicomWebMultipartEvent]?
        for size in [body.count, 1, 7, 8192, 65536] {
            var parser = try DicomWebMultipartStreamParser(contentType: type, compatibility: .pixeonLegacyFraming)
            var events: [DicomWebMultipartEvent] = []
            for offset in stride(from: 0, to: body.count, by: size) {
                events += try parser.feed(Data(body[offset..<min(body.count, offset + size)]))
            }
            events += try parser.finish()
            if let reference { XCTAssertEqual(events, reference) } else { reference = events }
            var payload = Data()
            for event in events {
                if case .payload(let bytes) = event {
                    XCTAssertLessThanOrEqual(bytes.count, 16384)
                    payload += bytes
                }
            }
            XCTAssertEqual(payload, source)
        }
    }

}
