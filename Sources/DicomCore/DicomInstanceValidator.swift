import Foundation

/// Composes existing validators over original Part 10 bytes. Does not infer complete IOD or operation approval.
public enum DicomInstanceValidator {
    /// Structure, VR/VM, modules, functional groups and references have finite whole-object work limits by default.
    /// Trusted outputs can explicitly evaluate every frame (Isis issue #2516); network inputs keep these limits.
    /// The separate codestream budget leaves the frames past it explicitly unevaluated.
    public struct Limits: Sendable {
        public let maximumObjectBytes: Int
        public let maximumObjectFrames: Int
        /// Encoded Pixel Data bytes the per-frame codestream checks read in all.
        public let maximumInputBytes: Int
        /// Frames the per-frame codestream checks read.
        public let maximumFrames: Int
        public let maximumFrameBytes: Int
        public let maximumDiagnostics: Int
        public let parsing: DicomDataSetParseLimits
        /// Budget for the inflated data set of a Deflated Explicit VR Little Endian instance.
        public let maximumInflatedBytes: Int
        public init(maximumInputBytes: Int = 256 * 1024 * 1024, maximumFrames: Int = 1024,
                    maximumFrameBytes: Int = 64 * 1024 * 1024, maximumDiagnostics: Int = 128,
                    parsing: DicomDataSetParseLimits = .default, maximumInflatedBytes: Int = 256 * 1024 * 1024,
                    maximumObjectBytes: Int = 256 * 1024 * 1024, maximumObjectFrames: Int = 1024) {
            self.maximumObjectBytes = max(0, maximumObjectBytes)
            self.maximumObjectFrames = max(0, maximumObjectFrames)
            self.maximumInputBytes = max(0, maximumInputBytes)
            self.maximumFrames = max(0, maximumFrames)
            self.maximumFrameBytes = max(0, maximumFrameBytes)
            self.maximumDiagnostics = max(1, maximumDiagnostics)
            self.parsing = parsing
            self.maximumInflatedBytes = max(0, maximumInflatedBytes)
        }
    }

    /// SOP Classes whose applicable modules are all composed; declared optional content may still
    /// report explicit limitations. Listed in Docs/QA/SCConformanceCoverage.md with their evidence.
    /// The SOP Classes of `DicomQualifiedProfileCatalog`: their modules are composed on native transfer syntaxes and a
    /// valid instance passes every non-operation layer; other SOP Classes keep the global `moduleRuleUnavailable`.
    public static let qualifiedProfiles: Set<String> = Set(DicomQualifiedProfileCatalog.profiles.map(\.sopClassUID))

