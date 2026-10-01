//
// J2KApplePlatform.swift
// J2KSwift
//
/// # J2KApplePlatform
///
/// Apple platform-specific features and optimisations.
///
/// Provides Quality of Service classes, power efficiency modes, thermal state
/// monitoring, and battery-aware processing for optimal performance on Apple
/// platforms.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

#if os(iOS) || os(tvOS) || os(watchOS)
import UIKit
#endif

#if os(macOS)
import IOKit.ps
#endif

// MARK: - Quality of Service

/// Quality of Service levels for Apple platforms.
///
/// Maps to system QoS classes for optimal scheduling and power efficiency.
///
/// Example:
/// ```swift
/// let qos = J2KQualityOfService.userInitiated
/// // Use for time-sensitive user operations
/// ```
public enum J2KQualityOfService: Sendable {
    /// User-interactive work (UI updates, animations).
    case userInteractive

    /// User-initiated work (responding to user actions).
    case userInitiated

    /// Utility work (downloads, imports).
    case utility

    /// Background work (maintenance, cleanup).
    case background

    /// Default QoS level.
    case `default`

    /// Converts to Foundation DispatchQoS.
    public var dispatchQoS: DispatchQoS {
        switch self {
        case .userInteractive:
            return .userInteractive
        case .userInitiated:
            return .userInitiated
        case .utility:
            return .utility
        case .background:
            return .background
        case .default:
            return .default
        }
    }

    /// Converts to TaskPriority for Swift Concurrency.
    public var taskPriority: TaskPriority {
        switch self {
        case .userInteractive:
            return .high
        case .userInitiated:
            return .high
        case .utility:
            return .medium
        case .background:
            return .low
        case .default:
            return .medium
        }
    }
}

// MARK: - Power Efficiency

/// Power efficiency manager for battery-aware processing.
///
/// Monitors power state and adjusts processing strategy to balance
/// performance and power consumption.
///
/// Example:
/// ```swift
/// let manager = J2KPowerEfficiencyManager()
/// await manager.startMonitoring()
/// let mode = await manager.recommendedMode()
/// ```
public actor J2KPowerEfficiencyManager {
    /// Power mode recommendation.
    public enum PowerMode: Sendable {
        /// Maximum performance (plugged in or high battery).
        case performance

        /// Balanced performance and efficiency.
        case balanced

        /// Power-saving mode (low battery).
        case powerSaver
    }

    /// Power state information.
    public struct PowerState: Sendable {
        /// Whether the device is plugged into power.
        public let isPluggedIn: Bool

        /// Battery level (0.0 - 1.0), nil if not available.
        public let batteryLevel: Double?

        /// Whether low power mode is enabled.
        public let isLowPowerModeEnabled: Bool

        /// Current thermal state.
        public let thermalState: J2KThermalState
    }

    private var currentState: PowerState?
    private var isMonitoring: Bool = false

    /// Creates a new power efficiency manager.
    public init() {}

    /// Starts monitoring power state.
    public func startMonitoring() async {
        guard !isMonitoring else { return }
        isMonitoring = true
        await updatePowerState()
    }

    /// Stops monitoring power state.
    public func stopMonitoring() {
        isMonitoring = false
    }

    /// Returns the current power state.
    ///
    /// - Returns: The current power state, or nil if not available.
    public func powerState() -> PowerState? {
        currentState
    }

    /// Returns the recommended processing mode based on power state.
    ///
    /// - Returns: The recommended power mode.
    public func recommendedMode() -> PowerMode {
        guard let state = currentState else {
            return .balanced
        }

        // If plugged in and not overheating, use performance mode
        if state.isPluggedIn && state.thermalState.rawValue < 2 {
            return .performance
        }

        // If low power mode enabled or battery low, use power saver
        if state.isLowPowerModeEnabled {
            return .powerSaver
        }

        if let level = state.batteryLevel, level < 0.2 {
            return .powerSaver
        }

        // If thermal state is concerning, reduce performance
        if state.thermalState.rawValue >= 2 {
            return .powerSaver
        }

        return .balanced
    }

    /// Updates the current power state.
    private func updatePowerState() async {
        #if os(iOS) || os(tvOS)
        currentState = await MainActor.run {
            let device = UIDevice.current
            device.isBatteryMonitoringEnabled = true

            return PowerState(
                isPluggedIn: device.batteryState == .charging || device.batteryState == .full,
                batteryLevel: device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil,
                isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: J2KThermalState.from(processInfo: ProcessInfo.processInfo)
            )
        }
        #elseif os(macOS)
        // On macOS, use IOKit to check power source
        let isPluggedIn = isConnectedToPower()
        let thermalState = J2KThermalState.from(processInfo: ProcessInfo.processInfo)

        currentState = PowerState(
            isPluggedIn: isPluggedIn,
            batteryLevel: nil,
            isLowPowerModeEnabled: false,
            thermalState: thermalState
        )
        #else
        currentState = nil
        #endif
    }

    #if os(macOS)
    /// Checks if the Mac is connected to power.
    private func isConnectedToPower() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        for source in sources {
            if let description = IOPSGetPowerSourceDescription(
                snapshot, source
            ).takeUnretainedValue() as? [String: Any] {
                if let powerSourceState = description[kIOPSPowerSourceStateKey] as? String {
                    return powerSourceState == kIOPSACPowerValue
                }
            }
        }

        return false
    }
    #endif
}

