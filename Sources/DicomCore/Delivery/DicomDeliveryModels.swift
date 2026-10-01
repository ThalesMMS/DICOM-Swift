import Foundation

public enum DicomDeliveryPriority: String, Codable, Sendable { case stat, routine }
public enum DicomDeliveryState: String, Codable, CaseIterable, Sendable {
    case pending, leased, retryWait, delivered, uncertain, deadLetter, cancelled
}
public enum DicomDeliveryErrorClass: String, Codable, Hashable, Sendable {
    case transient, permanent, uncertain, rejectedByDestination, signatureRejected, cancelled
}
public enum DicomDeliveryDestinationKind: String, Codable, Sendable { case dimseStore, stowRS, webhook }

public struct DicomDeliveryItem: Codable, Equatable, Sendable {
    public enum Payload: Codable, Equatable, Sendable { case objects([URL]), event(DicomWebhookEvent) }
    public var resource: DicomResourceRef?
    public var deliveryID: String
    public var eventID: String
    public var destinationID: String
    public var destinationKind: DicomDeliveryDestinationKind
    public var idempotencyKey: String
    public var priority: DicomDeliveryPriority
    public var state: DicomDeliveryState
    public var attempts: Int
    public var nextAttemptAt: Date
    public var leaseOwner: String?
    public var leaseUntil: Date?
    public var lastErrorClass: DicomDeliveryErrorClass?
    public var lastError: String?
    public var payload: Payload
    public var byteCount: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var receipt: DicomDeliveryReceipt?

    public init(deliveryID: String = UUID().uuidString, eventID: String, destinationID: String,
                destinationKind: DicomDeliveryDestinationKind, idempotencyKey: String,
                priority: DicomDeliveryPriority = .routine, payload: Payload, byteCount: Int64 = 0,
                now: Date = Date(), resource: DicomResourceRef? = nil) {
        self.resource = resource
        self.deliveryID = deliveryID
        self.eventID = eventID
        self.destinationID = destinationID
        self.destinationKind = destinationKind
        self.idempotencyKey = idempotencyKey
        self.priority = priority
        self.payload = payload
        self.byteCount = byteCount
        state = .pending
        attempts = 0
        nextAttemptAt = now
        createdAt = now
        updatedAt = now
    }
}

public struct DicomDeliveryReceipt: Codable, Equatable, Sendable {
    /// Classification is explicit; free-form reason strings never authorize retries.
    public struct Object: Codable, Equatable, Sendable {
        public var sopInstanceUID: String
        public var accepted: Bool
        public var reason: String?
        public var errorClass: DicomDeliveryErrorClass?
        public init(sopInstanceUID: String, accepted: Bool, reason: String? = nil,
                    errorClass: DicomDeliveryErrorClass? = nil) {
            self.sopInstanceUID = sopInstanceUID
            self.accepted = accepted
            self.reason = reason
            self.errorClass = errorClass
        }
    }
    public var remoteReference: String?
    public var status: String
    public var perObject: [Object]
    public init(remoteReference: String? = nil, status: String = "delivered", perObject: [Object] = []) {
        self.remoteReference = remoteReference
        self.status = status
        self.perObject = perObject
    }
}

public struct DicomDeliveryCycleReport: Sendable {
    public var attempted = 0
    public var delivered = 0
    public var paused = false
    public var retryAfter: TimeInterval?
    public var errors: [String] = []
    public init() {}
}
