//
//  ClinicalDICOMKitInteropTests.swift
//  DicomCoreTests
//

import Foundation
import XCTest
@testable import DicomCore

final class ClinicalDICOMKitInteropTests: XCTestCase {
    func test_readDICOMKitSyntheticCTPreservesMetadataAndStoredPixels() throws {
        let root = try requiredDirectory(environmentVariable: "DICOMKIT_SYNTHETIC_FIXTURE_ROOT")
        let url = root.appendingPathComponent("syn-ct.dcm")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("The pinned DICOMKit checkout does not contain syn-ct.dcm.")
        }

        let decoder = try DCMDecoder(contentsOf: url)
        XCTAssertTrue(decoder.isValid())
        XCTAssertEqual(decoder.info(for: .modality), "CT")
        XCTAssertEqual(decoder.width, 8)
        XCTAssertEqual(decoder.height, 8)
        XCTAssertEqual(decoder.intValue(for: DicomTag.bitsStored.rawValue), 12)
        XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), (0..<64).map(UInt16.init))
    }

    func test_readDICOMKitTranscodesPreservesMetadataAndLosslessPixels() throws {
        let fixtureRoot = try requiredDirectory(environmentVariable: "DICOMKIT_SYNTHETIC_FIXTURE_ROOT")
        let transcodeRoot = try requiredDirectory(environmentVariable: "DICOMKIT_TRANSCODE_OUTPUT_DIR")
        let reference = try DCMDecoder(contentsOf: fixtureRoot.appendingPathComponent("syn-ct.dcm"))
        let expectedPixels = try XCTUnwrap(reference.getPixels16())
        let outputs = try FileManager.default.contentsOfDirectory(
            at: transcodeRoot,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "dcm" }

        XCTAssertFalse(outputs.isEmpty)
        for output in outputs {
            let decoder = try DCMDecoder(contentsOf: output)
            XCTAssertTrue(decoder.isValid(), output.lastPathComponent)
            XCTAssertEqual(decoder.info(for: .modality), "CT", output.lastPathComponent)
            XCTAssertEqual(decoder.width, reference.width, output.lastPathComponent)
            XCTAssertEqual(decoder.height, reference.height, output.lastPathComponent)
            XCTAssertEqual(try XCTUnwrap(decoder.getPixels16()), expectedPixels, output.lastPathComponent)
        }
    }

    private func requiredDirectory(environmentVariable: String) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment[environmentVariable], !path.isEmpty else {
            throw XCTSkip("Set \(environmentVariable) through Scripts/conformance/run_dicomkit_interop.sh.")
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            XCTFail("\(environmentVariable) is not a directory: \(path)")
            return url
        }
        return url
    }
}
