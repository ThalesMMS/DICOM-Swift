import Foundation

/// Common Patient/Study/Series requirements for classic CT, MR and SC, plus their
/// mandatory equipment and Frame of Reference attributes. This is not a complete IOD schema.
public enum DicomCompositeImageModules {
    public enum Kind: Sendable {
        case ct, mr, cr, ultrasound, secondaryCapture, secondaryCaptureMultiframe
        /// SR/KOS documents: Patient, General Study and General Equipment without the image series rules.
        case structuredReport
        /// Enhanced CT, MR and XA multi-frame images (PS3.3 A.38, A.36, A.47).
        case enhancedCT, enhancedMR, enhancedXA
        /// Segmentation and Parametric Map multi-frame objects (PS3.3 A.51, A.75): General Image with
        /// functional groups, no root VOI/Modality LUT or Overlay Plane.
        case segmentation, parametricMap
        /// Softcopy Presentation States (PS3.3 A.33): General Series with Modality PR, no image modules.
        case presentationState
        /// RT Dose, Structure Set and Plan (PS3.3 A.18–A.20): RT Series replaces General Series; `rtDose`
        /// additionally composes General Image and Image Plane for grid-based doses.
        case radiotherapy, rtDose
        /// Waveforms (A.34): General Series with the IOD's modality, no image modules. Encapsulated documents
        /// (A.45): Encapsulated Document Series replaces General Series.
        case waveform, encapsulatedDocument

        public var isEnhanced: Bool { self == .enhancedCT || self == .enhancedMR || self == .enhancedXA }
        /// IODs whose frames are described by Multi-frame Functional Groups rather than root image modules.
        public var usesFunctionalGroups: Bool { isEnhanced || self == .segmentation || self == .parametricMap }
        /// C.7.3.1: Patient Position is Type 2C for CT and MR images.
        var requiresPatientPosition: Bool { [.ct, .mr, .enhancedCT, .enhancedMR].contains(self) }

        /// Single- and multi-frame Secondary Capture share the SC Equipment, orientation and
        /// Frame of Reference conventions of A.8.
        public var isSecondaryCapture: Bool { self == .secondaryCapture || self == .secondaryCaptureMultiframe }
    }

    /// Facts about the subject and series cannot be inferred from absent instance attributes.
    public struct Conditions: Sendable {
        public let nonHumanPatient: DicomAttributeRule.Truth
        public let nonBipedalAnatomy: DicomAttributeRule.Truth
        public let pairedBodyPart: DicomAttributeRule.Truth
        public let temporallyRelatedSeries: DicomAttributeRule.Truth
        public let calibratedImage: DicomAttributeRule.Truth
        /// CT derived images without Rescale Type: whether the output units are Hounsfield.
        public let rescaleUnitsAreHU: DicomAttributeRule.Truth
        /// MR images whose Scan Options do not settle cardiac gating.
        public let cardiacGating: DicomAttributeRule.Truth
        /// SR/KOS provenance facts that the instance cannot evidence on its own (C.17.2, C.17.3).
        public let fulfilsRequestedProcedure: DicomAttributeRule.Truth
        public let includesOtherDocumentContent: DicomAttributeRule.Truth
        public let identicalDocumentsStored: DicomAttributeRule.Truth
        public let equivalentCDADocument: DicomAttributeRule.Truth
        public let observationTimeDiffers: DicomAttributeRule.Truth
        public let rootTemplateUsed: DicomAttributeRule.Truth
        /// Enhanced MR capability and regulatory facts (C.8.13.5.2) the instance cannot evidence.
        public let sarCapable: DicomAttributeRule.Truth
        public let gradientOutputCapable: DicomAttributeRule.Truth
        public let operatingModeRegulated: DicomAttributeRule.Truth
        /// Ultrasound acquisition facts not established by absent attributes (A.6, C.8.5.6).
        public let ultrasoundStagedProtocol: DicomAttributeRule.Truth
        public let contrastMediaUsed: DicomAttributeRule.Truth
        /// Image Pixel: whether the displayed pixels have a non-unit aspect ratio when no spacing is supplied.
        public let nonSquarePixels: DicomAttributeRule.Truth
        /// Video IOD module applicability cannot be inferred from missing module attributes (A.32.5-7).
        public let imagingSubjectIsSpecimen: DicomAttributeRule.Truth
        public let frameLevelRetrieveResponse: DicomAttributeRule.Truth

