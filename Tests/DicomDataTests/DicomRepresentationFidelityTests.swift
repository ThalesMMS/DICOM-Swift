import Foundation
import XCTest
@testable import DicomData

/// Dataset ↔ DICOM JSON ↔ Native XML fidelity (#2322): every VR, multiplicity, sequence item order, empty
/// and null values, person-name groups, private tags, binaries, 64-bit integers, textual DS/IS, bulk-data
/// references with explicit resolution, and the rejection of malicious or unrepresentable input.
final class DicomRepresentationFidelityTests: XCTestCase {
    private typealias Rep = DicomDataSetRepresentation

    // MARK: - Corpus

    /// Every VR at least once, with multiplicity, empties, non-ASCII person names, private tags and nesting.
    static func corpus() -> DicomDataSet {
        let item = DicomDataSet(elements: [
            .init(tag: 0x00080100, vr: .SH, value: .strings(["T-A0100"])),
            .init(tag: 0x00080102, vr: .SH, value: .strings(["SRT"])),
            .init(tag: 0x00080104, vr: .LO, value: .strings(["Body   "])),
            .init(tag: 0x00081155, vr: .UI, value: .strings(["2.25.1"]))
        ])
        let nested = DicomDataSet(elements: [
            .init(tag: 0x0040A730, vr: .SQ, value: .sequence([.init(dataSet: item), .init(dataSet: .init(elements: []))])),
            .init(tag: 0x0040A040, vr: .CS, value: .strings(["CONTAINER"]))
        ])
        return DicomDataSet(elements: [
            .init(tag: 0x00080005, vr: .CS, value: .strings(["ISO_IR 192"])),
            .init(tag: 0x00080016, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: 0x00080018, vr: .UI, value: .strings(["2.25.23229901"])),
            .init(tag: 0x00080020, vr: .DA, value: .strings(["20260909"])),
            .init(tag: 0x00080030, vr: .TM, value: .strings(["120000.123456"])),
            .init(tag: 0x0008002A, vr: .DT, value: .strings(["20260909120000.000000+0000"])),
            .init(tag: 0x00080050, vr: .SH, value: .empty),
            .init(tag: 0x00080054, vr: .AE, value: .strings(["HOROS", "ISIS"])),
            .init(tag: 0x00080060, vr: .CS, value: .strings(["OT"])),
            .init(tag: 0x00080070, vr: .LO, value: .strings(["Vendor Two"])),
            .init(tag: 0x00081030, vr: .LO, value: .strings(["Estudo ç ã é & <tag>"])),
            .init(tag: 0x0008114A, vr: .SQ, value: .sequence([.init(dataSet: nested)])),
            .init(tag: 0x00100010, vr: .PN, value: .strings(["Yamada^Tarou=山田^太郎=やまだ^たろう"])),
            .init(tag: 0x00101001, vr: .PN, value: .strings(["Yamada^Tarou=山田^太郎=やまだ^たろう", "Doe^John^Q^Dr^Jr", "", "=Only^Ideographic"])),
            .init(tag: 0x00100020, vr: .LO, value: .strings(["ID-1"])),
            .init(tag: 0x00100030, vr: .DA, value: .empty),
            .init(tag: 0x00101010, vr: .AS, value: .strings(["042Y"])),
            .init(tag: 0x00281050, vr: .DS, value: .strings(["70.50", "-0", "1e-3", "  12  "])),
            .init(tag: 0x00102160, vr: .SH, value: .strings(["日本語"])),
            .init(tag: 0x00104000, vr: .LT, value: .strings([" leading and trailing \\ backslash kept "])),
            .init(tag: 0x00180050, vr: .DS, value: .strings(["2.5"])),
            .init(tag: 0x00181020, vr: .LO, value: .strings(["", "v2", "v3"])),
            .init(tag: 0x0009100F, vr: .FD, value: .floats([-1.5, 3.0e300, 0.1])),
            .init(tag: 0x00091010, vr: .FL, value: .floats([1.5, -2.25])),
            .init(tag: 0x0009100C, vr: .UC, value: .strings(["unlimited chars", "second"])),
            .init(tag: 0x00200013, vr: .IS, value: .strings(["007"])),
            .init(tag: 0x00091011, vr: .IS, value: .strings(["007", "-12"])),
            .init(tag: 0x00200037, vr: .DS, value: .strings(["1", "0", "0", "0", "1", "0"])),
            .init(tag: 0x0009100E, vr: .AT, value: .unsignedIntegers([0x00200032, 0x7FE00010])),
            .init(tag: 0x00280008, vr: .IS, value: .strings(["1"])),
            .init(tag: 0x00280010, vr: .US, value: .unsignedIntegers([65535])),
            .init(tag: 0x00280011, vr: .US, value: .unsignedIntegers([0])),
            .init(tag: 0x0009100D, vr: .SS, value: .signedIntegers([-32768, 32767])),
            .init(tag: 0x00281201, vr: .OW, value: .bytes(Data([0x01, 0x02, 0x03, 0x04]))),
            .init(tag: 0x0040A160, vr: .UT, value: .strings(["multi\nline\ttext"])),
            .init(tag: 0x0040E010, vr: .UR, value: .strings(["https://example.org/a?b=c&d=e"])),
            .init(tag: 0x00091004, vr: .UV, value: .unsignedIntegers([UInt(UInt64.max), 5])),
            .init(tag: 0x00091005, vr: .UL, value: .unsignedIntegers([4294967295, 1])),
            .init(tag: 0x00091006, vr: .SL, value: .signedIntegers([-2147483648, 2147483647])),
            .init(tag: 0x00091007, vr: .SV, value: .signedIntegers([Int.min, Int.max])),
            .init(tag: 0x00091008, vr: .OF, value: .floats([1.0, -0.5])),
            .init(tag: 0x00091009, vr: .OD, value: .floats([2.5, 1e100])),
            .init(tag: 0x0009100A, vr: .OL, value: .unsignedIntegers([1, 4294967295])),
            .init(tag: 0x0009100B, vr: .OV, value: .bytes(Data(repeating: 0x33, count: 8))),
            .init(tag: 0x00090010, vr: .LO, value: .strings(["ISIS PRIVATE"])),
            .init(tag: 0x00091001, vr: .UN, value: .bytes(Data([0xDE, 0xAD]))),
            .init(tag: 0x00091002, vr: .ST, value: .strings(["private text"])),
            .init(tag: 0x00091003, vr: .SQ, value: .empty),
            .init(tag: 0x7FE00010, vr: .OB, value: .bytes(Data((0..<64).map { UInt8($0) })))
        ])
    }

