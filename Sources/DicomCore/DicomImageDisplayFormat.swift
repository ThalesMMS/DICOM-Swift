//
//  DicomImageDisplayFormat.swift
//  DicomCore
//
//  `Image Display Format` (2010,0010) as a value (issue #1907).
//
//  PS3.3 C.13.3 defines six families, and only one of them is a uniform
//  grid. A `ROW\1,3,2` film is one image on the first row, three on the
//  second and two on the third — it is not a 3×3 with holes, and coercing it
//  into a grid puts images in the wrong boxes. This type models each family
//  as it is, parses the wire value strictly (exact segment counts, no token
//  silently dropped, no trailing junk accepted), and serializes back to the
//  canonical wire form.
//
//  The parser is deliberately separate from any presentation fallback:
//  refusing a value is this type's job; deciding what to show instead is the
//  caller's.
//

import Foundation

/// Why a wire value was refused.
public enum DicomImageDisplayFormatError: Error, Equatable, LocalizedError, Sendable {
    case emptyValue
    case unknownFamily(String)
    /// The family has a different number of `\`-separated segments than the
    /// standard defines — extra segments are junk, not extension points.
    case invalidSegmentCount(family: String, expected: Int, found: Int)
    /// A numeric token was empty or not a positive integer. `ROW\1,x,2` is
    /// refused whole, never quietly read as `ROW\1,2`.
    case invalidToken(String)
    case nonPositiveDimension(Int)
    /// A dimension, band count, or the total image box count is beyond what a
    /// film can plausibly hold; also raised when the arithmetic would
    /// overflow. The caps are documented on `maximumDimension` /
    /// `maximumImageBoxCount`.
    case excessiveCapacity
    case emptyCustomIdentifier

    public var errorDescription: String? {
        switch self {
        case .emptyValue:
            return "Image Display Format is empty."
        case .unknownFamily(let family):
            return "Unknown Image Display Format family \"\(family)\"."
        case .invalidSegmentCount(let family, let expected, let found):
            return "\(family) takes \(expected) backslash-separated segment(s), found \(found)."
        case .invalidToken(let token):
            return "\"\(token)\" is not a positive integer."
        case .nonPositiveDimension(let value):
            return "Image Display Format dimensions must be positive, got \(value)."
        case .excessiveCapacity:
            return "The Image Display Format asks for more image boxes than a film can hold."
        case .emptyCustomIdentifier:
            return "CUSTOM requires a non-empty format identifier."
        }
    }
}

/// A strictly parsed, round-trip-safe `Image Display Format` (2010,0010).
public enum DicomImageDisplayFormat: Equatable, Hashable, Sendable {
    /// `STANDARD\columns,rows` — a uniform grid.
    case standard(columns: Int, rows: Int)
    /// `ROW\c1,c2,…` — horizontal bands, top to bottom, `cN` images in
    /// band N. Non-uniform by design: there is no equivalent grid.
    case row(imagesPerRow: [Int])
    /// `COL\r1,r2,…` — vertical bands, left to right, `rN` images in band N.
    case col(imagesPerColumn: [Int])
    /// `SLIDE` — slide-format film; the printer defines the slot count.
    case slide
    /// `SUPERSLIDE` — superslide-format film; printer-defined slot count.
    case superslide
    /// `CUSTOM\id` — a printer-specific format named by its conformance
    /// statement; opaque to the SCU.
    case custom(identifier: String)

    /// The largest accepted value for a grid dimension or one band.
    public static let maximumDimension = 100
    /// The largest accepted total image box count for the computable
    /// families. Far above any real film, low enough that no downstream
    /// multiplication of the count can overflow.
    public static let maximumImageBoxCount = 10_000

    // MARK: - Strict parsing

    /// Parses a wire value strictly. Every refusal is a thrown
    /// ``DicomImageDisplayFormatError`` naming what was wrong — nothing is
    /// coerced, dropped, or defaulted.
    public init(wireValue: String) throws {
        // DICOM string values may carry even-length padding; interior
        // structure is untouched.
        let trimmed = wireValue.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false else {
            throw DicomImageDisplayFormatError.emptyValue
        }

        let segments = trimmed.components(separatedBy: "\\")
        let family = segments[0]

        switch family {
        case "STANDARD":
            guard segments.count == 2 else {
                throw DicomImageDisplayFormatError.invalidSegmentCount(
                    family: family, expected: 2, found: segments.count)
            }
            let dimensions = try Self.positiveIntegers(from: segments[1])
            guard dimensions.count == 2 else {
                throw DicomImageDisplayFormatError.invalidToken(segments[1])
            }
            self = try Self.validatedStandard(columns: dimensions[0], rows: dimensions[1])
        case "ROW":
            guard segments.count == 2 else {
                throw DicomImageDisplayFormatError.invalidSegmentCount(
                    family: family, expected: 2, found: segments.count)
            }
            self = try Self.validatedBands(.row, counts: try Self.positiveIntegers(from: segments[1]))
        case "COL":
            guard segments.count == 2 else {
                throw DicomImageDisplayFormatError.invalidSegmentCount(
                    family: family, expected: 2, found: segments.count)
            }
            self = try Self.validatedBands(.col, counts: try Self.positiveIntegers(from: segments[1]))
        case "SLIDE", "SUPERSLIDE":
            // `SLIDE\junk` is junk, not SLIDE.
            guard segments.count == 1 else {
                throw DicomImageDisplayFormatError.invalidSegmentCount(
                    family: family, expected: 1, found: segments.count)
            }
            self = family == "SLIDE" ? .slide : .superslide
        case "CUSTOM":
            guard segments.count == 2 else {
                throw DicomImageDisplayFormatError.invalidSegmentCount(
                    family: family, expected: 2, found: segments.count)
            }
            let identifier = segments[1].trimmingCharacters(in: .whitespaces)
            guard identifier.isEmpty == false else {
                throw DicomImageDisplayFormatError.emptyCustomIdentifier
            }
            self = .custom(identifier: identifier)
        default:
            throw DicomImageDisplayFormatError.unknownFamily(family)
        }
    }

