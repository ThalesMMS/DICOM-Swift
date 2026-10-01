import CoreGraphics
import Foundation
import ImageIO

public enum DicomPrintTag {
    public static let memoryAllocation = 0x20000060
    public static let ownerID = 0x21000160
    public static let proposedStudySequence = 0x213000A0
    public static let smoothingType = 0x20100080
    public static let minDensity = 0x20100120
    public static let maxDensity = 0x20100130
    public static let illumination = 0x2010015E
    public static let reflectedAmbientLight = 0x20100160
    public static let requestedResolutionID = 0x20200050
    public static let polarity = 0x20200020
    public static let requestedImageSize = 0x20200030
    public static let requestedDecimateCropBehavior = 0x20200040
    public static let originalImageSequence = 0x213000C0
    public static let presentationLUTSequence = 0x20500010
    public static let presentationLUTShape = 0x20500020
    public static let referencedPresentationLUTSequence = 0x20500500
    public static let lutDescriptor = 0x00283002
    public static let lutData = 0x00283006
    public static let executionStatus = 0x21000020
    public static let executionStatusInfo = 0x21000030
    public static let creationDate = 0x21000040
    public static let creationTime = 0x21000050
    public static let originator = 0x21000070
    public static let referencedPrintJobSequence = 0x21000500
    public static let printerConfigurationSequence = 0x2000001E
    public static let sopClassesSupported = 0x0008115A
    public static let maximumMemoryAllocation = 0x20000061
    public static let memoryBitDepth = 0x200000A0
    public static let printingBitDepth = 0x200000A1
    public static let mediaInstalledSequence = 0x200000A2
    public static let otherMediaAvailableSequence = 0x200000A4
    public static let supportedImageDisplayFormatsSequence = 0x200000A8
    public static let printerResolutionID = 0x20100052
    public static let printerPixelSpacing = 0x20100376
    public static let requestedImageSizeFlag = 0x202000A0
    public static let defaultPrinterResolutionID = 0x20100054
    public static let defaultMagnificationType = 0x201000A6
    public static let otherMagnificationTypesAvailable = 0x201000A7
    public static let defaultSmoothingType = 0x201000A8
    public static let otherSmoothingTypesAvailable = 0x201000A9
    public static let configurationInformationDescription = 0x20100152
    public static let maximumCollatedFilms = 0x20100154
    public static let decimateCropResult = 0x202000A2

    public static let numberOfCopies = 0x2000_0010
    public static let printPriority = 0x2000_0020
    public static let mediumType = 0x2000_0030
    public static let filmDestination = 0x2000_0040
    public static let filmSessionLabel = 0x2000_0050
    public static let printerStatus = 0x2110_0010
    public static let printerStatusInfo = 0x2110_0020
    public static let printerName = 0x2110_0030
    public static let imageDisplayFormat = 0x2010_0010
    public static let filmOrientation = 0x2010_0040
    public static let filmSizeID = 0x2010_0050
    public static let magnificationType = 0x2010_0060
    public static let borderDensity = 0x2010_0100
    public static let emptyImageDensity = 0x2010_0110
    public static let trim = 0x2010_0140
    public static let configurationInformation = 0x2010_0150
    public static let referencedFilmSessionSequence = 0x2010_0500
    public static let referencedImageBoxSequence = 0x2010_0510
    public static let imagePosition = 0x2020_0010
    public static let basicGrayscaleImageSequence = 0x2020_0110
    public static let basicColorImageSequence = 0x2020_0111
    // Basic Annotation Box (issue #1908)
    public static let annotationDisplayFormatID = 0x2010_0030
    public static let referencedBasicAnnotationBoxSequence = 0x2010_0520
    public static let annotationPosition = 0x2030_0010
    public static let textString = 0x2030_0020
}

public enum DicomPrintPriority: String, Codable, Equatable, Sendable {
    case low = "LOW"
    case medium = "MED"
    case high = "HIGH"
}

public enum DicomFilmOrientation: String, Codable, Equatable, Sendable {
    case portrait = "PORTRAIT"
    case landscape = "LANDSCAPE"
}

public enum DicomFilmDestination: String, Codable, Equatable, Sendable {
    case magazine = "MAGAZINE"
    case processor = "PROCESSOR"
    case bin = "BIN"
}

public enum DicomPrintManagementError: Error, Equatable, LocalizedError, Sendable {
    case emptyImageList
    case invalidImagePosition(Int)
    case unsupportedSnapshotData
    case unsupportedService(String)
    /// The printer created fewer Basic Grayscale or Color Image Boxes than the film box
    /// asked for — the conformant answer to a film box holding more images than
    /// its layout has slots. The image boxes that were not granted have no SOP
    /// Instance UID, so there is nothing to N-SET them onto; the job is
    /// reported with both counts instead of being sent to invented UIDs.
    case insufficientImageBoxes(requested: Int, granted: Int)
    /// The job holds more images than its film box's Image Display Format
    /// has slots, or addresses a position beyond the last slot (issue
    /// #1907). Refused before any association: sending it is the direct
    /// route to `insufficientImageBoxes` — or, on a lenient printer, to a
    /// scrambled film.
    case imageCountExceedsLayout(imageCount: Int, capacity: Int)
    /// An annotation is malformed before any association: empty or over-long
    /// text, a non-positive or duplicate position, or annotations on a film
    /// box that names no Annotation Display Format ID (issue #1908).
    case invalidAnnotation(reason: String)
    /// The job carries annotations but the SCP accepted no Basic Annotation
    /// Box presentation context. Nothing was created and nothing was
    /// printed: the caller decides whether to burn identification into the
    /// pixels or stop — the core never silently prints an unidentified film.
    case annotationBoxNotNegotiated
    /// The film box N-CREATE response referenced fewer Basic Annotation
    /// Boxes than the job's annotations (or none at all). No annotation UID
    /// is ever invented and no N-SET is sent; both counts go back to the
    /// caller (issue #1908).
    case insufficientAnnotationBoxes(requested: Int, granted: Int)
    /// The printer refused the N-SET of one annotation. The film was not
    /// printed: the N-ACTION is never sent after a failed annotation,
    /// because that would print a film without the identification the
    /// preview showed.
    case annotationSetFailed(position: Int, status: UInt16)
    /// None of the presentation contexts required by the requested print mode
    /// were accepted. Explicit color never falls back to grayscale.
    case printModeNotNegotiated(DicomPrintMode)

    case limitExceeded(String)
    case expectedImageBoxCountRequired
    case invalidPresentationLUT
    case sopClassMismatch(expected: String, received: String?)
    case missingCreatedUID(String)
    case printerFailure(statusInfo: String?)
    case printJobFailure(statusInfo: DicomPrintExecutionStatusInfo?)
    case monitoringTimedOut
    case annotationIgnored(position: Int, status: UInt16)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .limitExceeded(let limit): return "Print limit exceeded: \(limit)."
        case .expectedImageBoxCountRequired: return "This layout requires expectedImageBoxCount."
        case .invalidPresentationLUT: return "Invalid Presentation LUT descriptor or data."
        case .sopClassMismatch(let expected, let received):
            return "Expected SOP Class \(expected), received \(received ?? "missing")."
        case .missingCreatedUID(let sop): return "N-CREATE returned no usable identity for \(sop)."
        case .printerFailure(let info): return "Printer failure: \(info ?? "UNKNOWN")."
        case .printJobFailure(let info): return "Print Job failure: \(info?.rawValue ?? "UNKNOWN")."
        case .monitoringTimedOut: return "Print monitoring timed out; completion is unknown."
        case .annotationIgnored(let position, let status):
            return "Annotation \(position) may have been ignored (\(status))."
        case .cancelled: return "Print job cancelled."
        case .emptyImageList:
            return "A print job must contain at least one image box."
        case .invalidImagePosition(let position):
            return "Invalid image box position \(position)."
        case .unsupportedSnapshotData:
            return "Snapshot data could not be decoded into an RGB bitmap."
        case .unsupportedService(let service):
            return "Unsupported DICOM print management service: \(service)."
        case .insufficientImageBoxes(let requested, let granted):
            return "The printer granted \(granted) image box(es) for a film box that requested "
                + "\(requested). Nothing was printed: the missing image boxes do not exist on the printer."
        case .imageCountExceedsLayout(let imageCount, let capacity):
            return "The job holds \(imageCount) image(s) but the film layout has \(capacity) "
                + "image box(es). Split the job across films or choose a larger layout."
        case .invalidAnnotation(let reason):
            return "Invalid print annotation: \(reason)"
        case .annotationBoxNotNegotiated:
            return "The printer accepted no Basic Annotation Box presentation context. Nothing was "
                + "printed: the film would have come out without the identification it was approved with."
        case .insufficientAnnotationBoxes(let requested, let granted):
            return "The printer granted \(granted) annotation box(es) for a film that requested "
                + "\(requested). Nothing was printed: the missing annotation boxes do not exist on the printer."
        case .annotationSetFailed(let position, let status):
            return String(format: "The printer refused the annotation at position %d (status 0x%04X). "
                + "The film was not printed.", position, status)
        case .printModeNotNegotiated(.color):
            return "The printer did not accept Basic Color Print Management. Nothing was printed, "
                + "and color was not converted to grayscale."
        case .printModeNotNegotiated(.grayscale):
            return "The printer did not accept Basic Grayscale Print Management. Nothing was printed."
        case .printModeNotNegotiated(.automatic):
            return "The printer accepted neither Basic Color nor Basic Grayscale Print Management. Nothing was printed."
        }
    }
}

