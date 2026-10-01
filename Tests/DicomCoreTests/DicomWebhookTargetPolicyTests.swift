import DicomCore
import Foundation
import XCTest

final class DicomWebhookTargetPolicyTests: XCTestCase {
    func test_httpDenied_explicitExceptionOnly() throws {
        let url = URL(string: "http://example.test")!
        XCTAssertThrowsError(try DicomWebhookTargetPolicy(resolve: { _ in ["8.8.8.8"] }).validate(url))
        XCTAssertNoThrow(try DicomWebhookTargetPolicy(allowInsecureForHosts: ["example.test"],
            resolve: { _ in ["8.8.8.8"] }).validate(url))
    }
    func test_credentialsAndInvalidPort_rejected() {
        for text in ["https://u:p@example.test", "https://example.test:0", "https://example.test:65536"] {
            XCTAssertThrowsError(try DicomWebhookTargetPolicy(resolve: { _ in ["8.8.8.8"] }).validate(URL(string: text)!))
        }
    }
    func test_literalRestrictedClasses_denied() {
        for host in ["127.0.0.1", "10.2.3.4", "172.16.0.1", "192.168.1.1", "169.254.1.1", "224.0.0.1",
                     "0.0.0.0", "[::]", "[::1]", "[fc00::1]", "[fe80::1]", "[ff02::1]", "[::ffff:127.0.0.1]",
                     "[::ffff:192.168.0.1]", "100.64.0.1"] {
            XCTAssertThrowsError(try DicomWebhookTargetPolicy().validate(URL(string: "https://\(host)")!), host)
        }
    }
    func test_publicLiterals_acceptedWithoutResolver() {
        for host in ["8.8.8.8", "[2606:4700:4700::1111]"] {
            XCTAssertNoThrow(try DicomWebhookTargetPolicy(resolve: { _ in throw DicomWebhookTargetError.resolutionFailed })
                .validate(URL(string: "https://\(host)")!))
        }
    }
    func test_allowlistedHost_bypassesAddressClassButNotHTTPS() {
        let policy = DicomWebhookTargetPolicy(allowedHosts: ["EXAMPLE.TEST"], resolve: { _ in ["10.0.0.1"] })
        XCTAssertNoThrow(try policy.validate(URL(string: "https://example.test")!))
        XCTAssertThrowsError(try policy.validate(URL(string: "http://example.test")!))
        XCTAssertThrowsError(try policy.validate(URL(string: "https://sub.example.test")!))
    }
    func test_dnsAnyPrivateAnswer_rejected() {
        let policy = DicomWebhookTargetPolicy(resolve: { _ in ["8.8.8.8", "192.168.0.1"] })
        XCTAssertThrowsError(try policy.validate(URL(string: "https://public-name.test")!))
    }
    func test_loopbackAndPrivatePermissions_areSeparate() {
        XCTAssertNoThrow(try DicomWebhookTargetPolicy(allowLoopback: true).validate(URL(string: "https://127.0.0.1")!))
        XCTAssertThrowsError(try DicomWebhookTargetPolicy(allowPrivateNetworks: true)
            .validate(URL(string: "https://127.0.0.1")!))
        XCTAssertNoThrow(try DicomWebhookTargetPolicy(allowPrivateNetworks: true).validate(URL(string: "https://10.1.1.1")!))
    }
    func test_resolutionFailureAndEmptyAnswers_failClosed() {
        for answers in [[], ["not-an-address"]] as [[String]] {
            XCTAssertThrowsError(try DicomWebhookTargetPolicy(allowedHosts: ["example.test"], resolve: { _ in answers })
                .validate(URL(string: "https://example.test")!))
        }
    }
}
