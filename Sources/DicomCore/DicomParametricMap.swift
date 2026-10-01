import Foundation

/// Name-value metadata describing the quantitative meaning of Parametric Map values.
public struct DicomQuantityDefinition: Equatable, Hashable, Sendable {
    public let valueType: String?
    public let conceptName: DicomCodedConcept?
    public let conceptCode: DicomCodedConcept?
    public let numericValue: Double?
    public let floatingPointValue: Double?
    public let rationalNumeratorValue: Int?
    public let rationalDenominatorValue: UInt?
    public let textValue: String?

    public init(
        valueType: String? = nil,
        conceptName: DicomCodedConcept? = nil,
        conceptCode: DicomCodedConcept? = nil,
        numericValue: Double? = nil,
        floatingPointValue: Double? = nil,
        rationalNumeratorValue: Int? = nil,
        rationalDenominatorValue: UInt? = nil,
        textValue: String? = nil
    ) {
        self.valueType = valueType?.dicomPMNonEmptyValue
        self.conceptName = conceptName
        self.conceptCode = conceptCode
        self.numericValue = numericValue
        self.floatingPointValue = floatingPointValue
        self.rationalNumeratorValue = rationalNumeratorValue
        self.rationalDenominatorValue = rationalDenominatorValue
        self.textValue = textValue?.dicomPMNonEmptyValue
    }

    init?(dataSet: DicomDataSet) {
        let conceptName = dataSet.sequenceItems(for: .conceptNameCodeSequence)
            .first
            .flatMap { DicomCodedConcept(dataSet: $0.dataSet) }
        let conceptCode = dataSet.sequenceItems(for: .conceptCodeSequence)
            .first
            .flatMap { DicomCodedConcept(dataSet: $0.dataSet) }
        let textValue = dataSet.string(for: .textValue)
        let numericValue = dataSet.decimalString(for: .numericValue)
        let floatingPointValue = dataSet.float(for: .floatingPointValue)
        let rationalNumeratorValue = dataSet.int(for: .rationalNumeratorValue)
        let rationalDenominatorValue = dataSet.ints(for: .rationalDenominatorValue)
            .first
            .flatMap(UInt.init(exactly:))

        guard conceptName != nil ||
              conceptCode != nil ||
              textValue?.dicomPMNonEmptyValue != nil ||
              numericValue != nil ||
              floatingPointValue != nil ||
              rationalNumeratorValue != nil ||
              rationalDenominatorValue != nil else {
            return nil
        }

        self.init(
            valueType: dataSet.string(for: .valueType),
            conceptName: conceptName,
            conceptCode: conceptCode,
            numericValue: numericValue,
            floatingPointValue: floatingPointValue,
            rationalNumeratorValue: rationalNumeratorValue,
            rationalDenominatorValue: rationalDenominatorValue,
            textValue: textValue
        )
    }
}

// MARK: - Per-pixel validity

/// Outcome of mapping one stored Parametric Map value to a physical value.
///
/// The raw value is a small integer so a whole frame can be described by a
/// compact `[DicomParametricMapPixelValidity]` (one byte per pixel) that
/// travels next to the exact value arrays without boxing them into optionals.
/// `.valid` pixels carry an exact finite physical value; every other case is
/// a pixel that has no value and must be presented as missing, never as a
/// plausible number. Raw values are a cross-module contract with
/// ImagingCore's `QuantitativePixelValidity`; do not reorder or reassign them
/// without updating both enums and the AppShell pinning test.
public enum DicomParametricMapPixelValidity: UInt8, Equatable, Hashable, Sendable, CaseIterable, Codable {
    /// Finite stored value mapped to a finite physical value.
    case valid = 0
    /// Stored value matches Pixel Padding Value / Range Limit (background).
    case padding = 1
    /// Stored value is NaN.
    case notANumber = 2
    /// Stored value is +infinity.
    case positiveInfinity = 3
    /// Stored value is -infinity.
    case negativeInfinity = 4
    /// Stored value is finite but outside the mapping's LUT/range domain.
    case outsideMappingDomain = 5
    /// No Real World Value Mapping applies to this frame.
    case missingMapping = 6
    /// More than one Real World Value Mapping applies to this frame and the
    /// selection is not unambiguous.
    case ambiguousMapping = 7
    /// The mapping arithmetic overflowed to a non-finite physical value.
    case arithmeticOverflow = 8
    /// The applicable mapping carries non-finite slope/intercept/LUT entries
    /// or lacks the data needed to map any value.
    case malformedMappingMetadata = 9

    public var isValid: Bool { self == .valid }

    /// Stable diagnostic code (no PHI) for logs, reports, and tests.
    public var diagnosticCode: String {
        switch self {
        case .valid: return "PM_PIXEL_VALID"
        case .padding: return "PM_PIXEL_PADDING"
        case .notANumber: return "PM_PIXEL_NAN"
        case .positiveInfinity: return "PM_PIXEL_POSITIVE_INFINITY"
        case .negativeInfinity: return "PM_PIXEL_NEGATIVE_INFINITY"
        case .outsideMappingDomain: return "PM_PIXEL_OUTSIDE_MAPPING_DOMAIN"
        case .missingMapping: return "PM_PIXEL_MISSING_MAPPING"
        case .ambiguousMapping: return "PM_PIXEL_AMBIGUOUS_MAPPING"
        case .arithmeticOverflow: return "PM_PIXEL_ARITHMETIC_OVERFLOW"
        case .malformedMappingMetadata: return "PM_PIXEL_MALFORMED_MAPPING"
        }
    }

    /// Short human-readable reason suitable for a probe or ROI readout.
    public var summary: String {
        switch self {
        case .valid: return "valid"
        case .padding: return "padding"
        case .notANumber: return "NaN"
        case .positiveInfinity: return "+infinity"
        case .negativeInfinity: return "-infinity"
        case .outsideMappingDomain: return "outside mapping range"
        case .missingMapping: return "no mapping"
        case .ambiguousMapping: return "ambiguous mapping"
        case .arithmeticOverflow: return "arithmetic overflow"
        case .malformedMappingMetadata: return "malformed mapping"
        }
    }

