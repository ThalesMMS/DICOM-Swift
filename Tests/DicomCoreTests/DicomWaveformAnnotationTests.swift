import XCTest
@testable import DicomCore

final class DicomWaveformAnnotationTests: XCTestCase {
    func test_explicitChannelZero_isRejectedWhileAllChannelsRemainsValid() throws {
        let group = DicomWaveformMultiplexGroup(samplingFrequency: 500, channels: [.init(samples: [1])])
        let invalid = DicomWaveformAnnotation(referencedChannels: [.init(multiplexGroupNumber: 1, channel: .channel(0))])
        XCTAssertThrowsError(try DicomWaveformBuilder.part10Data(multiplexGroups: [group], annotations: [invalid])) {
            XCTAssertEqual($0 as? DicomWaveformError, .invalidChannelReference)
        }
        let all = DicomWaveformAnnotation(referencedChannels: [.init(multiplexGroupNumber: 1, channel: .all)])
        XCTAssertNoThrow(try DicomWaveformBuilder.part10Data(multiplexGroups: [group], annotations: [all]))
    }

    func test_annotationNonfiniteDecimals_areRejectedBeforeDataSetConstruction() {
        let group = DicomWaveformMultiplexGroup(samplingFrequency: 500, channels: [.init(samples: [1])])
        for value in [Double.nan, .infinity, -.infinity] {
            for annotation in [
                DicomWaveformAnnotation(referencedChannels: [], numericValues: [value]),
                DicomWaveformAnnotation(referencedChannels: [], referencedTimeOffsets: [value])
            ] {
                XCTAssertThrowsError(try DicomWaveformBuilder.dataSet(multiplexGroups: [group], annotations: [annotation]))
            }
        }
    }

