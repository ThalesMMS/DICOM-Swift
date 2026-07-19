import Foundation

public enum DicomVideoError: Error, Equatable, LocalizedError, Sendable {
    case emptyStream
    case invalidDimensions(columns: Int, rows: Int)
    case invalidNumberOfFrames(Int)
    case invalidFrameTiming
    case invalidFrameIndex(index: Int, frameCount: Int)
    case unsupportedTransferSyntax(String)
    case nativeFrameDecodeUnsupported(codec: String)
    case transcodingUnsupported(source: String, destination: String)
    case missingPixelData

    public var errorDescription: String? {
        switch self {
        case .emptyStream:
            return "Video Pixel Data stream must not be empty."
        case .invalidDimensions(let columns, let rows):
            return "Invalid video dimensions: \(columns)x\(rows)."
        case .invalidNumberOfFrames(let count):
            return "Invalid video frame count: \(count)."
        case .invalidFrameTiming:
            return "Video frame timing values must be positive finite numbers."
        case .invalidFrameIndex(let index, let frameCount):
            return "Invalid video frame \(index). Frame count is \(frameCount)."
        case .unsupportedTransferSyntax(let uid):
            return "Unsupported video transfer syntax: \(uid)."
        case .nativeFrameDecodeUnsupported(let codec):
            return "Native DICOM video frame decode is not implemented for \(codec)."
        case .transcodingUnsupported(let source, let destination):
            return "DICOM video transcoding from \(source) to \(destination) is not implemented."
        case .missingPixelData:
            return "Video DICOM object has no encapsulated Pixel Data."
        }
    }
}

public enum DicomVideoStorageKind: CaseIterable, Equatable, Hashable, Sendable {
    case endoscopic
    case microscopic
    case photographic

    public var storageSOPClassUID: String {
        switch self {
        case .endoscopic:
            return DicomVideo.videoEndoscopicImageStorageSOPClassUID
        case .microscopic:
            return DicomVideo.videoMicroscopicImageStorageSOPClassUID
        case .photographic:
            return DicomVideo.videoPhotographicImageStorageSOPClassUID
        }
    }

    public var defaultModality: String {
        switch self {
        case .endoscopic:
            return "ES"
        case .microscopic:
            return "GM"
        case .photographic:
            return "XC"
        }
    }

    public init?(storageSOPClassUID: String) {
        switch storageSOPClassUID.dicomVideoTrimmedValue {
        case DicomVideo.videoEndoscopicImageStorageSOPClassUID:
            self = .endoscopic
        case DicomVideo.videoMicroscopicImageStorageSOPClassUID:
            self = .microscopic
        case DicomVideo.videoPhotographicImageStorageSOPClassUID:
            self = .photographic
        default:
            return nil
        }
    }
}

public enum DicomVideoCodec: String, CaseIterable, Equatable, Hashable, Sendable {
    case mpeg2
    case h264
    case hevc
    case unknown

    public init(transferSyntax: DicomTransferSyntax?) {
        guard let transferSyntax else {
            self = .unknown
            return
        }
        switch transferSyntax {
        case .mpeg2MainProfileMainLevel,
             .mpeg2MainProfileMainLevelFragmentable,
             .mpeg2MainProfileHighLevel,
             .mpeg2MainProfileHighLevelFragmentable:
            self = .mpeg2
        case .mpeg4AVCH264HighProfileLevel41,
             .mpeg4AVCH264HighProfileLevel41Fragmentable,
             .mpeg4AVCH264BDCompatibleHighProfileLevel41,
             .mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable,
             .mpeg4AVCH264HighProfileLevel42For2DVideo,
             .mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable,
             .mpeg4AVCH264HighProfileLevel42For3DVideo,
             .mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable,
             .mpeg4AVCH264StereoHighProfileLevel42,
             .mpeg4AVCH264StereoHighProfileLevel42Fragmentable:
            self = .h264
        case .hevcH265MainProfileLevel51,
             .hevcH265Main10ProfileLevel51:
            self = .hevc
        default:
            self = .unknown
        }
    }

