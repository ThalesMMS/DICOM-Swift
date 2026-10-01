import Foundation

public enum DicomSRQualitativeEvaluation: Equatable, Sendable {
    case code(concept: DicomCodedConcept, value: DicomCodedConcept)
    case text(concept: DicomCodedConcept, text: String)
}
