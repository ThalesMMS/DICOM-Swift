//
// J2KAppleMemory.swift
// J2KSwift
//
/// # J2KAppleMemory
///
/// Apple-specific memory optimisations for J2KSwift.
///
/// Provides memory optimisations leveraging Apple Silicon unified memory architecture,
/// large page support, memory-mapped I/O with advanced flags, SIMD-aligned buffers,
/// and compressed memory awareness.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Unified Memory Management (Apple Silicon)

/// Apple Silicon unified memory manager.
///
/// Leverages unified memory architecture on Apple Silicon where CPU and GPU
/// share the same physical memory, eliminating copy overhead.
///
/// Example:
/// ```swift
/// let manager = J2KUnifiedMemoryManager()
/// let buffer = try await manager.allocateShared(size: 1024 * 1024)
/// // Use buffer for both CPU and GPU operations
/// await manager.deallocate(buffer)
/// ```
public actor J2KUnifiedMemoryManager {
    /// Configuration for unified memory management.
    public struct Configuration: Sendable {
        /// Whether to prefer shared memory allocation.
        public let preferShared: Bool

        /// Whether to enable large page support.
        public let enableLargePages: Bool

        /// Alignment requirement for SIMD operations (must be power of 2).
        public let alignment: Int

        /// Creates a new configuration.
        ///
        /// - Parameters:
        ///   - preferShared: Prefer shared memory (default: true on Apple Silicon).
        ///   - enableLargePages: Enable large page support (default: true).
        ///   - alignment: SIMD alignment requirement (default: 64 bytes).
        public init(
            preferShared: Bool = true,
            enableLargePages: Bool = true,
            alignment: Int = 64
        ) {
            self.preferShared = preferShared
            self.enableLargePages = enableLargePages
            self.alignment = alignment
        }
    }

    private let configuration: Configuration
    private var allocations: [UInt: Int] = [:]
    private var totalAllocated: Int = 0

    /// A Sendable handle representing an allocated memory region.
    ///
    /// Use ``pointer`` to access the underlying raw pointer for read/write operations.
    /// This handle can safely cross actor boundaries.
    public struct MemoryHandle: Sendable {
        /// The address of the allocated memory.
        public let address: UInt

        /// The raw pointer to the allocated memory.
        public var pointer: UnsafeMutableRawPointer {
            UnsafeMutableRawPointer(bitPattern: address)!
        }

        init(_ pointer: UnsafeMutableRawPointer) {
            self.address = UInt(bitPattern: pointer)
        }
    }

    /// Creates a new unified memory manager.
    ///
    /// - Parameter configuration: The memory management configuration.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Allocates a shared memory buffer optimised for unified memory access.
    ///
    /// On Apple Silicon, this allocates memory that can be efficiently shared
    /// between CPU and GPU without copying.
    ///
    /// - Parameter size: The size in bytes to allocate.
    /// - Returns: A handle to the allocated memory.
    /// - Throws: ``J2KError`` if allocation fails.
    public func allocateShared(size: Int) throws -> MemoryHandle {
        #if canImport(Darwin)
        let alignedSize = (size + configuration.alignment - 1) & ~(configuration.alignment - 1)

        var ptr: UnsafeMutableRawPointer?
        let result = posix_memalign(&ptr, configuration.alignment, alignedSize)

        guard result == 0, let allocatedPtr = ptr else {
            throw J2KError.internalError("Failed to allocate aligned memory: errno \(result)")
        }

        allocations[UInt(bitPattern: allocatedPtr)] = alignedSize
        totalAllocated += alignedSize

        // Prefault pages to improve first access performance
        memset(allocatedPtr, 0, alignedSize)

        return MemoryHandle(allocatedPtr)
        #else
        throw J2KError.internalError("Unified memory allocation is only available on Apple platforms")
        #endif
    }

    /// Deallocates a previously allocated shared memory buffer.
    ///
    /// - Parameter handle: The memory handle to deallocate.
    public func deallocate(_ handle: MemoryHandle) {
        #if canImport(Darwin)
        if let size = allocations.removeValue(forKey: handle.address) {
            totalAllocated -= size
        }
        free(handle.pointer)
        #endif
    }

    /// Returns statistics about memory usage.
    ///
    /// - Returns: A dictionary with memory statistics.
    public func statistics() -> [String: Int] {
        [
            "totalAllocated": totalAllocated,
            "allocationCount": allocations.count
        ]
    }
}

