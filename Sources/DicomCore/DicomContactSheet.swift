import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Contact sheet of decoded frames: each tile is the exporter's 8-bit display rendering, scaled to
/// fit a square cell; inputs that fail to decode are listed in `skipped` instead of aborting.
public enum DicomContactSheet {
    public struct Result: Equatable, Sendable {
        public let png: Data
        public let tiles: Int
        public let columns: Int
        public let rows: Int
        public let skipped: [String]
    }
    public enum Failure: Error, Equatable, LocalizedError, Sendable {
        case noTiles
        case renderFailed
        public var errorDescription: String? {
            switch self {
            case .noTiles: return "No frame could be rendered"
            case .renderFailed: return "Contact sheet rendering failed"
            }
        }
    }

    public static func render(inputs: [URL], columns: Int, cellSize: Int, maxFramesPerInput: Int) throws -> Result {
        guard columns > 0 else { throw Failure.renderFailed }
        var images: [CGImage] = []
        var skipped: [String] = []
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("contact-sheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        for input in inputs {
            do {
                let decoder = try DCMDecoder(contentsOf: input)
                let frames = min(max(1, decoder.pixelDataDescriptor?.numberOfFrames ?? 1), maxFramesPerInput)
                for frame in 0..<frames {
                    let target = scratch.appendingPathComponent("\(images.count).png")
                    _ = try DicomImageExporter().export(decoder: decoder, frame: frame, to: target, options: .init(format: .png, overwrite: true))
                    guard let source = CGImageSourceCreateWithURL(target as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw Failure.renderFailed
                    }
                    images.append(image)
                }
            } catch {
                skipped.append("\(input.lastPathComponent): \(error)")
            }
        }
        guard !images.isEmpty else { throw Failure.noTiles }
        let rows = (images.count + columns - 1) / columns
        let width = columns * cellSize, height = rows * cellSize
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw Failure.renderFailed }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        for (index, image) in images.enumerated() {
            let column = index % columns, row = index / columns
            let scale = min(Double(cellSize) / Double(image.width), Double(cellSize) / Double(image.height))
            let drawWidth = Double(image.width) * scale, drawHeight = Double(image.height) * scale
            let x = Double(column * cellSize) + (Double(cellSize) - drawWidth) / 2
            let y = Double(height) - Double((row + 1) * cellSize) + (Double(cellSize) - drawHeight) / 2
            context.draw(image, in: CGRect(x: x, y: y, width: drawWidth, height: drawHeight))
        }
        guard let sheet = context.makeImage() else { throw Failure.renderFailed }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw Failure.renderFailed }
        CGImageDestinationAddImage(destination, sheet, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.renderFailed }
        return Result(png: output as Data, tiles: images.count, columns: columns, rows: rows, skipped: skipped)
    }
}