    public var displayName: String {
        switch self {
        case .mpeg2:
            return "MPEG-2"
        case .h264:
            return "H.264"
        case .hevc:
            return "H.265"
        case .unknown:
            return "Unknown"
        }
    }

    public var lossyCompressionMethod: String? {
        switch self {
        case .mpeg2:
            return "ISO_13818_2"
        case .h264:
            return "ISO_14496_10"
        case .hevc:
            return "ISO_23008_2"
        case .unknown:
            return nil
        }
    }
}

public struct DicomVideoPixelData: Equatable, Sendable {
    public let fragments: [Data]
    public let transferSyntax: DicomTransferSyntax
    public let columns: Int
    public let rows: Int
    public let numberOfFrames: Int
    public let samplesPerPixel: Int
    public let photometricInterpretation: String
    public let planarConfiguration: Int?
    public let bitsAllocated: Int
    public let bitsStored: Int
    public let highBit: Int
    public let pixelRepresentation: Int
    public let frameTimeMilliseconds: Double?
    public let frameTimeVectorMilliseconds: [Double]
    public let cineRate: Int?
    public let recommendedDisplayFrameRate: Int?

    public init(
        streamData: Data,
        transferSyntax: DicomTransferSyntax = .mpeg4AVCH264HighProfileLevel41,
        columns: Int,
        rows: Int,
        numberOfFrames: Int,
        samplesPerPixel: Int = 3,
        photometricInterpretation: String = "YBR_PARTIAL_420",
        planarConfiguration: Int? = 0,
        bitsAllocated: Int = 8,
        bitsStored: Int = 8,
        highBit: Int = 7,
        pixelRepresentation: Int = 0,
        frameTimeMilliseconds: Double? = nil,
        frameTimeVectorMilliseconds: [Double] = [],
        cineRate: Int? = nil,
        recommendedDisplayFrameRate: Int? = nil
    ) throws {
        try self.init(
            fragments: [streamData],
            transferSyntax: transferSyntax,
            columns: columns,
            rows: rows,
            numberOfFrames: numberOfFrames,
            samplesPerPixel: samplesPerPixel,
            photometricInterpretation: photometricInterpretation,
            planarConfiguration: planarConfiguration,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored,
            highBit: highBit,
            pixelRepresentation: pixelRepresentation,
            frameTimeMilliseconds: frameTimeMilliseconds,
            frameTimeVectorMilliseconds: frameTimeVectorMilliseconds,
            cineRate: cineRate,
            recommendedDisplayFrameRate: recommendedDisplayFrameRate
        )
    }

    public init(
        fragments: [Data],
        transferSyntax: DicomTransferSyntax = .mpeg4AVCH264HighProfileLevel41,
        columns: Int,
        rows: Int,
        numberOfFrames: Int,
        samplesPerPixel: Int = 3,
        photometricInterpretation: String = "YBR_PARTIAL_420",
        planarConfiguration: Int? = 0,
        bitsAllocated: Int = 8,
        bitsStored: Int = 8,
        highBit: Int = 7,
        pixelRepresentation: Int = 0,
        frameTimeMilliseconds: Double? = nil,
        frameTimeVectorMilliseconds: [Double] = [],
        cineRate: Int? = nil,
        recommendedDisplayFrameRate: Int? = nil
    ) throws {
        guard transferSyntax.isVideoTransferSyntax else {
            throw DicomVideoError.unsupportedTransferSyntax(transferSyntax.rawValue)
        }
        guard columns > 0, rows > 0 else {
            throw DicomVideoError.invalidDimensions(columns: columns, rows: rows)
        }
        guard numberOfFrames > 0 else {
            throw DicomVideoError.invalidNumberOfFrames(numberOfFrames)
        }
        guard !fragments.isEmpty, fragments.allSatisfy({ !$0.isEmpty }) else {
            throw DicomVideoError.emptyStream
        }
        if let frameTimeMilliseconds, (!frameTimeMilliseconds.isFinite || frameTimeMilliseconds <= 0) {
            throw DicomVideoError.invalidFrameTiming
        }
        if frameTimeVectorMilliseconds.contains(where: { !$0.isFinite || $0 <= 0 }) {
            throw DicomVideoError.invalidFrameTiming
        }

        self.fragments = fragments
        self.transferSyntax = transferSyntax
        self.columns = columns
        self.rows = rows
        self.numberOfFrames = numberOfFrames
        self.samplesPerPixel = samplesPerPixel
        self.photometricInterpretation = photometricInterpretation.dicomVideoNonEmptyValue ?? "YBR_PARTIAL_420"
        self.planarConfiguration = planarConfiguration
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.pixelRepresentation = pixelRepresentation
        self.frameTimeMilliseconds = frameTimeMilliseconds
        self.frameTimeVectorMilliseconds = frameTimeVectorMilliseconds
        self.cineRate = cineRate
        self.recommendedDisplayFrameRate = recommendedDisplayFrameRate
    }

