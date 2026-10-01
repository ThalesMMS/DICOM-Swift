import Foundation

/// Local supported message subset. Segment/type attribute facts are recorded separately for every version.
/// Reference: HL7 Europe, https://www.hl7.eu/HL7v2x/ (v231, v24, v25, v251, v26).
enum HL7Tables {
    static func schema(_ version: HL7Version) -> HL7SchemaVersion {
        let raw: [String: String]
        let types: [String: String]
        let sets: [String: Set<String>]
        switch version {
        case .v2_3_1: raw = v2_3_1; types = types2_3_1; sets = sets2_3_1
        case .v2_4: raw = v2_4; types = types2_4; sets = sets2_4
        case .v2_5: raw = v2_5; types = types2_5; sets = sets2_5
        case .v2_5_1: raw = v2_5_1; types = types2_5_1; sets = sets2_5_1
        default: raw = v2_6; types = types2_6; sets = sets2_6
        }
        var segments = raw.mapValues { fields($0) }
        for name in segments.keys { segments[name]?.name = name }
        segments["ZXX"] = HL7SegmentDefinition(name: "ZXX", fields: [])
        // OBX-5 is typed by OBX-2. Result values are conditional on OBX-11 (X means unobtainable).
        if let i = segments["OBX"]?.fields.firstIndex(where: { $0.index == 5 }) {
            segments["OBX"]?.fields[i].dataTypeField = 2
            segments["OBX"]?.fields[i].condition = .init(field: 11, values: ["F", "P", "C", "R", "S", "U"])
        }
        // Q22 defines the otherwise query-specific QPD parameter field as a repeating QIP.
        if let i = segments["QPD"]?.fields.firstIndex(where: { $0.index == 3 }) {
            segments["QPD"]?.fields[i].dataType = .QIP
            segments["QPD"]?.fields[i].repeatable = true
        }
        var dataTypes: [HL7DataTypeName: HL7DataTypeDefinition] = [:]
        for (name, table) in types {
            guard let type = HL7DataTypeName(rawValue: name) else { continue }
            let components = table.split(separator: "\n").map { row -> HL7DataTypeDefinition.Component in
                let c = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                return .init(name: c[0], dataType: HL7DataTypeName(rawValue: c[1])!,
                             optionality: HL7Optionality(rawValue: c[2])!, maxLength: Int(c[3]))
            }
            dataTypes[type] = .init(name: type, components: components, versions: [version.rawValue])
        }
        completeLegacyTypes(&dataTypes, version: version)
        let structures = structures(version)
        var mapping = ["ADT^A01": "ADT_A01", "ADT^A04": "ADT_A01", "ADT^A08": "ADT_A01",
                       "ADT^A03": "ADT_A03", "ORM^O01": "ORM_O01", "ORU^R01": "ORU_R01",
                       "ACK": "ACK", "QRY^A19": "QRY_A19"]
        if version != .v2_3_1 { mapping["QBP^Q22"] = "QBP_Q21"; mapping["RSP^K22"] = "RSP_K22" }
        return HL7SchemaVersion(version: version, segments: segments, structures: structures,
                                messageTypeToStructure: mapping, valueSets: sets, dataTypes: dataTypes)
    }

    // These older registry pages name composite types but omit their component rows.
    // The layouts below express the historical components rather than treating the types as strings.
    private static func completeLegacyTypes(_ types: inout [HL7DataTypeName: HL7DataTypeDefinition], version: HL7Version) {
        let layouts: [HL7DataTypeName: [(String, HL7DataTypeName)]] = [
            .MSG: [("Message Code", .ID), ("Trigger Event", .ID), ("Message Structure", .ID)],
            .VID: [("Version ID", .ID), ("Internationalization Code", .CE), ("International Version ID", .CE)],
            .ELD: [("Segment ID", .ST), ("Segment Sequence", .NM), ("Field Position", .NM), ("Error Code", .CE)],
            .ERL: [("Segment ID", .ST), ("Segment Sequence", .NM), ("Field Position", .NM),
                   ("Field Repetition", .NM), ("Component Number", .NM), ("Subcomponent Number", .NM)],
            .EIP: [("Placer Assigned Identifier", .EI), ("Filler Assigned Identifier", .EI)],
            .FN: [("Surname", .ST), ("Own Surname Prefix", .ST), ("Own Surname", .ST),
                  ("Surname Prefix From Partner", .ST), ("Surname From Partner", .ST)],
            .VR: [("First Data Code Value", .ST), ("Last Data Code Value", .ST)],
            .MOC: [("Monetary Amount", .MO), ("Charge Code", .CE)],
            .DLD: [("Discharge Location", .IS), ("Effective Date", .TS)],
            .AUI: [("Authorization Number", .ST), ("Date", .DT), ("Source", .ST)],
            .PRL: [("Parent Observation Identifier", .CE), ("Parent Observation Sub-identifier", .ST), ("Parent Observation Value", .TX)],
            .SPS: [("Specimen Source Name", .CE), ("Additives", .TX), ("Collection Method", .TX),
                   ("Body Site", .CE), ("Site Modifier", .CE), ("Collection Modifier", .CE), ("Specimen Role", .CE)],
            .NDL: [("Name", .CNN), ("Start Date/Time", .TS), ("End Date/Time", .TS), ("Point Of Care", .IS),
                   ("Room", .IS), ("Bed", .IS), ("Facility", .HD), ("Location Status", .IS),
                   ("Patient Location Type", .IS), ("Building", .IS), ("Floor", .IS)],
            .OSD: [("Sequence Results Flag", .ID), ("Placer Entity Identifier", .ST), ("Placer Namespace", .IS),
                   ("Filler Entity Identifier", .ST), ("Filler Namespace", .IS), ("Sequence Condition", .ST),
                   ("Maximum Repeats", .NM), ("Placer Universal ID", .ST), ("Placer Universal ID Type", .ID),
                   ("Filler Universal ID", .ST), ("Filler Universal ID Type", .ID)],
            .SAD: [("Street Or Mailing Address", .ST), ("Street Name", .ST), ("Dwelling Number", .ST)],
            .SRT: [("Sort-by Field", .ST), ("Sequencing", .ID)],
            .CNN: [("ID Number", .ST), ("Family Name", .ST), ("Given Name", .ST), ("Second Names", .ST),
                   ("Suffix", .ST), ("Prefix", .ST), ("Degree", .IS), ("Source Table", .IS),
                   ("Assigning Authority Namespace", .IS), ("Assigning Authority ID", .ST), ("Assigning Authority Type", .ID)]
        ]
        if version == .v2_3_1 { types[.CNE] = nil; types[.CWE] = nil }
        for (name, layout) in layouts where types[name]?.components.isEmpty == true {
            types[name]?.components = layout.map { .init(name: $0.0, dataType: $0.1) }
        }
    }

