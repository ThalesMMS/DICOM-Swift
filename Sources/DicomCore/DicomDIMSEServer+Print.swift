import Foundation
import CryptoKit

/// The general metadata parser deliberately omits Pixel Data. Reattach only the
/// native Print Image value identified by its structural path, after admission.
func printSCPDataSet(_ bytes: Data, syntax: DicomTransferSyntax, limits: DicomPrintLimits) throws -> DicomDataSet {
    guard !syntax.usesDataSetDeflate else { throw DicomDIMSEProviderError(status: 0x0106) }
    let parsed = try DicomEncodedDataSetValidator.validate(bytes, transferSyntax: syntax)
    guard var data = parsed.dataSet, !parsed.pixelDataHeadersTruncated else { throw DicomDIMSEProviderError(status: 0x0106) }
    for header in parsed.pixelDataHeaders {
        guard header.path.count == 3, case .tag(let sequence) = header.path[0],
              [0x2020_0110, 0x2020_0111].contains(sequence), header.path[1] == .item(0),
              header.path[2] == .tag(0x7FE0_0010), header.valueLength != UInt32.max,
              var image = data.sequenceItems(for: sequence).first?.dataSet else { throw DicomDIMSEProviderError(status: 0x0106) }
        guard let rows = image.int(for: .rows), let columns = image.int(for: .columns) else { throw DicomDIMSEProviderError(status: 0x0120) }
        _ = try printSCPPixelByteCount(rows: rows, columns: columns, samples: image.int(for: .samplesPerPixel) ?? 0,
                                      bits: image.int(for: .bitsAllocated) ?? 0, limit: limits.bytesPerImageBox)
        let count = Int(header.valueLength)
        guard count <= limits.bytesPerImageBox || count - 1 == limits.bytesPerImageBox,
              header.valueOffset >= 0, header.valueOffset <= bytes.count,
              count <= bytes.count - header.valueOffset else { throw DicomDIMSEProviderError(status: 0x0213) }
        image.set(.init(tag: 0x7FE0_0010, vr: header.vr,
            value: .bytes(bytes.subdata(in: header.valueOffset..<(header.valueOffset + count)))))
        data.set(printSCPSequence(sequence, [image]))
    }
    return data
}

