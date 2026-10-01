import Foundation

public enum DicomWorkflowTag {
    public static let accessionNumber = 0x0008_0050
    public static let modality = 0x0008_0060
    public static let requestedProcedureDescription = 0x0032_1060
    public static let scheduledProcedureStepSequence = 0x0040_0100
    public static let scheduledStationAETitle = 0x0040_0001
    public static let scheduledProcedureStepStartDate = 0x0040_0002
    public static let scheduledProcedureStepStartTime = 0x0040_0003
    public static let scheduledProcedureStepDescription = 0x0040_0007
    public static let scheduledProcedureStepID = 0x0040_0009
    public static let performedStationAETitle = 0x0040_0241
    public static let performedStationName = 0x0040_0242
    public static let performedLocation = 0x0040_0243
    public static let performedProcedureStepStartDate = 0x0040_0244
    public static let performedProcedureStepStartTime = 0x0040_0245
    public static let performedProcedureStepEndDate = 0x0040_0250
    public static let performedProcedureStepEndTime = 0x0040_0251
    public static let performedProcedureStepStatus = 0x0040_0252
    public static let performedProcedureStepID = 0x0040_0253
    public static let performedProcedureStepDescription = 0x0040_0254
    public static let commentsOnPerformedProcedureStep = 0x0040_0280
    public static let scheduledStepAttributesSequence = 0x0040_0270
    public static let requestedProcedureID = 0x0040_1001
}

public struct DicomModalityWorklistQuery: Equatable, Sendable {
    public var patientName: String?
    public var patientID: String?
    public var accessionNumber: String?
    public var modality: String?
    public var scheduledStationAETitle: String?
    /// A date, or a `YYYYMMDD-YYYYMMDD` range (PS3.4 C.2.2.2.5).
    public var scheduledProcedureStepStartDate: String?
    /// A time, or an `HHMMSS-HHMMSS` range; empty returns every start time.
    public var scheduledProcedureStepStartTime: String?
    public var scheduledProcedureStepID: String?

    public init(patientName: String? = nil,
                patientID: String? = nil,
                accessionNumber: String? = nil,
                modality: String? = nil,
                scheduledStationAETitle: String? = nil,
                scheduledProcedureStepStartDate: String? = nil,
                scheduledProcedureStepStartTime: String? = nil,
                scheduledProcedureStepID: String? = nil) {
        self.patientName = patientName
        self.patientID = patientID
        self.accessionNumber = accessionNumber
        self.modality = modality
        self.scheduledStationAETitle = scheduledStationAETitle
        self.scheduledProcedureStepStartDate = scheduledProcedureStepStartDate
        self.scheduledProcedureStepStartTime = scheduledProcedureStepStartTime
        self.scheduledProcedureStepID = scheduledProcedureStepID
    }

    public var identifier: DicomDataSet {
        DicomDataSet(elements: [
            workflowString(DicomTag.patientName.rawValue, .PN, patientName),
            workflowString(DicomTag.patientID.rawValue, .LO, patientID),
            workflowString(DicomWorkflowTag.accessionNumber, .SH, accessionNumber),
            workflowString(DicomWorkflowTag.requestedProcedureID, .SH, nil),
            workflowString(DicomWorkflowTag.requestedProcedureDescription, .LO, nil),
            workflowSequence(DicomWorkflowTag.scheduledProcedureStepSequence, [
                DicomDataSet(elements: [
                    workflowString(DicomWorkflowTag.scheduledStationAETitle, .AE, scheduledStationAETitle),
                    workflowString(DicomWorkflowTag.scheduledProcedureStepStartDate, .DA, scheduledProcedureStepStartDate),
                    workflowString(DicomWorkflowTag.scheduledProcedureStepStartTime, .TM, scheduledProcedureStepStartTime),
                    workflowString(DicomWorkflowTag.modality, .CS, modality),
                    workflowString(DicomWorkflowTag.scheduledProcedureStepDescription, .LO, nil),
                    workflowString(DicomWorkflowTag.scheduledProcedureStepID, .SH, scheduledProcedureStepID)
                ])
            ])
        ])
    }
}

public struct DicomModalityWorklistResult: Equatable, Sendable {
    public var operation: DicomDIMSEOperationResult
    public var items: [DicomModalityWorklistItem]

