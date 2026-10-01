import CryptoKit
import Foundation

public enum DicomFilmCompositionError: Error, Equatable, Sendable {
    case invalidParameter(String)
    case resourceLimit
    case imageDoesNotFit(position: Int)
    case textRasterizationFailed
}

public struct DicomComposedFilmInfo: Equatable, Sendable {
    public enum Fit: String, Equatable, Sendable {
        case none, demagnified, cropped, decimated
        public var warningStatus: UInt16? {
            switch self {
            case .none: nil
            case .demagnified: 0xB604
            case .cropped: 0xB609
            case .decimated: 0xB60A
            }
        }
    }
    public var fitByPosition: [Int: Fit] = [:]
    public var smoothingType: String?
    public var identificationByPosition: [Int: String] = [:]
    public var filmIdentification: String?
    public var physicalWidthMillimeters: Double = 0
    public var physicalHeightMillimeters: Double = 0
}

public struct DicomComposedFilm: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let samplesPerPixel: Int
    public let pixelData: Data
    public let slotRectangles: [DicomFilmRectangle]
    public let info: DicomComposedFilmInfo
    /// SHA-256 of row-major, interleaved, 8-bit raster bytes.
    public var fingerprint: String {
        SHA256.hash(data: pixelData).map { String(format: "%02x", $0) }.joined()
    }
}

/// Shared inputs for CPU composition. Pixel spacing follows DICOM row/column order.
/// Position-indexed overrides are separate from the A1 wire models.
public struct DicomFilmDescription: Sendable {
    public var film: DicomFilm
    public var displayFormat: DicomImageDisplayFormat
    public var outputWidth: Int = 1024
    public var printerPixelSpacing: (row: Double, column: Double)?
    public var imagePixelSpacing: [Int: (row: Double, column: Double)] = [:]
    public var printerDefinedGrid: DicomImageDisplayFormat?
    public var color = false
    public var presentationLUT: DicomPresentationLUT?
    public var imagePresentationLUTs: [Int: DicomPresentationLUT] = [:]
    /// Optional unsigned native grayscale samples, preserving 12-bit LUT indices.
    public var nativeGrayscaleSamples: [Int: [UInt16]] = [:]
    public var nativeBitsStored: [Int: Int] = [:]
    public var imageDensityRanges: [Int: (minimum: UInt16, maximum: UInt16)] = [:]
    public var minimumDensity: UInt16 = 20
    public var maximumDensity: UInt16 = 300
    public var smoothingType: String?
    public var annotationRows: Int = 0
    public var textBandHeight: Int = 24
    public var identify = false
    public var maximumOutputBytes: Int = 64 * 1024 * 1024

    public init(film: DicomFilm) throws {
        self.film = film
        if let updates = film.filmBox.updates {
            if let value = updates.string(for: 0x2010_0060) { self.film.filmBox.magnificationType = value }
            if let value = updates.string(for: 0x2010_0100) { self.film.filmBox.borderDensity = value }
            if let value = updates.string(for: 0x2010_0110) { self.film.filmBox.emptyImageDensity = value }
            if let value = updates.string(for: 0x2010_0140) { self.film.filmBox.trim = value == "YES" }
            if let value = updates.int(for: 0x2010_015E), (0...65535).contains(value) { self.film.filmBox.illumination = UInt16(value) }
            if let value = updates.int(for: 0x2010_0160), (0...65535).contains(value) { self.film.filmBox.reflectedAmbientLight = UInt16(value) }
        }
        displayFormat = try DicomImageDisplayFormat(wireValue: film.filmBox.imageDisplayFormat)
        if let minimum = film.filmBox.updates?.int(for: 0x2010_0120), (0...65535).contains(minimum) {
            minimumDensity = UInt16(minimum)
        }
        if let maximum = film.filmBox.updates?.int(for: 0x2010_0130), (0...65535).contains(maximum) {
            maximumDensity = UInt16(maximum)
        }
        smoothingType = film.filmBox.updates?.string(for: 0x2010_0080)
        for image in film.imageBoxes {
            let components = image.originalImage?.string(for: .pixelSpacing)?
                .split(separator: "\\").compactMap { Double($0) } ?? []
            if components.count == 2 {
                imagePixelSpacing[image.position] = (components[0], components[1])
            }
        }
    }
}

