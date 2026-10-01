import Foundation

public struct DicomRealWorldValueMap: Equatable, Hashable, Sendable {
    public let label: String?
    public let explanation: String?
    public let firstMappedValue: Int
    public let lastMappedValue: Int
    public let units: DicomCodedConcept?
    public let intercept: Double?
    public let slope: Double?
    public let lutData: [Double]
    /// False for a linear item without Real World Value First/Last Value Mapped (Type 1, but absent from Philips
    /// MR conversions): it covers every stored value, as GDCM reads it (Isis issue #2842).
    public let declaresMappedRange: Bool

    public init?(label: String?,
                 explanation: String?,
                 firstMappedValue: Int,
                 lastMappedValue: Int,
                 units: DicomCodedConcept?,
                 intercept: Double?,
                 slope: Double?,
                 lutData: [Double],
                 declaresMappedRange: Bool = true) {
        guard firstMappedValue <= lastMappedValue else { return nil }
        if !lutData.isEmpty {
            let (span, overflowed) = lastMappedValue.subtractingReportingOverflow(firstMappedValue)
            guard !overflowed, span == lutData.count - 1 else { return nil }
        }
        guard (!lutData.isEmpty) || (intercept != nil && slope != nil) else { return nil }
        self.label = label?.dicomNonEmptyValue
        self.explanation = explanation?.dicomNonEmptyValue
        self.firstMappedValue = firstMappedValue
        self.lastMappedValue = lastMappedValue
        self.units = units
        self.intercept = intercept
        self.slope = slope
        self.lutData = lutData
        self.declaresMappedRange = declaresMappedRange
    }

    init?(dataSet: DicomDataSet) {
        let declared = dataSet.int(for: .realWorldValueFirstValueMapped)
            .flatMap { first in dataSet.int(for: .realWorldValueLastValueMapped).map { (first, $0) } }
        let lutData = dataSet.floats(for: .realWorldValueLUTData)
        // A LUT needs its first value; a complete linear item without a range maps any stored value.
        guard declared != nil || (lutData.isEmpty && dataSet.float(for: .realWorldValueSlope) != nil
                                  && dataSet.float(for: .realWorldValueIntercept) != nil) else {
            return nil
        }
        let (first, last) = declared ?? (Int(Int32.min), Int(Int32.max))
        self.init(
            label: dataSet.string(for: .realWorldValueLUTLabel),
            explanation: dataSet.string(for: .lutExplanation),
            firstMappedValue: first,
            lastMappedValue: last,
            units: dataSet.sequenceItems(for: .measurementUnitsCodeSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            intercept: dataSet.float(for: .realWorldValueIntercept),
            slope: dataSet.float(for: .realWorldValueSlope),
            lutData: lutData,
            declaresMappedRange: declared != nil
        )
    }

    public var physicalRange: ClosedRange<Double>? {
        guard declaresMappedRange else { return nil }
        if !lutData.isEmpty {
            guard lutData.allSatisfy(\.isFinite),
                  let minimum = lutData.min(), let maximum = lutData.max() else { return nil }
            return minimum...maximum
        }
        guard let intercept, let slope, intercept.isFinite, slope.isFinite else { return nil }
        let first = slope * Double(firstMappedValue) + intercept
        let last = slope * Double(lastMappedValue) + intercept
        guard first.isFinite, last.isFinite else { return nil }
        return min(first, last)...max(first, last)
    }

    public func contains(storedPixelValue: Int) -> Bool {
        firstMappedValue...lastMappedValue ~= storedPixelValue
    }

    public func physicalValue(forStoredPixelValue storedPixelValue: Int) -> Double? {
        guard contains(storedPixelValue: storedPixelValue) else { return nil }
        if !lutData.isEmpty {
            let index = storedPixelValue - firstMappedValue
            return lutData.indices.contains(index) && lutData[index].isFinite ? lutData[index] : nil
        }
        guard let intercept, let slope, intercept.isFinite, slope.isFinite else { return nil }
        let value = slope * Double(storedPixelValue) + intercept
        return value.isFinite ? value : nil
    }
}

public enum DicomSUVType: String, CaseIterable, Equatable, Hashable, Sendable {
    case bw = "BW"
    case lbm = "LBM"
    case bsa = "BSA"
    case ibw = "IBW"

