import XCTest
@testable import DicomCore
final class DicomExposurePolicyTests: XCTestCase {
    func test_externalWithoutTLSOrAuth_throwsFindings() {
        let policy = DicomExposurePolicy.defaults(for: .external)
        XCTAssertThrowsError(try policy.validate(bindAddress: "0.0.0.0", tlsEnabled: false, authenticationConfigured: false)) {
            XCTAssertEqual(($0 as? DicomExposureValidationError)?.findings.map(\.code), [.tlsRequired, .authenticationRequired])
        }
        XCTAssertNoThrow(try policy.validate(bindAddress: "0.0.0.0", tlsEnabled: true, authenticationConfigured: true))
        XCTAssertFalse(policy.allowAnonymousQuery)
    }
    func test_labOptIn_isAuditableAndNeverAppliesToExternal() throws {
        let policy = DicomExposurePolicy(mode: .intranetLab, requireTLS: false,
            requireAuthentication: true, allowUnauthorizedIntranetLab: true)
        XCTAssertEqual(try policy.validate(bindAddress: "0.0.0.0", tlsEnabled: false,
            authenticationConfigured: false), [.init(code: .labOptIn, isError: false)])
        let external = DicomExposurePolicy(mode: .external, requireTLS: false,
            requireAuthentication: false, allowUnauthorizedIntranetLab: true)
        XCTAssertThrowsError(try external.validate(bindAddress: "0.0.0.0", tlsEnabled: true,
            authenticationConfigured: false))
    }
    func test_intranetRequiresAuth_TLSOptional() {
        let policy = DicomExposurePolicy.defaults(for: .intranetLab)
        XCTAssertThrowsError(try policy.validate(bindAddress: "192.168.1.1", tlsEnabled: false, authenticationConfigured: false))
        XCTAssertNoThrow(try policy.validate(bindAddress: "192.168.1.1", tlsEnabled: false, authenticationConfigured: true))
    }
    func test_localOnlyRequiresNumericLoopback() {
        let policy = DicomExposurePolicy.defaults(for: .localOnly)
        for address in ["127.0.0.1", "127.10.20.30", "::1"] {
            XCTAssertNoThrow(try policy.validate(bindAddress: address, tlsEnabled: false, authenticationConfigured: true))
        }
        for address in ["0.0.0.0", "::", "localhost", "127.evil", "127.0.0.256", "192.168.1.1"] {
            XCTAssertThrowsError(try policy.validate(bindAddress: address, tlsEnabled: true, authenticationConfigured: true))
        }
    }
}
