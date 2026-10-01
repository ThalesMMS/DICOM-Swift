import Foundation

public enum DicomUnifiedProcedureStepState: String, CaseIterable, Sendable {
    case scheduled = "SCHEDULED"
    case inProgress = "IN PROGRESS"
    case completed = "COMPLETED"
    case canceled = "CANCELED"
    public var isFinal: Bool { self == .completed || self == .canceled }
}

/// PS3.4 2026c CC.2.5.1.3, including nested paths and the original requirement text.
public struct DicomUnifiedProcedureStepAttribute: Sendable {
    public let name: String
    public let tag: Int
    public let path: [Int]
    public let create: String
    public let set: String
    public let finalState: String
    public let get: String
    public let matching: String
    public let returned: String
    public let remark: String

    public static let table: [Self] = {
        var parents: [Int] = []
        return transcription.split(separator: "\n").map { line in
            let c = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let depth = c[0].prefix(while: { $0 == ">" }).count
            let tag = Int(c[1].filter { $0.isHexDigit }, radix: 16)!
            parents = Array(parents.prefix(depth))
            let path = parents + [tag]
            parents = path
            return Self(name: c[0], tag: tag, path: path, create: c[2], set: c[3], finalState: c[4],
                        get: c[5], matching: c[6], returned: c[7], remark: c[8])
        }
    }()