    public var unitConcept: DicomCodedConcept {
        switch self {
        case .bw:
            return DicomCodedConcept(codeValue: "g/ml{SUVbw}", codingSchemeDesignator: "UCUM", codeMeaning: "Standardized Uptake Value body weight")
        case .lbm:
            return DicomCodedConcept(codeValue: "g/ml{SUVlbm}", codingSchemeDesignator: "UCUM", codeMeaning: "Standardized Uptake Value lean body mass")
        case .bsa:
            return DicomCodedConcept(codeValue: "cm2/ml{SUVbsa}", codingSchemeDesignator: "UCUM", codeMeaning: "Standardized Uptake Value body surface area")
        case .ibw:
            return DicomCodedConcept(codeValue: "g/ml{SUVibw}", codingSchemeDesignator: "UCUM", codeMeaning: "Standardized Uptake Value ideal body weight")
        }
    }
}

public struct DicomQuantitativeDiagnostic: Equatable, Hashable, Sendable {
    public let code: String
    public let message: String
    public let tag: Int?

    public init(code: String, message: String, tag: Int? = nil) {
        self.code = code
        self.message = message
        self.tag = tag
    }
}

public struct DicomSUVMetadata: Equatable, Sendable {
    public let units: String?
    public let suvType: String?
    public let correctedImage: [String]
    public let decayCorrection: String?
    public let decayFactor: Double?
    public let patientWeightKg: Double?
    public let patientSizeMeters: Double?
    public let patientSex: String?
    public let injectedDoseBq: Double?
    public let radionuclideHalfLifeSeconds: Double?
    public let radiopharmaceuticalStartTime: DicomTime?
    public let radiopharmaceuticalStartDateTime: DicomDateTime?
    public let acquisitionTime: DicomTime?
    public let seriesTime: DicomTime?
    public let seriesDate: DicomDate?
    public let acquisitionDateTime: DicomDateTime?
    public let timeZoneOffsetMinutes: Int?

    public var diagnostics: [DicomQuantitativeDiagnostic] {
        Self.makeCommonDiagnostics(
            units: units, decayReference: decayReference, decayCorrection: decayCorrection,
            injectedDoseBq: injectedDoseBq, radionuclideHalfLifeSeconds: radionuclideHalfLifeSeconds,
            radiopharmaceuticalStartTime: radiopharmaceuticalStartTime,
            radiopharmaceuticalStartDateTime: radiopharmaceuticalStartDateTime,
            referenceTimeIsKnown: acquisitionTime != nil
        ) + timingDiagnostics
    }

    public init(units: String?,
                suvType: String?,
                correctedImage: [String],
                decayCorrection: String?,
                decayFactor: Double?,
                patientWeightKg: Double?,
                patientSizeMeters: Double?,
                patientSex: String?,
                injectedDoseBq: Double?,
                radionuclideHalfLifeSeconds: Double?,
                radiopharmaceuticalStartTime: DicomTime?,
                radiopharmaceuticalStartDateTime: DicomDateTime?,
                acquisitionTime: DicomTime?,
                seriesTime: DicomTime? = nil,
                seriesDate: DicomDate? = nil,
                acquisitionDateTime: DicomDateTime? = nil,
                timeZoneOffsetMinutes: Int? = nil) {
        self.units = units?.dicomNonEmptyValue?.uppercased()
        self.suvType = suvType?.dicomNonEmptyValue?.uppercased()
        self.correctedImage = correctedImage.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        self.decayCorrection = decayCorrection?.dicomNonEmptyValue?.uppercased()
        self.decayFactor = decayFactor
        self.patientWeightKg = patientWeightKg
        self.patientSizeMeters = patientSizeMeters
        self.patientSex = patientSex?.dicomNonEmptyValue?.uppercased()
        self.injectedDoseBq = injectedDoseBq
        self.radionuclideHalfLifeSeconds = radionuclideHalfLifeSeconds
        self.radiopharmaceuticalStartTime = radiopharmaceuticalStartTime
        self.radiopharmaceuticalStartDateTime = radiopharmaceuticalStartDateTime
        self.acquisitionTime = acquisitionTime ?? acquisitionDateTime?.time
        self.seriesTime = seriesTime
        self.seriesDate = seriesDate
        self.acquisitionDateTime = acquisitionDateTime
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
    }

