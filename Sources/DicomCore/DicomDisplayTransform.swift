import Foundation

public enum DicomPresentationLUTShape: String, Equatable, Hashable, Sendable {
    case identity = "IDENTITY"
    case inverse = "INVERSE"

    public init?(dicomValue: String?) {
        guard let normalized = dicomValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
              !normalized.isEmpty else {
            return nil
        }
        self.init(rawValue: normalized)
    }
}

public struct DicomLUTDescriptor: Equatable, Hashable, Sendable {
    public let storedEntryCount: Int
    public let firstMappedValue: Int
    public let bitsPerEntry: Int

    public var entryCount: Int {
        storedEntryCount == 0 ? 65_536 : storedEntryCount
    }

    public init?(storedEntryCount: Int, firstMappedValue: Int, bitsPerEntry: Int) {
        guard storedEntryCount >= 0, bitsPerEntry > 0 else { return nil }
        self.storedEntryCount = storedEntryCount
        self.firstMappedValue = firstMappedValue
        self.bitsPerEntry = bitsPerEntry
    }

    func clampedIndex(for inputValue: Int, availableEntryCount: Int) -> Int? {
        guard availableEntryCount > 0 else { return nil }
        let requestedIndex = inputValue - firstMappedValue
        return min(max(requestedIndex, 0), availableEntryCount - 1)
    }
}

public struct DicomLookupTable: Equatable, Sendable {
    public let descriptor: DicomLUTDescriptor
    public let explanation: String?
    public let lutType: String?
    public let data: [UInt16]

    public init(descriptor: DicomLUTDescriptor,
                explanation: String?,
                lutType: String?,
                data: [UInt16]) {
        self.descriptor = descriptor
        self.explanation = explanation
        self.lutType = lutType
        self.data = data
    }

    public func value(for inputValue: Int) -> UInt16? {
        guard let index = descriptor.clampedIndex(for: inputValue, availableEntryCount: data.count) else {
            return nil
        }
        return data[index]
    }

    public func normalizedValue(for inputValue: Int) -> Double? {
        guard let value = value(for: inputValue) else { return nil }
        let outputBits = min(max(descriptor.bitsPerEntry, 1), 16)
        let maximum = Double((1 << outputBits) - 1)
        guard maximum > 0 else { return nil }
        return min(max(Double(value) / maximum, 0.0), 1.0)
    }
}

public enum DicomDisplayWindowSource: Equatable, Hashable, Sendable {
    case dicom(index: Int)
    case preset(MedicalPreset)
    case autoPercentile(lower: Double, upper: Double)
}

public struct DicomDisplayWindow: Equatable, Hashable, Sendable {
    public let settings: WindowSettings
    public let explanation: String?
    public let source: DicomDisplayWindowSource

    public init(settings: WindowSettings,
                explanation: String?,
                source: DicomDisplayWindowSource) {
        self.settings = settings
        self.explanation = explanation
        self.source = source
    }
}

public enum DicomDisplaySelection: Equatable, Hashable, Sendable {
    case window(index: Int)
    case voiLUT(index: Int)
    case preset(MedicalPreset)
    case customWindow(WindowSettings)
}

public struct DicomDisplayTransformProfile: Equatable, Sendable {
    public let rescaleParameters: RescaleParameters
    public let rescaleType: String?
    public let modalityLUTs: [DicomLookupTable]
    public let windows: [DicomDisplayWindow]
    public let voiLUTs: [DicomLookupTable]
    public let presentationLUTShape: DicomPresentationLUTShape?
    public let photometricInterpretation: String
    public let suggestedPresets: [MedicalPreset]

    public init(rescaleParameters: RescaleParameters = RescaleParameters(intercept: 0, slope: 1),
                rescaleType: String? = nil,
                modalityLUTs: [DicomLookupTable] = [],
                windows: [DicomDisplayWindow] = [],
                voiLUTs: [DicomLookupTable] = [],
                presentationLUTShape: DicomPresentationLUTShape? = nil,
                photometricInterpretation: String = "MONOCHROME2",
                suggestedPresets: [MedicalPreset] = []) {
        self.rescaleParameters = rescaleParameters
        self.rescaleType = rescaleType
        self.modalityLUTs = modalityLUTs
        self.windows = windows
        self.voiLUTs = voiLUTs
        self.presentationLUTShape = presentationLUTShape
        self.photometricInterpretation = photometricInterpretation
        self.suggestedPresets = suggestedPresets
    }