    public var streamData: Data {
        fragments.reduce(into: Data()) { $0.append($1) }
    }

    public var codec: DicomVideoCodec {
        DicomVideoCodec(transferSyntax: transferSyntax)
    }
}

public struct DicomVideoBuildOptions: Equatable, Sendable {
    public var kind: DicomVideoStorageKind
    public var sopInstanceUID: String?
    public var studyInstanceUID: String?
    public var seriesInstanceUID: String?
    public var patientName: String?
    public var patientID: String?
    public var studyID: String?
    public var studyDate: String?
    public var studyTime: String?
    public var seriesNumber: Int?
    public var instanceNumber: Int?
    public var seriesDate: String?
    public var seriesTime: String?
    public var seriesDescription: String?
    public var contentDate: String?
    public var contentTime: String?
    public var modality: String?
    public var imageType: [String]
    public var sourceImageReferences: [DicomSourceImageReference]

    public init(
        kind: DicomVideoStorageKind = .endoscopic,
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        patientName: String? = nil,
        patientID: String? = nil,
        studyID: String? = nil,
        studyDate: String? = nil,
        studyTime: String? = nil,
        seriesNumber: Int? = nil,
        instanceNumber: Int? = nil,
        seriesDate: String? = nil,
        seriesTime: String? = nil,
        seriesDescription: String? = "Video",
        contentDate: String? = nil,
        contentTime: String? = nil,
        modality: String? = nil,
        imageType: [String] = ["ORIGINAL", "PRIMARY", "VIDEO"],
        sourceImageReferences: [DicomSourceImageReference] = []
    ) {
        self.kind = kind
        self.sopInstanceUID = sopInstanceUID?.dicomVideoNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomVideoNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomVideoNonEmptyValue
        self.patientName = patientName?.dicomVideoNonEmptyValue
        self.patientID = patientID?.dicomVideoNonEmptyValue
        self.studyID = studyID?.dicomVideoNonEmptyValue
        self.studyDate = studyDate?.dicomVideoNonEmptyValue
        self.studyTime = studyTime?.dicomVideoNonEmptyValue
        self.seriesNumber = seriesNumber
        self.instanceNumber = instanceNumber
        self.seriesDate = seriesDate?.dicomVideoNonEmptyValue
        self.seriesTime = seriesTime?.dicomVideoNonEmptyValue
        self.seriesDescription = seriesDescription?.dicomVideoNonEmptyValue
        self.contentDate = contentDate?.dicomVideoNonEmptyValue
        self.contentTime = contentTime?.dicomVideoNonEmptyValue
        self.modality = modality?.dicomVideoNonEmptyValue?.uppercased()
        self.imageType = imageType.map { $0.dicomVideoTrimmedValue.uppercased() }.filter { !$0.isEmpty }
        self.sourceImageReferences = sourceImageReferences.removingDuplicateVideoElements()
    }
}

public struct DicomVideo: Equatable, Sendable {
    public static let videoEndoscopicImageStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.77.1.1.1"
    public static let videoMicroscopicImageStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.77.1.2.1"
    public static let videoPhotographicImageStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.77.1.4.1"

