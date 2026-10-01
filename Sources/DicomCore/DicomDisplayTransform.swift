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

/// Why one VOI LUT Sequence item was rejected (issue #1865 phase A). The
/// silent profile path simply drops such items; this names the defect so a
/// caller can log or surface it without failing the whole decode.
public enum DicomVOILUTValidationError: Error, Equatable, Sendable {
    /// The item carries no LUT Descriptor (0028,3002).
    case missingDescriptor
    /// The descriptor has fewer than three values, a negative entry count,
    /// or a non-positive bit depth.
    case malformedDescriptor([Int])
    /// Bits per entry outside the 8...16 range this build can apply.
    case unsupportedBitsPerEntry(Int)
    /// The item carries no LUT Data (0028,3006), or it parsed to nothing.
    case emptyData
    /// LUT Data holds fewer entries than the descriptor declares.
    case entryCountShortfall(declared: Int, actual: Int)
}

enum DicomVOILUTValidator {
    static func validate(
        items: [DicomSequenceItem],
        littleEndian: Bool
    ) -> (accepted: [DicomLookupTable], rejected: [DicomVOILUTValidationError]) {
        var accepted: [DicomLookupTable] = []
        var rejected: [DicomVOILUTValidationError] = []
        for item in items {
            do {
                accepted.append(try table(from: item.dataSet, littleEndian: littleEndian))
            } catch let error as DicomVOILUTValidationError {
                rejected.append(error)
            } catch {
                rejected.append(.emptyData)
            }
        }
        return (accepted, rejected)
    }

    private static func table(
        from dataSet: DicomDataSet,
        littleEndian: Bool
    ) throws -> DicomLookupTable {
        guard let descriptorValues = dataSet.element(for: .lutDescriptor)?.intValues else {
            throw DicomVOILUTValidationError.missingDescriptor
        }
        guard descriptorValues.count >= 3,
              let descriptor = DicomLUTDescriptor(
                storedEntryCount: descriptorValues[0],
                firstMappedValue: descriptorValues[1],
                bitsPerEntry: descriptorValues[2]
              ) else {
            throw DicomVOILUTValidationError.malformedDescriptor(descriptorValues)
        }
        guard (8...16).contains(descriptor.bitsPerEntry) else {
            throw DicomVOILUTValidationError.unsupportedBitsPerEntry(descriptor.bitsPerEntry)
        }
        guard let element = dataSet.element(for: .lutData) else {
            throw DicomVOILUTValidationError.emptyData
        }
        let data = values(from: element, descriptor: descriptor, littleEndian: littleEndian)
        guard !data.isEmpty else {
            throw DicomVOILUTValidationError.emptyData
        }
        guard data.count >= descriptor.entryCount else {
            throw DicomVOILUTValidationError.entryCountShortfall(
                declared: descriptor.entryCount,
                actual: data.count
            )
        }
        return DicomLookupTable(
            descriptor: descriptor,
            explanation: dataSet.string(for: .lutExplanation)?.nilIfBlank,
            lutType: nil,
            data: data
        )
    }

