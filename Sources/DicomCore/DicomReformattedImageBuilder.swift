import Foundation

/// One image of a multiplanar reformat of a CT, MR or PET series, as a derived
/// instance of the source's own SOP class: reconstructed scalar values with the
/// Image Plane that goes with them, not a picture of a screen.
///
/// The patient, study, equipment and acquisition context is taken from an
/// instance of the source series; everything that described that instance's
/// own pixels, position or identity is replaced.
public struct DicomReformattedImageRequest: Sendable {
    public enum SampleKind: Sendable, Equatable {
        /// Whole modality values that fit 16 bits signed.
        case signedInteger
        /// Whole modality values that fit 16 bits unsigned.
        case unsignedInteger
        /// Real values: stored as 16 bits unsigned with this image's own Rescale Slope and Intercept.
        case real
    }

    public enum Projection: String, Sendable, Equatable {
        case none
        case mean
        case maximum
        case minimum
        /// The integral above the volume's minimum, divided by the slab's thickness.
        case sum
    }

    public struct SourceInstance: Sendable, Equatable {
        public var sopClassUID: String
        public var sopInstanceUID: String

        public init(sopClassUID: String, sopInstanceUID: String) {
            self.sopClassUID = sopClassUID
            self.sopInstanceUID = sopInstanceUID
        }
    }

    /// An instance of the source series, without its Pixel Data.
    public var template: DicomDataSet
    public var sopInstanceUID: String
    public var seriesInstanceUID: String
    public var frameOfReferenceUID: String?
    public var seriesNumber: Int
    public var instanceNumber: Int
    public var seriesDescription: String
    public var columns: Int
    public var rows: Int
    /// Millimeters; the pixels are square.
    public var pixelSpacing: Double
    /// Patient coordinates of the centre of the first pixel, and unit directions of the rows and columns.
    public var imagePosition: [Double]
    public var rowDirection: [Double]
    public var columnDirection: [Double]
    public var sliceThickness: Double
    public var spacingBetweenSlices: Double?
    public var projection: Projection
    /// Modality values, row by row.
    public var samples: [Float]
    public var sampleKind: SampleKind
    /// Replaces Units (0054,1001) when the values are not in the source's units.
    public var units: String?
    public var windowCenter: Double?
    public var windowWidth: Double?
    public var sourceInstances: [SourceInstance]
    public var createdAt: Date
    /// Said after the reformat's own description in Derivation Description
    /// (0008,2111): how the source geometry was taken, when it matters.
    public var derivationNote: String?

    public init(template: DicomDataSet, sopInstanceUID: String, seriesInstanceUID: String,
                frameOfReferenceUID: String?, seriesNumber: Int, instanceNumber: Int, seriesDescription: String,
                columns: Int, rows: Int, pixelSpacing: Double,
                imagePosition: [Double], rowDirection: [Double], columnDirection: [Double],
                sliceThickness: Double, spacingBetweenSlices: Double?, projection: Projection,
                samples: [Float], sampleKind: SampleKind, units: String? = nil,
                windowCenter: Double?, windowWidth: Double?,
                sourceInstances: [SourceInstance], createdAt: Date, derivationNote: String? = nil) {
        self.template = template
        self.sopInstanceUID = sopInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.frameOfReferenceUID = frameOfReferenceUID
        self.seriesNumber = seriesNumber
        self.instanceNumber = instanceNumber
        self.seriesDescription = seriesDescription
        self.columns = columns
        self.rows = rows
        self.pixelSpacing = pixelSpacing
        self.imagePosition = imagePosition
        self.rowDirection = rowDirection
        self.columnDirection = columnDirection
        self.sliceThickness = sliceThickness
        self.spacingBetweenSlices = spacingBetweenSlices
        self.projection = projection
        self.samples = samples
        self.sampleKind = sampleKind
        self.units = units
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.sourceInstances = sourceInstances
        self.createdAt = createdAt
        self.derivationNote = derivationNote
    }
}

public enum DicomReformattedImageError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSourceSOPClass(String)
    case invalidGeometry
    case sampleCountMismatch(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSourceSOPClass(let uid):
            "A reformat can be written from CT, MR and PET image series; this series is \(uid.isEmpty ? "of an unknown class" : uid)."
        case .invalidGeometry:
            "The reformat's geometry is not usable: sizes, spacing and directions must be finite and positive."
        case .sampleCountMismatch(let expected, let actual):
            "The reformat has \(actual) samples where \(expected) were expected."
        }
    }
}

