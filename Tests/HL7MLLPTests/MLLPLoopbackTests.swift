import Foundation
import XCTest
import Network
import DicomCore
import HL7v2
@testable import HL7MLLP

actor MLLPTestProcessor: MLLPMessageProcessing {
    var calls = 0
    var contexts: [MLLPInboundContext] = []
    var outcome: MLLPProcessingOutcome
    var delay: TimeInterval
    init(_ outcome: MLLPProcessingOutcome = .accepted, delay: TimeInterval = 0) {
        self.outcome = outcome; self.delay = delay
    }
    func process(_ message: HL7Message, raw: Data, context: MLLPInboundContext) async -> MLLPProcessingOutcome {
        calls += 1; contexts.append(context)
        if delay > 0 { try? await mllpSleep(delay) }
        return outcome
    }
}

actor MLLPTestAuthorizer: DicomAuthorizing {
    let policyVersion: Int64 = 1
    var received: [(DicomAccessOperation, DicomResourceRef, DicomAccessContext)] = []
    func decide(principal: DicomPrincipal?, operation: DicomAccessOperation, resource: DicomResourceRef,
                context: DicomAccessContext) async -> DicomAuthorizationDecision {
        received.append((operation, resource, context))
        return .init(outcome: .deny, reason: .scopeMissing, policyVersion: 1, evaluatedAt: Date())
    }
}

struct MLLPTestPrincipal: MLLPPrincipalResolving {
    func principal(peer: MLLPPeer, tlsPeerIdentity: String?) async -> DicomPrincipal? { .anonymous }
}

let mllpLocalExposure = DicomExposurePolicy(mode: .localOnly, requireTLS: false, requireAuthentication: false)

@MainActor
func mllpEventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    for _ in 0..<300 {
        if await condition() { return }
        try? await mllpSleep(0.01)
    }
    XCTFail("Condition did not become true", file: file, line: line)
}

func mllpNext(_ connection: MLLPConnection) async throws -> MLLPFrame {
    try await withThrowingTaskGroup(of: MLLPFrame.self) { group in
        group.addTask {
            guard let frame = await connection.next() else { throw MLLPError.connectionClosed }
            await connection.consumed()
            return frame
        }
        group.addTask { try await mllpSleep(3); throw MLLPError.connectionFailed }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

func mllpRaw(_ port: UInt16, limits: MLLPLimits = .init()) async throws -> MLLPConnection {
    let connection = MLLPConnection(connection: NWConnection(host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: port)!, using: .tcp), limits: limits)
    try await connection.start()
    return connection
}

/// Wire peer used to emit ACKs our production listener deliberately never emits (late, duplicate, mismatched).
actor MLLPScriptedServer {
    let listener: NWListener
    var connections: [MLLPConnection] = []
    var tasks: [Task<Void, Never>] = []
    var count = 0
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters, on: .any)
    }
    func start(_ script: @escaping @Sendable (MLLPConnection, HL7Message) async -> Void) async throws -> UInt16 {
        listener.newConnectionHandler = { connection in Task { await self.accept(connection, script: script) } }
        return try await withCheckedThrowingContinuation { c in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: c.resume(returning: listener.port!.rawValue); listener.stateUpdateHandler = nil
                case .failed: c.resume(throwing: MLLPError.connectionFailed); listener.stateUpdateHandler = nil
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "MLLP.test"))
        }
    }
    func accept(_ network: NWConnection,
                script: @escaping @Sendable (MLLPConnection, HL7Message) async -> Void) {
        let transport = MLLPConnection(connection: network)
        connections.append(transport)
        tasks.append(Task {
            do {
                try await transport.start()
                while let frame = await transport.next() {
                    count += 1
                    if let message = try? frame.decodeHL7() { await script(transport, message) }
                    await transport.consumed()
                }
            } catch { }
        })
    }
    func stop() async {
        listener.cancel()
        for task in tasks { task.cancel() }
        for connection in connections { await connection.cancel() }
        tasks.removeAll(); connections.removeAll()
    }
}