    init(dataSet: DicomDataSet, radiopharmaceuticalDataSet: DicomDataSet?) {
        let radiopharm = radiopharmaceuticalDataSet ?? dataSet
        let datasetOffset = dataSet.string(for: 0x00080201)
        func resolvedDateTime(_ value: DicomDateTime?) -> DicomDateTime? {
            guard let value, value.timeZoneOffsetMinutes == nil, let datasetOffset else { return value }
            return DicomDateTime(value.rawValue + datasetOffset) ?? value
        }
        let acquisitionTime = dataSet.time(for: .acquisitionTime)
        let acquisitionDateTime = dataSet.dateTime(for: 0x0008002A)
            ?? dataSet.date(for: .acquisitionDate).flatMap { date in
                acquisitionTime.flatMap { time in
                    DicomDateTime(date.rawValue + time.rawValue + (dataSet.string(for: 0x00080201) ?? ""))
                }
            }
        self.init(
            units: dataSet.string(for: .units),
            suvType: dataSet.string(for: .suvType),
            correctedImage: dataSet.strings(for: .correctedImage),
            decayCorrection: dataSet.string(for: .decayCorrection),
            decayFactor: dataSet.decimalString(for: .decayFactor),
            patientWeightKg: dataSet.decimalString(for: .patientWeight),
            patientSizeMeters: dataSet.decimalString(for: .patientSize),
            patientSex: dataSet.string(for: .patientSex),
            injectedDoseBq: radiopharm.decimalString(for: .radionuclideTotalDose),
            radionuclideHalfLifeSeconds: radiopharm.decimalString(for: .radionuclideHalfLife),
            radiopharmaceuticalStartTime: radiopharm.time(for: .radiopharmaceuticalStartTime),
            radiopharmaceuticalStartDateTime: resolvedDateTime(radiopharm.dateTime(for: .radiopharmaceuticalStartDateTime)),
            acquisitionTime: acquisitionTime,
            seriesTime: dataSet.time(for: .seriesTime),
            seriesDate: dataSet.date(for: .seriesDate),
            acquisitionDateTime: resolvedDateTime(acquisitionDateTime),
            timeZoneOffsetMinutes: datasetOffset.flatMap { DicomDateTime("19700101" + $0)?.timeZoneOffsetMinutes }
        )
    }

    public func suvValue(forActivityConcentrationBqPerMl activityConcentration: Double,
                         type: DicomSUVType) -> Double? {
        guard activityConcentration.isFinite else { return nil }
        if units == "GML", type == .bw, suvType == nil || suvType == DicomSUVType.bw.rawValue {
            return activityConcentration
        }
        guard units == "BQML",
              let dose = decayCorrectedInjectedDoseBq(),
              dose > 0,
              let factor = patientSizeCorrectionFactor(for: type),
              factor > 0 else {
            return nil
        }
        return activityConcentration * factor / dose
    }

    public func diagnostics(for type: DicomSUVType) -> [DicomQuantitativeDiagnostic] {
        DicomSUVMetadata.makeDiagnostics(
            for: type,
            units: units,
            suvType: suvType,
            decayReference: decayReference,
            decayCorrection: decayCorrection,
            patientWeightKg: patientWeightKg,
            patientSizeMeters: patientSizeMeters,
            normalizedPatientSex: normalizedPatientSex,
            injectedDoseBq: injectedDoseBq,
            radionuclideHalfLifeSeconds: radionuclideHalfLifeSeconds,
            radiopharmaceuticalStartTime: radiopharmaceuticalStartTime,
            radiopharmaceuticalStartDateTime: radiopharmaceuticalStartDateTime,
            referenceTimeIsKnown: acquisitionTime != nil
        ) + timingDiagnostics
    }

    /// The moment the pixel values are decay-corrected to, which decides how
    /// far the injected dose is decayed for SUV.
    public enum DecayReference: String, Equatable, Sendable {
        /// Decay Correction ADMIN: values are corrected to the administration,
        /// so the dose is used as injected.
        case administration
        /// Decay Correction START: values are corrected to the start of the
        /// scan, so the dose is decayed from the administration to it.
        case scanStart
    }

    /// Nil when the values are not decay-corrected (NONE) or the dataset does
    /// not say: no SUV is derived then.
    public var decayReference: DecayReference? {
        Self.decayReference(decayCorrection: decayCorrection, correctedImage: correctedImage)
    }

    static func decayReference(decayCorrection: String?, correctedImage: [String]) -> DecayReference? {
        switch decayCorrection {
        case "ADMIN": return .administration
        case "START": return .scanStart
        // Corrected Image does not identify the correction's reference time.
        case nil: return nil
        default: return nil
        }
    }

    /// The injected dose at the decay reference. Decay Factor (0054,1321) is
    /// not used: it is the per-frame factor already applied to the pixel
    /// values, not the decay of the dose since the administration.
    public func decayCorrectedInjectedDoseBq() -> Double? {
        guard let dose = injectedDoseBq, dose > 0, let decayReference else { return nil }
        switch decayReference {
        case .administration:
            return dose
        case .scanStart:
            guard let halfLife = radionuclideHalfLifeSeconds,
                  halfLife > 0,
                  let decaySeconds = decayTimeSeconds() else {
                return nil
            }
            return dose * pow(2.0, -decaySeconds / halfLife)
        }
    }