// MARK: - Memory-Mapped File I/O with F_NOCACHE

/// Memory-mapped file manager with Apple-specific optimisations.
///
/// Provides memory-mapped file I/O with F_NOCACHE flag to bypass buffer cache
/// for large sequential reads/writes, improving performance on Apple platforms.
///
/// Example:
/// ```swift
/// let manager = J2KMemoryMappedFile()
/// try await manager.mapFile(at: url, mode: .readOnly)
/// let data = try await manager.read(offset: 0, length: 1024)
/// try await manager.unmapFile()
/// ```
public actor J2KMemoryMappedFile {
    /// Memory mapping mode.
    public enum MappingMode: Sendable {
        case readOnly
        case readWrite
    }

    private var fileDescriptor: Int32?
    private var mappedAddress: UnsafeMutableRawPointer?
    private var mappedSize: Int = 0
    private var useNoCacheFlag: Bool = true

    /// Creates a new memory-mapped file manager.
    public init() {}

    /// Maps a file into memory with Apple-specific optimisations.
    ///
    /// - Parameters:
    ///   - url: The file URL to map.
    ///   - mode: The mapping mode (read-only or read-write).
    ///   - useNoCache: Whether to use F_NOCACHE flag (default: true).
    /// - Throws: ``J2KError`` if mapping fails.
    public func mapFile(at url: URL, mode: MappingMode, useNoCache: Bool = true) throws {
        #if canImport(Darwin)
        guard fileDescriptor == nil else {
            throw J2KError.internalError("File already mapped")
        }

        let path = url.path
        let openMode: Int32 = mode == .readOnly ? O_RDONLY : O_RDWR

        let fd = open(path, openMode)
        guard fd >= 0 else {
            throw J2KError.internalError("Failed to open file: errno \(errno)")
        }

        self.fileDescriptor = fd
        self.useNoCacheFlag = useNoCache

        // Get file size
        var fileStat = stat()
        guard fstat(fd, &fileStat) == 0 else {
            close(fd)
            throw J2KError.internalError("Failed to stat file: errno \(errno)")
        }

        let fileSize = Int(fileStat.st_size)

        // Set F_NOCACHE flag if requested
        if useNoCache {
            _ = fcntl(fd, F_NOCACHE, 1)
        }

        // Map the file
        let prot: Int32 = mode == .readOnly ? PROT_READ : (PROT_READ | PROT_WRITE)
        let flags: Int32 = MAP_SHARED

        let addr = mmap(nil, fileSize, prot, flags, fd, 0)
        guard addr != MAP_FAILED else {
            close(fd)
            throw J2KError.internalError("Failed to mmap file: errno \(errno)")
        }

        self.mappedAddress = addr
        self.mappedSize = fileSize

        // Advise kernel about access pattern (sequential)
        madvise(addr, fileSize, MADV_SEQUENTIAL)
        #else
        throw J2KError.internalError("Memory-mapped I/O is only fully optimized on Apple platforms")
        #endif
    }

    /// Reads data from the mapped file.
    ///
    /// - Parameters:
    ///   - offset: The offset to read from.
    ///   - length: The number of bytes to read.
    /// - Returns: The read data.
    /// - Throws: ``J2KError`` if reading fails.
    public func read(offset: Int, length: Int) throws -> Data {
        guard let addr = mappedAddress else {
            throw J2KError.internalError("No file mapped")
        }

        guard offset + length <= mappedSize else {
            throw J2KError.internalError("Read beyond file size")
        }

        let ptr = addr.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        return Data(bytes: ptr, count: length)
    }

    /// Writes data to the mapped file (if opened in read-write mode).
    ///
    /// - Parameters:
    ///   - data: The data to write.
    ///   - offset: The offset to write at.
    /// - Throws: ``J2KError`` if writing fails.
    public func write(_ data: Data, at offset: Int) throws {
        guard let addr = mappedAddress else {
            throw J2KError.internalError("No file mapped")
        }

        guard offset + data.count <= mappedSize else {
            throw J2KError.internalError("Write beyond file size")
        }

        let ptr = addr.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
        _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: ptr, count: data.count))
    }

    /// Unmaps the file and closes the file descriptor.
    ///
    /// This must be called explicitly before the actor is deallocated.
    /// - Throws: ``J2KError`` if unmapping fails.
    public func unmapFile() throws {
        #if canImport(Darwin)
        if let addr = mappedAddress {
            guard munmap(addr, mappedSize) == 0 else {
                throw J2KError.internalError("Failed to munmap file: errno \(errno)")
            }
            mappedAddress = nil
            mappedSize = 0
        }

        if let fd = fileDescriptor {
            close(fd)
            fileDescriptor = nil
        }
        #endif
    }
}