    public static let identity = DicomDisplayTransformProfile()

    public var isMonochrome1: Bool {
        photometricInterpretation.uppercased() == "MONOCHROME1"
    }

    public var isPresentationInverted: Bool {
        isMonochrome1 != (presentationLUTShape == .inverse)
    }

    public var defaultSelection: DicomDisplaySelection? {
        if !voiLUTs.isEmpty {
            return .voiLUT(index: 0)
        }
        if !windows.isEmpty {
            return .window(index: 0)
        }
        return nil
    }

    public func modalityValue(forStoredPixelValue storedValue: Double) -> Double {
        if let lut = modalityLUTs.first,
           storedValue.isFinite,
           let mapped = lut.value(for: Int(storedValue.rounded())) {
            return Double(mapped)
        }
        return rescaleParameters.apply(to: storedValue)
    }

    public func displayValue(forStoredPixelValue storedValue: Double,
                             selection: DicomDisplaySelection? = nil) -> UInt8? {
        let selected = selection ?? defaultSelection
        let modalityValue = modalityValue(forStoredPixelValue: storedValue)
        let normalized: Double?

        switch selected {
        case .window(let index):
            normalized = windows.indices.contains(index)
                ? Self.normalizedWindowValue(modalityValue, settings: windows[index].settings)
                : nil
        case .voiLUT(let index):
            normalized = voiLUTs.indices.contains(index)
                ? voiLUTs[index].normalizedValue(for: Int(modalityValue.rounded()))
                : nil
        case .preset(let preset):
            normalized = Self.normalizedWindowValue(
                modalityValue,
                settings: DCMWindowingProcessor.getPresetValuesV2(preset: preset)
            )
        case .customWindow(let settings):
            normalized = Self.normalizedWindowValue(modalityValue, settings: settings)
        case nil:
            normalized = nil
        }

        guard let normalized else { return nil }
        let presented = isPresentationInverted ? 1.0 - normalized : normalized
        let byteValue = Int((min(max(presented, 0.0), 1.0) * 255.0).rounded())
        return UInt8(max(0, min(255, byteValue)))
    }

    private static func normalizedWindowValue(_ value: Double, settings: WindowSettings) -> Double? {
        guard value.isFinite, settings.width > 0 else { return nil }
        let lower = settings.center - settings.width / 2.0
        let upper = settings.center + settings.width / 2.0
        guard upper > lower else { return nil }
        if value <= lower { return 0.0 }
        if value >= upper { return 1.0 }
        return (value - lower) / (upper - lower)
    }
}

extension DCMDecoder {
    public var displayTransformProfile: DicomDisplayTransformProfile {
        synchronized {
            makeDisplayTransformProfileUnsafe()
        }
    }

    public func storedPixelValue(at pixelIndex: Int, frame: Int = 0, sample: Int = 0) -> Int? {
        synchronized {
            guard let descriptor = pixelDataDescriptor else { return nil }
            return storedPixelValueUnsafe(
                at: pixelIndex,
                frame: frame,
                sample: sample,
                descriptor: descriptor
            )
        }
    }

    public func modalityPixelValue(at pixelIndex: Int, frame: Int = 0, sample: Int = 0) -> Double? {
        synchronized {
            guard let descriptor = pixelDataDescriptor,
                  let storedValue = storedPixelValueUnsafe(
                    at: pixelIndex,
                    frame: frame,
                    sample: sample,
                    descriptor: descriptor
                  ) else {
                return nil
            }
            return makeDisplayTransformProfileUnsafe()
                .modalityValue(forStoredPixelValue: Double(storedValue))
        }
    }

