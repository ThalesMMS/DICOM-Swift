//
//  MetalWindowingProcessor.swift
//  MetalBenchmark
//
//  This type encapsulates GPU-accelerated window/level
//  calculations using Metal compute shaders.  It provides a
//  high-performance alternative to CPU-based vDSP processing
//  for medical imaging windowing operations.  The implementation
//  mirrors the algorithm from DCMWindowingProcessor but executes
//  on the GPU for significantly improved throughput.
//

import Foundation
import Metal

/// Error types specific to Metal processing operations
public enum MetalProcessorError: Error {
    case metalNotAvailable
    case deviceCreationFailed
    case libraryCreationFailed
    case functionNotFound(String)
    case pipelineCreationFailed(Error)
    case bufferCreationFailed
    case commandBufferCreationFailed
    case invalidInput
}

/// GPU-accelerated window/level processor using Metal compute
/// shaders.  This class manages Metal device resources and
/// provides methods for applying window/level transformations to
/// 16-bit grayscale medical images.  The GPU implementation
/// typically achieves 3-5x speedup compared to vDSP on Apple
/// Silicon and modern Intel Macs.
/// Metal devices, command queues, and pipeline states support concurrent command encoding;
/// this wrapper stores them immutably and allocates per-operation buffers and encoders.
public final class MetalWindowingProcessor: @unchecked Sendable {

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private let displayLUTPipelineState: MTLComputePipelineState

    // MARK: - Initialization

    /// Initializes the Metal processor with system default device
    /// and creates the compute pipeline for window/level operations.
    /// This initialization may fail if Metal is not available or
    /// if the shader library cannot be loaded.
    ///
    /// - Throws: ``MetalProcessorError`` if Metal setup fails
    public init() throws {
        // Create Metal device
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalProcessorError.metalNotAvailable
        }
        self.device = device

        // Create command queue
        guard let commandQueue = device.makeCommandQueue() else {
            throw MetalProcessorError.deviceCreationFailed
        }
        self.commandQueue = commandQueue

