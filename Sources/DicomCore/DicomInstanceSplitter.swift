//
//  DicomInstanceSplitter.swift
//
//  Splits a multi-frame instance into single-frame instances: Enhanced/Legacy Converted CT/MR through the
//  qualified converter, multi-frame Secondary Capture frame by frame with native or encapsulated pixels kept.
//

import Foundation

/// One derived single-frame instance per source frame, each carrying a Source Image Sequence reference to the
/// source instance and frame, a new SOP Instance UID and a new Series Instance UID shared by the set.
public struct DicomInstanceSplitter: Sendable {
    public static let secondaryCaptureSOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    static let multiframeSecondaryCaptureSOPClassUIDs: Set<String> = [
        "1.2.840.10008.5.1.4.1.1.7.1", "1.2.840.10008.5.1.4.1.1.7.2", "1.2.840.10008.5.1.4.1.1.7.3", "1.2.840.10008.5.1.4.1.1.7.4"
    ]
    static let enhancedSOPClassUIDs: Set<String> = [
        "1.2.840.10008.5.1.4.1.1.2.1", "1.2.840.10008.5.1.4.1.1.4.1", DicomInstanceMerger.legacyConvertedCTSOPClassUID, DicomInstanceMerger.legacyConvertedMRSOPClassUID
    ]

    public typealias Identifiers = DicomEnhancedMultiframeConverter.Identifiers

    public struct Instance: Equatable, Sendable {
        public let sourceFrameNumber: Int
        public let instanceNumber: Int
        public let sopInstanceUID: String
        public let part10Data: Data
    }

    public struct Result: Equatable, Sendable {
        public let sourceSOPClassUID: String
        public let sourceSOPInstanceUID: String
        public let sopClassUID: String
        public let seriesInstanceUID: String
        public let instances: [Instance]
    }

    public enum SplitError: Error, Equatable, Sendable, CustomStringConvertible {
        case notPart10
        case unreadable(String)
        case unsupportedSOPClass(String)
        case singleFrame
        case unsupportedPixelStructure(String)
        case unsupportedTransferSyntax(String)
        case pixelDataSizeMismatch(expected: Int, actual: Int)
        case invalidIdentifiers(String)
        case converter(String)
        case roundTripFailed(frame: Int, reason: String)

        public var description: String {
            switch self {
            case .notPart10: return "input is not a Part 10 file"
            case .unreadable(let reason): return "input could not be decoded: \(reason)"
            case .unsupportedSOPClass(let uid): return "SOP Class \(uid) is not a splittable multi-frame class (Enhanced/Legacy Converted CT/MR, multi-frame Secondary Capture)"
            case .singleFrame: return "the instance has a single frame"
            case .unsupportedPixelStructure(let reason): return "unsupported pixel structure: \(reason)"
            case .unsupportedTransferSyntax(let uid): return "transfer syntax \(uid) cannot be split frame by frame"
            case .pixelDataSizeMismatch(let expected, let actual): return "Pixel Data carries \(actual) bytes, expected \(expected) for the declared frames"
            case .invalidIdentifiers(let reason): return "invalid identifiers: \(reason)"
            case .converter(let reason): return reason
            case .roundTripFailed(let frame, let reason): return "frame \(frame) failed verification: \(reason)"
            }
        }
    }

    public init() {}

    public func split(contentsOf url: URL, identifiers: Identifiers? = nil) throws -> Result {
        try split(try Data(contentsOf: url, options: .mappedIfSafe), identifiers: identifiers)
    }

    public func split(_ data: Data, identifiers: Identifiers? = nil) throws -> Result {
        guard DicomPart10FileMetaParser.hasPart10Prefix(data) else { throw SplitError.notPart10 }
        let decoder: DCMDecoder
        do { decoder = try DCMDecoder(data: data) } catch is CancellationError {
            throw CancellationError()
        } catch { throw SplitError.unreadable((error as? LocalizedError)?.errorDescription ?? "\(error)") }
        let sopClass = decoder.info(for: .sopClassUID)
        if Self.enhancedSOPClassUIDs.contains(sopClass) {
            do {
                let converted = try DicomEnhancedMultiframeConverter().convert(data, identifiers: identifiers)
                let outputSOPClass = converted.instances.first.flatMap { try? DicomPart10FileMetaParser.parse($0.part10Data).mediaStorageSOPClassUID } ?? ""
                return Result(sourceSOPClassUID: sopClass, sourceSOPInstanceUID: converted.sourceSOPInstanceUID, sopClassUID: outputSOPClass,
                              seriesInstanceUID: converted.seriesInstanceUID, instances: converted.instances.map {
                    Instance(sourceFrameNumber: $0.sourceFrameNumber, instanceNumber: $0.instanceNumber, sopInstanceUID: $0.sopInstanceUID, part10Data: $0.part10Data)
                })
            } catch let error as DicomEnhancedMultiframeConverter.ConversionError {
                throw SplitError.converter(error.errorDescription ?? "\(error)")
            }
        }
        guard Self.multiframeSecondaryCaptureSOPClassUIDs.contains(sopClass) else { throw SplitError.unsupportedSOPClass(sopClass) }
        return try splitSecondaryCapture(decoder: decoder, data: data, identifiers: identifiers)
    }