    // MARK: - Round trips

    /// Writes the corpus as Part 10, JSON and XML for the independent pydicom comparison (`representation_oracle.py`).
    func test_corpusSidecars_areWrittenForTheIndependentOracle() throws {
        guard let folder = ProcessInfo.processInfo.environment["DICOM_REPRESENTATION_CORPUS_DIRECTORY"] else { throw XCTSkip("corpus directory not requested") }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corpus = Self.corpus()
        try DicomDataSetWriter.part10Data(from: corpus, options: .init(transferSyntax: .explicitVRLittleEndian, mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.7", mediaStorageSOPInstanceUID: "2.25.23229901")).write(to: directory.appendingPathComponent("corpus.dcm"))
        try DicomJSONCodec.encode(corpus).write(to: directory.appendingPathComponent("corpus.json"))
        try DicomJSONCodec.encode(corpus, options: .init(decimals: .numbersWhenExact)).write(to: directory.appendingPathComponent("corpus-numbers.json"))
        try DicomNativeXMLCodec.encode(corpus).write(to: directory.appendingPathComponent("corpus.xml"))
    }

    func test_jsonRoundTrip_preservesEveryElement() throws {
        let original = Self.corpus()
        let json = try DicomJSONCodec.encode(original)
        let decoded = try DicomJSONCodec.decode(json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].dataSet, original)
        XCTAssertTrue(decoded[0].bulkData.isEmpty)
        XCTAssertTrue(decoded[0].diagnostics.isEmpty)
        // Re-encoding the decoded data set is byte-identical: the representation is a fixed point.
        XCTAssertEqual(try DicomJSONCodec.encode(decoded[0].dataSet), json)
    }

    func test_xmlRoundTrip_preservesEveryElement() throws {
        let original = Self.corpus()
        let xml = try DicomNativeXMLCodec.encode(original)
        let decoded = try DicomNativeXMLCodec.decode(xml)
        XCTAssertEqual(decoded.dataSet, original)
        XCTAssertEqual(try DicomNativeXMLCodec.encode(decoded.dataSet), xml)
        let text = String(decoding: xml, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<NativeDicomModel xmlns=\"http://dicom.nema.org/PS3.19/models/NativeDICOM\" xml:space=\"preserve\">"))
        XCTAssertTrue(text.contains("<DicomAttribute tag=\"00100010\" vr=\"PN\" keyword=\"PatientName\">"))
        XCTAssertTrue(text.contains("<DicomAttribute tag=\"00091001\" vr=\"UN\" privateCreator=\"ISIS PRIVATE\">"))
        XCTAssertTrue(text.contains("<PersonName number=\"1\"><Alphabetic><FamilyName>Yamada</FamilyName><GivenName>Tarou</GivenName></Alphabetic><Ideographic><FamilyName>山田</FamilyName><GivenName>太郎</GivenName></Ideographic><Phonetic><FamilyName>やまだ</FamilyName><GivenName>たろう</GivenName></Phonetic></PersonName>"))
        XCTAssertTrue(text.contains("<Value number=\"1\" xml:space=\"preserve\"> leading and trailing \\ backslash kept </Value>"))
        XCTAssertTrue(text.contains("<Value number=\"1\">00200032</Value>"))
        XCTAssertFalse(text.contains("DicomWebMetadata"))
    }

