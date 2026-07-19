import CoreGraphics
import Foundation

public enum DicomSecondaryCaptureError: Error, Equatable, LocalizedError, Sendable {
    case invalidDimensions(columns: Int, rows: Int)
    case invalidPixelBuffer(expected: Int, actual: Int)
    case unsupportedPixelLayout(String)
    case missingRequiredMetadata([String])
    case imageContextCreationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDimensions(let columns, let rows):
            return "Invalid Secondary Capture dimensions: \(columns)x\(rows)."
        case .invalidPixelBuffer(let expected, let actual):
            return "Invalid Secondary Capture pixel buffer: expected \(expected) bytes, found \(actual)."
        case .unsupportedPixelLayout(let reason):
            return "Unsupported Secondary Capture pixel layout: \(reason)."
        case .missingRequiredMetadata(let fields):
            return "Missing required Secondary Capture metadata: \(fields.joined(separator: ", "))."
        case .imageContextCreationFailed:
            return "Could not create a CoreGraphics context for the Secondary Capture snapshot."
        }
    }
}

public enum DicomSecondaryCaptureValidationScope: Equatable, Sendable {
    case syntheticDefaultsAllowed
    case clinicalExport
}

/// Native pixel payload for a single-frame Secondary Capture image.
public struct DicomSecondaryCapturePixelData: Equatable, Sendable {
    public let data: Data
    public let columns: Int
    public let rows: Int
    public let samplesPerPixel: Int
    public let photometricInterpretation: String
    public let bitsAllocated: Int
    public let bitsStored: Int
    public let highBit: Int
    public let pixelRepresentation: Int
    public let planarConfiguration: Int?

    public init(
        data: Data,
        columns: Int,
        rows: Int,
        samplesPerPixel: Int,
        photometricInterpretation: String,
        bitsAllocated: Int,
        bitsStored: Int,
        highBit: Int,
        pixelRepresentation: Int = 0,
        planarConfiguration: Int? = nil
    ) throws {
        guard columns > 0, rows > 0 else {
            throw DicomSecondaryCaptureError.invalidDimensions(columns: columns, rows: rows)
        }
        guard samplesPerPixel == 1 || samplesPerPixel == 3 else {
            throw DicomSecondaryCaptureError.unsupportedPixelLayout("samplesPerPixel must be 1 or 3")
        }
        guard bitsAllocated == 8 || bitsAllocated == 16 else {
            throw DicomSecondaryCaptureError.unsupportedPixelLayout("bitsAllocated must be 8 or 16")
        }
        guard bitsStored > 0, bitsStored <= bitsAllocated, highBit == bitsStored - 1 else {
            throw DicomSecondaryCaptureError.unsupportedPixelLayout("bitsStored/highBit are inconsistent")
        }
        guard pixelRepresentation == 0 else {
            throw DicomSecondaryCaptureError.unsupportedPixelLayout("only unsigned pixel data is supported")
        }
        if samplesPerPixel == 3 {
            guard photometricInterpretation.uppercased() == "RGB" else {
                throw DicomSecondaryCaptureError.unsupportedPixelLayout("three-sample payloads must be RGB")
            }
            guard planarConfiguration == 0 else {
                throw DicomSecondaryCaptureError.unsupportedPixelLayout("RGB payloads must be interleaved")
            }
        }

        let bytesPerSample = bitsAllocated / 8
        let expectedCount = columns * rows * samplesPerPixel * bytesPerSample
        guard data.count == expectedCount else {
            throw DicomSecondaryCaptureError.invalidPixelBuffer(expected: expectedCount, actual: data.count)
        }

        self.data = data
        self.columns = columns
        self.rows = rows
        self.samplesPerPixel = samplesPerPixel
        self.photometricInterpretation = photometricInterpretation.uppercased()
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.pixelRepresentation = pixelRepresentation
        self.planarConfiguration = planarConfiguration
    }

    public static func rgb8(columns: Int, rows: Int, data: Data) throws -> DicomSecondaryCapturePixelData {
        try DicomSecondaryCapturePixelData(
            data: data,
            columns: columns,
            rows: rows,
            samplesPerPixel: 3,
            photometricInterpretation: "RGB",
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7,
            planarConfiguration: 0
        )
    }

