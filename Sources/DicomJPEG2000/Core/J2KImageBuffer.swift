//
// J2KImageBuffer.swift
// J2KSwift
//
/// # J2KImageBuffer
///
/// Efficient image buffer with copy-on-write semantics.
///
/// This module provides an optimised buffer specifically for image data
/// with automatic copy-on-write behavior to minimise memory copies.

import Foundation

/// An efficient buffer for storing image component data.
///
/// `J2KImageBuffer` provides optimised storage for image data with
/// copy-on-write semantics. When a buffer is copied, the underlying
/// storage is shared until a write operation occurs, at which point
/// a new copy is created.
///
/// This allows efficient passing of image data without unnecessary copies.
///
/// Example:
/// ```swift
/// var buffer = J2KImageBuffer(width: 512, height: 512, bitDepth: 8)
/// buffer.setPixel(at: 0, value: 255)
/// let copy = buffer // Shares storage
/// var mutableCopy = copy
/// mutableCopy.setPixel(at: 1, value: 128) // Triggers copy
/// ```
public struct J2KImageBuffer: Sendable {
    /// The underlying storage.
    private var storage: Storage

    /// The width of the image in pixels.
    public let width: Int

    /// The height of the image in pixels.
    public let height: Int

    /// The bit depth per pixel.
    public let bitDepth: Int

    /// The number of pixels in the buffer.
    public var count: Int {
        width * height
    }

    /// The size of the buffer in bytes.
    public var sizeInBytes: Int {
        count * bytesPerPixel
    }

    /// The number of bytes per pixel.
    private var bytesPerPixel: Int {
        (bitDepth + 7) / 8
    }

    /// Creates a new image buffer with the specified dimensions.
    ///
    /// - Parameters:
    ///   - width: The width in pixels.
    ///   - height: The height in pixels.
    ///   - bitDepth: The bit depth per pixel (default: 8).
    public init(width: Int, height: Int, bitDepth: Int = 8) {
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        let capacity = width * height * ((bitDepth + 7) / 8)
        self.storage = Storage(capacity: capacity)
    }

    /// Creates a buffer from existing data.
    ///
    /// - Parameters:
    ///   - width: The width in pixels.
    ///   - height: The height in pixels.
    ///   - bitDepth: The bit depth per pixel.
    ///   - data: The pixel data.
    public init(width: Int, height: Int, bitDepth: Int, data: Data) {
        self.width = width
        self.height = height
        self.bitDepth = bitDepth
        self.storage = Storage(data: data)
    }

    /// Gets the value of a pixel at the specified index.
    ///
    /// - Parameter index: The pixel index (0-based).
    /// - Returns: The pixel value.
    public func getPixel(at index: Int) -> Int {
        storage.getPixel(at: index, bytesPerPixel: bytesPerPixel)
    }

    /// Sets the value of a pixel at the specified index.
    ///
    /// - Parameters:
    ///   - index: The pixel index (0-based).
    ///   - value: The pixel value.
    public mutating func setPixel(at index: Int, value: Int) {
        ensureUnique()
        storage.setPixel(at: index, value: value, bytesPerPixel: bytesPerPixel)
    }

    /// Gets the value of a pixel at the specified coordinates.
    ///
    /// - Parameters:
    ///   - x: The x-coordinate.
    ///   - y: The y-coordinate.
    /// - Returns: The pixel value.
    public func getPixel(x: Int, y: Int) -> Int {
        let index = y * width + x
        return getPixel(at: index)
    }

    /// Sets the value of a pixel at the specified coordinates.
    ///
    /// - Parameters:
    ///   - x: The x-coordinate.
    ///   - y: The y-coordinate.
    ///   - value: The pixel value.
    public mutating func setPixel(x: Int, y: Int, value: Int) {
        let index = y * width + x
        setPixel(at: index, value: value)
    }

