import Foundation
import DicomObjects

/// PHI-free diagnostic: ordinals and stable codes only; never annotation text or dates.
public struct DicomWaveformDiagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        case unknownGroup, unknownChannel, samplePositionOutOfRange, temporalMismatch
        case invalidAnnotationContent
    }
    public let code: Code
    public let annotationIndex: Int

    public static func evaluate(_ waveform: DicomWaveform) -> [Self] {
        evaluate(annotations: waveform.annotations, groups: waveform.multiplexGroups.map { ($0.numberOfChannels, $0.numberOfSamples) })
    }

    static func evaluate(annotations: [DicomWaveformAnnotation], groups: [(channels: Int, samples: Int)]) -> [Self] {
        var result: [Self] = []
        for (index, annotation) in annotations.enumerated() {
            var codes: [Code] = []
            for reference in annotation.referencedChannels {
                guard reference.multiplexGroupNumber > 0, reference.multiplexGroupNumber <= groups.count else {
                    codes.append(.unknownGroup); continue
                }
                let group = groups[reference.multiplexGroupNumber - 1]
                if reference.channelNumber < 0 || reference.channelNumber > group.channels { codes.append(.unknownChannel) }
                if annotation.referencedSamplePositions.contains(where: { $0 < 1 || $0 > group.samples }) {
                    codes.append(.samplePositionOutOfRange)
                }
            }
            let counts = [annotation.referencedSamplePositions.count, annotation.referencedTimeOffsets.count, annotation.referencedDateTimes.count]
            let present = counts.filter { $0 > 0 }
            if let type = annotation.temporalRangeType {
                let validCount: Bool
                let count = present.first ?? 0
                switch type {
                case .point, .begin, .end: validCount = count == 1
                case .segment: validCount = count == 2
                case .multipoint: validCount = count >= 2
                case .multisegment: validCount = count >= 4 && count.isMultiple(of: 2)
                }
                if present.count != 1 || !validCount { codes.append(.temporalMismatch) }
                if !annotation.referencedSamplePositions.isEmpty,
                   Set(annotation.referencedChannels.map(\.multiplexGroupNumber)).count != 1 {
                    codes.append(.temporalMismatch)
                }
            } else if !present.isEmpty { codes.append(.temporalMismatch) }
            if annotation.referencedChannels.isEmpty || (annotation.text == nil) == (annotation.conceptName == nil)
                || (annotation.conceptCode != nil && !annotation.numericValues.isEmpty) {
                codes.append(.invalidAnnotationContent)
            }
            for code in codes where !result.contains(.init(code: code, annotationIndex: index)) {
                result.append(.init(code: code, annotationIndex: index))
            }
        }
        return result
    }
}

extension DicomWaveform {
    public var diagnostics: [DicomWaveformDiagnostic] { DicomWaveformDiagnostic.evaluate(self) }
}