/// Association-owned working hierarchy. Jobs retain value snapshots, so an
/// accepted output never observes later N-SETs or deletion of working objects.
actor DicomPrintAssociationState {
    struct FilmState {
        var film: DicomFilm
        var images: [String]
        var annotations: [String]
        var lutUID: String?
        var printed = false
        var imagePixelFingerprints: [Int: String] = [:]
        var imageLUTUIDs: [Int: String] = [:]
        var nativeGrayscaleSamples: [Int: [UInt16]] = [:]
        var rawPixelByteCounts: [Int: Int] = [:]
        var isColor = false
        var imageDensityRanges: [Int: (minimum: UInt16, maximum: UInt16)] = [:]
    }
    struct JobState {
        var status: DicomPrintExecutionStatus = .pending
        var info = "QUEUED"
        let control: DicomPrintJobControl
        let snapshot: [FilmState]
        let presentationLUTs: [String: DicomPresentationLUT]
        let priority: DicomPrintPriority
        let created = Date()
    }
    let configuration: DicomPrintSCPConfiguration
    let provider: any DicomPrintSCPProviding
    let queueAdmission: DicomPrintQueueAdmission
    let ingressBudget = DicomPrintIngressBudget()
    var sessionUID: String?
    var filmSession = DicomFilmSession()
    var films: [FilmState] = []
    var luts: [String: DicomPresentationLUT] = [:]
    var jobs: [String: JobState] = [:]
    var released = false
    var printerEvents: Task<Void, Never>?

    init(configuration: DicomPrintSCPConfiguration, provider: any DicomPrintSCPProviding,
         queueAdmission: DicomPrintQueueAdmission? = nil) {
        self.configuration = configuration
        self.provider = provider
        self.queueAdmission = queueAdmission ?? .init(maximum: configuration.maximumQueuedJobs)
    }

    func release() {
        released = true
        printerEvents?.cancel()
        if !configuration.keepJobsOnRelease { jobs.values.forEach { $0.control.cancel() } }
        films.removeAll()
        sessionUID = nil
        luts.removeAll()
    }

    func handle(_ command: DicomDIMSECommandSet, context: DicomAcceptedPresentationContext,
                data: DicomDataSet?, connection: DicomDIMSEServerSession) async throws {
        defer { updateIngressBudget() }
        if printerEvents == nil, let statusProvider = provider.printerStatusProvider,
           let printerContext = connection.association.acceptedPresentationContext(for: DicomNetworkUID.printerSOPClass)
                ?? connection.association.acceptedPresentationContext(for: DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass)
                ?? connection.association.acceptedPresentationContext(for: DicomNetworkUID.basicColorPrintManagementMetaSOPClass) {
            printerEvents = Task {
                for await report in await statusProvider.statusChanges() {
                    if Task.isCancelled { break }
                    try? await printerEvent(report, context: printerContext, connection: connection)
                }
            }
        }
        let sop = command.affectedSOPClassUID ?? command.requestedSOPClassUID ?? ""
        guard configuration.permits(sop) else { throw DicomDIMSEProviderError(status: 0x0118) }
        let uid = command.affectedSOPInstanceUID ?? command.requestedSOPInstanceUID ?? ""
        var response = command
        var reply: DicomDataSet?
        var status: UInt16 = 0
        var injectedWarning: UInt16?
        let allowed: Set<Int>
        switch sop {
        case DicomNetworkUID.basicFilmSessionSOPClass:
            allowed = [0x2000_0010, 0x2000_0020, 0x2000_0030, 0x2000_0040, 0x2000_0050, 0x2000_0060]
        case DicomNetworkUID.basicFilmBoxSOPClass:
            allowed = [0x2010_0010, 0x2010_0030, 0x2010_0040, 0x2010_0050, 0x2010_0060, 0x2010_0100,
                       0x2010_0110, 0x2010_0120, 0x2010_0130, 0x2010_0140, 0x2010_0150, 0x2010_0500,
                       0x2050_0500, 0x2010_015E, 0x2010_0160, 0x2010_0080]
        case DicomNetworkUID.basicGrayscaleImageBoxSOPClass, DicomNetworkUID.basicColorImageBoxSOPClass:
            allowed = [0x2020_0010, 0x2020_0020, 0x2020_0030, 0x2020_0040, 0x2020_0110, 0x2020_0111,
                       0x2130_00C0, 0x2050_0500, 0x2010_0120, 0x2010_0130]
        case DicomNetworkUID.basicAnnotationBoxSOPClass: allowed = [0x2030_0010, 0x2030_0020]
        case DicomNetworkUID.presentationLUTSOPClass: allowed = [0x2050_0010, 0x2050_0020]
        default: allowed = []
        }
        let unknown = data?.elements.map(\.tag).filter { !allowed.contains($0) } ?? []
        switch command.commandField {
        case DicomDIMSECommandField.nCreateRQ:
            if let fault = configuration.failCreate {
                if fault & 0xF000 == 0xB000 { injectedWarning = fault }
                else { throw DicomDIMSEProviderError(status: fault) }
            }
            guard let data else { throw DicomDIMSEProviderError(status: 0x0120) }
            let created = DicomDataSetWriter.makeUID()
            response.affectedSOPInstanceUID = created
            switch sop {
            case DicomNetworkUID.basicFilmSessionSOPClass:
                guard sessionUID == nil else {
                    throw DicomDIMSEProviderError(status: 0x0110, errorComment: "Only one Film Session per association")
                }
                filmSession = DicomFilmSession()
                if let copies = data.string(for: 0x2000_0010) {
                    guard let count = Int(copies), count > 0, count <= 1000 else { throw DicomDIMSEProviderError(status: 0x0106) }
                    filmSession.numberOfCopies = count
                }
                if let priority = data.string(for: 0x2000_0020) {
                    guard let value = DicomPrintPriority(rawValue: priority) else { throw DicomDIMSEProviderError(status: 0x0106) }
                    filmSession.printPriority = value
                }
                filmSession.label = data.string(for: 0x2000_0050)
                if let medium = data.string(for: 0x2000_0030) { filmSession.mediumType = medium }
                if let destination = data.string(for: 0x2000_0040) {
                    guard let value = DicomFilmDestination(rawValue: destination) else { throw DicomDIMSEProviderError(status: 0x0106) }
                    filmSession.filmDestination = value
                }
                sessionUID = created
                if data.element(for: 0x2000_0060) != nil { status = 0xB600 }
                reply = filmSession.dataSet
                reply?.set(printSCPSequence(0x2000_0500, []))
            case DicomNetworkUID.basicFilmBoxSOPClass:
                guard let sessionUID else { throw DicomDIMSEProviderError(status: 0x0112) }
                guard data.element(for: 0x2010_0500) != nil else { throw DicomDIMSEProviderError(status: 0x0120) }
                guard data.sequenceItems(for: 0x2010_0500).count == 1,
                      data.sequenceItems(for: 0x2010_0500).first?.dataSet.string(for: .referencedSOPInstanceUID) == sessionUID else {
                    throw DicomDIMSEProviderError(status: 0x0106)
                }
                guard films.count < configuration.limits.maximumFilmsPerJob else { throw DicomDIMSEProviderError(status: 0x0213) }
                if !configuration.supportsCollation, films.contains(where: { !$0.printed }) { throw DicomDIMSEProviderError(status: 0xC616) }
                guard let formatString = data.string(for: 0x2010_0010) else { throw DicomDIMSEProviderError(status: 0x0120) }
                let format: DicomImageDisplayFormat
                do { format = try .init(wireValue: formatString) } catch { throw DicomDIMSEProviderError(status: 0x0106) }
                let grid = configuration.printerDefinedGrids[format.wireValue]
                guard let count = format.imageBoxCapacity ?? grid?.imageBoxCapacity,
                      count <= configuration.limits.imageBoxesPerFilm else { throw DicomDIMSEProviderError(status: 0x0213) }
                let orientation = data.string(for: 0x2010_0040) ?? "PORTRAIT"
                guard let orientationValue = DicomFilmOrientation(rawValue: orientation) else { throw DicomDIMSEProviderError(status: 0x0106) }
                let filmSize = data.string(for: 0x2010_0050) ?? "8INX10IN"
                do { _ = try DicomPhysicalFilmSize(filmSizeID: filmSize) } catch { throw DicomDIMSEProviderError(status: 0x0106) }
                guard ["REPLICATE", "BILINEAR", "CUBIC", "NONE"].contains(data.string(for: 0x2010_0060) ?? "REPLICATE"),
                      ["YES", "NO"].contains(data.string(for: 0x2010_0140) ?? "NO") else {
                    throw DicomDIMSEProviderError(status: 0x0106)
                }
                let annotationFormat = data.string(for: 0x2010_0030)
                let annotationCount = annotationFormat.flatMap { configuration.annotationFormats[$0] } ?? 0
                if annotationFormat != nil && (annotationCount <= 0 || !configuration.permits(DicomNetworkUID.basicAnnotationBoxSOPClass)) {
                    throw DicomDIMSEProviderError(status: 0x0106)
                }
                guard annotationCount <= configuration.limits.annotationsPerFilm else { throw DicomDIMSEProviderError(status: 0x0213) }
                let lutUID = data.sequenceItems(for: 0x2050_0500).first?.dataSet.string(for: .referencedSOPInstanceUID)
                if let lutUID, luts[lutUID] == nil { throw DicomDIMSEProviderError(status: 0x0112) }
                var filmBox = DicomFilmBox(displayFormat: format, orientation: orientationValue, filmSizeID: filmSize,
                    magnificationType: data.string(for: 0x2010_0060) ?? "REPLICATE",
                    borderDensity: data.string(for: 0x2010_0100) ?? "BLACK",
                    emptyImageDensity: data.string(for: 0x2010_0110) ?? "BLACK",
                    trim: data.string(for: 0x2010_0140) == "YES", annotationDisplayFormatID: annotationFormat)
                let densities = try printSCPDensities(data)
                filmBox.updates = densities.data
                if let smoothing = data.element(for: 0x2010_0080) { filmBox.updates?.set(smoothing) }
                status = densities.status
                if let illumination = data.int(for: 0x2010_015E), (0...65535).contains(illumination) {
                    filmBox.illumination = UInt16(illumination)
                }
                if let ambient = data.int(for: 0x2010_0160), (0...65535).contains(ambient) {
                    filmBox.reflectedAmbientLight = UInt16(ambient)
                }
                let imageUIDs = (0..<count).map { _ in DicomDataSetWriter.makeUID() }
                let annotationUIDs = (0..<annotationCount).map { _ in DicomDataSetWriter.makeUID() }
                let isColor = context.abstractSyntaxUID == DicomNetworkUID.basicColorPrintManagementMetaSOPClass
                    || (context.abstractSyntaxUID == DicomNetworkUID.basicFilmBoxSOPClass
                        && configuration.permits(DicomNetworkUID.basicColorImageBoxSOPClass)
                        && !configuration.permits(DicomNetworkUID.basicGrayscaleImageBoxSOPClass))
                let imageSOP = isColor
                    ? DicomNetworkUID.basicColorImageBoxSOPClass : DicomNetworkUID.basicGrayscaleImageBoxSOPClass
                films.append(.init(film: .init(sopInstanceUID: created, filmBox: filmBox, imageBoxes: []),
                                   images: imageUIDs, annotations: annotationUIDs, lutUID: lutUID, isColor: isColor))
                reply = DicomDataSet(elements: [
                    printSCPSequence(0x2010_0510, imageUIDs.map { printSCPReference(imageSOP, $0) }),
                    printSCPSequence(0x2010_0520, annotationUIDs.map { printSCPReference(DicomNetworkUID.basicAnnotationBoxSOPClass, $0) })
                ])
            case DicomNetworkUID.presentationLUTSOPClass:
                guard data.element(for: 0x2050_0020) != nil || data.element(for: 0x2050_0010) != nil else {
                    throw DicomDIMSEProviderError(status: 0x0120)
                }
                do {
                    let tables = data.sequenceItems(for: 0x2050_0010)
                    if let shape = data.string(for: 0x2050_0020) {
                        guard tables.isEmpty else { throw DicomPrintManagementError.invalidPresentationLUT }
                        guard let shape = DicomPresentationLUT.Shape(rawValue: shape) else { throw DicomPrintManagementError.invalidPresentationLUT }
                        luts[created] = .init(shape: shape)
                    } else {
                        guard tables.count == 1, let item = tables.first?.dataSet,
                              let bytes = item.element(for: 0x0028_3006)?.bytesValue, bytes.count % 2 == 0 else {
                            throw DicomPrintManagementError.invalidPresentationLUT
                        }
                        let descriptor = item.ints(for: 0x0028_3002)
                        guard descriptor.allSatisfy({ $0 >= 0 && $0 <= 65535 }) else { throw DicomPrintManagementError.invalidPresentationLUT }
                        let values = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8 }
                        luts[created] = try .init(descriptor: descriptor.map(UInt16.init), values: values)
                    }
                } catch { throw DicomDIMSEProviderError(status: 0x0106) }
            default: throw DicomDIMSEProviderError(status: 0x0211)
            }
        case DicomDIMSECommandField.nSetRQ:
            if let fault = configuration.failSet { throw DicomDIMSEProviderError(status: fault) }
            guard let data else { throw DicomDIMSEProviderError(status: 0x0120) }
            if sop == DicomNetworkUID.basicFilmSessionSOPClass {
                guard uid == sessionUID else { throw DicomDIMSEProviderError(status: 0x0112) }
                var updated = filmSession
                if let copies = data.string(for: 0x2000_0010) {
                    guard let count = Int(copies), count > 0, count <= 1000 else { throw DicomDIMSEProviderError(status: 0x0106) }
                    updated.numberOfCopies = count
                }
                if let priority = data.string(for: 0x2000_0020) {
                    guard let value = DicomPrintPriority(rawValue: priority) else { throw DicomDIMSEProviderError(status: 0x0106) }
                    updated.printPriority = value
                }
                if let label = data.string(for: 0x2000_0050) { updated.label = label }
                if let medium = data.string(for: 0x2000_0030) { updated.mediumType = medium }
                if let destination = data.string(for: 0x2000_0040) {
                    guard let value = DicomFilmDestination(rawValue: destination) else { throw DicomDIMSEProviderError(status: 0x0106) }
                    updated.filmDestination = value
                }
                filmSession = updated
                try connection.reply(response, contextID: context.id, status: unknown.isEmpty ? 0 : 0x0107,
                    attributeIdentifierList: unknown)
                return
            }
            guard let last = films.indices.last else { throw DicomDIMSEProviderError(status: 0x0112) }
            if sop == DicomNetworkUID.basicGrayscaleImageBoxSOPClass || sop == DicomNetworkUID.basicColorImageBoxSOPClass {
                guard films[last].images.contains(uid) else { throw DicomDIMSEProviderError(status: 0x0112) }
                guard let position = data.int(for: 0x2020_0010) else { throw DicomDIMSEProviderError(status: 0x0120) }
                guard position > 0, position <= films[last].images.count,
                      films[last].images[position - 1] == uid else { throw DicomDIMSEProviderError(status: 0x0106) }
                let color = sop == DicomNetworkUID.basicColorImageBoxSOPClass
                guard color == films[last].isColor else { throw DicomDIMSEProviderError(status: 0x0112) }
                let sequenceTag = color ? 0x2020_0111 : 0x2020_0110
                guard data.element(for: sequenceTag) != nil else { throw DicomDIMSEProviderError(status: 0x0120) }
                let items = data.sequenceItems(for: sequenceTag)
                guard items.count <= 1 else { throw DicomDIMSEProviderError(status: 0x0106) }
                if let item = items.first?.dataSet {
                    let required = [0x0028_0002, 0x0028_0004, 0x0028_0010, 0x0028_0011, 0x0028_0100,
                                    0x0028_0101, 0x0028_0102, 0x0028_0103, 0x7FE0_0010] + (color ? [0x0028_0006] : [])
                    guard required.allSatisfy({ item.element(for: $0) != nil }) else {
                        throw DicomDIMSEProviderError(status: 0x0120,
                            errorComment: "Missing image attributes: " + required.filter { item.element(for: $0) == nil }.map { String($0, radix: 16) }.joined(separator: ","))
                    }
                    guard let rows = item.int(for: .rows), let columns = item.int(for: .columns),
                          let allocated = item.int(for: .bitsAllocated), let stored = item.int(for: .bitsStored),
                          rows > 0, columns > 0, [8, 16].contains(allocated),
                          (stored == 8 && allocated == 8 || stored == 12 && allocated == 16 && !color),
                          item.int(for: .highBit) == stored - 1, item.int(for: .pixelRepresentation) == 0,
                          item.int(for: .samplesPerPixel) == (color ? 3 : 1),
                          color ? item.string(for: .photometricInterpretation) == "RGB" && item.int(for: .planarConfiguration) == 1
                            : ["MONOCHROME1", "MONOCHROME2"].contains(item.string(for: .photometricInterpretation) ?? "") else {
                        throw DicomDIMSEProviderError(status: 0x0106)
                    }
                    let expected = try printSCPPixelByteCount(rows: rows, columns: columns,
                        samples: color ? 3 : 1, bits: allocated, limit: configuration.limits.bytesPerImageBox)
                    let count = rows * columns * 3
                    guard let pixels = item.element(for: .pixelData)?.bytesValue else { throw DicomDIMSEProviderError(status: 0x0106) }
                    guard pixels.count == expected || pixels.count == expected + expected % 2 else { throw DicomDIMSEProviderError(status: 0x0106) }
                    let existing = films[last].film.imageBoxes.filter { $0.position != position }.reduce(0) { $0 + $1.bitmap.rgbData.count }
                    let sessionBytes = films.enumerated().filter { $0.offset != last }.reduce(existing) {
                        $0 + $1.element.film.imageBoxes.reduce(0) { $0 + $1.bitmap.rgbData.count }
                    }
                    let nativeResident = films.enumerated().reduce(0) { sum, film in
                        sum + film.element.nativeGrayscaleSamples.filter { film.offset != last || $0.key != position }
                            .values.reduce(0) { $0 + $1.count * 2 }
                    }
                    guard count + (stored == 12 ? rows * columns * 2 : 0)
                            <= configuration.maximumResidentPixelBytes - sessionBytes - nativeResident else {
                        throw DicomDIMSEProviderError(status: 0xC605)
                    }
                    let filmRaw = films[last].rawPixelByteCounts.filter { $0.key != position }.values.reduce(0, +)
                    let sessionRaw = films.enumerated().filter { $0.offset != last }.reduce(filmRaw) {
                        $0 + $1.element.rawPixelByteCounts.values.reduce(0, +)
                    }
                    guard expected <= configuration.limits.bytesPerFilm - filmRaw,
                          expected <= configuration.limits.bytesPerJob - sessionRaw else { throw DicomDIMSEProviderError(status: 0x0213) }
                    var rgb = Data(count: count)
                    var nativeSamples: [UInt16] = []
                    if stored == 12 { nativeSamples.reserveCapacity(rows * columns) }
                    for index in 0..<(rows * columns) {
                        for channel in 0..<3 {
                            let value: UInt8
                            if color { value = pixels[channel * rows * columns + index] }
                            else {
                                let raw = allocated == 8 ? UInt16(pixels[index]) : UInt16(pixels[index * 2]) | UInt16(pixels[index * 2 + 1]) << 8
                                if stored == 12 && channel == 0 {
                                    guard raw <= 4095 else { throw DicomDIMSEProviderError(status: 0x0106) }
                                    nativeSamples.append(item.string(for: .photometricInterpretation) == "MONOCHROME1" ? 4095 - raw : raw)
                                }
                                let scaled = UInt8(min(255, Int(raw) * 255 / ((1 << stored) - 1)))
                                value = item.string(for: .photometricInterpretation) == "MONOCHROME1" ? 255 - scaled : scaled
                            }
                            rgb[index * 3 + channel] = value
                        }
                    }
                    var image = try DicomImageBox(position: position, bitmap: .init(width: columns, height: rows, rgbData: rgb))
                    image.originalImage = data.sequenceItems(for: 0x2130_00C0).first?.dataSet
                    if let size = data.string(for: 0x2020_0030) {
                        guard let value = Double(size), value.isFinite, value > 0 else { throw DicomDIMSEProviderError(status: 0x0106) }
                        image.requestedImageSize = value
                    }
                    if let behavior = data.string(for: 0x2020_0040) {
                        guard let value = DicomPrintDecimateCropBehavior(rawValue: behavior) else { throw DicomDIMSEProviderError(status: 0x0106) }
                        image.requestedDecimateCropBehavior = value
                    }
                    if let polarity = data.string(for: 0x2020_0020) {
                        guard let value = DicomPrintPolarity(rawValue: polarity) else { throw DicomDIMSEProviderError(status: 0x0106) }
                        image.polarity = value
                    }
                    var candidate = films[last].film
                    let densities = try printSCPDensities(data)
                    var ranges = films[last].imageDensityRanges
                    if !densities.data.elements.isEmpty {
                        let old = ranges[position] ?? (20, 300)
                        let minimum = UInt16(densities.data.int(for: 0x2010_0120) ?? Int(old.minimum))
                        let maximum = UInt16(densities.data.int(for: 0x2010_0130) ?? Int(old.maximum))
                        guard minimum < maximum else { throw DicomDIMSEProviderError(status: 0x0106) }
                        ranges[position] = (minimum, maximum)
                    }
                    var native = films[last].nativeGrayscaleSamples
                    native[position] = stored == 12 ? nativeSamples : nil
                    var imageLUTUIDs = films[last].imageLUTUIDs
                    if data.element(for: 0x2050_0500) != nil {
                        let references = data.sequenceItems(for: 0x2050_0500)
                        guard references.count == 1, let reference = references.first?.dataSet.string(for: .referencedSOPInstanceUID),
                              luts[reference] != nil else { throw DicomDIMSEProviderError(status: 0x0112) }
                        imageLUTUIDs[position] = reference
                    }
                    candidate.imageBoxes.removeAll { $0.position == position }
                    candidate.imageBoxes.append(image)
                    let composed: DicomComposedFilm
                    do { composed = try compose(candidate, lutUID: films[last].lutUID, color: color,
                        imageLUTUIDs: imageLUTUIDs, native: native, densityRanges: ranges) }
                    catch DicomFilmCompositionError.imageDoesNotFit { throw DicomDIMSEProviderError(status: 0xC603) }
                    catch DicomFilmCompositionError.invalidParameter { throw DicomDIMSEProviderError(status: 0x0106) }
                    status = densities.status != 0 ? densities.status : composed.info.fitByPosition[position]?.warningStatus ?? 0
                    films[last].film = candidate
                    films[last].imageLUTUIDs = imageLUTUIDs
                    films[last].nativeGrayscaleSamples = native
                    films[last].rawPixelByteCounts[position] = expected
                    films[last].imageDensityRanges = ranges
                    films[last].imagePixelFingerprints[position] = SHA256.hash(data: pixels).map { String(format: "%02x", $0) }.joined()
                } else {
                    films[last].film.imageBoxes.removeAll { $0.position == position }
                    films[last].imagePixelFingerprints.removeValue(forKey: position)
                    films[last].nativeGrayscaleSamples.removeValue(forKey: position)
                    films[last].rawPixelByteCounts.removeValue(forKey: position)
                }
            } else if sop == DicomNetworkUID.basicFilmBoxSOPClass {
                guard films[last].film.sopInstanceUID == uid else { throw DicomDIMSEProviderError(status: 0x0112) }
                var candidate = films[last].film
                let densities = try printSCPDensities(data)
                var updates = candidate.filmBox.updates ?? DicomDataSet()
                for value in densities.data.elements { updates.set(value) }
                candidate.filmBox.updates = updates
                status = densities.status
                if let value = data.string(for: 0x2010_0060) {
                    guard ["REPLICATE", "BILINEAR", "CUBIC", "NONE"].contains(value) else { throw DicomDIMSEProviderError(status: 0x0106) }
                    candidate.filmBox.magnificationType = value
                }
                if let value = data.string(for: 0x2010_0100) { candidate.filmBox.borderDensity = value }
                if let value = data.string(for: 0x2010_0110) { candidate.filmBox.emptyImageDensity = value }
                for tag in [0x2010_0080, 0x2010_015E, 0x2010_0160] {
                    if let value = data.element(for: tag) { candidate.filmBox.updates?.set(value) }
                }
                if let value = data.string(for: 0x2010_0140) {
                    guard ["YES", "NO"].contains(value) else { throw DicomDIMSEProviderError(status: 0x0106) }
                    candidate.filmBox.trim = value == "YES"
                }
                var lutUID = films[last].lutUID
                if data.element(for: 0x2050_0500) != nil {
                    let references = data.sequenceItems(for: 0x2050_0500)
                    guard references.count == 1, let reference = references.first?.dataSet.string(for: .referencedSOPInstanceUID),
                          luts[reference] != nil else { throw DicomDIMSEProviderError(status: 0x0112) }
                    lutUID = reference
                }
                _ = try compose(candidate, lutUID: lutUID, color: films[last].isColor,
                                imageLUTUIDs: films[last].imageLUTUIDs, native: films[last].nativeGrayscaleSamples,
                                densityRanges: films[last].imageDensityRanges)
                films[last].film = candidate
                films[last].lutUID = lutUID
            } else if sop == DicomNetworkUID.basicAnnotationBoxSOPClass {
                guard films[last].annotations.contains(uid) else { throw DicomDIMSEProviderError(status: 0x0112) }
                guard let position = data.int(for: 0x2030_0010) else { throw DicomDIMSEProviderError(status: 0x0120) }
                guard position > 0, position <= films[last].annotations.count else { throw DicomDIMSEProviderError(status: 0x0106) }
                let text = data.string(for: 0x2030_0020) ?? ""
                if !text.isEmpty {
                    let annotation: DicomPrintAnnotation
                    do { annotation = try .init(position: position, text: text) } catch { throw DicomDIMSEProviderError(status: 0x0106) }
                    films[last].film.annotations.removeAll { $0.position == position }
                    films[last].film.annotations.append(annotation)
                } else { films[last].film.annotations.removeAll { $0.position == position } }
            } else { throw DicomDIMSEProviderError(status: 0x0211) }
        case DicomDIMSECommandField.nDeleteRQ:
            if sop == DicomNetworkUID.basicAnnotationBoxSOPClass || sop == DicomNetworkUID.printJobSOPClass {
                throw DicomDIMSEProviderError(status: 0x0211)
            }
            if sop == DicomNetworkUID.basicFilmSessionSOPClass && uid == sessionUID {
                sessionUID = nil; films.removeAll()
            } else if sop == DicomNetworkUID.basicFilmBoxSOPClass, let index = films.firstIndex(where: { $0.film.sopInstanceUID == uid }) {
                guard index == films.count - 1 else {
                    throw DicomDIMSEProviderError(status: 0x0110, errorComment: "Only the last Film Box can be deleted")
                }
                films.remove(at: index)
            } else if sop == DicomNetworkUID.presentationLUTSOPClass, luts[uid] != nil {
                guard !films.contains(where: { $0.lutUID == uid || $0.imageLUTUIDs.values.contains(uid) }),
                      !jobs.values.contains(where: { $0.presentationLUTs[uid] != nil }) else {
                    throw DicomDIMSEProviderError(status: 0x0110, errorComment: "Presentation LUT is referenced")
                }
                luts.removeValue(forKey: uid)
            } else { throw DicomDIMSEProviderError(status: 0x0112) }
        case DicomDIMSECommandField.nGetRQ:
            if sop == DicomNetworkUID.printerSOPClass && uid == DicomNetworkUID.printerSOPInstance {
                reply = configuration.printerAttributes
                if let statusProvider = provider.printerStatusProvider {
                    let report = await statusProvider.currentStatus()
                    reply?.set(printSCPString(0x2110_0010, report.state.rawValue))
                    reply?.set(printSCPString(0x2110_0020, report.statusInfo ?? "NORMAL"))
                }
                if reply?.element(for: 0x2110_0010) == nil { reply?.set(printSCPString(0x2110_0010, "NORMAL")) }
                if reply?.element(for: 0x2110_0020) == nil { reply?.set(printSCPString(0x2110_0020, "NORMAL")) }
                reply?.set(printSCPString(0x2110_0030, configuration.printerName, vr: .LO))
            } else if sop == DicomNetworkUID.printerConfigurationRetrievalSOPClass && uid == DicomNetworkUID.printerConfigurationRetrievalSOPInstance {
                reply = try configuration.capabilities.printerConfiguration?.dataSet ?? printerConfigurationDataSet()
            } else if sop == DicomNetworkUID.printJobSOPClass, let job = jobs[uid] {
                let date = DateFormatter()
                date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
                date.dateFormat = "yyyyMMdd"
                let day = date.string(from: job.created)
                date.dateFormat = "HHmmss"
                reply = .init(elements: [printSCPString(0x2100_0020, job.status.rawValue), printSCPString(0x2100_0030, job.info),
                    printSCPString(0x2000_0020, job.priority.rawValue), printSCPString(0x2100_0040, day, vr: .DA),
                    printSCPString(0x2100_0050, date.string(from: job.created), vr: .TM),
                    printSCPString(0x2110_0030, configuration.printerName, vr: .LO),
                    printSCPString(0x2100_0070, connection.association.request.callingAETitle, vr: .AE)])
            } else { throw DicomDIMSEProviderError(status: 0x0112) }
        case DicomDIMSECommandField.nActionRQ:
            if let fault = configuration.failAction { throw DicomDIMSEProviderError(status: fault) }
            guard command.actionTypeID == 1 else { throw DicomDIMSEProviderError(status: 0x0211) }
            let selected: [FilmState]
            let sessionAction = sop == DicomNetworkUID.basicFilmSessionSOPClass
            if sessionAction {
                guard uid == sessionUID else { throw DicomDIMSEProviderError(status: 0x0112) }
                guard configuration.supportsCollation else { try connection.reply(command, contextID: context.id, status: 0xB601); return }
                guard !films.isEmpty else { throw DicomDIMSEProviderError(status: 0xC600) }
                selected = films
            } else if sop == DicomNetworkUID.basicFilmBoxSOPClass, let film = films.first(where: { $0.film.sopInstanceUID == uid }) {
                selected = [film]
            } else { throw DicomDIMSEProviderError(status: 0x0112) }
            guard jobs.count < configuration.maximumQueuedJobs else { throw DicomDIMSEProviderError(status: sessionAction ? 0xC601 : 0xC602) }
            if selected.allSatisfy({ $0.film.imageBoxes.isEmpty }) {
                try connection.reply(command, contextID: context.id, status: sessionAction ? 0xB602 : 0xB603); return
            }
            guard queueAdmission.reserve() else { throw DicomDIMSEProviderError(status: sessionAction ? 0xC601 : 0xC602) }
            var queued = false
            defer { if !queued { queueAdmission.release() } }
            let sheets: [DicomComposedFilm]
            do {
                var remaining = configuration.limits.bytesPerJob
                sheets = try selected.map {
                    guard remaining > 0 else { throw DicomDIMSEProviderError(status: 0x0213) }
                    let sheet = try compose($0.film, lutUID: $0.lutUID, color: $0.isColor,
                        imageLUTUIDs: $0.imageLUTUIDs, native: $0.nativeGrayscaleSamples,
                        densityRanges: $0.imageDensityRanges, maximumOutputBytes: remaining)
                    remaining -= sheet.pixelData.count
                    return sheet
                }
            } catch DicomFilmCompositionError.imageDoesNotFit { throw DicomDIMSEProviderError(status: 0xC603) }
            catch DicomFilmCompositionError.resourceLimit { throw DicomDIMSEProviderError(status: 0x0213) }
            let jobID = DicomDataSetWriter.makeUID()
            let control = DicomPrintJobControl(id: jobID)
            let referencedLUTs = Set(selected.flatMap { film in
                Array(film.imageLUTUIDs.values) + (film.lutUID.map { [$0] } ?? [])
            })
            jobs[jobID] = .init(control: control, snapshot: selected,
                presentationLUTs: luts.filter { referencedLUTs.contains($0.key) }, priority: filmSession.printPriority)
            for index in films.indices where selected.contains(where: { $0.film.sopInstanceUID == films[index].film.sopInstanceUID }) {
                films[index].printed = true
            }
            let jobContext = connection.association.acceptedPresentationContext(for: DicomNetworkUID.printJobSOPClass)
            if jobContext != nil {
                reply = .init(elements: [printSCPSequence(0x2100_0500, [printSCPReference(DicomNetworkUID.printJobSOPClass, jobID)])])
            }
            let actionStatus = sheets.flatMap { sheet in
                sheet.info.fitByPosition.keys.sorted().compactMap { sheet.info.fitByPosition[$0]?.warningStatus }
            }.first ?? 0
            try connection.reply(response, contextID: context.id, status: actionStatus, identifier: reply)
            let copies = filmSession.numberOfCopies
            queued = true
            Task { await run(jobID, sheets: sheets, fingerprints: selected.map(\.imagePixelFingerprints),
                             copies: copies, connection: connection, context: jobContext) }
            return
        default: throw DicomDIMSEProviderError(status: 0x0211)
        }
        try connection.reply(response, contextID: context.id, status: unknown.isEmpty ? (injectedWarning ?? status) : 0x0107,
                             identifier: reply, attributeIdentifierList: unknown)
    }

    private func updateIngressBudget() {
        let sessionRaw = films.reduce(0) { $0 + $1.rawPixelByteCounts.values.reduce(0, +) }
        let resident = films.reduce(0) { total, film in
            total + film.film.imageBoxes.reduce(0) { $0 + $1.bitmap.rgbData.count }
                + film.nativeGrayscaleSamples.values.reduce(0) { $0 + $1.count * 2 }
        }
        var budgets: [String: DicomPrintIngressBudget.Allowance] = [:]
        if let last = films.last {
            let filmRaw = last.rawPixelByteCounts.values.reduce(0, +)
            for (index, uid) in last.images.enumerated() {
                let position = index + 1
                let oldRaw = last.rawPixelByteCounts[position] ?? 0
                let oldResident = (last.film.imageBoxes.first { $0.position == position }?.bitmap.rgbData.count ?? 0)
                    + (last.nativeGrayscaleSamples[position]?.count ?? 0) * 2
                budgets[uid] = .init(raw: min(configuration.limits.bytesPerImageBox,
                    configuration.limits.bytesPerFilm - filmRaw + oldRaw,
                    configuration.limits.bytesPerJob - sessionRaw + oldRaw),
                    resident: configuration.maximumResidentPixelBytes - resident + oldResident)
            }
        }
        ingressBudget.replace(budgets)
    }

    private func compose(_ film: DicomFilm, lutUID: String?, color: Bool,
                         imageLUTUIDs: [Int: String] = [:], native: [Int: [UInt16]] = [:],
                         densityRanges: [Int: (minimum: UInt16, maximum: UInt16)] = [:],
                         maximumOutputBytes: Int = 64 * 1024 * 1024) throws -> DicomComposedFilm {
        var description = try DicomFilmDescription(film: film)
        description.outputWidth = configuration.outputWidth
        description.printerPixelSpacing = try printConfiguredPixelSpacing(film.filmBox,
            meta: color ? DicomNetworkUID.basicColorPrintManagementMetaSOPClass : DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
            configuration: configuration.capabilities.printerConfiguration)
        description.color = color
        description.identify = configuration.identify
        description.presentationLUT = lutUID.flatMap { luts[$0] }
        description.imagePresentationLUTs = imageLUTUIDs.compactMapValues { luts[$0] }
        description.nativeGrayscaleSamples = native
        description.nativeBitsStored = native.mapValues { _ in 12 }
        description.imageDensityRanges = densityRanges
        description.maximumOutputBytes = min(64 * 1024 * 1024, maximumOutputBytes)
        description.printerDefinedGrid = configuration.printerDefinedGrids[description.displayFormat.wireValue]
        description.annotationRows = film.filmBox.annotationDisplayFormatID.flatMap { configuration.annotationFormats[$0] } ?? 0
        return try DicomFilmCompositor(textRasterizer: provider.textRasterizer).compose(description)
    }

    private func printerConfigurationDataSet() throws -> DicomDataSet {
        var formats: [DicomDataSet] = []
        for format in configuration.displayFormats {
            let slots = try DicomFilmGeometry.slots(format: format,
                bounds: .init(x: 0, y: 0, width: configuration.outputWidth, height: configuration.outputWidth * 5 / 4),
                printerDefinedGrid: configuration.printerDefinedGrids[format.wireValue])
            guard let first = slots.first else { continue }
            formats.append(.init(elements: [printSCPString(0x2010_0010, format.wireValue, vr: .ST),
                printSCPString(0x2010_0040, "PORTRAIT"), printSCPString(0x2010_0050, "8INX10IN"),
                printSCPString(0x2010_0052, "STANDARD"), printSCPString(0x2020_00A0, "YES"),
                .init(tag: 0x2010_0376, vr: .DS,
                      value: .strings([String(203.2 / Double(configuration.outputWidth)), String(203.2 / Double(configuration.outputWidth))])),
                .init(tag: 0x0028_0010, vr: .US, value: .unsignedIntegers([UInt(first.height)])),
                .init(tag: 0x0028_0011, vr: .US, value: .unsignedIntegers([UInt(first.width)]))]))
        }
        let installed = DicomDataSet(elements: [printSCPString(0x2000_0030, "BLUE FILM"), printSCPString(0x2010_0050, "8INX10IN"),
            .init(tag: 0x2010_0120, vr: .US, value: .unsignedIntegers([20])),
            .init(tag: 0x2010_0130, vr: .US, value: .unsignedIntegers([300]))])
        let printer = DicomDataSet(elements: [
            .init(tag: 0x0008_115A, vr: .UI, value: .strings(configuration.capabilities.acceptedSOPClassUIDs.sorted())),
            printSCPString(0x2110_0030, configuration.printerName, vr: .LO),
            printSCPString(0x0008_0070, configuration.printerAttributes.string(for: 0x0008_0070) ?? "DICOM-Swift", vr: .LO),
            printSCPString(0x0008_1090, configuration.printerAttributes.string(for: 0x0008_1090) ?? "CPU Film Printer", vr: .LO),
            printSCPSequence(0x2000_00A2, [installed]), printSCPSequence(0x2000_00A8, formats),
            printSCPString(0x2010_0054, "STANDARD"), printSCPString(0x2010_00A6, "REPLICATE"),
            .init(tag: 0x2010_00A7, vr: .CS, value: .strings(["BILINEAR", "CUBIC", "NONE"])),
            printSCPString(0x2020_00A2, "DEF DECIMATE"),
            .init(tag: 0x2010_0154, vr: .US, value: .unsignedIntegers([UInt(configuration.supportsCollation ? min(65535, max(0, configuration.limits.maximumFilmsPerJob)) : 0)]))
        ])
        return .init(elements: [printSCPSequence(0x2000_001E, [printer])])
    }

    private func printerEvent(_ report: DicomPrinterStatusReport, context: DicomAcceptedPresentationContext,
                              connection: DicomDIMSEServerSession) async throws {
        guard !released, report.state == .warning || report.state == .failure else { return }
        let command = DicomDIMSECommandSet(affectedSOPClassUID: DicomNetworkUID.printerSOPClass,
            commandField: DicomDIMSECommandField.nEventReportRQ, commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            affectedSOPInstanceUID: DicomNetworkUID.printerSOPInstance, eventTypeID: report.state == .warning ? 2 : 3)
        let data = DicomDataSet(elements: [printSCPString(0x2110_0020, report.statusInfo ?? "UNKNOWN"),
                                         printSCPString(0x2110_0030, configuration.printerName, vr: .LO)])
        _ = try await connection.suboperation(command, contextID: context.id,
            bytes: DicomDataSetWriter.dataSetData(from: data, transferSyntax: context.transferSyntax ?? .implicitVRLittleEndian))
    }

    private func run(_ id: String, sheets: [DicomComposedFilm], fingerprints: [[Int: String]], copies: Int,
                     connection: DicomDIMSEServerSession, context: DicomAcceptedPresentationContext?) async {
        defer { queueAdmission.release() }
        guard let control = jobs[id]?.control else { return }
        await provider.jobCreated(control)
        do {
            try await event(id, status: .pending, info: "QUEUED", connection: connection, context: context)
            if control.isCancelled { throw CancellationError() }
            try await event(id, status: .printing, info: "NORMAL", connection: connection, context: context)
            for copy in 0..<copies {
                for (index, sheet) in sheets.enumerated() {
                    if control.isCancelled { throw CancellationError() }
                    let filmIndex = copy * sheets.count + index
                    let result = await provider.outputProvider.output(sheet,
                        metadata: .init(jobID: id, filmIndex: filmIndex, filmCount: copies * sheets.count,
                                        originator: connection.association.request.callingAETitle,
                                        imagePixelFingerprints: fingerprints[index]), control: control)
                    if case .failure(let info) = result {
                        try await event(id, status: .failure, info: info, connection: connection, context: context)
                        jobs.removeValue(forKey: id)
                        await provider.outputProvider.finish(jobID: id)
                        return
                    }
                    control.recordCompletedFilm(filmIndex)
                }
            }
            if control.isCancelled { throw CancellationError() }
            try await event(id, status: .done, info: "NORMAL", connection: connection, context: context)
            jobs.removeValue(forKey: id)
        } catch {
            if control.isCancelled {
                do {
                    try await event(id, status: .failure, info: "CANCELLED", connection: connection, context: context)
                } catch { /* The terminal job is released even when notification fails. */ }
            }
            jobs.removeValue(forKey: id)
        }
        await provider.outputProvider.finish(jobID: id)
    }

    private func event(_ id: String, status: DicomPrintExecutionStatus, info: String,
                       connection: DicomDIMSEServerSession, context: DicomAcceptedPresentationContext?) async throws {
        jobs[id]?.status = status
        jobs[id]?.info = info
        guard !released, let context else { return }
        let eventID: UInt16 = [.pending: 1, .printing: 2, .done: 3, .failure: 4][status] ?? 4
        let data = DicomDataSet(elements: [printSCPString(0x2100_0030, info), printSCPString(0x2100_0020, status.rawValue)])
        let request = DicomDIMSECommandSet(affectedSOPClassUID: DicomNetworkUID.printJobSOPClass,
            commandField: DicomDIMSECommandField.nEventReportRQ, commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
            affectedSOPInstanceUID: id, eventTypeID: eventID)
        let response = try await connection.suboperation(request, contextID: context.id,
            bytes: DicomDataSetWriter.dataSetData(from: data, transferSyntax: context.transferSyntax ?? .implicitVRLittleEndian))
        guard response.status == 0 else { throw DicomDIMSEProviderError(status: response.status ?? 0x0110) }
    }
}

