import ArgumentParser
import DicomCore
import Foundation
import XCTest
@testable import dicomtool

final class LDAPCommandTests: XCTestCase {
    func test_denialReport_hasStableReasonsAndExcludesOperationalErrors() {
        for (error, reason) in [(DicomLDAPError.invalidCredentials, "invalidCredentials"),
                                (.unmappedIdentity, "unmappedIdentity"),
                                (.authorizationDenied, "authorizationDenied")] {
            XCTAssertEqual(LDAPCommand.denialReport(for: error), ["outcome": "deny", "reason": reason])
        }
        for error in [DicomLDAPError.tlsFailure, .timeout, .unavailable, .invalidConfiguration, .malformedResponse] {
            XCTAssertNil(LDAPCommand.denialReport(for: error), "\(error)")
        }
    }

    func test_cliRegistered_andPasswordArgumentsAreNotSupported() throws {
        XCTAssertTrue(DicomTool.configuration.subcommands.contains { $0 == LDAPCommand.self })
        _ = try LDAPCommand.parse(["--config", "/unused", "--username", "alice"])
        XCTAssertThrowsError(try LDAPCommand.parse(["--config", "/unused", "--username", "alice", "--password", "unused"]))
        XCTAssertFalse(LDAPCommand.helpMessage().contains("--secret"))
    }
    func test_passwordInput_preservesSpacesAndSeparatesSearchAndUserLines() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(" search secret \n user secret \n".utf8))
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try LDAPCommand.readPassword(pipe.fileHandleForReading), Data(" search secret ".utf8))
        XCTAssertEqual(try LDAPCommand.readPassword(pipe.fileHandleForReading), Data(" user secret ".utf8))
        XCTAssertThrowsError(try LDAPCommand.readPassword(pipe.fileHandleForReading))
    }
    func test_passwordInput_emptyAndOversizedLines_refused() throws {
        for input in [Data([10]), Data(repeating: 65, count: 4097)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try input.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            XCTAssertThrowsError(try LDAPCommand.readPassword(handle))
        }
    }
}