// MARK: - Thermal State Monitoring

/// Thermal state levels.
///
/// Represents the device's thermal condition for throttling decisions.
public enum J2KThermalState: Int, Sendable {
    /// Nominal thermal state.
    case nominal = 0

    /// Fair thermal state (some throttling may occur).
    case fair = 1

    /// Serious thermal state (significant throttling).
    case serious = 2

    /// Critical thermal state (heavy throttling required).
    case critical = 3

    /// Converts from ProcessInfo.ThermalState.
    public static func from(processInfo: ProcessInfo) -> J2KThermalState {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(macOS)
        switch processInfo.thermalState {
        case .nominal:
            return .nominal
        case .fair:
            return .fair
        case .serious:
            return .serious
        case .critical:
            return .critical
        @unknown default:
            return .nominal
        }
        #else
        return .nominal
        #endif
    }
}

/// Thermal state monitor for throttling decisions.
///
/// Monitors device thermal state and provides recommendations for
/// workload reduction to prevent overheating.
///
/// Example:
/// ```swift
/// let monitor = J2KThermalStateMonitor()
/// await monitor.startMonitoring()
/// let shouldThrottle = await monitor.shouldThrottleProcessing()
/// ```
public actor J2KThermalStateMonitor {
    /// Throttling recommendation.
    public struct ThrottlingRecommendation: Sendable {
        /// Current thermal state.
        public let thermalState: J2KThermalState

        /// Whether to throttle processing.
        public let shouldThrottle: Bool

        /// Recommended reduction factor (0.0 - 1.0).
        public let reductionFactor: Double
    }

    private var currentThermalState: J2KThermalState = .nominal
    private var isMonitoring: Bool = false
    #if !os(Linux) && !os(Windows)
    private var thermalObserver: (any NSObjectProtocol)?
    #endif

    /// Creates a new thermal state monitor.
    public init() {}

    isolated deinit {
        #if !os(Linux) && !os(Windows)
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        #endif
    }

    /// Starts monitoring thermal state.
    public func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        updateThermalState()

        // Register for thermal state change notifications
        #if !os(Linux) && !os(Windows)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task {
                await self?.updateThermalState()
            }
        }
        #endif
    }

    /// Stops monitoring thermal state.
    public func stopMonitoring() {
        isMonitoring = false

        #if !os(Linux) && !os(Windows)
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        #endif
    }

    /// Returns the current thermal state.
    ///
    /// - Returns: The current thermal state.
    public func currentState() -> J2KThermalState {
        currentThermalState
    }

    /// Returns whether processing should be throttled.
    ///
    /// - Returns: True if throttling is recommended.
    public func shouldThrottleProcessing() -> Bool {
        currentThermalState.rawValue >= J2KThermalState.serious.rawValue
    }

    /// Returns detailed throttling recommendation.
    ///
    /// - Returns: Throttling recommendation with reduction factor.
    public func throttlingRecommendation() -> ThrottlingRecommendation {
        let reductionFactor: Double

        switch currentThermalState {
        case .nominal:
            reductionFactor = 1.0 // No reduction
        case .fair:
            reductionFactor = 0.8 // 20% reduction
        case .serious:
            reductionFactor = 0.5 // 50% reduction
        case .critical:
            reductionFactor = 0.25 // 75% reduction
        }

        return ThrottlingRecommendation(
            thermalState: currentThermalState,
            shouldThrottle: shouldThrottleProcessing(),
            reductionFactor: reductionFactor
        )
    }

    /// Updates the current thermal state.
    private func updateThermalState() {
        guard isMonitoring else { return }
        #if os(iOS) || os(tvOS) || os(watchOS) || os(macOS)
        currentThermalState = J2KThermalState.from(processInfo: ProcessInfo.processInfo)
        #else
        currentThermalState = .nominal
        #endif
    }
}

