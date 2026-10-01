public enum DicomPlacementError: Error, Equatable, Sendable {
    case invalidTransition(from: DicomObjectPlacement.State, to: DicomObjectPlacement.State)
    case unknownProvider(String)
    case quotaExceeded(String)
    case journal(String)
}
