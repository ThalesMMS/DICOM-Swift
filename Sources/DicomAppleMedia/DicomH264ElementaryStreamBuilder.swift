import CoreMedia
import Foundation

/// Builds an H.264 Annex-B elementary stream from a CoreMedia format description and AVCC samples.
public struct DicomH264ElementaryStreamBuilder: Sendable {
    /// The accumulated Annex-B stream, including parameter sets and appended sample NAL units.
    public private(set) var data: Data

    private let nalUnitHeaderLength: Int

    /// Creates a builder and prefixes its stream with every H.264 parameter set in CoreMedia order.
    ///
    /// - Parameter formatDescription: An H.264 format description containing SPS and PPS parameter sets.
    /// - Throws: ``DicomH264ElementaryStreamError`` when the description is not H.264 or its parameter-set
    ///   metadata is incomplete.
    public init(formatDescription: CMFormatDescription) throws {
        guard CMFormatDescriptionGetMediaSubType(formatDescription) == kCMVideoCodecType_H264 else {
            throw DicomH264ElementaryStreamError.unsupportedFormat
        }

        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var parameterSetCount = 0
        var headerLength: Int32 = 0
        let firstStatus = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard firstStatus == noErr, parameterSetCount > 0 else {
            throw DicomH264ElementaryStreamError.missingParameterSets
        }

        let nalUnitHeaderLength = Int(headerLength)
        guard (1...4).contains(nalUnitHeaderLength) else {
            throw DicomH264ElementaryStreamError.invalidNALUnitHeaderLength(nalUnitHeaderLength)
        }

        var parameterSets: [Data] = []
        parameterSets.reserveCapacity(parameterSetCount)
        var hasSequenceParameterSet = false
        var hasPictureParameterSet = false
        for index in 0..<parameterSetCount {
            pointer = nil
            size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer, size > 0 else {
                throw DicomH264ElementaryStreamError.missingParameterSets
            }

            let parameterSet = Data(bytes: pointer, count: size)
            switch parameterSet[parameterSet.startIndex] & 0x1F {
            case 7:
                hasSequenceParameterSet = true
            case 8:
                hasPictureParameterSet = true
            default:
                break
            }
            parameterSets.append(parameterSet)
        }
        guard hasSequenceParameterSet, hasPictureParameterSet else {
            throw DicomH264ElementaryStreamError.missingParameterSets
        }

        var data = Data()
        for parameterSet in parameterSets {
            data.append(contentsOf: Self.annexBStartCode)
            data.append(parameterSet)
        }
        self.data = data
        self.nalUnitHeaderLength = nalUnitHeaderLength
    }

    /// Appends every NAL unit in one AVCC sample using four-byte Annex-B start codes.
    ///
    /// The receiver is changed only after the complete sample has been validated and converted.
    ///
    /// - Parameter sample: An AVCC sample whose big-endian NAL length prefixes match the format description.
    /// - Throws: ``DicomH264ElementaryStreamError`` when the sample contains a zero-length, truncated, or
    ///   incomplete NAL unit.
    public mutating func append(lengthPrefixedSample sample: Data, maximumOutputBytes: Int = .max) throws {
        let nalUnitRanges = try nalUnitRanges(in: sample)
        var convertedSize = 0
        for range in nalUnitRanges {
            let (nalUnitSize, additionOverflow) = range.count.addingReportingOverflow(Self.annexBStartCode.count)
            let (newSize, totalOverflow) = convertedSize.addingReportingOverflow(nalUnitSize)
            guard !additionOverflow, !totalOverflow else {
                throw DicomH264ElementaryStreamError.outputLimitExceeded(limit: maximumOutputBytes)
            }
            convertedSize = newSize
        }
        let (projectedSize, projectedOverflow) = data.count.addingReportingOverflow(convertedSize)
        guard maximumOutputBytes >= 0, !projectedOverflow, projectedSize <= maximumOutputBytes else {
            throw DicomH264ElementaryStreamError.outputLimitExceeded(limit: maximumOutputBytes)
        }

        var converted = Data()
        converted.reserveCapacity(convertedSize)
        for range in nalUnitRanges {
            converted.append(contentsOf: Self.annexBStartCode)
            converted.append(sample[range])
        }
        data.append(converted)
    }

    private func nalUnitRanges(in sample: Data) throws -> [Range<Data.Index>] {
        var ranges: [Range<Data.Index>] = []
        var offset = sample.startIndex
        while offset < sample.endIndex {
            let prefixBytes = sample.endIndex - offset
            guard prefixBytes >= nalUnitHeaderLength else {
                throw DicomH264ElementaryStreamError.trailingLengthPrefix(byteCount: prefixBytes)
            }

            var nalUnitLength = 0
            for byte in sample[offset..<(offset + nalUnitHeaderLength)] {
                nalUnitLength = (nalUnitLength << 8) | Int(byte)
            }
            offset += nalUnitHeaderLength
            guard nalUnitLength > 0 else {
                throw DicomH264ElementaryStreamError.zeroLengthNALUnit
            }

            let availableBytes = sample.endIndex - offset
            guard nalUnitLength <= availableBytes else {
                throw DicomH264ElementaryStreamError.truncatedNALUnit(
                    declaredLength: nalUnitLength,
                    availableBytes: availableBytes
                )
            }

            ranges.append(offset..<(offset + nalUnitLength))
            offset += nalUnitLength
        }
        return ranges
    }

    private static let annexBStartCode: [UInt8] = [0, 0, 0, 1]
}