    public init(operation: DicomDIMSEOperationResult,
                items: [DicomModalityWorklistItem]) {
        self.operation = operation
        self.items = items
    }
}

public struct DicomModalityWorklistItem: Equatable, Sendable {
    public var dataSet: DicomDataSet
    public var patientName: String?
    public var patientID: String?
    public var accessionNumber: String?
    public var requestedProcedureID: String?
    public var requestedProcedureDescription: String?
    public var scheduledStationAETitle: String?
    public var modality: String?
    public var scheduledProcedureStepStartDate: String?
    public var scheduledProcedureStepStartTime: String?
    public var scheduledProcedureStepDescription: String?
    public var scheduledProcedureStepID: String?

    public init(dataSet: DicomDataSet) {
        let scheduled = dataSet.element(for: DicomWorkflowTag.scheduledProcedureStepSequence)?
            .sequenceItems.first?.dataSet
        self.dataSet = dataSet
        self.patientName = dataSet.string(for: DicomTag.patientName)
        self.patientID = dataSet.string(for: DicomTag.patientID)
        self.accessionNumber = dataSet.string(for: DicomWorkflowTag.accessionNumber)
        self.requestedProcedureID = dataSet.string(for: DicomWorkflowTag.requestedProcedureID)
        self.requestedProcedureDescription = dataSet.string(for: DicomWorkflowTag.requestedProcedureDescription)
        self.scheduledStationAETitle = scheduled?.string(for: DicomWorkflowTag.scheduledStationAETitle)
        self.modality = scheduled?.string(for: DicomWorkflowTag.modality) ??
            dataSet.string(for: DicomWorkflowTag.modality)
        self.scheduledProcedureStepStartDate = scheduled?.string(for: DicomWorkflowTag.scheduledProcedureStepStartDate)
        self.scheduledProcedureStepStartTime = scheduled?.string(for: DicomWorkflowTag.scheduledProcedureStepStartTime)
        self.scheduledProcedureStepDescription = scheduled?.string(for: DicomWorkflowTag.scheduledProcedureStepDescription)
        self.scheduledProcedureStepID = scheduled?.string(for: DicomWorkflowTag.scheduledProcedureStepID)
    }

    public var stableIdentifier: String {
        [
            scheduledProcedureStepID,
            accessionNumber,
            requestedProcedureID,
            patientID
        ].compactMap { $0?.dicomWorkflowNilIfBlank }.first ?? "worklist-item"
    }

    public var displaySummary: String {
        [
            patientName,
            modality,
            scheduledProcedureStepStartDate,
            scheduledProcedureStepDescription ?? requestedProcedureDescription
        ].compactMap { $0?.dicomWorkflowNilIfBlank }
            .joined(separator: " - ")
    }

    public var scheduledStepAttributesDataSet: DicomDataSet {
        DicomDataSet(elements: [
            workflowString(DicomTag.studyInstanceUID.rawValue, .UI, dataSet.string(for: DicomTag.studyInstanceUID)),
            workflowString(DicomWorkflowTag.accessionNumber, .SH, accessionNumber),
            workflowString(DicomWorkflowTag.requestedProcedureID, .SH, requestedProcedureID),
            workflowString(DicomWorkflowTag.requestedProcedureDescription, .LO, requestedProcedureDescription),
            workflowString(DicomWorkflowTag.scheduledStationAETitle, .AE, scheduledStationAETitle),
            workflowString(DicomWorkflowTag.scheduledProcedureStepStartDate, .DA, scheduledProcedureStepStartDate),
            workflowString(DicomWorkflowTag.scheduledProcedureStepStartTime, .TM, scheduledProcedureStepStartTime),
            workflowString(DicomWorkflowTag.modality, .CS, modality),
            workflowString(DicomWorkflowTag.scheduledProcedureStepDescription, .LO, scheduledProcedureStepDescription),
            workflowString(DicomWorkflowTag.scheduledProcedureStepID, .SH, scheduledProcedureStepID)
        ].filter { !$0.isEmptyValue })
    }
}

public enum DicomMPPSStatus: String, Codable, Equatable, Sendable {
    case inProgress = "IN PROGRESS"
    case discontinued = "DISCONTINUED"
    case completed = "COMPLETED"
}