    private static let transcription = """
    Transaction UID|(0008,1195)|2/2 Shall be empty|(see )|O|Not allowed|-|-|Cannot be queried.
    Specific Character Set|(0008,0005)|1C/1C|1C/1C|RC|3/1|-|1C|Required if extended or replacement character set is used
    SOP Class UID|(0008,0016)|See|Not allowed|R|Not allowed|O|1|Uniquely identifies the SOP Class of the Unified Procedure Step. See for further explanation.
    SOP Instance UID|(0008,0018)|Not allowed. SOP Instance is conveyed in the Affected SOP Instance UID (0000,1000)|Not allowed. SOP Instance is conveyed in the Requested SOP Instance UID (0000,1001)|R|Not allowed. SOP Instance is conveyed in the Requested SOP Instance UID (0000,1001)|U|1|Uniquely identifies the SOP Instance of the UPS. SOP Instance UID shall be retrieved with Single Value Matching.
    Scheduled Procedure Step Priority|(0074,1200)|1/1|3/1|R|3/1|R|1|Scheduled Procedure Step Priority shall be retrieved with Single Value Matching.
    Scheduled Procedure Step Modification DateTime|(0040,4010)|-/1 SCP shall use time of CREATE|-/1 SCP shall use time of SET|R|3/1|O|3|Scheduled Procedure Step Modification DateTime shall be retrieved with Single Value Matching or Range Matching.
    Procedure Step Label|(0074,1204)|1/1|3/1|O|3/1|R|1|
    Worklist Label|(0074,1202)|2/1 If a value is not provided by the SCU, the SCP shall fill in the Worklist Label, e.g., using a default value or by assigning the UPS instance to a logical worklist.|3/1|O|3/1|R|1|
    Scheduled Processing Parameters Sequence|(0074,1210)|2/2|3/2|O|3/2|-|2|
    Scheduled Station Name Code Sequence|(0040,4025)|2/2|3/2|O|3/2|R|2|The Attributes of the Scheduled Station Name Code Sequence shall only be retrieved with Sequence Matching. In Push Scenario, the SCP-Performer has to create empty but could self fill later.
    Scheduled Station Class Code Sequence|(0040,4026)|2/2|3/2|O|3/2|R|2|The Attributes of the Scheduled Station Class Code Sequence shall only be retrieved with Sequence Matching.
    Scheduled Station Geographic Location Code Sequence|(0040,4027)|2/2|3/2|O|3/2|R|2|The Attributes of the Scheduled Station Geographic Location Code Sequence shall only be retrieved with Sequence Matching.
    Scheduled Human Performers Sequence|(0040,4034)|2C/2C|3/2|O|3/2|R|2|The Attributes of the Scheduled Human Performers Sequence shall only be retrieved with Sequence Matching. Required if a Human Performer is specified.
    >Human Performer Code Sequence|(0040,4009)|1/1|1/1|O|-/1|R|1|The Attributes of the Scheduled Human Performers Code Sequence shall only be retrieved with Sequence Matching.
    >Human Performer's Name|(0040,4037)|1/1|1/1|O|-/1|O|3|
    >Human Performer's Organization|(0040,4036)|1/1|1/1|O|-/1|O|3|
    Scheduled Procedure Step Start DateTime|(0040,4005)|1/1|3/1|R|3/1|R|1|Scheduled Procedure Step Start DateTime shall be retrieved with Single Value Matching or Range Matching.
    Expected Completion DateTime|(0040,4011)|3/1|3/1|O|3/1|R|3|Expected Completion DateTime shall be retrieved with Single Value Matching or Range Matching.
    Scheduled Procedure Step Expiration DateTime|(0040,4008)|3/3|3/3|O|3/3|O|3|Scheduled Procedure Step Expiration DateTime shall be retrieved with Single Value Matching or Range Matching.
    Scheduled Workitem Code Sequence|(0040,4018)|2/2|3/1|O|3/1|R|2|The Attributes of the Scheduled Workitem Code Sequence shall only be retrieved with Sequence Matching.
    Comments on the Scheduled Procedure Step|(0040,0400)|2/2|3/1|O|3/1|O|3|
    Input Readiness State|(0040,4041)|1/1|3/1|R|3/1|R|1|Input Readiness State shall be retrieved with Single Value Matching.
    Input Information Sequence|(0040,4021)|2/2|3/2|O|3/2|O|2|The Attributes of the Input Information Sequence shall only be retrieved with Sequence Matching.
    Study Instance UID|(0020,000D)|1C/2|3/2|O|3/2|O|2|Required if the Workitem is expected to result in the creation of any DICOM Composite Instances whose IOD contains the Study IE. There may be situations where the performer does not use the Study Instance UID suggested by the Scheduler.
    Output Destination Sequence|(0040,4070)|3/3|3/3|O|3/3|O|3|The Attributes of the Output Destination Sequence shall only be retrieved with Sequence Matching.
    Patient's Name|(0010,0010)|2/2|Not allowed|O|3/2|R|2|
    Patient ID|(0010,0020)|1C/2|Not allowed|O|3/2|R|2|Required if the subject of the workitem requires identification or if the workitem is expected to result in the creation of objects that identify the subject. See
    Issuer of Patient ID|(0010,0021)|2/2|-/-|O|3/2|R|2|
    Issuer of Patient ID Qualifiers Sequence|(0010,0024)|2/2|-/-|O|3/2|O|2|
    Other Patient IDs Sequence|(0010,1002)|2/2|3/3|O|3/2|O|2|
    >Patient ID|(0010,0020)|1/1|1/1|O|-/1|O|1|
    >Issuer of Patient ID|(0010,0021)|2/2|-/-|O|-/2|R|2|
    >Issuer of Patient ID Qualifiers Sequence|(0010,0024)|2/2|-/-|O|-/2|O|2|
    >Type of Patient ID|(0010,0022)|3/3|3/3|O|3/3|O|3|
    Patient's Birth Date|(0010,0030)|2/2|Not allowed|O|3/2|R|2|
    Patient's Sex|(0010,0040)|2/2|Not allowed|O|3/2|R|2|
    Gender Identity Sequence|(0010,0041)|3/3|-/-|O|3/3|O|3|
    >Gender Identity Code Sequence|(0010,0044)|1/1|-/-|O|-/1|O|1|
    >Effective Start DateTime|(0040,A034)|3/3|-/-|O|-/3|O|3|
    >Effective Stop DateTime|(0040,A035)|3/3|-/-|O|-/3|O|3|
    >Gender Identity Comment|(0010,0045)|3/3|-/-|O|-/3|O|3|
    Sex Parameters for Clinical Use Category Sequence|(0010,0043)|3/3|-/-|O|3/3|O|3|
    >Sex Parameters for Clinical Use Category Code Sequence|(0010,0046)|1/1|-/-|O|-/1|O|1|
    >Effective Start DateTime|(0040,A034)|3/3|-/-|O|-/3|O|3|
    >Effective Stop DateTime|(0040,A035)|3/3|-/-|O|-/3|O|3|
    >Sex Parameters for Clinical Use Category Comment|(0010,0042)|2C/2C|-/-|O|-/2C|O|3|Required if Sex Parameters for Clinical Use Category Code Sequence (0010,0046) is (131232, DCM, “Specified”). May be present otherwise.
    >Sex Parameters for Clinical Use Category Reference|(0010,0047)|2C/2C|-/-|O|-/2C|O|3|Required if Sex Parameters for Clinical Use Category Code Sequence (0010,0046) is (131232, DCM, “Specified”). May be present otherwise.
    Person Names to Use Sequence|(0010,0011)|3/3|-/-|O|3/3|O|3|
    >Name to Use|(0010,0012)|1/1|-/-|O|-/1|O|1|
    >Effective Start DateTime|(0040,A034)|3/3|-/-|O|-/3|O|3|
    >Effective Stop DateTime|(0040,A035)|3/3|-/-|O|-/3|O|3|
    >Name to Use Comment|(0010,0013)|3/3|-/-|O|-/3|O|3|
    Third Person Pronouns Sequence|(0010,0014)|3/3|-/-|O|3/3|O|3|
    >Pronoun Code Sequence|(0010,0015)|1/1|-/-|O|-/1|O|1|
    >Effective Start DateTime|(0040,A034)|3/3|-/-|O|-/3|O|3|
    >Effective Stop DateTime|(0040,A035)|3/3|-/-|O|-/3|O|3|
    >Pronoun Comment|(0010,0016)|3/3|-/-|O|-/3|O|3|
    Referenced Patient Photo Sequence|(0010,1100)|3/3|3/3|O|3/3|-|3|
    Admission ID|(0038,0010)|2/2|Not allowed|O|3/2|R|2|
    Issuer of Admission ID Sequence|(0038,0014)|2/2|Not allowed|O|3/2|R|2|
    Admitting Diagnoses Description|(0008,1080)|2/2|Not allowed|O|3/2|O|2|
    Admitting Diagnoses Code Sequence|(0008,1084)|2/2|Not allowed|O|3/2|O|2|The Attributes of the Admitting Diagnoses Code Sequence shall only be retrieved with Sequence Matching.
    Referenced Request Sequence|(0040,A370)|2/2|Not allowed|O|3/2|R|2|Could be "changed" while SCHEDULED by canceling and re-creating with the "correct" values.
    >Study Instance UID|(0020,000D)|1/1|Not allowed|O|-/1|O|1|
    >Accession Number|(0008,0050)|2/2|Not allowed|O|-/2|R|2|
    >Issuer of Accession Number Sequence|(0008,0051)|2/2|Not allowed|O|-/2|R|2|The Issuer of Accession Number Sequence shall only be retrieved with Sequence Matching.
    >Placer Order Number/Imaging Service Request|(0040,2016)|3/1|Not allowed|O|-/1|O|1C|Required if set.
    >Order Placer Identifier Sequence|(0040,0026)|2/2|Not allowed|O|-/2|O|2|The Order Placer Identifier Sequence shall only be retrieved with Sequence Matching.
    >Filler Order Number/Imaging Service Request|(0040,2017)|3/1|Not allowed|O|-/1|O|1C|Required if set.
    >Order Filler Identifier Sequence|(0040,0027)|2/2|Not allowed|O|-/2|O|2|The Order Filler Identifier Sequence shall only be retrieved with Sequence Matching.
    >Requested Procedure ID|(0040,1001)|2/2|Not allowed|O|-/2|R|2|
    >Requested Procedure Description|(0032,1060)|2/2|Not allowed|O|-/2|O|2|
    >Requested Procedure Code Sequence|(0032,1064)|2/2|Not allowed|O|-/2|O|2|
    >Reason for the Requested Procedure|(0040,1002)|3/3|3/3|O|-/3|O|3|
    >Reason for Requested Procedure Code Sequence|(0040,100A)|3/3|3/3|O|-/3|O|3|
    >Requested Procedure Comments|(0040,1400)|3/3|3/3|O|-/3|O|1C|Required if set.
    >Confidentiality Code|(0040,1008)|3/3|3/3|O|-/3|O|3|
    >Names of Intended Recipients of Results|(0040,1010)|3/3|3/3|O|-/3|O|3|
    >Imaging Service Request Comments|(0040,2400)|3/3|3/3|O|-/3|O|3|
    >Requesting Physician|(0032,1032)|3/3|3/3|O|-/3|O|3|
    >Requesting Service|(0032,1033)|3/1|3/1|O|-/3|R|3|
    >Requesting Service Code Sequence|(0032,1034)|3/3|3/3|O|-/3|O|3|
    >Issue Date of Imaging Service Request|(0040,2004)|3/3|3/3|O|-/3|O|3|
    >Issue Time of Imaging Service Request|(0040,2005)|3/3|3/3|O|-/3|O|3|
    >Referring Physician's Name|(0008,0090)|3/3|3/3|O|-/3|O|3|
    Replaced Procedure Step Sequence|(0074,1224)|1C/1C|Not allowed|O|3/2|R|3|Required if the UPS replaces another Procedure Step.
    Medical Alerts|(0010,2000)|3/2|3/2|O|3/2|O|2C|Required if present.
    Pregnancy Status|(0010,21C0)|3/2|3/2|O|3/2|O|2C|Required if present.
    Special Needs|(0038,0050)|3/2|3/2|O|3/2|O|2C|Required if present.
    Procedure Step State|(0074,1000)|1/1 Shall be created with a value of "SCHEDULED"|-/-. Use N-ACTION|R|3/1|R|1|Procedure Step State shall be retrieved with Single Value Matching
    Procedure Step Progress Information Sequence|(0074,1002)|2/2 Shall be empty|3/2|X|3/2||2|
    >Procedure Step Progress|(0074,1004)|-/-|3/1|O|-/1|-|-|
    >Procedure Step Progress Description|(0074,1006)|-/-|3/1|O|-/1|-|-|
    >Procedure Step Progress Parameters Sequence|(0074,1007)|-/-|3/3|O|-/3|||
    >>Content Item Modifier Sequence|(0040,0441)|-/-|3/3|O|-/3|||
    >Procedure Step Communications URI Sequence|(0074,1008)|-/-|3/1|O|-/1|-|-|
    >>Contact URI|(0074,100a)|-/-|1/1|O|-/1|-|-|
    >>Contact Display Name|(0074,100c)|-/-|3/1|O|-/1|-|-|
    >Procedure Step Cancellation DateTime|(0040,4052)|-/-|3/1|X|-/1|-|-|If changing the UPS State (0074,1000) to CANCELED and this Attribute has no value, the SCP shall fill it with the current datetime.
    >Reason For Cancellation|(0074,1238)|-/-|3/1|O|-/1|-|-|
    >Procedure Step Discontinuation Reason Code Sequence|(0074,100e)|-/-|3/1|X|-/1|||
    Unified Procedure Step Performed Procedure Sequence|(0074,1216)|2/2 Shall be created empty|3/2|P|3/2|-|-|See .
    >Actual Human Performers Sequence|(0040,4035)|-/-|3/1|RC|-/1|O|1C|Shall be provided if known. Return Key required if set. The Attributes of the Actual Human Performers Sequence shall only be retrieved with Sequence Matching.
    >>Human Performer Code Sequence|(0040,4009)|-/-|3/1|RC|-/1|-|-|Shall be provided if known.
    >>Human Performer's Name|(0040,4037)|-/-|3/1|RC|-/1|-|-|Shall be provided if known
    >>Human Performer's Organization|(0040,4036)|-/-|3/1|O|-/1|-|-|
    >Performed Station Name Code Sequence|(0040,4028)|-/-|3/2|P|-/2|O|3|
    >Performed Station Class Code Sequence|(0040,4029)|-/-|3/2|O|-/2|-|-|
    >Performed Station Geographic Location Code Sequence|(0040,4030)|-/-|3/2|O|-/2|-|-|
    >Performed Procedure Step Start DateTime|(0040,4050)|-/-|3/1|P|-/1|-|-|
    >Performed Procedure Step Description|(0040,0254)|-/-|3/1|O|-/1|-|-|
    >Comments on the Performed Procedure Step|(0040,0280)|-/-|3/1|O|-/1|-|-|
    >Performed Workitem Code Sequence|(0040,4019)|-/-|3/1|P|-/1|-|-|
    >Performed Processing Parameters Sequence|(0074,1212)|-/-|3/1|O|-/1|-|-|
    >Performed Procedure Step End DateTime|(0040,4051)|-/-|3/1|P|-/1|O|1C|Required if set.
    >Output Information Sequence|(0040,4033)|-/-|2/2|P|-/2|-|-|If there are no relevant output objects, then this sequence may have no items.
    """
}