        public init(nonHumanPatient: DicomAttributeRule.Truth = .undetermined,
                    nonBipedalAnatomy: DicomAttributeRule.Truth = .undetermined,
                    pairedBodyPart: DicomAttributeRule.Truth = .undetermined,
                    temporallyRelatedSeries: DicomAttributeRule.Truth = .undetermined,
                    calibratedImage: DicomAttributeRule.Truth = .undetermined,
                    rescaleUnitsAreHU: DicomAttributeRule.Truth = .undetermined,
                    cardiacGating: DicomAttributeRule.Truth = .undetermined,
                    fulfilsRequestedProcedure: DicomAttributeRule.Truth = .undetermined,
                    includesOtherDocumentContent: DicomAttributeRule.Truth = .undetermined,
                    identicalDocumentsStored: DicomAttributeRule.Truth = .undetermined,
                    equivalentCDADocument: DicomAttributeRule.Truth = .undetermined,
                    observationTimeDiffers: DicomAttributeRule.Truth = .undetermined,
                    rootTemplateUsed: DicomAttributeRule.Truth = .undetermined,
                    sarCapable: DicomAttributeRule.Truth = .undetermined,
                    gradientOutputCapable: DicomAttributeRule.Truth = .undetermined,
                    operatingModeRegulated: DicomAttributeRule.Truth = .undetermined,
                    ultrasoundStagedProtocol: DicomAttributeRule.Truth = .undetermined,
                    contrastMediaUsed: DicomAttributeRule.Truth = .undetermined,
                    nonSquarePixels: DicomAttributeRule.Truth = .undetermined,
                    imagingSubjectIsSpecimen: DicomAttributeRule.Truth = .undetermined,
                    frameLevelRetrieveResponse: DicomAttributeRule.Truth = .undetermined) {
            self.nonHumanPatient = nonHumanPatient
            self.nonBipedalAnatomy = nonBipedalAnatomy
            self.pairedBodyPart = pairedBodyPart
            self.temporallyRelatedSeries = temporallyRelatedSeries
            self.calibratedImage = calibratedImage
            self.rescaleUnitsAreHU = rescaleUnitsAreHU
            self.cardiacGating = cardiacGating
            self.fulfilsRequestedProcedure = fulfilsRequestedProcedure
            self.includesOtherDocumentContent = includesOtherDocumentContent
            self.identicalDocumentsStored = identicalDocumentsStored
            self.equivalentCDADocument = equivalentCDADocument
            self.observationTimeDiffers = observationTimeDiffers
            self.rootTemplateUsed = rootTemplateUsed
            self.sarCapable = sarCapable
            self.gradientOutputCapable = gradientOutputCapable
            self.operatingModeRegulated = operatingModeRegulated
            self.ultrasoundStagedProtocol = ultrasoundStagedProtocol
            self.contrastMediaUsed = contrastMediaUsed
            self.nonSquarePixels = nonSquarePixels
            self.imagingSubjectIsSpecimen = imagingSubjectIsSpecimen
            self.frameLevelRetrieveResponse = frameLevelRetrieveResponse
        }
    }

