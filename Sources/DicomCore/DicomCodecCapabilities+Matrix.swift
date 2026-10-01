import Foundation

extension DicomCodecCapabilities {
    /// Builds an executable-operation matrix for one explicit pixel profile and environment.
    /// Each row retains the requested dimensions and precision; it is not a claim about every image of that UID.
    public static func operationMatrix(
        for descriptor: DicomCompressedFrameDescriptor,
        intent: DicomEncodingIntent = .reversible,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [DicomCodecDecision] {
        DicomTransferSyntaxRegistry.standard.entries.flatMap { entry in
            let profile = DicomCompressedFrameDescriptor(
                transferSyntaxUID: entry.syntax.rawValue, rows: descriptor.rows, columns: descriptor.columns,
                bitsAllocated: descriptor.bitsAllocated, bitsStored: descriptor.bitsStored,
                highBit: descriptor.highBit, pixelRepresentation: descriptor.pixelRepresentation,
                samplesPerPixel: descriptor.samplesPerPixel,
                photometricInterpretation: descriptor.photometricInterpretation,
                planarConfiguration: descriptor.planarConfiguration
            )
            return [DicomCodecOperation.preserve, .decode, .encode].map {
                resolve(.init(operation: $0, descriptor: profile, intent: intent), environment: environment)
            }
        }
    }
}
