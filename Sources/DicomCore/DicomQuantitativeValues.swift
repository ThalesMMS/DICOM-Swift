import Foundation

public struct DicomCodedConcept: Equatable, Hashable, Sendable {
    public let codeValue: String
    public let codingSchemeDesignator: String
    public let codeMeaning: String?

    public init(codeValue: String, codingSchemeDesignator: String, codeMeaning: String? = nil) {
        self.codeValue = codeValue.dicomNonEmptyValue ?? codeValue
        self.codingSchemeDesignator = codingSchemeDesignator.dicomNonEmptyValue ?? codingSchemeDesignator
        self.codeMeaning = codeMeaning?.dicomNonEmptyValue
    }

    init?(dataSet: DicomDataSet) {
        guard let codeValue = dataSet.string(for: .codeValue)?.dicomNonEmptyValue,
              let codingScheme = dataSet.string(for: .codingSchemeDesignator)?.dicomNonEmptyValue else {
            return nil
        }
        self.init(
            codeValue: codeValue,
            codingSchemeDesignator: codingScheme,
            codeMeaning: dataSet.string(for: .codeMeaning)
        )
    }
}

public struct DicomRealWorldValueMap: Equatable, Hashable, Sendable {
    public let label: String?
    public let explanation: String?
    public let firstMappedValue: Int
    public let lastMappedValue: Int
    public let units: DicomCodedConcept?
    public let intercept: Double?
    public let slope: Double?
    public let lutData: [Double]

    public init?(label: String?,
                 explanation: String?,
                 firstMappedValue: Int,
                 lastMappedValue: Int,
                 units: DicomCodedConcept?,
                 intercept: Double?,
                 slope: Double?,
                 lutData: [Double]) {
        guard firstMappedValue <= lastMappedValue else { return nil }
        guard (!lutData.isEmpty) || (intercept != nil && slope != nil) else { return nil }
        self.label = label?.dicomNonEmptyValue
        self.explanation = explanation?.dicomNonEmptyValue
        self.firstMappedValue = firstMappedValue
        self.lastMappedValue = lastMappedValue
        self.units = units
        self.intercept = intercept
        self.slope = slope
        self.lutData = lutData
    }

