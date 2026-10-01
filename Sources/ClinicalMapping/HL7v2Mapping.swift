import CryptoKit
import Foundation
import HL7v2

/// HL7 v2 <-> clinical model for the assigned profiles (ADT A01/A04/A08, ORM O01, ORU R01).
/// Every identifier keeps its assigning authority; unmapped segments are reported as lost.
public enum HL7v2ClinicalMapper {
    public static let mapperName = "HL7v2ClinicalMapper/1"

    // MARK: helpers

    static func text(_ segment: HL7Segment?, _ field: Int, _ component: Int = 1, repetition: Int = 1) -> String? {
        guard let segment else { return nil }
        let value = segment[field][repetition][component][1].text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    static func identifier(_ segment: HL7Segment?, _ field: Int, repetition: Int = 1) -> AssignedIdentifier? {
        guard let value = text(segment, field, 1, repetition: repetition) else { return nil }
        // CX: value^check^scheme^assigning authority(HD: namespace&universal id&type); EI: entity id^namespace^universal id^type
        let authority = text(segment, field, 4, repetition: repetition) ?? text(segment, field, 2, repetition: repetition)
        return AssignedIdentifier(value: value, authority: authority)
    }

    static func entityIdentifier(_ segment: HL7Segment?, _ field: Int) -> AssignedIdentifier? {
        guard let value = text(segment, field, 1) else { return nil }
        return AssignedIdentifier(value: value, authority: text(segment, field, 2) ?? text(segment, field, 3))
    }

    static func code(_ segment: HL7Segment?, _ field: Int) -> ClinicalCode? {
        guard let identifier = text(segment, field, 1) else { return nil }
        return ClinicalCode(system: text(segment, field, 3), code: identifier, display: text(segment, field, 2))
    }

    /// XCN (components) or NDL (name parts as subcomponents of component 1, as in OBR-32).
    static func practitioner(_ segment: HL7Segment?, _ field: Int) -> ClinicalPractitioner? {
        guard let segment else { return nil }
        func sub(_ index: Int) -> String? {
            let value = segment[field][1][1][index].text?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        if text(segment, field, 2) == nil, sub(2) != nil {
            return ClinicalPractitioner(identifier: sub(1).map { AssignedIdentifier(value: $0) }, familyName: sub(2), givenName: sub(3))
        }
        guard text(segment, field, 1) != nil || text(segment, field, 2) != nil else { return nil }
        return ClinicalPractitioner(identifier: text(segment, field, 1).map { AssignedIdentifier(value: $0, authority: text(segment, field, 9)) },
                                    familyName: text(segment, field, 2), givenName: text(segment, field, 3))
    }

    /// HL7 TS/DTM (`YYYYMMDDHHMMSS[.S][+/-ZZZZ]`) to ISO 8601 with the source precision; no zone is invented.
    public static func isoDateTime(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 4 else { return nil }
        let zoneIndex = raw.firstIndex { $0 == "+" || $0 == "-" }
        let main = zoneIndex.map { String(raw[..<$0]) } ?? raw
        let zone = zoneIndex.map { String(raw[$0...]) }
        let digits = main.split(separator: ".").first.map(String.init) ?? main
        guard digits.allSatisfy(\.isNumber) else { return nil }
        var iso = String(digits.prefix(4))
        if digits.count >= 6 { iso += "-" + digits.dropFirst(4).prefix(2) }
        if digits.count >= 8 { iso += "-" + digits.dropFirst(6).prefix(2) }
        if digits.count >= 12 {
            iso += "T" + digits.dropFirst(8).prefix(2) + ":" + digits.dropFirst(10).prefix(2) + ":" + (digits.count >= 14 ? String(digits.dropFirst(12).prefix(2)) : "00")
            if let zone, zone.count == 5 { iso += String(zone.prefix(3)) + ":" + zone.suffix(2) }
            else { return iso + (zone == nil ? "" : "") }   // a time without zone stays a documented loss in the report
        }
        return iso
    }

    static func hl7DateTime(_ iso: String?) -> String? {
        guard let iso else { return nil }
        var main = iso
        var zone = ""
        if main.hasSuffix("Z") {
            main.removeLast(); zone = "+0000"
        } else if let range = main.range(of: "[+-][0-9]{2}:?[0-9]{2}$", options: .regularExpression) {
            zone = String(main[range]).replacingOccurrences(of: ":", with: "")
            main.removeSubrange(range)
        }
        return main.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "T", with: "")
            .replacingOccurrences(of: ":", with: "") + zone
    }

    static func timestamp(_ date: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d%02d%02d%02d+0000", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static func sex(fromHL7 code: String?) -> String? {
        switch code?.uppercased() {
        case "M": return "M"
        case "F": return "F"
        case "O", "A", "N": return "O"
        default: return nil
        }
    }

    static func digest(_ message: HL7Message) -> String? {
        guard let data = try? HL7Serializer().serialize(message) else { return nil }
        return Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: v2 -> model

    public static func patient(from pid: HL7Segment?, report: inout MappingReport) -> ClinicalPatientIdentity {
        guard let pid else {
            report.add(.absent("patient", reason: "PID missing"))
            return ClinicalPatientIdentity()
        }
        var identity = ClinicalPatientIdentity()
        let identifiers = pid[3].repetitions.indices.compactMap { identifier(pid, 3, repetition: $0 + 1) }
        identity.identifier = identifiers.first
        identity.otherIdentifiers = Array(identifiers.dropFirst())
        report.add(identifiers.isEmpty ? .absent("patient.identifier", reason: "PID-3 missing") : .mapped("PID-3", "patient.identifier"))
        identity.familyName = text(pid, 5, 1)
        identity.givenName = text(pid, 5, 2)
        if let middle = text(pid, 5, 3) { identity.givenName = [identity.givenName, middle].compactMap { $0 }.joined(separator: " ") }
        report.add(identity.familyName == nil ? .absent("patient.name", reason: "PID-5 missing") : .mapped("PID-5", "patient.name"))
        if let birth = isoDateTime(text(pid, 7)) { identity.birthDate = String(birth.prefix(10)); report.add(.mapped("PID-7", "patient.birthDate")) }
        else { report.add(.absent("patient.birthDate")) }
        if let sex = sex(fromHL7: text(pid, 8)) { identity.sex = sex; report.add(.mapped("PID-8", "patient.sex")) }
        else if text(pid, 8) != nil { report.add(.lost("PID-8", reason: "codeSystemUnknown")) }
        else { report.add(.absent("patient.sex")) }
        return identity
    }

    public static func order(from message: HL7Message, options: MappingOptions = .init()) throws -> Mapped<ClinicalOrder> {
        guard message.messageType.code == "ORM" else { throw MappingError.unsupportedMessage(message.messageType.code ?? "") }
        var report = MappingReport()
        let pid = message["PID"], orc = message["ORC"], obr = message["OBR"], pv1 = message["PV1"]
        var order = ClinicalOrder(patient: patient(from: pid, report: &report))
        order.placerOrderNumber = entityIdentifier(orc, 2) ?? entityIdentifier(obr, 2)
        order.fillerOrderNumber = entityIdentifier(orc, 3) ?? entityIdentifier(obr, 3)
        report.add(order.placerOrderNumber == nil ? .absent("order.placerOrderNumber", reason: "ORC-2/OBR-2 missing") : .mapped("ORC-2", "order.placerOrderNumber"))
        if order.fillerOrderNumber != nil { report.add(.mapped("ORC-3", "order.fillerOrderNumber")) }
        // Accession in OBR-18 (Placer Field 1, IHE RAD); its issuer in OBR-20 (Filler Field 2, Isis profile). Both are ST.
        if let accession = text(obr, 18) { order.accessionNumber = AssignedIdentifier(value: accession, authority: text(obr, 20)); report.add(.mapped("OBR-18/OBR-20", "order.accessionNumber")) }
        order.procedure = code(obr, 4)
        report.add(order.procedure == nil ? .absent("order.procedure", reason: "OBR-4 missing") : .mapped("OBR-4", "order.procedure"))
        order.procedureDescription = text(obr, 4, 2)
        order.modality = text(obr, 24)
        if order.modality != nil { report.add(.mapped("OBR-24", "order.modality")) }
        if let start = isoDateTime(text(obr, 27, 4) ?? text(orc, 7, 4)) { order.scheduledStart = start; report.add(.mapped("OBR-27.4", "order.scheduledStart")) }
        order.referringPhysician = practitioner(orc, 12) ?? practitioner(obr, 16)
        if order.referringPhysician != nil { report.add(.mapped("ORC-12", "order.referringPhysician")) }
        order.priority = text(obr, 5) ?? text(orc, 7, 6)
        switch text(orc, 1) {
        case "NW", "SN": order.status = .requested
        case "SC": order.status = .scheduled
        case "CA", "OC": order.status = .cancelled
        case "DC": order.status = .cancelled
        default: order.status = .unknown
        }
        report.add(.mapped("ORC-1", "order.status"))
        for segment in message.segments where !["MSH", "PID", "PV1", "ORC", "OBR", "NTE", "EVN"].contains(segment.name) {
            report.add(.lost(segment.name, reason: "noTargetInProfile"))
        }
        if pv1 != nil { report.add(.lost("PV1", reason: "encounterNotModelled")) }
        if options.strict, report.hasLoss { throw MappingError.lossNotAllowed(report) }
        let provenance = ClinicalProvenance(sourceKind: .hl7v2, sourceIdentifier: message.controlID ?? "", sourceDigest: digest(message), mapper: mapperName, report: report)
        return Mapped(value: order, provenance: provenance)
    }

    public static func identity(from message: HL7Message, options: MappingOptions = .init()) throws -> Mapped<ClinicalPatientIdentity> {
        guard message.messageType.code == "ADT" else { throw MappingError.unsupportedMessage(message.messageType.code ?? "") }
        var report = MappingReport()
        let identity = patient(from: message["PID"], report: &report)
        for segment in message.segments where !["MSH", "EVN", "PID"].contains(segment.name) { report.add(.lost(segment.name, reason: "noTargetInProfile")) }
        if options.strict, report.hasLoss { throw MappingError.lossNotAllowed(report) }
        return Mapped(value: identity, provenance: .init(sourceKind: .hl7v2, sourceIdentifier: message.controlID ?? "", sourceDigest: digest(message), mapper: mapperName, report: report))
    }

    public static func result(from message: HL7Message, options: MappingOptions = .init()) throws -> Mapped<ClinicalResult> {
        guard message.messageType.code == "ORU" else { throw MappingError.unsupportedMessage(message.messageType.code ?? "") }
        var report = MappingReport()
        let pid = message["PID"], obr = message["OBR"]
        var result = ClinicalResult(patient: patient(from: pid, report: &report))
        result.placerOrderNumber = entityIdentifier(obr, 2)
        result.fillerOrderNumber = entityIdentifier(obr, 3)
        result.identifier = result.fillerOrderNumber ?? result.placerOrderNumber
        if let accession = text(obr, 18) { result.accessionNumber = AssignedIdentifier(value: accession, authority: text(obr, 20)); report.add(.mapped("OBR-18/OBR-20", "result.accessionNumber")) }
        if let uid = text(obr, 19) ?? text(message["ZDS"], 1) { result.studyInstanceUID = uid; report.add(.mapped(text(obr, 19) != nil ? "OBR-19" : "ZDS-1", "result.studyInstanceUID")) }
        else { report.add(.absent("result.studyInstanceUID", reason: "OBR-19/ZDS-1 missing")) }
        result.procedure = code(obr, 4)
        switch text(obr, 25) {
        case "F": result.status = .final
        case "P", "A", "R", "I": result.status = .preliminary
        case "C": result.status = .corrected
        case "X": result.status = .cancelled
        default: result.status = .unknown
        }
        report.add(.mapped("OBR-25", "result.status"))
        result.issued = isoDateTime(text(obr, 22) ?? text(obr, 7))
        result.author = practitioner(obr, 32)
        var observations: [ClinicalObservation] = []
        var texts: [String] = []
        for segment in message.segments where segment.name == "OBX" {
            guard let code = code(segment, 3) else { report.add(.lost("OBX-3", reason: "codeMissing")); continue }
            let type = text(segment, 2) ?? ""
            let raw = text(segment, 5)
            let value: ClinicalObservation.Value
            switch type {
            case "NM", "SN": value = raw.map { .numeric(value: $0, unit: text(segment, 6)) } ?? .absent(reason: "OBX-5 missing")
            case "CE", "CWE", "CNE": value = raw.map { .coded(ClinicalCode(system: text(segment, 5, 3), code: $0, display: text(segment, 5, 2))) } ?? .absent(reason: "OBX-5 missing")
            case "ST", "TX", "FT": value = raw.map { .text($0) } ?? .absent(reason: "OBX-5 missing")
            default:
                report.add(.lost("OBX-5", reason: "valueTypeUnsupported:" + type))
                continue
            }
            observations.append(ClinicalObservation(code: code, value: value, status: text(segment, 11), effective: isoDateTime(text(segment, 14)),
                                                    interpretation: text(segment, 8), referenceRange: text(segment, 7), subID: text(segment, 4)))
            report.add(.mapped("OBX", "result.observations"))
        }
        for segment in message.segments where segment.name == "NTE" {
            if let comment = text(segment, 3) { texts.append(comment); report.add(.mapped("NTE-3", "result.reportText")) }
        }
        result.observations = observations
        result.reportText = texts
        for segment in message.segments where !["MSH", "PID", "PV1", "ORC", "OBR", "OBX", "NTE", "ZDS"].contains(segment.name) {
            report.add(.lost(segment.name, reason: "noTargetInProfile"))
        }
        if options.strict, report.hasLoss { throw MappingError.lossNotAllowed(report) }
        return Mapped(value: result, provenance: .init(sourceKind: .hl7v2, sourceIdentifier: message.controlID ?? "", sourceDigest: digest(message), mapper: mapperName, report: report))
    }

    // MARK: model -> v2

    static func pidSegment(_ identity: ClinicalPatientIdentity, report: inout MappingReport) -> HL7Segment {
        var pid = HL7SegmentBuilder("PID")
        pid.set(1, .text("1"))
        let identifiers = [identity.identifier].compactMap { $0 } + identity.otherIdentifiers
        if !identifiers.isEmpty {
            pid.set(3, repetitions: identifiers.map { identifier in
                HL7Repetition(components: [HL7Component(subcomponents: [.text(identifier.value)]), HL7Component(), HL7Component(),
                                           HL7Component(subcomponents: [.text(identifier.authority ?? "")])])
            })
            report.add(.mapped("patient.identifier", "PID-3"))
        } else { report.add(.absent("PID-3")) }
        if identity.familyName != nil || identity.givenName != nil {
            pid.set(5, HL7PersonName(family: identity.familyName ?? "", given: identity.givenName ?? ""))
            report.add(.mapped("patient.name", "PID-5"))
        }
        if let birth = identity.birthDate { pid.set(7, .text(birth.replacingOccurrences(of: "-", with: ""))); report.add(.mapped("patient.birthDate", "PID-7")) }
        if let sex = identity.sex { pid.set(8, .text(sex)); report.add(.mapped("patient.sex", "PID-8")) }
        return pid.segment
    }

    static func entity(_ identifier: AssignedIdentifier?) -> HL7Repetition {
        HL7Repetition(components: [HL7Component(subcomponents: [.text(identifier?.value ?? "")]), HL7Component(subcomponents: [.text(identifier?.authority ?? "")])])
    }

    public static func ormMessage(from order: ClinicalOrder, version: HL7Version = .v2_5_1, sendingApp: String = "ISIS", sendingFacility: String = "",
                                  controlID: String? = nil) throws -> Mapped<HL7Message> {
        var report = MappingReport()
        var builder = HL7MessageBuilder(version: version)
        builder.allowInvalid = true
        builder.msh(sendingApp: sendingApp, sendingFacility: sendingFacility, messageType: "ORM^O01^ORM_O01", controlID: controlID ?? UUID().uuidString.prefix(20).description)
        let pid = pidSegment(order.patient, report: &report)
        builder.segment("PID") { $0.segment = pid }
        builder.segment("ORC") { orc in
            orc.set(1, .text(order.status == .cancelled ? "CA" : "NW"))
            orc.set(2, entity(order.placerOrderNumber))
            if order.fillerOrderNumber != nil { orc.set(3, entity(order.fillerOrderNumber)) }
            if let referrer = order.referringPhysician {
                orc.set(12, HL7Repetition(components: [HL7Component(subcomponents: [.text(referrer.identifier?.value ?? "")]), HL7Component(subcomponents: [.text(referrer.familyName ?? "")]), HL7Component(subcomponents: [.text(referrer.givenName ?? "")])]))
            }
        }
        builder.segment("OBR") { obr in
            obr.set(1, .text("1"))
            obr.set(2, entity(order.placerOrderNumber))
            if order.fillerOrderNumber != nil { obr.set(3, entity(order.fillerOrderNumber)) }
            if let procedure = order.procedure {
                obr.set(4, HL7CodedElement(identifier: procedure.code, text: procedure.display ?? order.procedureDescription ?? "", system: procedure.system ?? ""))
            }
            if let priority = order.priority { obr.set(5, .text(priority)) }
            if let accession = order.accessionNumber {
                obr.set(18, .text(accession.value))
                if let authority = accession.authority { obr.set(20, .text(authority)) }
            }
            if let modality = order.modality { obr.set(24, .text(modality)) }
            if let start = hl7DateTime(order.scheduledStart) {
                obr.set(27, HL7Repetition(components: [HL7Component(), HL7Component(), HL7Component(), HL7Component(subcomponents: [.text(start)])]))
            }
        }
        report.add(.mapped("order", "ORM^O01"))
        if order.reason != nil { report.add(.lost("order.reason", reason: "noTargetInProfile")) }
        let message = try builder.build(allowInvalid: true)
        return Mapped(value: message, provenance: .init(sourceKind: .hl7v2, sourceIdentifier: message.controlID ?? "", mapper: mapperName, report: report))
    }

    public static func oruMessage(from result: ClinicalResult, version: HL7Version = .v2_5_1, sendingApp: String = "ISIS", controlID: String? = nil) throws -> Mapped<HL7Message> {
        var report = MappingReport()
        var builder = HL7MessageBuilder(version: version)
        builder.allowInvalid = true
        builder.msh(sendingApp: sendingApp, messageType: "ORU^R01^ORU_R01", controlID: controlID ?? UUID().uuidString.prefix(20).description)
        let pid = pidSegment(result.patient, report: &report)
        builder.segment("PID") { $0.segment = pid }
        builder.segment("ORC") { orc in
            orc.set(1, .text("RE"))
            orc.set(2, entity(result.placerOrderNumber))
            orc.set(3, entity(result.fillerOrderNumber))
        }
        builder.segment("OBR") { obr in
            obr.set(1, .text("1"))
            obr.set(2, entity(result.placerOrderNumber))
            obr.set(3, entity(result.fillerOrderNumber))
            if let procedure = result.procedure { obr.set(4, HL7CodedElement(identifier: procedure.code, text: procedure.display ?? "", system: procedure.system ?? "")) }
            if let accession = result.accessionNumber {
                obr.set(18, .text(accession.value))
                if let authority = accession.authority { obr.set(20, .text(authority)) }
            }
            if let uid = result.studyInstanceUID { obr.set(19, .text(uid)) }
            if let issued = hl7DateTime(result.issued) { obr.set(22, .text(issued)) }
            let status: String
            switch result.status {
            case .final: status = "F"
            case .preliminary: status = "P"
            case .corrected: status = "C"
            case .cancelled: status = "X"
            case .unknown: status = "I"
            }
            obr.set(25, .text(status))
            if let author = result.author {
                obr.set(32, HL7Repetition(components: [HL7Component(subcomponents: [.text(author.identifier?.value ?? ""), .text(author.familyName ?? ""), .text(author.givenName ?? "")])]))
            }
        }
        for (index, observation) in result.observations.enumerated() {
            builder.segment("OBX") { obx in
                obx.set(1, .text(String(index + 1)))
                obx.set(3, HL7CodedElement(identifier: observation.code.code, text: observation.code.display ?? "", system: observation.code.system ?? ""))
                if let subID = observation.subID { obx.set(4, .text(subID)) }
                switch observation.value {
                case .numeric(let value, let unit):
                    obx.set(2, .text("NM")); obx.set(5, .text(value))
                    if let unit { obx.set(6, HL7CodedElement(identifier: unit)) }
                case .coded(let code):
                    obx.set(2, .text("CE")); obx.set(5, HL7CodedElement(identifier: code.code, text: code.display ?? "", system: code.system ?? ""))
                case .text(let text):
                    obx.set(2, .text("TX")); obx.set(5, .text(text))
                case .absent(let reason):
                    obx.set(2, .text("TX"))
                    report.add(.changed("result.observations[\(index)].value", "OBX-5", reason: "absentValue:" + reason))
                }
                if let range = observation.referenceRange { obx.set(7, .text(range)) }
                if let interpretation = observation.interpretation { obx.set(8, .text(interpretation)) }
                obx.set(11, .text(observation.status ?? "F"))
                if let effective = hl7DateTime(observation.effective) { obx.set(14, .text(effective)) }
            }
        }
        for (index, line) in result.reportText.enumerated() {
            builder.segment("NTE") { nte in nte.set(1, .text(String(index + 1))); nte.set(3, .text(line)) }
        }
        report.add(.mapped("result", "ORU^R01"))
        if result.supersedes != nil { report.add(.changed("result.supersedes", "OBR-25", reason: "correctionExpressedAsStatus")) }
        let message = try builder.build(allowInvalid: true)
        return Mapped(value: message, provenance: .init(sourceKind: .hl7v2, sourceIdentifier: message.controlID ?? "", mapper: mapperName, report: report))
    }

    public static func adtMessage(from identity: ClinicalPatientIdentity, event: HL7ADTEvent = .A08, version: HL7Version = .v2_5_1, sendingApp: String = "ISIS", controlID: String? = nil) throws -> Mapped<HL7Message> {
        var report = MappingReport()
        var builder = HL7MessageBuilder(version: version)
        builder.allowInvalid = true
        builder.msh(sendingApp: sendingApp, messageType: "ADT^\(event.rawValue)^ADT_A01", controlID: controlID ?? UUID().uuidString.prefix(20).description)
        var evn = HL7SegmentBuilder("EVN")
        evn.set(1, .text(event.rawValue))
        evn.set(2, .text(Self.timestamp()))
        builder.segment("EVN") { $0 = evn }
        let pid = pidSegment(identity, report: &report)
        builder.segment("PID") { $0.segment = pid }
        builder.segment("PV1") { pv1 in pv1.set(1, .text("1")); pv1.set(2, .text("N")) }
        let message = try builder.build(allowInvalid: true)
        return Mapped(value: message, provenance: .init(sourceKind: .hl7v2, sourceIdentifier: message.controlID ?? "", mapper: mapperName, report: report))
    }
}
