import Foundation

/// Included PS3.3 Chapter 10 macros shared by the common composite modules. Rules cover
/// structure and conditions; identity resolution, terminology membership and target
/// availability remain separate layers.
public enum DicomCommonMacros {
    /// A condition whose only evidence is the attribute itself is satisfied when present
    /// and undetermined when absent; absence never establishes a false condition.
    static func selfEvidencing(_ tag: Int) -> DicomAttributeRule.Condition { .any([.present(tag), .undetermined]) }

    static let universalEntityIDTypes: Set<String> = ["DNS", "EUI64", "ISO", "URI", "UUID", "X400", "X500"]

    /// Table 10-17 HL7v2 Hierarchic Designator Macro.
    public static func hl7HierarchicDesignator() -> [DicomAttributeRule] {
        [
            .init(tag: 0x00400031, requirement: .type1C, condition: .not(.present(0x00400032)), mayBePresentOtherwise: true),
            .init(tag: 0x00400032, requirement: .type1C, condition: .not(.present(0x00400031)), mayBePresentOtherwise: true),
            .init(tag: 0x00400033, requirement: .type1C, condition: .present(0x00400032),
                  constraints: [.strings(universalEntityIDTypes)])
        ]
    }

    /// Table 10-18 Issuer of Patient ID Macro.
    public static func issuerOfPatientID() -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        return [
            .init(tag: 0x00100021, requirement: .type3),
            .init(tag: 0x00100024, requirement: .type3, itemRules: [
                .init(tag: 0x00400032, requirement: .type3),
                .init(tag: 0x00400033, requirement: .type1C, condition: .present(0x00400032),
                      constraints: [.strings(universalEntityIDTypes)]),
                .init(tag: 0x00400035, requirement: .type3),
                .init(tag: 0x00400036, requirement: .type3, itemRules: hl7HierarchicDesignator(), constraints: [.itemCount(1...1)]),
                .init(tag: 0x00400039, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...1)]),
                .init(tag: 0x0040003A, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...1)])
            ], constraints: [.itemCount(1...1)])
        ]
    }

    /// Table 10-11 SOP Instance Reference Macro.
    public static func sopInstanceReference() -> [DicomAttributeRule] {
        [0x00081150, 0x00081155].map { .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1)]) }
    }

    /// Table 10-3 Image SOP Instance Reference Macro. A reference that does not apply to the whole
    /// object is encoded only by its selector, so an absent selector denotes the whole object; whether
    /// a present selector suits the referenced object needs its metadata and is not checked here.
    public static func imageSOPInstanceReference() -> [DicomAttributeRule] {
        sopInstanceReference() + [
            .init(tag: 0x00081160, requirement: .type1C, condition: .present(0x00081160),
                  constraints: [.forbiddenWhen(.present(0x0062000B))]),
            .init(tag: 0x0062000B, requirement: .type1C, condition: .present(0x0062000B),
                  constraints: [.forbiddenWhen(.present(0x00081160))])
        ]
    }

    /// Table 10-3b Referenced Patient Photo item content.
    public static func referencedPatientPhoto() -> [DicomAttributeRule] {
        let retrievals = [0x0040E021, 0x0040E022, 0x0040E023, 0x0040E024, 0x0040E025]
        func alternative(_ tag: Int, _ items: [DicomAttributeRule]) -> DicomAttributeRule {
            .init(tag: tag, requirement: .type1C,
                  condition: .all(retrievals.filter { $0 != tag }.map { .not(.present($0)) }),
                  mayBePresentOtherwise: true, itemRules: items, constraints: [.itemCount(1...Int.max)])
        }
        return [
            .init(tag: 0x00081199, requirement: .type1, itemRules: imageSOPInstanceReference() + [
                .init(tag: 0x0040E001, requirement: .type1C, condition: selfEvidencing(0x0040E001))
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x0040E020, requirement: .type1, constraints: [.valueCount(1...1)]),
            .init(tag: 0x0020000D, requirement: .type1C, condition: .stringEquals(0x0040E020, "DICOM"), mayBePresentOtherwise: true),
            .init(tag: 0x0020000E, requirement: .type1C, condition: .stringEquals(0x0040E020, "DICOM"), mayBePresentOtherwise: true),
            alternative(0x0040E021, [.init(tag: 0x00080054, requirement: .type1)]),
            alternative(0x0040E022, [.init(tag: 0x00880130, requirement: .type2), .init(tag: 0x00880140, requirement: .type1)]),
            alternative(0x0040E023, [.init(tag: 0x0040E010, requirement: .type1)]),
            alternative(0x0040E024, [.init(tag: 0x0040E030, requirement: .type1), .init(tag: 0x0040E031, requirement: .type3)]),
            alternative(0x0040E025, [.init(tag: 0x00081190, requirement: .type1)])
        ]
    }

    /// Table 10-2 Content Item Macro, as included by protocol context and specimen preparation.
    public static func contentItem() -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        func when(_ values: [String]) -> DicomAttributeRule.Condition { .any(values.map { .stringEquals(0x0040A040, $0) }) }
        return [
            .init(tag: 0x0040A040, requirement: .type1, constraints: [.valueCount(1...1), .strings(["DATE", "TIME", "DATETIME",
                "PNAME", "UIDREF", "TEXT", "CODE", "NUMERIC", "COMPOSITE", "IMAGE", "WAVEFORM"])]),
            .init(tag: 0x0040A043, requirement: .type1, itemRules: codes, constraints: [.itemCount(1...1)]),
            .init(tag: 0x0040A032, requirement: .type3), .init(tag: 0x0040A033, requirement: .type3),
            .init(tag: 0x00081199, requirement: .type1C, condition: when(["COMPOSITE", "IMAGE", "WAVEFORM"]), mayBePresentOtherwise: true,
                  itemRules: imageSOPInstanceReference() + [
                      .init(tag: 0x0040A0B0, requirement: .type1C, condition: selfEvidencing(0x0040A0B0))
                  ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x004008EA, requirement: .type1C, condition: when(["NUMERIC"]), mayBePresentOtherwise: true,
                  itemRules: codes, constraints: [.itemCount(1...1)]),
            .init(tag: 0x0040A30A, requirement: .type1C, condition: when(["NUMERIC"]), mayBePresentOtherwise: true),
            .init(tag: 0x0040A161, requirement: .type1C, condition: selfEvidencing(0x0040A161)),
            .init(tag: 0x0040A162, requirement: .type1C, condition: selfEvidencing(0x0040A162)),
            .init(tag: 0x0040A163, requirement: .type1C, condition: .present(0x0040A162)),
            .init(tag: 0x0040A120, requirement: .type1C, condition: when(["DATETIME"]), mayBePresentOtherwise: true),
            .init(tag: 0x0040A121, requirement: .type1C, condition: when(["DATE"]), mayBePresentOtherwise: true),
            .init(tag: 0x0040A122, requirement: .type1C, condition: when(["TIME"]), mayBePresentOtherwise: true),
            .init(tag: 0x0040A123, requirement: .type1C, condition: when(["PNAME"]), mayBePresentOtherwise: true),
            .init(tag: 0x0040A124, requirement: .type1C, condition: when(["UIDREF"]), mayBePresentOtherwise: true),
            .init(tag: 0x0040A160, requirement: .type1C, condition: when(["TEXT"]), mayBePresentOtherwise: true),
            .init(tag: 0x0040A168, requirement: .type1C, condition: when(["CODE"]), mayBePresentOtherwise: true,
                  itemRules: codes, constraints: [.itemCount(1...1)])
        ]
    }

    /// Protocol Context Sequence content used by scheduled and performed protocol codes.
    public static func protocolCodeItem() -> [DicomAttributeRule] {
        DicomCodeSequenceMacro.standardRules() + [
            .init(tag: 0x00400440, requirement: .type3, itemRules: contentItem() + [
                .init(tag: 0x00400441, requirement: .type3, itemRules: contentItem(), constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...Int.max)])
        ]
    }

    /// Table 10-9 Request Attributes Macro. Whether a procedure was scheduled is external evidence.
    public static func requestAttributes() -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        return [
            .init(tag: 0x00080050, requirement: .type3),
            .init(tag: 0x00080051, requirement: .type3, itemRules: hl7HierarchicDesignator(), constraints: [.itemCount(1...1)]),
            .init(tag: 0x00081110, requirement: .type3, itemRules: sopInstanceReference(), constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x0020000D, requirement: .type3),
            .init(tag: 0x00321060, requirement: .type3),
            .init(tag: 0x00321064, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...1)]),
            .init(tag: 0x00400007, requirement: .type3),
            .init(tag: 0x00400008, requirement: .type3, itemRules: protocolCodeItem(), constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00400009, requirement: .type1C, condition: selfEvidencing(0x00400009)),
            .init(tag: 0x00401001, requirement: .type1C, condition: selfEvidencing(0x00401001)),
            .init(tag: 0x00401002, requirement: .type3),
            .init(tag: 0x0040100A, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...Int.max)])
        ]
    }

    /// Table 10.29-1 UDI Macro.
    public static func udi() -> [DicomAttributeRule] {
        [.init(tag: 0x00181009, requirement: .type1), .init(tag: 0x00500020, requirement: .type3)]
    }

    /// Table 10-20 Attribute Identifier Macro; selector applicability is only evidenced by the selectors present.
    public static func attributeIdentifier() -> [DicomAttributeRule] {
        [0x00720026, 0x00720028, 0x00720052, 0x00720054, 0x00720056].map {
            .init(tag: $0, requirement: .type1C, condition: selfEvidencing($0))
        } + [.init(tag: 0x00741057, requirement: .type1C, condition: .present(0x00720052))]
    }

    /// Table C.7.6.16-12b Real World Value Mapping Macro. The pixel alternatives live at the
    /// root of the instance, so their presence is supplied by the caller.
    public static func realWorldValueMapping(hasPixelData: DicomAttributeRule.Truth,
                                             hasFloatPixelData: DicomAttributeRule.Truth) -> [DicomAttributeRule] {
        let pixel = DicomAttributeRule.Condition.known(hasPixelData)
        let float = DicomAttributeRule.Condition.known(hasFloatPixelData)
        return [
            .init(tag: 0x00283003, requirement: .type1),
            .init(tag: 0x004008EA, requirement: .type1, itemRules: DicomCodeSequenceMacro.standardRules(), constraints: [.itemCount(1...1)]),
            .init(tag: 0x00409210, requirement: .type1),
            .init(tag: 0x00409211, requirement: .type1C, condition: .any([pixel, .present(0x00409212), .not(.present(0x00409213))]),
                  mayBePresentOtherwise: true),
            .init(tag: 0x00409216, requirement: .type1C, condition: .any([pixel, .present(0x00409212), .not(.present(0x00409214))]),
                  mayBePresentOtherwise: true),
            .init(tag: 0x00409213, requirement: .type1C, condition: .not(.present(0x00409211)), mayBePresentOtherwise: true),
            .init(tag: 0x00409214, requirement: .type1C, condition: .not(.present(0x00409216)), mayBePresentOtherwise: true),
            .init(tag: 0x00409212, requirement: .type1C, condition: .not(.present(0x00409224)), mayBePresentOtherwise: true),
            .init(tag: 0x00409224, requirement: .type1C, condition: .any([float, .not(.present(0x00409212))]), mayBePresentOtherwise: true),
            .init(tag: 0x00409225, requirement: .type1C, condition: .any([float, .not(.present(0x00409212))]), mayBePresentOtherwise: true),
            .init(tag: 0x00409220, requirement: .type3, itemRules: contentItem(), constraints: [.itemCount(1...Int.max)])
        ]
    }

    /// Table 10-19 Algorithm Identification Macro.
    public static func algorithmIdentification() -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        return [
            .init(tag: 0x0066002F, requirement: .type1, itemRules: codes, constraints: [.itemCount(1...1)]),
            .init(tag: 0x00660030, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...1)]),
            .init(tag: 0x00660031, requirement: .type1), .init(tag: 0x00660036, requirement: .type1),
            .init(tag: 0x00660032, requirement: .type3), .init(tag: 0x00240202, requirement: .type3)
        ]
    }

    /// Table 10-25 View Code Macro; Slice Progression Direction depends on series order and stays unqualified there.
    public static func viewCode() -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        return [
            .init(tag: 0x00540220, requirement: .type3, itemRules: codes + [
                .init(tag: 0x00540222, requirement: .type3, itemRules: codes, constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...1)])
        ]
    }

    /// Table 10-10 Basic Pixel Spacing Calibration Macro from a stated calibration fact.
    public static func pixelSpacingCalibration(calibratedImage: DicomAttributeRule.Truth) -> [DicomAttributeRule] {
        [
            .init(tag: 0x00280030, requirement: .type1C, condition: .known(calibratedImage), mayBePresentOtherwise: true,
                  constraints: [.valueCount(2...2)]),
            .init(tag: 0x00280A02, requirement: .type3, constraints: [.strings(["GEOMETRY", "FIDUCIAL"])]),
            .init(tag: 0x00280A04, requirement: .type1C, condition: .present(0x00280A02))
        ]
    }

    /// Tables C.36.2.4.12-1 and C.36.2.4.5-2 included by the CT/MR image modules for treatment imaging.
    public static func treatmentImagingRelations() -> [DicomAttributeRule] {
        let content = contentItem()
        return [
            .init(tag: 0x300A0675, requirement: .type1C, condition: .any([.present(0x300A07A1), .present(0x300A07A0)]),
                  mayBePresentOtherwise: true),
            .init(tag: 0x300A07A0, requirement: .type3, itemRules: [
                .init(tag: 0x00289520, requirement: .type1, constraints: [.valueCount(16...16)]),
                .init(tag: 0x300A065B, requirement: .type2, itemRules: content)
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x300A07A1, requirement: .type3, itemRules: [
                .init(tag: 0x3002010F, requirement: .type1, constraints: [.valueCount(16...16)]),
                .init(tag: 0x30020110, requirement: .type2, itemRules: content)
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x300C0002, requirement: .type3, itemRules: sopInstanceReference() + [
                .init(tag: 0x300C0004, requirement: .type3, itemRules: [.init(tag: 0x300C0006, requirement: .type1)],
                      constraints: [.itemCount(1...Int.max)])
            ], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x3002012E, requirement: .type3, constraints: [.strings(["FULL_ARC", "HALF_ARC", "CUSTOM_ARC"])]),
            .init(tag: 0x3002012F, requirement: .type3, constraints: [.strings(["CENTERED", "SHIFTED"])])
        ]
    }

    /// Table 10-15a Patient Orientation Macro. Defined context groups are not verified here.
    public static func patientOrientation() -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        let terminology: [DicomAttributeRule.Constraint] = [.itemCount(1...1), .requiredCondition(.known(.undetermined))]
        return [
            .init(tag: 0x00540410, requirement: .type1, itemRules: codes + [
                .init(tag: 0x00540412, requirement: .type1C, condition: selfEvidencing(0x00540412),
                      itemRules: codes, constraints: [.itemCount(1...Int.max), .requiredCondition(.known(.undetermined))])
            ], constraints: terminology),
            .init(tag: 0x30100030, requirement: .type1, itemRules: codes, constraints: terminology)
        ]
    }
}