    init?(dataSet: DicomDataSet) {
        guard let first = dataSet.int(for: .realWorldValueFirstValueMapped),
              let last = dataSet.int(for: .realWorldValueLastValueMapped) else {
            return nil
        }
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
            lutData: dataSet.floats(for: .realWorldValueLUTData)
        )
    }

    public var physicalRange: ClosedRange<Double>? {
        if !lutData.isEmpty {
            guard let minimum = lutData.min(), let maximum = lutData.max() else { return nil }
            return minimum...maximum
        }
        guard let intercept, let slope else { return nil }
        let first = slope * Double(firstMappedValue) + intercept
        let last = slope * Double(lastMappedValue) + intercept
        return min(first, last)...max(first, last)
    }

    public func contains(storedPixelValue: Int) -> Bool {
        firstMappedValue...lastMappedValue ~= storedPixelValue
    }

    public func physicalValue(forStoredPixelValue storedPixelValue: Int) -> Double? {
        guard contains(storedPixelValue: storedPixelValue) else { return nil }
        if !lutData.isEmpty {
            let index = storedPixelValue - firstMappedValue
            return lutData.indices.contains(index) ? lutData[index] : nil
        }
        guard let intercept, let slope else { return nil }
        return slope * Double(storedPixelValue) + intercept
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
    public let diagnostics: [DicomQuantitativeDiagnostic]

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
                acquisitionTime: DicomTime?) {
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
        self.acquisitionTime = acquisitionTime
        self.diagnostics = DicomSUVMetadata.makeCommonDiagnostics(
            units: self.units,
            decayFactor: decayFactor,
            injectedDoseBq: injectedDoseBq,
            radionuclideHalfLifeSeconds: radionuclideHalfLifeSeconds,
            radiopharmaceuticalStartTime: radiopharmaceuticalStartTime,
            radiopharmaceuticalStartDateTime: radiopharmaceuticalStartDateTime,
            acquisitionTime: acquisitionTime
        )
    }

    init(dataSet: DicomDataSet, radiopharmaceuticalDataSet: DicomDataSet?) {
        let radiopharm = radiopharmaceuticalDataSet ?? dataSet
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
            radiopharmaceuticalStartDateTime: radiopharm.dateTime(for: .radiopharmaceuticalStartDateTime),
            acquisitionTime: dataSet.time(for: .acquisitionTime) ?? dataSet.time(for: .seriesTime)
        )
    }

    public func suvValue(forActivityConcentrationBqPerMl activityConcentration: Double,
                         type: DicomSUVType) -> Double? {
        guard activityConcentration.isFinite else { return nil }
        if units == "GML", type == .bw {
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
            decayFactor: decayFactor,
            patientWeightKg: patientWeightKg,
            patientSizeMeters: patientSizeMeters,
            normalizedPatientSex: normalizedPatientSex,
            injectedDoseBq: injectedDoseBq,
            radionuclideHalfLifeSeconds: radionuclideHalfLifeSeconds,
            radiopharmaceuticalStartTime: radiopharmaceuticalStartTime,
            radiopharmaceuticalStartDateTime: radiopharmaceuticalStartDateTime,
            acquisitionTime: acquisitionTime
        )
    }

    public func decayCorrectedInjectedDoseBq() -> Double? {
        guard let dose = injectedDoseBq, dose > 0 else { return nil }
        if let decayFactor, decayFactor > 0 {
            return dose / decayFactor
        }

        guard let halfLife = radionuclideHalfLifeSeconds,
              halfLife > 0,
              let decaySeconds = decayTimeSeconds() else {
            return nil
        }
        return dose * pow(2.0, -decaySeconds / halfLife)
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

    private func decayTimeSeconds() -> Double? {
        let start = radiopharmaceuticalStartDateTime?.time ?? radiopharmaceuticalStartTime
        guard let start, let acquisitionTime else { return nil }
        var delta = acquisitionTime.secondsSinceStartOfDay - start.secondsSinceStartOfDay
        if delta < 0 {
            delta += 24.0 * 60.0 * 60.0
        }
        return delta >= 0 ? delta : nil
    }

    private static func makeDiagnostics(for type: DicomSUVType,
                                        units: String?,
                                        decayFactor: Double?,
                                        patientWeightKg: Double?,
                                        patientSizeMeters: Double?,
                                        normalizedPatientSex: String?,
                                        injectedDoseBq: Double?,
                                        radionuclideHalfLifeSeconds: Double?,
                                        radiopharmaceuticalStartTime: DicomTime?,
                                        radiopharmaceuticalStartDateTime: DicomDateTime?,
                                        acquisitionTime: DicomTime?) -> [DicomQuantitativeDiagnostic] {
        var diagnostics: [DicomQuantitativeDiagnostic] = []
        if units == nil {
            diagnostics.append(.missing(.units, "Units"))
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
        if decayFactor == nil {
            if radionuclideHalfLifeSeconds == nil {
                diagnostics.append(.missing(.radionuclideHalfLife, "Radionuclide Half Life"))
            }
            if radiopharmaceuticalStartTime == nil && radiopharmaceuticalStartDateTime == nil {
                diagnostics.append(.missing(.radiopharmaceuticalStartTime, "Radiopharmaceutical Start Time"))
            }
            if acquisitionTime == nil {
                diagnostics.append(.missing(.acquisitionTime, "Acquisition Time"))
            }
        }

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
                                              decayFactor: Double?,
                                              injectedDoseBq: Double?,
                                              radionuclideHalfLifeSeconds: Double?,
                                              radiopharmaceuticalStartTime: DicomTime?,
                                              radiopharmaceuticalStartDateTime: DicomDateTime?,
                                              acquisitionTime: DicomTime?) -> [DicomQuantitativeDiagnostic] {
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
        if decayFactor == nil {
            if radionuclideHalfLifeSeconds == nil {
                diagnostics.append(.missing(.radionuclideHalfLife, "Radionuclide Half Life"))
            }
            if radiopharmaceuticalStartTime == nil && radiopharmaceuticalStartDateTime == nil {
                diagnostics.append(.missing(.radiopharmaceuticalStartTime, "Radiopharmaceutical Start Time"))
            }
            if acquisitionTime == nil {
                diagnostics.append(.missing(.acquisitionTime, "Acquisition Time"))
            }
        }
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
    public var quantitativeValueProfile: DicomQuantitativeValueProfile {
        synchronized {
            makeQuantitativeValueProfileUnsafe()
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
        let quantitativeProfile = quantitativeValueProfile

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

    private func makeQuantitativeValueProfileUnsafe() -> DicomQuantitativeValueProfile {
        let dataSet = self.dataSet
        let maps = makeRealWorldValueMapsUnsafe()
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

        if !parseQuantitativeSequenceItemsUnsafe(for: .realWorldValueMappingSequence).isEmpty && maps.isEmpty {
            diagnostics.append(DicomQuantitativeDiagnostic(
                code: "invalid_real_world_value_mapping",
                message: "Real World Value Mapping Sequence is present but no complete mapping item could be parsed.",
                tag: DicomTag.realWorldValueMappingSequence.rawValue
            ))
        }

        return DicomQuantitativeValueProfile(
            realWorldValueMaps: maps,
            suvMetadata: suvMetadata,
            diagnostics: diagnostics.removingDuplicates()
        )
    }

    private func makeRealWorldValueMapsUnsafe() -> [DicomRealWorldValueMap] {
        var items = parseQuantitativeSequenceItemsUnsafe(for: .realWorldValueMappingSequence)
        let sharedItems = parseQuantitativeSequenceItemsUnsafe(for: .sharedFunctionalGroupsSequence)
        let perFrameItems = parseQuantitativeSequenceItemsUnsafe(for: .perFrameFunctionalGroupsSequence)
        items.append(contentsOf: (sharedItems + perFrameItems).flatMap {
            $0.dataSet.sequenceItems(for: .realWorldValueMappingSequence)
        })
        return items.compactMap { DicomRealWorldValueMap(dataSet: $0.dataSet) }.removingDuplicates()
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
