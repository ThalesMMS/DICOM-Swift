import Foundation

/// Integer pixel coordinates, with the origin at the upper left of the film.
public struct DicomFilmRectangle: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Physical film dimensions before applying Film Orientation.
public struct DicomPhysicalFilmSize: Equatable, Sendable {
    public let widthMillimeters: Double
    public let heightMillimeters: Double

    public init(filmSizeID: String) throws {
        let dimensions: (Double, Double)
        switch filmSizeID {
        case "8INX10IN": dimensions = (203.2, 254)
        case "8_5INX11IN": dimensions = (215.9, 279.4)
        case "10INX12IN": dimensions = (254, 304.8)
        case "10INX14IN": dimensions = (254, 355.6)
        case "11INX14IN": dimensions = (279.4, 355.6)
        case "11INX17IN": dimensions = (279.4, 431.8)
        case "14INX14IN": dimensions = (355.6, 355.6)
        case "14INX17IN": dimensions = (355.6, 431.8)
        case "24CMX24CM": dimensions = (240, 240)
        case "24CMX30CM": dimensions = (240, 300)
        case "A4": dimensions = (210, 297)
        case "A3": dimensions = (297, 420)
        default: throw DicomFilmGeometryError.unsupportedFilmSize(filmSizeID)
        }
        widthMillimeters = dimensions.0
        heightMillimeters = dimensions.1
    }
}

public enum DicomFilmGeometryError: Error, Equatable, Sendable {
    case unsupportedFilmSize(String)
    case invalidBounds
    case printerDefinedGeometryRequired
}

/// PS3.3 C.13.5.1 image position order. Printer-defined formats require an
/// explicit grid; no slot count is inferred from the number of supplied images.
public enum DicomFilmGeometry {
    public static func slots(format: DicomImageDisplayFormat, bounds: DicomFilmRectangle,
                             printerDefinedGrid: DicomImageDisplayFormat? = nil) throws -> [DicomFilmRectangle] {
        guard bounds.x >= 0, bounds.y >= 0, bounds.width > 0, bounds.height > 0,
              bounds.x <= Int.max - bounds.width, bounds.y <= Int.max - bounds.height else {
            throw DicomFilmGeometryError.invalidBounds
        }
        // Validate even values constructed directly using enum cases.
        let format = try DicomImageDisplayFormat(wireValue: format.wireValue)
        switch format {
        case .slide, .superslide, .custom:
            guard let grid = printerDefinedGrid, case .standard = grid else {
                throw DicomFilmGeometryError.printerDefinedGeometryRequired
            }
            return try slots(format: grid, bounds: bounds)
        default: break
        }
        func edge(_ extent: Int, _ index: Int, _ count: Int) -> Int {
            // Avoid extent * index overflow and share boundaries exactly.
            extent / count * index + extent % count * index / count
        }
        func rectangle(column: Int, row: Int, columns: Int, rows: Int) throws -> DicomFilmRectangle {
            guard bounds.width >= columns, bounds.height >= rows else {
                throw DicomFilmGeometryError.invalidBounds
            }
            let left = edge(bounds.width, column, columns)
            let top = edge(bounds.height, row, rows)
            return DicomFilmRectangle(x: bounds.x + left, y: bounds.y + top,
                width: edge(bounds.width, column + 1, columns) - left,
                height: edge(bounds.height, row + 1, rows) - top)
        }
        switch format {
        case let .standard(columns, rows):
            return try (0..<rows).flatMap { row in
                try (0..<columns).map { try rectangle(column: $0, row: row, columns: columns, rows: rows) }
            }
        case let .row(counts):
            return try counts.enumerated().flatMap { row, columns in
                try (0..<columns).map { try rectangle(column: $0, row: row, columns: columns, rows: counts.count) }
            }
        case let .col(counts):
            return try counts.enumerated().flatMap { column, rows in
                try (0..<rows).map { try rectangle(column: column, row: $0, columns: counts.count, rows: rows) }
            }
        case .slide, .superslide, .custom:
            throw DicomFilmGeometryError.printerDefinedGeometryRequired
        }
    }
}
