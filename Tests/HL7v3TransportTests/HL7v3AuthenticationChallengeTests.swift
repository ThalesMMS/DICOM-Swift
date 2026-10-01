import DicomCore
import Foundation
import HL7v3CDA
import XCTest
@testable import HL7v3Transport

final class HL7v3AuthenticationChallengeTests: XCTestCase {
    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
    }

    func test_pinnedRootsWithoutServerTrust_cancelOnlyTrustChallenges() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://example.test")!)
        for method in [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPBasic] {
            let delegate = HL7v3RedirectBlockingDelegate(maximumResponseBytes: 1024, trust: .pinnedRoots([]), serverName: "example.test")
            let space = URLProtectionSpace(host: "example.test", port: 443, protocol: "https", realm: nil, authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
                                                       failureResponse: nil, error: nil, sender: Sender())
            XCTAssertNil(space.serverTrust)
            let disposition = await withCheckedContinuation { continuation in
                delegate.urlSession(session, task: task, didReceive: challenge) { disposition, _ in
                    continuation.resume(returning: disposition)
                }
            }
            XCTAssertEqual(disposition, method == NSURLAuthenticationMethodServerTrust ? .cancelAuthenticationChallenge : .performDefaultHandling)
        }
    }

    func test_policyEquality_includesEachXMLLimit() {
        let base = HL7v3TransportPolicy()
        var other = base
        other.xmlLimits.maxBytes += 1
        XCTAssertNotEqual(base, other)
        other = base; other.xmlLimits.maxDepth += 1
        XCTAssertNotEqual(base, other)
        other = base; other.xmlLimits.maxElements += 1
        XCTAssertNotEqual(base, other)
        other = base; other.xmlLimits.maxAttributeLength += 1
        XCTAssertNotEqual(base, other)
        other = base; other.xmlLimits.maxTextLength += 1
        XCTAssertNotEqual(base, other)
        XCTAssertEqual(base, HL7v3TransportPolicy())
    }

    func test_explicitCancellation_preservesCancellationBeforeAndAfterBodySend() async {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for bodySent in [false, true] {
            let task = session.dataTask(with: URL(string: "https://example.test")!)
            let delegate = HL7v3RedirectBlockingDelegate(maximumResponseBytes: 1024, trust: .system, serverName: nil)
            delegate.cancel()
            do {
                let _: DicomWebHTTPResponse = try await withCheckedThrowingContinuation { continuation in
                    delegate.start(task: task, continuation: continuation)
                    if bodySent {
                        delegate.urlSession(session, task: task, didSendBodyData: 1, totalBytesSent: 1, totalBytesExpectedToSend: 1)
                    }
                    delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
                }
                XCTFail("Explicit cancellation must throw")
            } catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        }
    }
}