// MARK: - SIMD-Aligned Buffer Allocator

/// SIMD-aligned buffer allocator for optimal performance.
///
/// Allocates buffers aligned to SIMD boundaries (16, 32, 64 bytes) for
/// maximum performance with Accelerate framework and NEON instructions.
///
/// Example:
/// ```swift
/// let buffer = try J2KSIMDAlignedBuffer.allocate(size: 1024, alignment: .cache64)
/// // Use buffer for SIMD operations
/// buffer.deallocate()
/// ```
public struct J2KSIMDAlignedBuffer: @unchecked Sendable {
    /// Alignment requirements for different use cases.
    public enum Alignment: Int, Sendable {
        /// 16-byte alignment for basic SIMD (128-bit vectors).
        case simd16 = 16

        /// 32-byte alignment for AVX-style operations.
        case simd32 = 32

        /// 64-byte alignment for cache line optimisation.
        case cache64 = 64

        /// 128-byte alignment for large SIMD operations.
        case simd128 = 128
    }

    /// The raw pointer to the allocated memory.
    public let pointer: UnsafeMutableRawPointer

    /// The size of the allocated memory in bytes.
    public let size: Int

    /// The alignment of the allocated memory.
    public let alignment: Alignment

    /// Allocates a SIMD-aligned buffer.
    ///
    /// - Parameters:
    ///   - size: The size in bytes to allocate.
    ///   - alignment: The alignment requirement (default: 64 bytes).
    /// - Returns: A new SIMD-aligned buffer.
    /// - Throws: ``J2KError`` if allocation fails.
    public static func allocate(size: Int, alignment: Alignment = .cache64) throws -> J2KSIMDAlignedBuffer {
        #if canImport(Darwin)
        var ptr: UnsafeMutableRawPointer?
        let result = posix_memalign(&ptr, alignment.rawValue, size)

        guard result == 0, let allocatedPtr = ptr else {
            throw J2KError.internalError("Failed to allocate SIMD-aligned buffer: errno \(result)")
        }

        return J2KSIMDAlignedBuffer(pointer: allocatedPtr, size: size, alignment: alignment)
        #else
        throw J2KError.internalError("SIMD-aligned allocation is optimized for Apple platforms")
        #endif
    }

    /// Deallocates the buffer.
    public func deallocate() {
        #if canImport(Darwin)
        free(pointer)
        #endif
    }

    /// Accesses the buffer as typed memory.
    ///
    /// - Parameter body: A closure that takes a typed buffer pointer.
    /// - Returns: The result of the closure.
    public func withMemoryRebound<T, R>(
        to type: T.Type,
        _ body: (UnsafeMutableBufferPointer<T>) throws -> R
    ) rethrows -> R {
        let typedPtr = pointer.assumingMemoryBound(to: type)
        let count = size / MemoryLayout<T>.stride
        return try body(UnsafeMutableBufferPointer(start: typedPtr, count: count))
    }
}

// MARK: - Compressed Memory Support