public enum DicomUnifiedProcedureStepStatus {
    public static let success: UInt16 = 0x0000
    public static let duplicateInstance: UInt16 = 0x0111
    public static let warningB300: UInt16 = 0xB300
    public static let warningB301: UInt16 = 0xB301
    public static let warningB304: UInt16 = 0xB304
    public static let warningB305: UInt16 = 0xB305
    public static let warningB306: UInt16 = 0xB306
    public static let failureC300: UInt16 = 0xC300
    public static let failureC301: UInt16 = 0xC301
    public static let failureC302: UInt16 = 0xC302
    public static let failureC303: UInt16 = 0xC303
    public static let failureC304: UInt16 = 0xC304
    public static let failureC305: UInt16 = 0xC305
    public static let failureC306: UInt16 = 0xC306
    public static let failureC307: UInt16 = 0xC307
    public static let failureC308: UInt16 = 0xC308
    public static let failureC309: UInt16 = 0xC309
    public static let failureC30A: UInt16 = 0xC30A
    public static let failureC30B: UInt16 = 0xC30B
    public static let failureC30C: UInt16 = 0xC30C
    public static let failureC30D: UInt16 = 0xC30D
    public static let failureC30E: UInt16 = 0xC30E
    public static let failureC30F: UInt16 = 0xC30F
    public static let failureC310: UInt16 = 0xC310
    public static let failureC311: UInt16 = 0xC311
    public static let failureC312: UInt16 = 0xC312
    public static let failureC313: UInt16 = 0xC313
    public static let failureC314: UInt16 = 0xC314
    public static let failureC315: UInt16 = 0xC315
}

