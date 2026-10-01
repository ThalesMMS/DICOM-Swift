#if canImport(Darwin) && canImport(Network)
import Darwin
import XCTest
@testable import DicomCore

final class DicomDIMSEListenerBindingTests: XCTestCase {
    func test_ephemeralPort_acceptsOnlyConfiguredLoopbackAddress() async throws {
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS", port: 0)
        configuration.bindAddress = "127.0.0.1"
        let server = DicomDIMSEServer(configuration: configuration, exposure: .defaults(for: .localOnly))
        addTeardownBlock { await server.stop() }
        try server.start()
        let port = try XCTUnwrap(server.listeningPort)
        XCTAssertNotEqual(port, 0)
        XCTAssertEqual(try connectError(to: "127.0.0.1", port: port), 0)
        XCTAssertEqual(try connectError(to: "::1", port: port), ECONNREFUSED,
                       "An ephemeral listener must not accept traffic addressed to an unconfigured host")
    }

    func test_associationRequestLargerThanDefaultPDULimit_isAccepted() throws {
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS", port: 0)
        configuration.bindAddress = "127.0.0.1"
        let server = DicomDIMSEServer(configuration: configuration, exposure: .defaults(for: .localOnly))
        addTeardownBlock { await server.stop() }
        try server.start()
        let port = try XCTUnwrap(server.listeningPort)

        // 128 contexts x 4 transfer syntaxes, like pynetdicom StoragePresentationContexts or
        // `storescu -xf storescu.cfg Default` (issue #2791).
        let transferSyntaxUIDs = [
            DicomTransferSyntax.explicitVRLittleEndian.rawValue,
            DicomTransferSyntax.implicitVRLittleEndian.rawValue,
            "1.2.840.10008.1.2.1.99",
            "1.2.840.10008.1.2.4.50"
        ]
        let abstractSyntaxUIDs = [DicomNetworkUID.verificationSOPClass]
            + (1...127).map { "1.2.826.0.1.3680043.2.1143.107.104.103.115.\($0)" }
        let contexts = abstractSyntaxUIDs.enumerated().map { index, uid in
            DicomPresentationContextRequest(id: UInt8(index * 2 + 1), abstractSyntaxUID: uid,
                                            transferSyntaxUIDs: transferSyntaxUIDs)
        }
        let request = DicomAssociationRequest(calledAETitle: "ISIS", callingAETitle: "PEER",
                                              presentationContexts: contexts)
        let encoded = try DicomPDUCodec.encode(.associationRequest(request))
        XCTAssertGreaterThan(encoded.count, Int(configuration.storage.maximumPDULength))

        let transport = DicomTCPAssociationTransport(host: "127.0.0.1", port: port, timeout: 5)
        try transport.open()
        defer { transport.close() }
        try transport.writePDU(encoded)
        guard case .associationAccept(let accept) = try DicomPDUCodec.decode(transport.readPDU()) else {
            return XCTFail("Expected A-ASSOCIATE-AC")
        }
        XCTAssertEqual(accept.presentationContexts.first { $0.id == 1 }?.result, .acceptance)
    }

    private func connectError(to host: String, port: UInt16) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST
        hints.ai_socktype = SOCK_STREAM
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &resolved) == 0, let resolved else { throw POSIXError(.EINVAL) }
        defer { freeaddrinfo(resolved) }
        let address = resolved.pointee
        let descriptor = Darwin.socket(address.ai_family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EINVAL) }
        let result = Darwin.connect(descriptor, address.ai_addr, address.ai_addrlen)
        if result == 0 { return 0 }
        guard errno == EINPROGRESS else { return errno }
        var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&pending, 1, 1_000) > 0 else { return ETIMEDOUT }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return errno }
        return error
    }
}
#endif
