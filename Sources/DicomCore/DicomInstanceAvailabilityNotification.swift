import Foundation

public enum DicomInstanceAvailability: String, CaseIterable, Sendable {
    case online = "ONLINE", nearline = "NEARLINE", offline = "OFFLINE", unavailable = "UNAVAILABLE"
}

/// Availability is per instance. Completeness, durability and retrieval policy belong to the host.
public struct DicomInstanceAvailabilityNotification: Sendable {
    public struct WorkitemCode: Sendable {
        public var value: String
        public var scheme: String
        public var meaning: String
        public init(value: String, scheme: String, meaning: String) {
            self.value = value; self.scheme = scheme; self.meaning = meaning
        }
    }
    public struct ProcedureStep: Sendable {
        public var sopClassUID: String
        public var sopInstanceUID: String
        public var workitemCodes: [WorkitemCode]
        public init(sopClassUID: String, sopInstanceUID: String, workitemCodes: [WorkitemCode] = []) {
            self.sopClassUID = sopClassUID; self.sopInstanceUID = sopInstanceUID; self.workitemCodes = workitemCodes
        }
    }
    public struct Instance: Sendable {
        public var sopClassUID: String
        public var sopInstanceUID: String
        public var availability: DicomInstanceAvailability
        public var retrieveAETitle: String
        public var retrieveLocationUID: String?
        public var retrieveURI: String?
        public var retrieveURL: String?
        public var storageMediaFileSetID: String?
        public var storageMediaFileSetUID: String?
        public init(sopClassUID: String, sopInstanceUID: String, availability: DicomInstanceAvailability,
                    retrieveAETitle: String, retrieveLocationUID: String? = nil, retrieveURI: String? = nil,
                    retrieveURL: String? = nil, storageMediaFileSetID: String? = nil, storageMediaFileSetUID: String? = nil) {
            self.sopClassUID = sopClassUID; self.sopInstanceUID = sopInstanceUID; self.availability = availability
            self.retrieveAETitle = retrieveAETitle; self.retrieveLocationUID = retrieveLocationUID
            self.retrieveURI = retrieveURI; self.retrieveURL = retrieveURL
            self.storageMediaFileSetID = storageMediaFileSetID; self.storageMediaFileSetUID = storageMediaFileSetUID
        }
    }
    public struct Series: Sendable {
        public var seriesInstanceUID: String
        public var instances: [Instance]
        public init(seriesInstanceUID: String, instances: [Instance]) {
            self.seriesInstanceUID = seriesInstanceUID; self.instances = instances
        }
    }
    public var studyInstanceUID: String
    public var specificCharacterSet: String?
    public var referencedProcedureSteps: [ProcedureStep]
    public var series: [Series]
    public init(studyInstanceUID: String, series: [Series], referencedProcedureSteps: [ProcedureStep] = [],
                specificCharacterSet: String? = nil) {
        self.studyInstanceUID = studyInstanceUID; self.series = series
        self.referencedProcedureSteps = referencedProcedureSteps; self.specificCharacterSet = specificCharacterSet
    }

