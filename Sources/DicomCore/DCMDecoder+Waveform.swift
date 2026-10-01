import Foundation
import DicomObjects

extension DCMDecoder {
    public var waveform: DicomWaveform? {
        synchronized {
            DicomWaveformParser.makeWaveform(from: self)
        }
    }
}

enum DicomWaveformParser {
    static func makeWaveform(from decoder: DCMDecoder) -> DicomWaveform? {
        guard matches(decoder) else { return nil }
        let groupItems = parseItems(in: decoder, for: .waveformSequence)
        let groups = groupItems.compactMap { multiplexGroup(from: $0, displayScale: decoder.dataSet.float(for: .waveformDataDisplayScale)) }
        guard !groups.isEmpty else { return nil }
        if let kind = DicomWaveformStorageKind(storageSOPClassUID: decoder.info(for: .sopClassUID)) {
            guard groups.count == groupItems.count else { return nil }
            if kind.isAudio, !isValidAudio(kind: kind, groups: groups) {
                return nil
            }
            if kind == .multiChannelRespiratory,
               groups.contains(where: {
                   [.signed16, .signed32].contains($0.sampleInterpretation) == false
               }) {
                return nil
            }
        }

        return DicomWaveform(
            sopClassUID: decoder.info(for: .sopClassUID),
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            studyInstanceUID: decoder.info(for: .studyInstanceUID),
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID),
            modality: decoder.info(for: .modality),
            patientName: decoder.dataSet.personName(for: .patientName),
            patientID: decoder.info(for: .patientID),
            multiplexGroups: groups,
            annotations: parseItems(in: decoder, for: .waveformAnnotationSequence).map { DicomWaveformAnnotation(dataSet: $0.dataSet) },
            displayScale: DicomWaveformDisplayScale(dataSet: decoder.dataSet)
        )
    }

    private static func matches(_ decoder: DCMDecoder) -> Bool {
        let sopClassUID = decoder.info(for: .sopClassUID).dicomWaveformTrimmedValue
        return DicomWaveform.supportedStorageSOPClassUIDs.contains(sopClassUID) ||
            decoder.tagMetadataCache[DicomTag.waveformSequence.rawValue] != nil
    }

    private static func isValidAudio(
        kind: DicomWaveformStorageKind,
        groups: [DicomWaveformMultiplexGroup]
    ) -> Bool {
        guard groups.count == 1, let group = groups.first, (1...2).contains(group.numberOfChannels) else {
            return false
        }
        switch kind {
        case .basicVoiceAudio:
            return group.samplingFrequency == 8_000 &&
                [.unsigned8, .muLaw8, .aLaw8].contains(group.sampleInterpretation)
        case .generalAudio:
            return group.samplingFrequency <= 44_100 &&
                [.signed8, .signed16].contains(group.sampleInterpretation)
        default:
            return true
        }
    }

    static func multiplexGroup(from item: DicomSequenceItem, displayScale: Double? = nil) -> DicomWaveformMultiplexGroup? {
        let dataSet = item.dataSet
        guard let channelCount = dataSet.int(for: .numberOfWaveformChannels),
              channelCount > 0,
              let sampleCount = dataSet.int(for: .numberOfWaveformSamples),
              sampleCount >= 0,
              let samplingFrequency = dataSet.float(for: .samplingFrequency),
              samplingFrequency > 0,
              let interpretation = dataSet.string(for: .waveformSampleInterpretation)
                .flatMap(DicomWaveformSampleInterpretation.init(rawValue:)),
              let raw = dataSet.element(for: .waveformData)?.bytesValue else {
            return nil
        }

        let decodedSamples: [[Int]]
        do {
            decodedSamples = try splitSamples(
                raw,
                interpretation: interpretation,
                channelCount: channelCount,
                sampleCount: sampleCount
            )
        } catch {
            return nil
        }

        let channelItems = dataSet.sequenceItems(for: .channelDefinitionSequence)
        let channels = (0..<channelCount).map { index in
            channel(
                from: channelItems[safe: index]?.dataSet,
                fallbackNumber: index + 1,
                samples: decodedSamples[index], interpretation: interpretation
            )
        }

        return DicomWaveformMultiplexGroup(
            label: dataSet.string(for: .multiplexGroupLabel),
            originality: dataSet.string(for: .waveformOriginality) ?? "ORIGINAL",
            samplingFrequency: samplingFrequency,
            timeOffsetMilliseconds: dataSet.float(for: .multiplexGroupTimeOffset),
            triggerTimeOffsetMilliseconds: dataSet.float(for: .triggerTimeOffset),
            triggerSamplePosition: dataSet.int(for: .triggerSamplePosition),
            sampleInterpretation: interpretation,
            waveformDataDisplayScale: displayScale ?? dataSet.float(for: .waveformDataDisplayScale),
            paddingValue: sampleValue(dataSet, tag: 0x5400100A, interpretation: interpretation),
            channels: channels
        )
    }

    static func channel(
        from dataSet: DicomDataSet?,
        fallbackNumber: Int,
        samples: [Int], interpretation: DicomWaveformSampleInterpretation
    ) -> DicomWaveformChannel {
        guard let dataSet else {
            return DicomWaveformChannel(number: fallbackNumber, samples: samples)
        }
        return DicomWaveformChannel(
            number: dataSet.int(for: .waveformChannelNumber) ?? fallbackNumber,
            label: dataSet.string(for: .channelLabel),
            status: dataSet.strings(for: .channelStatus),
            source: dataSet.sequenceItems(for: .channelSourceSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            sourceModifiers: dataSet.sequenceItems(for: .channelSourceModifiersSequence).compactMap {
                DicomCodedConcept(dataSet: $0.dataSet)
            },
            sourceWaveformReferences: dataSet.sequenceItems(for: .sourceWaveformSequence).map(sourceReference),
            derivationDescription: dataSet.string(for: .channelDerivationDescription),
            sensitivity: dataSet.float(for: .channelSensitivity),
            sensitivityUnits: dataSet.sequenceItems(for: .channelSensitivityUnitsSequence)
                .first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            sensitivityCorrectionFactor: dataSet.float(for: .channelSensitivityCorrectionFactor),
            baseline: dataSet.float(for: .channelBaseline),
            timeSkew: dataSet.float(for: .channelTimeSkew),
            sampleSkew: dataSet.float(for: .channelSampleSkew),
            offset: dataSet.float(for: .channelOffset),
            bitsStored: dataSet.int(for: .waveformBitsStored),
            lowFrequency: dataSet.float(for: .filterLowFrequency),
            highFrequency: dataSet.float(for: .filterHighFrequency),
            notchFrequency: dataSet.float(for: .notchFilterFrequency),
            minimumValue: sampleValue(dataSet, tag: 0x54000110, interpretation: interpretation),
            maximumValue: sampleValue(dataSet, tag: 0x54000112, interpretation: interpretation),
            sampleInterpretation: interpretation,
            samples: samples
        )
    }

    static func sampleValue(_ dataSet: DicomDataSet, tag: Int,
                            interpretation: DicomWaveformSampleInterpretation) -> DicomWaveformSampleValue? {
        guard let raw = dataSet.element(for: tag)?.bytesValue,
              raw.count >= interpretation.bytesPerSample else { return nil }
        return try? DicomWaveformSampleValue(rawValue: sample(at: 0, in: raw, interpretation: interpretation),
                                            interpretation: interpretation)
    }

    private static func sourceReference(from item: DicomSequenceItem) -> DicomWaveformSourceReference {
        DicomWaveformSourceReference(
            referencedSOPClassUID: item.dataSet.string(for: .referencedSOPClassUID),
            referencedSOPInstanceUID: item.dataSet.string(for: .referencedSOPInstanceUID),
            referencedWaveformChannels: channelReferences(from: item.dataSet.ints(for: .referencedWaveformChannels))
        )
    }

    private static func channelReferences(from values: [Int]) -> [DicomWaveformChannelReference] {
        waveformReferences(values)
    }

    static func splitSamples(
        _ raw: Data,
        interpretation: DicomWaveformSampleInterpretation,
        channelCount: Int,
        sampleCount: Int
    ) throws -> [[Int]] {
        let expectedBytes = channelCount * sampleCount * interpretation.bytesPerSample
        let hasRequiredPadding = expectedBytes.isMultiple(of: 2) == false &&
            raw.count == expectedBytes + 1 && raw.last == 0
        guard raw.count == expectedBytes || hasRequiredPadding else {
            throw DicomWaveformError.invalidWaveformData(expectedBytes: expectedBytes, actualBytes: raw.count)
        }
        var channels = Array(repeating: [Int](), count: channelCount)
        for index in channels.indices {
            channels[index].reserveCapacity(sampleCount)
        }

        for sampleIndex in 0..<sampleCount {
            for channelIndex in 0..<channelCount {
                let flatIndex = (sampleIndex * channelCount + channelIndex) * interpretation.bytesPerSample
                channels[channelIndex].append(sample(at: flatIndex, in: raw, interpretation: interpretation))
            }
        }
        return channels
    }

    static func sample(
        at offset: Int,
        in data: Data,
        interpretation: DicomWaveformSampleInterpretation
    ) -> Int {
        switch interpretation {
        case .signed8:
            return Int(Int8(bitPattern: data[offset]))
        case .unsigned8, .muLaw8, .aLaw8:
            return Int(data[offset])
        case .signed16:
            return Int(Int16(bitPattern: data.readUInt16(at: offset)))
        case .unsigned16:
            return Int(data.readUInt16(at: offset))
        case .signed32:
            return Int(Int32(bitPattern: data.readUInt32(at: offset)))
        case .unsigned32:
            return Int(data.readUInt32(at: offset))
        }
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
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func readUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) |
            UInt32(self[offset + 1]) << 8 |
            UInt32(self[offset + 2]) << 16 |
            UInt32(self[offset + 3]) << 24
    }
}

extension DicomWaveformBuildOptions {
    public static func preservingClinicalContext(
        from decoder: DCMDecoder,
        kind: DicomWaveformStorageKind = .twelveLeadECG,
        sopInstanceUID: String? = nil,
        seriesDescription: String? = "Waveform"
    ) -> DicomWaveformBuildOptions {
        DicomWaveformBuildOptions(
            kind: kind,
            sopInstanceUID: sopInstanceUID,
            studyInstanceUID: decoder.info(for: .studyInstanceUID),
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID),
            patientName: decoder.info(for: .patientName),
            patientID: decoder.info(for: .patientID),
            studyID: decoder.info(for: .studyID),
            studyDate: decoder.info(for: .studyDate),
            studyTime: decoder.info(for: .studyTime),
            seriesNumber: decoder.intValue(for: .seriesNumber),
            instanceNumber: 1,
            seriesDate: decoder.info(for: .seriesDate),
            seriesTime: decoder.info(for: .seriesTime),
            seriesDescription: seriesDescription,
            modality: kind.defaultModality
        )
    }
}