    public static func monochrome8(columns: Int, rows: Int, data: Data) throws -> DicomSecondaryCapturePixelData {
        try DicomSecondaryCapturePixelData(
            data: data,
            columns: columns,
            rows: rows,
            samplesPerPixel: 1,
            photometricInterpretation: "MONOCHROME2",
            bitsAllocated: 8,
            bitsStored: 8,
            highBit: 7
        )
    }
}

public struct DicomSecondaryCaptureBuildOptions: Equatable, Sendable {
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
    public var instanceCreationDate: String?
    public var instanceCreationTime: String?
    public var dateOfSecondaryCapture: String?
    public var timeOfSecondaryCapture: String?
    public var conversionType: String
    public var derivationDescription: String?
    public var sourceImageReferences: [DicomSourceImageReference]
    public var secondaryCaptureDeviceID: String?
    public var secondaryCaptureDeviceManufacturer: String?
    public var secondaryCaptureDeviceManufacturerModelName: String?
    public var secondaryCaptureDeviceSoftwareVersions: String?

    public init(
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
        seriesDescription: String? = "Secondary Capture",
        contentDate: String? = nil,
        contentTime: String? = nil,
        instanceCreationDate: String? = nil,
        instanceCreationTime: String? = nil,
        dateOfSecondaryCapture: String? = nil,
        timeOfSecondaryCapture: String? = nil,
        conversionType: String = "WSD",
        derivationDescription: String? = "Rendered snapshot export",
        sourceImageReferences: [DicomSourceImageReference] = [],
        secondaryCaptureDeviceID: String? = nil,
        secondaryCaptureDeviceManufacturer: String? = "DICOM-Swift",
        secondaryCaptureDeviceManufacturerModelName: String? = nil,
        secondaryCaptureDeviceSoftwareVersions: String? = nil
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomSCNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomSCNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomSCNonEmptyValue
        self.patientName = patientName?.dicomSCNonEmptyValue
        self.patientID = patientID?.dicomSCNonEmptyValue
        self.studyID = studyID?.dicomSCNonEmptyValue
        self.studyDate = studyDate?.dicomSCNonEmptyValue
        self.studyTime = studyTime?.dicomSCNonEmptyValue
        self.seriesNumber = seriesNumber
        self.instanceNumber = instanceNumber
        self.seriesDate = seriesDate?.dicomSCNonEmptyValue
        self.seriesTime = seriesTime?.dicomSCNonEmptyValue
        self.seriesDescription = seriesDescription?.dicomSCNonEmptyValue
        self.contentDate = contentDate?.dicomSCNonEmptyValue
        self.contentTime = contentTime?.dicomSCNonEmptyValue
        self.instanceCreationDate = instanceCreationDate?.dicomSCNonEmptyValue
        self.instanceCreationTime = instanceCreationTime?.dicomSCNonEmptyValue
        self.dateOfSecondaryCapture = dateOfSecondaryCapture?.dicomSCNonEmptyValue
        self.timeOfSecondaryCapture = timeOfSecondaryCapture?.dicomSCNonEmptyValue
        self.conversionType = conversionType.dicomSCNonEmptyValue?.uppercased() ?? "WSD"
        self.derivationDescription = derivationDescription?.dicomSCNonEmptyValue
        self.sourceImageReferences = sourceImageReferences.removingDuplicateSCElements()
        self.secondaryCaptureDeviceID = secondaryCaptureDeviceID?.dicomSCNonEmptyValue
        self.secondaryCaptureDeviceManufacturer = secondaryCaptureDeviceManufacturer?.dicomSCNonEmptyValue
        self.secondaryCaptureDeviceManufacturerModelName = secondaryCaptureDeviceManufacturerModelName?.dicomSCNonEmptyValue
        self.secondaryCaptureDeviceSoftwareVersions = secondaryCaptureDeviceSoftwareVersions?.dicomSCNonEmptyValue
    }

