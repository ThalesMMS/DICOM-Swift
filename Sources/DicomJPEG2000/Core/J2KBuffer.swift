//
// J2KBuffer.swift
// J2KSwift
//
/// # J2KBuffer
///
/// Efficient buffer management for JPEG 2000 image data.
///
/// This module provides memory management utilities for handling large image buffers
/// with efficient allocation, deallocation, and copy-on-write semantics.

import Foundation

/// A memory buffer for storing image data with efficient management.
///
/// `J2KBuffer` provides a managed memory buffer with automatic reference counting
/// and support for efficient copy-on-write operations. It is designed to handle
/// large image data efficiently while minimising memory copies.
///
/// > Important: This is an **internal implementation detail** of the J2KSwift library.
/// > It is exposed as `public` only for cross-module use within the package.
/// > Use ``J2KImageBuffer`` for user-facing image data storage instead.
///
/// Example:
/// ```swift
/// let buffer = J2KBuffer(capacity: 1024 * 1024) // 1MB buffer
/// buffer.withUnsafeMutableBytes { ptr in
///     // Write data to buffer
/// }
/// ```
public struct J2KBuffer: Sendable {
    /// The underlying storage for the buffer.
    private var storage: Storage

    /// The capacity of the buffer in bytes.
    public var capacity: Int {
        storage.capacity
    }

    /// The current size of valid data in the buffer.
    public var count: Int {
        storage.count
    }

    /// Creates a new buffer with the specified capacity.
    ///
    /// - Parameter capacity: The capacity in bytes.
    public init(capacity: Int) {
        self.storage = Storage(capacity: capacity)
    }

    /// Creates a buffer from existing data.
    ///
    /// - Parameter data: The data to store in the buffer.
    public init(data: Data) {
        self.storage = Storage(data: data)
    }

    /// Provides read-only access to the buffer's bytes.
    ///
    /// - Parameter body: A closure that takes an unsafe buffer pointer.
    /// - Returns: The result of the closure.
    /// - Throws: Rethrows any error from the closure.
    public func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        try storage.withUnsafeBytes(body)
    }

    /// Provides mutable access to the buffer's bytes.
    ///
    /// - Parameter body: A closure that takes a mutable unsafe buffer pointer.
    /// - Returns: The result of the closure.
    /// - Throws: Rethrows any error from the closure.
    public mutating func withUnsafeMutableBytes<Result>(
        _ body: (UnsafeMutableRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        // Ensure unique storage before mutation
        if !isKnownUniquelyReferenced(&storage) {
            // Storage is shared, create a copy
            let newStorage = storage.copy()
            // Replace storage
            self = J2KBuffer(storage: newStorage)
        }
        return try storage.withUnsafeMutableBytes(body)
    }

    /// Converts the buffer to Data.
    ///
    /// - Returns: A Data object containing the buffer's contents.
    public func toData() -> Data {
        storage.toData()
    }

    /// Updates the count of valid data in the buffer.
    ///
    /// - Parameter newCount: The new count value.
    public mutating func updateCount(_ newCount: Int) {
        storage.updateCount(newCount)
    }

    /// Private initializer for copy-on-write.
    private init(storage: Storage) {
        self.storage = storage
    }

    /// Internal storage class for reference-counted buffer management.
    private final class Storage: @unchecked Sendable {
        private let buffer: UnsafeMutableRawBufferPointer
        let capacity: Int
        private(set) var count: Int

        init(capacity: Int) {
            self.capacity = capacity
            self.count = 0
            self.buffer = UnsafeMutableRawBufferPointer.allocate(
                byteCount: capacity,
                alignment: MemoryLayout<UInt64>.alignment
            )
        }

        init(data: Data) {
            self.capacity = data.count
            self.count = data.count
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
            Data(bytes: buffer.baseAddress!, count: count)
        }

        func updateCount(_ newCount: Int) {
            self.count = min(newCount, capacity)
        }

        func copy() -> Storage {
            let newStorage = Storage(capacity: capacity)
            newStorage.buffer.copyMemory(from: UnsafeRawBufferPointer(buffer))
            newStorage.count = count
            return newStorage
        }
    }
}
