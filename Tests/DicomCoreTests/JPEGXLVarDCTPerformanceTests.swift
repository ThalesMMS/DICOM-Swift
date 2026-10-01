import Foundation
@testable import DicomJPEGXL
import XCTest

final class JPEGXLVarDCTPerformanceTests: XCTestCase {
    func test_preCancelledDecodePropagatesCancellationBeforeParsing() async {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try JXLDecoder().decode(Data())
        }
        do {
            _ = try await worker.value
            XCTFail("A cancelled decode must not return an image")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func test_cancelDuringMultiGroupDecodePropagatesCancellation() async throws {
        guard let directory = ProcessInfo.processInfo.environment["DICOM_JPEGXL_LOSSY_CORPUS_DIRECTORY"] else {
            throw XCTSkip("DICOM_JPEGXL_LOSSY_CORPUS_DIRECTORY unset")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("rgb8_2048_d1.jxl"))
        let worker = Task.detached {
            var decoder = JXLDecoder()
            decoder.beforeVarDCTGroup = { group in
                if group == 1 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            return try decoder.decode(data)
        }
        do {
            _ = try await worker.value
            XCTFail("A cancelled multi-group decode must not return a partial image")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