func upsString(_ tag: Int, _ value: String, _ vr: DicomVR = .CS) -> DicomDataElement {
    .init(tag: tag, vr: vr, value: .strings([value]))
}
func upsSequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
    .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
}
func upsValued(_ element: DicomDataElement?) -> Bool {
    guard let element else { return false }
    if element.vr == .SQ { return !element.sequenceItems.isEmpty }
    return element.value.vm.count > 0 && (element.stringValues.isEmpty || element.stringValues.contains {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })
}
func upsTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMddHHmmss.SSSSSS"
    return formatter.string(from: date) + "+0000"
}

public enum DicomUnifiedProcedureStepPersistenceError: Error {
    case invalidState
}

public struct DicomUnifiedProcedureStepPersistedRecord: Codable, Sendable, Equatable {
    public let sopInstanceUID: String
    public let state: String
    public let transactionUID: String?
    /// Explicit VR Little Endian data set bytes.
    public let attributes: Data
    public let created: Date
    public let modified: Date
    public let knownFinalStateTags: [Int]

    public init(sopInstanceUID: String, state: String, transactionUID: String?, attributes: Data,
                created: Date, modified: Date, knownFinalStateTags: [Int]) {
        self.sopInstanceUID = sopInstanceUID
        self.state = state
        self.transactionUID = transactionUID
        self.attributes = attributes
        self.created = created
        self.modified = modified
        self.knownFinalStateTags = knownFinalStateTags.sorted()
    }
}

