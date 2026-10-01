import Foundation

public enum HL7BuildError: Error, Sendable {
    case invalid(HL7ValidationReport)
    case unsupportedVersion
}

public enum HL7ADTEvent: String, CaseIterable, Sendable { case A01, A03, A04, A08 }
public enum HL7AcknowledgmentCode: String, CaseIterable, Sendable { case AA, AE, AR }

public struct HL7Order: Sendable {
    public var placerID: String
    public var service: HL7CodedElement
    public init(placerID: String, service: HL7CodedElement) { self.placerID = placerID; self.service = service }
}

public struct HL7ObservationResult: Sendable {
    public var identifier: HL7CodedElement
    public var dataType: HL7DataTypeName
    public var value: HL7Repetition
    public var status: String
    public init(identifier: HL7CodedElement, dataType: HL7DataTypeName, value: HL7Repetition, status: String = "F") {
        self.identifier = identifier; self.dataType = dataType; self.value = value; self.status = status
    }
}

public struct HL7SegmentBuilder: Sendable {
    public var segment: HL7Segment
    public init(_ name: String) { segment = HL7Segment(name: name) }
    public mutating func set(_ field: Int, _ value: HL7Value) { segment[field] = HL7Field(value) }
    public mutating func set(_ field: Int, _ value: HL7Repetition) { segment[field] = HL7Field(repetitions: [value]) }
    public mutating func set<T: HL7TypedValue>(_ field: Int, _ value: T) { set(field, value.hl7Value) }
    public mutating func set(_ field: Int, repetitions: [HL7Repetition]) {
        segment[field] = HL7Field(repetitions: repetitions)
    }
}

public struct HL7MessageBuilder: Sendable {
    public let version: HL7Version
    public let profile: HL7Profile?
    public var allowInvalid = false
    public private(set) var message: HL7Message
    public init(version: HL7Version, profile: HL7Profile? = nil) {
        self.version = version; self.profile = profile; self.message = HL7Message(segments: [])
    }

