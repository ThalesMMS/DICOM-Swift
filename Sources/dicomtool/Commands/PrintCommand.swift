import ArgumentParser
import DicomCore
import Foundation

struct PrintCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "print", abstract: "DICOM film composition and printing",
        subcommands: [SCU.self, SCP.self, Compose.self, Status.self])

    struct Connection: ParsableArguments {
        @Option var host = "127.0.0.1"
        @Option var port: UInt16 = 11112
        @Option var aet = "DICOMTOOL"
        @Option var calledAet = "PRINT"
        func service() -> DicomDIMSEServiceSCU {
            .init(configuration: .init(host: host, port: port, calledAETitle: calledAet, callingAETitle: aet))
        }
    }

    struct FilmOptions: ParsableArguments {
        @Option var mode = "gray"
        @Option var layout = "STANDARD\\1,1"
        @Option var filmSize = "8INX10IN"
        @Option var orientation = "PORTRAIT"
        @Option var copies = 1
        @Option var lut: String?
        @Option var annotation: [String] = []
        @Option var annotationFormatId: String?
        @Flag var identify = false
        @Option var maxBytes = 256 * 1024 * 1024
        @Argument var files: [String] = []

        func job() throws -> DicomPrintJob {
            guard maxBytes > 0, copies > 0, copies <= 1000, !files.isEmpty,
                  ["gray", "color", "auto"].contains(mode),
                  let orientation = DicomFilmOrientation(rawValue: orientation.uppercased()) else {
                throw ValidationError("Invalid mode, orientation, copies, byte limit or empty input list")
            }
            let format = try DicomImageDisplayFormat(wireValue: layout)
            _ = try DicomPhysicalFilmSize(filmSizeID: filmSize)
            guard let capacity = format.imageBoxCapacity, capacity > 0, capacity <= 100 else {
                throw ValidationError("CLI input requires a STANDARD, ROW or COL layout with at most 100 boxes")
            }
            let limits = DicomPrintLimits(bytesPerImageBox: maxBytes, bytesPerFilm: maxBytes, bytesPerJob: maxBytes)
            var total = 0
            let decoders = try files.map { path in
                let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
                guard let size, size.int64Value <= Int64(maxBytes) else {
                    throw ValidationError("Input file exceeds --max-bytes before decoding")
                }
                let decoder = try DCMDecoder(contentsOfFile: path)
                let bytes = try limits.validateDimensions(width: decoder.width, height: decoder.height)
                guard bytes <= maxBytes - total else { throw ValidationError("Input exceeds --max-bytes") }
                total += bytes
                return decoder
            }
            let annotations = try annotation.map { value in
                let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, let position = Int(parts[0]) else { throw ValidationError("Annotation must be POS=TEXT") }
                return try DicomPrintAnnotation(position: position, text: String(parts[1]))
            }
            guard annotations.isEmpty || annotationFormatId != nil else { throw ValidationError("Annotations require --annotation-format-id") }
            let filmCount = (files.count - 1) / capacity + 1
            guard filmCount <= limits.maximumFilmsPerJob else { throw ValidationError("Too many films") }
            var films: [DicomFilm] = []
            for start in stride(from: 0, to: decoders.count, by: capacity) {
                let images = try decoders[start..<min(decoders.count, start + capacity)].enumerated().map { offset, decoder in
                    var image = try DicomImageBox(position: offset + 1, bitmap: DicomImagePreprocessor().render(decoder: decoder))
                    if identify {
                        image.originalImage = DicomDataSet(elements: [DicomTag.patientName, .patientID, .studyInstanceUID,
                            .seriesInstanceUID].compactMap { tag in
                                let value = decoder.info(for: tag)
                                guard !value.isEmpty else { return nil }
                                return DicomDataElement(tag: tag.rawValue, vr: tag == .patientName ? .PN : tag == .patientID ? .LO : .UI,
                                                        value: .strings([value]))
                            })
                    }
                    return image
                }
                films.append(.init(filmBox: .init(displayFormat: format, orientation: orientation,
                    filmSizeID: filmSize, annotationDisplayFormatID: annotationFormatId), imageBoxes: images, annotations: annotations))
            }
            let presentationLUT: DicomPresentationLUT?
            if let lut {
                switch lut {
                case "identity": presentationLUT = .init(shape: .identity)
                case "linod": presentationLUT = .init(shape: .linearOpticalDensity)
                default:
                    struct Table: Decodable { let descriptor: [UInt16]; let values: [UInt16] }
                    let table = try JSONDecoder().decode(Table.self, from: PrintCommand.boundedJSON(lut))
                    presentationLUT = try .init(descriptor: table.descriptor, values: table.values)
                }
            } else { presentationLUT = nil }
            return try DicomPrintJob(films: films, filmSession: .init(numberOfCopies: copies),
                printMode: mode == "gray" ? .grayscale : mode == "color" ? .color : .automatic,
                limits: limits, presentationLUT: presentationLUT)
        }
        var annotationFormats: [String: Int] {
            guard let annotationFormatId else { return [:] }
            return [annotationFormatId: annotation.compactMap { Int($0.split(separator: "=", maxSplits: 1).first ?? "") }.max() ?? 0]
        }
    }

    struct Compose: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "compose")
        @OptionGroup var film: FilmOptions
        @Option var output: String
        func run() async throws {
            let job = try film.job()
            guard job.effectiveFilms.count == 1 else { throw ValidationError("compose --output accepts one film") }
            let sheets = try DicomPrintPreview.compose(job: job, annotationFormats: film.annotationFormats, identify: film.identify)
            try DicomFilePrintOutputProvider.pngData(sheets[0]).write(to: URL(fileURLWithPath: output), options: .atomic)
            try PrintCommand.json(["fingerprint": sheets[0].fingerprint, "width": sheets[0].width, "height": sheets[0].height])
        }
    }

    struct SCU: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "scu")
        @OptionGroup var connection: Connection
        @OptionGroup var film: FilmOptions
        @Flag var monitor = false
        @Option var previewDir: String?
        func run() async throws {
            var job = try film.job()
            if monitor { job.monitor = .untilDone(timeout: 60) }
            if let previewDir {
                let sheets = try DicomPrintPreview.compose(job: job, annotationFormats: film.annotationFormats, identify: film.identify)
                let directory = URL(fileURLWithPath: previewDir)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for (index, sheet) in sheets.enumerated() {
                    try DicomFilePrintOutputProvider.pngData(sheet).write(to: directory.appendingPathComponent("preview-\(index).png"), options: .atomic)
                }
            }
            let result = try connection.service().sendPrintJob(job)
            try PrintCommand.json(["state": result.state.rawValue, "film_session_uid": result.filmSessionSOPInstanceUID,
                "execution_status": result.executionStatus?.rawValue as Any? ?? NSNull(),
                "execution_status_info": result.executionStatusInfo?.rawValue as Any? ?? NSNull(),
                "film_box_uid": result.filmBoxSOPInstanceUID, "image_box_uids": result.imageBoxSOPInstanceUIDs,
                "print_job_uids": result.printJobSOPInstanceUIDs,
                "operations": result.operations.map { record -> [String: Any] in
                    ["operation": record.kind.rawValue, "sop_class_uid": record.sopClassUID,
                     "sop_instance_uid": record.sopInstanceUID as Any? ?? NSNull(),
                     "status": record.status as Any? ?? NSNull()]
                }])
        }
    }

    struct SCP: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "scp")
        @Option var port: UInt16 = 11112
        @Option var aet = "PRINT"
        @Flag var gray = false
        @Flag var color = false
        @Flag var lut = false
        @Flag var printJob = false
        @Option var annotationFormat: [String] = []
        @Option var outputDir = "print-output"
        @Option var pdf: String?
        @Option var config: String?
        @Option var printerStatus = "NORMAL"
        @Option var maxImageBytes = 256 * 1024 * 1024
        @Option var duration: Double = 60
        @Option var failCreate: String?
        @Option var failSet: String?
        @Option var failAction: String?
        func run() async throws {
            guard duration.isFinite, duration > 0, duration <= 86400, maxImageBytes > 0,
                  ["NORMAL", "WARNING", "FAILURE"].contains(printerStatus) else { throw ValidationError("Invalid duration, limit or printer status") }
            var sops: Set<String> = [DicomNetworkUID.printerSOPClass, DicomNetworkUID.printerConfigurationRetrievalSOPClass]
            if gray || !color { sops.insert(DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass) }
            if color { sops.insert(DicomNetworkUID.basicColorPrintManagementMetaSOPClass) }
            if lut { sops.insert(DicomNetworkUID.presentationLUTSOPClass) }
            if printJob { sops.insert(DicomNetworkUID.printJobSOPClass) }
            if !annotationFormat.isEmpty { sops.insert(DicomNetworkUID.basicAnnotationBoxSOPClass) }
            var configuration = DicomPrintSCPConfiguration(capabilities: .init(acceptedSOPClassUIDs: sops))
            configuration.limits.bytesPerImageBox = maxImageBytes
            configuration.printerAttributes.set(.init(tag: 0x2110_0010, vr: .CS, value: .strings([printerStatus])))
            for format in annotationFormat {
                let parts = format.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, let rows = Int(parts[1]), rows > 0, rows <= 100 else { throw ValidationError("Annotation format must be ID=ROWS") }
                configuration.annotationFormats[String(parts[0])] = rows
            }
            func status(_ value: String?) throws -> UInt16? {
                guard let value else { return nil }
                guard let parsed = UInt16(value.replacingOccurrences(of: "0x", with: ""), radix: 16), parsed != 0 else {
                    throw ValidationError("Fault status must be a nonzero hexadecimal status")
                }
                return parsed
            }
            configuration.failCreate = try status(failCreate)
            configuration.failSet = try status(failSet)
            configuration.failAction = try status(failAction)
            if let config {
                struct Settings: Decodable {
                    var outputWidth: Int?
                    var maximumQueuedJobs: Int?
                    var maximumFilmsPerSession: Int?
                    var imageBoxesPerFilm: Int?
                    var bytesPerFilm: Int?
                    var bytesPerSession: Int?
                    var annotationFormats: [String: Int]?
                    var supportsCollation: Bool?
                    var keepJobsOnRelease: Bool?
                    var printerName: String?
                    var identify: Bool?
                }
                let settings = try JSONDecoder().decode(Settings.self, from: PrintCommand.boundedJSON(config))
                if let value = settings.outputWidth {
                    guard value > 0, value <= 65535 else { throw ValidationError("Invalid outputWidth") }
                    configuration.outputWidth = value
                }
                if let value = settings.maximumQueuedJobs { configuration.maximumQueuedJobs = value }
                if let value = settings.maximumFilmsPerSession { configuration.limits.maximumFilmsPerJob = value }
                if let value = settings.imageBoxesPerFilm { configuration.limits.imageBoxesPerFilm = value }
                if let value = settings.bytesPerFilm { configuration.limits.bytesPerFilm = value }
                if let value = settings.bytesPerSession { configuration.limits.bytesPerJob = value }
                if let value = settings.annotationFormats { configuration.annotationFormats = value }
                if let value = settings.supportsCollation { configuration.supportsCollation = value }
                if let value = settings.keepJobsOnRelease { configuration.keepJobsOnRelease = value }
                if let value = settings.printerName { configuration.printerName = value }
                if let value = settings.identify { configuration.identify = value }
                guard configuration.maximumQueuedJobs >= 0, configuration.limits.maximumFilmsPerJob > 0,
                      configuration.limits.imageBoxesPerFilm > 0, configuration.limits.bytesPerFilm > 0,
                      configuration.limits.bytesPerJob > 0,
                      configuration.annotationFormats.values.allSatisfy({ $0 > 0 && $0 <= 100 }) else {
                    throw ValidationError("Invalid Print SCP configuration limits")
                }
            }
            if !configuration.annotationFormats.isEmpty {
                sops.insert(DicomNetworkUID.basicAnnotationBoxSOPClass)
                configuration.capabilities = .init(acceptedSOPClassUIDs: sops)
            }
            let server = DicomDIMSEServer(configuration: .init(aeTitle: aet, port: port), print: configuration,
                printProvider: DicomPrintSCPProvider(outputProvider: ReportingOutput(
                    output: DicomFilePrintOutputProvider(directory: URL(fileURLWithPath: outputDir),
                        pdfURL: pdf.map { URL(fileURLWithPath: $0) }, writePNG: pdf == nil))))
            try server.start()
            try PrintCommand.json(["listening_port": server.listeningPort as Any? ?? NSNull()])
            do { try await Task.sleep(for: .seconds(duration)) } catch { await server.stop(); throw error }
            await server.stop()
        }
    }

    static func boundedJSON(_ path: String) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let limit = 1024 * 1024
        let bytes = try handle.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw ValidationError("Print JSON exceeds one MiB") }
        return bytes
    }

    struct ReportingOutput: DicomPrintOutputProviding {
        let output: any DicomPrintOutputProviding
        func finish(jobID: String) async { await output.finish(jobID: jobID) }
        func output(_ film: DicomComposedFilm, metadata: DicomPrintOutputMetadata,
                    control: DicomPrintJobControl) async -> DicomPrintOutputResult {
            let result = await output.output(film, metadata: metadata, control: control)
            if result == .success {
                do {
                    try PrintCommand.json(["job_id": metadata.jobID, "film_index": metadata.filmIndex,
                        "sheet_fingerprint": film.fingerprint,
                        "image_boxes": metadata.imagePixelFingerprints.keys.sorted().map {
                            ["position": $0, "sha256": metadata.imagePixelFingerprints[$0] ?? ""] as [String: Any]
                        }])
                } catch { return .failure(statusInfo: "OUTPUT REPORT FAILURE") }
            }
            return result
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status")
        @OptionGroup var connection: Connection
        func run() async throws {
            let scu = connection.service()
            let status = try scu.queryPrinter()
            let configuration = try scu.queryPrinterConfiguration()
            try PrintCommand.json(["status": status?.state.rawValue as Any? ?? NSNull(),
                "status_info": status?.statusInfo as Any? ?? NSNull(), "printer_name": status?.printerName as Any? ?? NSNull(),
                "configuration": configuration.map { PrintCommand.dataSetJSON($0.dataSet) } as Any? ?? NSNull()])
        }
    }

    static func json(_ value: [String: Any]) throws {
        Swift.print(String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }

    static func dataSetJSON(_ data: DicomDataSet) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: data.elements.map { element in
            let value: Any
            if case .sequence(let items) = element.value { value = items.map { dataSetJSON($0.dataSet) } }
            else { value = element.stringValue ?? String(describing: element.value) }
            return (String(format: "%08X", element.tag), value)
        })
    }
}