    public static func validate(dataSet: DicomDataSet) throws {
        func check(_ ds: DicomDataSet, allowed: Set<Int>, required: Set<Int>, sequences: Set<Int> = []) throws {
            guard ds.elements.allSatisfy({ allowed.contains($0.tag) && (($0.vr == .SQ) == sequences.contains($0.tag)) }),
                  required.allSatisfy({ upsValued(ds[$0]) }),
                  sequences.allSatisfy({ ds[$0]?.vr == .SQ }) else {
                throw DicomDIMSEProviderError(status: 0x0106, errorComment: "Invalid IAN attributes")
            }
        }
        try check(dataSet, allowed: [0x00080005, 0x00081111, 0x0020000D, 0x00081115],
                  required: [0x0020000D, 0x00081115], sequences: [0x00081111, 0x00081115])
        for step in dataSet.sequenceItems(for: 0x00081111) {
            try check(step.dataSet, allowed: [0x00081150, 0x00081155, 0x00404019],
                      required: [0x00081150, 0x00081155], sequences: [0x00404019])
            for code in step.dataSet.sequenceItems(for: 0x00404019) {
                try check(code.dataSet, allowed: [0x00080100, 0x00080102, 0x00080103, 0x00080104],
                          required: [0x00080100, 0x00080102, 0x00080104])
            }
        }
        for series in dataSet.sequenceItems(for: 0x00081115) {
            try check(series.dataSet, allowed: [0x0020000E, 0x00081199], required: [0x0020000E, 0x00081199], sequences: [0x00081199])
            for instance in series.dataSet.sequenceItems(for: 0x00081199) {
                try check(instance.dataSet, allowed: [0x00081150, 0x00081155, 0x00080056, 0x00080054,
                    0x0040E011, 0x0040E010, 0x00081190, 0x00880130, 0x00880140],
                    required: [0x00081150, 0x00081155, 0x00080056, 0x00080054])
                guard DicomInstanceAvailability(rawValue: instance.dataSet.string(for: 0x00080056) ?? "") != nil else {
                    throw DicomDIMSEProviderError(status: 0x0106)
                }
            }
        }
        func extended(_ ds: DicomDataSet) -> Bool {
            ds.elements.contains { $0.stringValues.contains { !$0.unicodeScalars.allSatisfy(\.isASCII) }
                || $0.sequenceItems.contains { extended($0.dataSet) } }
        }
        if extended(dataSet) && !upsValued(dataSet[0x00080005]) { throw DicomDIMSEProviderError(status: 0x0120) }
    }
}

public enum DicomInstanceAvailabilityNotificationBuilder {
    public static func build(_ notification: DicomInstanceAvailabilityNotification) throws -> DicomDataSet {
        let steps = notification.referencedProcedureSteps.map { step in
            DicomDataSet(elements: [upsString(0x00081150, step.sopClassUID, .UI), upsString(0x00081155, step.sopInstanceUID, .UI),
                upsSequence(0x00404019, step.workitemCodes.map { code in .init(elements: [
                    upsString(0x00080100, code.value, .SH), upsString(0x00080102, code.scheme, .SH),
                    upsString(0x00080104, code.meaning, .LO)]) })])
        }
        let series = notification.series.map { series in
            DicomDataSet(elements: [upsString(0x0020000E, series.seriesInstanceUID, .UI), upsSequence(0x00081199,
                series.instances.map { instance in
                    var elements = [upsString(0x00081150, instance.sopClassUID, .UI),
                        upsString(0x00081155, instance.sopInstanceUID, .UI), upsString(0x00080056, instance.availability.rawValue),
                        upsString(0x00080054, instance.retrieveAETitle, .AE)]
                    for (tag, value, vr): (Int, String?, DicomVR) in [
                        (0x0040E011, instance.retrieveLocationUID, .UI), (0x0040E010, instance.retrieveURI, .UR),
                        (0x00081190, instance.retrieveURL, .UR), (0x00880130, instance.storageMediaFileSetID, .SH),
                        (0x00880140, instance.storageMediaFileSetUID, .UI)] {
                        if let value { elements.append(upsString(tag, value, vr)) }
                    }
                    return .init(elements: elements)
                })])
        }
        var result = DicomDataSet(elements: [upsString(0x0020000D, notification.studyInstanceUID, .UI),
            upsSequence(0x00081111, steps), upsSequence(0x00081115, series)])
        if let charset = notification.specificCharacterSet { result.set(upsString(0x00080005, charset)) }
        try DicomInstanceAvailabilityNotification.validate(dataSet: result)
        return result
    }
    public static func validate(dataSet: DicomDataSet) throws { try DicomInstanceAvailabilityNotification.validate(dataSet: dataSet) }
}

public protocol DicomInstanceAvailabilityNotificationReceiving: Sendable {
    func receive(sopInstanceUID: String, dataSet: DicomDataSet) async throws
}
