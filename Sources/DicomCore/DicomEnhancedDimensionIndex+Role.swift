extension DicomEnhancedDimensionIndex {
    public enum Role: String, Hashable, Sendable {
        case spatial, stack, time, echo, cardiacPhase, respiratoryPhase, declared
    }

    /// Only known spatial macros are collapsed. Unknown dimensions remain selection coordinates.
    public var role: Role {
        switch (dimensionIndexPointer, functionalGroupPointer) {
        case (0x0020_9057, 0x0020_9111), (0x0020_0032, 0x0020_9113), (0x0020_9113, nil):
            return .spatial
        case (0x0020_9056, 0x0020_9111): return .stack
        case (0x0020_9128, 0x0020_9111): return .time
        case (0x0018_9082, 0x0018_9114), (0x0018_9114, nil): return .echo
        case (0x0020_9241, 0x0018_9118), (0x0020_9153, 0x0018_9118): return .cardiacPhase
        case (0x0020_9245, 0x0020_9253): return .respiratoryPhase
        default: return .declared
        }
    }
}