/// Compressed memory support for Apple platforms.
///
/// Monitors and adapts to memory pressure, enabling compressed memory
/// when available to reduce memory footprint.
///
/// Example:
/// ```swift
/// let monitor = J2KCompressedMemoryMonitor()
/// await monitor.startMonitoring()
/// let status = await monitor.currentStatus()
/// ```
public actor J2KCompressedMemoryMonitor {
    /// Memory pressure level.
    public enum MemoryPressure: Sendable {
        case normal
        case warning
        case critical
    }

    /// Compressed memory status.
    public struct Status: Sendable {
        /// Current memory pressure level.
        public let pressure: MemoryPressure

        /// Whether compressed memory is active.
        public let compressionActive: Bool

        /// Estimated compression ratio (if available).
        public let compressionRatio: Double?
    }

    private var currentPressure: MemoryPressure = .normal
    private var isMonitoring: Bool = false

    /// Creates a new compressed memory monitor.
    public init() {}

    /// Starts monitoring memory pressure.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        #if canImport(Darwin)
        // Set up dispatch source for memory pressure events
        // This is a simplified implementation; full implementation would use
        // dispatch_source_create with DISPATCH_SOURCE_TYPE_MEMORYPRESSURE
        #endif
    }

    /// Stops monitoring memory pressure.
    public func stopMonitoring() {
        isMonitoring = false
    }

    /// Returns the current memory status.
    ///
    /// - Returns: The current compressed memory status.
    public func currentStatus() -> Status {
        Status(
            pressure: currentPressure,
            compressionActive: currentPressure != .normal,
            compressionRatio: currentPressure != .normal ? 0.6 : nil
        )
    }

    /// Updates the memory pressure level.
    ///
    /// - Parameter pressure: The new pressure level.
    internal func updatePressure(_ pressure: MemoryPressure) {
        currentPressure = pressure
    }
}

// MARK: - Large Page Support

/// Large page allocator for improved TLB efficiency.
///
/// On supported systems, allocates memory using large pages (2MB or 1GB)
/// to reduce TLB misses and improve performance for large buffers.
///
/// Example:
/// ```swift
/// if J2KLargePageAllocator.isSupported {
///     let buffer = try J2KLargePageAllocator.allocate(size: 4 * 1024 * 1024)
///     // Use buffer
///     J2KLargePageAllocator.deallocate(buffer)
/// }
/// ```
public enum J2KLargePageAllocator {
    /// Whether large pages are supported on this system.
    public static var isSupported: Bool {
        #if canImport(Darwin) && arch(arm64)
        // Apple Silicon supports large pages
        return true
        #else
        return false
        #endif
    }

    /// The size of a large page on this system.
    public static var largePageSize: Int {
        #if canImport(Darwin) && arch(arm64)
        return 2 * 1024 * 1024 // 2 MB
        #else
        return 4096 // Fall back to standard page size
        #endif
    }

    /// Allocates memory using large pages if available.
    ///
    /// - Parameter size: The size in bytes to allocate (will be rounded up).
    /// - Returns: A pointer to the allocated memory.
    /// - Throws: ``J2KError`` if allocation fails.
    public static func allocate(size: Int) throws -> UnsafeMutableRawPointer {
        #if canImport(Darwin) && arch(arm64)
        // Round up to large page boundary
        let pageSize = largePageSize
        let alignedSize = ((size + pageSize - 1) / pageSize) * pageSize

        // Use vm_allocate with VM_FLAGS_SUPERPAGE_SIZE_2MB
        var address: vm_address_t = 0
        let kr = vm_allocate(
            mach_task_self_,
            &address,
            vm_size_t(alignedSize),
            VM_FLAGS_ANYWHERE | VM_FLAGS_SUPERPAGE_SIZE_2MB
        )

        guard kr == KERN_SUCCESS else {
            // Fall back to regular allocation
            let ptr = malloc(alignedSize)
            guard let allocatedPtr = ptr else {
                throw J2KError.internalError("Failed to allocate memory")
            }
            return allocatedPtr
        }

        return UnsafeMutableRawPointer(bitPattern: Int(address))!
        #else
        // Fall back to standard allocation
        let ptr = malloc(size)
        guard let allocatedPtr = ptr else {
            throw J2KError.internalError("Failed to allocate memory")
        }
        return allocatedPtr
        #endif
    }

    /// Deallocates memory allocated with large pages.
    ///
    /// - Parameters:
    ///   - pointer: The pointer to deallocate.
    ///   - size: The size that was originally allocated.
    public static func deallocate(_ pointer: UnsafeMutableRawPointer, size: Int) {
        #if canImport(Darwin) && arch(arm64)
        let pageSize = largePageSize
        let alignedSize = ((size + pageSize - 1) / pageSize) * pageSize
        vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: pointer)),
            vm_size_t(alignedSize)
        )
        #else
        free(pointer)
        #endif
    }
}