    public static let supportedStorageSOPClassUIDs: Set<String> = [
        videoEndoscopicImageStorageSOPClassUID,
        videoMicroscopicImageStorageSOPClassUID,
        videoPhotographicImageStorageSOPClassUID
    ]

    public let sopClassUID: String
    public let sopInstanceUID: String?
    public let studyInstanceUID: String?
    public let seriesInstanceUID: String?
    public let modality: String?
    public let patientName: DicomPersonName?
    public let patientID: String?
    public let imageType: [String]
    public let transferSyntaxUID: String
    public let transferSyntax: DicomTransferSyntax?
    public let columns: Int
    public let rows: Int
    public let numberOfFrames: Int
    public let frameTimeMilliseconds: Double?
    public let frameTimeVectorMilliseconds: [Double]
    public let cineRate: Int?
    public let recommendedDisplayFrameRate: Int?
    public let lossyImageCompression: String?
    public let lossyImageCompressionRatio: Double?
    public let lossyImageCompressionMethod: String?
    public let sourceImageReferences: [DicomSourceImageReference]
    public let streamData: Data
    public let indexedFramePayloads: [Data]
    public let encapsulatedPixelDataDescriptor: DicomEncapsulatedPixelDataDescriptor

    public init(
        sopClassUID: String,
        sopInstanceUID: String? = nil,
        studyInstanceUID: String? = nil,
        seriesInstanceUID: String? = nil,
        modality: String? = nil,
        patientName: DicomPersonName? = nil,
        patientID: String? = nil,
        imageType: [String] = [],
        transferSyntaxUID: String,
        transferSyntax: DicomTransferSyntax?,
        columns: Int,
        rows: Int,
        numberOfFrames: Int,
        frameTimeMilliseconds: Double? = nil,
        frameTimeVectorMilliseconds: [Double] = [],
        cineRate: Int? = nil,
        recommendedDisplayFrameRate: Int? = nil,
        lossyImageCompression: String? = nil,
        lossyImageCompressionRatio: Double? = nil,
        lossyImageCompressionMethod: String? = nil,
        sourceImageReferences: [DicomSourceImageReference] = [],
        streamData: Data,
        indexedFramePayloads: [Data] = [],
        encapsulatedPixelDataDescriptor: DicomEncapsulatedPixelDataDescriptor
    ) {
        self.sopClassUID = sopClassUID.dicomVideoNonEmptyValue ?? sopClassUID
        self.sopInstanceUID = sopInstanceUID?.dicomVideoNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomVideoNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomVideoNonEmptyValue
        self.modality = modality?.dicomVideoNonEmptyValue?.uppercased()
        self.patientName = patientName
        self.patientID = patientID?.dicomVideoNonEmptyValue
        self.imageType = imageType.map { $0.dicomVideoTrimmedValue.uppercased() }.filter { !$0.isEmpty }
        self.transferSyntaxUID = transferSyntaxUID.dicomVideoNonEmptyValue ?? transferSyntaxUID
        self.transferSyntax = transferSyntax
        self.columns = columns
        self.rows = rows
        self.numberOfFrames = max(1, numberOfFrames)
        self.frameTimeMilliseconds = frameTimeMilliseconds
        self.frameTimeVectorMilliseconds = frameTimeVectorMilliseconds
        self.cineRate = cineRate
        self.recommendedDisplayFrameRate = recommendedDisplayFrameRate
        self.lossyImageCompression = lossyImageCompression?.dicomVideoNonEmptyValue
        self.lossyImageCompressionRatio = lossyImageCompressionRatio
        self.lossyImageCompressionMethod = lossyImageCompressionMethod?.dicomVideoNonEmptyValue
        self.sourceImageReferences = sourceImageReferences.removingDuplicateVideoElements()
        self.streamData = streamData
        self.indexedFramePayloads = indexedFramePayloads
        self.encapsulatedPixelDataDescriptor = encapsulatedPixelDataDescriptor
    }

    public var kind: DicomVideoStorageKind? {
        DicomVideoStorageKind(storageSOPClassUID: sopClassUID)
    }

