import Foundation

public struct DicomSRMeasurementReport: Equatable, Sendable {
    public var sopInstanceUID: String
    public var sopClassUID: String?
    public var language: DicomSRLanguage?
    public var observers: [DicomSRObserver]
    public var procedureStudyInstanceUID: String?
    public var subject: DicomSRPatientSubject?
    public var proceduresReported: [DicomCodedConcept]
    public var imageLibrary: [DicomSRImageLibraryEntry]
    public var measurementGroups: [DicomSRMeasurementGroup]
    public var qualitativeEvaluations: [DicomSRQualitativeEvaluation]
    public var derivedMeasurements: [DicomSRDerivedMeasurement]

    public init(
        sopInstanceUID: String,
        sopClassUID: String? = nil,
        language: DicomSRLanguage? = nil,
        observers: [DicomSRObserver] = [],
        procedureStudyInstanceUID: String? = nil,
        subject: DicomSRPatientSubject? = nil,
        proceduresReported: [DicomCodedConcept] = [],
        imageLibrary: [DicomSRImageLibraryEntry] = [],
        measurementGroups: [DicomSRMeasurementGroup] = [],
        qualitativeEvaluations: [DicomSRQualitativeEvaluation] = [],
        derivedMeasurements: [DicomSRDerivedMeasurement] = []
    ) {
        self.sopInstanceUID = sopInstanceUID
        self.sopClassUID = sopClassUID
        self.language = language
        self.observers = observers
        self.procedureStudyInstanceUID = procedureStudyInstanceUID
        self.subject = subject
        self.proceduresReported = proceduresReported
        self.imageLibrary = imageLibrary
        self.measurementGroups = measurementGroups
        self.qualitativeEvaluations = qualitativeEvaluations
        self.derivedMeasurements = derivedMeasurements
    }
}