public struct DicomMPPSCreateRequest: Equatable, Sendable {
    public var sopInstanceUID: String
    public var status: DicomMPPSStatus
    public var performedStationAETitle: String?
    public var performedStationName: String?
    public var performedLocation: String?
    public var performedProcedureStepID: String?
    public var performedProcedureStepDescription: String?
    public var startDate: String?
    public var startTime: String?
    public var worklistItem: DicomModalityWorklistItem?

    public init(sopInstanceUID: String = DicomDataSetWriter.makeUID(),
                status: DicomMPPSStatus = .inProgress,
                performedStationAETitle: String? = nil,
                performedStationName: String? = nil,
                performedLocation: String? = nil,
                performedProcedureStepID: String? = nil,
                performedProcedureStepDescription: String? = nil,
                startDate: String? = nil,
                startTime: String? = nil,
                worklistItem: DicomModalityWorklistItem? = nil) {
        self.sopInstanceUID = sopInstanceUID
        self.status = status
        self.performedStationAETitle = performedStationAETitle
        self.performedStationName = performedStationName
        self.performedLocation = performedLocation
        self.performedProcedureStepID = performedProcedureStepID
        self.performedProcedureStepDescription = performedProcedureStepDescription
        self.startDate = startDate
        self.startTime = startTime
        self.worklistItem = worklistItem
    }

    public var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = [
            workflowString(DicomWorkflowTag.performedProcedureStepStatus, .CS, status.rawValue),
            workflowString(DicomWorkflowTag.performedStationAETitle, .AE, performedStationAETitle),
            workflowString(DicomWorkflowTag.performedStationName, .SH, performedStationName),
            workflowString(DicomWorkflowTag.performedLocation, .SH, performedLocation),
            workflowString(DicomWorkflowTag.performedProcedureStepID, .SH, performedProcedureStepID ?? worklistItem?.scheduledProcedureStepID),
            workflowString(DicomWorkflowTag.performedProcedureStepDescription, .LO, performedProcedureStepDescription ?? worklistItem?.scheduledProcedureStepDescription),
            workflowString(DicomWorkflowTag.performedProcedureStepStartDate, .DA, startDate),
            workflowString(DicomWorkflowTag.performedProcedureStepStartTime, .TM, startTime)
        ].filter { !$0.isEmptyValue }
        if let worklistItem {
            elements.append(workflowSequence(DicomWorkflowTag.scheduledStepAttributesSequence, [
                worklistItem.scheduledStepAttributesDataSet
            ]))
        }
        return DicomDataSet(elements: elements)
    }
}

public struct DicomMPPSUpdateRequest: Equatable, Sendable {
    public var sopInstanceUID: String
    public var status: DicomMPPSStatus
    public var endDate: String?
    public var endTime: String?
    public var comments: String?

    public init(sopInstanceUID: String,
                status: DicomMPPSStatus,
                endDate: String? = nil,
                endTime: String? = nil,
                comments: String? = nil) {
        self.sopInstanceUID = sopInstanceUID
        self.status = status
        self.endDate = endDate
        self.endTime = endTime
        self.comments = comments
    }

    public var dataSet: DicomDataSet {
        DicomDataSet(elements: [
            workflowString(DicomWorkflowTag.performedProcedureStepStatus, .CS, status.rawValue),
            workflowString(DicomWorkflowTag.performedProcedureStepEndDate, .DA, endDate),
            workflowString(DicomWorkflowTag.performedProcedureStepEndTime, .TM, endTime),
            workflowString(DicomWorkflowTag.commentsOnPerformedProcedureStep, .ST, comments)
        ].filter { !$0.isEmptyValue })
    }
}

private func workflowString(_ tag: Int, _ vr: DicomVR, _ value: String?) -> DicomDataElement {
    let trimmed = value?.dicomWorkflowNilIfBlank
    return DicomDataElement(tag: tag,
                            vr: vr,
                            value: trimmed.map { .strings([$0]) } ?? .empty)
}

private func workflowSequence(_ tag: Int, _ dataSets: [DicomDataSet]) -> DicomDataElement {
    DicomDataElement(tag: tag,
                     vr: .SQ,
                     value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) }))
}

private extension DicomDataElement {
    var isEmptyValue: Bool {
        if case .empty = value {
            return true
        }
        return false
    }
}

private extension String {
    var dicomWorkflowNilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