        // Load shader source from bundle and compile it at runtime — SPM does
        // not support makeDefaultLibrary(). The source ships as an opaque
        // `.metal.txt` resource (issue #1905): a `.metal` extension makes an
        // Xcode consumer treat it as build input and demand the Metal
        // Toolchain for a file that is only ever compiled here, at runtime.
        guard let shaderURL = Bundle.module.url(forResource: "WindowingShaders.metal",
                                                withExtension: "txt") else {
            throw MetalProcessorError.libraryCreationFailed
        }
        guard let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8) else {
            throw MetalProcessorError.libraryCreationFailed
        }
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
            throw MetalProcessorError.libraryCreationFailed
        }

        // Get the windowing kernel function
        guard let function = library.makeFunction(name: "applyWindowLevel") else {
            throw MetalProcessorError.functionNotFound("applyWindowLevel")
        }

        // Create compute pipeline state
        do {
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            throw MetalProcessorError.pipelineCreationFailed(error)
        }

        // The presentation-LUT kernel (issue #1906).
        guard let lutFunction = library.makeFunction(name: "applyDisplayLUT") else {
            throw MetalProcessorError.functionNotFound("applyDisplayLUT")
        }
        do {
            self.displayLUTPipelineState = try device.makeComputePipelineState(function: lutFunction)
        } catch {
            throw MetalProcessorError.pipelineCreationFailed(error)
        }
    }

    // MARK: - Presentation LUT (issue #1906)

    /// Applies a cached presentation table to stored pixel values on the GPU.
    ///
    /// The GPU indexes the exact table the CPU path indexes, so the output is
    /// byte-identical — there is no arithmetic to disagree about. Returns
    /// `nil` when the table cannot represent every input (an unmapped entry
    /// or an out-of-range stored value): those are the cases the scalar path
    /// reports as per-pixel failures, and the GPU must not turn them into
    /// silent zeros.
    public func applyDisplayLUT(storedValues: [Int],
                                lut: DicomDisplayLUT) throws -> Data? {
        guard !storedValues.isEmpty else { return nil }
        guard lut.hasUnmappedEntries == false else { return nil }

        let table = lut.tableBytes
        var indices = [UInt32](repeating: 0, count: storedValues.count)
        for (position, storedValue) in storedValues.enumerated() {
            let index = storedValue - lut.minimumStoredValue
            guard index >= 0, index < table.count else { return nil }
            indices[position] = UInt32(index)
        }

        let pixelCount = storedValues.count
        guard let indexBuffer = device.makeBuffer(
            bytes: indices,
            length: pixelCount * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ), let tableBuffer = device.makeBuffer(
            bytes: table,
            length: table.count,
            options: .storageModeShared
        ), let outputBuffer = device.makeBuffer(
            length: pixelCount,
            options: .storageModeShared
        ) else {
            throw MetalProcessorError.bufferCreationFailed
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalProcessorError.commandBufferCreationFailed
        }

        var lutCount = UInt32(table.count)
        var count = UInt32(pixelCount)
        encoder.setComputePipelineState(displayLUTPipelineState)
        encoder.setBuffer(indexBuffer, offset: 0, index: 0)
        encoder.setBuffer(tableBuffer, offset: 0, index: 1)
        encoder.setBuffer(outputBuffer, offset: 0, index: 2)
        encoder.setBytes(&lutCount, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 4)

        let threadGroupSize = MTLSize(
            width: min(displayLUTPipelineState.maxTotalThreadsPerThreadgroup, pixelCount),
            height: 1,
            depth: 1
        )
        let threadGroups = MTLSize(
            width: (pixelCount + threadGroupSize.width - 1) / threadGroupSize.width,
            height: 1,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw error
        }

        let outputPointer = outputBuffer.contents().assumingMemoryBound(to: UInt8.self)
        return Data(UnsafeBufferPointer(start: outputPointer, count: pixelCount))
    }

    // MARK: - Window/Level Operations

    /// Applies a linear window/level transformation to a 16-bit
    /// grayscale pixel buffer using GPU compute shader.  The
    /// resulting pixels are scaled to the 0–255 range and returned
    /// as `Data`.  This function mirrors the CPU implementation
    /// in DCMWindowingProcessor.applyWindowLevel but executes on
    /// the GPU for improved performance.  If the input is empty or
    /// the width is non-positive the function returns nil.
    ///
    /// - Parameters:
    ///   - pixels16: An array of unsigned 16-bit pixel intensities.
    ///   - center: The centre of the window.
    ///   - width: The width of the window.
    /// - Returns: A `Data` object containing 8-bit pixel values or
    ///   `nil` if the input is invalid.
    /// - Throws: ``MetalProcessorError`` if GPU processing fails
    public func applyWindowLevel(pixels16: [UInt16],
                                  center: Float,
                                  width: Float) throws -> Data? {
        // Validate input
        guard !pixels16.isEmpty, width > 0 else { return nil }

        let pixelCount = pixels16.count

        // Create input buffer
        guard let inputBuffer = device.makeBuffer(
            bytes: pixels16,
            length: pixelCount * MemoryLayout<UInt16>.stride,
            options: .storageModeShared
        ) else {
            throw MetalProcessorError.bufferCreationFailed
        }

        // Create output buffer
        guard let outputBuffer = device.makeBuffer(
            length: pixelCount * MemoryLayout<UInt8>.stride,
            options: .storageModeShared
        ) else {
            throw MetalProcessorError.bufferCreationFailed
        }

        // Prepare parameters (use setBytes instead of buffers for better performance)
        var centerParam = center
        var widthParam = width
        var pixelCountParam = UInt32(pixelCount)

        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalProcessorError.commandBufferCreationFailed
        }

        // Create compute encoder
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalProcessorError.commandBufferCreationFailed
        }

        // Set pipeline state and buffers
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        computeEncoder.setBuffer(outputBuffer, offset: 0, index: 1)
        // Use setBytes for small parameters - avoids buffer allocation overhead
        computeEncoder.setBytes(&centerParam, length: MemoryLayout<Float>.stride, index: 2)
        computeEncoder.setBytes(&widthParam, length: MemoryLayout<Float>.stride, index: 3)
        computeEncoder.setBytes(&pixelCountParam, length: MemoryLayout<UInt32>.stride, index: 4)

        // Calculate thread group size
        let threadGroupSize = MTLSize(
            width: min(pipelineState.maxTotalThreadsPerThreadgroup, pixelCount),
            height: 1,
            depth: 1
        )

        let threadGroups = MTLSize(
            width: (pixelCount + threadGroupSize.width - 1) / threadGroupSize.width,
            height: 1,
            depth: 1
        )

        // Dispatch compute kernel
        computeEncoder.dispatchThreadgroups(threadGroups,
                                            threadsPerThreadgroup: threadGroupSize)

        // End encoding
        computeEncoder.endEncoding()

        // Commit and wait for completion
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Extract result from output buffer
        let outputPointer = outputBuffer.contents().assumingMemoryBound(to: UInt8.self)
        let outputArray = Array(UnsafeBufferPointer(start: outputPointer, count: pixelCount))

        return Data(outputArray)
    }

    /// Convenience method that accepts Double parameters for
    /// compatibility with DCMWindowingProcessor API.  Internally
    /// converts to Float for GPU processing.
    ///
    /// - Parameters:
    ///   - pixels16: An array of unsigned 16-bit pixel intensities.
    ///   - center: The centre of the window.
    ///   - width: The width of the window.
    /// - Returns: A `Data` object containing 8-bit pixel values or
    ///   `nil` if the input is invalid.
    /// - Throws: ``MetalProcessorError`` if GPU processing fails
    public func applyWindowLevel(pixels16: [UInt16],
                                  center: Double,
                                  width: Double) throws -> Data? {
        return try applyWindowLevel(pixels16: pixels16,
                                   center: Float(center),
                                   width: Float(width))
    }

    // MARK: - Device Information

    /// Returns the name of the Metal device being used for
    /// processing.  Useful for diagnostic output and performance
    /// analysis.
    ///
    /// - Returns: String describing the GPU device
    public var deviceName: String {
        return device.name
    }

    /// Checks if Metal is available on the current system.
    /// This is a convenience method for checking availability
    /// before attempting to initialize the processor.
    ///
    /// - Returns: `true` if Metal is available, `false` otherwise
    public static var isMetalAvailable: Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }
}