    func test_crossRepresentationRoundTrip_andPart10AgreeOnTheSameDataSet() throws {
        let original = Self.corpus()
        let viaJSON = try DicomJSONCodec.decode(try DicomJSONCodec.encode(original))[0].dataSet
        let xml = try DicomNativeXMLCodec.encode(viaJSON)
        let viaXML = try DicomNativeXMLCodec.decode(xml).dataSet
        XCTAssertEqual(viaXML, original)
        let part10 = try DicomDataSetWriter.dataSetData(from: viaXML, transferSyntax: .explicitVRLittleEndian, purpose: .instance)
        let reparsed = try DicomDataSetParser.dataSet(from: part10, transferSyntax: .explicitVRLittleEndian)
        // The VR-aware comparison normalizes wire padding and numeric storage recursively through sequence items.
        let difference = DicomDataSetDiff.compare(original, reparsed,
            options: .init(ignoredTags: [DicomTag.pixelData.rawValue], ignoresFileMeta: false))
        XCTAssertTrue(difference.isEmpty, difference.changes.map(\.description).joined(separator: "\n"))
    }

    // MARK: - JSON specifics

    func test_json_writesTheStandardShapes() throws {
        let object = try DicomJSONCodec.object(from: Self.corpus())
        XCTAssertEqual(object["0009100E"] as? [String: Any] as NSDictionary?, ["vr": "AT", "Value": ["00200032", "7FE00010"]])
        XCTAssertEqual((object["00281050"] as? [String: Any])?["Value"] as? [String], ["70.50", "-0", "1e-3", "  12  "])
        XCTAssertEqual((object["00091011"] as? [String: Any])?["Value"] as? [String], ["007", "-12"])
        XCTAssertEqual((object["00091004"] as? [String: Any])?["Value"] as? [Any] as NSArray?, ["18446744073709551615", 5])
        XCTAssertEqual((object["00091007"] as? [String: Any])?["Value"] as? [Any] as NSArray?, ["-9223372036854775808", "9223372036854775807"])
        XCTAssertEqual(object["00080050"] as? [String: String], ["vr": "SH"])
        XCTAssertEqual(object["00091003"] as? [String: String], ["vr": "SQ"])
        let versions = try XCTUnwrap((object["00181020"] as? [String: Any])?["Value"] as? [Any])
        XCTAssertTrue(versions[0] is NSNull)
        XCTAssertEqual(versions[1] as? String, "v2")
        let names = try XCTUnwrap((object["00101001"] as? [String: Any])?["Value"] as? [Any])
        XCTAssertEqual(names[0] as? [String: String], ["Alphabetic": "Yamada^Tarou", "Ideographic": "山田^太郎", "Phonetic": "やまだ^たろう"])
        XCTAssertTrue(names[2] is NSNull)
        XCTAssertEqual(names[3] as? [String: String], ["Ideographic": "Only^Ideographic"])
        XCTAssertEqual((object["7FE00010"] as? [String: Any])?["InlineBinary"] as? String, Data((0..<64).map { UInt8($0) }).base64EncodedString())
        XCTAssertNil(object["00090000"])
    }

