import Foundation

enum DicomDIMSEReadResult {
    case message(DicomDIMSEMessage)
    case releaseRequest
}

struct DicomDIMSEMessage {
    var presentationContextID: UInt8
    var isCommand: Bool
    var data: Data
}

final class DicomDIMSEMessageReader {
    private var pendingPDVs: [DicomPDV] = []
    private var pendingPDVIndex = 0

    func readMessage(
        from transport: DicomAssociationTransport,
        maximumDataLength: Int64 = .max,
        reserveData: ((Int64) -> Bool)? = nil,
        releaseData: ((Int64) -> Void)? = nil,
        sink: ((Data) throws -> Void)? = nil
    ) throws -> DicomDIMSEMessage {
        switch try readNext(
            from: transport,
            maximumDataLength: maximumDataLength,
            reserveData: reserveData,
            releaseData: releaseData,
            sink: sink
        ) {
        case .message(let message):
            return message
        case .releaseRequest:
            throw DicomNetworkError.unsupportedPDU(DicomPDUType.releaseRequest)
        }
    }

    /// With a `sink`, each fragment goes to it as it arrives instead of into the message's `data`, which stays
    /// empty: only one PDU is held at a time (issue #2793). A sink that throws stops receiving the fragments, which
    /// are still read to the end of the message before its error is thrown.
    func readNext(
        from transport: DicomAssociationTransport,
        maximumDataLength: Int64 = .max,
        reserveData: ((Int64) -> Bool)? = nil,
        releaseData: ((Int64) -> Void)? = nil,
        sink: ((Data) throws -> Void)? = nil
    ) throws -> DicomDIMSEReadResult {
        var contextID: UInt8?
        var isCommand: Bool?
        var data = Data()
        var length: Int64 = 0
        var sinkError: Error?
        var admissionError: DicomStorageSCPAdmissionError?
        var reservedBytes: Int64 = 0
        var reservationTransferred = false
        defer {
            if reservationTransferred == false, reservedBytes > 0 {
                releaseData?(reservedBytes)
            }
        }

        while true {
            while pendingPDVIndex == pendingPDVs.count {
                pendingPDVs.removeAll(keepingCapacity: true)
                pendingPDVIndex = 0
                let pdu = try DicomPDUCodec.decode(try transport.readPDU())
                switch pdu {
                case .pData(let pdvs):
                    pendingPDVs.append(contentsOf: pdvs)
                case .releaseRequest:
                    return .releaseRequest
                case .abort(let abort):
                    throw DicomNetworkError.associationAborted(abort)
                default:
                    throw DicomNetworkError.unsupportedPDU(pdu.type)
                }
            }

            let pdv = pendingPDVs[pendingPDVIndex]
            pendingPDVIndex += 1
            if contextID == nil {
                contextID = pdv.presentationContextID
                isCommand = pdv.isCommand
            }
            guard contextID == pdv.presentationContextID,
                  isCommand == pdv.isCommand else {
                throw DicomNetworkError.malformedCommandSet("Mixed PDV fragments in one DIMSE message.")
            }
            if admissionError == nil {
                let fragmentBytes = Int64(pdv.data.count)
                if fragmentBytes > maximumDataLength || length > maximumDataLength - fragmentBytes {
                    admissionError = .messageTooLarge(limit: maximumDataLength)
                    data.removeAll(keepingCapacity: false)
                    releaseData?(reservedBytes)
                    reservedBytes = 0
                } else if let reserveData, reserveData(fragmentBytes) == false {
                    admissionError = .refused(.stagedByteLimit)
                    data.removeAll(keepingCapacity: false)
                    releaseData?(reservedBytes)
                    reservedBytes = 0
                } else {
                    if reserveData != nil {
                        reservedBytes += fragmentBytes
                    }
                    length += fragmentBytes
                    if let sink {
                        if sinkError == nil {
                            do { try sink(pdv.data) } catch { sinkError = error }
                        }
                    } else {
                        data.append(pdv.data)
                    }
                }
            }
            if pdv.isLastFragment {
                if let admissionError {
                    throw admissionError
                }
                if let sinkError {
                    throw sinkError
                }
                reservationTransferred = true
                return .message(DicomDIMSEMessage(presentationContextID: contextID ?? pdv.presentationContextID,
                                                  isCommand: isCommand ?? pdv.isCommand,
                                                  data: data))
            }
        }
    }
}