    /// Classifies a stored value that has not yet been mapped: padding first,
    /// then non-finite values. Returns `nil` for a finite non-padding value.
    public static func storedValueProblem(
        _ storedValue: Double,
        padding: DicomParametricMapPixelPaddingRule?
    ) -> DicomParametricMapPixelValidity? {
        if let padding, padding.matches(storedValue) {
            return .padding
        }
        if storedValue.isNaN {
            return .notANumber
        }
        if storedValue.isInfinite {
            return storedValue > 0 ? .positiveInfinity : .negativeInfinity
        }
        return nil
    }
}

/// Aggregated per-reason counts for one frame or one whole scalar volume.
public struct DicomParametricMapValidityCounts: Equatable, Hashable, Sendable {
    public let totalCount: Int
    public let validCount: Int
    /// Invalid reasons with a non-zero count. `.valid` never appears here.
    public let invalidCountsByReason: [DicomParametricMapPixelValidity: Int]

    public init(
        totalCount: Int,
        validCount: Int,
        invalidCountsByReason: [DicomParametricMapPixelValidity: Int]
    ) {
        self.totalCount = totalCount
        self.validCount = validCount
        self.invalidCountsByReason = invalidCountsByReason.filter { $0.key != .valid && $0.value > 0 }
    }

    public init(validity: [DicomParametricMapPixelValidity]) {
        var buckets = [Int](repeating: 0, count: DicomParametricMapPixelValidity.allCases.count)
        for reason in validity {
            buckets[Int(reason.rawValue)] += 1
        }
        var counts: [DicomParametricMapPixelValidity: Int] = [:]
        for reason in DicomParametricMapPixelValidity.allCases where reason != .valid {
            let count = buckets[Int(reason.rawValue)]
            if count > 0 {
                counts[reason] = count
            }
        }
        self.init(
            totalCount: validity.count,
            validCount: buckets[Int(DicomParametricMapPixelValidity.valid.rawValue)],
            invalidCountsByReason: counts
        )
    }

    public static let empty = DicomParametricMapValidityCounts(totalCount: 0, validCount: 0, invalidCountsByReason: [:])

    public var invalidCount: Int { totalCount - validCount }

    /// Fraction of valid pixels in `0...1`; `0` for an empty frame.
    public var validFraction: Double {
        totalCount > 0 ? Double(validCount) / Double(totalCount) : 0
    }

    public func count(for reason: DicomParametricMapPixelValidity) -> Int {
        reason == .valid ? validCount : (invalidCountsByReason[reason] ?? 0)
    }

    public func merging(_ other: DicomParametricMapValidityCounts) -> DicomParametricMapValidityCounts {
        var merged = invalidCountsByReason
        for (reason, count) in other.invalidCountsByReason {
            merged[reason, default: 0] += count
        }
        return DicomParametricMapValidityCounts(
            totalCount: totalCount + other.totalCount,
            validCount: validCount + other.validCount,
            invalidCountsByReason: merged
        )
    }

    /// Typed, PHI-free diagnostics: one entry per invalid reason present.
    public var diagnostics: [DicomQuantitativeDiagnostic] {
        DicomParametricMapPixelValidity.allCases.compactMap { reason in
            guard reason != .valid, let count = invalidCountsByReason[reason], count > 0 else { return nil }
            return DicomQuantitativeDiagnostic(
                code: reason.diagnosticCode,
                message: "\(count) of \(totalCount) pixels have no value (\(reason.summary))."
            )
        }
    }
}

/// Pixel Padding Value / Pixel Padding Range Limit resolved for the stored
/// value type of the object (integer, Float, or Double Float Pixel Data).
public struct DicomParametricMapPixelPaddingRule: Equatable, Hashable, Sendable {
    public let value: Double
    public let rangeLimit: Double?

    public init(value: Double, rangeLimit: Double? = nil) {
        self.value = value
        self.rangeLimit = rangeLimit
    }

    public func matches(_ storedValue: Double) -> Bool {
        if value.isNaN {
            return storedValue.isNaN
        }
        if let rangeLimit, !rangeLimit.isNaN {
            let lower = Swift.min(value, rangeLimit)
            let upper = Swift.max(value, rangeLimit)
            return storedValue >= lower && storedValue <= upper
        }
        return storedValue == value
    }
}

/// Real World Value Mapping metadata scoped to Parametric Map scalar values.
public struct DicomParametricMapRealWorldValueMap: Equatable, Hashable, Sendable {
    public let label: String?
    public let explanation: String?
    public let firstMappedValue: Double?
    public let lastMappedValue: Double?
    public let units: DicomCodedConcept?
    public let intercept: Double?
    public let slope: Double?
    public let lutData: [Double]
    public let quantityDefinitions: [DicomQuantityDefinition]

    public init(
        label: String? = nil,
        explanation: String? = nil,
        firstMappedValue: Double? = nil,
        lastMappedValue: Double? = nil,
        units: DicomCodedConcept? = nil,
        intercept: Double? = nil,
        slope: Double? = nil,
        lutData: [Double] = [],
        quantityDefinitions: [DicomQuantityDefinition] = []
    ) {
        self.label = label?.dicomPMNonEmptyValue
        self.explanation = explanation?.dicomPMNonEmptyValue
        self.firstMappedValue = firstMappedValue
        self.lastMappedValue = lastMappedValue
        self.units = units
        self.intercept = intercept
        self.slope = slope
        self.lutData = lutData
        self.quantityDefinitions = quantityDefinitions
    }

    init?(dataSet: DicomDataSet) {
        let firstMappedValue = dataSet.int(for: .realWorldValueFirstValueMapped).map(Double.init)
            ?? dataSet.float(for: .doubleFloatRealWorldValueFirstValueMapped)
        let lastMappedValue = dataSet.int(for: .realWorldValueLastValueMapped).map(Double.init)
            ?? dataSet.float(for: .doubleFloatRealWorldValueLastValueMapped)
        let units = dataSet.sequenceItems(for: .measurementUnitsCodeSequence)
            .first
            .flatMap { DicomCodedConcept(dataSet: $0.dataSet) }
        let quantityDefinitions = dataSet.sequenceItems(for: .quantityDefinitionSequence)
            .compactMap { DicomQuantityDefinition(dataSet: $0.dataSet) }
        let intercept = dataSet.float(for: .realWorldValueIntercept)
        let slope = dataSet.float(for: .realWorldValueSlope)
        let lutData = dataSet.floats(for: .realWorldValueLUTData)

        guard units != nil ||
              !quantityDefinitions.isEmpty ||
              intercept != nil ||
              slope != nil ||
              !lutData.isEmpty else {
            return nil
        }

        self.init(
            label: dataSet.string(for: .realWorldValueLUTLabel),
            explanation: dataSet.string(for: .lutExplanation),
            firstMappedValue: firstMappedValue,
            lastMappedValue: lastMappedValue,
            units: units,
            intercept: intercept,
            slope: slope,
            lutData: lutData,
            quantityDefinitions: quantityDefinitions
        )
    }

