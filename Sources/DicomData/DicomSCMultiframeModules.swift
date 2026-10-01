import Foundation

/// Modules specific to the four multi-frame Secondary Capture IODs (PS3.3 A.8.2–A.8.5):
/// Multi-frame, SC Multi-frame Image and Vector, Cine, Frame Pointers, Frame Extraction,
/// the root attributes of Multi-frame Functional Groups and Dimension, and the IOD content
/// constraints on pixel description, rescale and forbidden modules. Functional group macro
/// content is not composed here.
public enum DicomSCMultiframeModules {
    public enum Variant: String, Sendable, CaseIterable {
        case singleBit = "1.2.840.10008.5.1.4.1.1.7.1"
        case grayscaleByte = "1.2.840.10008.5.1.4.1.1.7.2"
        case grayscaleWord = "1.2.840.10008.5.1.4.1.1.7.3"
        case trueColor = "1.2.840.10008.5.1.4.1.1.7.4"

        public var sopClassUID: String { rawValue }
    }

    /// Transfer syntax facts that A.8.5.4 ties to the True Color photometric interpretation.
    public struct Encoding: Sendable {
        public let codec: DicomTransferSyntaxCodec
        public let compression: DicomTransferSyntaxCompression

        public init(codec: DicomTransferSyntaxCodec, compression: DicomTransferSyntaxCompression) {
            self.codec = codec
            self.compression = compression
        }

        /// A.8.5.4 photometric interpretations; nil when the syntax family is not listed there.
        var trueColorPhotometricInterpretations: Set<String>? {
            switch codec {
            case .native, .deflate, .deflatedFrames, .jpegLossless: return ["RGB"]
            case .rle: return ["RGB", "YBR_FULL"]
            case .jpegBaseline, .jpegExtended: return ["YBR_FULL_422"]
            case .jpeg2000, .jpeg2000Part2, .htj2k: return compression.isLossy ? ["YBR_ICT"] : ["YBR_RCT"]
            case .mpeg2, .h264, .hevc: return ["YBR_PARTIAL_420"]
            case .jpegLS: return compression.isLossy ? nil : ["RGB"]
            case .jpip, .jpegXL: return nil
            }
        }
    }

    static let vectorTags = [0x00181065, 0x00182001, 0x00182002, 0x00182003, 0x00182004, 0x00182005, 0x00182006]

