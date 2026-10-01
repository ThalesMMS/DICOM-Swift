import CoreGraphics
import Foundation
import ImageIO

enum DicomWebRenderedFrameEncoder {
    static func encode(
        _ bitmap: DicomRenderedBitmap,
        mediaType: String,
        quality: Double,
        maximumBytes: Int
    ) throws -> Data {
        guard bitmap.width > 0, bitmap.height > 0,
              let provider = CGDataProvider(data: bitmap.rgbData as CFData),
              let image = CGImage(
                width: bitmap.width,
                height: bitmap.height,
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                bytesPerRow: bitmap.width * 3,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw DicomWebFrameRouteError.renderingFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            contentTypeIdentifier(for: mediaType),
            1,
            nil
        ) else {
            throw DicomWebFrameRouteError.renderingFailed
        }
        let properties: CFDictionary = mediaType == "image/jpeg"
            ? [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
            : [:] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination), output.length <= maximumBytes else {
            if output.length > maximumBytes {
                throw DicomWebFrameRouteError.responseTooLarge
            }
            throw DicomWebFrameRouteError.renderingFailed
        }
        return output as Data
    }

    private static func contentTypeIdentifier(for mediaType: String) -> CFString {
        switch mediaType {
        case "image/png":
            return "public.png" as CFString
        case "image/gif":
            return "com.compuserve.gif" as CFString
        default:
            return "public.jpeg" as CFString
        }
    }
}