    /// Why this mapping cannot map any stored value, or `nil` when it is usable.
    public var malformationDescription: String? {
        if !lutData.isEmpty {
            // Non-finite LUT entries are reported per pixel (only the pixels
            // that index them lose their value); they do not void the table.
            if let firstMappedValue, !firstMappedValue.isFinite {
                return "Real World Value First Value Mapped is not finite."
            }
            if let lastMappedValue, !lastMappedValue.isFinite {
                return "Real World Value Last Value Mapped is not finite."
            }
            return nil
        }
        guard let intercept, let slope else {
            return "Real World Value Mapping declares neither LUT Data nor Slope/Intercept."
        }
        if !intercept.isFinite || !slope.isFinite {
            return "Real World Value Slope/Intercept are not finite."
        }
        if let firstMappedValue, !firstMappedValue.isFinite {
            return "Real World Value First Value Mapped is not finite."
        }
        if let lastMappedValue, !lastMappedValue.isFinite {
            return "Real World Value Last Value Mapped is not finite."
        }
        return nil
    }

    public var isMalformed: Bool { malformationDescription != nil }

    /// Stored-value domain declared by First/Last Value Mapped, when both exist.
    public var storedValueDomain: ClosedRange<Double>? {
        guard let firstMappedValue, let lastMappedValue,
              !firstMappedValue.isNaN, !lastMappedValue.isNaN else { return nil }
        return Swift.min(firstMappedValue, lastMappedValue)...Swift.max(firstMappedValue, lastMappedValue)
    }

    public var physicalRange: ClosedRange<Double>? {
        if !lutData.isEmpty {
            let finite = lutData.filter(\.isFinite)
            guard let minimum = finite.min(), let maximum = finite.max() else { return nil }
            return minimum...maximum
        }
        guard let firstMappedValue,
              let lastMappedValue,
              let intercept,
              let slope else {
            return nil
        }
        let first = slope * firstMappedValue + intercept
        let last = slope * lastMappedValue + intercept
        guard first.isFinite, last.isFinite else { return nil }
        return Swift.min(first, last)...Swift.max(first, last)
    }

    /// `true` when the finite stored value falls inside the declared domain
    /// (or when no domain is declared). Non-finite values never match.
    public func contains(storedValue: Double) -> Bool {
        guard storedValue.isFinite else { return false }
        guard let storedValueDomain else { return true }
        return storedValueDomain ~= storedValue
    }

    /// Per-pixel mapping outcome: the exact physical value, or the typed
    /// reason the pixel has no value. Padding is classified by the caller
    /// before invoking this mapping, so this method never receives a padding
    /// rule. Never falls back to a plausible number.
    public func mappingOutcome(forStoredValue storedValue: Double) -> DicomParametricMapMappingOutcome {
        if isMalformed {
            return .invalid(.malformedMappingMetadata)
        }
        if let problem = DicomParametricMapPixelValidity.storedValueProblem(storedValue, padding: nil) {
            return .invalid(problem)
        }
        guard contains(storedValue: storedValue) else {
            return .invalid(.outsideMappingDomain)
        }
        if !lutData.isEmpty {
            let first = firstMappedValue ?? 0
            let indexValue = storedValue - first
            guard indexValue.rounded() == indexValue,
                  let index = Int(exactly: indexValue),
                  lutData.indices.contains(index) else {
                return .invalid(.outsideMappingDomain)
            }
            let value = lutData[index]
            return value.isFinite ? .value(value) : .invalid(.malformedMappingMetadata)
        }
        guard let intercept, let slope else {
            return .invalid(.malformedMappingMetadata)
        }
        let value = slope * storedValue + intercept
        return value.isFinite ? .value(value) : .invalid(.arithmeticOverflow)
    }

    /// Returns the mapped physical value. Pixel Padding is not evaluated;
    /// callers must check the object's `pixelPadding` rule first.
    public func physicalValue(forStoredValue storedValue: Double) -> Double? {
        if case let .value(value) = mappingOutcome(forStoredValue: storedValue) {
            return value
        }
        return nil
    }
}

/// Result of mapping one stored value through one Real World Value Mapping.
public enum DicomParametricMapMappingOutcome: Equatable, Sendable {
    case value(Double)
    case invalid(DicomParametricMapPixelValidity)

    public var validity: DicomParametricMapPixelValidity {
        switch self {
        case .value: return .valid
        case let .invalid(reason): return reason
        }
    }
}

/// One decoded Parametric Map frame with scalar values and quantitative metadata.
public struct DicomParametricMapFrame: Equatable, Sendable {
    public let index: Int
    public let geometry: DicomFrameGeometry?
    public let sourceImageReferences: [DicomSourceImageReference]
    /// Exact stored values, byte-for-byte from Float/Double Float/integer
    /// Pixel Data (NaN, infinities, and padding preserved).
    public let scalarValues: [Double]
    /// Exact mapped physical values, or `nil` when no mapping applies to the
    /// frame. Invalid pixels hold `Double.nan`; consult `pixelValidity` for
    /// the reason.
    public let physicalValues: [Double]?
    /// One validity outcome per pixel, parallel to `scalarValues`.
    public let pixelValidity: [DicomParametricMapPixelValidity]
    /// Per-reason counts for this frame.
    public let validityCounts: DicomParametricMapValidityCounts
    public let units: DicomCodedConcept?
    public let quantityDefinitions: [DicomQuantityDefinition]
    public let realWorldValueMap: DicomParametricMapRealWorldValueMap?