    public static func rules(for dataSet: DicomDataSet, kind: Kind,
                             conditions: Conditions = .init()) -> [DicomAttributeRule] {
        let animal = DicomAttributeRule.Condition.known(conditions.nonHumanPatient)
        let deidentified = DicomAttributeRule.Condition.all([
            .present(0x00120062), .stringEquals(0x00120062, "YES")
        ])
        let codes = DicomCodeSequenceMacro.standardRules()
        var rules: [DicomAttributeRule] = [
            // C.7.1.1 Patient. Type 2 explicitly permits anonymous empty values.
            .init(tag: 0x00100010, requirement: .type2),
            .init(tag: 0x00100020, requirement: .type2),
            .init(tag: 0x00100030, requirement: .type2),
            .init(tag: 0x00100040, requirement: .type2, constraints: [.strings(["M", "F", "O"])]),
            .init(tag: 0x00100035, requirement: .type1C,
                  condition: .any([.present(0x00100033), .present(0x00100034)])),
            .init(tag: 0x00100200, requirement: .type3, constraints: [.strings(["YES", "NO"])]),
            .init(tag: 0x00102201, requirement: .type1C,
                  condition: .all([animal, .not(.present(0x00102202))]), mayBePresentOtherwise: true),
            .init(tag: 0x00102202, requirement: .type1C,
                  condition: .all([animal, .not(.present(0x00102201))]), mayBePresentOtherwise: true,
                  itemRules: codes, constraints: [.itemCount(1...1)]),
            .init(tag: 0x00102292, requirement: .type2C,
                  condition: .all([animal, .known(emptyBreed(in: dataSet))]), mayBePresentOtherwise: true),
            .init(tag: 0x00102293, requirement: .type2C, condition: animal, itemRules: codes),
            .init(tag: 0x00102294, requirement: .type2C, condition: animal, itemRules: [
                .init(tag: 0x00102295, requirement: .type1),
                .init(tag: 0x00102296, requirement: .type1, itemRules: codes, constraints: [.itemCount(1...1)])
            ]),
            .init(tag: 0x00102297, requirement: .type2C, condition: animal, mayBePresentOtherwise: true),
            .init(tag: 0x00102298, requirement: .type1C, condition: .known(responsiblePersonHasValue(in: dataSet))),
            .init(tag: 0x00102299, requirement: .type2C, condition: animal, mayBePresentOtherwise: true),
            .init(tag: 0x00120062, requirement: .type3, constraints: [.strings(["YES", "NO"])]),
            .init(tag: 0x00120063, requirement: .type1C,
                  condition: .all([deidentified, .not(.present(0x00120064))]), mayBePresentOtherwise: true),
            .init(tag: 0x00120064, requirement: .type1C,
                  condition: .all([deidentified, .not(.present(0x00120063))]), mayBePresentOtherwise: true,
                  itemRules: codes, constraints: [.itemCount(1...Int.max)]),
            // C.7.2.1 General Study.
            .init(tag: 0x0020000D, requirement: .type1),
            .init(tag: 0x00080020, requirement: .type2),
            .init(tag: 0x00080030, requirement: .type2),
            .init(tag: 0x00080090, requirement: .type2),
            .init(tag: 0x00200010, requirement: .type2),
            .init(tag: 0x00080050, requirement: .type2),
            // C.7.3.1 General Series; SC Equipment overrides Modality to Type 3.
            .init(tag: 0x00080060, requirement: kind.isSecondaryCapture ? .type3 : .type1),
            .init(tag: 0x0020000E, requirement: .type1),
            .init(tag: 0x00200011, requirement: .type2),
            .init(tag: 0x00200060, requirement: .type2C,
                  condition: .all([.known(conditions.pairedBodyPart), .not(.present(0x00200062))]),
                  mayBePresentOtherwise: true,
                  constraints: [.strings(["R", "L"]), .requiredCondition(.known(lateralityAgreement(in: dataSet)))]),
            .init(tag: 0x00200062, requirement: .type3, constraints: [.strings(["R", "L", "B", "U"])]),
            .init(tag: 0x00102210, requirement: .type1C,
                  condition: .all([animal, .known(conditions.nonBipedalAnatomy)]), mayBePresentOtherwise: true,
                  constraints: [.strings(["BIPED", "QUADRUPED"])]),
            .init(tag: 0x00185100, requirement: .type2C,
                  condition: .all([.known(kind.requiresPatientPosition ? .satisfied : .unsatisfied),
                                   .not(.present(0x00540410))]), mayBePresentOtherwise: true,
                  constraints: [.forbiddenWhen(.present(0x00540410))])
        ]
        rules.append(.init(tag: 0x00080096, requirement: .type3, itemRules: DicomPersonIdentificationMacro.rules(),
                           constraints: [.itemCount(1...1)]))
        for (sequence, names) in [(0x0008009D, 0x0008009C), (0x00081049, 0x00081048),
            (0x00081062, 0x00081060), (0x00081052, 0x00081050), (0x00081072, 0x00081070)] {
            rules.append(.init(tag: sequence, requirement: .type3, itemRules: DicomPersonIdentificationMacro.rules(),
                               constraints: [.itemCount(1...Int.max), .personIdentificationNames(names, whenMultipleItems: true)]))
        }
        if kind.isSecondaryCapture {
            // C.8.6.1 Conversion Type is a Defined Term, not a closed enumeration.
            rules.append(.init(tag: 0x00080064, requirement: .type1))
            // General Equipment is optional for SC, but its Type 2 Manufacturer
            // is required once that module is supplied. A padding range also requires it.
            let equipmentTags = [0x00080070, 0x00080080, 0x00080081, 0x00081010, 0x00081040, 0x00081041, 0x00081090,
                0x0018100B, 0x00181000, 0x00181020, 0x00181008, 0x0018100A, 0x00181002, 0x00181050,
                0x00181204, 0x00181205, 0x00181200, 0x00181201, 0x00280120, 0x00280121]
            if equipmentTags.contains(where: dataSet.contains) {
                rules.append(.init(tag: 0x00080070, requirement: .type2))
            }
        } else {
            rules.append(.init(tag: 0x00080070, requirement: .type2))
        }
        // A.8.1.3 makes this module conditional for SC. A present optional module
        // must also include both of its required attributes (C.7.4.1).
        // A.8.1.3 makes Frame of Reference conditional for SC; the multi-frame SC IODs also require it
        // when Pixel Measures or Plane Position/Orientation (Patient) functional groups are present.
        // A.75: Frame of Reference is mandatory for Parametric Maps.
        if kind.requiresPatientPosition || kind == .parametricMap
            || [0x00200032, 0x00200037, 0x00200052, 0x00201040].contains(where: dataSet.contains)
            || (kind == .secondaryCaptureMultiframe && functionalGroupsDeclareGeometry(in: dataSet)) {
            rules += [.init(tag: 0x00200052, requirement: .type1), .init(tag: 0x00201040, requirement: .type2)]
        }
        var composed = rules + includedMacroRules()
        if kind == .structuredReport || kind == .radiotherapy || kind == .rtDose || kind == .encapsulatedDocument {
            // SR/KOS series attributes belong to C.17.1/C.17.6.1 (DicomSRSeriesModule); RT objects use RT Series (C.8.8.1).
            let seriesTags: Set<Int> = [0x00080060, 0x0020000E, 0x00200011, 0x00200060, 0x00200062, 0x00102210, 0x00185100,
                                        0x00081111, 0x0008103F]
            composed.removeAll { seriesTags.contains($0.tag) }
        }
        return composed
    }