    public var codec: DicomVideoCodec {
        DicomVideoCodec(transferSyntax: transferSyntax)
    }

    public var frameRate: Double? {
        if let recommendedDisplayFrameRate, recommendedDisplayFrameRate > 0 {
            return Double(recommendedDisplayFrameRate)
        }
        if let cineRate, cineRate > 0 {
            return Double(cineRate)
        }
        if let frameTimeMilliseconds, frameTimeMilliseconds > 0 {
            return 1000.0 / frameTimeMilliseconds
        }
        return nil
    }

    public var durationSeconds: Double? {
        if !frameTimeVectorMilliseconds.isEmpty {
            return frameTimeVectorMilliseconds.reduce(0, +) / 1000.0
        }
        if let frameTimeMilliseconds, frameTimeMilliseconds > 0 {
            return Double(numberOfFrames) * frameTimeMilliseconds / 1000.0
        }
        if let frameRate, frameRate > 0 {
            return Double(numberOfFrames) / frameRate
        }
        return nil
    }

    public func framePayload(at index: Int) -> Data? {
        guard indexedFramePayloads.indices.contains(index) else { return nil }
        return indexedFramePayloads[index]
    }

    public func encodedFramePayload(at index: Int) throws -> Data {
        guard index >= 0, index < numberOfFrames else {
            throw DicomVideoError.invalidFrameIndex(index: index, frameCount: numberOfFrames)
        }
        guard let payload = framePayload(at: index) else {
            throw DicomVideoError.nativeFrameDecodeUnsupported(codec: codec.displayName)
        }
        return payload
    }

    public func decodedFrame(at index: Int) throws -> Data {
        guard index >= 0, index < numberOfFrames else {
            throw DicomVideoError.invalidFrameIndex(index: index, frameCount: numberOfFrames)
        }
        throw DicomVideoError.nativeFrameDecodeUnsupported(codec: codec.displayName)
    }

    public func transcodeStream(to destination: DicomTransferSyntax) throws -> Data {
        if let transferSyntax, destination == transferSyntax {
            return streamData
        }
        throw DicomVideoError.transcodingUnsupported(
            source: transferSyntax?.rawValue ?? transferSyntaxUID,
            destination: destination.rawValue
        )
    }
}

public enum DicomVideoBuilder {
    public static func dataSet(
        video: DicomVideoPixelData,
        options: DicomVideoBuildOptions = DicomVideoBuildOptions()
    ) throws -> DicomDataSet {
        let now = currentDicomDateTime()
        let sopInstanceUID = options.sopInstanceUID ?? DicomDataSetWriter.makeUID()
        let studyInstanceUID = options.studyInstanceUID ?? DicomDataSetWriter.makeUID()
        let seriesInstanceUID = options.seriesInstanceUID ?? DicomDataSetWriter.makeUID()
        let contentDate = options.contentDate ?? now.date
        let contentTime = options.contentTime ?? now.time
        let modality = options.modality ?? options.kind.defaultModality
        let imageType = options.imageType.isEmpty ? ["ORIGINAL", "PRIMARY", "VIDEO"] : options.imageType

        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, options.kind.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, sopInstanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            string(.modality, vr: .CS, modality),
            DicomDataElement(tag: DicomTag.imageType.rawValue, vr: .CS, value: .strings(imageType)),
            string(.contentDate, vr: .DA, contentDate),
            string(.contentTime, vr: .TM, contentTime),
            us(.samplesPerPixel, video.samplesPerPixel),
            string(.photometricInterpretation, vr: .CS, video.photometricInterpretation),
            us(.rows, video.rows),
            us(.columns, video.columns),
            isValue(.numberOfFrames, video.numberOfFrames),
            us(.bitsAllocated, video.bitsAllocated),
            us(.bitsStored, video.bitsStored),
            us(.highBit, video.highBit),
            us(.pixelRepresentation, video.pixelRepresentation),
            string(.lossyImageCompression, vr: .CS, "01"),
            DicomDataElement(
                tag: DicomTag.pixelData.rawValue,
                vr: .OB,
                value: .bytes(encapsulatedPixelData(for: video))
            )
        ]