    public init(
        index: Int,
        geometry: DicomFrameGeometry? = nil,
        sourceImageReferences: [DicomSourceImageReference] = [],
        scalarValues: [Double],
        physicalValues: [Double]? = nil,
        pixelValidity: [DicomParametricMapPixelValidity]? = nil,
        units: DicomCodedConcept? = nil,
        quantityDefinitions: [DicomQuantityDefinition] = [],
        realWorldValueMap: DicomParametricMapRealWorldValueMap? = nil
    ) {
        self.index = index
        self.geometry = geometry
        self.sourceImageReferences = sourceImageReferences
        self.scalarValues = scalarValues
        self.physicalValues = physicalValues
        let resolvedValidity = pixelValidity ?? Self.deriveValidity(
            scalarValues: scalarValues,
            physicalValues: physicalValues
        )
        self.pixelValidity = resolvedValidity
        self.validityCounts = DicomParametricMapValidityCounts(validity: resolvedValidity)
        self.units = units
        self.quantityDefinitions = quantityDefinitions
        self.realWorldValueMap = realWorldValueMap
    }

    /// Exact physical value for a valid pixel, `nil` for an invalid one.
    public func physicalValue(atPixelIndex index: Int) -> Double? {
        guard let physicalValues, physicalValues.indices.contains(index),
              pixelValidity.indices.contains(index), pixelValidity[index].isValid else {
            return nil
        }
        let value = physicalValues[index]
        return value.isFinite ? value : nil
    }

    private static func deriveValidity(
        scalarValues: [Double],
        physicalValues: [Double]?
    ) -> [DicomParametricMapPixelValidity] {
        guard let physicalValues, physicalValues.count == scalarValues.count else {
            return [DicomParametricMapPixelValidity](repeating: .missingMapping, count: scalarValues.count)
        }
        return zip(scalarValues, physicalValues).map { stored, physical in
            if physical.isFinite { return .valid }
            return DicomParametricMapPixelValidity.storedValueProblem(stored, padding: nil) ?? .outsideMappingDomain
        }
    }
}

/// Contiguous scalar layer assembled from all Parametric Map frames.
public struct DicomParametricMapScalarVolume: Equatable, Sendable {
    public let rows: Int
    public let columns: Int
    public let frameCount: Int
    public let scalarValues: [Double]
    /// Exact physical values for every frame (NaN for invalid pixels), or
    /// `nil` when at least one frame has no applicable mapping.
    public let physicalValues: [Double]?
    /// One validity outcome per voxel, parallel to `scalarValues`.
    public let pixelValidity: [DicomParametricMapPixelValidity]
    /// Per-reason counts across all frames.
    public let validityCounts: DicomParametricMapValidityCounts
    public let units: DicomCodedConcept?
    public let quantityDefinitions: [DicomQuantityDefinition]
    public let frameGeometry: [DicomFrameGeometry?]
    public let sourceImageReferences: [[DicomSourceImageReference]]

    public init(
        rows: Int,
        columns: Int,
        frameCount: Int,
        scalarValues: [Double],
        physicalValues: [Double]? = nil,
        pixelValidity: [DicomParametricMapPixelValidity]? = nil,
        units: DicomCodedConcept? = nil,
        quantityDefinitions: [DicomQuantityDefinition] = [],
        frameGeometry: [DicomFrameGeometry?] = [],
        sourceImageReferences: [[DicomSourceImageReference]] = []
    ) {
        self.rows = rows
        self.columns = columns
        self.frameCount = frameCount
        self.scalarValues = scalarValues
        self.physicalValues = physicalValues
        let resolvedValidity = pixelValidity ?? DicomParametricMapFrame(
            index: 0,
            scalarValues: scalarValues,
            physicalValues: physicalValues
        ).pixelValidity
        self.pixelValidity = resolvedValidity
        self.validityCounts = DicomParametricMapValidityCounts(validity: resolvedValidity)
        self.units = units
        self.quantityDefinitions = quantityDefinitions
        self.frameGeometry = frameGeometry
        self.sourceImageReferences = sourceImageReferences
    }
}

// MARK: - Object-level policy

/// Why a whole Parametric Map object was refused. Per-pixel problems never
/// reach this level unless every pixel is affected.
public enum DicomParametricMapRejectionReason: Equatable, Sendable {
    /// The object is not a Parametric Map (SOP Class, modality, or pixel element).
    case notParametricMap
    /// Rows, Columns, or Number of Frames do not describe a non-empty grid.
    case invalidDimensions(rows: Int, columns: Int, frameCount: Int)
    /// Float/Double Float/integer Pixel Data is absent or shorter than declared.
    case unreadablePixelPayload
    /// No Real World Value Mapping item exists at frame, shared, or top level.
    case missingRealWorldValueMapping
    /// Mappings exist but none declares Measurement Units Code Sequence.
    case missingMeasurementUnits
    /// Every frame has more than one applicable mapping and the selection is
    /// not unambiguous.
    case ambiguousRealWorldValueMapping(frameIndices: [Int])
    /// Mapping resolved, but not a single pixel produced a finite value.
    case allPixelsInvalid(DicomParametricMapValidityCounts)

    /// Stable diagnostic code (no PHI).
    public var code: String {
        switch self {
        case .notParametricMap: return "PM_NOT_PARAMETRIC_MAP"
        case .invalidDimensions: return "PM_INVALID_DIMENSIONS"
        case .unreadablePixelPayload: return "PM_UNREADABLE_PIXEL_PAYLOAD"
        case .missingRealWorldValueMapping: return "PM_MISSING_REAL_WORLD_VALUE_MAPPING"
        case .missingMeasurementUnits: return "PM_MISSING_MEASUREMENT_UNITS"
        case .ambiguousRealWorldValueMapping: return "PM_AMBIGUOUS_REAL_WORLD_VALUE_MAPPING"
        case .allPixelsInvalid: return "PM_ALL_PIXELS_INVALID"
        }
    }