    public static func validate(_ dataSet: DicomDataSet, variant: Variant, encoding: Encoding?,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let frames = frameCount(in: dataSet)
        let pointers = framePointers(in: dataSet)
        func pointed(_ tag: Int) -> DicomAttributeRule.Condition {
            .known(pointers.map { $0.contains(tag) ? .satisfied : .unsatisfied } ?? .undetermined)
        }
        let frameVector: [DicomAttributeRule.Constraint] = frames.map { [.valueCount($0...$0)] } ?? []
        let grayscaleWord = DicomAttributeRule.Condition.all([.stringEquals(0x00280004, "MONOCHROME2"), .integerGreaterThan(0x00280101, 1)])
        var rules: [DicomAttributeRule] = [
            // C.7.6.6 Multi-frame and C.8.6.3 SC Multi-frame Image.
            .init(tag: 0x00280008, requirement: .type1, constraints: [.valueCount(1...1), .integerRange(1...Int.max)]),
            .init(tag: 0x00280009, requirement: .type1, constraints: [.valueCount(1...Int.max), .requiredCondition(.known(pointersResolve(in: dataSet)))]),
            .init(tag: 0x00220028, requirement: .type3, constraints: [.strings(["YES", "NO"])]),
            .init(tag: 0x00280301, requirement: .type1, constraints: [.valueCount(1...1), .strings(["YES", "NO"])]),
            .init(tag: 0x00280302, requirement: .type3, constraints: [.strings(["YES", "NO"])]),
            .init(tag: 0x20500020, requirement: .type1C, condition: grayscaleWord, mayBePresentOtherwise: true, constraints: [.strings(["IDENTITY"])]),
            .init(tag: 0x00281052, requirement: .type1C, condition: grayscaleWord, mayBePresentOtherwise: true,
                  constraints: variant == .grayscaleByte ? [.requiredCondition(.known(decimal(dataSet[0x00281052], equals: 0)))] : []),
            .init(tag: 0x00281053, requirement: .type1C, condition: grayscaleWord, mayBePresentOtherwise: true,
                  constraints: variant == .grayscaleByte ? [.requiredCondition(.known(decimal(dataSet[0x00281053], equals: 1)))] : []),
            .init(tag: 0x00281054, requirement: .type1C, condition: grayscaleWord, mayBePresentOtherwise: true,
                  constraints: variant == .grayscaleByte ? [.strings(["US"])] : []),
            .init(tag: 0x00182010, requirement: .type1C, condition: .stringEquals(0x00080064, "DF"), mayBePresentOtherwise: true),
            .init(tag: 0x00182020, requirement: .type3, constraints: [.strings(["ROW", "COLUMN"])]),
            // C.7.6.5 Cine; audio multiplexing is only possible in the MPEG/H.26x families.
            .init(tag: 0x00181063, requirement: .type1C, condition: pointed(0x00181063), mayBePresentOtherwise: true, constraints: [.valueCount(1...1)]),
            .init(tag: 0x00181244, requirement: .type3, constraints: [.integers([0, 1])]),
            .init(tag: 0x003A0300, requirement: .type2C,
                  condition: .known([.mpeg2, .h264, .hevc].contains(encoding?.codec) ? .undetermined : .unsatisfied),
                  itemRules: [.init(tag: 0x003A0208, requirement: .type1), .init(tag: 0x003A0302, requirement: .type1),
                              .init(tag: 0x003A0301, requirement: .type1, itemRules: DicomCodeSequenceMacro.standardRules(),
                                    constraints: [.itemCount(1...1)])]),
            // C.7.6.9 Frame Pointers: frame numbers start at 1; descriptions/types match the FOI count.
            .init(tag: 0x00286010, requirement: .type3, constraints: [.valueCount(1...1), .integerRange(1...(frames ?? Int.max))]),
            .init(tag: 0x00286020, requirement: .type3, constraints: [.integerRange(1...(frames ?? Int.max))]),
            .init(tag: 0x00286022, requirement: .type3, constraints: [.requiredCondition(.known(matchesFramesOfInterest(dataSet, tag: 0x00286022)))]),
            .init(tag: 0x00286023, requirement: .type3, constraints: [.requiredCondition(.known(matchesFramesOfInterest(dataSet, tag: 0x00286023)))])
        ]
        // C.8.6.4 vectors are required exactly when the Frame Increment Pointer names them.
        rules += vectorTags.map {
            .init(tag: $0, requirement: .type1C, condition: pointed($0), mayBePresentOtherwise: true, constraints: frameVector)
        }
        rules += contentConstraints(variant: variant, encoding: encoding)
        if dataSet.contains(0x00081164) { rules += DicomFunctionalGroupsModule.frameExtractionRules() }
        if dataSet.contains(0x52009229) || dataSet.contains(0x52009230) {
            rules += DicomFunctionalGroupsModule.rootRules(frames: frames)
        }
        if dataSet.contains(0x00209221) || dataSet.contains(0x00209222) {
            rules += DicomFunctionalGroupsModule.dimensionRules(for: dataSet)
        }
        let attributes = DicomAttributeValidator.evaluate(dataSet, rules: rules, limits: limits)
        var report = attributes.report.limitingDiagnostics(to: limits.maximumDiagnostics)
        guard !report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) else { return report }
        var remaining = limits.maximumRuleEvaluations - attributes.evaluations
        // Dimension Index item conditions depend on each item's own pointer values.
        guard DicomFunctionalGroupsModule.validateDimensionIndexItems(in: dataSet, report: &report, remaining: &remaining, limits: limits) else {
            return report
        }
        var diagnostics: [DicomValidationReport.Diagnostic] = []
        func forbid(_ tag: Int) {
            diagnostics.append(.init(code: .conditionalAttributeForbidden, severity: .error, layer: .attributes, path: [.tag(tag)]))
        }
        // A.8.2.4/A.8.5.4 exclude the VOI LUT module; every multi-frame SC IOD excludes Overlay Plane.
        if [.singleBit, .trueColor].contains(variant) {
            for tag in [0x00283010, 0x00281050, 0x00281051, 0x00281056] where dataSet.contains(tag) { forbid(tag) }
        }
        for group in stride(from: 0x6000, through: 0x601E, by: 2) {
            let base = group << 16
            if let tag = [base | 0x0010, base | 0x3000].first(where: dataSet.contains) { forbid(tag) }
        }
        if dataSet.contains(0x52009229) {
            // Functional group macro content is composed by the Enhanced lot; declared groups stay explicit here.
            diagnostics.append(.init(code: .moduleRuleUnavailable, severity: .limitation, layer: .attributes, path: [.tag(0x52009229)]))
        }
        let available = limits.maximumDiagnostics - report.diagnostics.count
        guard available > 0 else { return report }
        if diagnostics.count > available {
            diagnostics = Array(diagnostics.prefix(max(0, available - 1)))
                + [.init(code: .evaluationLimitReached, severity: .limitation, layer: .attributes)]
        }
        report = report.merging(.init(diagnostics: diagnostics))
        return report
    }

    /// A.8.4.4: unused high bits of grayscale word samples must be zero. Returns nil when the
    /// value length is odd or Bits Stored is outside 1...16.
    public static func unusedHighBitsAreZero(_ bytes: Data, bitsStored: Int, littleEndian: Bool) -> Bool? {
        guard bytes.count.isMultiple(of: 2) else { return nil }
        guard (1..<16).contains(bitsStored) else { return bitsStored == 16 ? true : nil }
        let mask = UInt16(truncatingIfNeeded: ~((1 << bitsStored) - 1))
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let low = UInt16(bytes[littleEndian ? index : index + 1]), high = UInt16(bytes[littleEndian ? index + 1 : index])
            if (high << 8 | low) & mask != 0 { return false }
            index += 2
        }
        return true
    }

    private static func contentConstraints(variant: Variant, encoding: Encoding?) -> [DicomAttributeRule] {
        let forbiddenPlanar = DicomAttributeRule(tag: 0x00280006, requirement: .type3, constraints: [.forbiddenWhen(.known(.satisfied))])
        let representation = DicomAttributeRule(tag: 0x00280103, requirement: .type1, constraints: [.integers([0])])
        switch variant {
        case .singleBit:
            return [.init(tag: 0x00280002, requirement: .type1, constraints: [.integers([1])]),
                    .init(tag: 0x00280004, requirement: .type1, constraints: [.strings(["MONOCHROME2"])]),
                    .init(tag: 0x00280100, requirement: .type1, constraints: [.integers([1])]),
                    .init(tag: 0x00280101, requirement: .type1, constraints: [.integers([1])]),
                    .init(tag: 0x00280102, requirement: .type1, constraints: [.integers([0])]), representation, forbiddenPlanar]
        case .grayscaleByte:
            return [.init(tag: 0x00280002, requirement: .type1, constraints: [.integers([1])]),
                    .init(tag: 0x00280004, requirement: .type1, constraints: [.strings(["MONOCHROME2"])]),
                    .init(tag: 0x00280100, requirement: .type1, constraints: [.integers([8])]),
                    .init(tag: 0x00280101, requirement: .type1, constraints: [.integers([8])]),
                    .init(tag: 0x00280102, requirement: .type1, constraints: [.integers([7])]), representation, forbiddenPlanar]
        case .grayscaleWord:
            return [.init(tag: 0x00280002, requirement: .type1, constraints: [.integers([1])]),
                    .init(tag: 0x00280004, requirement: .type1, constraints: [.strings(["MONOCHROME2"])]),
                    .init(tag: 0x00280100, requirement: .type1, constraints: [.integers([16])]),
                    .init(tag: 0x00280101, requirement: .type1, constraints: [.integerRange(9...16)]),
                    .init(tag: 0x00280102, requirement: .type1, constraints: [.integerEqualsAttribute(0x00280101, offset: -1)]),
                    representation, forbiddenPlanar]
        case .trueColor:
            let photometric: [DicomAttributeRule.Constraint] = encoding?.trueColorPhotometricInterpretations.map { [.strings($0)] }
                ?? [.requiredCondition(.undetermined)]
            return [.init(tag: 0x00280002, requirement: .type1, constraints: [.integers([3])]),
                    .init(tag: 0x00280004, requirement: .type1, constraints: photometric),
                    .init(tag: 0x00280100, requirement: .type1, constraints: [.integers([8])]),
                    .init(tag: 0x00280101, requirement: .type1, constraints: [.integers([8])]),
                    .init(tag: 0x00280102, requirement: .type1, constraints: [.integers([7])]), representation,
                    .init(tag: 0x00280006, requirement: .type1C, condition: .stringEquals(0x00280004, "RGB"), mayBePresentOtherwise: true,
                          constraints: [.integers([0])])]
        }
    }

    private static func frameCount(in dataSet: DicomDataSet) -> Int? { DicomFunctionalGroupsModule.frameCount(in: dataSet) }

    /// Frame Increment Pointer values (AT) as tags; nil when the attribute is absent or opaque.
    private static func framePointers(in dataSet: DicomDataSet) -> Set<Int>? {
        guard let element = dataSet[0x00280009], element.vr == .AT, case .unsignedIntegers(let values) = element.value, !values.isEmpty else { return nil }
        return Set(values.map { Int($0) })
    }

    /// C.7.6.6: every pointed attribute must exist; vectors carry one value per frame, Frame Time one value.
    private static func pointersResolve(in dataSet: DicomDataSet) -> DicomAttributeRule.Truth {
        guard let pointers = framePointers(in: dataSet) else { return dataSet.contains(0x00280009) ? .undetermined : .satisfied }
        for tag in pointers {
            guard let element = dataSet[tag] else { return .unsatisfied }
            if vectorTags.contains(tag), let frames = frameCount(in: dataSet), element.vm.count != frames { return .unsatisfied }
            if tag == 0x00181063, element.vm.count != 1 { return .unsatisfied }
        }
        return .satisfied
    }

    private static func matchesFramesOfInterest(_ dataSet: DicomDataSet, tag: Int) -> DicomAttributeRule.Truth {
        guard let element = dataSet[tag], let interest = dataSet[0x00286020] else { return .satisfied }
        guard interest.vm.count > 1 else { return .satisfied }
        return element.vm.count == interest.vm.count ? .satisfied : .unsatisfied
    }

    private static func decimal(_ element: DicomDataElement?, equals expected: Decimal) -> DicomAttributeRule.Truth {
        guard let element else { return .satisfied }
        guard element.vr == .DS, case .strings(let values) = element.value, values.count == 1,
              let value = try? DicomDecimalString.parse(values[0], vr: .DS) else { return .undetermined }
        return value == expected ? .satisfied : .unsatisfied
    }
}
