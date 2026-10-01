import Foundation

public enum DicomPrintPreview {
    /// A preview before association requires an explicit mode. Automatic mode
    /// needs the negotiated mode supplied by the caller. Peer-dependent image
    /// size/crop requests are represented only when `peerConfiguration` permits them.
    public static func compose(job: DicomPrintJob, outputWidth: Int = 1024,
                               resolvedMode: DicomPrintMode? = nil,
                               peerConfiguration: DicomPrinterConfiguration? = nil,
                               annotationFormats: [String: Int] = [:],
                               printerDefinedGrids: [String: DicomImageDisplayFormat] = [:],
                               identify: Bool = false,
                               textRasterizer: any DicomPrintTextRasterizing = DicomCoreTextPrintRasterizer()) throws -> [DicomComposedFilm] {
        try job.limits.validate(films: job.effectiveFilms)
        let mode: DicomResolvedPrintMode
        switch job.printMode {
        case .grayscale: mode = .grayscale
        case .color: mode = .color
        case .automatic:
            guard let resolvedMode, resolvedMode != .automatic else {
                throw DicomFilmCompositionError.invalidParameter("Preview requires negotiated print mode")
            }
            mode = resolvedMode == .color ? .color : .grayscale
        }
        let meta = mode == .color ? DicomNetworkUID.basicColorPrintManagementMetaSOPClass
            : DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
        return try job.effectiveFilms.map { input in
            var film = input
            for index in film.imageBoxes.indices {
                let allowedSize = peerConfiguration?.requestedImageSizeAllowed(filmBox: film.filmBox, metaSOPClassUID: meta)
                if allowedSize != true && !(allowedSize == nil && film.imageBoxes[index].forceRequestedImageSize) {
                    film.imageBoxes[index].requestedImageSize = nil
                }
                if peerConfiguration?.configuration(for: meta)?.string(for: 0x2020_00A2)?.hasPrefix("DEF ") != true {
                    film.imageBoxes[index].requestedDecimateCropBehavior = nil
                }
            }
            var description = try DicomFilmDescription(film: film)
            description.outputWidth = outputWidth
            description.printerPixelSpacing = try printConfiguredPixelSpacing(film.filmBox, meta: meta, configuration: peerConfiguration)
            description.color = mode == .color
            description.presentationLUT = job.presentationLUT
            description.annotationRows = film.filmBox.annotationDisplayFormatID.flatMap { annotationFormats[$0] } ?? 0
            description.printerDefinedGrid = printerDefinedGrids[description.displayFormat.wireValue]
            description.identify = identify
            return try DicomFilmCompositor(textRasterizer: textRasterizer).compose(description)
        }
    }
}

func printConfiguredPixelSpacing(_ film: DicomFilmBox, meta: String,
                                 configuration: DicomPrinterConfiguration?) throws -> (row: Double, column: Double)? {
    guard let printer = configuration?.configuration(for: meta) else { return nil }
    let resolution = film.requestedResolutionID ?? printer.string(for: 0x2010_0054)
    guard let item = printer.sequenceItems(for: 0x2000_00A8).map(\.dataSet).first(where: {
        $0.string(for: 0x2010_0010) == film.imageDisplayFormat
            && $0.string(for: 0x2010_0040) == film.orientation.rawValue
            && $0.string(for: 0x2010_0050) == film.filmSizeID
            && (resolution == nil || $0.string(for: 0x2010_0052) == resolution)
    }), let value = item.string(for: 0x2010_0376) else { return nil }
    let values = value.split(separator: "\\").compactMap { Double($0) }
    guard values.count == 2, values.allSatisfy({ $0.isFinite && $0 > 0 }) else {
        throw DicomFilmCompositionError.invalidParameter("Configured Printer Pixel Spacing")
    }
    return (values[0], values[1])
}