    private func splitSecondaryCapture(decoder: DCMDecoder, data: Data, identifiers: Identifiers?) throws -> Result {
        let source = try DicomPart10PixelDataPreserver.dataSet(from: decoder)
        let frameCount = max(decoder.nImages, source.int(for: .numberOfFrames) ?? 1)
        guard frameCount > 1 else { throw SplitError.singleFrame }
        let rows = source.int(for: .rows) ?? 0, columns = source.int(for: .columns) ?? 0
        let samples = source.int(for: .samplesPerPixel) ?? 1, bitsAllocated = source.int(for: .bitsAllocated) ?? 0
        guard rows > 0, columns > 0, [1, 8, 16].contains(bitsAllocated) else { throw SplitError.unsupportedPixelStructure("Rows/Columns/Bits Allocated") }
        guard let syntax = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID)) else { throw SplitError.unsupportedTransferSyntax(decoder.info(for: .transferSyntaxUID)) }
        let sourceSOPInstanceUID = decoder.info(for: .sopInstanceUID)
        let ids = try Self.validated(identifiers ?? Identifiers(seriesInstanceUID: DicomDataSetWriter.makeUID(), sopInstanceUIDs: (0..<frameCount).map { _ in DicomDataSetWriter.makeUID() }),
                                     frameCount: frameCount, source: source)
        // Frame payloads: native slices or encapsulated fragments per frame.
        var frames: [Data] = []
        var pixelVR: DicomVR = bitsAllocated > 8 ? .OW : .OB
        var outputSyntax: DicomTransferSyntax = syntax == .explicitVRBigEndian ? syntax : .explicitVRLittleEndian
        if decoder.compressedImage {
            guard let descriptor = decoder.encapsulatedPixelDataDescriptor else { throw SplitError.unsupportedPixelStructure("encapsulated Pixel Data could not be indexed") }
            let reader = try DicomEncapsulatedPixelFrameReader(descriptor: descriptor, fileData: decoder.dicomDataSnapshot())
            guard reader.frameCount == frameCount else { throw SplitError.pixelDataSizeMismatch(expected: frameCount, actual: reader.frameCount) }
            frames = try (0..<frameCount).map { Self.encapsulate(try reader.frame(at: $0).data) }
            pixelVR = .OB
            outputSyntax = syntax
        } else {
            guard let bytes = source.element(for: .pixelData)?.bytesValue else { throw SplitError.unsupportedPixelStructure("Pixel Data missing") }
            let bitsPerFrame = rows * columns * samples * bitsAllocated
            guard bitsPerFrame.isMultiple(of: 8) else { throw SplitError.unsupportedPixelStructure("single-bit frames that do not end on a byte boundary") }
            let frameBytes = bitsPerFrame / 8
            guard bytes.count == frameBytes * frameCount || bytes.count == frameBytes * frameCount + 1 else {
                throw SplitError.pixelDataSizeMismatch(expected: frameBytes * frameCount, actual: bytes.count)
            }
            frames = (0..<frameCount).map { Data(bytes[bytes.startIndex + $0 * frameBytes..<bytes.startIndex + ($0 + 1) * frameBytes]) }
        }
        var template = source
        [DicomTag.numberOfFrames.rawValue, DicomTag.frameIncrementPointer.rawValue, 0x0018_1063, 0x0018_1065, 0x0018_2001, 0x0018_2002,
         0x0018_2003, 0x0018_2004, 0x0018_2005, 0x0018_2006, 0x0028_6010, DicomTag.extendedOffsetTable.rawValue, DicomTag.extendedOffsetTableLengths.rawValue,
         DicomTag.pixelData.rawValue].forEach { template.remove($0) }
        let sliceLocations = source.decimalStrings(for: 0x0018_2005)
        func string(_ tag: DicomTag, _ vr: DicomVR, _ values: [String]) -> DicomDataElement { DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings(values)) }
        template.set(string(.sopClassUID, .UI, [Self.secondaryCaptureSOPClassUID]))
        template.set(string(.seriesInstanceUID, .UI, [ids.seriesInstanceUID]))
        template.set(string(.imageType, .CS, ["DERIVED", "SECONDARY"]))
        var instances: [Instance] = []
        for (index, payload) in frames.enumerated() {
            var dataSet = template
            let uid = ids.sopInstanceUIDs[index]
            dataSet.set(string(.sopInstanceUID, .UI, [uid]))
            dataSet.set(string(.instanceNumber, .IS, [String(index + 1)]))
            if sliceLocations.count == frameCount { dataSet.set(DicomDataElement(tag: 0x0020_1041, vr: .DS, value: .strings([DicomInstanceMerger.decimal(sliceLocations[index])]))) }
            dataSet.set(DicomDataElement(tag: DicomTag.sourceImageSequence.rawValue, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [
                string(.referencedSOPClassUID, .UI, [decoder.info(for: .sopClassUID)]), string(.referencedSOPInstanceUID, .UI, [sourceSOPInstanceUID]),
                string(.referencedFrameNumber, .IS, [String(index + 1)])
            ]))])))
            dataSet.set(string(.derivationDescription, .ST, ["Frame \(index + 1) of \(frameCount) extracted from a multi-frame instance"]))
            dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: pixelVR, value: .bytes(payload)))
            let part10: Data
            do {
                part10 = try DicomDataSetWriter.part10Data(from: dataSet, options: DicomPart10WriterOptions(
                    transferSyntax: outputSyntax, mediaStorageSOPClassUID: Self.secondaryCaptureSOPClassUID, mediaStorageSOPInstanceUID: uid))
            } catch { throw SplitError.roundTripFailed(frame: index + 1, reason: "write failed: \(error)") }
            try Self.verify(part10, frame: index + 1, uid: uid, payload: payload, encapsulated: decoder.compressedImage)
            instances.append(Instance(sourceFrameNumber: index + 1, instanceNumber: index + 1, sopInstanceUID: uid, part10Data: part10))
        }
        return Result(sourceSOPClassUID: decoder.info(for: .sopClassUID), sourceSOPInstanceUID: sourceSOPInstanceUID,
                      sopClassUID: Self.secondaryCaptureSOPClassUID, seriesInstanceUID: ids.seriesInstanceUID, instances: instances)
    }

    private static func validated(_ identifiers: Identifiers, frameCount: Int, source: DicomDataSet) throws -> Identifiers {
        guard identifiers.sopInstanceUIDs.count == frameCount else { throw SplitError.invalidIdentifiers("expected \(frameCount) SOP Instance UIDs") }
        let outputs = [identifiers.seriesInstanceUID] + identifiers.sopInstanceUIDs
        guard outputs.allSatisfy(DicomDataSetEditor.isValidUID) else { throw SplitError.invalidIdentifiers("malformed UID") }
        guard Set(outputs).count == outputs.count else { throw SplitError.invalidIdentifiers("output UIDs must be unique") }
        guard DicomDataSetEditor.uidValues(in: source).isDisjoint(with: outputs) else { throw SplitError.invalidIdentifiers("output UIDs must differ from the source identities") }
        return identifiers
    }

    /// Empty Basic Offset Table, one fragment (even length), sequence delimiter.
    public static func encapsulate(_ frame: Data) -> Data {
        var padded = frame
        if !padded.count.isMultiple(of: 2) { padded.append(0) }
        var data = Data([0xFE, 0xFF, 0x00, 0xE0, 0, 0, 0, 0, 0xFE, 0xFF, 0x00, 0xE0])
        withUnsafeBytes(of: UInt32(padded.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(padded)
        data.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
        return data
    }

    private static func verify(_ data: Data, frame: Int, uid: String, payload: Data, encapsulated: Bool) throws {
        let reopened: DCMDecoder
        do { reopened = try DCMDecoder(data: data) } catch is CancellationError {
            throw CancellationError()
        } catch { throw SplitError.roundTripFailed(frame: frame, reason: "reopen failed: \(error)") }
        guard reopened.info(for: .sopInstanceUID) == uid, reopened.info(for: 0x0002_0003) == uid, reopened.nImages == 1,
              reopened.info(for: .sopClassUID) == secondaryCaptureSOPClassUID, !reopened.dataSet.contains(.numberOfFrames) else {
            throw SplitError.roundTripFailed(frame: frame, reason: "identity or frame count did not round-trip")
        }
        let bytes = (try? DicomPart10PixelDataPreserver.dataSet(from: reopened))?.element(for: .pixelData)?.bytesValue
        if encapsulated {
            guard let descriptor = reopened.encapsulatedPixelDataDescriptor, let reader = try? DicomEncapsulatedPixelFrameReader(descriptor: descriptor, fileData: reopened.dicomDataSnapshot()),
                  reader.frameCount == 1, encapsulate((try? reader.frame(at: 0).data) ?? Data()) == payload else {
                throw SplitError.roundTripFailed(frame: frame, reason: "encapsulated frame did not round-trip")
            }
        } else {
            guard bytes == payload else { throw SplitError.roundTripFailed(frame: frame, reason: "pixel bytes did not round-trip") }
        }
        guard reopened.dataSet[.sourceImageSequence]?.sequenceItems.first?[.referencedFrameNumber]?.stringValue == String(frame) else {
            throw SplitError.roundTripFailed(frame: frame, reason: "provenance did not round-trip")
        }
    }
}