    public var message: String {
        switch self {
        case .notParametricMap:
            return "The object is not a Parametric Map."
        case let .invalidDimensions(rows, columns, frameCount):
            return "Parametric Map dimensions are invalid (rows=\(rows), columns=\(columns), frames=\(frameCount))."
        case .unreadablePixelPayload:
            return "Parametric Map requires Float, Double Float, or integer Pixel Data covering every declared frame."
        case .missingRealWorldValueMapping:
            return "Parametric Map requires at least one Real World Value Mapping item."
        case .missingMeasurementUnits:
            return "Parametric Map Real World Value Mapping requires Measurement Units Code Sequence."
        case let .ambiguousRealWorldValueMapping(frameIndices):
            let frames = frameIndices.prefix(8).map(String.init).joined(separator: ", ")
            return "Multiple Real World Value Mappings apply ambiguously to frame(s) \(frames); "
                + "no mapping was chosen silently."
        case let .allPixelsInvalid(counts):
            let reasons = counts.diagnostics.map(\.message).joined(separator: " ")
            return "Every Parametric Map pixel is invalid. \(reasons)"
        }
    }

    public var diagnostic: DicomQuantitativeDiagnostic {
        DicomQuantitativeDiagnostic(code: code, message: message)
    }
}

/// Typed error thrown by `DCMDecoder.decodeParametricMap()`.
public struct DicomParametricMapDecodeError: Error, Equatable, Sendable, LocalizedError {
    public let reason: DicomParametricMapRejectionReason

    public init(reason: DicomParametricMapRejectionReason) {
        self.reason = reason
    }

    public var errorDescription: String? { reason.message }
}

/// Parsed Parametric Map object exposing frame-level and volume-level scalar data.
public struct DicomParametricMap: Equatable, Sendable {
    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.30"

    public let sopInstanceUID: String?
    public let rows: Int
    public let columns: Int
    public let frameCount: Int
    public let frames: [DicomParametricMapFrame]
    public let realWorldValueMaps: [DicomParametricMapRealWorldValueMap]
    public let pixelPadding: DicomParametricMapPixelPaddingRule?
    public let scalarVolume: DicomParametricMapScalarVolume

    public init(
        sopInstanceUID: String? = nil,
        rows: Int,
        columns: Int,
        frameCount: Int,
        frames: [DicomParametricMapFrame],
        realWorldValueMaps: [DicomParametricMapRealWorldValueMap] = [],
        pixelPadding: DicomParametricMapPixelPaddingRule? = nil,
        scalarVolume: DicomParametricMapScalarVolume? = nil
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomPMNonEmptyValue
        self.rows = rows
        self.columns = columns
        self.frameCount = frameCount
        self.frames = frames
        self.realWorldValueMaps = realWorldValueMaps
        self.pixelPadding = pixelPadding
        self.scalarVolume = scalarVolume ?? Self.makeScalarVolume(
            rows: rows,
            columns: columns,
            frameCount: frameCount,
            frames: frames
        )
    }

    /// Per-reason counts across the whole object.
    public var validityCounts: DicomParametricMapValidityCounts { scalarVolume.validityCounts }

    /// PHI-free diagnostics describing the invalid pixel population.
    public var validityDiagnostics: [DicomQuantitativeDiagnostic] { validityCounts.diagnostics }

    private static func makeScalarVolume(
        rows: Int,
        columns: Int,
        frameCount: Int,
        frames: [DicomParametricMapFrame]
    ) -> DicomParametricMapScalarVolume {
        let physicalFrames = frames.compactMap(\.physicalValues)
        let physicalValues = physicalFrames.count == frames.count ? physicalFrames.flatMap { $0 } : nil
        let frameUnits = frames.compactMap(\.units)
        let units = frameUnits.count == frames.count ? frameUnits.removingDuplicatePMValues().singlePMValue : nil
        let quantityDefinitions = frames.flatMap(\.quantityDefinitions).removingDuplicatePMValues()

        return DicomParametricMapScalarVolume(
            rows: rows,
            columns: columns,
            frameCount: frameCount,
            scalarValues: frames.flatMap(\.scalarValues),
            physicalValues: physicalValues,
            pixelValidity: frames.flatMap(\.pixelValidity),
            units: units,
            quantityDefinitions: quantityDefinitions,
            frameGeometry: frames.map(\.geometry),
            sourceImageReferences: frames.map(\.sourceImageReferences)
        )
    }
}

extension DCMDecoder {
    /// Parametric Map, or `nil` when the object is refused. Use
    /// `decodeParametricMap()` for the typed rejection reason.
    public var parametricMap: DicomParametricMap? {
        try? decodeParametricMap()
    }

    /// Decodes the Parametric Map with per-pixel validity, throwing a typed
    /// `DicomParametricMapDecodeError` when the object cannot be interpreted
    /// honestly (bad dimensions or payload, no mapping or units, ambiguous
    /// mapping on every frame, or not a single valid pixel).
    public func decodeParametricMap() throws -> DicomParametricMap {
        try synchronized {
            try DicomParametricMapParser.makeParametricMap(from: self)
        }
    }
}

private enum DicomParametricMapParser {
    /// How a frame's mapping was resolved before any pixel was classified.
    private enum FrameMappingResolution {
        /// No candidate mapping at any scope.
        case missing
        /// Candidates exist at this scope but none declares units.
        case missingUnits
        /// More than one candidate applies and the choice is not unambiguous.
        case ambiguous([DicomParametricMapRealWorldValueMap])
        /// One mapping covers the whole frame.
        case single(DicomParametricMapRealWorldValueMap)
        /// Several mappings with identical units and disjoint stored-value
        /// domains: each pixel is mapped by the one whose domain contains it.
        case partitioned([DicomParametricMapRealWorldValueMap])
    }