func printSCPString(_ tag: Int, _ value: String, vr: DicomVR = .CS) -> DicomDataElement {
    .init(tag: tag, vr: vr, value: .strings([value]))
}

func printSCPSequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
    .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
}

func printSCPReference(_ sop: String, _ uid: String) -> DicomDataSet {
    .init(elements: [printSCPString(0x0008_1150, sop, vr: .UI), printSCPString(0x0008_1155, uid, vr: .UI)])
}

func printSCPDensities(_ data: DicomDataSet) throws -> (data: DicomDataSet, status: UInt16) {
    var result = DicomDataSet()
    var status: UInt16 = 0
    for tag in [0x2010_0120, 0x2010_0130] where data.element(for: tag) != nil {
        guard let value = data.int(for: tag), value >= 0, value <= 65535 else { throw DicomDIMSEProviderError(status: 0x0106) }
        let bounded = min(300, max(20, value))
        if bounded != value { status = 0xB605 }
        result.set(.init(tag: tag, vr: .US, value: .unsignedIntegers([UInt(bounded)])))
    }
    guard (result.int(for: 0x2010_0120) ?? 20) < (result.int(for: 0x2010_0130) ?? 300) else {
        throw DicomDIMSEProviderError(status: 0x0106)
    }
    return (result, status)
}

