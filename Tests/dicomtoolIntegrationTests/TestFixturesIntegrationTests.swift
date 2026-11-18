//
//  TestFixturesIntegrationTests.swift
//  dicomtoolIntegrationTests
//
//  Integration tests that rely on real fixture files.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest

final class TestFixturesIntegrationTests: XCTestCase {
    func testValidDICOMFileDiscovery() throws {
        _ = try TestFixtures.validDICOMFile()
    }
}