    static func makeParametricMap(from decoder: DCMDecoder) throws -> DicomParametricMap {
        guard matches(decoder) else {
            throw DicomParametricMapDecodeError(reason: .notParametricMap)
        }

        let rows = decoder.height
        let columns = decoder.width
        let frameCount = decoder.nImages
        guard rows > 0, columns > 0, frameCount > 0 else {
            throw DicomParametricMapDecodeError(
                reason: .invalidDimensions(rows: rows, columns: columns, frameCount: frameCount)
            )
        }
        let pixelCountResult = rows.multipliedReportingOverflow(by: columns)
        guard !pixelCountResult.overflow else {
            throw DicomParametricMapDecodeError(
                reason: .invalidDimensions(rows: rows, columns: columns, frameCount: frameCount)
            )
        }
        let pixelCount = pixelCountResult.partialValue
        let totalPixelCountResult = pixelCount.multipliedReportingOverflow(by: frameCount)
        guard !totalPixelCountResult.overflow else {
            throw DicomParametricMapDecodeError(
                reason: .invalidDimensions(rows: rows, columns: columns, frameCount: frameCount)
            )
        }
        let totalPixelCount = totalPixelCountResult.partialValue
        guard totalPixelCount <= Int.max / MemoryLayout<UInt64>.size else {
            throw DicomParametricMapDecodeError(reason: .unreadablePixelPayload)
        }
        guard let payload = scalarValues(from: decoder, count: totalPixelCount) else {
            throw DicomParametricMapDecodeError(reason: .unreadablePixelPayload)
        }
        let scalarValues = payload.values
        let padding = pixelPaddingRule(in: decoder, element: payload.element)

        let topLevelMaps = parseItems(in: decoder, for: .realWorldValueMappingSequence)
            .compactMap { DicomParametricMapRealWorldValueMap(dataSet: $0.dataSet) }
        let sharedItems = parseItems(in: decoder, for: .sharedFunctionalGroupsSequence)
        let perFrameItems = parseItems(in: decoder, for: .perFrameFunctionalGroupsSequence)
        let sharedMaps = sharedItems.flatMap { realWorldValueMaps(from: $0.dataSet) }
        let perFrameMaps = perFrameItems.map { realWorldValueMaps(from: $0.dataSet) }
        let functionalGroups = DicomEnhancedMultiframeParser.makeFunctionalGroups(
            sharedItems: sharedItems,
            perFrameItems: perFrameItems,
            declaredFrameCount: frameCount
        )

        var frames: [DicomParametricMapFrame] = []
        frames.reserveCapacity(frameCount)
        var sawCandidate = false
        var sawUnits = false
        var resolvedFrameCount = 0
        var ambiguousFrames: [Int] = []
        for frameIndex in 0..<frameCount {
            let start = frameIndex * pixelCount
            let values = Array(scalarValues[start..<(start + pixelCount)])
            let candidates = mapsForFrame(
                frameIndex,
                perFrameMaps: perFrameMaps,
                sharedMaps: sharedMaps,
                topLevelMaps: topLevelMaps
            )
            let resolution = resolveMapping(candidates: candidates)
            switch resolution {
            case .missing:
                break
            case .missingUnits:
                sawCandidate = true
            case .ambiguous:
                sawCandidate = true
                sawUnits = true
                ambiguousFrames.append(frameIndex)
            case .single, .partitioned:
                sawCandidate = true
                sawUnits = true
                resolvedFrameCount += 1
            }

            let mapped = classify(values: values, resolution: resolution, padding: padding)
            let geometry = functionalGroups?.geometry(forFrame: frameIndex)

            frames.append(DicomParametricMapFrame(
                index: frameIndex,
                geometry: geometry,
                sourceImageReferences: geometry?.sourceImageReferences ?? [],
                scalarValues: values,
                physicalValues: mapped.physicalValues,
                pixelValidity: mapped.validity,
                units: mapped.units,
                quantityDefinitions: mapped.quantityDefinitions,
                realWorldValueMap: mapped.selectedMap
            ))
        }

        let map = DicomParametricMap(
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            rows: rows,
            columns: columns,
            frameCount: frameCount,
            frames: frames,
            realWorldValueMaps: (topLevelMaps + sharedMaps + perFrameMaps.flatMap { $0 }).removingDuplicatePMValues(),
            pixelPadding: padding
        )

        // Object-level policy: refuse only when nothing can be interpreted honestly.
        if map.validityCounts.validCount == 0 {
            if !sawCandidate {
                throw DicomParametricMapDecodeError(reason: .missingRealWorldValueMapping)
            }
            if !sawUnits {
                throw DicomParametricMapDecodeError(reason: .missingMeasurementUnits)
            }
            if resolvedFrameCount == 0, !ambiguousFrames.isEmpty {
                throw DicomParametricMapDecodeError(reason: .ambiguousRealWorldValueMapping(frameIndices: ambiguousFrames))
            }
            throw DicomParametricMapDecodeError(reason: .allPixelsInvalid(map.validityCounts))
        }
        return map
    }

    private static func matches(_ decoder: DCMDecoder) -> Bool {
        decoder.info(for: .sopClassUID).dicomPMTrimmedValue == DicomParametricMap.storageSOPClassUID ||
            decoder.info(for: .modality).dicomPMTrimmedValue == "PM" ||
            decoder.tagMetadataCache[DicomTag.floatPixelData.rawValue] != nil ||
            decoder.tagMetadataCache[DicomTag.doubleFloatPixelData.rawValue] != nil
    }

    private static func realWorldValueMaps(from dataSet: DicomDataSet) -> [DicomParametricMapRealWorldValueMap] {
        dataSet.sequenceItems(for: .realWorldValueMappingSequence).compactMap {
            DicomParametricMapRealWorldValueMap(dataSet: $0.dataSet)
        }
    }

    // MARK: Mapping scope resolution

    /// Scope precedence: per-frame items override shared items, which override
    /// the top-level sequence. Ambiguity is only assessed within one scope.
    private static func mapsForFrame(
        _ index: Int,
        perFrameMaps: [[DicomParametricMapRealWorldValueMap]],
        sharedMaps: [DicomParametricMapRealWorldValueMap],
        topLevelMaps: [DicomParametricMapRealWorldValueMap]
    ) -> [DicomParametricMapRealWorldValueMap] {
        if let maps = perFrameMaps[safe: index], !maps.isEmpty {
            return maps
        }
        if !sharedMaps.isEmpty {
            return sharedMaps
        }
        return topLevelMaps
    }

    private static func resolveMapping(
        candidates: [DicomParametricMapRealWorldValueMap]
    ) -> FrameMappingResolution {
        guard !candidates.isEmpty else { return .missing }
        let withUnits = candidates.filter { $0.units != nil }.removingDuplicatePMValues()
        guard !withUnits.isEmpty else { return .missingUnits }
        if withUnits.count == 1, let only = withUnits.first {
            return .single(only)
        }
        // Several mappings: unambiguous only when they all express the same
        // units and their stored-value domains never overlap, so every pixel
        // belongs to at most one of them.
        let units = withUnits.compactMap(\.units).removingDuplicatePMValues()
        guard units.count == 1 else { return .ambiguous(withUnits) }
        let domains = withUnits.map(\.storedValueDomain)
        guard domains.allSatisfy({ $0 != nil }) else { return .ambiguous(withUnits) }
        let sorted = domains.compactMap { $0 }.sorted { $0.lowerBound < $1.lowerBound }
        guard !zip(sorted, sorted.dropFirst()).contains(where: {
            $0.0.upperBound >= $0.1.lowerBound
        }) else { return .ambiguous(withUnits) }
        return .partitioned(withUnits)
    }