func mllpSendACK(_ transport: MLLPConnection, _ message: HL7Message) async {
    if let ack = try? MLLPAckBuilder.ack(for: message, outcome: .accepted, policy: .init()),
       let data = try? HL7Serializer().serialize(ack), let wire = try? MLLPFramer.frame(data) {
        try? await transport.send(frame: wire)
    }
}

@MainActor
final class MLLPLoopbackTests: XCTestCase {
    func test_plainTCP_processingOutcomesAndStructuralERR() async throws {
        for outcome in [MLLPProcessingOutcome.accepted, .rejectedApplication(code: "app", text: "Rejected"),
                        .uncertain(reason: "Lost confirmation"), .error(text: "Failure")] {
            let processor = MLLPTestProcessor(outcome)
            let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure), processor: processor)
            let port = try await listener.start()
            let client = MLLPClient(host: "127.0.0.1", port: port)
            let result = try await client.send(mllpMessage(), timeout: 2)
            XCTAssertEqual(result.description, outcome.description == "accepted" ? "acknowledged(AA)" : "negativeAck(AE)")
            let contexts = await processor.contexts
            XCTAssertEqual(contexts.count, 1)
            XCTAssertFalse(contexts[0].transportSecured)
            await client.disconnect(); await listener.stop()
        }
        let processor = MLLPTestProcessor()
        let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure), processor: processor)
        let port = try await listener.start()
        let raw = try await mllpRaw(port)
        var invalid = mllpMessage(); invalid["PID"] = nil
        try await raw.send(frame: MLLPFramer.frame(HL7Serializer().serialize(invalid)))
        let frame = try await mllpNext(raw)
        let ack = try frame.decodeHL7()
        XCTAssertEqual(ack["MSA"]?[1][1][1][1].text, "AR")
        XCTAssertNotNil(ack["ERR"])
        let calls = await processor.calls; XCTAssertEqual(calls, 0)
        await raw.cancel(); await listener.stop()
    }

    func test_TLS_trustedServerAndWrongCAAndHostname() async throws {
        let fixture = try MLLPTLSTestMaterial.write(); defer { fixture.remove() }
        let serverTLS = DicomTLSConfiguration(mode: .enabled, material: .init(
            certificatePath: fixture.serverCertificatePath, privateKeyPath: fixture.serverPrivateKeyPath),
            securityProfile: .bcp195RFC8996)
        let processor = MLLPTestProcessor()
        let listener = MLLPListener(configuration: .init(tls: serverTLS, exposure: mllpLocalExposure), processor: processor)
        let port = try await listener.start()
        var limits = MLLPLimits(); limits.idleTimeout = 1
        for (ca, name, success) in [(fixture.caCertificatePath, "localhost", true),
                                  (fixture.wrongCACertificatePath, "localhost", false),
                                  (fixture.caCertificatePath, "wrong.invalid", false)] {
            let client = MLLPClient(host: "127.0.0.1", port: port, tls: .init(mode: .enabled,
                material: .init(trustStorePath: ca), securityProfile: .bcp195RFC8996), serverName: name,
                limits: limits, retry: .init(attempts: 1))
            do {
                let result = try await client.send(mllpMessage(), timeout: 2)
                XCTAssertTrue(success); XCTAssertEqual(result.description, "acknowledged(AA)")
            } catch { XCTAssertFalse(success) }
            await client.disconnect()
        }
        let contexts = await processor.contexts
        XCTAssertEqual(contexts.count, 1); XCTAssertTrue(contexts[0].transportSecured)
        await listener.stop()
    }

    func test_authorizerDeny_ARAuditAndNoProcessing() async throws {
        let sink = DicomInMemoryAuditSink()
        let audit = MLLPAuditing(recorder: .init(sinks: [sink], policy: .failClosed))
        let processor = MLLPTestProcessor()
        let authorizer = MLLPTestAuthorizer()
        let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure, listenerID: "test"),
            processor: processor, principals: MLLPTestPrincipal(), authorizer: authorizer, audit: audit)
        let port = try await listener.start()
        let client = MLLPClient(host: "127.0.0.1", port: port)
        let result = try await client.send(mllpMessage(), timeout: 2)
        XCTAssertEqual(result.description, "negativeAck(AR)")
        let calls = await processor.calls; XCTAssertEqual(calls, 0)
        let requests = await authorizer.received
        XCTAssertEqual(requests.first?.0, .receiveMessage)
        XCTAssertEqual(requests.first?.1, .init(kind: .configuration, id: "mllp:test"))
        XCTAssertEqual(requests.first?.2.protocol, .mllp)
        let events = await sink.events
        XCTAssertTrue(events.contains { $0.eventIdentification.eventTypeCode.contains { $0.displayName == "deny" } })
        await client.disconnect(); await listener.stop()
    }

    func test_fragmentedAndConcatenatedMessages_respectAccumulatorPressure() async throws {
        var limits = MLLPLimits(); limits.maxPendingFrames = 1
        let processor = MLLPTestProcessor(delay: 0.01)
        let listener = MLLPListener(configuration: .init(limits: limits, exposure: mllpLocalExposure), processor: processor)
        let port = try await listener.start(); let raw = try await mllpRaw(port)
        let first = mllpMessage("fragmented")
        let wire = try MLLPFramer.frame(HL7Serializer().serialize(first))
        for byte in wire { try await raw.send(frame: Data([byte])) }
        let ack = try await mllpNext(raw).decodeHL7()
        XCTAssertEqual(ack["MSA"]?[2][1][1][1].text, "fragmented")
        let messages = (0..<5).map { mllpMessage("concat\($0)") }
        let joined = try messages.reduce(into: Data()) { $0.append(try MLLPFramer.frame(HL7Serializer().serialize($1))) }
        try await raw.send(frame: joined)
        for message in messages {
            let ack = try await mllpNext(raw).decodeHL7()
            XCTAssertEqual(ack["MSA"]?[2][1][1][1].text, message.controlID)
        }
        let calls = await processor.calls; XCTAssertEqual(calls, 6)
        await raw.cancel(); await listener.stop()
    }

    func test_giantFrame_closesConnectionAndNewConnectionRecovers() async throws {
        var limits = MLLPLimits(); limits.maxMessageBytes = 512; limits.maxBufferedBytes = 1024
        let processor = MLLPTestProcessor()
        let listener = MLLPListener(configuration: .init(limits: limits, exposure: mllpLocalExposure), processor: processor)
        let port = try await listener.start(); let raw = try await mllpRaw(port)
        try await raw.send(frame: Data([11]) + Data(repeating: 65, count: 4096) + Data([28, 13]))
        await mllpEventually { await raw.isClosed }
        await mllpEventually { await listener.connections == 0 }
        let client = MLLPClient(host: "127.0.0.1", port: port)
        let result = try await client.send(mllpMessage(), timeout: 2)
        XCTAssertEqual(result.description, "acknowledged(AA)")
        await client.disconnect(); await listener.stop()
    }

    func test_idleAndLifetime_closeAndCancelReleasesWaitersBuffersTasks() async throws {
        for lifetime in [false, true] {
            var limits = MLLPLimits(); limits.idleTimeout = lifetime ? 5 : 0.1
            limits.connectionLifetime = lifetime ? 0.15 : 5
            let listener = MLLPListener(configuration: .init(limits: limits, exposure: mllpLocalExposure),
                                        processor: MLLPTestProcessor())
            let port = try await listener.start(); let raw = try await mllpRaw(port)
            await mllpEventually { await raw.isClosed }
            await mllpEventually { await listener.connections == 0 }
            await listener.stop()
            let metrics = await raw.metrics
            XCTAssertTrue(metrics.closed); XCTAssertEqual(metrics.activeTasks, 0)
            XCTAssertEqual(metrics.pending, 0); XCTAssertEqual(metrics.bufferedBytes, 0)
            let next = await raw.next(); XCTAssertNil(next)
        }
        let accumulator = MLLPAccumulator()
        _ = try await accumulator.feed(Data([11, 65, 28, 13, 11, 66]))
        await accumulator.close(discardPending: true)
        let stats = await accumulator.stats
        let closed = await accumulator.closed
        XCTAssertTrue(closed); XCTAssertEqual(stats.bufferedBytes, 0); XCTAssertEqual(stats.pending, 0)
    }

    func test_maxConnections_refusesExtraConnection() async throws {
        let listener = MLLPListener(configuration: .init(maxConnections: 1, exposure: mllpLocalExposure),
                                    processor: MLLPTestProcessor())
        let port = try await listener.start(); let first = try await mllpRaw(port)
        await mllpEventually { await listener.connections == 1 }
        let second = try? await mllpRaw(port)
        await mllpEventually { await listener.refusedConnections == 1 }
        let count = await listener.connections; XCTAssertEqual(count, 1)
        await first.cancel(); await second?.cancel(); await listener.stop()
    }

    func test_inFlight_suspendsAndCancellationReleasesCapacity() async throws {
        var limits = MLLPLimits(); limits.maxInFlight = 1
        let processor = MLLPTestProcessor(delay: 0.4)
        let listener = MLLPListener(configuration: .init(limits: limits, exposure: mllpLocalExposure), processor: processor)
        let port = try await listener.start()
        let client = MLLPClient(host: "127.0.0.1", port: port, limits: limits)
        let first = Task { try await client.send(mllpMessage("first"), timeout: 2) }
        await mllpEventually { await processor.calls == 1 }
        let second = Task { try await client.send(mllpMessage("second"), timeout: 2) }
        await mllpEventually { await client.diagnostics.waitingForCapacity == 1 }
        let calls = await processor.calls; XCTAssertEqual(calls, 1)
        second.cancel()
        do { _ = try await second.value; XCTFail("Cancelled send succeeded") } catch { }
        let result = try await first.value; XCTAssertEqual(result.description, "acknowledged(AA)")
        let diagnostics = await client.diagnostics
        XCTAssertEqual(diagnostics.waitingForCapacity, 0); XCTAssertEqual(diagnostics.pending, 0)
        await client.disconnect(); await listener.stop()
    }

    func test_ackTimeout_noAutomaticResendAndLateDuplicateIgnored() async throws {
        let server = try MLLPScriptedServer()
        let port = try await server.start { transport, message in
            try? await mllpSleep(0.15)
            await mllpSendACK(transport, message)
            await mllpSendACK(transport, message)
        }
        let client = MLLPClient(host: "127.0.0.1", port: port)
        let result = try await client.send(mllpMessage(), timeout: 0.05)
        XCTAssertEqual(result.description, "ackTimeout")
        await mllpEventually { await client.diagnostics.lateOrDuplicateACKs == 2 }
        let count = await server.count; XCTAssertEqual(count, 1)
        await client.disconnect(); await server.stop()
    }

    func test_mismatchedACK_keepsWaitingThenReturnsMatchOrMismatch() async throws {
        for eventualMatch in [false, true] {
            let server = try MLLPScriptedServer()
            let port = try await server.start { transport, message in
                var other = message; other["MSH"]?[10] = HL7Field(.text("other"))
                await mllpSendACK(transport, other)
                if eventualMatch {
                    try? await mllpSleep(0.03)
                    await mllpSendACK(transport, message)
                    await mllpSendACK(transport, message)
                }
            }
            let client = MLLPClient(host: "127.0.0.1", port: port)
            let result = try await client.send(mllpMessage(), timeout: 0.15)
            XCTAssertEqual(result.description, eventualMatch ? "acknowledged(AA)" : "ackMismatch")
            if eventualMatch { await mllpEventually { await client.diagnostics.lateOrDuplicateACKs == 1 } }
            let diagnostics = await client.diagnostics; XCTAssertEqual(diagnostics.mismatchedACKs, 1)
            await client.disconnect(); await server.stop()
        }
    }

    func test_reconnect_afterListenerRestart() async throws {
        let processor = MLLPTestProcessor()
        let first = MLLPListener(configuration: .init(exposure: mllpLocalExposure), processor: processor)
        let port = try await first.start()
        let client = MLLPClient(host: "127.0.0.1", port: port, reconnect: true)
        let result = try await client.send(mllpMessage(), timeout: 2)
        XCTAssertEqual(result.description, "acknowledged(AA)")
        await first.stop()
        let second = MLLPListener(configuration: .init(port: port, exposure: mllpLocalExposure), processor: processor)
        _ = try await second.start()
        try await mllpSleep(0.05)
        let next = try await client.send(mllpMessage(), timeout: 2)
        XCTAssertEqual(next.description, "acknowledged(AA)")
        await client.disconnect(); await second.stop()
    }

    func test_exposure_validatesBeforeBindAndLabOptIn() async throws {
        for mode in [DicomExposureMode.localOnly, .intranetLab, .external] {
            let configuration = MLLPListenerConfiguration(bindAddress: "0.0.0.0", exposure: .init(
                mode: mode, requireTLS: false, requireAuthentication: false))
            let listener = MLLPListener(configuration: configuration, processor: MLLPTestProcessor())
            do { _ = try await listener.start(); XCTFail("Unsafe exposure accepted") } catch { }
            let connections = await listener.connections; XCTAssertEqual(connections, 0)
        }
        let lab = MLLPListenerConfiguration(bindAddress: "0.0.0.0", exposure: .init(mode: .intranetLab,
            requireTLS: false, requireAuthentication: false, allowUnauthorizedIntranetLab: true))
        let findings = try lab.validateExposure(authorizerConfigured: false)
        XCTAssertTrue(findings.contains { $0.code == .labOptIn })
        let external = MLLPListenerConfiguration(bindAddress: "127.0.0.1", exposure: .init(mode: .external,
            requireTLS: false, requireAuthentication: false, allowUnauthorizedIntranetLab: true))
        XCTAssertThrowsError(try external.validateExposure(authorizerConfigured: false))
    }

    func test_ephemeralPort_isPinnedToLoopback() async throws {
        let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure), processor: MLLPTestProcessor())
        let port = try await listener.start()
        let endpoint = await listener.resolvedEndpoint
        XCTAssertEqual(endpoint, .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
        let raw = try await mllpRaw(port); await raw.cancel()
        // Enumerate a local non-loopback IPv4 address without opening any non-loopback listener.
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { XCTFail("getifaddrs failed"); await listener.stop(); return }
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        var nonLoopback: String?
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  current.pointee.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count),
                           nil, 0, NI_NUMERICHOST) == 0 { nonLoopback = String(cString: buffer); break }
        }
        if let nonLoopback {
            var limits = MLLPLimits(); limits.idleTimeout = 0.5
            let probe = MLLPConnection(connection: NWConnection(host: NWEndpoint.Host(nonLoopback),
                port: NWEndpoint.Port(rawValue: port)!, using: .tcp), limits: limits)
            do { try await probe.start(); XCTFail("Loopback listener accepted via non-loopback IP") } catch { }
            await probe.cancel()
        } else {
            await listener.stop()
            throw XCTSkip("No local non-loopback IPv4 address available for the negative pinning probe")
        }
        await listener.stop()
    }
}