    func test_json_numberPolicyAndCanonicalization() throws {
        let numbers = try DicomJSONCodec.object(from: Self.corpus(), options: .init(decimals: .numbersWhenExact))
        XCTAssertEqual((numbers["00281050"] as? [String: Any])?["Value"] as? [Any] as NSArray?, ["70.50", "-0", "1e-3", "  12  "])
        XCTAssertEqual((numbers["00180050"] as? [String: Any])?["Value"] as? [Any] as NSArray?, [2.5])
        XCTAssertEqual((numbers["00091011"] as? [String: Any])?["Value"] as? [Any] as NSArray?, ["007", -12])
        let json = Data(#"{"00101030":{"vr":"DS","Value":[70.5, 1e-3]},"00200013":{"vr":"IS","Value":[7]},"00620021":{"vr":"UV","Value":[18446744073709551615]}}"#.utf8)
        let decoded = try DicomJSONCodec.decode(json)[0]
        XCTAssertEqual(decoded.dataSet[0x00101030]?.value, .strings(["70.5", "0.001"]))
        XCTAssertEqual(decoded.dataSet[0x00200013]?.value, .strings(["7"]))
        XCTAssertEqual(decoded.dataSet[0x00620021]?.value, .unsignedIntegers([UInt(UInt64.max)]))
        XCTAssertEqual(decoded.diagnostics, [.init(code: .numberCanonicalized, path: [.tag(0x00101030)])])
    }

    func test_json_nullsAndUnknownVRsFollowThePolicies() throws {
        let json = Data(#"{"00280010":{"vr":"US","Value":[1,null]},"00080070":{"vr":"LO","Value":[null,"b"]}}"#.utf8)
        XCTAssertThrowsError(try DicomJSONCodec.decode(json)) { XCTAssertEqual($0 as? Rep.Error, .nullValue(tag: "00280010", index: 1)) }
        let tolerant = try DicomJSONCodec.decode(json, options: .init(nulls: .dropWithDiagnostic))[0]
        XCTAssertEqual(tolerant.dataSet[0x00280010]?.value, .unsignedIntegers([1]))
        XCTAssertEqual(tolerant.dataSet[0x00080070]?.value, .strings(["", "b"]))
        XCTAssertEqual(tolerant.diagnostics, [.init(code: .nullValueDropped, path: [.tag(0x00280010)])])
        let unknown = Data(#"{"00091001":{"vr":"ZZ","InlineBinary":"3q0="}}"#.utf8)
        XCTAssertThrowsError(try DicomJSONCodec.decode(unknown)) { XCTAssertEqual($0 as? Rep.Error, .unsupportedVR(tag: "00091001", vr: "ZZ")) }
        let kept = try DicomJSONCodec.decode(unknown, options: .init(unknownVRs: .treatAsUnknown))[0]
        XCTAssertEqual(kept.dataSet[0x00091001], .init(tag: 0x00091001, vr: .UN, value: .bytes(Data([0xDE, 0xAD]))))
        XCTAssertEqual(kept.diagnostics.map(\.code), [.unknownVRTreatedAsUnknown])
    }

    func test_json_rejectsMalformedAndUnrepresentableInput() {
        let cases: [(String, Rep.Error)] = [
            (#"{"0010001":{"vr":"PN"}}"#, .malformedTag("0010001")),
            (#"{"00100010":{"Value":["A"]}}"#, .missingVR(tag: "00100010")),
            (#"{"7FE00010":{"vr":"OB","InlineBinary":"AA","BulkDataURI":"/x"}}"#, .conflictingValueFields(tag: "7FE00010")),
            (#"{"7FE00010":{"vr":"OB","InlineBinary":"not base64!"}}"#, .invalidBase64(tag: "7FE00010")),
            (#"{"00280010":{"vr":"US","Value":[65536]}}"#, .unrepresentableValue(tag: "00280010", index: 0, reason: "out of range for US")),
            (#"{"00280106":{"vr":"SS","Value":["1"]}}"#, .unrepresentableValue(tag: "00280106", index: 0, reason: "SS values must be JSON numbers")),
            (#"{"00209165":{"vr":"AT","Value":["ZZZZ"]}}"#, .unrepresentableValue(tag: "00209165", index: 0, reason: "AT values are eight hexadecimal digits")),
            (#"{"00080060":{"vr":"CS","Value":[1]}}"#, .unrepresentableValue(tag: "00080060", index: 0, reason: "CS values must be JSON strings")),
            (#"[1]"#, .invalidDocument("array entries must be objects")),
            (#"{"00080060":{"vr":"CS","Value":"OT"}}"#, .invalidDocument("Value of 00080060 is not an array"))
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try DicomJSONCodec.decode(Data(json.utf8)), json) { XCTAssertEqual($0 as? Rep.Error, expected, json) }
        }
        XCTAssertThrowsError(try DicomJSONCodec.decode(Data("{".utf8)))
        XCTAssertThrowsError(try DicomJSONCodec.encode(DicomDataSet(elements: [.init(tag: 0x00189087, vr: .FD, value: .floats([.nan]))]))) {
            XCTAssertEqual($0 as? Rep.Error, .unrepresentableValue(tag: "00189087", index: 0, reason: "non-finite floating point"))
        }
    }

    func test_json_enforcesByteAndDepthLimits() throws {
        var nested = "{\"0040A730\":{\"vr\":\"SQ\",\"Value\":[{}]}}"
        for _ in 0..<70 { nested = "{\"0040A730\":{\"vr\":\"SQ\",\"Value\":[\(nested)]}}" }
        XCTAssertThrowsError(try DicomJSONCodec.decode(Data(nested.utf8))) { XCTAssertEqual($0 as? Rep.Error, .depthExceeded(limit: 64)) }
        XCTAssertThrowsError(try DicomJSONCodec.decode(Data(nested.utf8), options: .init(maximumBytes: 16))) {
            XCTAssertEqual($0 as? Rep.Error, .inputTooLarge(byteCount: nested.utf8.count, limit: 16))
        }
    }

    // MARK: - Bulk data

    private struct StubResolver: Rep.BulkDataResolver {
        let payloads: [String: Data]
        let refused: Set<String>
        func data(for reference: Rep.BulkDataReference) async throws -> Data {
            try Task.checkCancellation()
            if refused.contains(reference.uri) { throw URLError(.cancelled) }
            guard let data = payloads[reference.uri] else { throw URLError(.fileDoesNotExist) }
            return data
        }
    }

    func test_bulkDataReferences_stayUnresolvedUntilExplicitlyResolved() async throws {
        let json = Data("""
        {"00189087":{"vr":"FD","BulkDataURI":"https://a.example/fd"},
         "00101030":{"vr":"DS","BulkDataURI":"https://a.example/ds"},
         "0008114A":{"vr":"SQ","Value":[{"7FE00010":{"vr":"OB","BulkDataURI":"https://a.example/pixels"}}]}}
        """.utf8)
        let decoded = try DicomJSONCodec.decode(json)[0]
        XCTAssertEqual(decoded.dataSet[0x00189087]?.value, .empty)
        XCTAssertEqual(decoded.bulkData.map(\.uri), ["https://a.example/pixels", "https://a.example/ds", "https://a.example/fd"])
        XCTAssertEqual(decoded.bulkData[0].path, [.tag(0x0008114A), .item(0), .tag(0x7FE00010)])
        // The XML form writes the same kind of reference for binaries the host keeps out of line.
        let xml = try DicomNativeXMLCodec.encode(Self.corpus(), options: .init(binary: .reference { path, _ in path.last == .tag(0x7FE00010) ? "https://a.example/pixels" : nil }))
        XCTAssertTrue(String(decoding: xml, as: UTF8.self).contains("<BulkData uri=\"https://a.example/pixels\"/>"))
        var fd = Data(); for value in [1.5, -2.0] { withUnsafeBytes(of: value.bitPattern.littleEndian) { fd.append(contentsOf: $0) } }
        let resolver = StubResolver(payloads: ["https://a.example/fd": fd, "https://a.example/ds": Data("1.5\\-2 ".utf8),
                                               "https://a.example/pixels": Data([9, 8, 7])], refused: [])
        let resolved = try await Rep.resolvingBulkData(decoded, using: resolver)
        XCTAssertEqual(resolved.dataSet[0x00189087]?.value, .floats([1.5, -2.0]))
        XCTAssertEqual(resolved.dataSet[0x00101030]?.value, .strings(["1.5", "-2"]))
        XCTAssertEqual(resolved.dataSet[0x0008114A]?.sequenceItems.first?.dataSet[0x7FE00010]?.value, .bytes(Data([9, 8, 7])))
        XCTAssertTrue(resolved.bulkData.isEmpty)
    }

    func test_bulkDataResolution_refusalLimitsAndCancellationDoNotProduceEmptyValues() async throws {
        let json = Data(#"{"7FE00010":{"vr":"OB","BulkDataURI":"https://a.example/pixels"}}"#.utf8)
        let decoded = try DicomJSONCodec.decode(json)[0]
        let refused = StubResolver(payloads: [:], refused: ["https://a.example/pixels"])
        do { _ = try await Rep.resolvingBulkData(decoded, using: refused); XCTFail("refusal must propagate") } catch { XCTAssertEqual((error as? URLError)?.code, .cancelled) }
        let large = StubResolver(payloads: ["https://a.example/pixels": Data(count: 10)], refused: [])
        do {
            _ = try await Rep.resolvingBulkData(decoded, using: large, limits: .init(maximumBytesPerReference: 4))
            XCTFail("limit must apply")
        } catch { XCTAssertEqual(error as? Rep.Error, .bulkDataTooLarge(tag: "7FE00010", byteCount: 10, limit: 4)) }
        do {
            _ = try await Rep.resolvingBulkData(decoded, using: large, limits: .init(maximumReferences: 0))
            XCTFail("reference count limit must apply")
        } catch { XCTAssertEqual(error as? Rep.Error, .bulkDataTooLarge(tag: "", byteCount: 1, limit: 0)) }
        let task = Task { try await Rep.resolvingBulkData(decoded, using: large) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancellation must propagate") } catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        XCTAssertEqual(decoded.dataSet[0x7FE00010]?.value, .empty, "the unresolved element stays empty in the original decode result only")
        XCTAssertEqual(decoded.bulkData.count, 1)
    }

    // MARK: - XML specifics

    func test_bulkDataResolution_enforcesAggregateBudgetWithoutMutatingOriginal() async throws {
        let json = Data(#"{"77771001":{"vr":"OB","BulkDataURI":"/a"},"77771002":{"vr":"OB","BulkDataURI":"/b"},"77771003":{"vr":"OB","BulkDataURI":"/c"}}"#.utf8)
        let decoded = try DicomJSONCodec.decode(json)[0]
        let resolver = StubResolver(payloads: ["/a": Data(count: 4), "/b": Data(count: 4), "/c": Data(count: 4)], refused: [])
        do {
            _ = try await Rep.resolvingBulkData(decoded, using: resolver,
                                               limits: .init(maximumBytesPerReference: 4, maximumTotalBytes: 11))
            XCTFail("aggregate limit must apply")
        } catch { XCTAssertEqual(error as? Rep.Error, .bulkDataTooLarge(tag: "77771003", byteCount: 12, limit: 11)) }
        XCTAssertTrue(decoded.dataSet.elements.allSatisfy { $0.value == .empty })
        XCTAssertEqual(decoded.bulkData.count, 3)
        let resolved = try await Rep.resolvingBulkData(decoded, using: resolver,
                                                      limits: .init(maximumBytesPerReference: 4, maximumTotalBytes: 12))
        XCTAssertTrue(resolved.bulkData.isEmpty)
        XCTAssertTrue(resolved.dataSet.elements.allSatisfy { $0.bytesValue?.count == 4 })
    }

    func test_xml_rejectsMalformedDescendantsBeforeReconstruction() {
        let cases = [
            ("PN", "<PersonName number=\"1\"><Alphabetic/><Alphabetic/></PersonName>"),
            ("PN", "<PersonName number=\"1\"><Unknown/></PersonName>"),
            ("PN", "<PersonName number=\"1\"><Alphabetic><FamilyName>A</FamilyName><FamilyName>B</FamilyName></Alphabetic></PersonName>"),
            ("PN", "<PersonName number=\"1\"><Alphabetic><Unknown/></Alphabetic></PersonName>"),
            ("PN", "<PersonName number=\"1\"><Alphabetic><FamilyName xmlns=\"urn:foreign\">A</FamilyName></Alphabetic></PersonName>"),
            ("PN", "<PersonName number=\"1\"><Alphabetic><FamilyName><Value/></FamilyName></Alphabetic></PersonName>"),
            ("LO", "<Value number=\"1\"><Value number=\"1\">A</Value></Value>"),
            ("OB", "<InlineBinary><Value>AA==</Value></InlineBinary>"),
            ("OB", "<BulkData uri=\"/a\"><Unknown/></BulkData>"),
            ("SQ", "<Item number=\"1\"><DicomAttribute tag=\"00100010\" vr=\"PN\"><PersonName number=\"1\"><Alphabetic xmlns=\"urn:foreign\"/></PersonName></DicomAttribute></Item>")
        ]
        for (vr, child) in cases {
            let xml = "<NativeDicomModel xmlns=\"\(DicomNativeXMLCodec.namespace)\"><DicomAttribute tag=\"00091001\" vr=\"\(vr)\">\(child)</DicomAttribute></NativeDicomModel>"
            XCTAssertThrowsError(try DicomNativeXMLCodec.decode(Data(xml.utf8)), child)
        }
    }

    func test_xmlEncoding_rejectsProhibitedControlsAndParsesAllowedWhitespace() throws {
        for text in ["before\u{1B}after", "before\u{0}after", "before\u{FFFF}after"] {
            let dataSet = DicomDataSet(elements: [.init(tag: 0x0040A160, vr: .UT, value: .strings([text]))])
            do {
                let encoded = try DicomNativeXMLCodec.encode(dataSet)
                XCTAssertTrue(XMLParser(data: encoded).parse(), "encoder produced invalid XML 1.0")
                XCTFail("prohibited control accepted")
            } catch { XCTAssertTrue(error is Rep.Error) }
        }
        let allowed = DicomDataSet(elements: [.init(tag: 0x0040A160, vr: .UT, value: .strings(["a\tb\nc"]))])
        let xml = try DicomNativeXMLCodec.encode(allowed)
        XCTAssertTrue(XMLParser(data: xml).parse())
        XCTAssertEqual(try DicomNativeXMLCodec.decode(xml).dataSet, allowed)
    }

    func test_xml_rejectsForeignUnknownAndVRIncompatibleChildren() {
        let cases = [("LO", "<Value xmlns=\"urn:foreign\" number=\"1\">x</Value>"),
                     ("SQ", "<Item xmlns=\"urn:foreign\" number=\"1\"/>"),
                     ("OB", "<InlineBinary xmlns=\"urn:foreign\">AA==</InlineBinary>"),
                     ("LO", "<Unknown/>"), ("LO", "<Item number=\"1\"/>"),
                     ("SQ", "<Value number=\"1\">x</Value>"), ("LO", "<InlineBinary>AA==</InlineBinary>"),
                     ("LO", "<Value number=\"1\">x</Value><BulkData uri=\"/x\"/>"),
                     ("OB", "<InlineBinary>AA==</InlineBinary><InlineBinary>AQ==</InlineBinary>")]
        for (vr, child) in cases {
            let xml = "<NativeDicomModel xmlns=\"\(DicomNativeXMLCodec.namespace)\"><DicomAttribute tag=\"00091001\" vr=\"\(vr)\">\(child)</DicomAttribute></NativeDicomModel>"
            XCTAssertThrowsError(try DicomNativeXMLCodec.decode(Data(xml.utf8)), child)
        }
    }

    func test_nativePixelDataWithItemPrefix_isPreservedExactly() throws {
        let prefix = Data([0xFE, 0xFF, 0x00, 0xE0, 0, 0, 0, 0])
        for bytes in [prefix, prefix + Data([0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])] {
            let dataSet = DicomDataSet(elements: [.init(tag: 0x7FE00010, vr: .OB, value: .bytes(bytes))])
            let json = try DicomJSONCodec.encode(dataSet)
            let xml = try DicomNativeXMLCodec.encode(dataSet)
            XCTAssertEqual(try DicomJSONCodec.decode(json)[0].dataSet[0x7FE00010]?.bytesValue, bytes)
            XCTAssertEqual(try DicomNativeXMLCodec.decode(xml).dataSet[0x7FE00010]?.bytesValue, bytes)
        }
    }

    func test_xml_rejectsEntitiesExternalReferencesAndNamespaceMistakes() {
        let entity = """
        <?xml version="1.0"?><!DOCTYPE lol [<!ENTITY a "aaaaaaaaaa"><!ENTITY b "&a;&a;&a;&a;&a;&a;&a;&a;&a;&a;">]>
        <NativeDicomModel xmlns="http://dicom.nema.org/PS3.19/models/NativeDICOM"><DicomAttribute tag="00080060" vr="CS"><Value number="1">&b;</Value></DicomAttribute></NativeDicomModel>
        """
        XCTAssertThrowsError(try DicomNativeXMLCodec.decode(Data(entity.utf8))) {
            XCTAssertEqual($0 as? Rep.Error, .invalidDocument("DTD entity declarations are not accepted"))
        }
        let external = """
        <?xml version="1.0"?><!DOCTYPE x [<!ENTITY ext SYSTEM "file:///etc/hosts">]>
        <NativeDicomModel xmlns="http://dicom.nema.org/PS3.19/models/NativeDICOM"><DicomAttribute tag="00080060" vr="CS"><Value number="1">&ext;</Value></DicomAttribute></NativeDicomModel>
        """
        XCTAssertThrowsError(try DicomNativeXMLCodec.decode(Data(external.utf8)))
        let wrongNamespace = "<NativeDicomModel><DicomAttribute tag=\"00080060\" vr=\"CS\"><Value number=\"1\">OT</Value></DicomAttribute></NativeDicomModel>"
        XCTAssertThrowsError(try DicomNativeXMLCodec.decode(Data(wrongNamespace.utf8)))
        let wrapper = "<DicomWebMetadata><NativeDicomModel xmlns=\"http://dicom.nema.org/PS3.19/models/NativeDICOM\"/></DicomWebMetadata>"
        XCTAssertThrowsError(try DicomNativeXMLCodec.decode(Data(wrapper.utf8)))
        let numbering = "<NativeDicomModel xmlns=\"http://dicom.nema.org/PS3.19/models/NativeDICOM\"><DicomAttribute tag=\"00080060\" vr=\"CS\"><Value number=\"2\">OT</Value></DicomAttribute></NativeDicomModel>"
        XCTAssertThrowsError(try DicomNativeXMLCodec.decode(Data(numbering.utf8))) { XCTAssertEqual($0 as? Rep.Error, .invalidDocument("00080060 numbering is not 1…n")) }
        let badBase64 = "<NativeDicomModel xmlns=\"http://dicom.nema.org/PS3.19/models/NativeDICOM\"><DicomAttribute tag=\"7FE00010\" vr=\"OB\"><InlineBinary>!!</InlineBinary></DicomAttribute></NativeDicomModel>"
        XCTAssertThrowsError(try DicomNativeXMLCodec.decode(Data(badBase64.utf8))) { XCTAssertEqual($0 as? Rep.Error, .invalidBase64(tag: "7FE00010")) }
        XCTAssertThrowsError(try DicomNativeXMLCodec.decode(Data(numbering.utf8), options: .init(maximumBytes: 8))) {
            XCTAssertEqual($0 as? Rep.Error, .inputTooLarge(byteCount: numbering.utf8.count, limit: 8))
        }
        var deep = "<DicomAttribute tag=\"0040A730\" vr=\"SQ\"><Item number=\"1\"></Item></DicomAttribute>"
        for _ in 0..<80 { deep = "<DicomAttribute tag=\"0040A730\" vr=\"SQ\"><Item number=\"1\">\(deep)</Item></DicomAttribute>" }
        XCTAssertThrowsError(try DicomNativeXMLCodec.decode(Data("<NativeDicomModel xmlns=\"http://dicom.nema.org/PS3.19/models/NativeDICOM\">\(deep)</NativeDicomModel>".utf8))) {
            XCTAssertEqual($0 as? Rep.Error, .depthExceeded(limit: 64))
        }
    }

    func test_xmlSpace_isInheritedAndCanBeOverridden() throws {
        let xml = """
        <NativeDicomModel xmlns="http://dicom.nema.org/PS3.19/models/NativeDICOM" xml:space="preserve">
          <DicomAttribute tag="00081030" vr="LO"><Value number="1">  preserved  </Value><Value number="2" xml:space="default">  trimmed  </Value></DicomAttribute>
          <DicomAttribute tag="0008114A" vr="SQ"><Item number="1"><DicomAttribute tag="0008103E" vr="LO"><Value number="1">  nested  </Value></DicomAttribute></Item></DicomAttribute>
        </NativeDicomModel>
        """
        let decoded = try DicomNativeXMLCodec.decode(Data(xml.utf8)).dataSet
        XCTAssertEqual(decoded[0x00081030]?.value, .strings(["  preserved  ", "trimmed"]))
        XCTAssertEqual(decoded[0x0008114A]?.sequenceItems.first?[0x0008103E]?.value, .strings(["  nested  "]))
    }

    func test_xml_readsTheStandardExampleShapes() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <NativeDicomModel xmlns="http://dicom.nema.org/PS3.19/models/NativeDICOM">
          <DicomAttribute tag="00080005" vr="CS" keyword="SpecificCharacterSet"><Value number="1">ISO_IR 192</Value></DicomAttribute>
          <DicomAttribute tag="00100010" vr="PN" keyword="PatientName"><PersonName number="1"><Alphabetic><FamilyName>Wang</FamilyName><GivenName>XiaoDong</GivenName></Alphabetic><Ideographic><FamilyName>王</FamilyName><GivenName>小東</GivenName></Ideographic></PersonName></DicomAttribute>
          <DicomAttribute tag="00080060" vr="CS" keyword="Modality"><Value number="1">  CT  </Value></DicomAttribute>
          <DicomAttribute tag="00101030" vr="DS"><Value number="2">2.0</Value><Value number="1">1.0</Value></DicomAttribute>
          <DicomAttribute tag="00091001" vr="OB" privateCreator="ACME"><BulkData uri="https://a.example/bulk/1"/></DicomAttribute>
          <DicomAttribute tag="0008114A" vr="SQ"><Item number="1"><DicomAttribute tag="00081155" vr="UI"><Value number="1">2.25.5</Value></DicomAttribute></Item><Item number="2"/></DicomAttribute>
          <DicomAttribute tag="00080050" vr="SH"/>
        </NativeDicomModel>
        """
        let decoded = try DicomNativeXMLCodec.decode(Data(xml.utf8))
        XCTAssertEqual(decoded.dataSet[0x00100010]?.value, .strings(["Wang^XiaoDong=王^小東"]))
        XCTAssertEqual(decoded.dataSet[0x00080060]?.value, .strings(["CT"]))
        XCTAssertEqual(decoded.dataSet[0x00101030]?.value, .strings(["1.0", "2.0"]))
        XCTAssertEqual(decoded.dataSet[0x00091001]?.value, .empty)
        XCTAssertEqual(decoded.bulkData, [.init(path: [.tag(0x00091001)], tag: 0x00091001, vr: .OB, uri: "https://a.example/bulk/1")])
        XCTAssertEqual(decoded.dataSet[0x0008114A]?.sequenceItems.count, 2)
        XCTAssertEqual(decoded.dataSet[0x0008114A]?.sequenceItems[1].dataSet, DicomDataSet(elements: []))
        XCTAssertEqual(decoded.dataSet[0x00080050], .init(tag: 0x00080050, vr: .SH, value: .empty))
    }


    func test_encapsulatedPixelDataWithoutFileMeta_usesExplicitContextIncludingBulkResolution() async throws {
        let fragment = Data([0xFE, 0xFF, 0, 0xE0, 0, 0, 0, 0, 0xFE, 0xFF, 0, 0xE0, 4, 0, 0, 0, 0xFF, 0xD8, 0xFF, 0xD9])
        let wire = fragment + Data([0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
        let source = DicomDataSet(elements: [.init(tag: 0x7FE00010, vr: .OB, value: .bytes(wire))])
        let encoding = Rep.EncodingOptions(transferSyntax: .jpegBaseline)
        let decoding = Rep.DecodingOptions(transferSyntax: .jpegBaseline)
        let json = try DicomJSONCodec.encode(source, options: encoding)
        XCTAssertEqual(try DicomJSONCodec.decode(json, options: decoding)[0].dataSet, source)
        let xml = try DicomNativeXMLCodec.encode(source, options: encoding)
        XCTAssertEqual(try DicomNativeXMLCodec.decode(xml, options: decoding).dataSet, source)
        let reference = try DicomJSONCodec.decode(Data(#"{"7FE00010":{"vr":"OB","BulkDataURI":"https://a.example/px"}}"#.utf8), options: decoding)[0]
        let resolved = try await Rep.resolvingBulkData(reference, using: StubResolver(payloads: ["https://a.example/px": fragment], refused: []))
        XCTAssertEqual(resolved.dataSet, source)
    }

    func test_encapsulatedPixelData_isCarriedWithoutTheSequenceDelimiterAndRestored() throws {
        let fragment = Data([0xFE, 0xFF, 0x00, 0xE0, 0x00, 0x00, 0x00, 0x00, 0xFE, 0xFF, 0x00, 0xE0, 0x04, 0x00, 0x00, 0x00, 0xFF, 0xD8, 0xFF, 0xD9])
        let wire = fragment + Data([0xFE, 0xFF, 0xDD, 0xE0, 0x00, 0x00, 0x00, 0x00])
        let dataSet = DicomDataSet(elements: [.init(tag: 0x00020010, vr: .UI, value: .strings([DicomTransferSyntax.jpegBaseline.rawValue])),
                                             .init(tag: 0x7FE00010, vr: .OB, value: .bytes(wire))])
        let object = try DicomJSONCodec.object(from: dataSet)
        XCTAssertEqual((object["7FE00010"] as? [String: Any])?["InlineBinary"] as? String, fragment.base64EncodedString())
        XCTAssertEqual(try DicomJSONCodec.decode(try DicomJSONCodec.encode(dataSet))[0].dataSet, dataSet)
        XCTAssertEqual(try DicomNativeXMLCodec.decode(try DicomNativeXMLCodec.encode(dataSet)).dataSet, dataSet)
    }

    func test_representations_omitPixelDataOnRequestWithoutTouchingOtherBinaries() throws {
        let options = Rep.EncodingOptions(binary: .omit([0x7FE00010]))
        let object = try DicomJSONCodec.object(from: Self.corpus(), options: options)
        XCTAssertNil(object["7FE00010"])
        XCTAssertNotNil((object["00281201"] as? [String: Any])?["InlineBinary"])
        XCTAssertFalse(String(decoding: try DicomNativeXMLCodec.encode(Self.corpus(), options: options), as: UTF8.self).contains("tag=\"7FE00010\""))
    }
}
