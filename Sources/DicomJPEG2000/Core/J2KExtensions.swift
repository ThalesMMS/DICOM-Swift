//
// J2KExtensions.swift
// J2KSwift
//
/// # J2KExtensions
///
/// Useful extensions for working with JPEG 2000 data.
///
/// This file provides convenient extensions to standard library types
/// to make working with JPEG 2000 images and data easier.

import Foundation

// MARK: - Data Extensions

extension Data {
    /// Reads a big-endian UInt16 from the data at the specified offset.
    ///
    /// - Parameter offset: The byte offset to read from.
    /// - Returns: The UInt16 value, or nil if there is insufficient data.
    public func readBigEndianUInt16(at offset: Int) -> UInt16? {
        guard offset + 2 <= count else { return nil }
        return self.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            return UInt16(ptr[offset]) << 8 | UInt16(ptr[offset + 1])
        }
    }

    /// Reads a big-endian UInt32 from the data at the specified offset.
    ///
    /// - Parameter offset: The byte offset to read from.
    /// - Returns: The UInt32 value, or nil if there is insufficient data.
    public func readBigEndianUInt32(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        return self.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)
            return UInt32(ptr[offset]) << 24 |
                   UInt32(ptr[offset + 1]) << 16 |
                   UInt32(ptr[offset + 2]) << 8 |
                   UInt32(ptr[offset + 3])
        }
    }

    /// Appends a big-endian UInt16 to the data.
    ///
    /// - Parameter value: The value to append.
    public mutating func appendBigEndianUInt16(_ value: UInt16) {
        self.append(UInt8(value >> 8))
        self.append(UInt8(value & 0xFF))
    }

    /// Appends a big-endian UInt32 to the data.
    ///
    /// - Parameter value: The value to append.
    public mutating func appendBigEndianUInt32(_ value: UInt32) {
        self.append(UInt8(value >> 24))
        self.append(UInt8((value >> 16) & 0xFF))
        self.append(UInt8((value >> 8) & 0xFF))
        self.append(UInt8(value & 0xFF))
    }
}

// MARK: - Array Extensions for Signal Processing

extension Array where Element == Int {
    /// Calculates the mean (average) of the array elements.
    ///
    /// - Returns: The mean value, or 0 if the array is empty.
    public var mean: Double {
        guard !isEmpty else { return 0 }
        let sum = self.reduce(0, +)
        return Double(sum) / Double(count)
    }

    /// Calculates the variance of the array elements.
    ///
    /// - Returns: The variance value.
    public var variance: Double {
        guard !isEmpty else { return 0 }
        let m = mean
        let squaredDiffs = self.map { Double($0) - m }.map { $0 * $0 }
        return squaredDiffs.reduce(0, +) / Double(count)
    }

    /// Calculates the standard deviation of the array elements.
    ///
    /// - Returns: The standard deviation value.
    public var standardDeviation: Double {
        variance.squareRoot()
    }
}

extension Array where Element == Double {
    /// Calculates the mean (average) of the array elements.
    ///
    /// - Returns: The mean value, or 0 if the array is empty.
    public var mean: Double {
        guard !isEmpty else { return 0 }
        return self.reduce(0, +) / Double(count)
    }

    /// Calculates the variance of the array elements.
    ///
    /// - Returns: The variance value.
    public var variance: Double {
        guard !isEmpty else { return 0 }
        let m = mean
        let squaredDiffs = self.map { $0 - m }.map { $0 * $0 }
        return squaredDiffs.reduce(0, +) / Double(count)
    }

    /// Calculates the standard deviation of the array elements.
    ///
    /// - Returns: The standard deviation value.
    public var standardDeviation: Double {
        variance.squareRoot()
    }

    /// Normalizes the array values to the range [0, 1].
    ///
    /// - Returns: A new array with normalised values.
    public func normalized() -> [Double] {
        guard !isEmpty else { return [] }
        guard let minVal = self.min(), let maxVal = self.max() else { return self }
        let range = maxVal - minVal
        guard range > 0 else { return self.map { _ in 0.5 } }
        return self.map { ($0 - minVal) / range }
    }
}