    func test_annotationsDisplayAndPadding_roundTrip() throws {
        let code = DicomCodedConcept(codeValue: "1", codingSchemeDesignator: "99TEST", codeMeaning: "Test", codingSchemeVersion: "1")
        let reference = DicomWaveformChannelReference(multiplexGroupNumber: 1, channel: .all)
        let annotations = DicomWaveformAnnotation.TemporalRangeType.allCases.map { type in
            let count: Int
            switch type {
            case .point, .begin, .end: count = 1
            case .multipoint, .segment: count = 2
            case .multisegment: count = 4
            }
            return DicomWaveformAnnotation(referencedChannels: [reference], groupNumber: 7,
                conceptName: code, conceptCode: code, conceptNameModifiers: [code], conceptCodeModifiers: [code],
                temporalRangeType: type, referencedSamplePositions: Array(1...count))
        } + [DicomWaveformAnnotation(referencedChannels: [reference], text: "Annotation"),
             DicomWaveformAnnotation(referencedChannels: [reference], conceptName: code, numericValues: [1, 2],
                measurementUnits: code, temporalRangeType: .segment, referencedTimeOffsets: [0, 0.1]),
             DicomWaveformAnnotation(referencedChannels: [reference], conceptName: code, temporalRangeType: .point,
                referencedDateTimes: ["20260910120000"])]
        let padding = try DicomWaveformSampleValue(rawValue: -32768, interpretation: .signed16)
        let channel = DicomWaveformChannel(sensitivity: 2, sensitivityCorrectionFactor: 3, baseline: 4,
            minimumValue: try .init(rawValue: -100, interpretation: .signed16),
            maximumValue: try .init(rawValue: 100, interpretation: .signed16), samples: [1, -32768, 3, 4])
        let group = DicomWaveformMultiplexGroup(samplingFrequency: 500, paddingValue: padding, channels: [channel])
        let color = DicomWaveformDisplayScale.CIELab(l: 1, a: 2, b: 3)
        let display = DicomWaveformDisplayScale(millimetersPerSecond: 25, background: color, presentationGroups: [
            .init(number: 1, channels: [.init(reference: .init(multiplexGroupNumber: 1, channel: .channel(1)),
                offset: 0.125, color: color, position: 0.5, shading: .baseline, fractionalScale: -0.25, absoluteScale: 2)])])
        let bytes = try DicomWaveformBuilder.part10Data(multiplexGroups: [group], annotations: annotations, displayScale: display)
        let decoder = try DCMDecoder(data: bytes)
        let parsed = try XCTUnwrap(decoder.waveform)
        XCTAssertEqual(parsed.annotations, annotations)
        XCTAssertEqual(parsed.displayScale, display)
        XCTAssertEqual(parsed.multiplexGroups[0].paddingValue, padding)
        XCTAssertEqual(parsed.multiplexGroups[0].channels[0].minimumValue, channel.minimumValue)
        XCTAssertEqual(parsed.multiplexGroups[0].channels[0].maximumValue, channel.maximumValue)
        XCTAssertEqual(parsed.multiplexGroups[0].channels[0].physicalSamples(), [10, nil, 22, 28])
        XCTAssertEqual(parsed.diagnostics, [])
        let dataSet = try DicomWaveformBuilder.dataSet(multiplexGroups: [group], annotations: annotations, displayScale: display)
        let implicit = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .implicitVRLittleEndian))
        let implicitWaveform = try XCTUnwrap(DCMDecoder(data: implicit).waveform)
        XCTAssertEqual(implicitWaveform.annotations, annotations)
        XCTAssertEqual(implicitWaveform.displayScale, display)
        XCTAssertEqual(implicitWaveform.multiplexGroups[0].channels[0].physicalSamples(), [10, nil, 22, 28])
        XCTAssertNil(decoder.dataSet.sequenceItems(for: .waveformSequence).first?.dataSet.element(for: .waveformDataDisplayScale))
    }

    func test_displayOffset_usesBoundedDecimalString() throws {
        let group = DicomWaveformMultiplexGroup(samplingFrequency: 500, channels: [.init(samples: [1])])
        for offset in [0.1 + 0.2, -1.234567890123456e-123, 1.234567890123456e123] {
            let display = DicomWaveformDisplayScale(presentationGroups: [.init(number: 1, channels: [
                .init(reference: .init(multiplexGroupNumber: 1, channel: .channel(1)), offset: offset,
                      color: .init(l: 1, a: 2, b: 3), position: 0.5)
            ])])
            let data = try DicomWaveformBuilder.dataSet(multiplexGroups: [group], displayScale: display)
            let channel = try XCTUnwrap(data.sequenceItems(for: 0x003A0240).first?.dataSet
                .sequenceItems(for: 0x003A0242).first?.dataSet)
            let text = try XCTUnwrap(channel.string(for: 0x003A0218))
            XCTAssertLessThanOrEqual(text.utf8.count, 16)
            XCTAssertEqual(try XCTUnwrap(Double(text)) / offset, 1, accuracy: 1e-8)
        }
    }

    func test_nonfiniteDisplayOffset_isOmittedWithoutLosingChannelPresentation() throws {
        let group = DicomWaveformMultiplexGroup(samplingFrequency: 500, channels: [.init(samples: [1])])
        for offset in [Double.nan, .infinity, -.infinity] {
            let display = DicomWaveformDisplayScale(presentationGroups: [.init(number: 1, channels: [
                .init(reference: .init(multiplexGroupNumber: 1, channel: .channel(1)), offset: offset,
                      color: .init(l: 1, a: 2, b: 3), position: 0.5)
            ])])
            let data = try DicomWaveformBuilder.dataSet(multiplexGroups: [group], displayScale: display)
            let channel = try XCTUnwrap(data.sequenceItems(for: 0x003A0240).first?.dataSet
                .sequenceItems(for: 0x003A0242).first?.dataSet)
            XCTAssertFalse(channel.contains(0x003A0218))
            XCTAssertEqual(channel.ints(for: 0x003A0244), [1, 2, 3])
            XCTAssertEqual(channel.float(for: 0x003A0245), 0.5)
        }
    }

    func test_annotationDecimals_roundTripWithinDSByteLimit() throws {
        let group = DicomWaveformMultiplexGroup(samplingFrequency: 500, channels: [.init(samples: [1])])
        let code = DicomCodedConcept(codeValue: "1", codingSchemeDesignator: "99TEST", codeMeaning: "Test")
        let values = [0.1 + 0.2, -1.234567890123456e-123, 1.234567890123456e123]
        let annotation = DicomWaveformAnnotation(referencedChannels: [.init(multiplexGroupNumber: 1, channel: .all)],
            conceptName: code, numericValues: values, measurementUnits: code,
            temporalRangeType: .multipoint, referencedTimeOffsets: values.map(abs))
        let data = try DicomWaveformBuilder.dataSet(multiplexGroups: [group], annotations: [annotation])
        let item = try XCTUnwrap(data.sequenceItems(for: .waveformAnnotationSequence).first?.dataSet)
        for tag in [0x0040A30A, 0x0040A138] {
            XCTAssertEqual(item.strings(for: tag).count, values.count)
            XCTAssertTrue(item.strings(for: tag).allSatisfy { $0.utf8.count <= 16 })
        }
        let bytes = try DicomDataSetWriter.part10Data(from: data)
        let parsed = try XCTUnwrap(DCMDecoder(data: bytes).waveform?.annotations.first)
        for (actual, expected) in zip(parsed.numericValues, values) {
            XCTAssertEqual(actual / expected, 1, accuracy: 1e-8)
        }
        for (actual, expected) in zip(parsed.referencedTimeOffsets, values.map(abs)) {
            XCTAssertEqual(actual / expected, 1, accuracy: 1e-8)
        }
    }

    func test_badReferencesAndTemporalCounts_reportOnlyTypedOrdinals() {
        let group = DicomWaveformMultiplexGroup(samplingFrequency: 100, channels: [.init(samples: [1, 2])])
        let annotations: [DicomWaveformAnnotation] = [
            .init(referencedChannels: [.init(multiplexGroupNumber: 2, channel: .all)], text: "private"),
            .init(referencedChannels: [.init(multiplexGroupNumber: 1, channel: .channel(2))], text: "private"),
            .init(referencedChannels: [.init(multiplexGroupNumber: 1, channel: .all)], text: "private",
                  temporalRangeType: .segment, referencedSamplePositions: [3])]
        let waveform = DicomWaveform(sopClassUID: DicomWaveform.generalECGWaveformStorageSOPClassUID, multiplexGroups: [group], annotations: annotations)
        XCTAssertEqual(waveform.diagnostics.map(\.code), [.unknownGroup, .unknownChannel, .samplePositionOutOfRange, .temporalMismatch])
        XCTAssertFalse(String(describing: waveform.diagnostics).contains("private"))
        XCTAssertThrowsError(try DicomWaveformBuilder.part10Data(multiplexGroups: [group], annotations: [
            .init(referencedChannels: [.init(multiplexGroupNumber: -1, channel: .all)], text: "Event")])) {
            XCTAssertEqual($0 as? DicomWaveformError, .invalidChannelReference)
        }
    }

    func test_g711_referencePairsAndIndependentCompanders() throws {
        let mu = DicomWaveformSampleInterpretation.muLaw8
        let a = DicomWaveformSampleInterpretation.aLaw8
        for (byte, value) in [(255, 0), (127, 0), (0, -32124), (128, 32124), (254, 8), (126, -8)] {
            XCTAssertEqual(mu.linearPCM16(from: byte), Int16(value))
        }
        for (byte, value) in [(128, 8), (0, -8), (255, 32256), (127, -32256), (144, 264)] {
            XCTAssertEqual(a.linearPCM16(from: byte), Int16(value))
        }
        // Independent encoders locate the G.711 segment from the linear magnitude.
        func compactMu(_ pcm: Int) -> Int {
            let mask = pcm < 0 ? 0x7F : 0xFF
            let magnitude = min(abs(pcm), 32635) + 132
            var segment = 0
            while segment < 7 && magnitude > (255 << segment) { segment += 1 }
            return ((segment << 4) | ((magnitude >> (segment + 3)) & 15)) ^ mask
        }
        func compactA(_ pcm: Int) -> Int {
            let magnitude = pcm < 0 ? -pcm - 1 : pcm
            var segment = 0
            while segment < 7 && magnitude >= (256 << segment) { segment += 1 }
            return (pcm < 0 ? 0 : 128) | (segment << 4) | ((magnitude >> (segment == 0 ? 4 : segment + 3)) & 15)
        }
        for byte in 0...255 {
            let muValue = Int(try XCTUnwrap(mu.linearPCM16(from: byte)))
            XCTAssertEqual(mu.linearPCM16(from: compactMu(muValue)), Int16(muValue))
            let aValue = Int(try XCTUnwrap(a.linearPCM16(from: byte)))
            XCTAssertEqual(compactA(aValue), byte)
        }
        XCTAssertNil(mu.linearPCM16(from: -1))
        XCTAssertNil(DicomWaveformSampleInterpretation.signed16.linearPCM16(from: 1))
    }
}