        if let planarConfiguration = video.planarConfiguration {
            elements.append(us(.planarConfiguration, planarConfiguration))
        }
        if let frameTime = video.frameTimeMilliseconds {
            elements.append(ds(.frameTime, frameTime))
            elements.append(DicomDataElement(
                tag: DicomTag.frameIncrementPointer.rawValue,
                vr: .AT,
                value: .unsignedIntegers([UInt(DicomTag.frameTime.rawValue)])
            ))
        }
        if !video.frameTimeVectorMilliseconds.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.frameTimeVector.rawValue,
                vr: .DS,
                value: .strings(video.frameTimeVectorMilliseconds.map(formatDecimal))
            ))
        }
        if let cineRate = video.cineRate {
            elements.append(isValue(.cineRate, cineRate))
        }
        if let recommendedDisplayFrameRate = video.recommendedDisplayFrameRate {
            elements.append(isValue(.recommendedDisplayFrameRate, recommendedDisplayFrameRate))
        }
        if let method = video.codec.lossyCompressionMethod {
            elements.append(string(.lossyImageCompressionMethod, vr: .CS, method))
        }
        appendOptionalStrings(options, to: &elements)
        if !options.sourceImageReferences.isEmpty {
            elements.append(sequence(.sourceImageSequence, options.sourceImageReferences.map(sourceImageDataSet)))
        }
        return DicomDataSet(elements: elements)
    }

    public static func part10Data(
        video: DicomVideoPixelData,
        options: DicomVideoBuildOptions = DicomVideoBuildOptions()
    ) throws -> Data {
        let dataSet = try dataSet(video: video, options: options)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: video.transferSyntax,
                mediaStorageSOPClassUID: options.kind.storageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }

    public static func write(
        video: DicomVideoPixelData,
        to url: URL,
        options: DicomVideoBuildOptions = DicomVideoBuildOptions()
    ) throws {
        let data = try part10Data(video: video, options: options)
        try data.write(to: url, options: [.atomic])
    }

    private static func encapsulatedPixelData(for video: DicomVideoPixelData) -> Data {
        var data = Data()
        appendItemValue(basicOffsetTable(for: video), to: &data)
        for fragment in video.fragments {
            appendItemValue(fragment, to: &data)
        }
        appendSequenceDelimiter(to: &data)
        return data
    }

    private static func basicOffsetTable(for video: DicomVideoPixelData) -> Data {
        guard video.fragments.count == video.numberOfFrames else { return Data() }
        var table = Data()
        var offset: UInt32 = 0
        for fragment in video.fragments {
            appendUInt32(offset, to: &table)
            let paddedLength = fragment.count + (fragment.count % 2)
            offset += UInt32(8 + paddedLength)
        }
        return table
    }

    private static func appendItemValue(_ value: Data, to data: inout Data) {
        data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0])
        appendUInt32(UInt32(value.count + (value.count % 2)), to: &data)
        data.append(value)
        if value.count % 2 != 0 {
            data.append(0)
        }
    }

    private static func appendSequenceDelimiter(to data: inout Data) {
        data.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0])
        appendUInt32(0, to: &data)
    }

    private static func appendOptionalStrings(_ options: DicomVideoBuildOptions, to elements: inout [DicomDataElement]) {
        appendOptionalString(.patientName, vr: .PN, options.patientName, to: &elements)
        appendOptionalString(.patientID, vr: .LO, options.patientID, to: &elements)
        appendOptionalString(.studyID, vr: .SH, options.studyID, to: &elements)
        appendOptionalString(.studyDate, vr: .DA, options.studyDate, to: &elements)
        appendOptionalString(.studyTime, vr: .TM, options.studyTime, to: &elements)
        appendOptionalString(.seriesDate, vr: .DA, options.seriesDate, to: &elements)
        appendOptionalString(.seriesTime, vr: .TM, options.seriesTime, to: &elements)
        appendOptionalString(.seriesDescription, vr: .LO, options.seriesDescription, to: &elements)
        if let seriesNumber = options.seriesNumber {
            elements.append(isValue(.seriesNumber, seriesNumber))
        }
        if let instanceNumber = options.instanceNumber {
            elements.append(isValue(.instanceNumber, instanceNumber))
        }
    }

    private static func appendOptionalString(
        _ tag: DicomTag,
        vr: DicomVR,
        _ value: String?,
        to elements: inout [DicomDataElement]
    ) {
        guard let value = value?.dicomVideoNonEmptyValue else { return }
        elements.append(string(tag, vr: vr, value))
    }

    private static func sourceImageDataSet(_ reference: DicomSourceImageReference) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        if let sopClassUID = reference.referencedSOPClassUID {
            elements.append(string(.referencedSOPClassUID, vr: .UI, sopClassUID))
        }
        if let sopInstanceUID = reference.referencedSOPInstanceUID {
            elements.append(string(.referencedSOPInstanceUID, vr: .UI, sopInstanceUID))
        }
        if !reference.referencedFrameNumbers.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.referencedFrameNumber.rawValue,
                vr: .IS,
                value: .strings(reference.referencedFrameNumbers.map(String.init))
            ))
        }
        return DicomDataSet(elements: elements)
    }

    private static func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private static func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private static func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(clamping: value)]))
    }

    private static func isValue(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .IS, value: .strings([String(value)]))
    }

    private static func ds(_ tag: DicomTag, _ value: Double) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings([formatDecimal(value)]))
    }

    private static func formatDecimal(_ value: Double) -> String {
        String(format: "%.12g", value)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    private static func currentDicomDateTime() -> (date: String, time: String) {
        let date = Date()
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "yyyyMMdd"

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        timeFormatter.dateFormat = "HHmmss"

        return (dateFormatter.string(from: date), timeFormatter.string(from: date))
    }
}

