/// Functional groups whose source placement is preserved when all frames agree.
public enum DicomSegmentationFunctionalGroup: Int, Hashable, Sendable, CaseIterable {
    case pixelMeasures = 0x00289110
    case planeOrientation = 0x00209116
    case segmentIdentification = 0x0062000A
    case derivationImage = 0x00089124
}