// MARK: - Asynchronous I/O using DispatchIO

/// Asynchronous file I/O using DispatchIO.
///
/// Provides high-performance asynchronous file I/O using GCD's DispatchIO
/// for efficient reading and writing of JPEG 2000 files.
///
/// Example:
/// ```swift
/// let io = J2KAsyncFileIO()
/// let data = try await io.read(from: url, offset: 0, length: 1024)
/// try await io.write(data, to: url)
/// ```
public actor J2KAsyncFileIO {
    /// Read options.
    public struct ReadOptions: Sendable {
        /// Quality of Service for the operation.
        public let qos: J2KQualityOfService

        /// Buffer size for reading (default: 64 KB).
        public let bufferSize: Int

        /// Creates new read options.
        ///
        /// - Parameters:
        ///   - qos: Quality of Service (default: .userInitiated).
        ///   - bufferSize: Buffer size (default: 64 KB).
        public init(qos: J2KQualityOfService = .userInitiated, bufferSize: Int = 64 * 1024) {
            self.qos = qos
            self.bufferSize = bufferSize
        }
    }

    /// Creates a new async file I/O handler.
    public init() {}

    /// Reads data from a file asynchronously.
    ///
    /// - Parameters:
    ///   - url: The file URL to read from.
    ///   - offset: The offset to start reading from.
    ///   - length: The number of bytes to read.
    ///   - options: Read options.
    /// - Returns: The read data.
    /// - Throws: ``J2KError`` if reading fails.
    public func read(
        from url: URL,
        offset: Int = 0,
        length: Int,
        options: ReadOptions = ReadOptions()
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let path = url.path
            let queue = DispatchQueue(
                label: "com.j2kswift.asyncio",
                qos: options.qos.dispatchQoS
            )

            guard let channel = DispatchIO(
                type: .random,
                path: path,
                oflag: O_RDONLY,
                mode: 0,
                queue: queue,
                cleanupHandler: { _ in }
            ) else {
                continuation.resume(throwing: J2KError.internalError("Failed to open file for reading"))
                return
            }

            var data = Data()
            var readError: Error?

            channel.read(
                offset: off_t(offset),
                length: length,
                queue: queue
            ) { done, chunk, error in
                if error != 0 {
                    readError = J2KError.internalError("Read error: errno \(error)")
                }

                if let chunk = chunk, !chunk.isEmpty {
                    data.append(contentsOf: chunk)
                }

                if done {
                    channel.close()
                    if let error = readError {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: data)
                    }
                }
            }
        }
    }

    /// Writes data to a file asynchronously.
    ///
    /// - Parameters:
    ///   - data: The data to write.
    ///   - url: The file URL to write to.
    ///   - options: Write options (uses ReadOptions for QoS).
    /// - Throws: ``J2KError`` if writing fails.
    public func write(
        _ data: Data,
        to url: URL,
        options: ReadOptions = ReadOptions()
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let path = url.path
            let queue = DispatchQueue(
                label: "com.j2kswift.asyncio.write",
                qos: options.qos.dispatchQoS
            )

            guard let channel = DispatchIO(
                type: .random,
                path: path,
                oflag: O_WRONLY | O_CREAT | O_TRUNC,
                mode: 0o644,
                queue: queue,
                cleanupHandler: { _ in }
            ) else {
                continuation.resume(throwing: J2KError.internalError("Failed to open file for writing"))
                return
            }

            var writeError: Error?

            data.withUnsafeBytes { buffer in
                let dispatchData = DispatchData(bytes: buffer)

                channel.write(
                    offset: 0,
                    data: dispatchData,
                    queue: queue
                ) { done, _, error in
                    if error != 0 {
                        writeError = J2KError.internalError("Write error: errno \(error)")
                    }

                    if done {
                        channel.close()
                        if let error = writeError {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }
}