    public func calculatePercentileWindow(lower: Double = 0.01,
                                          upper: Double = 0.99) -> WindowSettings? {
        synchronized {
            guard lower >= 0,
                  upper <= 1,
                  lower < upper,
                  let descriptor = pixelDataDescriptor,
                  descriptor.samplesPerPixel > 0 else {
                return nil
            }

            let pixelsPerFrame = descriptor.rows * descriptor.columns
            let profile = makeDisplayTransformProfileUnsafe()
            var values: [Double] = []
            values.reserveCapacity(pixelsPerFrame * descriptor.numberOfFrames)

            for frame in 0..<descriptor.numberOfFrames {
                for pixelIndex in 0..<pixelsPerFrame {
                    guard let storedValue = storedPixelValueUnsafe(
                        at: pixelIndex,
                        frame: frame,
                        sample: 0,
                        descriptor: descriptor
                    ) else {
                        return nil
                    }
                    values.append(profile.modalityValue(forStoredPixelValue: Double(storedValue)))
                }
            }

            guard !values.isEmpty else { return nil }
            values.sort()
            let lowerIndex = Int((Double(values.count - 1) * lower).rounded(.down))
            let upperIndex = Int((Double(values.count - 1) * upper).rounded(.up))
            let low = values[max(0, min(values.count - 1, lowerIndex))]
            let high = values[max(0, min(values.count - 1, upperIndex))]
            let width = max(high - low, 1.0)
            return WindowSettings(center: (low + high) / 2.0, width: width)
        }
    }

    private func makeDisplayTransformProfileUnsafe() -> DicomDisplayTransformProfile {
        let dataSet = self.dataSet
        let photometric = photometricInterpretation.isEmpty ? "MONOCHROME2" : photometricInterpretation
        let modality = dataSet.string(for: .modality) ?? info(for: .modality)
        let bodyPart = dataSet.string(for: .bodyPartExamined) ?? info(for: .bodyPartExamined)

        return DicomDisplayTransformProfile(
            rescaleParameters: rescaleParametersV2,
            rescaleType: dataSet.string(for: .rescaleType)?.nilIfBlank,
            modalityLUTs: makeLookupTablesUnsafe(sequenceTag: .modalityLUTSequence, typeTag: .modalityLUTType),
            windows: makeDisplayWindowsUnsafe(dataSet: dataSet),
            voiLUTs: makeLookupTablesUnsafe(sequenceTag: .voiLUTSequence, typeTag: nil),
            presentationLUTShape: DicomPresentationLUTShape(
                dicomValue: dataSet.string(for: .presentationLUTShape) ?? info(for: .presentationLUTShape)
            ),
            photometricInterpretation: photometric,
            suggestedPresets: DCMWindowingProcessor.suggestPresets(for: modality, bodyPart: bodyPart.nilIfBlank)
        )
    }

    private func makeDisplayWindowsUnsafe(dataSet: DicomDataSet) -> [DicomDisplayWindow] {
        let centers = dataSet.decimalStrings(for: .windowCenter)
        let widths = dataSet.decimalStrings(for: .windowWidth)
        let explanations = dataSet.strings(for: .windowCenterWidthExplanation)
        let pairCount = min(centers.count, widths.count)

        var windows: [DicomDisplayWindow] = []
        windows.reserveCapacity(pairCount)
        for index in 0..<pairCount {
            let settings = WindowSettings(center: centers[index], width: widths[index])
            guard settings.isValid else { continue }
            windows.append(DicomDisplayWindow(
                settings: settings,
                explanation: explanations[safe: index]?.nilIfBlank,
                source: .dicom(index: index)
            ))
        }

        if windows.isEmpty, windowSettingsV2.isValid {
            windows.append(DicomDisplayWindow(
                settings: windowSettingsV2,
                explanation: nil,
                source: .dicom(index: 0)
            ))
        }
        return windows
    }

    private func makeLookupTablesUnsafe(sequenceTag: DicomTag,
                                        typeTag: DicomTag?) -> [DicomLookupTable] {
        parseDisplaySequenceItemsUnsafe(for: sequenceTag).compactMap {
            lookupTable(from: $0.dataSet, typeTag: typeTag)
        }
    }