    public func patientSizeCorrectionFactor(for type: DicomSUVType) -> Double? {
        switch type {
        case .bw:
            return patientWeightKg.map { $0 * 1000.0 }
        case .lbm:
            guard let weight = patientWeightKg,
                  let heightCm = patientHeightCentimeters(),
                  let sex = normalizedPatientSex else {
                return nil
            }
            let leanBodyMassKg: Double
            switch sex {
            case "M":
                leanBodyMassKg = 1.10 * weight - 120.0 * pow(weight / heightCm, 2.0)
            case "F":
                leanBodyMassKg = 1.07 * weight - 148.0 * pow(weight / heightCm, 2.0)
            default:
                return nil
            }
            return leanBodyMassKg > 0 ? leanBodyMassKg * 1000.0 : nil
        case .bsa:
            guard let weight = patientWeightKg,
                  let heightCm = patientHeightCentimeters() else {
                return nil
            }
            let bodySurfaceAreaM2 = 0.007184 * pow(weight, 0.425) * pow(heightCm, 0.725)
            return bodySurfaceAreaM2 > 0 ? bodySurfaceAreaM2 * 10_000.0 : nil
        case .ibw:
            guard let heightCm = patientHeightCentimeters(),
                  let sex = normalizedPatientSex else {
                return nil
            }
            let idealBodyWeightKg: Double
            switch sex {
            case "M":
                idealBodyWeightKg = 48.0 + 1.06 * (heightCm - 152.0)
            case "F":
                idealBodyWeightKg = 45.5 + 0.91 * (heightCm - 152.0)
            default:
                return nil
            }
            return idealBodyWeightKg > 0 ? idealBodyWeightKg * 1000.0 : nil
        }
    }

    private var normalizedPatientSex: String? {
        guard let patientSex else { return nil }
        if patientSex.hasPrefix("M") { return "M" }
        if patientSex.hasPrefix("F") { return "F" }
        return nil
    }

    private func patientHeightCentimeters() -> Double? {
        guard let patientSizeMeters, patientSizeMeters > 0 else { return nil }
        return patientSizeMeters * 100.0
    }

    /// Seconds from administration to the scan start for Decay Correction START.
    /// The scan starts at the earlier of Series Time and Acquisition Time: a
    /// later bed position has a later Acquisition Time, but every bed of the
    /// volume is corrected to the start (issue #2775); a derived series has a
    /// later Series Time and keeps its Acquisition Time. Series Time alone is
    /// not enough. Complete dates take precedence; time-only values retain the
    /// midnight rollover.
    public func decayTimeSeconds() -> Double? {
        guard let start = radiopharmaceuticalStartDateTime?.time ?? radiopharmaceuticalStartTime,
              let acquisition = acquisitionTime else { return nil }
        if let dateTimeTime = acquisitionDateTime?.time,
           dateTimeTime.secondsSinceStartOfDay != acquisition.secondsSinceStartOfDay {
            return nil
        }
        var reference = acquisition
        var referenceDate = acquisitionDateTime?.date
        var referenceOffset = acquisitionDateTime?.timeZoneOffsetMinutes ?? timeZoneOffsetMinutes
        if let seriesTime {
            let useSeries: Bool
            if let seriesDate, let acquisitionDateTime {
                guard (timeZoneOffsetMinutes == nil) == (referenceOffset == nil),
                      let seriesInstant = Self.instant(date: seriesDate, time: seriesTime,
                                                       offsetMinutes: timeZoneOffsetMinutes ?? 0),
                      let acquisitionInstant = Self.instant(date: acquisitionDateTime.date, time: acquisition,
                                                            offsetMinutes: referenceOffset ?? 0) else { return nil }
                useSeries = seriesInstant < acquisitionInstant
            } else {
                guard seriesDate == nil else { return nil }
                useSeries = acquisitionDateTime == nil
                    && seriesTime.secondsSinceStartOfDay < acquisition.secondsSinceStartOfDay
            }
            if useSeries {
                reference = seriesTime
                referenceDate = seriesDate
                referenceOffset = timeZoneOffsetMinutes
            }
        }
        let startOffset = radiopharmaceuticalStartDateTime?.timeZoneOffsetMinutes ?? timeZoneOffsetMinutes
        // Two local times remain comparable; one known offset cannot supply the other's zone.
        guard (startOffset == nil) == (referenceOffset == nil) else { return nil }
        if let startDateTime = radiopharmaceuticalStartDateTime, let referenceDate {
            guard let startDate = Self.instant(
                date: startDateTime.date, time: start,
                offsetMinutes: startOffset ?? 0
            ), let referenceDate = Self.instant(
                date: referenceDate, time: reference,
                offsetMinutes: referenceOffset ?? 0
            ) else { return nil }
            let delta = referenceDate.timeIntervalSince(startDate)
            return delta >= 0 ? delta : nil
        }
        let localDelta = reference.secondsSinceStartOfDay - start.secondsSinceStartOfDay
        // Infer midnight rollover only from the local clocks, before comparing instants.
        let rolledDelta = localDelta < 0 ? localDelta + 24 * 60 * 60 : localDelta
        let delta = rolledDelta - Double((referenceOffset ?? 0) - (startOffset ?? 0)) * 60
        return delta >= 0 ? delta : nil
    }