    // index | name | type | optionality | repetitions (* unlimited) | length | table | introduced | deprecated
    private static func fields(_ table: String) -> HL7SegmentDefinition {
        .init(name: "", fields: table.split(separator: "\n").map { line in
            let c = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            return .init(index: Int(c[0])!, name: c[1], dataType: HL7DataTypeName(rawValue: c[2])!,
                         optionality: HL7Optionality(rawValue: c[3])!, repeatable: c[4] != "1",
                         maxRepetitions: Int(c[4]), length: Int(c[5]), valueSetID: c[6].isEmpty ? nil : c[6],
                         introducedIn: c[7].isEmpty ? nil : c[7], deprecatedIn: c[8].isEmpty ? nil : c[8])
        })
    }

    private static func structures(_ version: HL7Version) -> [String: HL7MessageStructure] {
        func s(_ name: String, _ min: Int = 0, _ max: Int? = 1) -> HL7StructureNode {
            .init(segment: name, min: min, max: max)
        }
        func g(_ name: String, _ nodes: [HL7StructureNode], _ min: Int = 0, _ max: Int? = 1) -> HL7StructureNode {
            .init(group: name, children: nodes, min: min, max: max)
        }
        let insurance = g("INSURANCE", [s("IN1", 1)], 0, nil)
        let visit = g("VISIT", [s("PV1", 1), s("PV2")])
        let patient = g("PATIENT", [s("PID", 1), s("PD1"), s("NTE", 0, nil), visit])
        let observation = g("OBSERVATION", [s("OBX", 1), s("NTE", 0, nil)], 0, nil)
        let order = g("ORDER_OBSERVATION", [s("ORC"), s("OBR", 1), s("NTE", 0, nil), observation], 1, nil)
        let adt = [s("MSH", 1), s("EVN", 1), s("PID", 1), s("PD1"), s("NK1", 0, nil),
                   s("PV1", 1), s("PV2"), s("OBX", 0, nil), s("AL1", 0, nil), s("DG1", 0, nil),
                   s("GT1", 0, nil), insurance]
        var all: [HL7MessageStructure] = [
            .init(id: "ADT_A01", children: adt), .init(id: "ADT_A03", children: adt),
            .init(id: "ACK", children: [s("MSH", 1), s("MSA", 1), s("ERR", 0, nil)]),
            .init(id: "ORM_O01", children: [s("MSH", 1), s("NTE", 0, nil), patient,
                g("ORDER", [s("ORC", 1), g("ORDER_DETAIL", [s("OBR", 1), s("NTE", 0, nil),
                    s("DG1", 0, nil), observation], 0, nil)], 1, nil)]),
            .init(id: "ORU_R01", children: [s("MSH", 1),
                g("PATIENT_RESULT", [patient, order], 1, nil), s("DSC")]),
            .init(id: "QRY_A19", children: [s("MSH", 1), s("QRD", 1), s("QRF")])
        ]
        if version != .v2_3_1 {
            all.append(.init(id: "QBP_Q21", children: [s("MSH", 1), s("QPD", 1), s("RCP", 1), s("DSC")]))
            all.append(.init(id: "RSP_K22", children: [s("MSH", 1), s("MSA", 1), s("ERR", 0, nil),
                s("QAK", 1), s("QPD", 1), g("QUERY_RESPONSE", [s("PID", 1), s("PD1")], 0, nil), s("DSC")]))
        }
        return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    }
}