public struct DicomUnifiedProcedureStepRecord: Sendable {
    public let sopInstanceUID: String
    public internal(set) var state: DicomUnifiedProcedureStepState
    public internal(set) var transactionUID: String?
    public internal(set) var attributes: DicomDataSet
    public let created: Date
    public internal(set) var modified: Date
    /// Host knowledge for CC.2.5.1.3 RC rows whose condition is "if known".
    public var knownFinalStateTags: Set<Int> = []

    public init(sopInstanceUID: String, attributes: DicomDataSet, now: Date = Date()) {
        self.sopInstanceUID = sopInstanceUID
        self.state = .scheduled
        self.attributes = DicomDataSet(elements: attributes.elements.filter { $0.tag != 0x00081195 })
        self.attributes.set(upsString(0x00080016, "1.2.840.10008.5.1.4.34.6.1", .UI))
        self.attributes.set(upsString(0x00080018, sopInstanceUID, .UI))
        self.attributes.set(upsString(0x00741000, state.rawValue))
        self.created = now
        self.modified = now
        self.attributes.set(upsString(0x00404010, upsTime(now), .DT))
    }

    public var persisted: DicomUnifiedProcedureStepPersistedRecord {
        get throws {
            try .init(sopInstanceUID: sopInstanceUID, state: state.rawValue, transactionUID: transactionUID,
                      attributes: DicomDataSetWriter.dataSetData(from: attributes,
                                                               transferSyntax: .explicitVRLittleEndian),
                      created: created, modified: modified, knownFinalStateTags: knownFinalStateTags.sorted())
        }
    }