/// Since issue #1908, Basic Annotation Box is a supported service — it is no
/// longer in this list.
public enum DicomPrintManagementUnsupportedService: String, CaseIterable, Sendable {
    case storageCommitment = "Storage Commitment"
}

public enum DicomPrinterStatusState: String, Equatable, Sendable {
    case normal = "NORMAL"
    case warning = "WARNING"
    case failure = "FAILURE"
    case unknown = "UNKNOWN"
}

public enum DicomPrinterStatusSource: Equatable, Sendable {
    case nGet
    case nEventReport(eventTypeID: UInt16)
}

/// One Printer SOP status observation. N-GET supplies the status explicitly;
/// N-EVENT-REPORT identifies it through Event Type 1/2/3.
public struct DicomPrinterStatusReport: Equatable, Sendable {
    public var operationStatus: UInt16
    public var state: DicomPrinterStatusState
    public var statusInfo: String?
    public var printerName: String?
    public var source: DicomPrinterStatusSource

    public init(state: DicomPrinterStatusState,
                statusInfo: String? = nil,
                printerName: String? = nil,
                source: DicomPrinterStatusSource, operationStatus: UInt16 = 0) {
        self.operationStatus = operationStatus
        self.state = state
        self.statusInfo = statusInfo
        self.printerName = printerName
        self.source = source
    }
}

public enum DicomPrintManagementSupport {
    public static let supportedSOPClassUIDs: Set<String> = [
        DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
        DicomNetworkUID.basicColorPrintManagementMetaSOPClass,
        DicomNetworkUID.basicFilmSessionSOPClass,
        DicomNetworkUID.basicFilmBoxSOPClass,
        DicomNetworkUID.basicGrayscaleImageBoxSOPClass,
        DicomNetworkUID.basicColorImageBoxSOPClass,
        DicomNetworkUID.basicAnnotationBoxSOPClass,
        DicomNetworkUID.printerSOPClass,
        DicomNetworkUID.presentationLUTSOPClass,
        DicomNetworkUID.printJobSOPClass,
        DicomNetworkUID.printerConfigurationRetrievalSOPClass
    ]

    public static let unsupportedServices = Set(DicomPrintManagementUnsupportedService.allCases)

    public static func rejectUnsupported(_ service: DicomPrintManagementUnsupportedService) throws {
        throw DicomPrintManagementError.unsupportedService(service.rawValue)
    }
}

public struct DicomFilmSession: Equatable, Sendable {
    public var numberOfCopies: Int
    public var printPriority: DicomPrintPriority
    public var mediumType: String
    public var filmDestination: DicomFilmDestination
    public var label: String?
    public var updates: DicomDataSet?

    public init(numberOfCopies: Int = 1,
                printPriority: DicomPrintPriority = .medium,
                mediumType: String = "BLUE FILM",
                filmDestination: DicomFilmDestination = .magazine,
                label: String? = nil) {
        self.numberOfCopies = max(1, numberOfCopies)
        self.printPriority = printPriority
        self.mediumType = mediumType
        self.filmDestination = filmDestination
        self.label = label
    }

    public var dataSet: DicomDataSet {
        DicomDataSet(elements: [
            printString(DicomPrintTag.numberOfCopies, .IS, String(numberOfCopies)),
            printString(DicomPrintTag.printPriority, .CS, printPriority.rawValue),
            printString(DicomPrintTag.mediumType, .CS, mediumType),
            printString(DicomPrintTag.filmDestination, .CS, filmDestination.rawValue),
            printString(DicomPrintTag.filmSessionLabel, .LO, label)
        ].filter { !$0.isEmptyValue })
    }
}

public struct DicomFilmBox: Equatable, Sendable {
    public var imageDisplayFormat: String
    public var orientation: DicomFilmOrientation
    public var filmSizeID: String
    public var magnificationType: String?
    public var borderDensity: String?
    public var emptyImageDensity: String?
    public var trim: Bool
    public var configurationInformation: String?
    /// `Annotation Display Format ID` (2010,0030) — the printer-specific
    /// annotation format from its conformance statement (issue #1908). Sent
    /// only when set: there is no universal default to presume, and a film
    /// box that requests no annotations must not carry the attribute.
    public var annotationDisplayFormatID: String?
    public var expectedImageBoxCount: Int?
    public var illumination: UInt16?
    public var reflectedAmbientLight: UInt16?
    public var requestedResolutionID: String?
    public var updates: DicomDataSet?

    public init(imageDisplayFormat: String = "STANDARD\\1,1",
                orientation: DicomFilmOrientation = .portrait,
                filmSizeID: String = "8INX10IN",
                magnificationType: String? = "REPLICATE",
                borderDensity: String? = "BLACK",
                emptyImageDensity: String? = "BLACK",
                trim: Bool = false,
                configurationInformation: String? = nil,
                annotationDisplayFormatID: String? = nil) {
        self.imageDisplayFormat = imageDisplayFormat
        self.orientation = orientation
        self.filmSizeID = filmSizeID
        self.magnificationType = magnificationType
        self.borderDensity = borderDensity
        self.emptyImageDensity = emptyImageDensity
        self.trim = trim
        self.configurationInformation = configurationInformation
        self.annotationDisplayFormatID = annotationDisplayFormatID
    }

    /// A film box whose Image Display Format is typed from the start
    /// (issue #1907). Stores the canonical wire value; the stringly
    /// initializer above remains for source compatibility.
    public init(displayFormat: DicomImageDisplayFormat,
                orientation: DicomFilmOrientation = .portrait,
                filmSizeID: String = "8INX10IN",
                magnificationType: String? = "REPLICATE",
                borderDensity: String? = "BLACK",
                emptyImageDensity: String? = "BLACK",
                trim: Bool = false,
                configurationInformation: String? = nil,
                annotationDisplayFormatID: String? = nil) {
        self.init(imageDisplayFormat: displayFormat.wireValue,
                  orientation: orientation,
                  filmSizeID: filmSizeID,
                  magnificationType: magnificationType,
                  borderDensity: borderDensity,
                  emptyImageDensity: emptyImageDensity,
                  trim: trim,
                  configurationInformation: configurationInformation,
                  annotationDisplayFormatID: annotationDisplayFormatID)
    }

    /// The strictly parsed Image Display Format, or `nil` when the stored
    /// string is not a valid wire value. Parsing failures carry no detail
    /// here — parse with `DicomImageDisplayFormat(wireValue:)` directly to
    /// learn why a value was refused.
    public var typedImageDisplayFormat: DicomImageDisplayFormat? {
        try? DicomImageDisplayFormat(wireValue: imageDisplayFormat)
    }