public struct DicomReformattedImage: Sendable {
    public let data: Data
    public let sopClassUID: String
    public let rescaleSlope: Double
    public let rescaleIntercept: Double
}

public enum DicomReformattedImageBuilder {
    public static let ctImageStorage = "1.2.840.10008.5.1.4.1.1.2"
    public static let mrImageStorage = "1.2.840.10008.5.1.4.1.1.4"
    public static let petImageStorage = "1.2.840.10008.5.1.4.1.1.128"
    public static let supportedSOPClassUIDs: Set<String> = [ctImageStorage, mrImageStorage, petImageStorage]

    /// The source instance's data set, read for use as a template. Pixel Data is not kept.
    public static func template(fromPart10 data: Data) throws -> DicomDataSet {
        let meta = try DicomPart10FileMetaParser.parse(data)
        guard let uid = meta.transferSyntaxUID, let syntax = DicomTransferSyntax(uid: uid) else {
            throw DicomReformattedImageError.unsupportedSourceSOPClass("")
        }
        let body = Data(data[(data.startIndex + meta.dataSetOffset)...])
        return try DicomDataSetParser.dataSet(from: body, transferSyntax: syntax)
    }

    public static func image(_ request: DicomReformattedImageRequest) throws -> DicomReformattedImage {
        let sopClassUID = request.template.string(for: 0x0008_0016)?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)) ?? ""
        guard supportedSOPClassUIDs.contains(sopClassUID) else {
            throw DicomReformattedImageError.unsupportedSourceSOPClass(sopClassUID)
        }
        let vectors = request.imagePosition + request.rowDirection + request.columnDirection
        guard request.columns > 0, request.rows > 0, request.columns <= 65_535, request.rows <= 65_535,
              request.pixelSpacing.isFinite, request.pixelSpacing > 0,
              request.sliceThickness.isFinite, request.sliceThickness > 0,
              request.imagePosition.count == 3, request.rowDirection.count == 3, request.columnDirection.count == 3,
              vectors.allSatisfy(\.isFinite) else {
            throw DicomReformattedImageError.invalidGeometry
        }
        guard request.samples.count == request.columns * request.rows else {
            throw DicomReformattedImageError.sampleCountMismatch(
                expected: request.columns * request.rows, actual: request.samples.count
            )
        }

        var dataSet = DicomDataSet(elements: request.template.elements.filter(keepsFromTemplate))
        let encoded = encode(request.samples, as: request.sampleKind)
        let date = dateText(request.createdAt)
        let time = timeText(request.createdAt)

        func set(_ tag: Int, _ vr: DicomVR, _ values: [String]) {
            dataSet.set(.init(tag: tag, vr: vr, value: .strings(values)))
        }
        func set(_ tag: Int, unsigned value: Int) {
            dataSet.set(.init(tag: tag, vr: .US, value: .unsignedIntegers([UInt(value)])))
        }

        var imageType = ["DERIVED", "SECONDARY", "REFORMATTED"]
        switch request.projection {
        case .none: break
        case .mean: imageType.append("MEAN")
        case .maximum: imageType.append("MAX_IP")
        case .minimum: imageType.append("MIN_IP")
        // No defined term names a ray sum; the derivation description says what the values are.
        case .sum: break
        }
        set(0x0008_0008, .CS, imageType)
        set(0x0008_0012, .DA, [date])
        set(0x0008_0013, .TM, [time])
        set(0x0008_0016, .UI, [sopClassUID])
        set(0x0008_0018, .UI, [request.sopInstanceUID])
        set(0x0008_0023, .DA, [date])
        set(0x0008_0033, .TM, [time])
        set(0x0008_103E, .LO, [String(request.seriesDescription.prefix(64))])
        set(0x0008_2111, .ST, [derivationDescription(request)])
        var derivationCodes = [codeItem("113072", "DCM", "Multiplanar reformatting")]
        if request.projection == .maximum { derivationCodes.append(codeItem("113078", "DCM", "Maximum intensity projection")) }
        if request.projection == .minimum { derivationCodes.append(codeItem("113079", "DCM", "Minimum intensity projection")) }
        dataSet.set(.init(tag: 0x0008_9215, vr: .SQ, value: .sequence(derivationCodes)))
        if !request.sourceInstances.isEmpty {
            dataSet.set(.init(tag: 0x0008_2112, vr: .SQ, value: .sequence(request.sourceInstances.map { source in
                DicomSequenceItem(dataSet: DicomDataSet(elements: [
                    .init(tag: 0x0008_1150, vr: .UI, value: .strings([source.sopClassUID])),
                    .init(tag: 0x0008_1155, vr: .UI, value: .strings([source.sopInstanceUID])),
                    .init(tag: 0x0040_A170, vr: .SQ, value: .sequence([
                        codeItem("121322", "DCM", "Source image for image processing operation")
                    ]))
                ]))
            })))
        }

        set(0x0018_0050, .DS, [decimalText(request.sliceThickness)])
        if let spacing = request.spacingBetweenSlices, spacing.isFinite, spacing > 0 {
            set(0x0018_0088, .DS, [decimalText(spacing)])
        }
        set(0x0020_000E, .UI, [request.seriesInstanceUID])
        set(0x0020_0011, .IS, [String(request.seriesNumber)])
        set(0x0020_0013, .IS, [String(request.instanceNumber)])
        set(0x0020_0032, .DS, request.imagePosition.map(decimalText))
        set(0x0020_0037, .DS, (request.rowDirection + request.columnDirection).map(decimalText))
        if let frameOfReferenceUID = request.frameOfReferenceUID, !frameOfReferenceUID.isEmpty {
            set(0x0020_0052, .UI, [frameOfReferenceUID])
        }
        // Along the stack's own normal, so it orders the slices of this series.
        let normal = cross(request.rowDirection, request.columnDirection)
        set(0x0020_1041, .DS, [decimalText(zip(normal, request.imagePosition).reduce(0) { $0 + $1.0 * $1.1 })])

        set(0x0028_0002, unsigned: 1)
        set(0x0028_0004, .CS, ["MONOCHROME2"])
        set(0x0028_0010, unsigned: request.rows)
        set(0x0028_0011, unsigned: request.columns)
        set(0x0028_0030, .DS, [decimalText(request.pixelSpacing), decimalText(request.pixelSpacing)])
        set(0x0028_0100, unsigned: 16)
        set(0x0028_0101, unsigned: 16)
        set(0x0028_0102, unsigned: 15)
        set(0x0028_0103, unsigned: request.sampleKind == .signedInteger ? 1 : 0)
        set(0x0028_0301, .CS, ["NO"])
        if let center = request.windowCenter, let width = request.windowWidth,
           center.isFinite, width.isFinite, width > 0 {
            set(0x0028_1050, .DS, [decimalText(center)])
            set(0x0028_1051, .DS, [decimalText(width)])
        }
        set(0x0028_1052, .DS, [decimalText(encoded.intercept)])
        set(0x0028_1053, .DS, [decimalText(encoded.slope)])
        if let rescaleType = request.template.string(for: 0x0028_1054), !rescaleType.isEmpty {
            set(0x0028_1054, .LO, [rescaleType])
        }
        if sopClassUID == petImageStorage {
            if let units = request.units, !units.isEmpty { set(0x0054_1001, .CS, [units]) }
            set(0x0054_1330, unsigned: request.instanceNumber)
        }
        dataSet.set(.init(tag: 0x7FE0_0010, vr: .OW, value: .bytes(encoded.bytes)))

        let data = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(
            transferSyntax: .explicitVRLittleEndian,
            mediaStorageSOPClassUID: sopClassUID,
            mediaStorageSOPInstanceUID: request.sopInstanceUID
        ))
        return DicomReformattedImage(data: data, sopClassUID: sopClassUID,
                                     rescaleSlope: encoded.slope, rescaleIntercept: encoded.intercept)
    }

    // MARK: - Template

    /// What of the source instance still holds for an image made from the whole series.
    static func keepsFromTemplate(_ element: DicomDataElement) -> Bool {
        let tag = element.tag
        let group = tag >> 16
        // Private elements describe the source's own pixels and acquisition in ways nobody here can vouch for.
        if group % 2 == 1 { return false }
        switch group {
        case 0x0002, 0x0028, 0x0088, 0x0400, 0x4FFE, 0x5200, 0x5400, 0x7FE0, 0xFFFA:
            // Lossy compression is a fact about the values themselves, and stays.
            return tag == 0x0028_2110 || tag == 0x0028_2112 || tag == 0x0028_2114
        case 0x6000 ... 0x60FF:
            return false
        default:
            break
        }
        return !replacedTags.contains(tag)
    }

    private static let replacedTags: Set<Int> = [
        0x0008_0008, 0x0008_0012, 0x0008_0013, 0x0008_0014, 0x0008_0018, 0x0008_0023, 0x0008_0033,
        0x0008_103E, 0x0008_1140, 0x0008_2111, 0x0008_2112, 0x0008_9215, 0x0008_1115, 0x0008_114A,
        0x0018_0050, 0x0018_0088,
        0x0020_000E, 0x0020_0011, 0x0020_0013, 0x0020_0020, 0x0020_0032, 0x0020_0037, 0x0020_1041, 0x0020_4000,
        0x0020_9056, 0x0020_9057, 0x0020_1002
    ]

    // MARK: - Pixels

    static func encode(_ samples: [Float], as kind: DicomReformattedImageRequest.SampleKind)
        -> (bytes: Data, slope: Double, intercept: Double) {
        var bytes = Data(count: samples.count * 2)
        switch kind {
        case .signedInteger:
            bytes.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: Int16.self)
                for (index, sample) in samples.enumerated() {
                    let value = sample.isFinite ? sample.rounded() : 0
                    words[index] = Int16(max(-32_768, min(32_767, value))).littleEndian
                }
            }
            return (bytes, 1, 0)
        case .unsignedInteger:
            bytes.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: UInt16.self)
                for (index, sample) in samples.enumerated() {
                    let value = sample.isFinite ? sample.rounded() : 0
                    words[index] = UInt16(max(0, min(65_535, value))).littleEndian
                }
            }
            return (bytes, 1, 0)
        case .real:
            var lower = Float.greatestFiniteMagnitude
            var upper = -Float.greatestFiniteMagnitude
            for sample in samples where sample.isFinite {
                lower = min(lower, sample)
                upper = max(upper, sample)
            }
            guard lower <= upper else { return (bytes, 1, 0) }
            let intercept = Double(lower)
            let slope = upper > lower ? (Double(upper) - Double(lower)) / 65_535 : 1
            bytes.withUnsafeMutableBytes { raw in
                let words = raw.bindMemory(to: UInt16.self)
                for (index, sample) in samples.enumerated() {
                    let stored = sample.isFinite ? ((Double(sample) - intercept) / slope).rounded() : 0
                    words[index] = UInt16(max(0, min(65_535, stored))).littleEndian
                }
            }
            return (bytes, slope, intercept)
        }
    }

    // MARK: - Text

    private static func derivationDescription(_ request: DicomReformattedImageRequest) -> String {
        var text = "Multiplanar reformat of the source series, \(decimalText(request.sliceThickness)) mm"
        switch request.projection {
        case .none: text += " plane"
        case .mean: text += " slab, mean"
        case .maximum: text += " slab, maximum intensity projection"
        case .minimum: text += " slab, minimum intensity projection"
        case .sum: text += " slab, sum of the values above the volume's minimum, divided by the slab thickness"
        }
        text += ". Reconstructed values, trilinear interpolation."
        let remaining = 1024 - text.unicodeScalars.count - 1
        if remaining > 0,
           let note = request.derivationNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            text += " " + String(note.unicodeScalars.prefix(remaining))
        }
        return text
    }

    private static func codeItem(_ value: String, _ scheme: String, _ meaning: String) -> DicomSequenceItem {
        DicomSequenceItem(dataSet: DicomDataSet(elements: [
            .init(tag: 0x0008_0100, vr: .SH, value: .strings([value])),
            .init(tag: 0x0008_0102, vr: .SH, value: .strings([scheme])),
            .init(tag: 0x0008_0104, vr: .LO, value: .strings([meaning]))
        ]))
    }

    private static func cross(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
        [lhs[1] * rhs[2] - lhs[2] * rhs[1], lhs[2] * rhs[0] - lhs[0] * rhs[2], lhs[0] * rhs[1] - lhs[1] * rhs[0]]
    }

    /// A DS value: at most 16 characters, with as many digits as fit.
    static func decimalText(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        for precision in stride(from: 15, through: 1, by: -1) {
            let text = String(format: "%.\(precision)g", locale: Locale(identifier: "en_US_POSIX"), value)
            if text.count <= 16 { return text }
        }
        return String(format: "%.6e", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func dateText(_ date: Date) -> String { formatted(date, "yyyyMMdd") }
    private static func timeText(_ date: Date) -> String { formatted(date, "HHmmss") }

    private static func formatted(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
