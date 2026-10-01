import Foundation

/// Typed, bounded edits of native (uncompressed) pixel regions with derived-object metadata.
/// The edit never runs in place: it returns a new Part 10 object with a fresh SOP Instance UID,
/// `Image Type` value 1 set to `DERIVED`, a `Derivation Description` and a `Source Image Sequence`
/// pointing at the original. Compressed pixel data is refused; transcode to a native syntax first.
public struct DicomPixelEdit: Equatable, Sendable {
    public enum Intent: String, Codable, Equatable, Sendable {
        /// Pixels are replaced to remove burned-in information; the change is irreversible by design.
        case redaction
        /// Pixels are replaced for annotation or test purposes; the change is irreversible.
        case annotation
    }
    public struct Region: Codable, Equatable, Sendable {
        public var x: Int, y: Int, width: Int, height: Int
        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }
    public var region: Region
    /// Stored sample value written to every sample of the region (each channel for colour images).
    public var sample: Int
    /// Frames to edit; `nil` edits every frame.
    public var frames: [Int]?
    public var intent: Intent
    public var derivationDescription: String?

    public init(region: Region, sample: Int, frames: [Int]? = nil, intent: Intent = .redaction, derivationDescription: String? = nil) {
        self.region = region
        self.sample = sample
        self.frames = frames
        self.intent = intent
        self.derivationDescription = derivationDescription
    }
}

public struct DicomPixelEditReport: Codable, Equatable, Sendable {
    public let sourceSOPInstanceUID: String
    public let derivedSOPInstanceUID: String
    public let region: DicomPixelEdit.Region
    public let framesEdited: [Int]
    public let samplesChanged: Int
    public let samplesWritten: Int
    public let sample: Int
    public let intent: DicomPixelEdit.Intent
    public let bitsAllocated: Int
    public let samplesPerPixel: Int
    public let derivationDescription: String
}

public enum DicomPixelEditError: Error, Equatable, LocalizedError, Sendable {
    case compressedPixelData(transferSyntaxUID: String)
    case pixelDataUnavailable
    case regionOutOfBounds(columns: Int, rows: Int)
    case emptyRegion
    case frameOutOfRange(Int, frameCount: Int)
    case sampleOutOfRange(Int, bitsStored: Int, signed: Bool)
    case unsupportedLayout(bitsAllocated: Int, samplesPerPixel: Int)
    case missingSOPIdentity

    public var errorDescription: String? {
        switch self {
        case .compressedPixelData(let uid): return "Pixel data is encapsulated (\(uid)); transcode to a native transfer syntax before editing"
        case .pixelDataUnavailable: return "Pixel data is not available"
        case .regionOutOfBounds(let columns, let rows): return "Region exceeds the \(columns)x\(rows) frame"
        case .emptyRegion: return "Region is empty"
        case .frameOutOfRange(let frame, let count): return "Frame \(frame) is outside 0..<\(count)"
        case .sampleOutOfRange(let sample, let bits, let signed): return "Sample \(sample) does not fit \(signed ? "signed" : "unsigned") \(bits)-bit storage"
        case .unsupportedLayout(let bits, let spp): return "Unsupported pixel layout: \(bits) bits allocated, \(spp) samples per pixel"
        case .missingSOPIdentity: return "SOP Class/Instance UID missing; a derived object cannot reference its source"
        }
    }
}

public enum DicomPixelEditor {
    public struct Output: Equatable, Sendable {
        public let fileData: Data
        public let dataSet: DicomDataSet
        public let report: DicomPixelEditReport
    }

    /// Plans the edit without writing pixels: validates bounds, sample range and layout, and reports what would change.
    public static func plan(_ edit: DicomPixelEdit, part10 data: Data) throws -> DicomPixelEditReport {
        try perform(edit, part10: data, write: false).report
    }

    public static func apply(_ edit: DicomPixelEdit, part10 data: Data, makeUID: () -> String = DicomDataSetWriter.makeUID) throws -> Output {
        try perform(edit, part10: data, write: true, makeUID: makeUID)
    }