    /// Targets contain actual metadata keyed by SOP Instance UID; no network fetch or pixel decoding is performed.
    public static func validate(_ data: Data, targets: [String: DicomDataSet] = [:],
                                imageConditions: DicomCompositeImageModules.Conditions = .init(),
                                limits: Limits = .init()) throws -> DicomValidationReport {
        try Task.checkCancellation()
        var state = State(limits: limits)
        guard data.count <= limits.maximumObjectBytes else {
            state.stop()
            return state.report
        }
        let meta: DicomPart10FileMetaParser.FileMeta
        do { meta = try DicomPart10FileMetaParser.parse(data) }
        catch { state.record(.invalidDataSetStructure, layer: .structure); return state.report }
        let base = data.startIndex
        let metaRead = try DicomEncodedDataSetValidator.validate(Data(data[(base + 132)..<(base + meta.dataSetOffset)]),
            limits: limits.parsing, maximumDiagnostics: limits.maximumDiagnostics)
        state.merge(metaRead.report)
        guard !state.stopped, let fileMeta = metaRead.dataSet else { return state.report }
        if let length = fileMeta[0x00020000], length.vr == .UL, length.vm.count == 1 {
            if length.intValue != meta.dataSetOffset - 144 || Data(data[(base + 132)..<(base + 136)]) != Data([2, 0, 0, 0]) {
                state.record(.invalidDataSetStructure, layer: .structure, path: [.tag(0x00020000)])
            }
        } else { state.record(.requiredAttributeMissing, layer: .structure, path: [.tag(0x00020000)]) }
        state.merge(DicomAttributeValidator.validate(fileMeta, rules: [0x00020002, 0x00020003, 0x00020010].map {
            .init(tag: $0, requirement: .type1, constraints: [.valueCount(1...1)])
        }, limits: state.attributeLimits))
        guard !state.stopped, let uid = meta.transferSyntaxUID, let syntax = DicomTransferSyntax(uid: uid) else {
            state.record(.codestreamRuleUnavailable, layer: .codestream, severity: .limitation)
            state.record(.validationInterrupted, layer: .structure, severity: .limitation)
            state.record(.valueUnavailable, layer: .vrAndVM, severity: .limitation)
            state.record(.moduleRuleUnavailable, layer: .attributes, severity: .limitation)
            return state.report
        }
        // PS3.5 A.5: the deflated body inflates to an Explicit VR Little Endian data set, within an explicit budget.
        // Otherwise the body is a slice of the input, so a large object is not copied.
        var body = data[(base + meta.dataSetOffset)...], bodySyntax = syntax
        if syntax.usesDataSetDeflate {
            do {
                body = try DicomDeflatedDataSetCodec.inflate(body,
                    inflatedSizeLimit: min(limits.maximumInflatedBytes, limits.maximumObjectBytes))
                bodySyntax = .explicitVRLittleEndian
            } catch DicomDeflatedDataSetError.dataSetTooLarge {
                state.record(.evaluationLimitReached, layer: .structure, severity: .limitation)
                state.record(.valueUnavailable, layer: .vrAndVM, severity: .limitation)
                state.record(.moduleRuleUnavailable, layer: .attributes, severity: .limitation)
                return state.report
            } catch {
                state.record(.invalidDeflatedDataSet, layer: .structure)
                state.record(.valueUnavailable, layer: .vrAndVM, severity: .limitation)
                state.record(.moduleRuleUnavailable, layer: .attributes, severity: .limitation)
                return state.report
            }
        }
        let parsed = try DicomEncodedDataSetValidator.validate(body, transferSyntax: bodySyntax,
            limits: limits.parsing, maximumDiagnostics: max(1, limits.maximumDiagnostics - state.report.diagnostics.count))
        state.merge(parsed.report)
        guard !state.stopped, let dataSet = parsed.dataSet else {
            state.record(.validationInterrupted, layer: .attributes, severity: .limitation)
            return state.report
        }
        // Bound frame-scaled work before composing modules, including items beyond a false Number of Frames.
        let frames = max(dataSet.int(for: .numberOfFrames) ?? 1,
                         dataSet[0x52009230]?.sequenceItems.count ?? 0)
        guard frames <= limits.maximumObjectFrames else {
            state.stop()
            return state.report
        }
        // Per-frame functional groups make the rule evaluations grow with the frames, so their budget does too.
        state.frameCount = max(1, min(dataSet.int(for: .numberOfFrames) ?? 1, 1_000_000))
        state.merge(DicomSOPCommonModule.validate(dataSet, limits: state.attributeLimits))
        for (tag, value) in [(0x00080016, meta.mediaStorageSOPClassUID), (0x00080018, meta.mediaStorageSOPInstanceUID)] {
            if let declared = dataSet.string(for: tag), let value, declared != value {
                state.record(.referenceIdentityContradiction, layer: .attributes, path: [.tag(tag)])
            }
        }
        guard !state.stopped else { return state.report }
        let sop = dataSet.string(for: 0x00080016)
        // Profiles outside `qualifiedProfiles` still have modules without composition.
        if !qualifiedProfiles.contains(sop ?? "") {
            state.record(.moduleRuleUnavailable, layer: .attributes, path: [.tag(0x00080016)], severity: .limitation)
        }
        let multiframeVariant = sop.flatMap(DicomSCMultiframeModules.Variant.init(rawValue:))
        let enhancedProfile = sop.flatMap(DicomEnhancedImageModules.Profile.init(rawValue:))
        if enhancedProfile?.isVideo == true, !syntax.isVideoTransferSyntax {
            state.record(.codestreamRuleUnavailable, layer: .codestream, path: [.tag(0x7FE00010)], severity: .limitation)
        }
        let imageKind: DicomCompositeImageModules.Kind? = switch sop {
        case "1.2.840.10008.5.1.4.1.1.66.5", "1.2.840.10008.5.1.4.1.1.66.1", "1.2.840.10008.5.1.4.1.1.66.3": nil
        case "1.2.840.10008.5.1.4.1.1.2": .ct
        case "1.2.840.10008.5.1.4.1.1.4": .mr
        case "1.2.840.10008.5.1.4.1.1.7": .secondaryCapture
        case "1.2.840.10008.5.1.4.1.1.1": .cr
        case "1.2.840.10008.5.1.4.1.1.6.1": .ultrasound
        default: enhancedProfile?.kind ?? (multiframeVariant == nil ? nil : .secondaryCaptureMultiframe)
        }
        let hasPixelData: DicomAttributeRule.Truth = parsed.pixelDataHeaders.contains { $0.path == [.tag(0x7FE00010)] }
            ? .satisfied : parsed.pixelDataHeadersTruncated ? .undetermined : .unsatisfied
        // Which root pixel attribute the original bytes carry (Pixel Data, Float or Double Float Pixel Data).
        let pixelKind: DicomEnhancedImageModules.PixelData = parsed.pixelDataHeadersTruncated ? .undetermined
            : hasPixelData == .satisfied ? .integer
            : parsed.pixelDataHeaders.contains { $0.path == [.tag(0x7FE00008)] } ? .float
            : parsed.pixelDataHeaders.contains { $0.path == [.tag(0x7FE00009)] } ? .double : .none
        let hasFloatPixelData: DicomAttributeRule.Truth = pixelKind == .undetermined ? .undetermined
            : pixelKind == .float || pixelKind == .double ? .satisfied : .unsatisfied
        if let imageKind {
            state.merge(DicomPixelPaddingModule.validate(dataSet, hasPixelData: hasPixelData, limits: state.attributeLimits))
            guard !state.stopped else { return state.report }
            state.merge(DicomCompositeImageModules.validate(dataSet, kind: imageKind,
                conditions: imageConditions, limits: state.attributeLimits))
            // Images without declared references have nothing to resolve; the layer is evaluated, not skipped.
            state.merge(.init(evaluatedLayers: [.references]))
            if !state.stopped, DicomCommonInstanceReferenceModule.required(by: dataSet) {
                state.merge(DicomCommonInstanceReferenceModule.validate(dataSet, targets: targets, limits: state.attributeLimits))
            }
            // Enhanced IODs reference images through their functional group macros, not C.12.4.
            if !state.stopped, !imageKind.isEnhanced, DicomGeneralReferenceModule.applies(to: dataSet) {
                state.merge(DicomGeneralReferenceModule.validate(dataSet, targets: targets, limits: state.attributeLimits))
            }
            if !state.stopped, !imageKind.isEnhanced {
                state.merge(DicomGeneralImageModule.validate(dataSet, kind: imageKind,
                    temporallyRelatedSeries: imageConditions.temporallyRelatedSeries, hasPixelData: hasPixelData,
                    hasFloatPixelData: hasFloatPixelData, limits: state.attributeLimits))
            }
            if !state.stopped, imageKind.isSecondaryCapture {
                state.merge(DicomSCImageModule.validate(dataSet, calibratedImage: imageConditions.calibratedImage,
                                                       limits: state.attributeLimits))
            }
            if !state.stopped, imageKind == .cr {
                state.merge(DicomCRModules.validate(dataSet, calibratedImage: imageConditions.calibratedImage, limits: state.attributeLimits))
            }
            if !state.stopped, imageKind == .ultrasound {
                state.merge(DicomUltrasoundModules.validate(dataSet, transferSyntax: syntax, pixelData: pixelKind,
                    conditions: imageConditions, limits: state.attributeLimits))
                if !state.stopped {
                    state.merge(DicomUltrasoundValidation.validate(dataSet, littleEndian: !syntax.isBigEndian,
                        limits: state.attributeLimits))
                }
            }
            if !state.stopped, DicomContrastBolusModule.applies(to: dataSet) {
                state.merge(DicomContrastBolusModule.validate(dataSet, limits: state.attributeLimits))
            }
            if !state.stopped, imageKind == .ct {
                state.merge(DicomSingleFrameCTSeriesModule.validate(dataSet, limits: state.attributeLimits))
            }
            if !state.stopped, imageKind == .ct, DicomMultiEnergyCTModule.applies(to: dataSet) {
                state.merge(DicomMultiEnergyCTModule.validate(dataSet, limits: state.attributeLimits))
            }
            if !state.stopped, let multiframeVariant {
                state.merge(DicomSCMultiframeModules.validate(dataSet, variant: multiframeVariant,
                    encoding: .init(codec: syntax.registryEntry.codec, compression: syntax.registryEntry.compression),
                    limits: state.attributeLimits))
            }
            // Optional modules shared by the classic image IODs evaluate only when declared.
            if !state.stopped { state.merge(DicomGeneralAcquisitionModule.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped { state.merge(DicomClinicalTrialModules.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped {
                state.merge(DicomPatientStudyModule.validate(dataSet, nonHumanPatient: imageConditions.nonHumanPatient,
                                                             limits: state.attributeLimits))
            }
            if !state.stopped { state.merge(DicomSynchronizationModule.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped, enhancedProfile != .vlWholeSlideMicroscopy { state.merge(DicomSpecimenModule.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped { state.merge(DicomEnhancedPatientOrientationModule.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped { state.merge(DicomDeviceModule.validate(dataSet, limits: state.attributeLimits)) }
            // Multi-frame SC, Enhanced, SEG and PM IODs exclude Overlay Plane; their compositions report declared groups.
            if !state.stopped, imageKind != .secondaryCaptureMultiframe, !imageKind.usesFunctionalGroups {
                state.merge(DicomOverlayPlaneModule.validate(dataSet, limits: state.attributeLimits))
            }
            if !state.stopped, enhancedProfile != .vlWholeSlideMicroscopy, imageKind == .secondaryCapture || imageKind == .ultrasound || multiframeVariant == .trueColor || imageKind == .enhancedCT
                || imageKind == .enhancedMR || imageKind == .segmentation || imageKind == .parametricMap {
                state.merge(DicomICCProfileModule.validate(dataSet, limits: state.attributeLimits))
            }
            if !state.stopped, let enhancedProfile {
                state.merge(DicomEnhancedImageModules.validate(dataSet, profile: enhancedProfile, conditions: imageConditions,
                                                                pixelData: pixelKind, limits: state.attributeLimits))
            }
            if !state.stopped, imageKind == .secondaryCapture || imageKind == .cr, DicomModalityLUTModule.applies(to: dataSet) {
                state.merge(DicomModalityLUTModule.validate(dataSet, littleEndian: !syntax.isBigEndian, limits: state.attributeLimits))
            }
            if !state.stopped, !imageKind.usesFunctionalGroups, DicomVOILUTModule.applies(to: dataSet) {
                state.merge(DicomVOILUTModule.validate(dataSet, littleEndian: !syntax.isBigEndian, limits: state.attributeLimits))
            }
            if !state.stopped, DicomImagePlaneModule.applies(to: dataSet, kind: imageKind) {
                state.merge(DicomImagePlaneModule.validate(dataSet, limits: state.attributeLimits))
            }
        }
        guard !state.stopped else { return state.report }
        if sop == "1.2.840.10008.5.1.4.1.1.2" {
            state.merge(DicomCTImageModule.validate(dataSet, rescaleUnitsAreHU: imageConditions.rescaleUnitsAreHU, limits: state.attributeLimits))
        } else if sop == "1.2.840.10008.5.1.4.1.1.4" {
            state.merge(DicomMRImageModule.validate(dataSet, heartGating: imageConditions.cardiacGating, limits: state.attributeLimits))
        } else if let sop, DicomSRSupportMatrix.standard.supportedSOPClassUIDs.contains(sop),
                  let profile = DicomSRProfileConstraints(sopClassUID: sop) {
            let kind = profile.kind
            let schemes = DicomCodeSequenceMacro.versionIndependentSchemes
            state.merge(DicomCompositeImageModules.validate(dataSet, kind: .structuredReport, conditions: imageConditions, limits: state.attributeLimits))
            if !state.stopped { state.merge(DicomClinicalTrialModules.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped {
                state.merge(DicomPatientStudyModule.validate(dataSet, nonHumanPatient: imageConditions.nonHumanPatient, limits: state.attributeLimits))
            }
            if !state.stopped { state.merge(DicomSRSeriesModule.validate(dataSet, kind: kind, limits: state.attributeLimits)) }
            // A.35.2/A.35.3 list Synchronization (U); the KOS IOD does not.
            if !state.stopped, kind == .structuredReport {
                state.merge(DicomSynchronizationModule.validate(dataSet, limits: state.attributeLimits))
            }
            let references = DicomSRReferenceValidator.validate(dataSet, kind: kind, targets: targets, limits: state.attributeLimits)
            state.merge(references.report)
            // Provenance conditions the graph cannot settle come from the stated facts.
            var conditions = references.documentConditions
            if conditions.requestedProcedureApplies == .undetermined { conditions.requestedProcedureApplies = imageConditions.fulfilsRequestedProcedure }
            if conditions.includesOtherDocumentContent == .undetermined { conditions.includesOtherDocumentContent = imageConditions.includesOtherDocumentContent }
            if conditions.identicalDocumentsRequired == .undetermined { conditions.identicalDocumentsRequired = imageConditions.identicalDocumentsStored }
            if conditions.equivalentCDAKnown == .undetermined { conditions.equivalentCDAKnown = imageConditions.equivalentCDADocument }
            if !state.stopped {
                state.merge(DicomSRDocumentModule.validate(dataSet, kind: kind, conditions: conditions, versionRequirements: schemes,
                                                           limits: state.attributeLimits))
            }
            if !state.stopped, !profile.rootTemplateRules().isEmpty {
                state.merge(DicomAttributeValidator.validate(dataSet, rules: profile.rootTemplateRules(), limits: state.attributeLimits))
            }
            var defaults = DicomSRContentItemMacro.Conditions()
            defaults.observationTimeDiffers = imageConditions.observationTimeDiffers
            defaults.identifyingTemplateRequired = profile.rootTemplateIdentifier == nil ? imageConditions.rootTemplateUsed : .satisfied
            defaults.allowedValueTypes = profile.valueTypes
            if !state.stopped {
                state.merge(DicomSRContentValidator.validate(dataSet, versionRequirements: schemes,
                    referenceConditions: references.contentReferenceConditions, defaultContentConditions: defaults,
                    targets: targets, limits: state.attributeLimits))
            }
        } else if let sop, let profile = DicomPresentationStateModules.Profile(rawValue: sop) {
            state.merge(DicomCompositeImageModules.validate(dataSet, kind: .presentationState, conditions: imageConditions, limits: state.attributeLimits))
            if !state.stopped { state.merge(DicomClinicalTrialModules.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped {
                state.merge(DicomPatientStudyModule.validate(dataSet, nonHumanPatient: imageConditions.nonHumanPatient, limits: state.attributeLimits))
            }
            if !state.stopped { state.merge(DicomSpecimenModule.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped {
                state.merge(DicomPresentationStateModules.validate(dataSet, profile: profile, targets: targets, limits: state.attributeLimits))
            }
            // Overlay Plane content, the Modality LUT data and the ICC profile use the classic helpers. The VOI LUT
            // data inside softcopy items depends on the referenced image's pixel context and is not compared here.
            if !state.stopped, profile != .blending { state.merge(DicomOverlayPlaneModule.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped, profile == .grayscale || profile == .pseudoColor, DicomModalityLUTModule.applies(to: dataSet) {
                state.merge(DicomModalityLUTModule.validate(dataSet, littleEndian: !syntax.isBigEndian, limits: state.attributeLimits))
            }
            // The ICC Profile module belongs to the color presentation states only (A.33.2–A.33.4).
            if !state.stopped, profile != .grayscale, DicomICCProfileModule.applies(to: dataSet) {
                state.merge(DicomICCProfileModule.validate(dataSet, limits: state.attributeLimits))
            }
        } else if let profile = enhancedProfile, profile == .spatialRegistration || profile == .deformableSpatialRegistration {
            // The common non-image General Series composition; no pixel or functional-group modules.
            state.merge(DicomCompositeImageModules.validate(dataSet, kind: .waveform,
                conditions: imageConditions, limits: state.attributeLimits))
            if !state.stopped { state.merge(DicomClinicalTrialModules.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped {
                state.merge(DicomPatientStudyModule.validate(dataSet, nonHumanPatient: imageConditions.nonHumanPatient,
                    limits: state.attributeLimits))
            }
            if !state.stopped {
                state.merge(DicomEnhancedImageModules.validate(dataSet, profile: profile,
                    conditions: imageConditions, pixelData: .none, limits: state.attributeLimits))
            }
            if !state.stopped {
                state.merge(DicomCommonInstanceReferenceModule.validate(dataSet, targets: targets, limits: state.attributeLimits))
            }
            if !state.stopped, DicomGeneralReferenceModule.applies(to: dataSet) {
                state.merge(DicomGeneralReferenceModule.validate(dataSet, targets: targets, limits: state.attributeLimits))
            }
        } else if sop == DicomSurfaceSegmentation.storageSOPClassUID {
            state.merge(DicomCompositeImageModules.validate(dataSet, kind: .segmentation,
                conditions: imageConditions, limits: state.attributeLimits))
            if !state.stopped { state.merge(DicomClinicalTrialModules.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped {
                state.merge(DicomPatientStudyModule.validate(dataSet, nonHumanPatient: imageConditions.nonHumanPatient,
                    limits: state.attributeLimits))
            }
            if !state.stopped {
                state.merge(DicomEnhancedImageModules.validate(dataSet, profile: .surfaceSegmentation,
                    conditions: imageConditions, pixelData: pixelKind, limits: state.attributeLimits))
            }
            state.merge(.init(evaluatedLayers: [.references]))
            if !state.stopped, DicomCommonInstanceReferenceModule.required(by: dataSet) {
                state.merge(DicomCommonInstanceReferenceModule.validate(dataSet, targets: targets, limits: state.attributeLimits))
            }
            if !state.stopped, DicomGeneralReferenceModule.applies(to: dataSet) {
                state.merge(DicomGeneralReferenceModule.validate(dataSet, targets: targets, limits: state.attributeLimits))
            }
        } else if let sop, let profile = DicomRTModules.Profile(rawValue: sop) {
            state.merge(DicomCompositeImageModules.validate(dataSet, kind: .radiotherapy, conditions: imageConditions, limits: state.attributeLimits))
            if !state.stopped { state.merge(DicomClinicalTrialModules.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped {
                state.merge(DicomPatientStudyModule.validate(dataSet, nonHumanPatient: imageConditions.nonHumanPatient, limits: state.attributeLimits))
            }
            // A.18: grid-based doses carry General Image, Image Pixel, Image Plane and Multi-frame.
            if !state.stopped, profile == .rtDose, hasPixelData != .unsatisfied {
                state.merge(DicomPixelPaddingModule.validate(dataSet, hasPixelData: hasPixelData, limits: state.attributeLimits))
                if !state.stopped {
                    state.merge(DicomGeneralImageModule.validate(dataSet, kind: .rtDose, temporallyRelatedSeries: imageConditions.temporallyRelatedSeries,
                                                                 hasPixelData: hasPixelData, limits: state.attributeLimits))
                }
                if !state.stopped { state.merge(DicomImagePlaneModule.validate(dataSet, limits: state.attributeLimits)) }
            }
            if !state.stopped {
                state.merge(DicomRTModules.validate(dataSet, profile: profile, pixelData: pixelKind, targets: targets, limits: state.attributeLimits))
            }
            if !state.stopped, profile != .rtDose, DicomGeneralReferenceModule.applies(to: dataSet) {
                state.merge(DicomGeneralReferenceModule.validate(dataSet, targets: targets, limits: state.attributeLimits))
            }
            if !state.stopped, DicomCommonInstanceReferenceModule.applies(to: dataSet) {
                state.merge(DicomCommonInstanceReferenceModule.validate(dataSet, targets: targets, limits: state.attributeLimits))
            }
        } else if let sop, let profile = DicomWaveformModules.Profile(rawValue: sop) {
            state.merge(DicomCompositeImageModules.validate(dataSet, kind: .waveform, conditions: imageConditions, limits: state.attributeLimits))
            if !state.stopped { state.merge(DicomClinicalTrialModules.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped {
                state.merge(DicomPatientStudyModule.validate(dataSet, nonHumanPatient: imageConditions.nonHumanPatient, limits: state.attributeLimits))
            }
            if !state.stopped { state.merge(DicomWaveformModules.validate(dataSet, profile: profile, targets: targets, limits: state.attributeLimits)) }
        } else if let sop, let profile = DicomEncapsulatedDocumentModules.Profile(rawValue: sop) {
            state.merge(DicomCompositeImageModules.validate(dataSet, kind: .encapsulatedDocument, conditions: imageConditions, limits: state.attributeLimits))
            if !state.stopped { state.merge(DicomClinicalTrialModules.validate(dataSet, limits: state.attributeLimits)) }
            if !state.stopped {
                state.merge(DicomPatientStudyModule.validate(dataSet, nonHumanPatient: imageConditions.nonHumanPatient, limits: state.attributeLimits))
            }
            if !state.stopped {
                state.merge(DicomEncapsulatedDocumentModules.validate(dataSet, profile: profile, targets: targets, limits: state.attributeLimits))
            }
            if !state.stopped, DicomICCProfileModule.applies(to: dataSet) {
                state.merge(DicomICCProfileModule.validate(dataSet, limits: state.attributeLimits))
            }
            if !state.stopped, DicomCommonInstanceReferenceModule.applies(to: dataSet) {
                state.merge(DicomCommonInstanceReferenceModule.validate(dataSet, targets: targets, limits: state.attributeLimits))
            }
        } else if imageKind == nil {
            state.record(.referenceRuleUnavailable, layer: .references, severity: .limitation)
        }
        guard !state.stopped else { return state.report }
        if imageKind == nil, parsed.pixelDataHeaders.isEmpty, !parsed.pixelDataHeadersTruncated {
            // Non-image objects carry no pixel data or codestream; both layers hold vacuously.
            state.merge(.init(evaluatedLayers: [.pixelsAndGeometry, .codestream]))
        } else if syntax.registryEntry.isEncapsulated {
            try state.frames(data, metadata: dataSet, syntax: syntax, header: parsed.pixelDataHeaders.first { $0.path == [.tag(0x7FE00010)] })
        } else {
            // The length check reads no sample, so the frame count bounds nothing there.
            let native = DicomNativePixelValidator.validate(parsed, transferSyntax: bodySyntax,
                maximumFrames: .max, maximumFrameBytes: limits.maximumFrameBytes,
                attributeLimits: state.attributeLimits)
            state.merge(native)
            // A clean native pass verified the original Pixel Data VR and length the wire pass left unread.
            // Native syntaxes carry no codestream: that layer holds once the bytes match the metadata.
            if native.diagnostics.isEmpty, !parsed.pixelDataHeadersTruncated {
                state.removeOmittedPixelLimitation()
                state.merge(.init(evaluatedLayers: [.codestream]))
                if multiframeVariant == .grayscaleWord {
                    state.checkUnusedHighBits(body, dataSetOffset: body.startIndex, parsed: parsed, dataSet: dataSet, syntax: bodySyntax)
                }
            }
        }
        if state.report.evaluatedLayers.contains(.operation) {
            state.record(.semanticScopeUnavailable, layer: .operation, severity: .limitation)
        }
        return state.report
    }

    private struct State {
        /// Rule evaluations allowed per frame on top of the attribute validator's default budget.
        static let ruleEvaluationsPerFrame = 1_000

        let limits: Limits
        var report = DicomValidationReport()
        var stopped = false
        var frameCount = 1
        var attributeLimits: DicomAttributeValidator.Limits {
            .init(maximumRuleEvaluations: DicomAttributeValidator.Limits().maximumRuleEvaluations
                    + frameCount * Self.ruleEvaluationsPerFrame,
                  maximumDiagnostics: max(1, limits.maximumDiagnostics - report.diagnostics.count))
        }
        mutating func stop() {
            guard !stopped else { return }
            stopped = true
            report = report.merging(.init(diagnostics: DicomValidationReport.Layer.allCases.map {
                .init(code: .evaluationLimitReached, severity: .limitation, layer: $0)
            }))
        }
        mutating func merge(_ other: DicomValidationReport) {
            guard !stopped else { return }
            report = report.merging(.init(evaluatedLayers: other.evaluatedLayers))
            for diagnostic in other.diagnostics {
                guard report.diagnostics.count < limits.maximumDiagnostics else { stop(); return }
                report = report.merging(.init(diagnostics: [diagnostic]))
            }
        }
        mutating func record(_ code: DicomValidationReport.Code, layer: DicomValidationReport.Layer,
                             path: [DicomValidationReport.PathComponent] = [], severity: DicomValidationReport.Severity = .error) {
            merge(.init(diagnostics: [.init(code: code, severity: severity, layer: layer, path: path)]))
        }
        /// A.8.4.4: grayscale word samples must keep their unused high bits zero.
        mutating func checkUnusedHighBits(_ data: Data, dataSetOffset: Int, parsed: DicomDataSetValidationResult,
                                          dataSet: DicomDataSet, syntax: DicomTransferSyntax) {
            guard !stopped, let header = parsed.pixelDataHeaders.first(where: { $0.path == [.tag(0x7FE00010)] }),
                  let bitsStored = dataSet[0x00280101]?.intValue else { return }
            let start = dataSetOffset + header.valueOffset, end = start + Int(header.valueLength)
            guard start >= data.startIndex, end <= data.endIndex else {
                record(.valueUnavailable, layer: .pixelsAndGeometry, path: [.tag(0x7FE00010)], severity: .limitation); return
            }
            switch DicomSCMultiframeModules.unusedHighBitsAreZero(data[start..<end], bitsStored: bitsStored, littleEndian: !syntax.isBigEndian) {
            case .some(false): record(.pixelMetadataContradiction, layer: .pixelsAndGeometry, path: [.tag(0x7FE00010)])
            case .none: record(.valueUnavailable, layer: .pixelsAndGeometry, path: [.tag(0x7FE00010)], severity: .limitation)
            case .some(true): break
            }
        }
        /// The per-frame budget ran out: the frames past it are declared unevaluated on the pixel and codestream layers,
        /// and the layers already evaluated keep their findings.
        mutating func frameBudgetExhausted(at frame: Int? = nil) {
            let path: [DicomValidationReport.PathComponent] = frame.map { [.tag(0x7FE00010), .frame($0)] } ?? [.tag(0x7FE00010)]
            record(.evaluationLimitReached, layer: .codestream, path: path, severity: .limitation)
            record(.evaluationLimitReached, layer: .pixelsAndGeometry, path: path, severity: .limitation)
        }
        mutating func removeOmittedPixelLimitation() {
            guard !stopped else { return }
            report = .init(evaluatedLayers: report.evaluatedLayers, diagnostics: report.diagnostics.filter {
                !($0.layer == .vrAndVM && $0.code == .valueUnavailable && $0.path == [.tag(0x7FE00010)])
            })
        }
        mutating func frames(_ data: Data, metadata: DicomDataSet, syntax: DicomTransferSyntax, header: DicomPixelDataHeaderEvidence?) throws {
            if syntax.isVideoTransferSyntax {
                do {
                    guard let header, header.vr == .OB, header.valueLength == UInt32.max else {
                        record(.invalidDataSetStructure, layer: .structure, path: [.tag(0x7FE00010)]); return
                    }
                    let decoder = try DCMDecoder(data: data)
                    guard let descriptor = decoder.encapsulatedPixelDataDescriptor, !descriptor.fragments.isEmpty else {
                        record(.invalidDataSetStructure, layer: .structure, path: [.tag(0x7FE00010)]); return
                    }
                    var remaining = limits.maximumFrameBytes
                    for fragment in descriptor.fragments {
                        guard fragment.length <= remaining else { frameBudgetExhausted(); return }
                        remaining -= fragment.length
                    }
                    guard let video = decoder.video(payloadMode: .streamOnly) else {
                        record(.invalidDataSetStructure, layer: .structure, path: [.tag(0x7FE00010)]); return
                    }
                    if !syntax.rawValue.hasSuffix(".1"), descriptor.fragments.count != 1 {
                        record(.pixelMetadataContradiction, layer: .pixelsAndGeometry, path: [.tag(0x7FE00010)])
                    }
                    let description = try DicomVideoStreamInspector.inspect(video.streamData, codec: video.codec)
                    let depth = description.bitDepth ?? 8
                    let maximumDepth = syntax == .hevcH265Main10ProfileLevel51 ? 10 : 8
                    if depth > maximumDepth || description.chromaFormat != 1 {
                        record(.pixelMetadataContradiction, layer: .codestream, path: [.tag(0x00280101)])
                    }
                    if metadata.int(for: 0x00280002) != 3 || metadata.string(for: 0x00280004) != "YBR_PARTIAL_420" ||
                        metadata.int(for: 0x00280006) != 0 || metadata.int(for: 0x00280100) != (depth <= 8 ? 8 : 16) ||
                        metadata.int(for: 0x00280101) != depth || metadata.int(for: 0x00280102) != depth - 1 ||
                        metadata.int(for: 0x00280103) != 0 {
                        record(.pixelMetadataContradiction, layer: .pixelsAndGeometry, path: [.tag(0x00280004)])
                    }
                    if description.accessUnits.count != metadata.int(for: 0x00280008) {
                        record(.pixelMetadataContradiction, layer: .pixelsAndGeometry, path: [.tag(0x00280008)])
                    }
                    if description.width != metadata.int(for: 0x00280011) || description.height != metadata.int(for: 0x00280010) {
                        record(.pixelMetadataContradiction, layer: .pixelsAndGeometry, path: [.tag(0x00280010)])
                    }
                    if metadata.string(for: 0x00282114) != video.codec.lossyCompressionMethod {
                        record(.attributeValueContradiction, layer: .attributes, path: [.tag(0x00282114)])
                    }
                    // PS3.5 §8.2 profile, level and Blu-ray format: warnings only, never a rejection (#2905).
                    for violation in DicomVideoConformance.violations(of: syntax, in: description) {
                        merge(.init(diagnostics: [.init(code: .videoBitstreamConstraintViolation, severity: .warning,
                                                        layer: .codestream, path: [.tag(0x7FE00010)],
                                                        detail: violation.detail)]))
                    }
                    merge(.init(evaluatedLayers: [.codestream, .pixelsAndGeometry]))
                    removeOmittedPixelLimitation()
                } catch is CancellationError { throw CancellationError() }
                catch {
                    record(.invalidDataSetStructure, layer: .codestream, path: [.tag(0x7FE00010)])
                }
                return
            }
            guard [DicomTransferSyntax.rleLossless, .deflatedImageFrameCompression, .jpegBaseline, .jpegExtended, .jpegLossless,
                   .jpegLosslessFirstOrder, .jpegLSLossless, .jpegLSNearLossless].contains(syntax)
                || DicomJ2KFrameValidator.supported.contains(syntax) else {
                record(.codestreamRuleUnavailable, layer: .codestream, path: [.tag(0x7FE00010)], severity: .limitation)
                record(.valueUnavailable, layer: .pixelsAndGeometry, path: [.tag(0x7FE00010)], severity: .limitation)
                return
            }
            guard !report.diagnostics.contains(where: { $0.severity == .error && [.structure, .vrAndVM].contains($0.layer) }) else {
                record(.validationInterrupted, layer: .codestream, severity: .limitation); return
            }
            if let count = metadata[0x00280008] {
                guard count.vr == .IS, count.vm.count == 1, let value = count.intValue, value > 0 else {
                    record(.referenceSelectionInvalid, layer: .pixelsAndGeometry, path: [.tag(0x00280008)])
                    record(.valueUnavailable, layer: .codestream, severity: .limitation); return
                }
            }
            guard metadata.contains(0x7FE00001) == metadata.contains(0x7FE00002) else {
                record(.invalidDataSetStructure, layer: .structure, path: [.tag(0x7FE00001)])
                record(.valueUnavailable, layer: .codestream, severity: .limitation); return
            }
            do {
                let decoder = try DCMDecoder(data: data)
                if DicomJ2KPart2Profile.isPart2(syntax.rawValue) {
                    // PS3.5 8.2.4: every fragment is a component collection whose components are frames (#2331).
                    guard let descriptor = decoder.encapsulatedPixelDataDescriptor, !descriptor.fragments.isEmpty else {
                        record(.invalidDataSetStructure, layer: .structure, path: [.tag(0x7FE00010)])
                        record(.valueUnavailable, layer: .codestream, severity: .limitation); return
                    }
                    guard descriptor.fragments.count <= limits.maximumFrames else { frameBudgetExhausted(); return }
                    let bytes = decoder.dicomDataSnapshot()
                    var components = 0
                    for (index, fragment) in descriptor.fragments.enumerated() {
                        try Task.checkCancellation()
                        guard !stopped else { return }
                        guard fragment.valueRange.lowerBound >= 0, fragment.valueRange.upperBound <= bytes.count else {
                            record(.invalidDataSetStructure, layer: .structure, path: [.tag(0x7FE00010), .frame(index)]); return
                        }
                        guard fragment.length <= limits.maximumFrameBytes else { frameBudgetExhausted(at: index); return }
                        let collection = bytes.subdata(in: fragment.valueRange)
                        merge(DicomJ2KFrameValidator.validate(metadata, frame: collection, transferSyntax: syntax, frameIndex: index,
                            maximumEncodedBytes: limits.maximumFrameBytes, attributeLimits: attributeLimits))
                        components += (try? DicomJ2KCodestreamInspector.inspect(collection).components.count) ?? 0
                        guard components <= limits.maximumFrames else { frameBudgetExhausted(at: index); return }
                    }
                    let declared = metadata[0x00280008]?.intValue ?? 1
                    if components != declared {
                        record(.pixelMetadataContradiction, layer: .pixelsAndGeometry, path: [.tag(0x00280008)])
                    }
                    if !stopped, let header, header.vr == .OB, header.valueLength == UInt32.max { removeOmittedPixelLimitation() }
                    return
                }
                let reader = try decoder.makeEncapsulatedPixelFrameReader()
                try reader.validateDeclaredFrameCount()
                guard !reader.diagnostics.contains(where: { $0.severity == .error }) else {
                    record(.invalidDataSetStructure, layer: .structure, path: [.tag(0x7FE00010)])
                    record(.valueUnavailable, layer: .codestream, severity: .limitation); return
                }
                // Frames are checked within the frame and byte budgets; the rest are declared unevaluated.
                var budget = limits.maximumInputBytes
                for index in 0..<reader.frameCount {
                    try Task.checkCancellation()
                    guard !stopped else { return }
                    guard report.diagnostics.count < limits.maximumDiagnostics else { stop(); return }
                    guard index < limits.maximumFrames else { frameBudgetExhausted(at: index); break }
                    // Sum original fragment lengths before the frame reader allocates its assembled buffer.
                    let indexes = reader.descriptor.frameFragmentIndexes[index]
                    if syntax == .deflatedImageFrameCompression, indexes.count != 1 {
                        record(.invalidDataSetStructure, layer: .structure, path: [.tag(DicomTag.pixelData.rawValue), .frame(index)])
                        continue
                    }
                    var remaining = limits.maximumFrameBytes
                    var exhausted = false
                    for fragment in indexes {
                        let size = reader.descriptor.fragments[fragment].length
                        guard size <= remaining, size <= budget else { exhausted = true; break }
                        remaining -= size
                        budget -= size
                    }
                    guard !exhausted else { frameBudgetExhausted(at: index); break }
                    let frame = try reader.frameData(at: index)
                    if let lengths = reader.descriptor.extendedOffsetTable?.lengths, lengths.indices.contains(index) {
                        let length = lengths[index], actual = UInt64(frame.count)
                        let padded = !length.isMultiple(of: 2) && length < actual && actual - length == 1 && frame.last == 0
                        if indexes.count != 1 {
                            record(.invalidDataSetStructure, layer: .structure, path: [.tag(0x7FE00001), .frame(index)])
                        }
                        if length != actual && !padded {
                            record(.pixelDataLengthMismatch, layer: .structure, path: [.tag(0x7FE00002), .frame(index)])
                        }
                    }
                    guard !stopped else { return }
                    if syntax == .rleLossless {
                        merge(DicomRLEFrameValidator.validate(metadata, frame: frame, frameIndex: index,
                            limits: .init(maximumEncodedBytes: limits.maximumFrameBytes), attributeLimits: attributeLimits))
                    } else if syntax == .deflatedImageFrameCompression {
                        merge(DicomDeflatedFrameValidator.validate(metadata, frame: frame, frameIndex: index,
                            maximumEncodedBytes: limits.maximumFrameBytes, attributeLimits: attributeLimits))
                    } else if syntax == .jpegLSLossless || syntax == .jpegLSNearLossless {
                        merge(DicomJPEGLSFrameValidator.validate(metadata, frame: frame, transferSyntax: syntax, frameIndex: index,
                            maximumEncodedBytes: limits.maximumFrameBytes, attributeLimits: attributeLimits))
                    } else if DicomJ2KFrameValidator.supported.contains(syntax) {
                        merge(DicomJ2KFrameValidator.validate(metadata, frame: frame, transferSyntax: syntax, frameIndex: index,
                            maximumEncodedBytes: limits.maximumFrameBytes, attributeLimits: attributeLimits))
                    } else {
                        merge(DicomJPEGFrameValidator.validate(metadata, frame: frame, transferSyntax: syntax, frameIndex: index,
                            maximumEncodedBytes: limits.maximumFrameBytes, attributeLimits: attributeLimits))
                    }
                }
                // The encapsulated Pixel Data carried VR OB with undefined length and every fragment was read and framed:
                // the wire pass's omission of the value no longer applies.
                let framedEverything = !report.diagnostics.contains { $0.code == .evaluationLimitReached && $0.layer == .codestream }
                if !stopped, framedEverything, let header, header.vr == .OB, header.valueLength == UInt32.max {
                    removeOmittedPixelLimitation()
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                record(.invalidDataSetStructure, layer: .structure, path: [.tag(0x7FE00010)])
                record(.valueUnavailable, layer: .codestream, severity: .limitation)
            }
        }
    }
}