extension DCMDecoder {
    public var video: DicomVideo? {
        synchronized {
            DicomVideoParser.makeVideo(from: self)
        }
    }
}

private enum DicomVideoParser {
    static func makeVideo(from decoder: DCMDecoder) -> DicomVideo? {
        guard matches(decoder),
              let descriptor = encapsulatedDescriptor(from: decoder),
              !descriptor.fragments.isEmpty else {
            return nil
        }

        let streamData = fragmentData(descriptor.fragments, in: decoder)
        guard !streamData.isEmpty else { return nil }
        let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID)
        let framePayloads = descriptor.frameFragmentIndexes.indices.compactMap {
            descriptor.frame($0, in: decoder.dicomData)?.data
        }
        let sourceReferences = parseItems(in: decoder, for: .sourceImageSequence).map(sourceImageReference)

        return DicomVideo(
            sopClassUID: decoder.info(for: .sopClassUID),
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            studyInstanceUID: decoder.info(for: .studyInstanceUID),
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID),
            modality: decoder.info(for: .modality),
            patientName: decoder.dataSet.personName(for: .patientName),
            patientID: decoder.info(for: .patientID),
            imageType: decoder.info(for: .imageType).dicomVideoMultiValues,
            transferSyntaxUID: decoder.transferSyntaxUID,
            transferSyntax: syntax,
            columns: decoder.width,
            rows: decoder.height,
            numberOfFrames: max(1, decoder.intValue(for: .numberOfFrames) ?? decoder.nImages),
            frameTimeMilliseconds: decoder.doubleValue(for: .frameTime),
            frameTimeVectorMilliseconds: decoder.dataSet.floats(for: .frameTimeVector),
            cineRate: decoder.intValue(for: .cineRate),
            recommendedDisplayFrameRate: decoder.intValue(for: .recommendedDisplayFrameRate),
            lossyImageCompression: decoder.info(for: .lossyImageCompression),
            lossyImageCompressionRatio: decoder.doubleValue(for: .lossyImageCompressionRatio),
            lossyImageCompressionMethod: decoder.info(for: .lossyImageCompressionMethod),
            sourceImageReferences: sourceReferences,
            streamData: streamData,
            indexedFramePayloads: framePayloads,
            encapsulatedPixelDataDescriptor: descriptor
        )
    }

    private static func matches(_ decoder: DCMDecoder) -> Bool {
        let sopClassUID = decoder.info(for: .sopClassUID).dicomVideoTrimmedValue
        let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID)
        return DicomVideo.supportedStorageSOPClassUIDs.contains(sopClassUID) ||
            syntax?.isVideoTransferSyntax == true
    }

    private static func encapsulatedDescriptor(from decoder: DCMDecoder) -> DicomEncapsulatedPixelDataDescriptor? {
        if let descriptor = decoder.makeEncapsulatedPixelDataDescriptorUnsafe() {
            return descriptor
        }
        guard decoder.offset >= 0 else { return nil }
        return try? DicomEncapsulatedPixelDataParser().parse(
            data: decoder.dicomData,
            pixelDataOffset: decoder.offset,
            numberOfFrames: max(1, decoder.nImages),
            extendedOffsetTableData: rawElementData(in: decoder, for: .extendedOffsetTable),
            extendedOffsetTableLengthsData: rawElementData(in: decoder, for: .extendedOffsetTableLengths)
        )
    }

    private static func rawElementData(in decoder: DCMDecoder, for tag: DicomTag) -> Data? {
        guard let metadata = decoder.tagMetadataCache[tag.rawValue],
              metadata.elementLength > 0,
              metadata.offset >= 0 else {
            return nil
        }
        let end = metadata.offset + metadata.elementLength
        guard end <= decoder.dicomData.count else { return nil }
        return Data(decoder.dicomData[metadata.offset..<end])
    }

    private static func fragmentData(
        _ fragments: [DicomEncapsulatedPixelDataFragment],
        in decoder: DCMDecoder
    ) -> Data {
        fragments.reduce(into: Data()) { result, fragment in
            guard fragment.valueRange.lowerBound >= 0,
                  fragment.valueRange.upperBound <= decoder.dicomData.count else {
                return
            }
            result.append(Data(decoder.dicomData[fragment.valueRange]))
        }
    }

    private static func sourceImageReference(from item: DicomSequenceItem) -> DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: item.dataSet.string(for: .referencedSOPClassUID),
            referencedSOPInstanceUID: item.dataSet.string(for: .referencedSOPInstanceUID),
            referencedFrameNumbers: item.dataSet.ints(for: .referencedFrameNumber)
        )
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

