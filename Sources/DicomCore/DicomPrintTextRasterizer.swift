import CoreGraphics
import CoreText
import Foundation

public protocol DicomPrintTextRasterizing: Sendable {
    /// Returns an 8-bit coverage mask. Implementations must throw if the whole
    /// string cannot be represented; an empty or blank result is also rejected.
    func rasterize(_ text: String, width: Int, height: Int) throws -> Data
}

public struct DicomCoreTextPrintRasterizer: DicomPrintTextRasterizing {
    public init() {}

    public func rasterize(_ text: String, width: Int, height: Int) throws -> Data {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 2, height > 2, !overflow, count <= 64 * 1024 * 1024,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.contains("\n"), !text.contains("\r") else {
            throw DicomFilmCompositionError.textRasterizationFailed
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, Double(height) * 0.6, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let advance = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        guard advance > 0 else { throw DicomFilmCompositionError.textRasterizationFailed }
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            guard !glyphs.contains(0) else { throw DicomFilmCompositionError.textRasterizationFailed }
        }
        let scale = min(1, Double(width - 2) / advance)
        guard scale >= 0.25 else { throw DicomFilmCompositionError.textRasterizationFailed }
        var mask = Data(count: count)
        let rendered = mask.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.setShouldAntialias(true)
            context.textMatrix = .identity
            context.translateBy(x: 1, y: (Double(height) - Double(ascent + descent) * scale) / 2 + Double(descent) * scale)
            context.scaleBy(x: scale, y: scale)
            context.textPosition = .zero
            CTLineDraw(line, context)
            return true
        }
        guard rendered, mask.contains(where: { $0 != 0 }) else { throw DicomFilmCompositionError.textRasterizationFailed }
        // CoreGraphics bitmap coordinates are bottom-up; film coordinates are top-down.
        var topDown = Data(capacity: count)
        for row in (0..<height).reversed() { topDown.append(mask.subdata(in: row * width..<(row + 1) * width)) }
        return topDown
    }
}
