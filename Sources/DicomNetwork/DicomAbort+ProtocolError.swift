import Foundation

extension DicomAbort {
    /// The A-ABORT the upper layer sends before closing when a PDU is
    /// unexpected or malformed (PS3.8 Table 9-10, actions AA-1 and AA-8;
    /// issue #2792), or nil when the error is no protocol error: the peer
    /// aborted, the connection failed, or an operation failed above the DUL.
    public static func forProtocolError(_ error: Error) -> DicomAbort? {
        guard let error = error as? DicomNetworkError else { return nil }
        let reason: DicomAbortReason
        switch error {
        case .invalidPDUType:
            reason = .unrecognizedPDU
        case .unsupportedPDU:
            reason = .unexpectedPDU
        case .invalidItemType:
            reason = .unrecognizedPDUParameter
        case .duplicatePDUParameter:
            reason = .unexpectedPDUParameter
        case .invalidPDULength, .invalidPresentationContextID, .invalidAEString, .missingApplicationContext,
             .missingPresentationContext, .missingTransferSyntax:
            reason = .invalidPDUParameterValue
        default:
            return nil
        }
        return DicomAbort(source: .serviceProvider, reason: reason)
    }
}