    private func parseDisplaySequenceItemsUnsafe(for tag: DicomTag) -> [DicomSequenceItem] {
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

    private func lookupTable(from dataSet: DicomDataSet,
                             typeTag: DicomTag?) -> DicomLookupTable? {
        guard let descriptorValues = dataSet.element(for: .lutDescriptor)?.intValues,
              descriptorValues.count >= 3,
              let descriptor = DicomLUTDescriptor(
                storedEntryCount: descriptorValues[0],
                firstMappedValue: descriptorValues[1],
                bitsPerEntry: descriptorValues[2]
              ),
              let lutData = dataSet.element(for: .lutData).map({ lutDataValues(from: $0) }),
              !lutData.isEmpty else {
            return nil
        }

        return DicomLookupTable(
            descriptor: descriptor,
            explanation: dataSet.string(for: .lutExplanation)?.nilIfBlank,
            lutType: typeTag.flatMap { dataSet.string(for: $0)?.nilIfBlank },
            data: lutData
        )
    }

    private func lutDataValues(from element: DicomDataElement) -> [UInt16] {
        switch element.value {
        case .unsignedIntegers(let values):
            return values.compactMap(UInt16.init(exactly:))
        case .signedIntegers(let values):
            return values.map { UInt16(truncatingIfNeeded: $0) }
        case .bytes(let data):
            return data.readUInt16Values(littleEndian: littleEndian)
        default:
            return element.stringValues.compactMap { UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    private func storedPixelValueUnsafe(at pixelIndex: Int,
                                        frame: Int,
                                        sample: Int,
                                        descriptor: DicomPixelDataDescriptor) -> Int? {
        guard pixelIndex >= 0,
              frame >= 0,
              frame < descriptor.numberOfFrames,
              sample >= 0,
              sample < descriptor.samplesPerPixel,
              descriptor.bytesPerSample <= 4 else {
            return nil
        }

        let pixelsPerFrame = descriptor.rows * descriptor.columns
        guard pixelIndex < pixelsPerFrame else { return nil }

        let sampleIndex: Int
        if descriptor.planarConfiguration == 1 && descriptor.samplesPerPixel > 1 {
            sampleIndex = sample * pixelsPerFrame + pixelIndex
        } else {
            sampleIndex = pixelIndex * descriptor.samplesPerPixel + sample
        }
        let byteOffset = descriptor.frameOffsets[frame] + sampleIndex * descriptor.bytesPerSample
        guard byteOffset >= 0,
              byteOffset + descriptor.bytesPerSample <= dicomData.count else {
            return nil
        }

        let rawValue: Int
        switch descriptor.bytesPerSample {
        case 1:
            rawValue = Int(dicomData[byteOffset])
        case 2:
            rawValue = Int(dicomData.readUInt16(at: byteOffset, littleEndian: littleEndian))
        case 4:
            rawValue = Int(dicomData.readUInt32(at: byteOffset, littleEndian: littleEndian))
        default:
            return nil
        }

        let shift = max(0, descriptor.highBit - descriptor.bitsStored + 1)
        let mask = (1 << descriptor.bitsStored) - 1
        let storedBits = (rawValue >> shift) & mask

        guard descriptor.isSigned else {
            return storedBits
        }

        let signBit = 1 << (descriptor.bitsStored - 1)
        return (storedBits & signBit) != 0
            ? storedBits - (1 << descriptor.bitsStored)
            : storedBits
    }
}

private extension Data {
    func readUInt16(at offset: Int, littleEndian: Bool) -> UInt16 {
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1])
        return littleEndian ? (b1 << 8 | b0) : (b0 << 8 | b1)
    }

    func readUInt16Values(littleEndian: Bool) -> [UInt16] {
        stride(from: 0, to: count - count % 2, by: 2).map {
            readUInt16(at: $0, littleEndian: littleEndian)
        }
    }

    func readUInt32(at offset: Int, littleEndian: Bool) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1])
        let b2 = UInt32(self[offset + 2])
        let b3 = UInt32(self[offset + 3])
        return littleEndian
            ? (b3 << 24 | b2 << 16 | b1 << 8 | b0)
            : (b0 << 24 | b1 << 16 | b2 << 8 | b3)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }
}
