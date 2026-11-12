//
//  DicomRuntimeTrapHardeningTests.swift
//  DicomCoreTests
//
//  Checks typed errors for unsupported buffer types and codec runtime failures.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest
@testable import DicomCore

final class DicomRuntimeTrapHardeningTests: XCTestCase {
    func testUnsupportedBufferPoolTypeDoesNotTrap() {
        let pool = BufferPool.shared
        pool.clear()
        pool.resetStatistics()

        let buffer = pool.acquire(type: [Double].self, count: 8)

        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(pool.statistics.misses, 1)

        pool.release(buffer)
        XCTAssertEqual(pool.statistics.currentPoolSize, 0)
    }

    func testWindowingAutoModeFallsBackToVDSP() throws {
        let pixels = (0..<128).map { UInt16($0 * 16) }
        let auto = try XCTUnwrap(DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels,
            center: 512,
            width: 1024,
            processingMode: .auto
        ))
        let vdsp = try XCTUnwrap(DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels,
            center: 512,
            width: 1024,
            processingMode: .vdsp
        ))

        XCTAssertEqual(auto, vdsp)
    }

    func testCodecRuntimeFailuresThrowTypedErrors() {
        XCTAssertThrowsError(try DicomJPEGLSCodec.decode(Data())) { error in
            XCTAssertTrue(error is DICOMError)
        }

        XCTAssertThrowsError(try DicomJPEG2000Codec.decode(Data())) { error in
            XCTAssertTrue(error is DICOMError)
        }
    }

    func testDICOMErrorObjCArchivingDoesNotTrap() throws {
        let error = DICOMErrorObjC(from: .unknown(underlyingError: "archive smoke"))
        let data = try NSKeyedArchiver.archivedData(withRootObject: error, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: DICOMErrorObjC.self, from: data)

        XCTAssertNotNil(decoded)
    }
}