    public func dataSet(referencingFilmSessionUID filmSessionUID: String) -> DicomDataSet {
        DicomDataSet(elements: [
            printString(DicomPrintTag.imageDisplayFormat, .ST, imageDisplayFormat),
            printString(DicomPrintTag.filmOrientation, .CS, orientation.rawValue),
            printString(DicomPrintTag.filmSizeID, .CS, filmSizeID),
            printString(DicomPrintTag.magnificationType, .CS, magnificationType),
            printString(DicomPrintTag.borderDensity, .CS, borderDensity),
            printString(DicomPrintTag.emptyImageDensity, .CS, emptyImageDensity),
            printString(DicomPrintTag.trim, .CS, trim ? "YES" : "NO"),
            printString(DicomPrintTag.configurationInformation, .ST, configurationInformation),
            printString(DicomPrintTag.annotationDisplayFormatID, .CS, annotationDisplayFormatID),
            printSequence(DicomPrintTag.referencedFilmSessionSequence, [
                referenceDataSet(
                    sopClassUID: DicomNetworkUID.basicFilmSessionSOPClass,
                    sopInstanceUID: filmSessionUID
                )
            ])
        ].filter { !$0.isEmptyValue })
    }
}

public struct DicomPrintTemplate: Equatable, Sendable {
    public var filmSession: DicomFilmSession
    public var filmBox: DicomFilmBox
    public var imageSize: DicomImageSize?

    public init(filmSession: DicomFilmSession = DicomFilmSession(),
                filmBox: DicomFilmBox = DicomFilmBox(),
                imageSize: DicomImageSize? = nil) {
        self.filmSession = filmSession
        self.filmBox = filmBox
        self.imageSize = imageSize
    }

    public static func singleImage(label: String? = nil,
                                   imageSize: DicomImageSize? = nil) -> DicomPrintTemplate {
        DicomPrintTemplate(
            filmSession: DicomFilmSession(label: label),
            filmBox: DicomFilmBox(imageDisplayFormat: "STANDARD\\1,1"),
            imageSize: imageSize
        )
    }
}

/// One line of text on one Basic Annotation Box (issue #1908).
public struct DicomPrintAnnotation: Equatable, Sendable {
    /// `Text String` (2030,0020) is LO: 64 characters at most.
    public static let maximumTextLength = 64

    /// `Annotation Position` (2030,0010), one-based, per the printer's
    /// Annotation Display Format.
    public let position: Int
    public let text: String

    public init(position: Int, text: String) throws {
        guard position > 0 else {
            throw DicomPrintManagementError.invalidAnnotation(
                reason: "annotation position must be positive, got \(position).")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw DicomPrintManagementError.invalidAnnotation(
                reason: "annotation text at position \(position) is empty.")
        }
        guard trimmed.count <= Self.maximumTextLength else {
            throw DicomPrintManagementError.invalidAnnotation(
                reason: "annotation text at position \(position) exceeds "
                    + "\(Self.maximumTextLength) characters (LO). Truncating silently is not this type's call.")
        }
        self.position = position
        self.text = trimmed
    }

    public var dataSet: DicomDataSet {
        DicomDataSet(elements: [
            printUnsigned(DicomPrintTag.annotationPosition, .US, UInt(position)),
            printString(DicomPrintTag.textString, .LO, text)
        ])
    }
}

public struct DicomImageBox: Equatable, Sendable {
    public var position: Int
    public var bitmap: DicomRenderedBitmap
    public var requestedImageSize: Double?
    public var forceRequestedImageSize = false
    public var requestedDecimateCropBehavior: DicomPrintDecimateCropBehavior?
    public var originalImage: DicomDataSet?
    public var polarity: DicomPrintPolarity = .normal

    public init(position: Int = 1, bitmap: DicomRenderedBitmap) throws {
        guard position > 0 else {
            throw DicomPrintManagementError.invalidImagePosition(position)
        }
        self.position = position
        self.bitmap = bitmap
    }

    public var dataSet: DicomDataSet {
        dataSet(for: .grayscale)
    }

    func dataSet(for mode: DicomResolvedPrintMode) -> DicomDataSet {
        let sequenceTag: Int
        let imageDataSet: DicomDataSet
        switch mode {
        case .grayscale:
            sequenceTag = DicomPrintTag.basicGrayscaleImageSequence
            imageDataSet = grayscaleImageDataSet
        case .color:
            sequenceTag = DicomPrintTag.basicColorImageSequence
            imageDataSet = colorImageDataSet
        }
        return DicomDataSet(elements: [
            printUnsigned(DicomPrintTag.imagePosition, .US, UInt(position)),
            printSequence(sequenceTag, [imageDataSet])
        ])
    }

    private var grayscaleImageDataSet: DicomDataSet {
        DicomDataSet(elements: [
            printUnsigned(DicomTag.samplesPerPixel.rawValue, .US, 1),
            printString(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
            printUnsigned(DicomTag.rows.rawValue, .US, UInt(bitmap.height)),
            printUnsigned(DicomTag.columns.rawValue, .US, UInt(bitmap.width)),
            printUnsigned(DicomTag.bitsAllocated.rawValue, .US, 8),
            printUnsigned(DicomTag.bitsStored.rawValue, .US, 8),
            printUnsigned(DicomTag.highBit.rawValue, .US, 7),
            printUnsigned(DicomTag.pixelRepresentation.rawValue, .US, 0),
            printBytes(DicomTag.pixelData.rawValue, .OB, grayscalePixelData)
        ])
    }

    private var colorImageDataSet: DicomDataSet {
        var planarPixelData = Data()
        planarPixelData.reserveCapacity(bitmap.rgbData.count)
        for channel in 0..<3 {
            for offset in stride(from: channel, to: bitmap.rgbData.count, by: 3) {
                planarPixelData.append(bitmap.rgbData[offset])
            }
        }
        return DicomDataSet(elements: [
            printUnsigned(DicomTag.samplesPerPixel.rawValue, .US, 3),
            printString(DicomTag.photometricInterpretation.rawValue, .CS, "RGB"),
            printUnsigned(DicomTag.planarConfiguration.rawValue, .US, 1),
            printUnsigned(DicomTag.rows.rawValue, .US, UInt(bitmap.height)),
            printUnsigned(DicomTag.columns.rawValue, .US, UInt(bitmap.width)),
            printUnsigned(DicomTag.bitsAllocated.rawValue, .US, 8),
            printUnsigned(DicomTag.bitsStored.rawValue, .US, 8),
            printUnsigned(DicomTag.highBit.rawValue, .US, 7),
            printUnsigned(DicomTag.pixelRepresentation.rawValue, .US, 0),
            printBytes(DicomTag.pixelData.rawValue, .OB, planarPixelData)
        ])
    }

    private var grayscalePixelData: Data {
        DicomBitmapOperations.grayscaleData(fromRGB: bitmap.rgbData)
    }
}

public struct DicomPrintJob: Equatable, Sendable {
    public var cleanup = true
    public var monitor: DicomPrintMonitor = .none
    public var printScope: DicomPrintScope = .filmBox
    public var presentationLUT: DicomPresentationLUT?
    public var cancellationToken = DicomPrintCancellationToken()
    public var limits = DicomPrintLimits()
    public var films: [DicomFilm] = []
    public var effectiveFilms: [DicomFilm] {
        films.isEmpty ? [DicomFilm(id: id, sopInstanceUID: filmBoxSOPInstanceUID,
                                  filmBox: filmBox, imageBoxes: imageBoxes, annotations: annotations)] : films
    }
    public var id: String
    public var filmSessionSOPInstanceUID: String
    public var filmBoxSOPInstanceUID: String
    public var filmSession: DicomFilmSession
    public private(set) var filmBox: DicomFilmBox
    public var printMode: DicomPrintMode
    public var imageBoxes: [DicomImageBox]
    /// The film's annotation texts (issue #1908). Non-empty only when the
    /// film box names an Annotation Display Format ID; the SCU then requires
    /// a negotiated Basic Annotation Box context and never prints a film
    /// whose annotations could not be set.
    public private(set) var annotations: [DicomPrintAnnotation]

