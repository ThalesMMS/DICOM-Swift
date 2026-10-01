/// JPEG 2000 packet orders. The explicit encoder profile supports LRCP/RLCP;
/// the HTJ2K Lossless RPCL transfer syntax uses its own single-layer RPCL profile.
public enum DicomJPEG2000Progression: String, CaseIterable, Sendable {
    case lrcp, rlcp, rpcl, pcrl, cprl
}