func printSCPPixelByteCount(rows: Int, columns: Int, samples: Int, bits: Int, limit: Int) throws -> Int {
    guard rows > 0, rows <= 65535, columns > 0, columns <= 65535, [1, 3].contains(samples),
          [8, 16].contains(bits) else { throw DicomDIMSEProviderError(status: 0x0106) }
    let count = rows * columns * samples * (bits / 8)
    guard count <= limit else { throw DicomDIMSEProviderError(status: 0x0213) }
    return count
}

final class DicomPrintIngressBudget: @unchecked Sendable {
    struct Allowance { let raw: Int; let resident: Int }
    private let lock = NSLock()
    private var values: [String: Allowance] = [:]
    func replace(_ values: [String: Allowance]) { lock.withLock { self.values = values } }
    func allowance(for uid: String) -> Allowance? { lock.withLock { values[uid] } }
}

/// Inspect headers before forwarding a PDV into the DIMSE message accumulator.
/// Only bounded header/scalar storage is retained here; Pixel Data is never copied.
struct DicomPrintPixelAdmission {
    let allowance: DicomPrintIngressBudget.Allowance
    let explicitVR: Bool
    private var header: [UInt8] = []
    private var headerLength = 8
    private var remaining = 0
    private var valueTag = 0
    private var scalar: [UInt8] = []
    private var metadataCount = 0
    private var rows = 0
    private var columns = 0
    private var samples = 0
    private var bits = 0
    private var pixelValue = false
    private var sawPixels = false
    private(set) var pixelBytesSeen = 0
    private(set) var failure: UInt16?