    private static func instant(date: DicomDate, time: DicomTime, offsetMinutes: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: date.year, month: date.month, day: date.day)
        guard components.isValidDate(in: calendar), let midnight = calendar.date(from: components) else { return nil }
        return midnight.addingTimeInterval(time.secondsSinceStartOfDay - Double(offsetMinutes * 60))
    }

    private var timingDiagnostics: [DicomQuantitativeDiagnostic] {
        guard units == "BQML", decayReference == .scanStart, acquisitionTime != nil,
              radiopharmaceuticalStartDateTime?.time != nil || radiopharmaceuticalStartTime != nil,
              decayTimeSeconds() == nil else { return [] }
        return [DicomQuantitativeDiagnostic(
            code: "inconsistent_pet_timing",
            message: "PET acquisition and administration timing is inconsistent; SUV is not derived.",
            tag: DicomTag.acquisitionTime.rawValue
        )]
    }

    private static func decayDiagnostics(decayReference: DecayReference?,
                                         decayCorrection: String?,
                                         radionuclideHalfLifeSeconds: Double?,
                                         radiopharmaceuticalStartTime: DicomTime?,
                                         radiopharmaceuticalStartDateTime: DicomDateTime?,
                                         referenceTimeIsKnown: Bool) -> [DicomQuantitativeDiagnostic] {
        guard let decayReference else {
            if let decayCorrection {
                return [DicomQuantitativeDiagnostic(
                    code: "decay_not_corrected",
                    message: "PET values are not decay-corrected to a known reference (Decay Correction \(decayCorrection)); SUV is not derived.",
                    tag: DicomTag.decayCorrection.rawValue
                )]
            }
            return [.missing(.decayCorrection, "Decay Correction")]
        }
        guard decayReference == .scanStart else { return [] }
        var diagnostics: [DicomQuantitativeDiagnostic] = []
        if radionuclideHalfLifeSeconds == nil {
            diagnostics.append(.missing(.radionuclideHalfLife, "Radionuclide Half Life"))
        }
        if radiopharmaceuticalStartTime == nil && radiopharmaceuticalStartDateTime?.time == nil {
            diagnostics.append(.missing(.radiopharmaceuticalStartTime, "Radiopharmaceutical Start Time"))
        }
        if !referenceTimeIsKnown {
            diagnostics.append(.missing(.acquisitionTime, "Acquisition Time"))
        }
        return diagnostics
    }