    /// A validated uniform grid.
    public static func validatedStandard(columns: Int, rows: Int) throws -> DicomImageDisplayFormat {
        for value in [columns, rows] {
            guard value > 0 else { throw DicomImageDisplayFormatError.nonPositiveDimension(value) }
            guard value <= maximumDimension else { throw DicomImageDisplayFormatError.excessiveCapacity }
        }
        let (capacity, overflow) = columns.multipliedReportingOverflow(by: rows)
        guard overflow == false, capacity <= maximumImageBoxCount else {
            throw DicomImageDisplayFormatError.excessiveCapacity
        }
        return .standard(columns: columns, rows: rows)
    }

    /// A validated set of horizontal bands.
    public static func validatedRow(imagesPerRow: [Int]) throws -> DicomImageDisplayFormat {
        try validatedBands(.row, counts: imagesPerRow)
    }

    /// A validated set of vertical bands.
    public static func validatedCol(imagesPerColumn: [Int]) throws -> DicomImageDisplayFormat {
        try validatedBands(.col, counts: imagesPerColumn)
    }

    private enum BandAxis { case row, col }

    private static func validatedBands(_ axis: BandAxis, counts: [Int]) throws -> DicomImageDisplayFormat {
        guard counts.isEmpty == false else {
            throw DicomImageDisplayFormatError.invalidToken("")
        }
        guard counts.count <= maximumDimension else {
            throw DicomImageDisplayFormatError.excessiveCapacity
        }
        var total = 0
        for count in counts {
            guard count > 0 else { throw DicomImageDisplayFormatError.nonPositiveDimension(count) }
            guard count <= maximumDimension else { throw DicomImageDisplayFormatError.excessiveCapacity }
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard overflow == false, sum <= maximumImageBoxCount else {
                throw DicomImageDisplayFormatError.excessiveCapacity
            }
            total = sum
        }
        switch axis {
        case .row: return .row(imagesPerRow: counts)
        case .col: return .col(imagesPerColumn: counts)
        }
    }

    /// Every comma-separated token as a positive integer — a token that is
    /// empty or non-numeric refuses the whole value.
    private static func positiveIntegers(from segment: String) throws -> [Int] {
        try segment.components(separatedBy: ",").map { token in
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard trimmed.isEmpty == false, let value = Int(trimmed) else {
                throw DicomImageDisplayFormatError.invalidToken(token)
            }
            return value
        }
    }

    // MARK: - Wire form and capacity

    /// The canonical (2010,0010) value.
    public var wireValue: String {
        switch self {
        case let .standard(columns, rows):
            return "STANDARD\\\(columns),\(rows)"
        case let .row(imagesPerRow):
            return "ROW\\\(imagesPerRow.map(String.init).joined(separator: ","))"
        case let .col(imagesPerColumn):
            return "COL\\\(imagesPerColumn.map(String.init).joined(separator: ","))"
        case .slide:
            return "SLIDE"
        case .superslide:
            return "SUPERSLIDE"
        case let .custom(identifier):
            return "CUSTOM\\\(identifier)"
        }
    }

    /// How many image boxes the format defines, or `nil` for the families
    /// whose slot count only the printer knows (`SLIDE`, `SUPERSLIDE`,
    /// `CUSTOM`). The arithmetic is checked: a value built directly from
    /// case syntax with dimensions the parser would refuse also answers
    /// `nil` rather than trapping.
    public var imageBoxCapacity: Int? {
        switch self {
        case let .standard(columns, rows):
            guard columns > 0, rows > 0 else { return nil }
            let (capacity, overflow) = columns.multipliedReportingOverflow(by: rows)
            return overflow ? nil : capacity
        case let .row(imagesPerRow):
            return Self.checkedSum(of: imagesPerRow)
        case let .col(imagesPerColumn):
            return Self.checkedSum(of: imagesPerColumn)
        case .slide, .superslide, .custom:
            return nil
        }
    }

    private static func checkedSum(of counts: [Int]) -> Int? {
        guard counts.isEmpty == false else { return nil }
        var total = 0
        for count in counts {
            guard count > 0 else { return nil }
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard overflow == false else { return nil }
            total = sum
        }
        return total
    }
}
