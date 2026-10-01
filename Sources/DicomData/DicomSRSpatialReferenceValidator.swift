import Foundation

/// Resolves SCOORD image selections and checks frame/Total Pixel Matrix bounds.
/// Supplied targets preserve complete actual metadata; pixel payloads may be omitted.
public enum DicomSRSpatialReferenceValidator {
    public typealias Result = DicomSRCoordinateReferenceValidator.Result

    public static func validate(_ dataSet: DicomDataSet, targets: [String: DicomDataSet] = [:],
                                limits: DicomAttributeValidator.Limits = .init()) -> Result {
        evaluate(dataSet, targets: targets, limits: limits)
    }

    package static func evaluate(_ dataSet: DicomDataSet, targets: [String: DicomDataSet],
                                 limits: DicomAttributeValidator.Limits) -> Result {
        DicomSRCoordinateReferenceValidator.evaluate(dataSet, targets: targets, limits: limits, spatialOnly: true)
    }
}