    // MARK: Per-pixel classification

    private struct MappedFrame {
        let physicalValues: [Double]?
        let validity: [DicomParametricMapPixelValidity]
        let units: DicomCodedConcept?
        let quantityDefinitions: [DicomQuantityDefinition]
        let selectedMap: DicomParametricMapRealWorldValueMap?
    }

    private static func classify(
        values: [Double],
        resolution: FrameMappingResolution,
        padding: DicomParametricMapPixelPaddingRule?
    ) -> MappedFrame {
        switch resolution {
        case .missing, .missingUnits:
            return MappedFrame(
                physicalValues: nil,
                validity: [DicomParametricMapPixelValidity](repeating: .missingMapping, count: values.count),
                units: nil,
                quantityDefinitions: [],
                selectedMap: nil
            )
        case .ambiguous:
            return MappedFrame(
                physicalValues: nil,
                validity: [DicomParametricMapPixelValidity](repeating: .ambiguousMapping, count: values.count),
                units: nil,
                quantityDefinitions: [],
                selectedMap: nil
            )
        case let .single(map):
            var physical = [Double](repeating: .nan, count: values.count)
            var validity = [DicomParametricMapPixelValidity](repeating: .valid, count: values.count)
            for (index, stored) in values.enumerated() {
                if let problem = DicomParametricMapPixelValidity.storedValueProblem(stored, padding: padding) {
                    validity[index] = problem
                    continue
                }
                switch map.mappingOutcome(forStoredValue: stored) {
                case let .value(value):
                    physical[index] = value
                case let .invalid(reason):
                    validity[index] = reason
                }
            }
            return MappedFrame(
                physicalValues: physical,
                validity: validity,
                units: map.units,
                quantityDefinitions: map.quantityDefinitions,
                selectedMap: map
            )
        case let .partitioned(maps):
            var physical = [Double](repeating: .nan, count: values.count)
            var validity = [DicomParametricMapPixelValidity](repeating: .valid, count: values.count)
            for (index, stored) in values.enumerated() {
                if let problem = DicomParametricMapPixelValidity.storedValueProblem(stored, padding: padding) {
                    validity[index] = problem
                    continue
                }
                guard let map = maps.first(where: { $0.contains(storedValue: stored) }) else {
                    validity[index] = .outsideMappingDomain
                    continue
                }
                switch map.mappingOutcome(forStoredValue: stored) {
                case let .value(value):
                    physical[index] = value
                case let .invalid(reason):
                    validity[index] = reason
                }
            }
            return MappedFrame(
                physicalValues: physical,
                validity: validity,
                units: maps.first?.units,
                quantityDefinitions: maps.flatMap(\.quantityDefinitions).removingDuplicatePMValues(),
                selectedMap: maps.first
            )
        }
    }

    // MARK: Pixel payload

    private enum PixelElement {
        case integer(bitsAllocated: Int, signed: Bool)
        case float
        case doubleFloat
    }

    private struct Payload {
        let values: [Double]
        let element: PixelElement
    }

    private static func scalarValues(from decoder: DCMDecoder, count: Int) -> Payload? {
        if let range = pixelDataRange(in: decoder, tag: .floatPixelData) {
            return readFloat32Values(decoder.dicomData, range: range, count: count, littleEndian: decoder.littleEndian)
                .map { Payload(values: $0, element: .float) }
        }
        if let range = pixelDataRange(in: decoder, tag: .doubleFloatPixelData) {
            return readFloat64Values(decoder.dicomData, range: range, count: count, littleEndian: decoder.littleEndian)
                .map { Payload(values: $0, element: .doubleFloat) }
        }
        guard let range = pixelDataRange(in: decoder, tag: .pixelData) ?? legacyPixelDataRange(in: decoder) else {
            return nil
        }
        let bitsAllocated = decoder.intValue(for: .bitsAllocated) ?? decoder.bitDepth
        let signed = decoder.pixelRepresentation == 1
        return readIntegerValues(
            decoder.dicomData,
            range: range,
            count: count,
            bitsAllocated: bitsAllocated,
            signed: signed,
            littleEndian: decoder.littleEndian
        ).map { Payload(values: $0, element: .integer(bitsAllocated: bitsAllocated, signed: signed)) }
    }

    /// Pixel Padding Value / Range Limit for the pixel element actually used:
    /// (0028,0120)/(0028,0121) for integer Pixel Data, (0028,0122)/(0028,0124)
    /// for Float Pixel Data, (0028,0123)/(0028,0125) for Double Float Pixel Data.
    private static func pixelPaddingRule(
        in decoder: DCMDecoder,
        element: PixelElement
    ) -> DicomParametricMapPixelPaddingRule? {
        switch element {
        case let .integer(_, signed):
            guard let value = readIntegerTag(.pixelPaddingValue, in: decoder, signed: signed) else { return nil }
            return DicomParametricMapPixelPaddingRule(
                value: value,
                rangeLimit: readIntegerTag(.pixelPaddingRangeLimit, in: decoder, signed: signed)
            )
        case .float:
            guard let value = readFloat32Tag(.floatPixelPaddingValue, in: decoder) else { return nil }
            return DicomParametricMapPixelPaddingRule(
                value: value,
                rangeLimit: readFloat32Tag(.floatPixelPaddingRangeLimit, in: decoder)
            )
        case .doubleFloat:
            guard let value = readFloat64Tag(.doubleFloatPixelPaddingValue, in: decoder) else { return nil }
            return DicomParametricMapPixelPaddingRule(
                value: value,
                rangeLimit: readFloat64Tag(.doubleFloatPixelPaddingRangeLimit, in: decoder)
            )
        }
    }

