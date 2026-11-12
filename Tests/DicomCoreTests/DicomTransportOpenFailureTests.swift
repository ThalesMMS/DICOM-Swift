//
//  DicomTransportOpenFailureTests.swift
//  DicomCoreTests
//
//  Issue #1696: `open()` waited out its whole timeout for a peer that had already refused it, then
//  blamed TCP.
//
//  `NWConnection` does not move to `.failed` when it thinks the situation could improve on its own.
//  It stops at `.waiting`, holding the reason. A refused port lands there in milliseconds; so does
//  a rejected certificate. The state handler treated everything but `.ready`/`.failed` as nothing
//  worth waking up for, so the caller sat until the deadline and was then told the connection timed
//  out — the one explanation that was not true.
//
//  These measure the clock, not only the error. An assertion on the error alone would still pass
//  against the version that took a minute to produce it.
//
//  Thales Matheus Mendonça Santos — July 2026
//

import Foundation
import XCTest
@testable import DicomCore
#if canImport(Network)
import Network
#endif

final class DicomTransportOpenFailureTests: XCTestCase {

    func test_waitingErrorClassification_onlyTreatsNonRecoverableFailuresAsTerminal() throws {
        #if canImport(Network)
        XCTAssertTrue(
            DicomTCPAssociationTransport.isTerminalOpenWaitingError(
                .posix(.ECONNREFUSED)
            )
        )
        XCTAssertFalse(
            DicomTCPAssociationTransport.isTerminalOpenWaitingError(
                .posix(.ENETDOWN)
            )
        )
        #else
        throw XCTSkip("Network framework is unavailable on this platform.")
        #endif
    }

    /// Nothing listens on port 1. The kernel says so at once, and the caller
    /// hears it at once rather than at the end of its timeout.
    func test_openAgainstARefusedPort_failsLongBeforeTheTimeout() throws {
        #if canImport(Network)
        let timeout: TimeInterval = 30
        let transport = DicomTCPAssociationTransport(
            host: "127.0.0.1",
            port: 1,
            timeout: timeout
        )
        defer { transport.close() }

        let startedAt = Date()
        XCTAssertThrowsError(try transport.open()) { error in
            // Not a timeout: the refusal is the reason, and it is what the
            // caller has to be able to report.
            if let networkError = error as? DicomNetworkError,
               case .networkTimeout = networkError {
                XCTFail("A refused connection was reported as a timeout")
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(
            elapsed,
            timeout / 3,
            "A refused connection took \(elapsed)s of a \(timeout)s budget — `.waiting` is being ignored again"
        )
        XCTAssertFalse(transport.isOpen)
        #else
        throw XCTSkip("Network framework is unavailable on this platform.")
        #endif
    }

    /// The control: the same transport against a port that is listening opens.
    /// Without it, the test above would pass just as well against an `open()`
    /// that failed instantly on everything.
    func test_openAgainstAListeningPort_succeeds() throws {
        #if canImport(Network)
        let listener = try NWListener(using: .tcp, on: .any)
        let ready = XCTestExpectation(description: "listener ready")
        listener.newConnectionHandler = { $0.cancel() }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: DispatchQueue(label: "DicomTransportOpenFailureTests.listener"))
        defer { listener.cancel() }
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let transport = DicomTCPAssociationTransport(host: "127.0.0.1", port: port, timeout: 5)
        defer { transport.close() }

        XCTAssertNoThrow(try transport.open())
        XCTAssertTrue(transport.isOpen)
        #else
        throw XCTSkip("Network framework is unavailable on this platform.")
        #endif
    }
}