    public init(id: String = DicomDataSetWriter.makeUID(),
                filmSessionSOPInstanceUID: String = DicomDataSetWriter.makeUID(),
                filmBoxSOPInstanceUID: String = DicomDataSetWriter.makeUID(),
                filmSession: DicomFilmSession,
                filmBox: DicomFilmBox,
                printMode: DicomPrintMode = .grayscale,
                imageBoxes: [DicomImageBox],
                annotations: [DicomPrintAnnotation] = [],
                limits: DicomPrintLimits = DicomPrintLimits(),
                cleanup: Bool = true,
                monitor: DicomPrintMonitor = .none,
                printScope: DicomPrintScope = .filmBox,
                presentationLUT: DicomPresentationLUT? = nil,
                cancellationToken: DicomPrintCancellationToken = DicomPrintCancellationToken()) throws {
        guard !imageBoxes.isEmpty else {
            throw DicomPrintManagementError.emptyImageList
        }
        // Issue #1908: annotations need the printer-specific display format
        // on the film box — there is no universal default to presume — and
        // one text per position.
        if annotations.isEmpty == false {
            guard let formatID = filmBox.annotationDisplayFormatID,
                  formatID.trimmingCharacters(in: .whitespaces).isEmpty == false else {
                throw DicomPrintManagementError.invalidAnnotation(
                    reason: "the film box names no Annotation Display Format ID.")
            }
            var seenPositions = Set<Int>()
            for annotation in annotations {
                guard seenPositions.insert(annotation.position).inserted else {
                    throw DicomPrintManagementError.invalidAnnotation(
                        reason: "duplicate annotation position \(annotation.position).")
                }
            }
        }
        // Issue #1907: when the film box's Image Display Format is one of
        // the computable families, the typed capacity bounds the job before
        // any association opens. More images than slots, or a position past
        // the last slot, is the direct route to `insufficientImageBoxes` —
        // or to a lenient printer scrambling the film. `SLIDE`,
        // `SUPERSLIDE` and `CUSTOM` have printer-defined capacities and
        // stay unbounded here.
        if let capacity = filmBox.typedImageDisplayFormat?.imageBoxCapacity {
            guard imageBoxes.count <= capacity else {
                throw DicomPrintManagementError.imageCountExceedsLayout(
                    imageCount: imageBoxes.count, capacity: capacity)
            }
            for box in imageBoxes where box.position > capacity {
                throw DicomPrintManagementError.invalidImagePosition(box.position)
            }
        }
        try limits.validate(films: [DicomFilm(id: id, sopInstanceUID: filmBoxSOPInstanceUID,
                                            filmBox: filmBox, imageBoxes: imageBoxes, annotations: annotations)])
        self.limits = limits
        self.cleanup = cleanup
        self.monitor = monitor
        self.printScope = printScope
        self.presentationLUT = presentationLUT
        self.cancellationToken = cancellationToken
        self.id = id
        self.filmSessionSOPInstanceUID = filmSessionSOPInstanceUID
        self.filmBoxSOPInstanceUID = filmBoxSOPInstanceUID
        self.filmSession = filmSession
        self.filmBox = filmBox
        self.printMode = printMode
        self.imageBoxes = imageBoxes
        self.annotations = annotations
    }

    public init(renderedBitmap: DicomRenderedBitmap,
                template: DicomPrintTemplate = .singleImage(),
                id: String = DicomDataSetWriter.makeUID()) throws {
        let imageBox = try DicomImageBox(position: 1, bitmap: renderedBitmap)
        try self.init(id: id,
                      filmSession: template.filmSession,
                      filmBox: template.filmBox,
                      imageBoxes: [imageBox])
    }

    public init(decoder: DCMDecoder,
                template: DicomPrintTemplate = .singleImage(),
                options: DicomImagePreprocessOptions = DicomImagePreprocessOptions(),
                id: String = DicomDataSetWriter.makeUID()) throws {
        let renderOptions = DicomImagePreprocessOptions(
            frameIndex: options.frameIndex,
            displaySelection: options.displaySelection,
            outputSize: template.imageSize ?? options.outputSize,
            annotations: options.annotations
        )
        _ = try DicomPrintLimits().validateDimensions(width: renderOptions.outputSize?.width ?? decoder.width,
                                                      height: renderOptions.outputSize?.height ?? decoder.height)
        let bitmap = try DicomImagePreprocessor().render(decoder: decoder, options: renderOptions)
        try self.init(renderedBitmap: bitmap, template: template, id: id)
    }

    public init(snapshotPNGData: Data,
                template: DicomPrintTemplate = .singleImage(),
                id: String = DicomDataSetWriter.makeUID()) throws {
        let bitmap = try Self.bitmap(fromPNGData: snapshotPNGData)
        try self.init(renderedBitmap: bitmap, template: template, id: id)
    }

    private static func bitmap(fromPNGData data: Data) throws -> DicomRenderedBitmap {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let declaredWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let declaredHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw DicomPrintManagementError.unsupportedSnapshotData
        }
        _ = try DicomPrintLimits().validateDimensions(width: declaredWidth, height: declaredHeight)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DicomPrintManagementError.unsupportedSnapshotData
        }
        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let didRender = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: width * 4,
                                          space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didRender else {
            throw DicomPrintManagementError.unsupportedSnapshotData
        }

        var rgb = Data()
        rgb.reserveCapacity(width * height * 3)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(rgba[offset])
            rgb.append(rgba[offset + 1])
            rgb.append(rgba[offset + 2])
        }
        return try DicomRenderedBitmap(width: width, height: height, rgbData: rgb)
    }
}

public struct DicomPrintJobResult: Equatable, Sendable {
    public var operations: [DicomPrintOperationRecord] = []
    public var warnings: [DicomPrintOperationRecord] = []
    public var stateHistory: [DicomPrintJobState] = [.queued]
    public var state: DicomPrintJobState = .accepted {
        didSet { if stateHistory.last != state { stateHistory.append(state) } }
    }
    public var filmResults: [DicomPrintFilmResult] = []
    public var presentationLUTSOPInstanceUID: String?
    public var printJobSOPInstanceUIDs: [String] = []
    public var executionStatus: DicomPrintExecutionStatus?
    public var executionStatusInfo: DicomPrintExecutionStatusInfo?
    public var capabilities: DicomPrintPeerCapabilities?

    public var operation: DicomDIMSEOperationResult
    public var filmSessionSOPInstanceUID: String
    public var filmBoxSOPInstanceUID: String
    public var imageBoxSOPInstanceUIDs: [String]
    /// The Basic Annotation Box SOP Instance UIDs the printer created and
    /// the job set text onto, in annotation order (issue #1908). Empty for a
    /// job without annotations.
    public var annotationBoxSOPInstanceUIDs: [String]
    /// Printer SOP observations collected before and after film acceptance,
    /// including asynchronous events received while querying.
    public var printerStatusReports: [DicomPrinterStatusReport]

    public init(operation: DicomDIMSEOperationResult,
                filmSessionSOPInstanceUID: String,
                filmBoxSOPInstanceUID: String,
                imageBoxSOPInstanceUIDs: [String],
                annotationBoxSOPInstanceUIDs: [String] = [],
                printerStatusReports: [DicomPrinterStatusReport] = []) {
        self.operation = operation
        self.filmSessionSOPInstanceUID = filmSessionSOPInstanceUID
        self.filmBoxSOPInstanceUID = filmBoxSOPInstanceUID
        self.imageBoxSOPInstanceUIDs = imageBoxSOPInstanceUIDs
        self.annotationBoxSOPInstanceUIDs = annotationBoxSOPInstanceUIDs
        self.printerStatusReports = printerStatusReports
    }
}

public enum DicomPrintQueueStatus: String, Codable, Equatable, Sendable {
    case queued
    case sending
    case completed
    case failed
    case cancelled
}

public struct DicomPrintQueueEntry: Equatable, Sendable {
    public var id: String
    public var label: String?
    public var status: DicomPrintQueueStatus
    public var failureDescription: String?

    public init(id: String,
                label: String?,
                status: DicomPrintQueueStatus,
                failureDescription: String? = nil) {
        self.id = id
        self.label = label
        self.status = status
        self.failureDescription = failureDescription
    }
}

public final class DicomPrintJobQueue {
    private let lock = NSLock()
    private var order: [String] = []
    private var entriesByID: [String: DicomPrintQueueEntry] = [:]
    private var tokensByID: [String: DicomPrintCancellationToken] = [:]
    private var resultsByID: [String: DicomPrintJobResult] = [:]

