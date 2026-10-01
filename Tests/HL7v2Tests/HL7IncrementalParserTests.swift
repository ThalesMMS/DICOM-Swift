import XCTest
@testable import HL7v2

final class HL7IncrementalParserTests: XCTestCase {
    func test_skippedMalformedLazySegment_doesNotMaterializeHeader() throws {
        var options = HL7ParserOptions()
        options.recovery = .skipBadSegments
        let view = HL7LazySegment(header: Data(hl7Header().utf8), wire: Data("bad|VALUE\r".utf8),
            options: options, lineIndex: 7)
        XCTAssertThrowsError(try view.materialize()) {
            XCTAssertEqual($0 as? HL7ParseError, .malformed(.init(), lineIndex: 7))
        }
    }
    private func messages(_ events: [HL7IncrementalEvent]) -> [HL7Message] {
        events.compactMap { if case .message(let message) = $0 { return message }; return nil }
    }
    func test_corpus_randomChunking_matchesOneShot() throws {
        var random: UInt64 = 2360
        for url in hl7Fixtures("own") + hl7Fixtures("hl7kit") {
            if url.lastPathComponent == "bad_segment_id.hl7" { continue }
            let data = try Data(contentsOf: url)
            var options = HL7ParserOptions(); options.lenientTerminators = true
            let expected = try HL7Parser(options: options).parse(data)
            for _ in 0..<4 {
                var parser = HL7IncrementalParser(options: options)
                var actual: [HL7Message] = []
                var index = 0
                while index < data.count {
                    random = random &* 6364136223846793005 &+ 1
                    let end = min(data.count, index + 1 + Int(random % 53))
                    actual += messages(try parser.feed(data.subdata(in: index..<end)))
                    index = end
                }
                actual += messages(try parser.finish())
                XCTAssertEqual(actual, [expected], url.lastPathComponent)
            }
        }
    }
    func test_everySplit_insideEscapesAndUTF8AndLatin1_matchesOneShot() throws {
        let utf8 = Data((hl7Header(charset: "UNICODE UTF-8") + "PID|é漢🙂\\F\\A\\X4142\\\r").utf8)
        let latin1 = HL7Charset.iso8859(1).encode(hl7Header(charset: "8859/1") + "PID|José\r")!
        for data in [utf8, latin1] {
            let expected = try HL7Parser().parse(data)
            for split in 0...data.count {
                var parser = HL7IncrementalParser()
                var actual = messages(try parser.feed(Data(data.prefix(split))))
                actual += messages(try parser.feed(Data(data.dropFirst(split))))
                actual += messages(try parser.finish())
                XCTAssertEqual(actual, [expected], "split=\(split)")
            }
        }
    }
    func test_messageBoundaries_nextMSHAndTrailersAndEOF() throws {
        let member = Data((hl7Header() + "PID|1\r").utf8)
        let wire = try HL7BatchDocument.join([member, member], fileEnvelope: true)
        var parser = HL7IncrementalParser()
        let actual = messages(try parser.feed(wire)) + messages(try parser.finish())
        XCTAssertEqual(actual.count, 2)
        XCTAssertEqual(try actual.map { try HL7Serializer().serialize($0) }, [member, member])
        var next = HL7IncrementalParser()
        XCTAssertTrue(try next.feed(member).isEmpty)
        XCTAssertEqual(messages(try next.feed(Data("MSH".utf8))).count, 1)
        var eof = HL7IncrementalParser()
        _ = try eof.feed(Data((hl7Header() + "PID|1").utf8))
        XCTAssertFalse(try XCTUnwrap(messages(eof.finish()).first).hasTrailingTerminator)
    }
    func test_byteAndSegmentLimits_throwTypedPaths() throws {
        var options = HL7ParserOptions(); options.maxMessageBytes = 12
        var parser = HL7IncrementalParser(options: options)
        XCTAssertThrowsError(try parser.feed(Data(repeating: 65, count: 13))) {
            XCTAssertEqual($0 as? HL7ParseError, .limitExceeded(.messageBytes, .init()))
        }
        options = .init(); options.maxSegments = 1
        parser = .init(options: options)
        XCTAssertThrowsError(try parser.feed(Data((hl7Header() + "PID|1\r").utf8))) {
            XCTAssertEqual($0 as? HL7ParseError, .limitExceeded(.segments, .init()))
        }
    }
    func test_exactByteLimit_nextMessageDoesNotOverflow() throws {
        let data = Data(hl7Header().utf8)
        var options = HL7ParserOptions(); options.maxMessageBytes = data.count
        var parser = HL7IncrementalParser(options: options)
        XCTAssertEqual(messages(try parser.feed(data + data)).count, 1)
        XCTAssertEqual(messages(try parser.finish()).count, 1)
    }
    func test_segmentAndLazyOutput_preserveFieldsAndDeferErrors() throws {
        let data = Data((hl7Header() + "PID|1||ABC^DEF~GHI&JKL\r").utf8)
        let expected = try HL7Parser().parse(data).segments
        var parser = HL7IncrementalParser(output: .segments)
        let actual = try parser.feed(data).compactMap { if case .segment(let s) = $0 { return s }; return nil }
        XCTAssertEqual(actual, expected)
        var lazy = HL7IncrementalParser(output: .lazySegments)
        let views = try lazy.feed(data).compactMap { if case .lazySegment(let s) = $0 { return s }; return nil }
        XCTAssertEqual(try views[1].field(3), expected[1][3])
        XCTAssertEqual(try views[1].field(99), HL7Field(.absent))
        let invalid = try lazy.feed(Data("bad|SECRET\r".utf8))
        if case .lazySegment(let segment) = invalid.first {
            XCTAssertThrowsError(try segment.field(1))
        } else { XCTFail("Expected lazy segment") }
    }
    func test_stream_rejectsOversizedRetainedChunks() async throws {
        var options = HL7ParserOptions(); options.maxMessageBytes = 8
        let stream = HL7IncrementalParser.stream(options: options) { Data(repeating: 65, count: 9) }
        var iterator = stream.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            XCTFail("Expected bounded chunk failure")
        } catch {
            XCTAssertEqual(error as? HL7ParseError, .limitExceeded(.messageBytes, .init()))
        }
    }
    func test_stream_pullsOnlyOnDemandAndDoesNotDropEvents() async throws {
        let data = Data((hl7Header() + "PID|1\r").utf8)
        actor Source {
            var calls = 0
            let bytes: Data
            init(_ bytes: Data) { self.bytes = bytes }
            func next() -> Data? { calls += 1; return calls <= 2 ? bytes : nil }
        }
        let source = Source(data)
        let stream = HL7IncrementalParser.stream { await source.next() }
        let before = await source.calls
        XCTAssertEqual(before, 0)
        var iterator = stream.makeAsyncIterator()
        let first = try await iterator.next()
        XCTAssertNotNil(first)
        let calls = await source.calls
        XCTAssertEqual(calls, 2)
        let second = try await iterator.next()
        XCTAssertNotNil(second)
        let end = try await iterator.next()
        XCTAssertNil(end)
    }
}