    private static func perform(_ edit: DicomPixelEdit, part10 data: Data, write: Bool,
                                makeUID: () -> String = DicomDataSetWriter.makeUID) throws -> Output {
        let decoder = try DCMDecoder(data: data)
        let transferSyntaxUID = decoder.dataSet.string(for: .transferSyntaxUID) ?? DicomTransferSyntax.explicitVRLittleEndian.rawValue
        guard !decoder.compressedImage, let transferSyntax = DicomTransferSyntax(uid: transferSyntaxUID),
              [.explicitVRLittleEndian, .implicitVRLittleEndian].contains(transferSyntax) else {
            throw DicomPixelEditError.compressedPixelData(transferSyntaxUID: transferSyntaxUID)
        }
        guard let descriptor = decoder.pixelDataDescriptor else { throw DicomPixelEditError.pixelDataUnavailable }
        var dataSet = try DicomPart10PixelDataPreserver.dataSet(from: decoder)
        guard case .bytes(var pixels)? = dataSet.element(for: .pixelData)?.value else { throw DicomPixelEditError.pixelDataUnavailable }
        let columns = descriptor.columns, rows = descriptor.rows
        let bytesPerSample = descriptor.bitsAllocated / 8
        guard [1, 2].contains(bytesPerSample), [1, 3].contains(descriptor.samplesPerPixel) else {
            throw DicomPixelEditError.unsupportedLayout(bitsAllocated: descriptor.bitsAllocated, samplesPerPixel: descriptor.samplesPerPixel)
        }
        let region = edit.region
        guard region.width > 0, region.height > 0 else { throw DicomPixelEditError.emptyRegion }
        guard region.x >= 0, region.y >= 0, region.x + region.width <= columns, region.y + region.height <= rows else {
            throw DicomPixelEditError.regionOutOfBounds(columns: columns, rows: rows)
        }
        let signed = descriptor.pixelRepresentation == 1
        let bitsStored = max(1, min(descriptor.bitsStored, descriptor.bitsAllocated))
        let lower = signed ? -(1 << (bitsStored - 1)) : 0
        let upper = signed ? (1 << (bitsStored - 1)) - 1 : (1 << bitsStored) - 1
        guard (lower...upper).contains(edit.sample) else {
            throw DicomPixelEditError.sampleOutOfRange(edit.sample, bitsStored: bitsStored, signed: signed)
        }
        let frameCount = max(1, descriptor.numberOfFrames)
        let frames = edit.frames ?? Array(0..<frameCount)
        for frame in frames where frame < 0 || frame >= frameCount { throw DicomPixelEditError.frameOutOfRange(frame, frameCount: frameCount) }
        guard let sopClass = dataSet.string(for: .sopClassUID), let sopInstance = dataSet.string(for: .sopInstanceUID),
              !sopClass.isEmpty, !sopInstance.isEmpty else { throw DicomPixelEditError.missingSOPIdentity }

        let raw = UInt16(truncatingIfNeeded: edit.sample)
        let bytesPerFrame = descriptor.bytesPerFrame
        let samplesPerPixel = descriptor.samplesPerPixel
        let planar = descriptor.planarConfiguration == 1 && samplesPerPixel == 3
        var changed = 0, written = 0
        for frame in frames.sorted() {
            let base = frame * bytesPerFrame
            for row in region.y..<(region.y + region.height) {
                for column in region.x..<(region.x + region.width) {
                    for channel in 0..<samplesPerPixel {
                        let sampleIndex = planar
                            ? channel * columns * rows + row * columns + column
                            : (row * columns + column) * samplesPerPixel + channel
                        let offset = base + sampleIndex * bytesPerSample
                        guard offset + bytesPerSample <= pixels.count else { throw DicomPixelEditError.pixelDataUnavailable }
                        written += 1
                        if bytesPerSample == 1 {
                            let value = UInt8(truncatingIfNeeded: raw)
                            if pixels[offset] != value { changed += 1; if write { pixels[offset] = value } }
                        } else {
                            let current = UInt16(pixels[offset]) | (UInt16(pixels[offset + 1]) << 8)
                            if current != raw {
                                changed += 1
                                if write { pixels[offset] = UInt8(raw & 0xFF); pixels[offset + 1] = UInt8(raw >> 8) }
                            }
                        }
                    }
                }
            }
        }
        let description = edit.derivationDescription ?? "Pixel region \(region.x),\(region.y) \(region.width)x\(region.height) replaced (\(edit.intent.rawValue))"
        var derivedUID = sopInstance
        if write {
            dataSet.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: bytesPerSample > 1 ? .OW : .OB, value: .bytes(pixels)))
            var imageType = dataSet.strings(for: .imageType)
            if imageType.isEmpty { imageType = ["DERIVED", "SECONDARY"] } else { imageType[0] = "DERIVED" }
            dataSet.set(DicomDataElement(tag: DicomTag.imageType.rawValue, vr: .CS, value: .strings(imageType)))
            dataSet.set(DicomDataElement(tag: 0x0008_2111, vr: .ST, value: .strings([String(description.prefix(1024))])))
            // A region edit does not prove that every burned-in annotation was removed.
            // Preserve the source status so de-identification still checks unverified pixels.
            // Regenerate first: the editor rewrites every occurrence of the old UID, and the Source Image
            // Sequence must keep pointing at the original object.
            let result = try DicomDataSetEditor.apply(DicomDataSetEdit(operations: [.regenerateUID(.instance)]), to: dataSet, makeUID: makeUID)
            dataSet = DicomDataSet(elements: result.dataSet.elements.filter { $0.group != 0x0002 })
            derivedUID = dataSet.string(for: .sopInstanceUID) ?? sopInstance
            let source = DicomDataSet(elements: [
                DicomDataElement(tag: 0x0008_1150, vr: .UI, value: .strings([sopClass])),
                DicomDataElement(tag: 0x0008_1155, vr: .UI, value: .strings([sopInstance])),
            ])
            dataSet.set(DicomDataElement(tag: 0x0008_2112, vr: .SQ, value: .sequence([DicomSequenceItem(dataSet: source)])))
        }
        let report = DicomPixelEditReport(sourceSOPInstanceUID: sopInstance, derivedSOPInstanceUID: derivedUID, region: region,
                                          framesEdited: frames.sorted(), samplesChanged: changed, samplesWritten: written, sample: edit.sample,
                                          intent: edit.intent, bitsAllocated: descriptor.bitsAllocated, samplesPerPixel: samplesPerPixel,
                                          derivationDescription: description)
        guard write else { return Output(fileData: Data(), dataSet: dataSet, report: report) }
        let fileData = try DicomDataSetWriter.part10Data(from: dataSet, options: DicomPart10WriterOptions(
            transferSyntax: transferSyntax, mediaStorageSOPClassUID: sopClass, mediaStorageSOPInstanceUID: derivedUID))
        return Output(fileData: fileData, dataSet: dataSet, report: report)
    }
}
