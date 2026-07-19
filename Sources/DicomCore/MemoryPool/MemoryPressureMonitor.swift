import Foundation
import Dispatch

/// Memory pressure monitoring using DispatchSource for automatic buffer pool cleanup.
///
/// **Design Decision: DispatchSource vs NotificationCenter**
///
/// This implementation uses `DispatchSource.makeMemoryPressureSource()` rather than
/// `NotificationCenter` (UIApplication.didReceiveMemoryWarningNotification) because:
///
/// 1. **Platform Independence**: Works on both iOS and macOS through Foundation.
///    The library targets iOS 13+ and macOS 12+, and DispatchSource is available on both.
///
/// 2. **System-Level Integration**: DispatchSource provides direct access to kernel-level
///    memory pressure events with finer granularity (.warning, .critical).
///
/// 3. **Non-UI Context**: The DICOM library operates independently of UI layer, so
///    UIApplication notifications are not available in all contexts (e.g., command-line tools,
///    frameworks, background processes).
///
/// 4. **Lower Latency**: Kernel-level events arrive faster than NotificationCenter messages
///    which must traverse the runloop and notification dispatch queue.
///
/// 5. **Explicit Lifecycle**: DispatchSource provides clear activation/cancellation semantics,
///    making testing and cleanup more predictable.
///
/// **Memory Pressure Response Strategy:**
///
/// - **Warning Level**: Release 50% of pooled buffers (largest first) to free memory while
///   maintaining some performance benefit. This is triggered when the system is under moderate
///   memory pressure but not critical.
///
/// - **Critical Level**: Release all pooled buffers immediately. System is at risk of
///   terminating processes, so we prioritize memory over performance.
///
/// The monitor automatically starts on first access to `shared` singleton and continues
/// monitoring until explicitly stopped via `stop()`.
///
/// **Usage Example:**
///
/// ```swift
/// // Automatic monitoring (recommended)
/// BufferPool.shared.enableMemoryPressureMonitoring()
///
/// // Or manual control
/// let monitor = MemoryPressureMonitor { level in
///     switch level {
///     case .warning:
///         print("Memory warning - reducing buffer pool")
///         BufferPool.shared.releaseHalf()
///     case .critical:
///         print("Memory critical - clearing buffer pool")
///         BufferPool.shared.clear()
///     }
/// }
/// monitor.start()
/// // Later...
/// monitor.stop()
/// ```
///
/// **Thread Safety:**
/// The monitor is thread-safe and can be started/stopped from any thread. Callbacks are
/// dispatched on a serial queue to ensure handlers don't run concurrently.
final class MemoryPressureMonitor {

    /// Memory pressure level reported by the system.
    enum PressureLevel {
        case warning  // System under moderate memory pressure
        case critical // System critically low on memory, may terminate processes
    }

    /// Callback invoked when memory pressure is detected.
    /// - Parameter level: The severity of memory pressure.
    typealias PressureHandler = (PressureLevel) -> Void

    // MARK: - Private Properties

    private let handler: PressureHandler
    private var source: DispatchSourceMemoryPressure?
    private let queue: DispatchQueue
    private let lock = DicomLock()
    private var isMonitoring: Bool = false

    // MARK: - Initialization

    /// Creates a memory pressure monitor with the specified handler.
    ///
    /// The monitor is not started automatically. Call `start()` to begin monitoring.
    ///
    /// - Parameters:
    ///   - queue: Queue on which to invoke the handler. Defaults to a serial background queue.
    ///   - handler: Closure to invoke when memory pressure is detected.
    init(queue: DispatchQueue? = nil, handler: @escaping PressureHandler) {
        self.handler = handler
        self.queue = queue ?? DispatchQueue(
            label: "com.dicomcore.memorypressure",
            qos: .utility
        )
    }

    // MARK: - Control Methods

    /// Starts monitoring system memory pressure.
    ///
    /// If already monitoring, this is a no-op. Safe to call multiple times.
    ///
    /// **Implementation Note:**
    /// Uses `DispatchSource.MemoryPressure.all` to monitor both warning and critical events.
    /// The source is activated on the specified queue and remains active until `stop()` is called.
    func start() {
        lock.withLock {
            guard !isMonitoring else { return }

            let pressureSource = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: queue
            )

            pressureSource.setEventHandler { [weak self] in
                guard let self = self else { return }

                let event = pressureSource.data

                // Map DispatchSource.MemoryPressure flags to our PressureLevel enum
                if event.contains(.critical) {
                    self.handler(.critical)
                } else if event.contains(.warning) {
                    self.handler(.warning)
                }
            }

            pressureSource.activate()
            self.source = pressureSource
            self.isMonitoring = true
        }
    }

    /// Stops monitoring system memory pressure.
    ///
    /// If not currently monitoring, this is a no-op. Safe to call multiple times.
    ///
    /// **Implementation Note:**
    /// Cancels the dispatch source and releases it. The monitor can be restarted by calling
    /// `start()` again, which will create a new dispatch source.
    func stop() {
        lock.withLock {
            guard isMonitoring else { return }

            source?.cancel()
            source = nil
            isMonitoring = false
        }
    }

    /// Returns whether the monitor is currently active.
    var isActive: Bool {
        lock.withLock { isMonitoring }
    }

    // MARK: - Deinitialization

    deinit {
        // Ensure source is cancelled if still active
        source?.cancel()
    }
}