    public static func preservingClinicalContext(
        from decoder: DCMDecoder,
        referencedFrameNumbers: [Int] = [],
        sopInstanceUID: String? = nil,
        seriesDescription: String? = "Secondary Capture"
    ) -> DicomSecondaryCaptureBuildOptions {
        var sourceReferences: [DicomSourceImageReference] = []
        let sourceSOPClassUID = decoder.info(for: .sopClassUID).dicomSCNonEmptyValue
        let sourceSOPInstanceUID = decoder.info(for: .sopInstanceUID).dicomSCNonEmptyValue
        if sourceSOPClassUID != nil || sourceSOPInstanceUID != nil {
            sourceReferences.append(DicomSourceImageReference(
                referencedSOPClassUID: sourceSOPClassUID,
                referencedSOPInstanceUID: sourceSOPInstanceUID,
                referencedFrameNumbers: referencedFrameNumbers
            ))
        }

        return DicomSecondaryCaptureBuildOptions(
            sopInstanceUID: sopInstanceUID,
            studyInstanceUID: decoder.info(for: .studyInstanceUID).dicomSCNonEmptyValue,
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID).dicomSCNonEmptyValue,
            patientName: decoder.info(for: .patientName).dicomSCNonEmptyValue,
            patientID: decoder.info(for: .patientID).dicomSCNonEmptyValue,
            studyID: decoder.info(for: .studyID).dicomSCNonEmptyValue,
            studyDate: decoder.info(for: .studyDate).dicomSCNonEmptyValue,
            studyTime: decoder.info(for: .studyTime).dicomSCNonEmptyValue,
            seriesNumber: decoder.intValue(for: .seriesNumber),
            instanceNumber: 1,
            seriesDate: decoder.info(for: .seriesDate).dicomSCNonEmptyValue,
            seriesTime: decoder.info(for: .seriesTime).dicomSCNonEmptyValue,
            seriesDescription: seriesDescription,
            sourceImageReferences: sourceReferences
        )
    }
}

/// Parsed Secondary Capture image metadata and source references.
public struct DicomSecondaryCaptureImage: Equatable, Sendable {
    public static let storageSOPClassUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID

    public let sopInstanceUID: String?
    public let studyInstanceUID: String?
    public let seriesInstanceUID: String?
    public let modality: String?
    public let patientName: DicomPersonName?
    public let patientID: String?
    public let imageType: [String]
    public let conversionType: String?
    public let derivationDescription: String?
    public let dateOfSecondaryCapture: String?
    public let timeOfSecondaryCapture: String?
    public let sourceImageReferences: [DicomSourceImageReference]
    public let secondaryCaptureDeviceID: String?
    public let secondaryCaptureDeviceManufacturer: String?
    public let secondaryCaptureDeviceManufacturerModelName: String?
    public let secondaryCaptureDeviceSoftwareVersions: String?
    public let pixelDataDescriptor: DicomPixelDataDescriptor?

    public init(
        sopInstanceUID: String?,
        studyInstanceUID: String?,
        seriesInstanceUID: String?,
        modality: String?,
        patientName: DicomPersonName?,
        patientID: String?,
        imageType: [String] = [],
        conversionType: String? = nil,
        derivationDescription: String? = nil,
        dateOfSecondaryCapture: String? = nil,
        timeOfSecondaryCapture: String? = nil,
        sourceImageReferences: [DicomSourceImageReference] = [],
        secondaryCaptureDeviceID: String? = nil,
        secondaryCaptureDeviceManufacturer: String? = nil,
        secondaryCaptureDeviceManufacturerModelName: String? = nil,
        secondaryCaptureDeviceSoftwareVersions: String? = nil,
        pixelDataDescriptor: DicomPixelDataDescriptor? = nil
    ) {
        self.sopInstanceUID = sopInstanceUID?.dicomSCNonEmptyValue
        self.studyInstanceUID = studyInstanceUID?.dicomSCNonEmptyValue
        self.seriesInstanceUID = seriesInstanceUID?.dicomSCNonEmptyValue
        self.modality = modality?.dicomSCNonEmptyValue?.uppercased()
        self.patientName = patientName
        self.patientID = patientID?.dicomSCNonEmptyValue
        self.imageType = imageType
        self.conversionType = conversionType?.dicomSCNonEmptyValue?.uppercased()
        self.derivationDescription = derivationDescription?.dicomSCNonEmptyValue
        self.dateOfSecondaryCapture = dateOfSecondaryCapture?.dicomSCNonEmptyValue
        self.timeOfSecondaryCapture = timeOfSecondaryCapture?.dicomSCNonEmptyValue
        self.sourceImageReferences = sourceImageReferences.removingDuplicateSCElements()
        self.secondaryCaptureDeviceID = secondaryCaptureDeviceID?.dicomSCNonEmptyValue
        self.secondaryCaptureDeviceManufacturer = secondaryCaptureDeviceManufacturer?.dicomSCNonEmptyValue
        self.secondaryCaptureDeviceManufacturerModelName = secondaryCaptureDeviceManufacturerModelName?.dicomSCNonEmptyValue
        self.secondaryCaptureDeviceSoftwareVersions = secondaryCaptureDeviceSoftwareVersions?.dicomSCNonEmptyValue
        self.pixelDataDescriptor = pixelDataDescriptor
    }
}

