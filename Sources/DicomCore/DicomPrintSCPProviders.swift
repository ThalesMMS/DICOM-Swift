import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class DicomPrintQueueAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let maximum: Int
    private var count = 0
    init(maximum: Int) { self.maximum = maximum }
    func reserve() -> Bool {
        lock.withLock {
            guard count < maximum else { return false }
            count += 1
            return true
        }
    }
    func release() { lock.withLock { count -= 1 } }
}

public struct DicomPrintSCPConfiguration: Sendable {
    public var capabilities: DicomPrintPeerCapabilities
    public var limits = DicomPrintLimits()
    public var maximumQueuedJobs = 16
    public var maximumResidentPixelBytes = 512 * 1024 * 1024
    public var supportsCollation = true
    public var keepJobsOnRelease = false
    public var outputWidth = 1024
    public var identify = false
    public var annotationFormats: [String: Int] = [:]
    public var printerDefinedGrids: [String: DicomImageDisplayFormat] = [:]
    public var printerName = "DICOM-Swift"
    public var printerAttributes = DicomDataSet()
    public var displayFormats: [DicomImageDisplayFormat] = [.standard(columns: 1, rows: 1)]
    public var failCreate: UInt16?
    public var failSet: UInt16?
    public var failAction: UInt16?

    public init(capabilities: DicomPrintPeerCapabilities = .init(acceptedSOPClassUIDs: [
        DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
        DicomNetworkUID.printerSOPClass
    ])) {
        self.capabilities = capabilities
    }

    func permits(_ sop: String) -> Bool {
        let accepted = capabilities.acceptedSOPClassUIDs
        if accepted.contains(sop) { return true }
        let gray = accepted.contains(DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass)
        let color = accepted.contains(DicomNetworkUID.basicColorPrintManagementMetaSOPClass)
        if [DicomNetworkUID.basicFilmSessionSOPClass, DicomNetworkUID.basicFilmBoxSOPClass,
            DicomNetworkUID.printerSOPClass].contains(sop) { return gray || color }
        return sop == DicomNetworkUID.basicGrayscaleImageBoxSOPClass && gray
            || sop == DicomNetworkUID.basicColorImageBoxSOPClass && color
    }
}

public protocol DicomPrinterStatusProviding: Sendable {
    func currentStatus() async -> DicomPrinterStatusReport
    func statusChanges() async -> AsyncStream<DicomPrinterStatusReport>
}

public protocol DicomPrintSCPProviding: Sendable {
    var outputProvider: any DicomPrintOutputProviding { get }
    var textRasterizer: any DicomPrintTextRasterizing { get }
    var printerStatusProvider: (any DicomPrinterStatusProviding)? { get }
    func jobCreated(_ control: DicomPrintJobControl) async
}

extension DicomPrintSCPProviding {
    public var printerStatusProvider: (any DicomPrinterStatusProviding)? { nil }
}

public struct DicomPrintSCPProvider: DicomPrintSCPProviding {
    public let outputProvider: any DicomPrintOutputProviding
    public let textRasterizer: any DicomPrintTextRasterizing
    public let printerStatusProvider: (any DicomPrinterStatusProviding)?
    private let onJob: @Sendable (DicomPrintJobControl) async -> Void

    public init(outputProvider: any DicomPrintOutputProviding,
                textRasterizer: any DicomPrintTextRasterizing = DicomCoreTextPrintRasterizer(),
                printerStatusProvider: (any DicomPrinterStatusProviding)? = nil,
                onJob: @escaping @Sendable (DicomPrintJobControl) async -> Void = { _ in }) {
        self.outputProvider = outputProvider
        self.textRasterizer = textRasterizer
        self.printerStatusProvider = printerStatusProvider
        self.onJob = onJob
    }
    public func jobCreated(_ control: DicomPrintJobControl) async { await onJob(control) }
}

public struct DicomPrintOutputMetadata: Equatable, Sendable {
    public let jobID: String
    public let filmIndex: Int
    public let filmCount: Int
    public let originator: String
    public let imagePixelFingerprints: [Int: String]

    public init(jobID: String, filmIndex: Int, filmCount: Int, originator: String,
                imagePixelFingerprints: [Int: String] = [:]) {
        self.jobID = jobID
        self.filmIndex = filmIndex
        self.filmCount = filmCount
        self.originator = originator
        self.imagePixelFingerprints = imagePixelFingerprints
    }
}

public enum DicomPrintOutputResult: Equatable, Sendable {
    case success
    case failure(statusInfo: String)
}

/// A physical printer adapter implements this protocol and returns success only
/// when it has confirmed output. Returning from an enqueue operation is insufficient.
public protocol DicomPrintOutputProviding: Sendable {
    func output(_ film: DicomComposedFilm, metadata: DicomPrintOutputMetadata,
                control: DicomPrintJobControl) async -> DicomPrintOutputResult
    func finish(jobID: String) async
}

extension DicomPrintOutputProviding {
    public func finish(jobID: String) async {}
}

public final class DicomPrintJobControl: @unchecked Sendable {
    public let id: String
    private let lock = NSLock()
    private var cancelled = false
    private var completed: [Int] = []

    public init(id: String) { self.id = id }
    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public var completedFilmIndices: [Int] { lock.withLock { completed } }
    func recordCompletedFilm(_ index: Int) { lock.withLock { completed.append(index) } }
}