extension MLLPLoopbackTests {
    func test_wireAckModes_originalEnhancedAndSuppression() async throws {
        for commit in [false, true] {
            for mode in [HL7AckMode.original, .always, .never, .errors, .successful] {
                let processor = MLLPTestProcessor()
                let policy = MLLPAckPolicy(commitAck: commit)
                let listener = MLLPListener(configuration: .init(ackPolicy: policy, exposure: mllpLocalExposure),
                                            processor: processor)
                let port = try await listener.start()
                let client = MLLPClient(host: "127.0.0.1", port: port, ackPolicy: policy)
                var message = mllpMessage()
                if mode != .original { message["MSH"]?[commit ? 15 : 16] = HL7Field(.text(mode.rawValue)) }
                let result = try await client.send(message, timeout: mode == .errors ? 0.1 : 2)
                let expected = mode == .never ? "noAckExpected" : mode == .errors ? "ackTimeout"
                    : commit && mode != .original ? "acknowledged(CA)" : "acknowledged(AA)"
                XCTAssertEqual(result.description, expected)
                await mllpEventually { await processor.calls == 1 }
                await client.disconnect(); await listener.stop()
            }
        }
    }

    func test_listenerGlobalLimit_serializesAcrossConnectionsAndStopDrains() async throws {
        var limits = MLLPLimits(); limits.maxInFlight = 1
        let processor = MLLPTestProcessor(delay: 0.1)
        let listener = MLLPListener(configuration: .init(limits: limits, exposure: mllpLocalExposure), processor: processor)
        let port = try await listener.start()
        let first = MLLPClient(host: "127.0.0.1", port: port)
        let second = MLLPClient(host: "127.0.0.1", port: port)
        let a = Task { try await first.send(mllpMessage(), timeout: 2) }
        await mllpEventually { await processor.calls == 1 }
        let b = Task { try await second.send(mllpMessage(), timeout: 2) }
        await mllpEventually { await listener.connections == 2 }
        let inFlight = await listener.inFlight; XCTAssertEqual(inFlight, 1)
        let calls = await processor.calls; XCTAssertEqual(calls, 1)
        let resultA = try await a.value; let resultB = try await b.value
        XCTAssertEqual(resultA.description, "acknowledged(AA)"); XCTAssertEqual(resultB.description, "acknowledged(AA)")
        await listener.stop(); await first.disconnect(); await second.disconnect()
        let tasks = await listener.activeTasks; let connections = await listener.connections
        XCTAssertEqual(tasks, 0); XCTAssertEqual(connections, 0)
    }