    public init(persisted: DicomUnifiedProcedureStepPersistedRecord) throws {
        guard let state = DicomUnifiedProcedureStepState(rawValue: persisted.state) else {
            throw DicomUnifiedProcedureStepPersistenceError.invalidState
        }
        self.sopInstanceUID = persisted.sopInstanceUID
        self.state = state
        self.transactionUID = persisted.transactionUID
        self.attributes = try DicomDataSetParser.dataSet(from: persisted.attributes,
                                                       transferSyntax: .explicitVRLittleEndian)
        self.created = persisted.created
        self.modified = persisted.modified
        self.knownFinalStateTags = Set(persisted.knownFinalStateTags)
    }

    public func finalStateViolations(for targetState: DicomUnifiedProcedureStepState) -> [Int] {
        guard targetState.isFinal else { return [] }
        var missing: Set<Int> = []
        for row in DicomUnifiedProcedureStepAttribute.table {
            let required = row.finalState == "R" || (row.finalState == "P" && targetState == .completed)
                || (row.finalState == "X" && targetState == .canceled)
                || (row.finalState == "RC" && (knownFinalStateTags.contains(row.tag)
                    || (row.tag == 0x00080005 && containsExtendedText(attributes))))
            guard required else { continue }
            var containers = [attributes]
            for parent in row.path.dropLast() {
                containers = containers.flatMap { $0.sequenceItems(for: parent).map(\.dataSet) }
            }
            if containers.isEmpty {
                // An absent optional parent does not impose requirements on nonexistent items.
                if row.finalState == "RC" && knownFinalStateTags.contains(row.tag) { missing.insert(row.tag) }
                continue
            }
            for container in containers {
                // The table explicitly permits Output Information Sequence with no items.
                let valid = row.tag == 0x00404033 ? container[row.tag]?.vr == .SQ : upsValued(container[row.tag])
                if !valid { missing.insert(row.tag) }
            }
        }
        return missing.sorted()
    }

    public func changingState(to target: DicomUnifiedProcedureStepState, transactionUID: String?,
                              now: Date = Date()) -> DicomUnifiedProcedureStepTransition {
        func failure(_ status: UInt16) -> DicomUnifiedProcedureStepTransition { .init(record: self, status: status) }
        if target == .scheduled { return failure(0xC303) }
        guard let transactionUID, !transactionUID.isEmpty,
              self.transactionUID == nil || self.transactionUID == transactionUID else { return failure(0xC301) }
        if state == .scheduled && target != .inProgress { return failure(0xC310) }
        if state.isFinal {
            return failure(state == target ? (state == .completed ? 0xB306 : 0xB304) : 0xC300)
        }
        if state == .inProgress && target == .inProgress { return failure(0xC302) }
        var updated = self
        if target == .canceled {
            var progress = updated.attributes.sequenceItems(for: 0x00741002).first?.dataSet ?? .init()
            if !upsValued(progress[0x00404052]) { progress.set(upsString(0x00404052, upsTime(now), .DT)) }
            updated.attributes.set(upsSequence(0x00741002, [progress]))
        }
        if !updated.finalStateViolations(for: target).isEmpty { return failure(0xC304) }
        updated.state = target
        updated.transactionUID = transactionUID
        updated.modified = now
        updated.attributes.set(upsString(0x00741000, target.rawValue))
        return .init(record: updated, events: [.stateReport(updated)], status: 0)
    }
}

private func containsExtendedText(_ dataSet: DicomDataSet) -> Bool {
    dataSet.elements.contains { element in
        element.stringValues.contains { !$0.unicodeScalars.allSatisfy(\.isASCII) }
            || element.sequenceItems.contains { containsExtendedText($0.dataSet) }
    }
}

public struct DicomUnifiedProcedureStepTransition: Sendable {
    public let record: DicomUnifiedProcedureStepRecord?
    public let events: [DicomUnifiedProcedureStepEvent]
    public let status: UInt16
    public var warning: Bool { status & 0xF000 == 0xB000 || status == 1 }
    public init(record: DicomUnifiedProcedureStepRecord? = nil,
                events: [DicomUnifiedProcedureStepEvent] = [], status: UInt16) {
        self.record = record; self.events = events; self.status = status
    }
}