    public func cancel(id: String) {
        lock.lock()
        defer { lock.unlock() }
        tokensByID[id]?.cancel()
        entriesByID[id]?.status = .cancelled
    }
    public func recordResult(id: String, result: DicomPrintJobResult) {
        lock.lock()
        defer { lock.unlock() }
        resultsByID[id] = result
        entriesByID[id]?.status = result.state == .cancelled ? .cancelled : result.state == .failed ? .failed : .completed
    }
    public func result(id: String) -> DicomPrintJobResult? {
        lock.lock()
        defer { lock.unlock() }
        return resultsByID[id]
    }

    public init() {}

    public var entries: [DicomPrintQueueEntry] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { entriesByID[$0] }
    }

    @discardableResult
    public func enqueue(_ job: DicomPrintJob) -> DicomPrintQueueEntry {
        lock.lock()
        defer { lock.unlock() }
        let entry = DicomPrintQueueEntry(
            id: job.id,
            label: job.filmSession.label,
            status: .queued
        )
        if entriesByID[job.id] == nil {
            order.append(job.id)
        }
        tokensByID[job.id] = job.cancellationToken
        entriesByID[job.id] = entry
        return entry
    }

    public func markSending(id: String) {
        update(id: id, status: .sending, failureDescription: nil)
    }

    public func markCompleted(id: String) {
        update(id: id, status: .completed, failureDescription: nil)
    }

    public func markFailed(id: String, failureDescription: String) {
        update(id: id, status: .failed, failureDescription: failureDescription)
    }

    private func update(id: String,
                        status: DicomPrintQueueStatus,
                        failureDescription: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entriesByID[id] else { return }
        entry.status = status
        entry.failureDescription = failureDescription
        entriesByID[id] = entry
    }
}

private func referenceDataSet(sopClassUID: String, sopInstanceUID: String) -> DicomDataSet {
    DicomDataSet(elements: [
        printString(DicomTag.referencedSOPClassUID.rawValue, .UI, sopClassUID),
        printString(DicomTag.referencedSOPInstanceUID.rawValue, .UI, sopInstanceUID)
    ])
}

private func printString(_ tag: Int, _ vr: DicomVR, _ value: String?) -> DicomDataElement {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    let dataValue: DicomDataValue
    if let trimmed, !trimmed.isEmpty {
        dataValue = .strings([trimmed])
    } else {
        dataValue = .empty
    }
    return DicomDataElement(tag: tag,
                            vr: vr,
                            value: dataValue)
}

private func printUnsigned(_ tag: Int, _ vr: DicomVR, _ value: UInt) -> DicomDataElement {
    DicomDataElement(tag: tag, vr: vr, value: .unsignedIntegers([value]))
}

private func printBytes(_ tag: Int, _ vr: DicomVR, _ value: Data) -> DicomDataElement {
    DicomDataElement(tag: tag, vr: vr, value: .bytes(value))
}

private func printSequence(_ tag: Int, _ dataSets: [DicomDataSet]) -> DicomDataElement {
    DicomDataElement(tag: tag,
                     vr: .SQ,
                     value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) }))
}

private extension DicomDataElement {
    var isEmptyValue: Bool {
        if case .empty = value {
            return true
        }
        return false
    }
}

public enum DicomPrintScope: Equatable, Sendable { case filmBox, filmSession }
public enum DicomPrintMonitor: Equatable, Sendable { case none, untilDone(timeout: TimeInterval) }
public enum DicomPrintJobState: String, Equatable, Sendable {
    case queued, preparing, sending, accepted, printing, done, failed, cancelled
}
public enum DicomPrintExecutionStatus: String, Equatable, Sendable {
    case pending = "PENDING", printing = "PRINTING", done = "DONE", failure = "FAILURE"
}
public enum DicomPrintDecimateCropBehavior: String, Equatable, Sendable {
    case decimate = "DECIMATE", crop = "CROP", fail = "FAIL"
}
public enum DicomPrintPolarity: String, Equatable, Sendable { case normal = "NORMAL", reverse = "REVERSE" }

public final class DicomPrintCancellationToken: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    public static func == (lhs: DicomPrintCancellationToken, rhs: DicomPrintCancellationToken) -> Bool { lhs === rhs }
}

public struct DicomPresentationLUT: Equatable, Sendable {
    public enum Shape: String, Equatable, Sendable { case identity = "IDENTITY", linearOpticalDensity = "LIN OD" }
    public let shape: Shape?
    public let descriptor: [UInt16]
    public let values: [UInt16]
    public init(shape: Shape) { self.shape = shape; descriptor = []; values = [] }
    public init(descriptor: [UInt16], values: [UInt16]) throws {
        guard descriptor.count == 3, [256, 4096].contains(descriptor[0]), descriptor[1] == 0,
              (10...16).contains(descriptor[2]), values.count == Int(descriptor[0]),
              values.allSatisfy({ UInt32($0) < (UInt32(1) << descriptor[2]) }) else {
            throw DicomPrintManagementError.invalidPresentationLUT
        }
        self.shape = nil; self.descriptor = descriptor; self.values = values
    }
    public var dataSet: DicomDataSet {
        if let shape { return DicomDataSet(elements: [printString(0x2050_0020, .CS, shape.rawValue)]) }
        var bytes = Data()
        for value in values { bytes.append(UInt8(truncatingIfNeeded: value)); bytes.append(UInt8(value >> 8)) }
        return DicomDataSet(elements: [printSequence(0x2050_0010, [DicomDataSet(elements: [
            DicomDataElement(tag: 0x0028_3002, vr: .US, value: .unsignedIntegers(descriptor.map(UInt.init))),
            printBytes(0x0028_3006, .OW, bytes)
        ])])])
    }
}

public struct DicomFilm: Equatable, Sendable {
    public var id: String
    public var sopInstanceUID: String
    public var filmBox: DicomFilmBox
    public var imageBoxes: [DicomImageBox]
    public var annotations: [DicomPrintAnnotation]
    public init(id: String = DicomDataSetWriter.makeUID(),
                sopInstanceUID: String = DicomDataSetWriter.makeUID(), filmBox: DicomFilmBox,
                imageBoxes: [DicomImageBox], annotations: [DicomPrintAnnotation] = []) {
        self.id = id; self.sopInstanceUID = sopInstanceUID; self.filmBox = filmBox
        self.imageBoxes = imageBoxes; self.annotations = annotations
    }

    /// Snapshot input for the shared film compositor. Decoding retains the A1
    /// snapshot admission checks; the typed layout controls subsequent composition.
    public init(snapshotPNGData: Data, layout: DicomImageDisplayFormat) throws {
        let job = try DicomPrintJob(snapshotPNGData: snapshotPNGData)
        self.init(filmBox: DicomFilmBox(displayFormat: layout), imageBoxes: job.imageBoxes)
    }
}

public struct DicomPrintLimits: Equatable, Sendable {
    public var maximumFilmsPerJob: Int
    public var imageBoxesPerFilm: Int
    public var bytesPerImageBox: Int
    public var bytesPerFilm: Int
    public var bytesPerJob: Int
    public var annotationsPerFilm: Int
    public init(maximumFilmsPerJob: Int = 100, imageBoxesPerFilm: Int = 100,
                bytesPerImageBox: Int = 256 * 1024 * 1024, bytesPerFilm: Int = 512 * 1024 * 1024,
                bytesPerJob: Int = 1024 * 1024 * 1024, annotationsPerFilm: Int = 100) {
        self.maximumFilmsPerJob = maximumFilmsPerJob; self.imageBoxesPerFilm = imageBoxesPerFilm
        self.bytesPerImageBox = bytesPerImageBox; self.bytesPerFilm = bytesPerFilm
        self.bytesPerJob = bytesPerJob; self.annotationsPerFilm = annotationsPerFilm
    }
    public func validateDimensions(width: Int, height: Int) throws -> Int {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 3)
        guard width > 0, height > 0, width <= 65535, height <= 65535,
              !overflow, !byteOverflow, bytes <= bytesPerImageBox else {
            throw DicomPrintManagementError.limitExceeded("bytesPerImageBox or dimensions")
        }
        return bytes
    }
    public func validate(films: [DicomFilm]) throws {
        try validate(inputs: films.map { film in
            DicomPrintFilmInput(id: film.id, filmBox: film.filmBox, images: film.imageBoxes.map { box in
                DicomPrintImageInput(width: box.bitmap.width, height: box.bitmap.height) { box.bitmap }
            }, annotations: film.annotations)
        })
        for film in films {
            let capacity = try DicomImageDisplayFormat(wireValue: film.filmBox.imageDisplayFormat).imageBoxCapacity
                ?? film.filmBox.expectedImageBoxCount ?? 0
            var positions = Set<Int>()
            for box in film.imageBoxes {
                guard box.position > 0, box.position <= capacity, positions.insert(box.position).inserted else {
                    throw DicomPrintManagementError.invalidImagePosition(box.position)
                }
            }
        }
    }
}

