import Foundation

public protocol DicomWebNotificationConnection: Sendable {
    func send(text: String) async throws
    func close() async
}

public enum DicomWebNotificationDeliveryError: Error, Sendable {
    case noConnection
    case writeFailure
}

/// Connected endpoints only. Event reports are never retained for later delivery.
public actor DicomWebNotificationHub {
    private var connections: [String: [UUID: any DicomWebNotificationConnection]] = [:]
    public init() {}
    @discardableResult
    public func register(_ connection: any DicomWebNotificationConnection, ae: String) -> UUID {
        let id = UUID()
        connections[ae, default: [:]][id] = connection
        return id
    }
    public func unregister(_ id: UUID, ae: String) {
        connections[ae]?[id] = nil
        if connections[ae]?.isEmpty == true { connections[ae] = nil }
    }
    public func send(text: String, to ae: String) async throws {
        guard let endpoints = connections[ae], !endpoints.isEmpty else {
            throw DicomWebNotificationDeliveryError.noConnection
        }
        var failed = false
        for (id, connection) in endpoints {
            do { try await connection.send(text: text) }
            catch { failed = true; unregister(id, ae: ae); await connection.close() }
        }
        if failed { throw DicomWebNotificationDeliveryError.writeFailure }
    }
    public func close() async {
        let active = connections.values.flatMap { $0.values }
        connections = [:]
        for connection in active { await connection.close() }
    }
}

public struct DicomWebNotificationEventSink: DicomUnifiedProcedureStepEventSink {
    public let hub: DicomWebNotificationHub
    public init(hub: DicomWebNotificationHub) { self.hub = hub }
    // A subscription remains valid while its user agent has no open connection.
    public func canDeliver(to receivingAETitle: String) async throws -> Bool { true }
    public func deliver(_ event: DicomUnifiedProcedureStepEvent, to receivingAETitle: String) async throws {
        try await hub.send(text: Self.encode(event), to: receivingAETitle)
    }
    public static func encode(_ event: DicomUnifiedProcedureStepEvent, messageID: UInt16 = 1) throws -> String {
        var dataSet = event.dataSet
        dataSet.set(upsString(0x00000002, "1.2.840.10008.5.1.4.34.6.4", .UI))
        dataSet.set(.init(tag: 0x00000110, vr: .US, value: .unsignedIntegers([UInt(messageID)])))
        dataSet.set(upsString(0x00001000, event.sopInstanceUID, .UI))
        dataSet.set(.init(tag: 0x00001002, vr: .US, value: .unsignedIntegers([UInt(event.typeID)])))
        if let requester = DicomWebWorklistContext.requester {
            dataSet.set(upsString(0x00741236, requester, .AE))
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: DicomJSONCodec.object(from: dataSet),
                                                         options: [.sortedKeys]), as: UTF8.self)
    }
}

enum DicomWebWorklistContext {
    @TaskLocal static var requester: String?
}