    @discardableResult public mutating func msh(sendingApp: String = "", sendingFacility: String = "",
        receivingApp: String = "", receivingFacility: String = "", messageType: String,
        controlID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).description,
        processingID: String = "P", charset: HL7Charset = .ascii) -> Self {
        var header = HL7Segment(name: "MSH")
        let declaration: String
        switch charset {
        case .ascii: declaration = "ASCII"
        case .utf8: declaration = "UNICODE UTF-8"
        case .iso8859(let n): declaration = "8859/\(n)"
        case .windows1252: declaration = "WINDOWS-1252"
        case .unknown(let value): declaration = value
        }
        for (field, value) in [(1, "|"), (2, "^~\\&"), (3, sendingApp), (4, sendingFacility), (5, receivingApp),
            (6, receivingFacility), (7, Self.now()), (10, controlID), (11, processingID),
            (12, version.rawValue), (18, declaration)] { header[field] = HL7Field(.text(value)) }
        header[9] = messageTypeField(messageType)
        message["MSH"] = header
        message = HL7Message(segments: message.segments, charset: charset, charsetDeclarations: [declaration])
        return self
    }

    @discardableResult public mutating func segment(_ name: String, _ configure: (inout HL7SegmentBuilder) -> Void) -> Self {
        var builder = HL7SegmentBuilder(name)
        configure(&builder)
        message.segments.append(builder.segment)
        return self
    }

    public mutating func set(_ path: HL7Path, _ value: HL7Value) {
        guard let field = path.field, field > 0, path.repetition > 0,
              (path.component ?? 1) > 0, (path.subcomponent ?? 1) > 0 else { return }
        var segment = message[path.segment] ?? HL7Segment(name: path.segment)
        if path.component == nil && path.subcomponent == nil {
            var existing = segment[field]
            existing[path.repetition] = hl7Scalar(value)
            segment[field] = existing
        } else { segment[field][path.repetition][path.component ?? 1][path.subcomponent ?? 1] = value }
        message[path.segment] = segment
    }
    public mutating func set(_ path: HL7Path, _ value: HL7Repetition) {
        guard let field = path.field, field > 0, path.repetition > 0 else { return }
        var segment = message[path.segment] ?? HL7Segment(name: path.segment)
        if let component = path.component, component > 0 {
            segment[field][path.repetition][component] = HL7Component(subcomponents: value.components.map { $0[1] })
        } else { segment[field][path.repetition] = value }
        message[path.segment] = segment
    }
    public mutating func set<T: HL7TypedValue>(_ path: HL7Path, _ value: T) { set(path, value.hl7Value) }

    @discardableResult public mutating func adt(event: HL7ADTEvent, pid: HL7Segment, pv1: HL7Segment,
                                               evn: HL7Segment? = nil) -> Self {
        select("ADT^" + event.rawValue)
        var eventSegment = evn ?? HL7Segment(name: "EVN")
        if evn == nil {
            eventSegment[1] = HL7Field(.text(event.rawValue)); eventSegment[2] = HL7Field(.text(Self.now()))
        }
        message.segments += [eventSegment, pid, pv1]
        return self
    }

    @discardableResult public mutating func orm(order: HL7Order) -> Self {
        select("ORM^O01")
        segment("ORC") { $0.set(1, .text("NW")); $0.set(2, .text(order.placerID)) }
        segment("OBR") { $0.set(1, .text("1")); $0.set(2, .text(order.placerID)); $0.set(4, order.service) }
        return self
    }

    @discardableResult public mutating func oru(results: [HL7ObservationResult]) -> Self {
        select("ORU^R01")
        for (index, result) in results.enumerated() {
            segment("OBR") { $0.set(1, .text(String(index + 1))); $0.set(4, result.identifier) }
            segment("OBX") {
                $0.set(1, .text("1")); $0.set(2, .text(result.dataType.rawValue)); $0.set(3, result.identifier)
                $0.set(5, result.value); $0.set(11, .text(result.status))
            }
        }
        return self
    }

    @discardableResult public mutating func ack(for original: HL7Message, code: HL7AcknowledgmentCode,
        text: String? = nil, errors: [HL7ValidationFinding] = []) -> Self {
        msh(messageType: "ACK^" + (original.messageType.triggerEvent ?? "A01"), charset: original.charset)
        if let source = original["MSH"], var header = message["MSH"] {
            header[3] = source[5]; header[4] = source[6]; header[5] = source[3]; header[6] = source[4]
            message["MSH"] = header
        }
        segment("MSA") {
            $0.set(1, .text(code.rawValue)); $0.set(2, .text(original.controlID ?? ""))
            if let text { $0.set(3, .text(text)) }
        }
        let legacyError = version == .v2_3_1 || version == .v2_4
        for finding in errors {
            let number: String
            switch finding.code {
            case .requiredMissing, .conditionalUnmet: number = "101"
            case .dataTypeInvalid: number = "102"
            case .valueNotInSet: number = "103"
            case .unexpectedSegment, .segmentOrder, .cardinality, .zSegmentUnexpected: number = "100"
            default: number = "207"
            }
            segment("ERR") { error in
                if legacyError {
                    var location = hl7Repetition([finding.path.segment, String(finding.segmentOccurrence),
                                                 finding.path.field.map(String.init) ?? "", ""])
                    location[4] = HL7Component(subcomponents: [.text(number), .empty, .text("HL70357")])
                    error.set(1, location)
                } else {
                    error.set(2, hl7Repetition([finding.path.segment, String(finding.segmentOccurrence),
                        finding.path.field.map(String.init) ?? "", String(finding.path.repetition),
                        finding.path.component.map(String.init) ?? "", finding.path.subcomponent.map(String.init) ?? ""]))
                    error.set(3, HL7CodedElement(identifier: number, system: "HL70357"))
                    error.set(4, .text(finding.severity == .error ? "E" : "W"))
                }
            }
        }
        return self
    }

    @discardableResult public mutating func qryA19(patientID: String) -> Self {
        select("QRY^A19")
        segment("QRD") {
            $0.set(1, .text(Self.now())); $0.set(2, .text("R")); $0.set(3, .text("I")); $0.set(4, .text("Q1"))
            $0.set(7, hl7Repetition(["1", "RD"])); $0.set(8, .text(patientID))
            $0.set(9, .text("DEM")); $0.set(10, .text("ALL"))
        }
        return self
    }

    @discardableResult public mutating func qbpQ22(patientID: String, queryTag: String = "Q1") -> Self {
        select("QBP^Q22")
        queryParameters(patientID: patientID, queryTag: queryTag)
        segment("RCP") { $0.set(1, .text("I")) }
        return self
    }

    @discardableResult public mutating func rspK22(for query: HL7Message, patients: [HL7Segment],
                                                  code: HL7AcknowledgmentCode = .AA) -> Self {
        select("RSP^K22")
        if let source = query["MSH"], var header = message["MSH"] {
            header[3] = source[5]; header[4] = source[6]; header[5] = source[3]; header[6] = source[4]
            message["MSH"] = header
        }
        segment("MSA") { $0.set(1, .text(code.rawValue)); $0.set(2, .text(query.controlID ?? "")) }
        segment("QAK") {
            $0.set(1, query["QPD"]?[2][1][1][1] ?? .empty)
            $0.set(2, .text(code == .AA ? (patients.isEmpty ? "NF" : "OK") : code.rawValue))
        }
        if let qpd = query["QPD"] { message.segments.append(qpd) }
        message.segments += patients
        return self
    }

    public func build(allowInvalid: Bool = false) throws -> HL7Message {
        guard let schema = HL7SchemaRegistry.shared.schema(for: version), schema.version == version else {
            throw HL7BuildError.unsupportedVersion
        }
        let report = HL7Validator(schema: schema, profile: profile).validate(message)
        if !report.isValid && !allowInvalid && !self.allowInvalid { throw HL7BuildError.invalid(report) }
        return message
    }

    private mutating func select(_ type: String) {
        if message["MSH"] == nil { msh(messageType: type) }
        else {
            let field = messageTypeField(type)
            message["MSH"]?[9] = field
        }
    }
    private func messageTypeField(_ type: String) -> HL7Field {
        var parts = type.split(separator: "^", omittingEmptySubsequences: false).map(String.init)
        if versionKey(version.rawValue).map({ $0 >= 20500 }) == true {
            let key = parts.first == "ACK" ? "ACK" : parts.prefix(2).joined(separator: "^")
            if parts.count == 1 && parts.first == "ACK" { parts.append("A01") }
            if parts.count == 2, let id = HL7SchemaRegistry.shared.schema(for: version)?.messageTypeToStructure[key] {
                parts.append(id)
            }
        }
        return HL7Field(repetitions: [hl7Repetition(parts)])
    }
    private mutating func queryParameters(patientID: String, queryTag: String) {
        segment("QPD") {
            $0.set(1, HL7CodedElement(identifier: "Q22", text: "Find Candidates", system: "HL7"))
            $0.set(2, .text(queryTag)); $0.set(3, hl7Repetition(["@PID.3.1", patientID]))
        }
    }
    private static func now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmssZ"
        return formatter.string(from: Date())
    }
}