    private static func readIntegerTag(_ tag: DicomTag, in decoder: DCMDecoder, signed: Bool) -> Double? {
        guard let range = pixelDataRange(in: decoder, tag: tag), range.count >= 2 else { return nil }
        let raw = readUInt16(decoder.dicomData, at: range.lowerBound, littleEndian: decoder.littleEndian)
        let vr = decoder.tagMetadataCache[tag.rawValue]?.vr
        let interpretSigned = vr == .SS || (vr != .US && signed)
        return interpretSigned ? Double(Int16(bitPattern: raw)) : Double(raw)
    }

    private static func readFloat32Tag(_ tag: DicomTag, in decoder: DCMDecoder) -> Double? {
        guard let range = pixelDataRange(in: decoder, tag: tag), range.count >= 4 else { return nil }
        return Double(Float(bitPattern: readUInt32(decoder.dicomData, at: range.lowerBound, littleEndian: decoder.littleEndian)))
    }

    private static func readFloat64Tag(_ tag: DicomTag, in decoder: DCMDecoder) -> Double? {
        guard let range = pixelDataRange(in: decoder, tag: tag), range.count >= 8 else { return nil }
        return Double(bitPattern: readUInt64(decoder.dicomData, at: range.lowerBound, littleEndian: decoder.littleEndian))
    }

    private static func pixelDataRange(in decoder: DCMDecoder, tag: DicomTag) -> Range<Int>? {
        guard let metadata = decoder.tagMetadataCache[tag.rawValue],
              metadata.offset >= 0,
              metadata.elementLength >= 0,
              metadata.offset <= decoder.dicomData.count,
              metadata.offset + metadata.elementLength <= decoder.dicomData.count else {
            return nil
        }
        return metadata.offset..<(metadata.offset + metadata.elementLength)
    }

    private static func legacyPixelDataRange(in decoder: DCMDecoder) -> Range<Int>? {
        guard decoder.offset >= 0, decoder.offset < decoder.dicomData.count else { return nil }
        return decoder.offset..<decoder.dicomData.count
    }

    private static func parseItems(in decoder: DCMDecoder, for tag: DicomTag) -> [DicomSequenceItem] {
        guard let metadata = decoder.tagMetadataCache[tag.rawValue],
              metadata.offset >= 0,
              metadata.elementLength >= 0,
              metadata.offset + metadata.elementLength <= decoder.dicomData.count else {
            return []
        }

        let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) ?? .explicitVRLittleEndian
        return (try? DicomSequenceValueParser.parseItems(
            in: decoder.dicomData,
            valueOffset: metadata.offset,
            valueLength: metadata.elementLength,
            littleEndian: decoder.littleEndian,
            explicitVR: syntax.isExplicitVR,
            characterSet: decoder.activeCharacterSet
        )) ?? []
    }

    private static func readIntegerValues(
        _ data: Data,
        range: Range<Int>,
        count: Int,
        bitsAllocated: Int,
        signed: Bool,
        littleEndian: Bool
    ) -> [Double]? {
        switch bitsAllocated {
        case 8:
            guard range.lowerBound + count <= range.upperBound else { return nil }
            return (0..<count).map {
                let value = data[range.lowerBound + $0]
                return signed ? Double(Int8(bitPattern: value)) : Double(value)
            }
        case 16:
            let requiredBytes = count * 2
            guard range.lowerBound + requiredBytes <= range.upperBound else { return nil }
            return (0..<count).map {
                let value = readUInt16(data, at: range.lowerBound + $0 * 2, littleEndian: littleEndian)
                return signed ? Double(Int16(bitPattern: value)) : Double(value)
            }
        case 32:
            let requiredBytes = count * 4
            guard range.lowerBound + requiredBytes <= range.upperBound else { return nil }
            return (0..<count).map {
                let value = readUInt32(data, at: range.lowerBound + $0 * 4, littleEndian: littleEndian)
                return signed ? Double(Int32(bitPattern: value)) : Double(value)
            }
        default:
            return nil
        }
    }

    /// Reads IEEE single-precision values exactly, including NaN and the
    /// infinities; classification happens per pixel afterwards.
    private static func readFloat32Values(
        _ data: Data,
        range: Range<Int>,
        count: Int,
        littleEndian: Bool
    ) -> [Double]? {
        let requiredBytes = count * 4
        guard range.lowerBound + requiredBytes <= range.upperBound else { return nil }
        return (0..<count).map {
            let value = readUInt32(data, at: range.lowerBound + $0 * 4, littleEndian: littleEndian)
            return Double(Float(bitPattern: value))
        }
    }

    /// Reads IEEE double-precision values exactly, including NaN and the
    /// infinities; classification happens per pixel afterwards.
    private static func readFloat64Values(
        _ data: Data,
        range: Range<Int>,
        count: Int,
        littleEndian: Bool
    ) -> [Double]? {
        let requiredBytes = count * 8
        guard range.lowerBound + requiredBytes <= range.upperBound else { return nil }
        return (0..<count).map {
            Double(bitPattern: readUInt64(data, at: range.lowerBound + $0 * 8, littleEndian: littleEndian))
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt16 {
        let b0 = UInt16(data[offset])
        let b1 = UInt16(data[offset + 1])
        return littleEndian ? (b1 << 8 | b0) : (b0 << 8 | b1)
    }

    private static func readUInt32(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        if littleEndian {
            return b3 << 24 | b2 << 16 | b1 << 8 | b0
        }
        return b0 << 24 | b1 << 16 | b2 << 8 | b3
    }

    private static func readUInt64(_ data: Data, at offset: Int, littleEndian: Bool) -> UInt64 {
        let bytes = (0..<8).map { UInt64(data[offset + $0]) }
        if littleEndian {
            return bytes[7] << 56 | bytes[6] << 48 | bytes[5] << 40 | bytes[4] << 32 |
                bytes[3] << 24 | bytes[2] << 16 | bytes[1] << 8 | bytes[0]
        }
        return bytes[0] << 56 | bytes[1] << 48 | bytes[2] << 40 | bytes[3] << 32 |
            bytes[4] << 24 | bytes[5] << 16 | bytes[6] << 8 | bytes[7]
    }
}

private extension Array where Element: Hashable {
    func removingDuplicatePMValues() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Array where Element: Equatable {
    var singlePMValue: Element? {
        guard let first, allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}

private extension String {
    var dicomPMTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomPMNonEmptyValue: String? {
        let trimmed = dicomPMTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }
}
