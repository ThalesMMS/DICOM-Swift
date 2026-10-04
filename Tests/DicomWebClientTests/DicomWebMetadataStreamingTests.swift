import DicomData
import DicomTestUtilities
import Foundation
import XCTest
@testable import DicomWebClient

/// WADO-RS metadata is read one data set at a time: a study's metadata larger than `maximumMetadataBytes` is read,
/// and that limit bounds each data set instead.
final class DicomWebMetadataStreamingTests: XCTestCase {
    private let base = URL(string: "https://archive.example/dicom-web")!

    func test_studyMetadataOver64MiB_isReadOneDataSetAtATime() async throws {
        let instances = 1_200
        let transport = GeneratedMetadataTransport(instances: instances, commentBytes: 60 * 1024)
        let client = DicomWebClient(configuration: .init(baseURL: base), transport: transport)
        var count = 0
        var columns = 0
        let meter = FootprintMeter()
        try await client.retrieveMetadata(studyInstanceUID: "2.25.1") { decoded in
            XCTAssertEqual(decoded.dataSet.string(for: .sopInstanceUID), "2.25.1.\(count)")
            XCTAssertEqual(decoded.sourceURL?.lastPathComponent, "metadata")
            if case .unsignedIntegers(let values)? = decoded.dataSet[0x00280011]?.value { columns += values.count }
            count += 1
        }
        let peak = meter.stop()
        let bytes = transport.sentBytes
        print("metadata_bytes=\(bytes) instances=\(count) peak_footprint_growth_bytes=\(peak)")
        XCTAssertGreaterThan(bytes, 64 * 1024 * 1024)
        XCTAssertEqual(count, instances)
        XCTAssertEqual(columns, instances)
        XCTAssertLessThan(peak, 32 * 1024 * 1024, "peak footprint growth \(peak / 1_048_576) MiB")
    }

    func test_dataSetOverTheLimit_isTooLarge_andArrayReadsUseTheSameReader() async throws {
        var configuration = DicomWebClientConfiguration(baseURL: base)
        configuration.maximumMetadataBytes = 16 * 1024
        let small = DicomWebClient(configuration: configuration,
                                   transport: GeneratedMetadataTransport(instances: 40, commentBytes: 8 * 1024))
        let series = try await small.retrieveSeriesMetadata(studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        XCTAssertEqual(series.count, 40)
        let large = DicomWebClient(configuration: configuration,
                                   transport: GeneratedMetadataTransport(instances: 2, commentBytes: 32 * 1024))
        do {
            _ = try await large.retrieveStudyMetadata(studyInstanceUID: "2.25.1")
            XCTFail("a data set over the limit was read")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.kind, .tooLarge)
        }
    }

    /// The client reads tolerantly by default: an element outside the model is a diagnostic, not a failed response.
    func test_clientDefault_isTheTolerantRead() async throws {
        let body = Data(#"[{"00280010":{"vr":"US","Value":"512"},"00280011":{"vr":"US","Value":[512,null]},"00100020":{"Value":["ID"]},"00280100":{"vr":"US","Value":["x"]}}]"#.utf8)
        let client = DicomWebClient(configuration: .init(baseURL: base), transport: GeneratedMetadataTransport(body: body))
        let decoded = try await client.retrieveInstanceMetadata(studyInstanceUID: "1", seriesInstanceUID: "2", sopInstanceUID: "3")
        let dataSet = try XCTUnwrap(decoded.first?.dataSet)
        XCTAssertEqual(dataSet[0x00280010]?.value, .unsignedIntegers([512]))
        XCTAssertEqual(dataSet[0x00280011]?.value, .unsignedIntegers([512]))
        XCTAssertEqual(dataSet[0x00100020]?.vr, .LO)
        XCTAssertNil(dataSet[0x00280100])
        XCTAssertEqual(decoded.first?.diagnostics.filter { $0.code == .invalidElementDropped }.map(\.path), [[.tag(0x00280100)]])
    }
}

/// Answers every request with a DICOM JSON array made up as it is read, 64 KiB at a time, so the test never
/// holds the whole response. Each data set carries a long comment full of characters JSON has to escape.
private final class GeneratedMetadataTransport: DicomWebHTTPTransport, @unchecked Sendable {
    private let instances: Int
    private let comment: String
    private let fixedBody: Data?
    private let lock = NSLock()
    private var sent = 0

    init(instances: Int, commentBytes: Int) {
        self.instances = instances
        let unit = #"{x} [y] \"q\" \\ "#
        comment = String(repeating: unit, count: commentBytes / unit.utf8.count)
        fixedBody = nil
    }

    init(body: Data) {
        instances = 0
        comment = ""
        fixedBody = body
    }

    var sentBytes: Int { lock.withLock { sent } }

    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse {
        throw URLError(.unsupportedURL)
    }

    func stream(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPStreamedResponse {
        let body = Body(transport: self)
        return .init(statusCode: 200, headers: ["Content-Type": "application/dicom+json"],
                     body: AsyncThrowingStream(unfolding: { body.next() }))
    }

    /// The next 64 KiB of one response, produced only when the reader asks for it.
    private final class Body: @unchecked Sendable {
        private let transport: GeneratedMetadataTransport
        private let lock = NSLock()
        private var pending = Data("[".utf8)
        private var index = 0
        private var done = false

        init(transport: GeneratedMetadataTransport) { self.transport = transport }

        func next() -> Data? {
            lock.withLock {
                if let fixed = transport.fixedBody {
                    defer { done = true }
                    return done ? nil : fixed
                }
                while pending.count < 64 * 1024, index <= transport.instances {
                    if index == transport.instances {
                        pending.append(UInt8(ascii: "]"))
                    } else {
                        if index > 0 { pending.append(UInt8(ascii: ",")) }
                        pending.append(Data(transport.dataSet(index).utf8))
                    }
                    index += 1
                }
                guard !pending.isEmpty else { return nil }
                let chunk = Data(pending.prefix(64 * 1024))
                pending = Data(pending.dropFirst(chunk.count))
                transport.lock.withLock { transport.sent += chunk.count }
                return chunk
            }
        }
    }

    fileprivate func dataSet(_ index: Int) -> String {
        """
        {"00080018":{"vr":"UI","Value":["2.25.1.\(index)"]},"0020000D":{"vr":"UI","Value":["2.25.1"]},\
        "0020000E":{"vr":"UI","Value":["2.25.2"]},"00280010":{"vr":"US","Value":[512]},\
        "00280011":{"vr":"US","Value":[512]},"00280030":{"vr":"DS","Value":[0.5,0.5]},\
        "00204000":{"vr":"LT","Value":["\(comment)"]}}
        """
    }
}