public extension DicomTransferSyntax {
    var isVideoTransferSyntax: Bool {
        switch self {
        case .mpeg2MainProfileMainLevel,
             .mpeg2MainProfileMainLevelFragmentable,
             .mpeg2MainProfileHighLevel,
             .mpeg2MainProfileHighLevelFragmentable,
             .mpeg4AVCH264HighProfileLevel41,
             .mpeg4AVCH264HighProfileLevel41Fragmentable,
             .mpeg4AVCH264BDCompatibleHighProfileLevel41,
             .mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable,
             .mpeg4AVCH264HighProfileLevel42For2DVideo,
             .mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable,
             .mpeg4AVCH264HighProfileLevel42For3DVideo,
             .mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable,
             .mpeg4AVCH264StereoHighProfileLevel42,
             .mpeg4AVCH264StereoHighProfileLevel42Fragmentable,
             .hevcH265MainProfileLevel51,
             .hevcH265Main10ProfileLevel51:
            return true
        default:
            return false
        }
    }
}

private extension Array where Element: Equatable {
    func removingDuplicateVideoElements() -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(element) {
            result.append(element)
        }
        return result
    }
}

private extension String {
    var dicomVideoTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomVideoNonEmptyValue: String? {
        let trimmed = dicomVideoTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }

    var dicomVideoMultiValues: [String] {
        let trimmed = dicomVideoTrimmedValue
        guard !trimmed.isEmpty else { return [] }
        return trimmed
            .split(separator: "\\", omittingEmptySubsequences: false)
            .map { String($0).dicomVideoTrimmedValue }
    }
}