    public static func validate(_ dataSet: DicomDataSet, kind: Kind, conditions: Conditions = .init(),
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        DicomAttributeValidator.validate(dataSet, rules: rules(for: dataSet, kind: kind, conditions: conditions), limits: limits)
    }

    /// Identification, reference and code macros included by Patient, General Study, General Series
    /// and General Equipment (Tables 10-3b, 10-9, 10-11, 10-16, 10-17, 10-18, 10.29-1 and C.7.1.4-1).
    private static func includedMacroRules() -> [DicomAttributeRule] {
        let codes = DicomCodeSequenceMacro.standardRules()
        let sop = DicomCommonMacros.sopInstanceReference()
        let issuer = DicomCommonMacros.hl7HierarchicDesignator()
        let patientID = DicomCommonMacros.issuerOfPatientID()
        func codeSequence(_ tag: Int, single: Bool = false) -> DicomAttributeRule {
            .init(tag: tag, requirement: .type3, itemRules: codes, constraints: [.itemCount(single ? 1...1 : 1...Int.max)])
        }
        return patientID + [
            .init(tag: 0x00100026, requirement: .type3, itemRules: [.init(tag: 0x00100020, requirement: .type1)] + patientID,
                  constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00100027, requirement: .type3, itemRules: [.init(tag: 0x00100020, requirement: .type1),
                .init(tag: 0x00100028, requirement: .type3), .init(tag: 0x00185100, requirement: .type3)] + patientID,
                  constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00101002, requirement: .type3, itemRules: [.init(tag: 0x00100020, requirement: .type1),
                .init(tag: 0x00100022, requirement: .type1)] + patientID, constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00101100, requirement: .type3, itemRules: DicomCommonMacros.referencedPatientPhoto(),
                  constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00100216, requirement: .type3, itemRules: [.init(tag: 0x00100214, requirement: .type1),
                .init(tag: 0x00100215, requirement: .type1, itemRules: codes, constraints: [.itemCount(1...1)]),
                .init(tag: 0x00100217, requirement: .type1)], constraints: [.itemCount(1...Int.max)]),
            codeSequence(0x00100219), codeSequence(0x00102161),
            .init(tag: 0x00100221, requirement: .type3, itemRules: [.init(tag: 0x00100222, requirement: .type1),
                .init(tag: 0x00100223, requirement: .type1), codeSequence(0x00100229)], constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00081120, requirement: .type3, itemRules: sop, constraints: [.itemCount(1...1)]),
            .init(tag: 0x00080051, requirement: .type3, itemRules: issuer, constraints: [.itemCount(1...1)]),
            codeSequence(0x00081032),
            .init(tag: 0x00081110, requirement: .type3, itemRules: sop, constraints: [.itemCount(1...Int.max)]),
            codeSequence(0x00321034, single: true), codeSequence(0x00401012),
            codeSequence(0x0008103F, single: true),
            .init(tag: 0x00081111, requirement: .type3, itemRules: sop, constraints: [.itemCount(1...1)]),
            .init(tag: 0x00081250, requirement: .type3, itemRules: [.init(tag: 0x0020000D, requirement: .type1),
                .init(tag: 0x0020000E, requirement: .type1), .init(tag: 0x0040A170, requirement: .type2, itemRules: codes)],
                  constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00400275, requirement: .type3, itemRules: DicomCommonMacros.requestAttributes(),
                  constraints: [.itemCount(1...Int.max)]),
            .init(tag: 0x00400260, requirement: .type3, itemRules: DicomCommonMacros.protocolCodeItem(),
                  constraints: [.itemCount(1...Int.max)]),
            codeSequence(0x00081041, single: true),
            .init(tag: 0x0018100A, requirement: .type3, itemRules: DicomCommonMacros.udi(), constraints: [.itemCount(1...Int.max)])
        ]
    }