public enum DicomUnifiedProcedureStepSCPStatus: String, Sendable {
    case restarted = "RESTARTED", goingDown = "GOING DOWN"
}
public enum DicomUnifiedProcedureStepListStatus: String, Sendable {
    case warmStart = "WARM START", coldStart = "COLD START"
}

public struct DicomUnifiedProcedureStepEvent: Sendable {
    public enum Payload: Sendable {
        case state(DicomUnifiedProcedureStepState, inputReadiness: String, cancellation: DicomDataSet)
        case cancel(requestingAE: String, information: DicomDataSet)
        case progress(DicomDataSet)
        case scpStatus(DicomUnifiedProcedureStepSCPStatus, subscriptions: DicomUnifiedProcedureStepListStatus,
                       instances: DicomUnifiedProcedureStepListStatus)
        case assigned(DicomDataSet)
    }
    public let sopInstanceUID: String
    public let payload: Payload
    public init(sopInstanceUID: String, payload: Payload) { self.sopInstanceUID = sopInstanceUID; self.payload = payload }
    public var typeID: UInt16 {
        switch payload {
        case .state: 1
        case .cancel: 2
        case .progress: 3
        case .scpStatus: 4
        case .assigned: 5
        }
    }
    public var dataSet: DicomDataSet {
        switch payload {
        case let .state(state, readiness, cancellation):
            return .init(elements: [upsString(0x00741000, state.rawValue), upsString(0x00404041, readiness)]
                + cancellation.elements.filter { [0x00741238, 0x0074100E].contains($0.tag) })
        case let .cancel(ae, information):
            return .init(elements: [upsString(0x00741236, ae, .AE)] + information.elements.filter {
                [0x00741238, 0x0074100E, 0x0074100A, 0x0074100C].contains($0.tag)
            })
        case .progress(let information): return .init(elements: [upsSequence(0x00741002, [information])])
        case let .scpStatus(status, subscriptions, instances):
            return .init(elements: [upsString(0x00741242, status.rawValue),
                upsString(0x00741244, subscriptions.rawValue), upsString(0x00741246, instances.rawValue)])
        case .assigned(let information): return information
        }
    }
    static func stateReport(_ record: DicomUnifiedProcedureStepRecord) -> Self {
        .init(sopInstanceUID: record.sopInstanceUID, payload: .state(record.state,
            inputReadiness: record.attributes.string(for: 0x00404041) ?? "",
            cancellation: record.attributes.sequenceItems(for: 0x00741002).first?.dataSet ?? .init()))
    }
    static func assigned(_ record: DicomUnifiedProcedureStepRecord) -> Self? {
        var elements = record.attributes.elements.filter { $0.tag == 0x00404025 && upsValued($0) }
        for human in record.attributes.sequenceItems(for: 0x00404034) {
            elements += human.dataSet.elements.filter { [0x00404009, 0x00404036].contains($0.tag) && upsValued($0) }
        }
        return elements.isEmpty ? nil : .init(sopInstanceUID: record.sopInstanceUID,
                                              payload: .assigned(.init(elements: elements)))
    }
}

/// Checks explicit table rows recursively; macro attributes remain governed by their IOD definitions.
func upsAttributeViolations(_ dataSet: DicomDataSet, creating: Bool, parent: [Int] = []) -> [Int] {
    var invalid: Set<Int> = []
    for row in DicomUnifiedProcedureStepAttribute.table where Array(row.path.dropLast()) == parent {
        let code = creating ? row.create : row.set
        let element = dataSet[row.tag]
        if code.hasPrefix("1/1") && (creating || !parent.isEmpty || element != nil) && !upsValued(element) { invalid.insert(row.tag) }
        if let element {
            if code.hasPrefix("Not allowed") || code.hasPrefix("-/-") { invalid.insert(row.tag) }
            if creating && code.contains("empty") && upsValued(element) { invalid.insert(row.tag) }
            for item in element.sequenceItems {
                invalid.formUnion(upsAttributeViolations(item.dataSet, creating: creating, parent: row.path))
            }
        }
    }
    return invalid.sorted()
}
