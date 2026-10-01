import Foundation
import DicomData

public struct DicomWaveformAnnotation: Equatable, Sendable {
    public enum TemporalRangeType: String, CaseIterable, Sendable {
        case point = "POINT", multipoint = "MULTIPOINT", segment = "SEGMENT"
        case multisegment = "MULTISEGMENT", begin = "BEGIN", end = "END"
    }
    public var referencedChannels: [DicomWaveformChannelReference]
    public var groupNumber: Int?
    public var text: String?
    public var conceptName: DicomCodedConcept?
    public var conceptCode: DicomCodedConcept?
    public var conceptNameModifiers: [DicomCodedConcept]
    public var conceptCodeModifiers: [DicomCodedConcept]
    public var numericValues: [Double]
    public var measurementUnits: DicomCodedConcept?
    public var temporalRangeType: TemporalRangeType?
    public var referencedSamplePositions: [Int]
    public var referencedTimeOffsets: [Double]
    public var referencedDateTimes: [String]

    public init(referencedChannels: [DicomWaveformChannelReference], groupNumber: Int? = nil,
                text: String? = nil, conceptName: DicomCodedConcept? = nil, conceptCode: DicomCodedConcept? = nil,
                conceptNameModifiers: [DicomCodedConcept] = [], conceptCodeModifiers: [DicomCodedConcept] = [],
                numericValues: [Double] = [], measurementUnits: DicomCodedConcept? = nil,
                temporalRangeType: TemporalRangeType? = nil, referencedSamplePositions: [Int] = [],
                referencedTimeOffsets: [Double] = [], referencedDateTimes: [String] = []) {
        self.referencedChannels = referencedChannels
        self.groupNumber = groupNumber
        self.text = text
        self.conceptName = conceptName
        self.conceptCode = conceptCode
        self.conceptNameModifiers = conceptNameModifiers
        self.conceptCodeModifiers = conceptCodeModifiers
        self.numericValues = numericValues
        self.measurementUnits = measurementUnits
        self.temporalRangeType = temporalRangeType
        self.referencedSamplePositions = referencedSamplePositions
        self.referencedTimeOffsets = referencedTimeOffsets
        self.referencedDateTimes = referencedDateTimes
    }

    package init(dataSet ds: DicomDataSet) {
        func code(_ tag: Int) -> DicomCodedConcept? {
            ds.sequenceItems(for: tag).first.flatMap { DicomCodedConcept(dataSet: $0.dataSet) }
        }
        func modifiers(_ tag: Int) -> [DicomCodedConcept] {
            ds.sequenceItems(for: tag).first?.dataSet.sequenceItems(for: 0x0040A195)
                .compactMap { DicomCodedConcept(dataSet: $0.dataSet) } ?? []
        }
        self.init(referencedChannels: waveformReferences(ds.ints(for: 0x0040A0B0)),
                  groupNumber: ds.int(for: 0x0040A180), text: ds.string(for: 0x00700006),
                  conceptName: code(0x0040A043), conceptCode: code(0x0040A168),
                  conceptNameModifiers: modifiers(0x0040A043), conceptCodeModifiers: modifiers(0x0040A168),
                  numericValues: ds.floats(for: 0x0040A30A), measurementUnits: code(0x004008EA),
                  temporalRangeType: ds.string(for: 0x0040A130).flatMap(TemporalRangeType.init(rawValue:)),
                  referencedSamplePositions: ds.ints(for: 0x0040A132),
                  referencedTimeOffsets: ds.floats(for: 0x0040A138), referencedDateTimes: ds.strings(for: 0x0040A13A))
    }

    package var dataSet: DicomDataSet {
        var e = [waveformReferenceElement(referencedChannels)]
        if let groupNumber { e.append(.init(tag: 0x0040A180, vr: .US, value: .unsignedIntegers([UInt(clamping: groupNumber)]))) }
        if let text { e.append(.init(tag: 0x00700006, vr: .ST, value: .strings([text]))) }
        for (tag, concept, modifiers) in [(0x0040A043, conceptName, conceptNameModifiers),
                                         (0x0040A168, conceptCode, conceptCodeModifiers), (0x004008EA, measurementUnits, [])] {
            if let concept { e.append(waveformSequence(tag, [waveformCode(concept, modifiers: modifiers)])) }
        }
        if !numericValues.isEmpty { e.append(.init(tag: 0x0040A30A, vr: .DS, value: .strings(numericValues.map(waveformDecimalString)))) }
        if let temporalRangeType { e.append(.init(tag: 0x0040A130, vr: .CS, value: .strings([temporalRangeType.rawValue]))) }
        if !referencedSamplePositions.isEmpty {
            e.append(.init(tag: 0x0040A132, vr: .UL, value: .unsignedIntegers(referencedSamplePositions.map { UInt(clamping: $0) })))
        }
        if !referencedTimeOffsets.isEmpty { e.append(.init(tag: 0x0040A138, vr: .DS, value: .strings(referencedTimeOffsets.map(waveformDecimalString)))) }
        if !referencedDateTimes.isEmpty { e.append(.init(tag: 0x0040A13A, vr: .DT, value: .strings(referencedDateTimes))) }
        return .init(elements: e)
    }
}

package func waveformDecimalString(_ value: Double) -> String {
    var text = String(value)
    for precision in stride(from: 15, through: 9, by: -1) where text.utf8.count > 16 {
        text = String(format: "%.*g", precision, value)
    }
    return text
}

package func waveformReferences(_ values: [Int]) -> [DicomWaveformChannelReference] {
    stride(from: 0, to: values.count - values.count % 2, by: 2).map {
        .init(multiplexGroupNumber: values[$0], channel: values[$0 + 1] == 0 ? .all : .channel(values[$0 + 1]))
    }
}

package func waveformReferenceElement(_ references: [DicomWaveformChannelReference]) -> DicomDataElement {
    .init(tag: 0x0040A0B0, vr: .US, value: .unsignedIntegers(references.flatMap {
        [UInt(clamping: $0.multiplexGroupNumber), UInt(clamping: $0.channelNumber)]
    }))
}

package func waveformSequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
    .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
}

package func waveformCode(_ code: DicomCodedConcept, modifiers: [DicomCodedConcept] = []) -> DicomDataSet {
    var e: [DicomDataElement] = [
        .init(tag: 0x00080100, vr: .SH, value: .strings([code.codeValue])),
        .init(tag: 0x00080102, vr: .SH, value: .strings([code.codingSchemeDesignator]))
    ]
    if let meaning = code.codeMeaning { e.append(.init(tag: 0x00080104, vr: .LO, value: .strings([meaning]))) }
    if let version = code.codingSchemeVersion { e.append(.init(tag: 0x00080103, vr: .SH, value: .strings([version]))) }
    if !modifiers.isEmpty { e.append(waveformSequence(0x0040A195, modifiers.map { waveformCode($0) })) }
    return .init(elements: e)
}