    static func values(
        from element: DicomDataElement,
        descriptor: DicomLUTDescriptor,
        littleEndian: Bool
    ) -> [UInt16] {
        let entryLimit = descriptor.entryCount
        switch element.value {
        case .unsignedIntegers(let values):
            return values.lazy.prefix(entryLimit).compactMap(UInt16.init(exactly:))
        case .signedIntegers(let values):
            return values.lazy.prefix(entryLimit).map { UInt16(truncatingIfNeeded: $0) }
        case .bytes(let data):
            if descriptor.bitsPerEntry == 8 {
                if data.count >= entryLimit * MemoryLayout<UInt16>.size {
                    let lowByteOffset = littleEndian ? 0 : 1
                    let highByteOffset = littleEndian ? 1 : 0
                    let usesOneWordPerEntry = (0..<entryLimit).allSatisfy {
                        data[$0 * MemoryLayout<UInt16>.size + highByteOffset] == 0
                    }
                    if usesOneWordPerEntry {
                        return (0..<entryLimit).map {
                            UInt16(data[$0 * MemoryLayout<UInt16>.size + lowByteOffset])
                        }
                    }
                }
                return data.lazy.prefix(entryLimit).map(UInt16.init)
            }
            return Data(data.prefix(entryLimit * MemoryLayout<UInt16>.size))
                .readUInt16Values(littleEndian: littleEndian)
        default:
            return element.stringValues.lazy.prefix(entryLimit).compactMap {
                UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
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
    public let presentationLUT: DicomLookupTable?
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
                suggestedPresets: [MedicalPreset] = [],
                presentationLUT: DicomLookupTable? = nil) {
        self.presentationLUT = presentationLUT
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
        if let lut = presentationLUT {
            guard !lut.data.isEmpty else { return nil }
            let lastIndex = Double(lut.data.count - 1)
            let scaled = min(max(normalized, 0), 1) * lastIndex
            let index = Int((isMonochrome1 ? lastIndex - scaled : scaled).rounded())
            let maximum = (1 << min(lut.descriptor.bitsPerEntry, 16)) - 1
            return UInt8((min(Int(lut.data[index]), maximum) * 255) / maximum)
        }
        let byte = UInt8(Int(min(max(normalized, 0.0), 1.0) * 255.0))
        return isPresentationInverted ? 255 - byte : byte
    }

    private static func normalizedWindowValue(_ value: Double, settings: WindowSettings) -> Double? {
        guard value.isFinite, settings.width > 0 else { return nil }
        if settings.width <= 1 {
            return value <= settings.center - 0.5 ? 0 : 1
        }
        let lower = settings.center - 0.5 - (settings.width - 1) / 2
        return min(max((value - lower) / (settings.width - 1), 0), 1)
    }
}

extension DCMDecoder {
    public var displayTransformProfile: DicomDisplayTransformProfile {
        synchronized {
            makeDisplayTransformProfileUnsafe()
        }
    }

    /// The VOI LUT Sequence (0028,3010), item by item, with a typed reason
    /// for every rejected item (issue #1865 phase A). Accepted tables are the
    /// ones `displayTransformProfile.voiLUTs` keeps; the rejections are what
    /// that silent path drops.
    public func validatedVOILookupTables() -> (accepted: [DicomLookupTable],
                                               rejected: [DicomVOILUTValidationError]) {
        synchronized {
            validatedVOILookupTablesUnsafe()
        }
    }

    private func validatedVOILookupTablesUnsafe() -> (accepted: [DicomLookupTable],
                                                       rejected: [DicomVOILUTValidationError]) {
        DicomVOILUTValidator.validate(
            items: parseDisplaySequenceItemsUnsafe(for: .voiLUTSequence),
            littleEndian: littleEndian
        )
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

    /// Stored pixel values of one frame/sample read under a single lock acquisition. Callers that walk every pixel
    /// (display rendering, export, statistics) must use this instead of `storedPixelValue(at:)` per pixel, which
    /// pays the synchronisation cost per sample (measured at ~3 s for a 512x512 frame in #2367).
    /// Returns nil before allocating when the Int buffer exceeds the output byte budget (256 MiB by default).
    public func storedPixelValues(frame: Int = 0, sample: Int = 0, maximumOutputBytes: Int = 256 * 1_024 * 1_024) -> [Int]? {
        synchronized {
            guard let descriptor = pixelDataDescriptor else { return nil }
            let pixelsPerFrame = descriptor.rows * descriptor.columns
            guard (0..<descriptor.numberOfFrames).contains(frame),
                  (0..<descriptor.samplesPerPixel).contains(sample), maximumOutputBytes >= 0,
                  pixelsPerFrame <= maximumOutputBytes / MemoryLayout<Int>.stride else { return nil }
            var values = [Int](repeating: 0, count: pixelsPerFrame)
            for pixelIndex in 0..<pixelsPerFrame {
                guard let value = storedPixelValueUnsafe(at: pixelIndex, frame: frame, sample: sample, descriptor: descriptor) else { return nil }
                values[pixelIndex] = value
            }
            return values
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
        let validatedVOILUTs = validatedVOILookupTablesUnsafe().accepted

        return DicomDisplayTransformProfile(
            rescaleParameters: rescaleParametersV2,
            rescaleType: dataSet.string(for: .rescaleType)?.nilIfBlank,
            modalityLUTs: makeLookupTablesUnsafe(sequenceTag: .modalityLUTSequence, typeTag: .modalityLUTType),
            windows: makeDisplayWindowsUnsafe(dataSet: dataSet),
            voiLUTs: validatedVOILUTs,
            presentationLUTShape: DicomPresentationLUTShape(
                dicomValue: dataSet.string(for: .presentationLUTShape) ?? info(for: .presentationLUTShape)
            ),
            photometricInterpretation: photometric,
            suggestedPresets: DCMWindowingProcessor.suggestPresets(for: modality, bodyPart: bodyPart.nilIfBlank),
            presentationLUT: makeLookupTablesUnsafe(sequenceTag: .presentationLUTSequence, typeTag: nil).first
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
        let valueLengthLimit: DicomSequenceValueParser.ValueLengthLimit?
        if tag == .voiLUTSequence {
            valueLengthLimit = Self.voiLUTValueLengthLimit
        } else {
            valueLengthLimit = nil
        }
        return (try? DicomSequenceValueParser.parseItems(
            in: dicomData,
            valueOffset: metadata.offset,
            valueLength: metadata.elementLength,
            littleEndian: littleEndian,
            explicitVR: syntax.isExplicitVR,
            characterSet: activeCharacterSet,
            valueLengthLimit: valueLengthLimit,
            parentContext: contextualVRContextUnsafe(), parentSequenceTag: tag.rawValue
        )) ?? []
    }

    static func voiLUTValueLengthLimit(
        tag: Int,
        vr: DicomVR,
        precedingElements: [DicomDataElement]
    ) -> Int? {
        guard tag == DicomTag.lutData.rawValue,
              let descriptorValues = precedingElements.last(where: {
                  $0.tag == DicomTag.lutDescriptor.rawValue
              })?.intValues,
              descriptorValues.count >= 3,
              let descriptor = DicomLUTDescriptor(
                  storedEntryCount: descriptorValues[0],
                  firstMappedValue: descriptorValues[1],
                  bitsPerEntry: descriptorValues[2]
              ) else {
            return nil
        }
        guard (8...16).contains(descriptor.bitsPerEntry) else { return 0 }

        let bytesPerEntry: Int
        switch vr {
        case .US, .SS:
            bytesPerEntry = MemoryLayout<UInt16>.size
        case .UL, .SL:
            bytesPerEntry = MemoryLayout<UInt32>.size
        case .OW:
            // Standard 8-bit OW data uses one byte per entry, but the DICOM
            // compatibility note explicitly permits detecting legacy writers
            // that allocated one word per entry from the Value Length.
            bytesPerEntry = MemoryLayout<UInt16>.size
        case .OB, .OV, .UN:
            bytesPerEntry = descriptor.bitsPerEntry == 8 ? 1 : MemoryLayout<UInt16>.size
        default:
            return nil
        }
        return descriptor.entryCount * bytesPerEntry
    }

    func lookupTable(from dataSet: DicomDataSet,
                             typeTag: DicomTag?) -> DicomLookupTable? {
        DicomLookupTableParser.lookupTable(from: dataSet, typeTag: typeTag, littleEndian: littleEndian)
    }

    private func lutDataValues(
        from element: DicomDataElement,
        descriptor: DicomLUTDescriptor? = nil
    ) -> [UInt16] {
        DicomLookupTableParser.lutDataValues(from: element, descriptor: descriptor, littleEndian: littleEndian)
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

/// LUT item parsing shared by the decoder's display-transform profile and the presentation-state parsers
/// (issue #2396: per-item Modality LUTs of Blending states).
enum DicomLookupTableParser {
    static func lookupTable(from dataSet: DicomDataSet,
                            typeTag: DicomTag?,
                            littleEndian: Bool) -> DicomLookupTable? {
        guard let descriptorValues = dataSet.element(for: .lutDescriptor)?.intValues,
              descriptorValues.count >= 3,
              let descriptor = DicomLUTDescriptor(
                storedEntryCount: descriptorValues[0],
                firstMappedValue: descriptorValues[1],
                bitsPerEntry: descriptorValues[2]
              ),
              let lutData = dataSet.element(for: .lutData).map({ lutDataValues(from: $0, descriptor: descriptor, littleEndian: littleEndian) }),
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


    static func lutDataValues(
        from element: DicomDataElement,
        descriptor: DicomLUTDescriptor? = nil,
        littleEndian: Bool
    ) -> [UInt16] {
        let entryLimit = descriptor?.entryCount ?? .max
        switch element.value {
        case .unsignedIntegers(let values):
            return values.lazy.prefix(entryLimit).compactMap(UInt16.init(exactly:))
        case .signedIntegers(let values):
            return values.lazy.prefix(entryLimit).map { UInt16(truncatingIfNeeded: $0) }
        case .bytes(let data):
            if descriptor?.bitsPerEntry == 8 {
                if data.count >= entryLimit * 2 {
                    let words = Data(data.prefix(entryLimit * 2)).readUInt16Values(littleEndian: littleEndian)
                    if words.allSatisfy({ $0 <= 255 }) { return words }
                }
                return data.lazy.prefix(entryLimit).map(UInt16.init)
            }
            let boundedData = descriptor.map {
                Data(data.prefix($0.entryCount * MemoryLayout<UInt16>.size))
            } ?? data
            return boundedData.readUInt16Values(littleEndian: littleEndian)
        default:
            return element.stringValues.lazy.prefix(entryLimit).compactMap {
                UInt16($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}
