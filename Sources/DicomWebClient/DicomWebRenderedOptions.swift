import Foundation

/// The query parameters and `Accept` of a WADO-RS rendered or thumbnail request (PS3.18 8.3.5.1).
public struct DicomWebRenderedOptions: Equatable, Sendable {
    /// The VOI LUT function named in the `window` parameter.
    public enum WindowFunction: String, Equatable, Sendable {
        case linear
        case linearExact = "linear-exact"
        case sigmoid
    }

    /// A window center and width with the function that applies them.
    public struct Window: Equatable, Sendable {
        public var center: Double
        public var width: Double
        public var function: WindowFunction

        public init(center: Double, width: Double, function: WindowFunction = .linear) {
            self.center = center
            self.width = width
            self.function = function
        }
    }

    /// The width and height, in pixels, of the rendered image.
    public struct Viewport: Equatable, Sendable {
        public var width: Int
        public var height: Int

        public init(width: Int, height: Int) {
            self.width = width
            self.height = height
        }
    }

    public var window: Window?
    public var viewport: Viewport?
    /// Lossy image quality, from 1 to 100.
    public var quality: Int?
    /// The `Accept` header. A multipart type such as `multipart/related; type="image/jpeg"` asks for one part per
    /// rendered frame; the answer may also be a single image.
    public var accept: String

    public init(window: Window? = nil, viewport: Viewport? = nil, quality: Int? = nil,
                accept: String = DicomWebMediaTypeNegotiator.acceptHeader(for: .rendered)) {
        self.window = window
        self.viewport = viewport
        self.quality = quality
        self.accept = accept
    }

    /// `window=center,width,function`, `viewport=width,height` and `quality=n`, in that order; absent ones are left out.
    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let window {
            items.append(.init(name: "window", value: "\(Self.decimal(window.center)),\(Self.decimal(window.width)),"
                + window.function.rawValue))
        }
        if let viewport { items.append(.init(name: "viewport", value: "\(viewport.width),\(viewport.height)")) }
        if let quality { items.append(.init(name: "quality", value: String(quality))) }
        return items
    }

    /// Whether every present value is one a server can accept: a finite center, a positive width and viewport, and a
    /// quality from 1 to 100.
    var isValid: Bool {
        if let window, !window.center.isFinite || !window.width.isFinite || window.width <= 0 { return false }
        if let viewport, viewport.width <= 0 || viewport.height <= 0 { return false }
        if let quality, !(1...100).contains(quality) { return false }
        return true
    }

    /// A decimal string without a trailing `.0` for whole values, so `40` is written `40`.
    private static func decimal(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }
}
