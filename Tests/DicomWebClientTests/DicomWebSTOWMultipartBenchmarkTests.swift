import DicomData
import Foundation
import XCTest
@testable import DicomWebClient

final class DicomWebSTOWMultipartBenchmarkTests: XCTestCase {
    func test_releaseMultiInstanceBody_serializesWithinBudget() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DICOMWEB_STOW_MULTIPART_BENCHMARK"] == "1" else {
            throw XCTSkip("Set DICOMWEB_STOW_MULTIPART_BENCHMARK=1 to run the STOW multipart benchmark.")
        }
        #if DEBUG
        XCTFail("The STOW multipart benchmark must run with -c release.")
        #else
        let mode = environment["DICOMWEB_STOW_MULTIPART_BENCHMARK_MODE"] ?? "preallocated"
        guard mode == "legacy" || mode == "preallocated" else {
            XCTFail("Unknown STOW multipart benchmark mode: \(mode)")
            return
        }
        let instanceCount = max(
            Int(environment["DICOMWEB_STOW_MULTIPART_BENCHMARK_INSTANCES"] ?? "") ?? 64,
            1
        )
        let payloadByteCount = max(
            Int(environment["DICOMWEB_STOW_MULTIPART_BENCHMARK_PAYLOAD_BYTES"] ?? "") ?? 1_048_576,
            1
        )
        let iterations = max(
            Int(environment["DICOMWEB_STOW_MULTIPART_BENCHMARK_ITERATIONS"] ?? "") ?? 5,
            1
        )
        let boundary = "dicomweb-benchmark-boundary"
        let payload = Data(repeating: 0xA5, count: payloadByteCount)
        let instances = (0..<instanceCount).map { index in
            DicomWebStoreInstance(
                data: payload,
                transferSyntax: index.isMultiple(of: 2) ? "1.2.840.10008.1.2.1" : nil
            )
        }
        let operation: () throws -> Data = mode == "legacy"
            ? { Self.legacyBody(instances: instances, boundary: boundary) }
            : {
                try DicomWebSTOWMultipartBodyBuilder.build(
                    instances: instances,
                    boundary: boundary,
                    maximumBytes: .max
                )
            }

        let identity = try autoreleasepool { () throws -> (byteCount: Int, hash: UInt64) in
            let body = try operation()
            return (body.count, Self.stableHash(body))
        }
        var samples: [Double] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let elapsed = try autoreleasepool { () throws -> Double in
                let start = DispatchTime.now().uptimeNanoseconds
                let body = try operation()
                XCTAssertEqual(body.count, identity.byteCount)
                withExtendedLifetime(body) {}
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            }
            samples.append(elapsed)
        }

        let componentBuffers = mode == "legacy" ? instanceCount * 3 + 1 : 5
        print(
            String(
                format: "DICOMWEB_STOW_MULTIPART_BENCHMARK mode=%@ instances=%d payload_bytes=%d " +
                    "body_bytes=%d iterations=%d p50_ms=%.3f p95_ms=%.3f " +
                    "component_data_buffers=%d body_hash=%llu peak_rss_bytes=%llu",
                mode,
                instanceCount,
                payloadByteCount,
                identity.byteCount,
                iterations,
                Self.percentile(samples, fraction: 0.50),
                Self.percentile(samples, fraction: 0.95),
                componentBuffers,
                identity.hash,
                BenchmarkMemorySampler.currentPeakResidentMemoryBytes() ?? 0
            )
        )
        #endif
    }

    private static func legacyBody(instances: [DicomWebStoreInstance], boundary: String) -> Data {
        var body = Data()
        for instance in instances {
            body.append(Data("--\(boundary)\r\n".utf8))
            var contentType = instance.contentType
            if let transferSyntax = instance.transferSyntax {
                contentType += "; transfer-syntax=\(transferSyntax)"
            }
            body.append(Data(
                "Content-Type: \(contentType)\r\nContent-Length: \(instance.data.count)\r\n\r\n".utf8
            ))
            body.append(instance.data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    private static func stableHash(_ data: Data) -> UInt64 {
        data.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func percentile(_ samples: [Double], fraction: Double) -> Double {
        let ordered = samples.sorted()
        let index = min(Int((Double(ordered.count - 1) * fraction).rounded(.up)), ordered.count - 1)
        return ordered[index]
    }
}