    func test_disconnect_cancelsPendingAndCapacityWaiterAndBoundedListenerStop() async throws {
        var limits = MLLPLimits(); limits.maxInFlight = 1
        let processor = MLLPTestProcessor(delay: 10)
        let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure, drainTimeout: 0.05),
                                    processor: processor)
        let port = try await listener.start()
        let client = MLLPClient(host: "127.0.0.1", port: port, limits: limits)
        let a = Task { try await client.send(mllpMessage(), timeout: 10) }
        await mllpEventually { await processor.calls == 1 }
        let b = Task { try await client.send(mllpMessage(), timeout: 10) }
        await mllpEventually { await client.diagnostics.waitingForCapacity == 1 }
        await client.disconnect()
        for task in [a, b] {
            do { _ = try await task.value; XCTFail("Disconnected send succeeded") } catch { }
        }
        let start = ContinuousClock.now
        await listener.stop()
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let tasks = await listener.activeTasks; let connections = await listener.connections
        let diagnostics = await client.diagnostics
        XCTAssertEqual(tasks, 0); XCTAssertEqual(connections, 0)
        XCTAssertEqual(diagnostics.pending, 0); XCTAssertEqual(diagnostics.waitingForCapacity, 0)
    }

    func test_idempotentOptIn_boundsResendAttempts() async throws {
        let server = try MLLPScriptedServer()
        let port = try await server.start { _, _ in }
        let client = MLLPClient(host: "127.0.0.1", port: port,
            retry: .init(attempts: 2, baseDelay: 0.01, maxDelay: 0.01, jitter: 0))
        let result = try await client.send(mllpMessage(), timeout: 0.05, resendPolicy: .idempotent)
        XCTAssertEqual(result.description, "ackTimeout")
        let count = await server.count; XCTAssertEqual(count, 2)
        await client.disconnect(); await server.stop()
    }

    func test_sameControlIDInFlight_isRejected() async throws {
        let processor = MLLPTestProcessor(delay: 0.1)
        let listener = MLLPListener(configuration: .init(exposure: mllpLocalExposure), processor: processor)
        let port = try await listener.start()
        let client = MLLPClient(host: "127.0.0.1", port: port)
        let message = mllpMessage()
        let first = Task { try await client.send(message, timeout: 2) }
        await mllpEventually { await processor.calls == 1 }
        do { _ = try await client.send(message, timeout: 2); XCTFail("Duplicate ID accepted") }
        catch { XCTAssertTrue(error is MLLPError) }
        _ = try await first.value
        await client.disconnect(); await listener.stop()
    }
}
