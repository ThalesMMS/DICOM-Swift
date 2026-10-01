import Foundation

/// Per-association response correlation. Message fragments must still be sent whole (PS3.8 E.1).
public final class DicomDIMSEOutstandingOperations: @unchecked Sendable {
    public enum State: Equatable, Sendable { case pending, final, cancelled }
    private let lock = NSLock()
    private let maximumInvoked: UInt16
    private var nextID: UInt16 = 1
    private var operations: [UInt16: (response: UInt16, state: State)] = [:]
    private var pendingCount = 0

    public init(window: DicomAsynchronousOperationsWindow = .init()) {
        maximumInvoked = window.maximumInvoked
    }

    public var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingCount
    }

    public func allocateMessageID() throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        for _ in 0..<UInt16.max {
            let candidate = nextID
            nextID = nextID == .max ? 1 : nextID + 1
            if operations[candidate]?.state != .pending { return candidate }
        }
        throw DicomNetworkError.malformedCommandSet("No free DIMSE Message ID.")
    }

    public func register(_ command: DicomDIMSECommandSet) throws {
        guard command.commandField & 0x8000 == 0, command.commandField != DicomDIMSECommandField.cCancelRQ else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let id = command.messageID, id != 0, operations[id]?.state != .pending else {
            throw DicomNetworkError.malformedCommandSet("Missing or duplicate outstanding Message ID.")
        }
        guard maximumInvoked == 0 || pendingCount < Int(maximumInvoked) else {
            throw DicomNetworkError.malformedCommandSet("Negotiated asynchronous operations window exceeded.")
        }
        operations[id] = (command.commandField | 0x8000, .pending)
        pendingCount += 1
    }

    public func correlate(_ response: DicomDIMSECommandSet) throws {
        guard response.commandField & 0x8000 != 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let id = response.messageIDBeingRespondedTo, let operation = operations[id],
              operation.state == .pending else {
            throw DicomNetworkError.malformedCommandSet("Unexpected Message ID Being Responded To.")
        }
        guard response.commandField == operation.response else {
            throw DicomNetworkError.unexpectedDIMSECommand(expected: operation.response, actual: response.commandField)
        }
        guard let status = response.status else {
            throw DicomNetworkError.malformedCommandSet("Response is missing Status (0000,0900).")
        }
        let state: State = status == 0xFF00 || status == 0xFF01 ? .pending : status == 0xFE00 ? .cancelled : .final
        operations[id] = (operation.response, state)
        if state != .pending { pendingCount -= 1 }
    }

    public func state(for messageID: UInt16) -> State? {
        lock.lock()
        defer { lock.unlock() }
        return operations[messageID]?.state
    }
}