public enum DicomSecondaryCaptureBuilder {
    public static func dataSet(
        pixelData: DicomSecondaryCapturePixelData,
        options: DicomSecondaryCaptureBuildOptions = DicomSecondaryCaptureBuildOptions()
    ) -> DicomDataSet {
        let now = currentDicomDateTime()
        let sopInstanceUID = options.sopInstanceUID ?? DicomDataSetWriter.makeUID()
        let studyInstanceUID = options.studyInstanceUID ?? DicomDataSetWriter.makeUID()
        let seriesInstanceUID = options.seriesInstanceUID ?? DicomDataSetWriter.makeUID()
        let contentDate = options.contentDate ?? now.date
        let contentTime = options.contentTime ?? now.time
        let instanceCreationDate = options.instanceCreationDate ?? contentDate
        let instanceCreationTime = options.instanceCreationTime ?? contentTime
        let dateOfSecondaryCapture = options.dateOfSecondaryCapture ?? contentDate
        let timeOfSecondaryCapture = options.timeOfSecondaryCapture ?? contentTime

        var elements: [DicomDataElement] = [
            string(.sopClassUID, vr: .UI, DicomSecondaryCaptureImage.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, sopInstanceUID),
            string(.studyInstanceUID, vr: .UI, studyInstanceUID),
            string(.seriesInstanceUID, vr: .UI, seriesInstanceUID),
            string(.modality, vr: .CS, "OT"),
            DicomDataElement(tag: DicomTag.imageType.rawValue, vr: .CS, value: .strings(["DERIVED", "SECONDARY"])),
            string(.conversionType, vr: .CS, options.conversionType),
            string(.instanceCreationDate, vr: .DA, instanceCreationDate),
            string(.instanceCreationTime, vr: .TM, instanceCreationTime),
            string(.contentDate, vr: .DA, contentDate),
            string(.contentTime, vr: .TM, contentTime),
            string(.dateOfSecondaryCapture, vr: .DA, dateOfSecondaryCapture),
            string(.timeOfSecondaryCapture, vr: .TM, timeOfSecondaryCapture),
            us(.samplesPerPixel, pixelData.samplesPerPixel),
            string(.photometricInterpretation, vr: .CS, pixelData.photometricInterpretation),
            us(.rows, pixelData.rows),
            us(.columns, pixelData.columns),
            us(.bitsAllocated, pixelData.bitsAllocated),
            us(.bitsStored, pixelData.bitsStored),
            us(.highBit, pixelData.highBit),
            us(.pixelRepresentation, pixelData.pixelRepresentation),
            DicomDataElement(
                tag: DicomTag.pixelData.rawValue,
                vr: pixelData.bitsAllocated <= 8 ? .OB : .OW,
                value: .bytes(pixelData.data)
            )
        ]

        if let planarConfiguration = pixelData.planarConfiguration {
            elements.append(us(.planarConfiguration, planarConfiguration))
        }
        appendOptionalStrings(options, to: &elements)
        if !options.sourceImageReferences.isEmpty {
            elements.append(sequence(.sourceImageSequence, options.sourceImageReferences.map(sourceImageDataSet)))
        }

        return DicomDataSet(elements: elements)
    }

    public static func validatedDataSet(
        pixelData: DicomSecondaryCapturePixelData,
        options: DicomSecondaryCaptureBuildOptions = DicomSecondaryCaptureBuildOptions(),
        validationScope: DicomSecondaryCaptureValidationScope = .clinicalExport
    ) throws -> DicomDataSet {
        try validate(pixelData: pixelData, options: options, scope: validationScope)
        return dataSet(pixelData: pixelData, options: options)
    }