    private static func makeDiagnostics(for type: DicomSUVType,
                                        units: String?,
                                        suvType: String?,
                                        decayReference: DecayReference?,
                                        decayCorrection: String?,
                                        patientWeightKg: Double?,
                                        patientSizeMeters: Double?,
                                        normalizedPatientSex: String?,
                                        injectedDoseBq: Double?,
                                        radionuclideHalfLifeSeconds: Double?,
                                        radiopharmaceuticalStartTime: DicomTime?,
                                        radiopharmaceuticalStartDateTime: DicomDateTime?,
                                        referenceTimeIsKnown: Bool) -> [DicomQuantitativeDiagnostic] {
        var diagnostics: [DicomQuantitativeDiagnostic] = []
        if units == nil {
            diagnostics.append(.missing(.units, "Units"))
        } else if units == "GML", type == .bw, let suvType, suvType != DicomSUVType.bw.rawValue {
            diagnostics.append(DicomQuantitativeDiagnostic(
                code: "incompatible_suv_type",
                message: "PET Units GML contain \(suvType), not SUVbw.",
                tag: DicomTag.suvType.rawValue
            ))
        } else if units != "BQML" && !(units == "GML" && type == .bw) {
            diagnostics.append(DicomQuantitativeDiagnostic(
                code: "unsupported_pet_units",
                message: "SUV calculation requires PET Units BQML, or GML when values are already SUVbw.",
                tag: DicomTag.units.rawValue
            ))
        }
        if units == "GML" && type == .bw {
            return diagnostics
        }
        if injectedDoseBq == nil {
            diagnostics.append(.missing(.radionuclideTotalDose, "Radionuclide Total Dose"))
        }
        diagnostics.append(contentsOf: decayDiagnostics(
            decayReference: decayReference,
            decayCorrection: decayCorrection,
            radionuclideHalfLifeSeconds: radionuclideHalfLifeSeconds,
            radiopharmaceuticalStartTime: radiopharmaceuticalStartTime,
            radiopharmaceuticalStartDateTime: radiopharmaceuticalStartDateTime,
            referenceTimeIsKnown: referenceTimeIsKnown
        ))

        switch type {
        case .bw:
            if patientWeightKg == nil {
                diagnostics.append(.missing(.patientWeight, "Patient Weight"))
            }
        case .lbm, .bsa:
            if patientWeightKg == nil {
                diagnostics.append(.missing(.patientWeight, "Patient Weight"))
            }
            if patientSizeMeters == nil {
                diagnostics.append(.missing(.patientSize, "Patient Size"))
            }
            if type == .lbm && normalizedPatientSex == nil {
                diagnostics.append(.missing(.patientSex, "Patient Sex"))
            }
        case .ibw:
            if patientSizeMeters == nil {
                diagnostics.append(.missing(.patientSize, "Patient Size"))
            }
            if normalizedPatientSex == nil {
                diagnostics.append(.missing(.patientSex, "Patient Sex"))
            }
        }
        return diagnostics
    }

    private static func makeCommonDiagnostics(units: String?,
                                              decayReference: DecayReference?,
                                              decayCorrection: String?,
                                              injectedDoseBq: Double?,
                                              radionuclideHalfLifeSeconds: Double?,
                                              radiopharmaceuticalStartTime: DicomTime?,
                                              radiopharmaceuticalStartDateTime: DicomDateTime?,
                                              referenceTimeIsKnown: Bool) -> [DicomQuantitativeDiagnostic] {
        var diagnostics: [DicomQuantitativeDiagnostic] = []
        if units == nil {
            diagnostics.append(.missing(.units, "Units"))
        } else if units != "BQML" && units != "GML" {
            diagnostics.append(DicomQuantitativeDiagnostic(
                code: "unsupported_pet_units",
                message: "SUV calculation requires PET Units BQML, or GML when values are already SUVbw.",
                tag: DicomTag.units.rawValue
            ))
        }
        if units == "GML" {
            return diagnostics
        }
        if injectedDoseBq == nil {
            diagnostics.append(.missing(.radionuclideTotalDose, "Radionuclide Total Dose"))
        }
        diagnostics.append(contentsOf: decayDiagnostics(
            decayReference: decayReference,
            decayCorrection: decayCorrection,
            radionuclideHalfLifeSeconds: radionuclideHalfLifeSeconds,
            radiopharmaceuticalStartTime: radiopharmaceuticalStartTime,
            radiopharmaceuticalStartDateTime: radiopharmaceuticalStartDateTime,
            referenceTimeIsKnown: referenceTimeIsKnown
        ))
        return diagnostics
    }
}

public enum DicomQuantitativePhysicalValueSource: Equatable, Hashable, Sendable {
    case realWorldValueMap(label: String?)
    case suv(DicomSUVType)
}

public struct DicomQuantitativeValue: Equatable, Sendable {
    public let storedValue: Int
    public let modalityValue: Double
    public let modalityUnit: String?
    public let physicalValue: Double?
    public let physicalUnit: DicomCodedConcept?
    public let physicalRange: ClosedRange<Double>?
    public let source: DicomQuantitativePhysicalValueSource?

    public init(storedValue: Int,
                modalityValue: Double,
                modalityUnit: String?,
                physicalValue: Double?,
                physicalUnit: DicomCodedConcept?,
                physicalRange: ClosedRange<Double>?,
                source: DicomQuantitativePhysicalValueSource?) {
        self.storedValue = storedValue
        self.modalityValue = modalityValue
        self.modalityUnit = modalityUnit?.dicomNonEmptyValue
        self.physicalValue = physicalValue
        self.physicalUnit = physicalUnit
        self.physicalRange = physicalRange
        self.source = source
    }
}

public struct DicomQuantitativeValueProfile: Equatable, Sendable {
    public let realWorldValueMaps: [DicomRealWorldValueMap]
    public let suvMetadata: DicomSUVMetadata?
    public let diagnostics: [DicomQuantitativeDiagnostic]