    private static func functionalGroupsDeclareGeometry(in dataSet: DicomDataSet) -> Bool {
        [0x52009229, 0x52009230].contains { tag in
            (dataSet[tag]?.sequenceItems ?? []).contains { item in
                [0x00289110, 0x00209113, 0x00209116].contains(where: item.dataSet.contains)
            }
        }
    }

    private static func emptyBreed(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let element = dataSet[0x00102293] else { return .undetermined }
        guard element.vr == .SQ else { return .undetermined }
        if case .empty = element.value { return .satisfied }
        guard case .sequence(let items) = element.value else { return .undetermined }
        return items.isEmpty ? .satisfied : .unsatisfied
    }

    private static func lateralityAgreement(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let series = dataSet[0x00200060], let image = dataSet[0x00200062] else { return .satisfied }
        var values: [String] = []
        for element in [series, image] {
            guard element.vr == .CS else { return .undetermined }
            if case .empty = element.value { return .satisfied }
            guard case .strings(let strings) = element.value, strings.count == 1,
                  strings[0].utf8.count <= 16 else { return .undetermined }
            let value = strings[0].trimmingCharacters(in: CharacterSet(charactersIn: " "))
            if value.isEmpty { return .satisfied }
            values.append(value)
        }
        return values[0] == values[1] ? .satisfied : .unsatisfied
    }

    private static func responsiblePersonHasValue(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let element = dataSet[0x00102297] else { return .unsatisfied }
        guard element.vr == .PN else { return .undetermined }
        if case .empty = element.value { return .unsatisfied }
        guard case .strings(let values) = element.value, values.count <= 1,
              values.allSatisfy({ $0.utf8.count <= 1024 }) else { return .undetermined }
        return values.allSatisfy { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ^=")).isEmpty } ? .unsatisfied : .satisfied
    }
}