    init(allowance: DicomPrintIngressBudget.Allowance, explicitVR: Bool) {
        self.allowance = allowance
        self.explicitVR = explicitVR
    }

    mutating func consume(_ bytes: Data, final: Bool) {
        let dimensions: Set<Int> = [0x0028_0010, 0x0028_0011, 0x0028_0002, 0x0028_0100]
        for byte in bytes {
            if failure != nil { break }
            if remaining > 0 {
                remaining -= 1
                if pixelValue {
                    pixelBytesSeen += 1
                    if remaining == 0 { pixelValue = false }
                    continue
                }
                metadataCount += 1
                if dimensions.contains(valueTag) {
                    scalar.append(byte)
                    if remaining == 0 {
                        guard scalar.count == 2 else { failure = 0x0106; break }
                        let value = Int(scalar[0]) | Int(scalar[1]) << 8
                        switch valueTag {
                        case 0x0028_0010: rows = value
                        case 0x0028_0011: columns = value
                        case 0x0028_0002: samples = value
                        case 0x0028_0100: bits = value
                        default: break
                        }
                    }
                }
            } else {
                metadataCount += 1
                header.append(byte)
                if header.count == 6 && explicitVR && !(header[0] == 0xFE && header[1] == 0xFF) {
                    let vr = String(bytes: header[4..<6], encoding: .ascii) ?? ""
                    headerLength = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "UC", "UR", "UT", "UN"].contains(vr) ? 12 : 8
                }
                if header.count == headerLength {
                    let group = Int(header[0]) | Int(header[1]) << 8
                    let element = Int(header[2]) | Int(header[3]) << 8
                    let tag = group << 16 | element
                    let vr = explicitVR && group != 0xFFFE ? String(bytes: header[4..<6], encoding: .ascii) : nil
                    let start = !explicitVR || group == 0xFFFE ? 4 : headerLength == 12 ? 8 : 6
                    let length = header[start...].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
                    let sequence = vr == "SQ" || (!explicitVR && DCMDictionary().vrCode(forTag: tag) == "SQ")
                    header.removeAll(keepingCapacity: true)
                    headerLength = 8
                    scalar.removeAll(keepingCapacity: true)
                    if sequence || group == 0xFFFE { continue }
                    guard length != UInt32.max else { failure = 0x0106; break }
                    valueTag = tag
                    remaining = Int(length)
                    if tag == 0x7FE0_0010 {
                        guard !sawPixels else { failure = 0x0106; break }
                        sawPixels = true
                        do {
                            let expected = try printSCPPixelByteCount(rows: rows, columns: columns, samples: samples,
                                                                     bits: bits, limit: allowance.raw)
                            guard remaining == expected || remaining == expected + expected % 2 else { failure = 0x0106; break }
                            let resident = rows * columns * (bits == 16 && samples == 1 ? 5 : 3)
                            guard resident <= allowance.resident else { failure = 0xC605; break }
                            pixelValue = true
                        } catch let error as DicomDIMSEProviderError { failure = error.status }
                        catch { failure = 0x0110 }
                    } else if remaining > 65536 || dimensions.contains(tag) && remaining != 2 {
                        failure = remaining > 65536 ? 0x0213 : 0x0106
                    }
                }
            }
            if metadataCount > 65536 { failure = 0x0213 }
        }
        if final, failure == nil, remaining != 0 || !header.isEmpty { failure = 0x0106 }
    }
}