    /// Provides read-only access to the raw buffer data.
    ///
    /// - Parameter body: A closure that receives the buffer pointer.
    /// - Returns: The result of the closure.
    /// - Throws: Rethrows any error from the closure.
    public func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBytes(body)
    }

    /// Provides mutable access to the raw buffer data.
    ///
    /// - Parameter body: A closure that receives the mutable buffer pointer.
    /// - Returns: The result of the closure.
    /// - Throws: Rethrows any error from the closure.
    public mutating func withUnsafeMutableBytes<Result>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        ensureUnique()
        return try storage.withUnsafeMutableBytes(body)
    }

    /// Converts the buffer to Data.
    ///
    /// - Returns: A Data object containing the buffer's contents.
    public func toData() -> Data {
        storage.toData()
    }

    /// Ensures the storage is uniquely referenced.
    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }
    }

    /// Internal storage class for the buffer.
    private final class Storage: @unchecked Sendable {
        private let buffer: UnsafeMutableRawBufferPointer
        private let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            self.buffer = UnsafeMutableRawBufferPointer.allocate(
                byteCount: capacity,
                alignment: MemoryLayout<UInt64>.alignment
            )
            // Initialise to zero
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
        }

        init(data: Data) {
            self.capacity = data.count
            self.buffer = UnsafeMutableRawBufferPointer.allocate(
                byteCount: capacity,
                alignment: MemoryLayout<UInt64>.alignment
            )
            data.withUnsafeBytes { srcPtr in
                buffer.copyMemory(from: srcPtr)
            }
        }

        deinit {
            buffer.deallocate()
        }

        func getPixel(at index: Int, bytesPerPixel: Int) -> Int {
            let offset = index * bytesPerPixel
            guard offset + bytesPerPixel <= capacity else { return 0 }

            switch bytesPerPixel {
            case 1:
                return Int(buffer.load(fromByteOffset: offset, as: UInt8.self))
            case 2:
                return Int(buffer.load(fromByteOffset: offset, as: UInt16.self))
            case 4:
                return Int(buffer.load(fromByteOffset: offset, as: UInt32.self))
            default:
                // For other sizes, read bytes manually
                var value = 0
                for i in 0..<bytesPerPixel {
                    value |= Int(buffer.load(fromByteOffset: offset + i, as: UInt8.self)) << (i * 8)
                }
                return value
            }
        }

        func setPixel(at index: Int, value: Int, bytesPerPixel: Int) {
            let offset = index * bytesPerPixel
            guard offset + bytesPerPixel <= capacity else { return }

            switch bytesPerPixel {
            case 1:
                buffer.storeBytes(of: UInt8(value & 0xFF), toByteOffset: offset, as: UInt8.self)
            case 2:
                buffer.storeBytes(of: UInt16(value & 0xFFFF), toByteOffset: offset, as: UInt16.self)
            case 4:
                buffer.storeBytes(of: UInt32(value & 0xFFFFFFFF), toByteOffset: offset, as: UInt32.self)
            default:
                // For other sizes, write bytes manually
                for i in 0..<bytesPerPixel {
                    let byte = UInt8((value >> (i * 8)) & 0xFF)
                    buffer.storeBytes(of: byte, toByteOffset: offset + i, as: UInt8.self)
                }
            }
        }

        func withUnsafeBytes<Result>(
            _ body: (UnsafeRawBufferPointer) throws -> Result
        ) rethrows -> Result {
            try body(UnsafeRawBufferPointer(buffer))
        }

        func withUnsafeMutableBytes<Result>(
            _ body: (UnsafeMutableRawBufferPointer) throws -> Result
        ) rethrows -> Result {
            try body(buffer)
        }

        func toData() -> Data {
            Data(bytes: buffer.baseAddress!, count: capacity)
        }

        func copy() -> Storage {
            let newStorage = Storage(capacity: capacity)
            newStorage.buffer.copyMemory(from: UnsafeRawBufferPointer(buffer))
            return newStorage
        }
    }
}