public actor DicomRasterPrintOutputProvider: DicomPrintOutputProviding {
    public struct Record: Equatable, Sendable {
        public let film: DicomComposedFilm
        public let metadata: DicomPrintOutputMetadata
    }
    public let maximumFilmCount: Int
    public let maximumBytes: Int
    public private(set) var records: [Record] = []
    private var byteCount = 0

    public init(maximumFilmCount: Int = 100, maximumBytes: Int = 256 * 1024 * 1024) {
        self.maximumFilmCount = maximumFilmCount
        self.maximumBytes = maximumBytes
    }

    public func output(_ film: DicomComposedFilm, metadata: DicomPrintOutputMetadata,
                       control: DicomPrintJobControl) async -> DicomPrintOutputResult {
        guard !control.isCancelled else { return .failure(statusInfo: "CANCELLED") }
        guard records.count < maximumFilmCount, byteCount <= maximumBytes,
              film.pixelData.count <= maximumBytes - byteCount else { return .failure(statusInfo: "INSUFFIC MEMORY") }
        records.append(.init(film: film, metadata: metadata))
        byteCount += film.pixelData.count
        return .success
    }
}

public actor DicomFilePrintOutputProvider: DicomPrintOutputProviding {
    public let directory: URL
    public let pdfURL: URL?
    public let writePNG: Bool
    private var documents: [String: (context: CGContext, temporary: URL)] = [:]
    public init(directory: URL, pdfURL: URL? = nil, writePNG: Bool = true) {
        self.directory = directory
        self.pdfURL = pdfURL
        self.writePNG = writePNG
    }

    public func output(_ film: DicomComposedFilm, metadata: DicomPrintOutputMetadata,
                       control: DicomPrintJobControl) async -> DicomPrintOutputResult {
        guard !control.isCancelled else { return .failure(statusInfo: "CANCELLED") }
        // Job identifiers are generated UIDs, never patient names or source paths.
        guard !metadata.jobID.isEmpty, metadata.jobID.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              metadata.filmIndex >= 0 else { return .failure(statusInfo: "INVALID JOB") }
        do {
            guard !control.isCancelled else { return .failure(statusInfo: "CANCELLED") }
            if writePNG {
                let data = try Self.pngData(film)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent("\(metadata.jobID)-\(metadata.filmIndex).png")
                try data.write(to: destination, options: .atomic)
            }
            if let pdfURL {
                if documents[metadata.jobID] == nil {
                    guard metadata.filmIndex == 0 else { return .failure(statusInfo: "INVALID FILM ORDER") }
                    let parent = pdfURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    let temporary = parent.appendingPathComponent(".\(metadata.jobID).pdf")
                    guard let context = CGContext(temporary as CFURL, mediaBox: nil, nil) else {
                        return .failure(statusInfo: "OUTPUT FAILURE")
                    }
                    documents[metadata.jobID] = (context, temporary)
                }
                guard let document = documents[metadata.jobID] else { return .failure(statusInfo: "OUTPUT FAILURE") }
                var bounds = CGRect(x: 0, y: 0, width: film.info.physicalWidthMillimeters * 72 / 25.4,
                                    height: film.info.physicalHeightMillimeters * 72 / 25.4)
                let box = Data(bytes: &bounds, count: MemoryLayout<CGRect>.size) as CFData
                document.context.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
                document.context.draw(try Self.image(film), in: bounds)
                document.context.endPDFPage()
                if metadata.filmIndex == metadata.filmCount - 1 {
                    document.context.closePDF()
                    guard !control.isCancelled else {
                        documents.removeValue(forKey: metadata.jobID)
                        try? FileManager.default.removeItem(at: document.temporary)
                        return .failure(statusInfo: "CANCELLED")
                    }
                    if FileManager.default.fileExists(atPath: pdfURL.path) {
                        _ = try FileManager.default.replaceItemAt(pdfURL, withItemAt: document.temporary)
                    } else {
                        try FileManager.default.moveItem(at: document.temporary, to: pdfURL)
                    }
                    documents.removeValue(forKey: metadata.jobID)
                }
            }
            return .success
        } catch {
            if let document = documents.removeValue(forKey: metadata.jobID) {
                document.context.closePDF()
                try? FileManager.default.removeItem(at: document.temporary)
            }
            return .failure(statusInfo: "OUTPUT FAILURE")
        }
    }

    public func finish(jobID: String) {
        if let document = documents.removeValue(forKey: jobID) {
            document.context.closePDF()
            try? FileManager.default.removeItem(at: document.temporary)
        }
    }

    public nonisolated static func pngData(_ film: DicomComposedFilm) throws -> Data {
        let image = try Self.image(film)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw DicomFilmCompositionError.invalidParameter("PNG destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DicomFilmCompositionError.invalidParameter("PNG encoding") }
        return data as Data
    }

    private nonisolated static func image(_ film: DicomComposedFilm) throws -> CGImage {
        guard let provider = CGDataProvider(data: film.pixelData as CFData),
              let image = CGImage(width: film.width, height: film.height, bitsPerComponent: 8,
                bitsPerPixel: film.samplesPerPixel * 8, bytesPerRow: film.width * film.samplesPerPixel,
                space: film.samplesPerPixel == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw DicomFilmCompositionError.invalidParameter("Raster")
        }
        return image
    }
}
