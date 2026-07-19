//
//  DCMBinaryReader.swift
//
//  Low-level binary I/O operations for DICOM file parsing.
//  This module handles reading primitive data types from DICOM
//  binary streams with proper endianness support.  All methods
//  advance the location cursor automatically through inout
//  parameters.
//
//  Usage:
//
//    var location = 0
//    let reader = DCMBinaryReader(data: dicomData, littleEndian: true)
//    let value = reader.readShort(&location)
//    // location is now advanced by 2 bytes
//

import Foundation

/// Binary reader for DICOM file data.
/// Handles low-level reading of primitive types (bytes, shorts, ints,
/// floats, doubles, strings) from DICOM binary streams.  All read
/// operations respect the configured endianness and automatically
/// advance the location cursor passed as an inout parameter.
///
/// This class is designed to be used by DCMDecoder and other DICOM
/// parsing components.  Each read method takes an inout location
/// parameter to track the current read position safely.
internal final class DCMBinaryReader {

    // MARK: - Properties

    /// Raw DICOM file contents
    private let data: Data

    /// Current byte order.  True for little endian (most common),
    /// false for big endian (rare).
    private let littleEndian: Bool

    // MARK: - Initialization

    /// Creates a binary reader for DICOM data.
    /// - Parameters:
    ///   - data: The DICOM file data to read from
    ///   - littleEndian: Byte order flag (true = little endian, false = big endian)
    internal init(data: Data, littleEndian: Bool) {
        self.data = data
        self.littleEndian = littleEndian
    }

    // MARK: - Reading Methods

    internal func readString(length: Int, location: inout Int) -> String {
        readString(length: length, location: &location, characterSet: .defaultCharacterSet)
    }

    /// Reads a DICOM text value and decodes it through the active Specific Character Set.
    internal func readString(length: Int,
                             location: inout Int,
                             characterSet: DicomSpecificCharacterSet) -> String {
        guard length > 0, location + length <= data.count else {
            location += length
            return ""
        }
        let slice = data[location..<location + length]
        location += length
        return characterSet.decode(Data(slice))
    }

    /// Reads a single byte from the current location and advances
    /// the cursor.
    internal func readByte(location: inout Int) -> UInt8 {
        guard location < data.count else { return 0 }
        let b = data[location]
        location += 1
        return b
    }

    /// Reads a 16‑bit unsigned integer respecting the current
    /// endianness and advances the cursor.
    internal func readShort(location: inout Int) -> UInt16 {
        guard location + 1 < data.count else { return 0 }
        let value = data.dicomInteger(at: location, as: UInt16.self, littleEndian: littleEndian)
        location += 2
        return value
    }

    /// Reads a 32‑bit signed integer respecting the current
    /// endianness and advances the cursor.
    internal func readInt(location: inout Int) -> Int {
        guard location + 3 < data.count else { return 0 }
        let value = data.dicomInteger(at: location, as: UInt32.self, littleEndian: littleEndian)
        location += 4
        return Int(value)
    }

    /// Reads a 64‑bit double precision floating point number.  The
    /// DICOM standard stores doubles as IEEE 754 values.  This
    /// implementation reconstructs the bit pattern into a UInt64
    /// then converts it to Double using Swift's bitPattern
    /// initializer.
    internal func readDouble(location: inout Int) -> Double {
        guard location + 7 < data.count else { return 0.0 }
        let bits = data.dicomInteger(at: location, as: UInt64.self, littleEndian: littleEndian)
        location += 8
        return Double(bitPattern: bits)
    }

    /// Reads a 32‑bit floating point number.  Similar to
    /// ``readDouble`` but producing a Float.  Because Swift's
    /// bitPattern initialisers require UInt32, we assemble the
    /// bytes accordingly then reinterpret the bits.
    internal func readFloat(location: inout Int) -> Float {
        guard location + 3 < data.count else { return 0.0 }
        let value = data.dicomInteger(at: location, as: UInt32.self, littleEndian: littleEndian)
        location += 4
        return Float(bitPattern: value)
    }

    /// Reads a lookup table stored as a sequence of 16‑bit values
    /// and converts them to 8‑bit entries by discarding the low
    /// eight bits.  Returns nil if the length is odd, in which
    /// case the cursor is advanced and the table is skipped.
    internal func readLUT(length: Int, location: inout Int) -> [UInt8]? {
        guard length % 2 == 0 else {
            // Skip odd length sequences
            location += length
            return nil
        }
        let count = length / 2
        var table: [UInt8] = Array(repeating: 0, count: count)
        for i in 0..<count {
            let value = readShort(location: &location)
            table[i] = UInt8(value >> 8)
        }
        return table
    }
}