extension DicomPrintJob {
    public init(films: [DicomFilm], filmSession: DicomFilmSession = DicomFilmSession(),
                printMode: DicomPrintMode = .grayscale, printScope: DicomPrintScope = .filmBox,
                limits: DicomPrintLimits = DicomPrintLimits(), cleanup: Bool = true,
                monitor: DicomPrintMonitor = .none, presentationLUT: DicomPresentationLUT? = nil,
                cancellationToken: DicomPrintCancellationToken = DicomPrintCancellationToken()) throws {
        try limits.validate(films: films)
        let first = films[0]
        try self.init(filmBoxSOPInstanceUID: first.sopInstanceUID, filmSession: filmSession,
                      filmBox: first.filmBox, printMode: printMode, imageBoxes: first.imageBoxes,
                      annotations: first.annotations, limits: limits, cleanup: cleanup, monitor: monitor,
                      printScope: printScope, presentationLUT: presentationLUT, cancellationToken: cancellationToken)
        self.films = films
    }
}

public struct DicomPrintFilmResult: Equatable, Sendable {
    public var operations: [DicomPrintOperationRecord] = []
    public var printJobSOPInstanceUIDs: [String] = []
    public var id: String
    public var sopInstanceUID: String?
    public var imageBoxSOPInstanceUIDs: [String] = []
    public var annotationBoxSOPInstanceUIDs: [String] = []
    public var state: DicomPrintJobState = .queued
    public var failureDescription: String?
}
public struct DicomPrintBatch: Equatable, Sendable {
    public let jobs: [DicomPrintJob]
    public init(jobs: [DicomPrintJob], limits: DicomPrintLimits = DicomPrintLimits()) throws {
        try limits.validate(films: jobs.flatMap(\.effectiveFilms)); self.jobs = jobs
    }
}
public struct DicomPrintBatchResult: Equatable, Sendable {
    public var results: [DicomPrintJobResult] = []
    public var films: [DicomPrintFilmResult] = []
}

public struct DicomPrintOperationRecord: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case create, set, action, get, delete, eventReport }
    public var kind: Kind
    public var sopClassUID: String
    public var sopInstanceUID: String?
    public var status: UInt16?
    public var warningMeaning: String?
    public var eventTypeID: UInt16?
    public var executionStatus: DicomPrintExecutionStatus?
    public var executionStatusInfo: DicomPrintExecutionStatusInfo?
    public init(kind: Kind, sopClassUID: String, sopInstanceUID: String?, status: UInt16?, warningMeaning: String? = nil) {
        self.kind = kind; self.sopClassUID = sopClassUID; self.sopInstanceUID = sopInstanceUID; self.status = status
        self.warningMeaning = warningMeaning ?? status.flatMap { Self.meanings[$0] }
    }
    private static let meanings: [UInt16: String] = [
        0x0107: "Attribute list error; attributes may have been ignored",
        0x0116: "Attribute value out of range",
        0xB600: "Memory allocation not supported", 0xB601: "Film session printing (collation) not supported",
        0xB602: "Film session contains no Image Boxes (empty page)",
        0xB603: "Film Box contains no Image Boxes (empty page)",
        0xB604: "Image demagnified to fit Image Box", 0xB605: "Density replaced by printer operating limit",
        0xB609: "Image cropped to fit Image Box", 0xB60A: "Image decimated to fit Image Box"
    ]
}

public struct DicomPrinterConfiguration: Equatable, Sendable {
    public let dataSet: DicomDataSet
    public let operationStatus: UInt16
    public init(dataSet: DicomDataSet, operationStatus: UInt16 = 0) {
        self.dataSet = dataSet; self.operationStatus = operationStatus
    }
    public var media: [DicomDataSet] {
        printers.flatMap { $0.sequenceItems(for: DicomPrintTag.mediaInstalledSequence).map(\.dataSet)
            + $0.sequenceItems(for: DicomPrintTag.otherMediaAvailableSequence).map(\.dataSet) }
    }
    public var displayFormats: [DicomDataSet] {
        printers.flatMap { $0.sequenceItems(for: DicomPrintTag.supportedImageDisplayFormatsSequence).map(\.dataSet) }
    }
    public var printers: [DicomDataSet] { dataSet.sequenceItems(for: 0x2000_001E).map(\.dataSet) }
    public func configuration(for metaSOPClassUID: String) -> DicomDataSet? {
        printers.first { ($0.string(for: 0x0008_115A) ?? "").components(separatedBy: "\\").contains(metaSOPClassUID) }
    }
    public func requestedImageSizeAllowed(filmBox: DicomFilmBox, metaSOPClassUID: String) -> Bool? {
        guard let configuration = configuration(for: metaSOPClassUID) else { return nil }
        let resolution = filmBox.requestedResolutionID ?? configuration.string(for: 0x2010_0054)
        let item = configuration.sequenceItems(for: 0x2000_00A8).map(\.dataSet).first {
            $0.string(for: DicomPrintTag.imageDisplayFormat) == filmBox.imageDisplayFormat &&
            $0.string(for: DicomPrintTag.filmOrientation) == filmBox.orientation.rawValue &&
            $0.string(for: DicomPrintTag.filmSizeID) == filmBox.filmSizeID &&
            (resolution == nil || $0.string(for: 0x2010_0052) == resolution)
        }
        guard let value = item?.string(for: 0x2020_00A0) else { return false }
        return value == "YES"
    }
}
public struct DicomPrintPeerCapabilities: Equatable, Sendable {
    public var acceptedSOPClassUIDs: Set<String>
    public var printerConfiguration: DicomPrinterConfiguration?
    public init(acceptedSOPClassUIDs: Set<String>, printerConfiguration: DicomPrinterConfiguration? = nil) {
        self.acceptedSOPClassUIDs = acceptedSOPClassUIDs; self.printerConfiguration = printerConfiguration
    }
    public var annotationBox: Bool { acceptedSOPClassUIDs.contains(DicomNetworkUID.basicAnnotationBoxSOPClass) }
    public var presentationLUT: Bool { acceptedSOPClassUIDs.contains(DicomNetworkUID.presentationLUTSOPClass) }
    public var printJob: Bool { acceptedSOPClassUIDs.contains(DicomNetworkUID.printJobSOPClass) }
    public var grayscaleMeta: Bool { acceptedSOPClassUIDs.contains(DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass) }
    public var colorMeta: Bool { acceptedSOPClassUIDs.contains(DicomNetworkUID.basicColorPrintManagementMetaSOPClass) }
    public var printer: Bool { grayscaleMeta || colorMeta || acceptedSOPClassUIDs.contains(DicomNetworkUID.printerSOPClass) }
    public var printerConfigurationRetrieval: Bool { acceptedSOPClassUIDs.contains(DicomNetworkUID.printerConfigurationRetrievalSOPClass) }
    public var filmSession: Bool { grayscaleMeta || colorMeta || acceptedSOPClassUIDs.contains(DicomNetworkUID.basicFilmSessionSOPClass) }
    public var filmBox: Bool { grayscaleMeta || colorMeta || acceptedSOPClassUIDs.contains(DicomNetworkUID.basicFilmBoxSOPClass) }
    public var grayscaleImageBox: Bool { grayscaleMeta || acceptedSOPClassUIDs.contains(DicomNetworkUID.basicGrayscaleImageBoxSOPClass) }
    public var colorImageBox: Bool { colorMeta || acceptedSOPClassUIDs.contains(DicomNetworkUID.basicColorImageBoxSOPClass) }
}
public struct DicomPrintIdentificationRequirements: Equatable, Sendable {
    public var requiresAnnotation: Bool
    public var allowsBurnIn: Bool
    public init(requiresAnnotation: Bool, allowsBurnIn: Bool = false) {
        self.requiresAnnotation = requiresAnnotation; self.allowsBurnIn = allowsBurnIn
    }
}
public enum DicomPrintIdentificationDecision: Equatable, Sendable {
    case proceed
    case blocked(reason: String)
    case recomposeWithBurnIn(reason: String, requiresOperatorConfirmation: Bool)
}
public enum DicomPrintIdentificationGate {
    public static func decide(requested: DicomPrintIdentificationRequirements,
                              negotiated: DicomPrintPeerCapabilities,
                              failure: DicomPrintManagementError? = nil) -> DicomPrintIdentificationDecision {
        if let failure {
            switch failure {
            case .annotationBoxNotNegotiated, .insufficientAnnotationBoxes, .annotationSetFailed, .annotationIgnored:
                let reason = failure.localizedDescription
                return requested.allowsBurnIn ? .recomposeWithBurnIn(reason: reason, requiresOperatorConfirmation: true)
                    : .blocked(reason: reason)
            default: return .blocked(reason: failure.localizedDescription)
            }
        }
        if requested.requiresAnnotation && !negotiated.annotationBox {
            return decide(requested: requested, negotiated: negotiated, failure: .annotationBoxNotNegotiated)
        }
        return .proceed
    }
}

