import Foundation

/// A strictly increasing list of one-based DICOM frame numbers.
public struct DicomWebFrameList: Equatable, Sendable {
    /// Validation failures for a frame-list path component.
    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case invalidNumber
        case notStrictlyIncreasing
        case limitExceeded
    }

    /// One-based frame numbers in request order.
    public let numbers: [Int]

    /// Creates a validated frame list.
    public init(_ numbers: [Int]) throws {
        guard !numbers.isEmpty else { throw ValidationError.empty }
        guard numbers.allSatisfy({ $0 > 0 }) else { throw ValidationError.invalidNumber }
        guard zip(numbers, numbers.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }) else {
            throw ValidationError.notStrictlyIncreasing
        }
        self.numbers = numbers
    }

    package init(pathComponent: String, maximumLength: Int, maximumCount: Int) throws {
        guard !pathComponent.isEmpty else { throw ValidationError.empty }
        guard pathComponent.utf8.count <= maximumLength else { throw ValidationError.limitExceeded }
        let fields = pathComponent.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count <= maximumCount else { throw ValidationError.limitExceeded }
        let numbers = try fields.map { field -> Int in
            guard !field.isEmpty,
                  field.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(field),
                  value > 0 else {
                throw ValidationError.invalidNumber
            }
            return value
        }
        try self.init(numbers)
    }

    var pathComponent: String {
        numbers.map(String.init).joined(separator: ",")
    }
}