    public static func dataSet(
        from image: CGImage,
        options: DicomSecondaryCaptureBuildOptions = DicomSecondaryCaptureBuildOptions(),
        validationScope: DicomSecondaryCaptureValidationScope = .syntheticDefaultsAllowed
    ) throws -> DicomDataSet {
        let pixelData = try rgb8PixelData(from: image)
        try validate(pixelData: pixelData, options: options, scope: validationScope)
        return dataSet(pixelData: pixelData, options: options)
    }

    public static func part10Data(
        pixelData: DicomSecondaryCapturePixelData,
        options: DicomSecondaryCaptureBuildOptions = DicomSecondaryCaptureBuildOptions(),
        validationScope: DicomSecondaryCaptureValidationScope = .syntheticDefaultsAllowed
    ) throws -> Data {
        try validate(pixelData: pixelData, options: options, scope: validationScope)
        let dataSet = dataSet(pixelData: pixelData, options: options)
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomSecondaryCaptureImage.storageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
    }

    public static func part10Data(
        from image: CGImage,
        options: DicomSecondaryCaptureBuildOptions = DicomSecondaryCaptureBuildOptions(),
        validationScope: DicomSecondaryCaptureValidationScope = .syntheticDefaultsAllowed
    ) throws -> Data {
        try part10Data(
            pixelData: rgb8PixelData(from: image),
            options: options,
            validationScope: validationScope
        )
    }

    public static func validate(
        pixelData: DicomSecondaryCapturePixelData,
        options: DicomSecondaryCaptureBuildOptions,
        scope: DicomSecondaryCaptureValidationScope = .clinicalExport
    ) throws {
        _ = pixelData
        guard scope == .clinicalExport else { return }

        let requiredStrings: [(String, String?)] = [
            ("SOP Instance UID", options.sopInstanceUID),
            ("Study Instance UID", options.studyInstanceUID),
            ("Series Instance UID", options.seriesInstanceUID),
            ("Patient Name", options.patientName),
            ("Patient ID", options.patientID),
            ("Study ID", options.studyID),
            ("Study Date", options.studyDate)
        ]
        var missing = requiredStrings.compactMap { item in
            item.1?.dicomSCNonEmptyValue == nil ? item.0 : nil
        }
        if options.seriesNumber == nil {
            missing.append("Series Number")
        }
        if options.instanceNumber == nil {
            missing.append("Instance Number")
        }
        guard missing.isEmpty else {
            throw DicomSecondaryCaptureError.missingRequiredMetadata(missing)
        }
    }

