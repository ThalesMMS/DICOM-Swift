import XCTest
import ArgumentParser
import DicomCore
@testable import dicomtool

final class SecureDefaultsCommandTests: XCTestCase, @unchecked Sendable {
    func test_serveNonLoopbackRefusesBeforeReadingDirectory() async throws {
        let command = try WebCommand.Serve.parse(["/unused-synthetic", "--bind", "0.0.0.0"])
        do { _ = try await command.start(); XCTFail("Unprotected server accepted") }
        catch { XCTAssertTrue(error is DicomExposureValidationError) }
    }
    func test_listenNonLoopbackRefusesBeforeCreatingDirectory() throws {
        let command = try NetCommand.Listen.parse(["/unused-synthetic", "--host", "0.0.0.0"])
        XCTAssertThrowsError(try command.start()) { XCTAssertTrue($0 is DicomExposureValidationError) }
    }
    func test_labFlagsAndSecureExposureValidation() throws {
        let web = try WebCommand.Serve.parse(["/unused", "--host", "0.0.0.0", "--allow-insecure-lab"])
        let net = try NetCommand.Listen.parse(["/unused", "--host", "0.0.0.0", "--intranet-lab"])
        XCTAssertTrue(web.allowInsecureLab)
        XCTAssertTrue(net.intranetLab)
        for host in [web.bind, net.options.host] {
            let policy = try ServerSecurityOptions.exposure(host: host, tls: false, authentication: false, lab: true)
            XCTAssertTrue(policy.allowUnauthorizedIntranetLab)
        }
        XCTAssertThrowsError(try ServerSecurityOptions.exposure(host: "0.0.0.0", tls: true, authentication: false, lab: false))
        XCTAssertNoThrow(try ServerSecurityOptions.exposure(host: "0.0.0.0", tls: true, authentication: true, lab: false))
    }
    func test_auditAndScopesOptionsParse() throws {
        let command = try WebCommand.Serve.parse(["/unused", "--principal-scopes", "export", "--audit-syslog",
            "127.0.0.1:6514", "--audit-tls", "--audit-fail-closed"])
        XCTAssertEqual(command.security.principalScopes, ["export"])
        XCTAssertNoThrow(try command.security.recorder())
    }
}
