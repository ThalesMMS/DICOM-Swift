//
//  TestFixtures.swift
//  dicomtoolIntegrationTests
//
//  Shared helpers for locating test DICOM fixtures.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
import XCTest
import DicomTestSupport

enum TestFixtures {
    static func fixturesPath() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DicomCoreTests")
            .appendingPathComponent("Fixtures")
    }

    static func validDICOMFile() throws -> URL {
        try DicomTestRuntimePreflight.require(.bundledSyntheticFixtures)
        let fixturesPath = fixturesPath()

        guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
            throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
                capability: .bundledSyntheticFixtures,
                kind: .regression,
                message: "Fixtures directory not found: \(fixturesPath.path)."
            ))
        }

        let ctFile = fixturesPath.appendingPathComponent("CT").appendingPathComponent("ct_synthetic.dcm")
        if FileManager.default.fileExists(atPath: ctFile.path) {
            return ctFile
        }

        let enumerator = FileManager.default.enumerator(at: fixturesPath, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            if ext == "dcm" || ext == "dicom" {
                return fileURL
            }
        }

        throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
            capability: .bundledSyntheticFixtures,
            kind: .regression,
            message: "No DICOM files found in required bundled Fixtures directory."
        ))
    }
}