    public static func rgb8PixelData(from image: CGImage) throws -> DicomSecondaryCapturePixelData {
        let columns = image.width
        let rows = image.height
        guard columns > 0, rows > 0 else {
            throw DicomSecondaryCaptureError.invalidDimensions(columns: columns, rows: rows)
        }

        let bytesPerPixel = 4
        let bytesPerRow = columns * bytesPerPixel
        var rgba = Data(count: bytesPerRow * rows)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        try rgba.withUnsafeMutableBytes { pointer in
            guard let baseAddress = pointer.baseAddress else {
                throw DicomSecondaryCaptureError.imageContextCreationFailed
            }
            guard let context = CGContext(
                data: baseAddress,
                width: columns,
                height: rows,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else {
                throw DicomSecondaryCaptureError.imageContextCreationFailed
            }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        }

        var rgb = Data()
        rgb.reserveCapacity(columns * rows * 3)
        for offset in stride(from: 0, to: rgba.count, by: bytesPerPixel) {
            rgb.append(rgba[offset])
            rgb.append(rgba[offset + 1])
            rgb.append(rgba[offset + 2])
        }
        return try .rgb8(columns: columns, rows: rows, data: rgb)
    }

    private static func appendOptionalStrings(
        _ options: DicomSecondaryCaptureBuildOptions,
        to elements: inout [DicomDataElement]
    ) {
        appendOptionalString(.patientName, vr: .PN, options.patientName, to: &elements)
        appendOptionalString(.patientID, vr: .LO, options.patientID, to: &elements)
        appendOptionalString(.studyID, vr: .SH, options.studyID, to: &elements)
        appendOptionalString(.studyDate, vr: .DA, options.studyDate, to: &elements)
        appendOptionalString(.studyTime, vr: .TM, options.studyTime, to: &elements)
        appendOptionalString(.seriesDate, vr: .DA, options.seriesDate, to: &elements)
        appendOptionalString(.seriesTime, vr: .TM, options.seriesTime, to: &elements)
        appendOptionalString(.seriesDescription, vr: .LO, options.seriesDescription, to: &elements)
        appendOptionalString(.derivationDescription, vr: .ST, options.derivationDescription, to: &elements)
        appendOptionalString(.secondaryCaptureDeviceID, vr: .LO, options.secondaryCaptureDeviceID, to: &elements)
        appendOptionalString(
            .secondaryCaptureDeviceManufacturer,
            vr: .LO,
            options.secondaryCaptureDeviceManufacturer,
            to: &elements
        )
        appendOptionalString(
            .secondaryCaptureDeviceManufacturerModelName,
            vr: .LO,
            options.secondaryCaptureDeviceManufacturerModelName,
            to: &elements
        )
        appendOptionalString(
            .secondaryCaptureDeviceSoftwareVersions,
            vr: .LO,
            options.secondaryCaptureDeviceSoftwareVersions,
            to: &elements
        )

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
        guard let value = value?.dicomSCNonEmptyValue else { return }
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
    public var secondaryCaptureImage: DicomSecondaryCaptureImage? {
        synchronized {
            DicomSecondaryCaptureParser.makeImage(from: self)
        }
    }
}

private enum DicomSecondaryCaptureParser {
    static func makeImage(from decoder: DCMDecoder) -> DicomSecondaryCaptureImage? {
        guard matches(decoder) else { return nil }
        let topLevelReferences = parseItems(in: decoder, for: .sourceImageSequence).map(sourceImageReference)
        let derivationReferences = parseItems(in: decoder, for: .derivationImageSequence).flatMap {
            $0.dataSet.sequenceItems(for: .sourceImageSequence).map(sourceImageReference)
        }

        return DicomSecondaryCaptureImage(
            sopInstanceUID: decoder.info(for: .sopInstanceUID),
            studyInstanceUID: decoder.info(for: .studyInstanceUID),
            seriesInstanceUID: decoder.info(for: .seriesInstanceUID),
            modality: decoder.info(for: .modality),
            patientName: decoder.dataSet.personName(for: .patientName),
            patientID: decoder.info(for: .patientID),
            imageType: decoder.info(for: .imageType).dicomSCMultiValues,
            conversionType: decoder.info(for: .conversionType),
            derivationDescription: decoder.info(for: .derivationDescription),
            dateOfSecondaryCapture: decoder.info(for: .dateOfSecondaryCapture),
            timeOfSecondaryCapture: decoder.info(for: .timeOfSecondaryCapture),
            sourceImageReferences: topLevelReferences + derivationReferences,
            secondaryCaptureDeviceID: decoder.info(for: .secondaryCaptureDeviceID),
            secondaryCaptureDeviceManufacturer: decoder.info(for: .secondaryCaptureDeviceManufacturer),
            secondaryCaptureDeviceManufacturerModelName: decoder.info(for: .secondaryCaptureDeviceManufacturerModelName),
            secondaryCaptureDeviceSoftwareVersions: decoder.info(for: .secondaryCaptureDeviceSoftwareVersions),
            pixelDataDescriptor: decoder.pixelDataDescriptor
        )
    }

    private static func matches(_ decoder: DCMDecoder) -> Bool {
        decoder.info(for: .sopClassUID).dicomSCTrimmedValue == DicomSecondaryCaptureImage.storageSOPClassUID
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

private extension Array where Element: Equatable {
    func removingDuplicateSCElements() -> [Element] {
        var result: [Element] = []
        for element in self where !result.contains(element) {
            result.append(element)
        }
        return result
    }
}

private extension String {
    var dicomSCTrimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
    }

    var dicomSCNonEmptyValue: String? {
        let trimmed = dicomSCTrimmedValue
        return trimmed.isEmpty ? nil : trimmed
    }

    var dicomSCMultiValues: [String] {
        let trimmed = dicomSCTrimmedValue
        guard !trimmed.isEmpty else { return [] }
        return trimmed
            .split(separator: "\\", omittingEmptySubsequences: false)
            .map { String($0).dicomSCTrimmedValue }
    }
}