final class DicomPrintAdmissionTransport: DicomAssociationTransport {
    private let underlying: DicomAssociationTransport
    private let association: DicomAssociation
    private let budget: DicomPrintIngressBudget
    private var commandBytes = Data()
    private var inspection: DicomPrintPixelAdmission?
    private var rejectedInstance = false
    private var results: [UInt16?] = []
    var isOpen: Bool { underlying.isOpen }

    init(underlying: DicomAssociationTransport, association: DicomAssociation, budget: DicomPrintIngressBudget) {
        self.underlying = underlying
        self.association = association
        self.budget = budget
    }

    func writePDU(_ data: Data) throws { try underlying.writePDU(data) }
    func takeImageFailure() -> UInt16? { results.isEmpty ? nil : results.removeFirst() }

    func readPDU() throws -> Data {
        let encoded = try underlying.readPDU()
        guard case .pData(let values) = try DicomPDUCodec.decode(encoded) else { return encoded }
        var forwarded: [DicomPDV] = []
        for value in values {
            var value = value
            if value.isCommand {
                guard commandBytes.count + value.data.count <= 65536 else { throw DicomDIMSEProviderError(status: 0x0213) }
                commandBytes.append(value.data)
                if value.isLastFragment {
                    let command = try DicomDIMSECommandSet.decode(commandBytes)
                    commandBytes.removeAll(keepingCapacity: true)
                    inspection = nil
                    rejectedInstance = false
                    let sop = command.requestedSOPClassUID ?? command.affectedSOPClassUID ?? ""
                    if command.commandField == DicomDIMSECommandField.nSetRQ,
                       command.commandDataSetType != DicomDIMSECommandDataSetType.noDataSet,
                       [DicomNetworkUID.basicGrayscaleImageBoxSOPClass, DicomNetworkUID.basicColorImageBoxSOPClass].contains(sop) {
                        let allowance = budget.allowance(for: command.requestedSOPInstanceUID ?? command.affectedSOPInstanceUID ?? "")
                        rejectedInstance = allowance == nil
                        let syntax = association.acceptedPresentationContexts.first { $0.id == value.presentationContextID }?.transferSyntax
                        inspection = .init(allowance: allowance ?? .init(raw: 0, resident: 0), explicitVR: syntax?.isExplicitVR ?? false)
                    }
                }
            } else if inspection != nil {
                inspection?.consume(value.data, final: value.isLastFragment)
                let failure = rejectedInstance ? UInt16(0x0112) : inspection?.failure
                if failure != nil { value.data = Data() }
                if value.isLastFragment {
                    results.append(failure)
                    inspection = nil
                    rejectedInstance = false
                }
            }
            forwarded.append(value)
        }
        return try DicomPDUCodec.encode(.pData(forwarded))
    }
}
