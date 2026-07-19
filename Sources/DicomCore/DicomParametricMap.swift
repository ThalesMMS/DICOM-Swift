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

    public var physicalRange: ClosedRange<Double>? {
        if !lutData.isEmpty {
            guard let minimum = lutData.min(), let maximum = lutData.max() else { return nil }
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
        return min(first, last)...max(first, last)
    }

    public func contains(storedValue: Double) -> Bool {
        guard let firstMappedValue, let lastMappedValue else { return true }
        return min(firstMappedValue, lastMappedValue)...max(firstMappedValue, lastMappedValue) ~= storedValue
    }

    public func physicalValue(forStoredValue storedValue: Double) -> Double? {
        guard contains(storedValue: storedValue) else { return nil }
        if !lutData.isEmpty {
            let first = firstMappedValue ?? 0
            let indexValue = storedValue - first
            guard indexValue.rounded() == indexValue,
                  let index = Int(exactly: indexValue),
                  lutData.indices.contains(index) else {
                return nil
            }
            return lutData[index]
        }
        guard let intercept, let slope else { return nil }
        return slope * storedValue + intercept
    }
}

/// One decoded Parametric Map frame with scalar values and quantitative metadata.
public struct DicomParametricMapFrame: Equatable, Sendable {
    public let index: Int
    public let geometry: DicomFrameGeometry?
    public let sourceImageReferences: [DicomSourceImageReference]
    public let scalarValues: [Double]
    public let physicalValues: [Double]?
    public let units: DicomCodedConcept?
    public let quantityDefinitions: [DicomQuantityDefinition]
    public let realWorldValueMap: DicomParametricMapRealWorldValueMap?

    public init(
        index: Int,
        geometry: DicomFrameGeometry? = nil,
        sourceImageReferences: [DicomSourceImageReference] = [],
        scalarValues: [Double],
        physicalValues: [Double]? = nil,
        units: DicomCodedConcept? = nil,
        quantityDefinitions: [DicomQuantityDefinition] = [],
        realWorldValueMap: DicomParametricMapRealWorldValueMap? = nil
    ) {
        self.index = index
        self.geometry = geometry
        self.sourceImageReferences = sourceImageReferences
        self.scalarValues = scalarValues
        self.physicalValues = physicalValues
        self.units = units
        self.quantityDefinitions = quantityDefinitions
        self.realWorldValueMap = realWorldValueMap
    }
}

/// Contiguous scalar layer assembled from all Parametric Map frames.
public struct DicomParametricMapScalarVolume: Equatable, Sendable {
    public let rows: Int
    public let columns: Int
    public let frameCount: Int
    public let scalarValues: [Double]
    public let physicalValues: [Double]?
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
        self.units = units
        self.quantityDefinitions = quantityDefinitions
        self.frameGeometry = frameGeometry
        self.sourceImageReferences = sourceImageReferences
    }
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
    public let scalarVolume: DicomParametricMapScalarVolume

    public init(
        sopInstanceUID: String? = nil,
        rows: Int,
        columns: Int,
        frameCount: Int,
        frames: [DicomParametricMapFrame],
        realWorldValueMaps: [DicomParametricMapRealWorldValueMap] = [],
        scalarVolume: DicomParametricMapScalarVolume? = nil
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomPMNonEmptyValue
        self.rows = rows
        self.columns = columns
        self.frameCount = frameCount
        self.frames = frames
        self.realWorldValueMaps = realWorldValueMaps
        self.scalarVolume = scalarVolume ?? Self.makeScalarVolume(
            rows: rows,
            columns: columns,
            frameCount: frameCount,
            frames: frames
        )
    }

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
            units: units,
            quantityDefinitions: quantityDefinitions,
            frameGeometry: frames.map(\.geometry),
            sourceImageReferences: frames.map(\.sourceImageReferences)
        )
    }
}

extension DCMDecoder {
    public var parametricMap: DicomParametricMap? {
        synchronized {
            DicomParametricMapParser.makeParametricMap(from: self)
        }
    }
}

private enum DicomParametricMapParser {
    static func makeParametricMap(from decoder: DCMDecoder) -> DicomParametricMap? {
        guard matches(decoder) else { return nil }

        let rows = decoder.height
        let columns = decoder.width
        let frameCount = max(1, decoder.nImages)
        let pixelCount = rows * columns
        let totalPixelCount = pixelCount * frameCount
        guard rows > 0, columns > 0, frameCount > 0, totalPixelCount > 0 else { return nil }
        guard let scalarValues = scalarValues(from: decoder, count: totalPixelCount) else { return nil }

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
        for frameIndex in 0..<frameCount {
            let start = frameIndex * pixelCount
            let values = Array(scalarValues[start..<(start + pixelCount)])
            let frameMaps = mapsForFrame(
                frameIndex,
                perFrameMaps: perFrameMaps,
                sharedMaps: sharedMaps,
                topLevelMaps: topLevelMaps
            )
            let selectedMap = selectedMap(for: values, maps: frameMaps)
            let mappedPhysicalValues: [Double]?
            if let selectedMap {
                mappedPhysicalValues = physicalValues(for: values, map: selectedMap)
            } else {
                mappedPhysicalValues = nil
            }
            let geometry = functionalGroups?.geometry(forFrame: frameIndex)

            frames.append(DicomParametricMapFrame(
                index: frameIndex,
                geometry: geometry,
                sourceImageReferences: geometry?.sourceImageReferences ?? [],
                scalarValues: values,
                physicalValues: mappedPhysicalValues,
                units: selectedMap?.units,
                quantityDefinitions: selectedMap?.quantityDefinitions ?? [],
                realWorldValueMap: selectedMap
            ))
        }

        return DicomParametricMap(
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            rows: rows,
            columns: columns,
            frameCount: frameCount,
            frames: frames,
            realWorldValueMaps: (topLevelMaps + sharedMaps + perFrameMaps.flatMap { $0 }).removingDuplicatePMValues()
        )
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

    private static func selectedMap(
        for values: [Double],
        maps: [DicomParametricMapRealWorldValueMap]
    ) -> DicomParametricMapRealWorldValueMap? {
        guard let firstValue = values.first else { return maps.first }
        return maps.first { $0.contains(storedValue: firstValue) } ?? maps.first
    }

    private static func physicalValues(
        for values: [Double],
        map: DicomParametricMapRealWorldValueMap
    ) -> [Double]? {
        let mapped = values.compactMap { map.physicalValue(forStoredValue: $0) }
        return mapped.count == values.count ? mapped : nil
    }

    private static func scalarValues(from decoder: DCMDecoder, count: Int) -> [Double]? {
        if let range = pixelDataRange(in: decoder, tag: .floatPixelData) {
            return readFloat32Values(decoder.dicomData, range: range, count: count, littleEndian: decoder.littleEndian)
        }
        if let range = pixelDataRange(in: decoder, tag: .doubleFloatPixelData) {
            return readFloat64Values(decoder.dicomData, range: range, count: count, littleEndian: decoder.littleEndian)
        }
        guard let range = pixelDataRange(in: decoder, tag: .pixelData) ?? legacyPixelDataRange(in: decoder) else {
            return nil
        }
        return readIntegerValues(
            decoder.dicomData,
            range: range,
            count: count,
            bitsAllocated: decoder.intValue(for: .bitsAllocated) ?? decoder.bitDepth,
            signed: decoder.pixelRepresentation == 1,
            littleEndian: decoder.littleEndian
        )
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