public struct DicomPrintExecutionStatusInfo: RawRepresentable, Equatable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let normal = Self(rawValue: "NORMAL")
    public static let badReceiveMgz = Self(rawValue: "BAD RECEIVE MGZ")
    public static let badSupplyMgz = Self(rawValue: "BAD SUPPLY MGZ")
    public static let calibrating = Self(rawValue: "CALIBRATING")
    public static let calibrationErr = Self(rawValue: "CALIBRATION ERR")
    public static let checkChemistry = Self(rawValue: "CHECK CHEMISTRY")
    public static let checkSorter = Self(rawValue: "CHECK SORTER")
    public static let chemicalsEmpty = Self(rawValue: "CHEMICALS EMPTY")
    public static let chemicalsLow = Self(rawValue: "CHEMICALS LOW")
    public static let coverOpen = Self(rawValue: "COVER OPEN")
    public static let elecConfigErr = Self(rawValue: "ELEC CONFIG ERR")
    public static let elecDown = Self(rawValue: "ELEC DOWN")
    public static let elecSwError = Self(rawValue: "ELEC SW ERROR")
    public static let empty8X10 = Self(rawValue: "EMPTY 8X10")
    public static let empty8X10Blue = Self(rawValue: "EMPTY 8X10 BLUE")
    public static let empty8X10Clr = Self(rawValue: "EMPTY 8X10 CLR")
    public static let empty8X10Papr = Self(rawValue: "EMPTY 8X10 PAPR")
    public static let empty10X12 = Self(rawValue: "EMPTY 10X12")
    public static let empty10X12Blue = Self(rawValue: "EMPTY 10X12 BLUE")
    public static let empty10X12Clr = Self(rawValue: "EMPTY 10X12 CLR")
    public static let empty10X12Papr = Self(rawValue: "EMPTY 10X12 PAPR")
    public static let empty10X14 = Self(rawValue: "EMPTY 10X14")
    public static let empty10X14Blue = Self(rawValue: "EMPTY 10X14 BLUE")
    public static let empty10X14Clr = Self(rawValue: "EMPTY 10X14 CLR")
    public static let empty10X14Papr = Self(rawValue: "EMPTY 10X14 PAPR")
    public static let empty11X14 = Self(rawValue: "EMPTY 11X14")
    public static let empty11X14Blue = Self(rawValue: "EMPTY 11X14 BLUE")
    public static let empty11X14Clr = Self(rawValue: "EMPTY 11X14 CLR")
    public static let empty11X14Papr = Self(rawValue: "EMPTY 11X14 PAPR")
    public static let empty14X14 = Self(rawValue: "EMPTY 14X14")
    public static let empty14X14Blue = Self(rawValue: "EMPTY 14X14 BLUE")
    public static let empty14X14Clr = Self(rawValue: "EMPTY 14X14 CLR")
    public static let empty14X14Papr = Self(rawValue: "EMPTY 14X14 PAPR")
    public static let empty14X17 = Self(rawValue: "EMPTY 14X17")
    public static let empty14X17Blue = Self(rawValue: "EMPTY 14X17 BLUE")
    public static let empty14X17Clr = Self(rawValue: "EMPTY 14X17 CLR")
    public static let empty14X17Papr = Self(rawValue: "EMPTY 14X17 PAPR")
    public static let empty24X24 = Self(rawValue: "EMPTY 24X24")
    public static let empty24X24Blue = Self(rawValue: "EMPTY 24X24 BLUE")
    public static let empty24X24Clr = Self(rawValue: "EMPTY 24X24 CLR")
    public static let empty24X24Papr = Self(rawValue: "EMPTY 24X24 PAPR")
    public static let empty24X30 = Self(rawValue: "EMPTY 24X30")
    public static let empty24X30Blue = Self(rawValue: "EMPTY 24X30 BLUE")
    public static let empty24X30Clr = Self(rawValue: "EMPTY 24X30 CLR")
    public static let empty24X30Papr = Self(rawValue: "EMPTY 24X30 PAPR")
    public static let emptyA4Papr = Self(rawValue: "EMPTY A4 PAPR")
    public static let emptyA4Trans = Self(rawValue: "EMPTY A4 TRANS")
    public static let exposureFailure = Self(rawValue: "EXPOSURE FAILURE")
    public static let filmJam = Self(rawValue: "FILM JAM")
    public static let filmTranspErr = Self(rawValue: "FILM TRANSP ERR")
    public static let finisherEmpty = Self(rawValue: "FINISHER EMPTY")
    public static let finisherError = Self(rawValue: "FINISHER ERROR")
    public static let finisherLow = Self(rawValue: "FINISHER LOW")
    public static let low8X10 = Self(rawValue: "LOW 8X10")
    public static let low8X10Blue = Self(rawValue: "LOW 8X10 BLUE")
    public static let low8X10Clr = Self(rawValue: "LOW 8X10 CLR")
    public static let low8X10Papr = Self(rawValue: "LOW 8X10 PAPR")
    public static let low10X12 = Self(rawValue: "LOW 10X12")
    public static let low10X12Blue = Self(rawValue: "LOW 10X12 BLUE")
    public static let low10X12Clr = Self(rawValue: "LOW 10X12 CLR")
    public static let low10X12Papr = Self(rawValue: "LOW 10X12 PAPR")
    public static let low10X14 = Self(rawValue: "LOW 10X14")
    public static let low10X14Blue = Self(rawValue: "LOW 10X14 BLUE")
    public static let low10X14Clr = Self(rawValue: "LOW 10X14 CLR")
    public static let low10X14Papr = Self(rawValue: "LOW 10X14 PAPR")
    public static let low11X14 = Self(rawValue: "LOW 11X14")
    public static let low11X14Blue = Self(rawValue: "LOW 11X14 BLUE")
    public static let low11X14Clr = Self(rawValue: "LOW 11X14 CLR")
    public static let low11X14Papr = Self(rawValue: "LOW 11X14 PAPR")
    public static let low14X14 = Self(rawValue: "LOW 14X14")
    public static let low14X14Blue = Self(rawValue: "LOW 14X14 BLUE")
    public static let low14X14Clr = Self(rawValue: "LOW 14X14 CLR")
    public static let low14X14Papr = Self(rawValue: "LOW 14X14 PAPR")
    public static let low14X17 = Self(rawValue: "LOW 14X17")
    public static let low14X17Blue = Self(rawValue: "LOW 14X17 BLUE")
    public static let low14X17Clr = Self(rawValue: "LOW 14X17 CLR")
    public static let low14X17Papr = Self(rawValue: "LOW 14X17 PAPR")
    public static let low24X24 = Self(rawValue: "LOW 24X24")
    public static let low24X24Blue = Self(rawValue: "LOW 24X24 BLUE")
    public static let low24X24Clr = Self(rawValue: "LOW 24X24 CLR")
    public static let low24X24Papr = Self(rawValue: "LOW 24X24 PAPR")
    public static let low24X30 = Self(rawValue: "LOW 24X30")
    public static let low24X30Blue = Self(rawValue: "LOW 24X30 BLUE")
    public static let low24X30Clr = Self(rawValue: "LOW 24X30 CLR")
    public static let low24X30Papr = Self(rawValue: "LOW 24X30 PAPR")
    public static let lowA4Papr = Self(rawValue: "LOW A4 PAPR")
    public static let lowA4Trans = Self(rawValue: "LOW A4 TRANS")
    public static let noReceiveMgz = Self(rawValue: "NO RECEIVE MGZ")
    public static let noRibbon = Self(rawValue: "NO RIBBON")
    public static let noSupplyMgz = Self(rawValue: "NO SUPPLY MGZ")
    public static let checkPrinter = Self(rawValue: "CHECK PRINTER")
    public static let checkProc = Self(rawValue: "CHECK PROC")
    public static let printerDown = Self(rawValue: "PRINTER DOWN")
    public static let printerBusy = Self(rawValue: "PRINTER BUSY")
    public static let printBuffFull = Self(rawValue: "PRINT BUFF FULL")
    public static let printerInit = Self(rawValue: "PRINTER INIT")
    public static let printerOffline = Self(rawValue: "PRINTER OFFLINE")
    public static let procDown = Self(rawValue: "PROC DOWN")
    public static let procInit = Self(rawValue: "PROC INIT")
    public static let procOverflowFl = Self(rawValue: "PROC OVERFLOW FL")
    public static let procOverflowHi = Self(rawValue: "PROC OVERFLOW HI")
    public static let queued = Self(rawValue: "QUEUED")
    public static let receiverFull = Self(rawValue: "RECEIVER FULL")
    public static let reqMedNotInst = Self(rawValue: "REQ MED NOT INST")
    public static let reqMedNotAvai = Self(rawValue: "REQ MED NOT AVAI")
    public static let ribbonError = Self(rawValue: "RIBBON ERROR")
    public static let supplyEmpty = Self(rawValue: "SUPPLY EMPTY")
    public static let supplyLow = Self(rawValue: "SUPPLY LOW")
    public static let unknown = Self(rawValue: "UNKNOWN")
}