    public init(realWorldValueMaps: [DicomRealWorldValueMap] = [],
                suvMetadata: DicomSUVMetadata? = nil,
                diagnostics: [DicomQuantitativeDiagnostic] = []) {
        self.realWorldValueMaps = realWorldValueMaps
        self.suvMetadata = suvMetadata
        self.diagnostics = diagnostics
    }

    public static let empty = DicomQuantitativeValueProfile()

    public var physicalRange: ClosedRange<Double>? {
        let ranges = realWorldValueMaps.compactMap(\.physicalRange)
        guard let first = ranges.first else { return nil }
        return ranges.dropFirst().reduce(first) { range, next in
            min(range.lowerBound, next.lowerBound)...max(range.upperBound, next.upperBound)
        }
    }

    public func realWorldValueMap(forStoredPixelValue storedValue: Int,
                                  preferredLabel: String? = nil) -> DicomRealWorldValueMap? {
        let normalizedLabel = preferredLabel?.dicomNonEmptyValue?.uppercased()
        if let normalizedLabel,
           let matched = realWorldValueMaps.first(where: {
               $0.label?.uppercased() == normalizedLabel && $0.contains(storedPixelValue: storedValue)
           }) {
            return matched
        }
        return realWorldValueMaps.first { $0.contains(storedPixelValue: storedValue) }
    }

    public func realWorldValue(forStoredPixelValue storedValue: Int,
                               preferredLabel: String? = nil) -> Double? {
        realWorldValueMap(forStoredPixelValue: storedValue, preferredLabel: preferredLabel)?
            .physicalValue(forStoredPixelValue: storedValue)
    }
}

extension DCMDecoder {
    /// Object-wide inventory. Use the frame-specific profile for measurements.
    public var quantitativeValueProfile: DicomQuantitativeValueProfile {
        synchronized {
            makeQuantitativeValueProfileUnsafe()
        }
    }

    public func quantitativeValueProfile(forFrame frame: Int) -> DicomQuantitativeValueProfile {
        synchronized {
            guard frame >= 0, frame < max(1, nImages) else {
                return DicomQuantitativeValueProfile(diagnostics: [.init(
                    code: "quantitative_frame_out_of_range", message: "Requested quantitative frame is outside the source."
                )])
            }
            return makeQuantitativeValueProfileUnsafe(frame: frame)
        }
    }

    public func quantitativeValue(at pixelIndex: Int,
                                  frame: Int = 0,
                                  sample: Int = 0,
                                  preferredRealWorldValueMapLabel: String? = nil,
                                  suvType: DicomSUVType? = nil) -> DicomQuantitativeValue? {
        guard let storedValue = storedPixelValue(at: pixelIndex, frame: frame, sample: sample),
              let modalityValue = modalityPixelValue(at: pixelIndex, frame: frame, sample: sample) else {
            return nil
        }

        let displayProfile = displayTransformProfile
        let quantitativeProfile = quantitativeValueProfile(forFrame: frame)

        if let suvType {
            let suvValue = quantitativeProfile.suvMetadata?.suvValue(
                forActivityConcentrationBqPerMl: modalityValue,
                type: suvType
            )
            return DicomQuantitativeValue(
                storedValue: storedValue,
                modalityValue: modalityValue,
                modalityUnit: displayProfile.rescaleType,
                physicalValue: suvValue,
                physicalUnit: suvValue == nil ? nil : suvType.unitConcept,
                physicalRange: nil,
                source: suvValue == nil ? nil : .suv(suvType)
            )
        }

        let map = quantitativeProfile.realWorldValueMap(
            forStoredPixelValue: storedValue,
            preferredLabel: preferredRealWorldValueMapLabel
        )
        return DicomQuantitativeValue(
            storedValue: storedValue,
            modalityValue: modalityValue,
            modalityUnit: displayProfile.rescaleType,
            physicalValue: map?.physicalValue(forStoredPixelValue: storedValue),
            physicalUnit: map?.units,
            physicalRange: map?.physicalRange,
            source: map.map { .realWorldValueMap(label: $0.label) }
        )
    }

