public enum DicomRTContourGeometricType: String, CaseIterable, Sendable {
    case point = "POINT"
    case openPlanar = "OPEN_PLANAR"
    case openNonplanar = "OPEN_NONPLANAR"
    case closedPlanar = "CLOSED_PLANAR"
    case closedPlanarXOR = "CLOSEDPLANAR_XOR"
}