extension DicomPrintJob {
    /// Validates the declared raster budget before invoking the allocation closure.
    public init(width: Int, height: Int, template: DicomPrintTemplate = .singleImage(),
                limits: DicomPrintLimits = DicomPrintLimits(),
                makeBitmap: () throws -> DicomRenderedBitmap) throws {
        let bytes = try limits.validateDimensions(width: width, height: height)
        guard limits.maximumFilmsPerJob >= 1, limits.imageBoxesPerFilm >= 1,
              bytes <= limits.bytesPerFilm, bytes <= limits.bytesPerJob else {
            throw DicomPrintManagementError.limitExceeded("film or job budget")
        }
        let format = try DicomImageDisplayFormat(wireValue: template.filmBox.imageDisplayFormat)
        guard let capacity = format.imageBoxCapacity ?? template.filmBox.expectedImageBoxCount, capacity > 0 else {
            throw DicomPrintManagementError.expectedImageBoxCountRequired
        }
        let bitmap = try makeBitmap()
        guard bitmap.width == width, bitmap.height == height else {
            throw DicomPrintManagementError.limitExceeded("bitmap differs from declared dimensions")
        }
        try self.init(filmSession: template.filmSession, filmBox: template.filmBox,
                      imageBoxes: [DicomImageBox(bitmap: bitmap)], limits: limits)
    }
}

/// A deferred, declared raster. The renderer is invoked only after the entire
/// job or batch has passed its dimension, layout, count and byte budgets.
public struct DicomPrintImageInput {
    public let width: Int
    public let height: Int
    public let makeBitmap: () throws -> DicomRenderedBitmap
    public init(width: Int, height: Int, makeBitmap: @escaping () throws -> DicomRenderedBitmap) {
        self.width = width; self.height = height; self.makeBitmap = makeBitmap
    }
}
public struct DicomPrintFilmInput {
    public let id: String
    public let filmBox: DicomFilmBox
    public let images: [DicomPrintImageInput]
    public let annotations: [DicomPrintAnnotation]
    public init(id: String = DicomDataSetWriter.makeUID(), filmBox: DicomFilmBox,
                images: [DicomPrintImageInput], annotations: [DicomPrintAnnotation] = []) {
        self.id = id; self.filmBox = filmBox; self.images = images; self.annotations = annotations
    }
}
extension DicomPrintLimits {
    public func validate(inputs: [DicomPrintFilmInput]) throws {
        guard !inputs.isEmpty, inputs.count <= maximumFilmsPerJob else {
            throw DicomPrintManagementError.limitExceeded("maximumFilmsPerJob")
        }
        var total = 0
        for film in inputs {
            guard !film.images.isEmpty else { throw DicomPrintManagementError.emptyImageList }
            guard film.images.count <= imageBoxesPerFilm, film.annotations.count <= annotationsPerFilm else {
                throw DicomPrintManagementError.limitExceeded("imageBoxesPerFilm or annotationsPerFilm")
            }
            let format = try DicomImageDisplayFormat(wireValue: film.filmBox.imageDisplayFormat)
            guard let capacity = format.imageBoxCapacity ?? film.filmBox.expectedImageBoxCount, capacity > 0 else {
                throw DicomPrintManagementError.expectedImageBoxCountRequired
            }
            guard capacity <= imageBoxesPerFilm else {
                throw DicomPrintManagementError.limitExceeded("imageBoxesPerFilm layout capacity")
            }
            guard film.images.count <= capacity else {
                throw DicomPrintManagementError.imageCountExceedsLayout(imageCount: film.images.count, capacity: capacity)
            }
            if !film.annotations.isEmpty {
                guard let format = film.filmBox.annotationDisplayFormatID, !format.trimmingCharacters(in: .whitespaces).isEmpty,
                      Set(film.annotations.map(\.position)).count == film.annotations.count else {
                    throw DicomPrintManagementError.invalidAnnotation(reason: "Missing format or duplicate positions.")
                }
            }
            var filmBytes = 0
            for image in film.images {
                let bytes = try validateDimensions(width: image.width, height: image.height)
                guard bytes <= bytesPerFilm - filmBytes, bytes <= bytesPerJob - total else {
                    throw DicomPrintManagementError.limitExceeded("bytesPerFilm or bytesPerJob")
                }
                total += bytes; filmBytes += bytes
            }
        }
    }
}
extension DicomPrintJob {
    public init(inputs: [DicomPrintFilmInput], filmSession: DicomFilmSession = DicomFilmSession(),
                printMode: DicomPrintMode = .grayscale, printScope: DicomPrintScope = .filmBox,
                limits: DicomPrintLimits = DicomPrintLimits(), cleanup: Bool = true,
                monitor: DicomPrintMonitor = .none, presentationLUT: DicomPresentationLUT? = nil,
                cancellationToken: DicomPrintCancellationToken = DicomPrintCancellationToken()) throws {
        try limits.validate(inputs: inputs)
        let films = try inputs.map { film in
            DicomFilm(id: film.id, filmBox: film.filmBox, imageBoxes: try film.images.enumerated().map { index, image in
                if cancellationToken.isCancelled { throw DicomPrintManagementError.cancelled }
                let bitmap = try image.makeBitmap()
                guard bitmap.width == image.width, bitmap.height == image.height else {
                    throw DicomPrintManagementError.limitExceeded("bitmap differs from declared dimensions")
                }
                return try DicomImageBox(position: index + 1, bitmap: bitmap)
            }, annotations: film.annotations)
        }
        try self.init(films: films, filmSession: filmSession, printMode: printMode, printScope: printScope,
                      limits: limits, cleanup: cleanup, monitor: monitor, presentationLUT: presentationLUT,
                      cancellationToken: cancellationToken)
    }
}
extension DicomPrintBatch {
    public init(inputs: [[DicomPrintFilmInput]], limits: DicomPrintLimits = DicomPrintLimits()) throws {
        try limits.validate(inputs: inputs.flatMap { $0 })
        guard inputs.allSatisfy({ !$0.isEmpty }) else { throw DicomPrintManagementError.emptyImageList }
        try self.init(jobs: inputs.map { try DicomPrintJob(inputs: $0, limits: limits) }, limits: limits)
    }
}