    private func makeQuantitativeValueProfileUnsafe(frame: Int? = nil) -> DicomQuantitativeValueProfile {
        let dataSet = self.dataSet
        let items = realWorldValueItemsUnsafe(frame: frame)
        let parsedMaps = items.compactMap { DicomRealWorldValueMap(dataSet: $0.dataSet) }
        let maps = parsedMaps.removingDuplicates()
        var diagnostics: [DicomQuantitativeDiagnostic] = []

        let isPETLike = dataSet.string(for: .modality)?.uppercased() == "PT" ||
            dataSet.string(for: .units)?.dicomNonEmptyValue != nil ||
            tagMetadataCache[DicomTag.radiopharmaceuticalInformationSequence.rawValue] != nil

        let suvMetadata: DicomSUVMetadata?
        if isPETLike {
            let radiopharmDataSet = parseQuantitativeSequenceItemsUnsafe(for: .radiopharmaceuticalInformationSequence)
                .first?
                .dataSet
            let metadata = DicomSUVMetadata(dataSet: dataSet, radiopharmaceuticalDataSet: radiopharmDataSet)
            diagnostics.append(contentsOf: metadata.diagnostics)
            suvMetadata = metadata
        } else {
            suvMetadata = nil
        }

        if parsedMaps.count != items.count {
            diagnostics.append(DicomQuantitativeDiagnostic(
                code: "invalid_real_world_value_mapping",
                message: "Real World Value Mapping Sequence contains an incomplete mapping item.",
                tag: DicomTag.realWorldValueMappingSequence.rawValue
            ))
        }
        if maps.contains(where: { !$0.declaresMappedRange }) {
            diagnostics.append(.init(
                code: "real_world_value_mapping_without_range",
                message: "A linear real-world mapping has no First/Last Value Mapped; it is applied to every stored value.",
                tag: DicomTag.realWorldValueMappingSequence.rawValue
            ))
        }
        if maps.contains(where: { $0.declaresMappedRange && $0.physicalRange == nil }) {
            diagnostics.append(.init(
                code: "non_finite_real_world_value_mapping",
                message: "A real-world mapping contains non-finite values or overflows its physical range.",
                tag: DicomTag.realWorldValueMappingSequence.rawValue
            ))
        }

        return DicomQuantitativeValueProfile(
            realWorldValueMaps: maps,
            suvMetadata: suvMetadata,
            diagnostics: diagnostics.removingDuplicates()
        )
    }

    private func realWorldValueItemsUnsafe(frame: Int?) -> [DicomSequenceItem] {
        var items = parseQuantitativeSequenceItemsUnsafe(for: .realWorldValueMappingSequence)
        let sharedItems = parseQuantitativeSequenceItemsUnsafe(for: .sharedFunctionalGroupsSequence)
        let perFrameItems = parseQuantitativeSequenceItemsUnsafe(for: .perFrameFunctionalGroupsSequence)
        if let frame {
            if perFrameItems.indices.contains(frame),
               perFrameItems[frame].dataSet[.realWorldValueMappingSequence] != nil {
                return perFrameItems[frame].dataSet.sequenceItems(for: .realWorldValueMappingSequence)
            }
            if let shared = sharedItems.first, shared.dataSet[.realWorldValueMappingSequence] != nil {
                return shared.dataSet.sequenceItems(for: .realWorldValueMappingSequence)
            }
            return items
        }
        items.append(contentsOf: (sharedItems + perFrameItems).flatMap {
            $0.dataSet.sequenceItems(for: .realWorldValueMappingSequence)
        })
        return items
    }

    private func parseQuantitativeSequenceItemsUnsafe(for tag: DicomTag) -> [DicomSequenceItem] {
        guard let metadata = tagMetadataCache[tag.rawValue],
              metadata.offset >= 0,
              metadata.elementLength >= 0,
              metadata.offset + metadata.elementLength <= dicomData.count else {
            return []
        }

        let syntax = DicomTransferSyntax(uid: transferSyntaxUID) ?? .explicitVRLittleEndian
        return (try? DicomSequenceValueParser.parseItems(
            in: dicomData,
            valueOffset: metadata.offset,
            valueLength: metadata.elementLength,
            littleEndian: littleEndian,
            explicitVR: syntax.isExplicitVR,
            characterSet: activeCharacterSet
        )) ?? []
    }
}

private extension DicomQuantitativeDiagnostic {
    static func missing(_ tag: DicomTag, _ name: String) -> DicomQuantitativeDiagnostic {
        DicomQuantitativeDiagnostic(
            code: "missing_required_metadata",
            message: "\(name) is required for this quantitative value calculation.",
            tag: tag.rawValue
        )
    }
}

private extension DicomTime {
    var secondsSinceStartOfDay: Double {
        Double(hour * 3600 + (minute ?? 0) * 60 + (second ?? 0)) + (fractionalSeconds ?? 0)
    }
}

private extension String {
    var dicomNonEmptyValue: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