public struct DicomFilmCompositor: Sendable {
    public let textRasterizer: any DicomPrintTextRasterizing

    public init(textRasterizer: any DicomPrintTextRasterizing = DicomCoreTextPrintRasterizer()) {
        self.textRasterizer = textRasterizer
    }

    public func compose(_ description: DicomFilmDescription) throws -> DicomComposedFilm {
        let film = description.film
        let box = film.filmBox
        let physical = try DicomPhysicalFilmSize(filmSizeID: box.filmSizeID)
        let landscape = box.orientation == .landscape
        let physicalWidth = landscape ? physical.heightMillimeters : physical.widthMillimeters
        let physicalHeight = landscape ? physical.widthMillimeters : physical.heightMillimeters
        guard description.maximumOutputBytes > 0, description.minimumDensity < description.maximumDensity,
              description.annotationRows >= 0, description.annotationRows <= 100,
              description.textBandHeight > 0, description.textBandHeight <= 4096 else {
            throw DicomFilmCompositionError.invalidParameter("density, annotation geometry or output limit")
        }
        let widthValue: Double
        let heightValue: Double
        if let spacing = description.printerPixelSpacing {
            guard spacing.row.isFinite, spacing.column.isFinite, spacing.row > 0, spacing.column > 0 else {
                throw DicomFilmCompositionError.invalidParameter("Printer Pixel Spacing")
            }
            widthValue = physicalWidth / spacing.column
            heightValue = physicalHeight / spacing.row
        } else {
            widthValue = Double(description.outputWidth)
            heightValue = widthValue * physicalHeight / physicalWidth
        }
        let channels = description.color ? 3 : 1
        guard widthValue.isFinite, heightValue.isFinite, widthValue >= 1, heightValue >= 1,
              widthValue < Double(Int.max), heightValue < Double(Int.max),
              widthValue <= Double(description.maximumOutputBytes),
              heightValue <= Double(description.maximumOutputBytes) else {
            throw DicomFilmCompositionError.resourceLimit
        }
        let width = Int(widthValue.rounded())
        let height = Int(heightValue.rounded())
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixels.multipliedReportingOverflow(by: channels)
        guard !overflow, !byteOverflow, byteCount <= description.maximumOutputBytes else {
            throw DicomFilmCompositionError.resourceLimit
        }
        let magnification = box.magnificationType ?? "REPLICATE"
        guard ["REPLICATE", "BILINEAR", "CUBIC", "NONE"].contains(magnification) else {
            throw DicomFilmCompositionError.invalidParameter("Magnification Type")
        }
        let illumination = Double(box.illumination ?? 2000)
        let ambient = Double(box.reflectedAmbientLight ?? 10)
        let darkestLuminance = ambient + illumination * pow(10, -Double(description.maximumDensity) / 100)
        let brightestLuminance = ambient + illumination * pow(10, -Double(description.minimumDensity) / 100)
        guard darkestLuminance >= 0.05, brightestLuminance <= 4000, brightestLuminance > darkestLuminance else {
            throw DicomFilmCompositionError.invalidParameter("GSDF luminance range")
        }
        let darkestJND = Self.jndIndex(luminance: darkestLuminance)
        let brightestJND = Self.jndIndex(luminance: brightestLuminance)
        func opticalDensityPValue(_ od: Double) -> Double {
            let luminance = min(brightestLuminance, max(darkestLuminance, ambient + illumination * pow(10, -od)))
            return (Self.jndIndex(luminance: luminance) - darkestJND) / (brightestJND - darkestJND)
        }
        var info = DicomComposedFilmInfo()
        info.physicalWidthMillimeters = physicalWidth
        info.physicalHeightMillimeters = physicalHeight
        info.smoothingType = description.smoothingType
        guard Set(film.imageBoxes.map(\.position)).count == film.imageBoxes.count else {
            throw DicomFilmCompositionError.invalidParameter("Duplicate image position")
        }
        if description.identify {
            let identities = film.imageBoxes.map { image -> (Int, String?, String) in
                let source = image.originalImage
                let uid = source?.string(for: .studyInstanceUID)
                let text = [source?.string(for: .patientName), source?.string(for: .patientID), uid]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
                return (image.position, uid, text)
            }
            guard identities.allSatisfy({ !$0.2.isEmpty }) else {
                throw DicomFilmCompositionError.invalidParameter("Missing image identification")
            }
            if let first = identities.first, let uid = first.1, !uid.isEmpty,
               identities.allSatisfy({ $0.1 == uid && $0.2 == first.2 }) {
                info.filmIdentification = first.2
            } else {
                info.identificationByPosition = Dictionary(uniqueKeysWithValues: identities.map { ($0.0, $0.2) })
            }
        }
        let bands = description.annotationRows + (info.filmIdentification == nil ? 0 : 1)
        let bandPixels = bands * description.textBandHeight
        let margin = box.trim ? 1 : 0
        guard width > margin * 2, height > bandPixels + margin * 2 else {
            throw DicomFilmCompositionError.invalidParameter("Text bands exceed film")
        }
        let slots = try DicomFilmGeometry.slots(format: description.displayFormat,
            bounds: .init(x: margin, y: margin, width: width - margin * 2,
                          height: height - bandPixels - margin * 2),
            printerDefinedGrid: description.printerDefinedGrid)
        guard Set(film.imageBoxes.map(\.position)).count == film.imageBoxes.count,
              film.imageBoxes.allSatisfy({ $0.position > 0 && $0.position <= slots.count }),
              Set(film.annotations.map(\.position)).count == film.annotations.count,
              film.annotations.allSatisfy({ $0.position > 0 && $0.position <= description.annotationRows }) else {
            throw DicomFilmCompositionError.invalidParameter("Image or annotation position")
        }
        func density(_ value: String?) throws -> UInt8 {
            if value == nil || value == "BLACK" { return 0 }
            if value == "WHITE" { return 255 }
            guard let od = value.flatMap(Double.init), od.isFinite, od >= 0 else {
                throw DicomFilmCompositionError.invalidParameter("Density")
            }
            return UInt8((min(1, max(0, opticalDensityPValue(od / 100))) * 255).rounded())
        }
        let border = try density(box.borderDensity)
        let empty = try density(box.emptyImageDensity)
        var raster = [UInt8](repeating: border, count: byteCount)
        func fill(_ rect: DicomFilmRectangle, _ value: UInt8) {
            for y in rect.y..<(rect.y + rect.height) {
                for x in rect.x..<(rect.x + rect.width) {
                    for channel in 0..<channels { raster[(y * width + x) * channels + channel] = value }
                }
            }
        }
        for slot in slots { fill(slot, empty) }
        if box.trim {
            for x in 0..<width {
                for c in 0..<channels { raster[x * channels + c] = 255; raster[((height - 1) * width + x) * channels + c] = 255 }
            }
            for y in 0..<height {
                for c in 0..<channels { raster[y * width * channels + c] = 255; raster[(y * width + width - 1) * channels + c] = 255 }
            }
        }
        func text(_ string: String, in rect: DicomFilmRectangle) throws {
            let mask = try textRasterizer.rasterize(string, width: rect.width, height: rect.height)
            guard mask.count == rect.width * rect.height, mask.contains(where: { $0 != 0 }) else {
                throw DicomFilmCompositionError.textRasterizationFailed
            }
            fill(rect, 0)
            for y in 0..<rect.height {
                for x in 0..<rect.width {
                    for c in 0..<channels { raster[((rect.y + y) * width + rect.x + x) * channels + c] = mask[y * rect.width + x] }
                }
            }
        }
        for image in film.imageBoxes {
            var slot = slots[image.position - 1]
            if let label = info.identificationByPosition[image.position] {
                guard slot.height > description.textBandHeight else {
                    throw DicomFilmCompositionError.invalidParameter("Image identification band")
                }
                try text(label, in: .init(x: slot.x, y: slot.y + slot.height - description.textBandHeight,
                                          width: slot.width, height: description.textBandHeight))
                slot = .init(x: slot.x, y: slot.y, width: slot.width, height: slot.height - description.textBandHeight)
            }
            let bitmap = image.bitmap
            if let lut = description.imagePresentationLUTs[image.position] ?? description.presentationLUT,
               !lut.values.isEmpty, lut.values.count != (1 << (description.nativeBitsStored[image.position] ?? 8)) {
                throw DicomFilmCompositionError.invalidParameter("Presentation LUT length does not match Bits Stored")
            }
            let spacing = description.imagePixelSpacing[image.position]
            if let spacing {
                guard spacing.row.isFinite, spacing.column.isFinite, spacing.row > 0, spacing.column > 0 else {
                    throw DicomFilmCompositionError.invalidParameter("Image Pixel Spacing")
                }
            }
            let aspect = Double(bitmap.height) / Double(bitmap.width) * ((spacing?.row ?? 1) / (spacing?.column ?? 1))
            let printerAspect = (description.printerPixelSpacing?.column ?? 1) / (description.printerPixelSpacing?.row ?? 1)
            var targetWidth = Double(bitmap.width)
            var targetHeight = targetWidth * aspect * printerAspect
            if let size = image.requestedImageSize {
                guard size.isFinite, size > 0 else { throw DicomFilmCompositionError.invalidParameter("Requested Image Size") }
                targetWidth = size / (description.printerPixelSpacing?.column ?? (physicalWidth / Double(width)))
                targetHeight = targetWidth * aspect * printerAspect
            } else if magnification != "NONE" {
                let scale = min(Double(slot.width) / targetWidth, Double(slot.height) / targetHeight)
                // Oversize input is handled below, retaining its fit warning.
                if scale >= 1 { targetWidth *= scale; targetHeight *= scale }
            }
            var fit = DicomComposedFilmInfo.Fit.none
            if targetWidth > Double(slot.width) || targetHeight > Double(slot.height) {
                switch image.requestedDecimateCropBehavior {
                case .fail: throw DicomFilmCompositionError.imageDoesNotFit(position: image.position)
                case .crop: fit = .cropped
                case .decimate:
                    guard magnification != "NONE" else { throw DicomFilmCompositionError.imageDoesNotFit(position: image.position) }
                    fit = .decimated
                case nil:
                    guard magnification != "NONE" else { throw DicomFilmCompositionError.imageDoesNotFit(position: image.position) }
                    fit = .demagnified
                }
                if fit != .cropped {
                    let scale = min(Double(slot.width) / targetWidth, Double(slot.height) / targetHeight)
                    targetWidth *= scale; targetHeight *= scale
                }
            }
            guard targetWidth.isFinite, targetHeight.isFinite, targetWidth >= 1, targetHeight >= 1 else {
                throw DicomFilmCompositionError.invalidParameter("Image scale")
            }
            info.fitByPosition[image.position] = fit
            let source = description.color ? bitmap.rgbData : DicomBitmapOperations.grayscaleData(fromRGB: bitmap.rgbData)
            let native = description.nativeGrayscaleSamples[image.position]
            let nativeBits = description.nativeBitsStored[image.position] ?? 8
            if let native {
                guard !description.color, [8, 12].contains(nativeBits), native.count == bitmap.width * bitmap.height,
                      native.allSatisfy({ $0 < (UInt16(1) << nativeBits) }) else {
                    throw DicomFilmCompositionError.invalidParameter("Native grayscale samples")
                }
            }
            let originX = Double(slot.x) + (Double(slot.width) - targetWidth) / 2
            let originY = Double(slot.y) + (Double(slot.height) - targetHeight) / 2
            let lut = description.imagePresentationLUTs[image.position] ?? description.presentationLUT
            let imageDensity = description.imageDensityRanges[image.position]
                ?? (description.minimumDensity, description.maximumDensity)
            guard imageDensity.minimum < imageDensity.maximum else {
                throw DicomFilmCompositionError.invalidParameter("Image density range")
            }
            let imageDarkJND = Self.jndIndex(luminance: ambient + illumination * pow(10, -Double(imageDensity.maximum) / 100))
            let imageBrightJND = Self.jndIndex(luminance: ambient + illumination * pow(10, -Double(imageDensity.minimum) / 100))
            func sample(_ x: Int, _ y: Int, _ c: Int) -> Double {
                let index = min(bitmap.height - 1, max(0, y)) * bitmap.width + min(bitmap.width - 1, max(0, x))
                if let native { return Double(native[index]) * 255 / Double((1 << nativeBits) - 1) }
                return Double(source[index * channels + c])
            }
            func cubic(_ distance: Double) -> Double {
                let t = abs(distance)
                if t <= 1 { return 1.5 * t * t * t - 2.5 * t * t + 1 }
                if t < 2 { return -0.5 * t * t * t + 2.5 * t * t - 4 * t + 2 }
                return 0
            }
            for y in slot.y..<(slot.y + slot.height) {
                for x in slot.x..<(slot.x + slot.width) {
                    guard Double(x) + 0.5 >= originX, Double(x) + 0.5 < originX + targetWidth,
                          Double(y) + 0.5 >= originY, Double(y) + 0.5 < originY + targetHeight else { continue }
                    let sx = (Double(x) + 0.5 - originX) / targetWidth * Double(bitmap.width) - 0.5
                    let sy = (Double(y) + 0.5 - originY) / targetHeight * Double(bitmap.height) - 0.5
                    let ix = Int(floor(sx)), iy = Int(floor(sy))
                    for c in 0..<channels {
                        var value: Double
                        if magnification == "BILINEAR" {
                            let dx = sx - Double(ix), dy = sy - Double(iy)
                            value = sample(ix, iy, c) * (1 - dx) * (1 - dy) + sample(ix + 1, iy, c) * dx * (1 - dy)
                                + sample(ix, iy + 1, c) * (1 - dx) * dy + sample(ix + 1, iy + 1, c) * dx * dy
                        } else if magnification == "CUBIC" {
                            value = 0
                            for j in -1...2 { for i in -1...2 {
                                value += sample(ix + i, iy + j, c) * cubic(sx - Double(ix + i)) * cubic(sy - Double(iy + j))
                            } }
                        } else { value = sample(Int(sx.rounded()), Int(sy.rounded()), c) }
                        value = min(255, max(0, value)) / 255
                        if let lut, !description.color {
                            if lut.shape == .linearOpticalDensity {
                                let minimum = Double(imageDensity.minimum) / 100
                                let maximum = Double(imageDensity.maximum) / 100
                                let luminance = ambient + illumination * pow(10, -(maximum - value * (maximum - minimum)))
                                value = (Self.jndIndex(luminance: luminance) - imageDarkJND) / (imageBrightJND - imageDarkJND)
                            } else if !lut.values.isEmpty {
                                let index = Int((value * Double(lut.values.count - 1)).rounded())
                                value = Double(lut.values[index]) / Double((UInt32(1) << lut.descriptor[2]) - 1)
                            }
                        }
                        if image.polarity == .reverse { value = 1 - value }
                        if !description.color {
                            value = (imageDarkJND + value * (imageBrightJND - imageDarkJND) - darkestJND) / (brightestJND - darkestJND)
                        }
                        raster[(y * width + x) * channels + c] = UInt8((min(1, max(0, value)) * 255).rounded())
                    }
                }
            }
        }
        let bandTop = height - margin - bandPixels
        for annotation in film.annotations {
            try text(annotation.text, in: .init(x: margin, y: bandTop + (annotation.position - 1) * description.textBandHeight,
                width: width - margin * 2, height: description.textBandHeight))
        }
        if let label = info.filmIdentification {
            try text(label, in: .init(x: margin, y: bandTop + description.annotationRows * description.textBandHeight,
                width: width - margin * 2, height: description.textBandHeight))
        }
        return .init(width: width, height: height, samplesPerPixel: channels, pixelData: Data(raster),
                     slotRectangles: slots, info: info)
    }

    /// PS3.14 equation 7-2, inverse GSDF over 0.05...4000 cd/m².
    /// https://dicom.nema.org/medical/dicom/current/output/chtml/part14/chapter_7.html
    static func jndIndex(luminance: Double) -> Double {
        let logarithm = log10(luminance)
        let coefficients = [71.498068, 94.593053, 41.912053, 9.8247004, 0.28175407,
                            -1.1878455, -0.18014349, 0.14710899, -0.017046845]
        return coefficients.reversed().reduce(0) { $0 * logarithm + $1 }
    }
}
