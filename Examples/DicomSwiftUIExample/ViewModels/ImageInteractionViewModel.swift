//
//  ImageInteractionViewModel.swift
//  DicomSwiftUIExample
//
//  ViewModel for managing image interaction gestures (pan, zoom, rotation)
//
//  This view model provides a SwiftUI-friendly interface for interactive image
//  manipulation in medical imaging viewers. It manages pan (translation), zoom
//  (magnification), and rotation transformations, supporting both discrete gestures
//  (pinch-to-zoom, two-finger rotation) and combined interactions.
//
//  The view model maintains reactive state via @Published properties, enabling
//  automatic UI updates when transformations change. It provides methods for
//  gesture handling, preset zoom levels, and reset functionality.
//
//  Thread Safety:
//
//  All methods marked with @MainActor run on the main thread, ensuring UI
//  updates are safe. The view model is designed for single-threaded access
//  from SwiftUI views.
//
//  Usage Patterns:
//
//  Use this view model in conjunction with DicomImageViewModel to provide
//  interactive pan/zoom/rotation controls. The interaction view model manages
//  transformations, while the image view model handles DICOM loading and rendering.
//

import Foundation
import SwiftUI
import Combine
import OSLog

// MARK: - View Model

/// View model for managing image interaction gestures and transformations.
///
/// ## Overview
///
/// ``ImageInteractionViewModel`` provides reactive state management for interactive
/// image manipulation in medical imaging applications. It manages pan (translation),
/// zoom (magnification), and rotation transformations through gesture handling and
/// programmatic APIs.
///
/// The view model is designed to work seamlessly with ``DicomImageViewModel`` and
/// SwiftUI's gesture modifiers, providing a clean separation between image loading/rendering
/// and user interaction. This enables flexible UI architectures where interaction
/// controls are decoupled from image display.
///
/// **Key Features:**
/// - Reactive state with `@Published` properties
/// - Pan (translation) with configurable limits
/// - Zoom (scale) with min/max constraints and preset levels
/// - Optional rotation support
/// - Combined gesture handling (simultaneous pan + zoom)
/// - Reset to default view
/// - Fit-to-view and actual-size presets
/// - Thread-safe operations with main actor isolation
///
/// ## Usage
///
/// Basic usage with pan and zoom gestures:
///
/// ```swift
/// struct InteractiveImageView: View {
///     @StateObject private var interactionVM = ImageInteractionViewModel()
///     @StateObject private var imageVM = DicomImageViewModel()
///
///     var body: some View {
///         if let image = imageVM.image {
///             Image(decorative: image, scale: 1.0)
///                 .resizable()
///                 .aspectRatio(contentMode: .fit)
///                 .scaleEffect(interactionVM.scale)
///                 .offset(interactionVM.offset)
///                 .rotationEffect(interactionVM.rotation)
///                 .gesture(dragGesture)
///                 .gesture(magnificationGesture)
///                 .gesture(rotationGesture)
///         }
///     }
///
///     var dragGesture: some Gesture {
///         DragGesture()
///             .onChanged { value in
///                 interactionVM.updatePan(translation: value.translation)
///             }
///             .onEnded { _ in
///                 interactionVM.endPan()
///             }
///     }
///
///     var magnificationGesture: some Gesture {
///         MagnificationGesture()
///             .onChanged { value in
///                 interactionVM.updateZoom(scale: value)
///             }
///             .onEnded { _ in
///                 interactionVM.endZoom()
///             }
///     }
///
///     var rotationGesture: some Gesture {
///         RotationGesture()
///             .onChanged { value in
///                 interactionVM.updateRotation(angle: value)
///             }
///             .onEnded { _ in
///                 interactionVM.endRotation()
///             }
///     }
/// }
/// ```
///
/// Preset zoom levels:
///
/// ```swift
/// @StateObject private var interactionVM = ImageInteractionViewModel()
///
/// var body: some View {
///     VStack {
///         // Image display
///         // ...
///
///         // Zoom controls
///         HStack {
///             Button("Fit") {
///                 interactionVM.fitToView()
///             }
///
///             Button("100%") {
///                 interactionVM.setZoom(to: 1.0)
///             }
///
///             Button("200%") {
///                 interactionVM.setZoom(to: 2.0)
///             }
///
///             Button("Reset") {
///                 interactionVM.reset()
///             }
///         }
///     }
/// }
/// ```
///
/// Combined pan and zoom with SimultaneousGesture:
///
/// ```swift
/// @StateObject private var interactionVM = ImageInteractionViewModel()
///
/// var body: some View {
///     Image(...)
///         .scaleEffect(interactionVM.scale)
///         .offset(interactionVM.offset)
///         .gesture(
///             SimultaneousGesture(
///                 DragGesture()
///                     .onChanged { interactionVM.updatePan(translation: $0.translation) }
///                     .onEnded { _ in interactionVM.endPan() },
///                 MagnificationGesture()
///                     .onChanged { interactionVM.updateZoom(scale: $0) }
///                     .onEnded { _ in interactionVM.endZoom() }
///             )
///         )
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a View Model
///
/// - ``init()``
/// - ``init(minScale:maxScale:enableRotation:)``
///
/// ### Pan Gestures
///
/// - ``updatePan(translation:)``
/// - ``setPan(offset:)``
/// - ``endPan()``
///
/// ### Zoom Gestures
///
/// - ``updateZoom(scale:)``
/// - ``setZoom(to:)``
/// - ``zoomIn()``
/// - ``zoomOut()``
/// - ``fitToView()``
/// - ``endZoom()``
///
/// ### Rotation Gestures
///
/// - ``updateRotation(angle:)``
/// - ``setRotation(angle:)``
/// - ``endRotation()``
///
/// ### Reset and State
///
/// - ``reset()``
/// - ``resetPan()``
/// - ``resetZoom()``
/// - ``resetRotation()``
///
/// ### State Properties
///
/// - ``offset``
/// - ``scale``
/// - ``rotation``
/// - ``isInteracting``
/// - ``isPanning``
/// - ``isZooming``
/// - ``isRotating``
///
/// ### Configuration Properties
///
/// - ``minScale``
/// - ``maxScale``
/// - ``enableRotation``
///
/// ### Computed Properties
///
/// - ``isAtMinZoom``
/// - ``isAtMaxZoom``
/// - ``isAtDefaultView``
/// - ``currentZoomPercent``
///
@MainActor
public final class ImageInteractionViewModel: ObservableObject {

    // MARK: - Published Properties

    /// Current pan offset (translation) in points
    @Published public private(set) var offset: CGSize = .zero

    /// Current zoom scale (1.0 = 100%, 2.0 = 200%, etc.)
    @Published public private(set) var scale: CGFloat = 1.0

    /// Current rotation angle in radians
    @Published public private(set) var rotation: Angle = .zero

    /// Whether user is currently interacting with any gesture
    @Published public private(set) var isInteracting: Bool = false

    /// Whether user is currently panning
    @Published public private(set) var isPanning: Bool = false

    /// Whether user is currently zooming
    @Published public private(set) var isZooming: Bool = false

    /// Whether user is currently rotating
    @Published public private(set) var isRotating: Bool = false

    // MARK: - Public Configuration Properties

    /// Minimum allowed zoom scale (default: 0.5 = 50%)
    public let minScale: CGFloat

    /// Maximum allowed zoom scale (default: 10.0 = 1000%)
    public let maxScale: CGFloat

    /// Whether rotation gestures are enabled (default: false)
    public let enableRotation: Bool

    // MARK: - Private Properties

    private let logger: Logger

    // Gesture start states
    private var panStartOffset: CGSize?
    private var zoomStartScale: CGFloat?
    private var rotationStartAngle: Angle?

    // MARK: - Initialization

    /// Creates a new image interaction view model with default settings.
    ///
    /// Initializes the view model with default zoom limits (0.5x to 10x) and
    /// rotation disabled. The view starts at default position (no pan, 1.0x zoom,
    /// no rotation).
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct MyView: View {
    ///     @StateObject private var interactionVM = ImageInteractionViewModel()
    ///
    ///     var body: some View {
    ///         // Use interactionVM here
    ///     }
    /// }
    /// ```
    ///
    public init() {
        self.minScale = 0.5
        self.maxScale = 10.0
        self.enableRotation = false
        self.logger = Logger(subsystem: "com.dicomswiftui.example", category: "ImageInteractionViewModel")
        logger.info("🖼️ ImageInteractionViewModel initialized with defaults")
    }

    /// Creates a new image interaction view model with custom settings.
    ///
    /// Initializes the view model with custom zoom limits and rotation configuration.
    /// The view starts at default position (no pan, 1.0x zoom, no rotation).
    ///
    /// - Parameters:
    ///   - minScale: Minimum allowed zoom scale (must be greater than 0)
    ///   - maxScale: Maximum allowed zoom scale (must be greater than minScale)
    ///   - enableRotation: Whether to enable rotation gestures
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Custom zoom range with rotation enabled
    /// let interactionVM = ImageInteractionViewModel(
    ///     minScale: 0.25,
    ///     maxScale: 20.0,
    ///     enableRotation: true
    /// )
    /// ```
    ///
    public init(minScale: CGFloat = 0.5, maxScale: CGFloat = 10.0, enableRotation: Bool = false) {
        self.minScale = max(0.01, minScale)  // Ensure minScale is positive
        self.maxScale = max(self.minScale, maxScale)  // Ensure maxScale >= minScale
        self.enableRotation = enableRotation
        self.logger = Logger(subsystem: "com.dicomswiftui.example", category: "ImageInteractionViewModel")
        logger.info("🖼️ ImageInteractionViewModel initialized: minScale=\(self.minScale), maxScale=\(self.maxScale), rotation=\(enableRotation)")
    }

    // MARK: - Public Interface - Pan Gestures

    /// Updates pan position during drag gesture.
    ///
    /// Applies the specified translation to the pan offset. This method is designed
    /// for use in `.onChanged` handlers of `DragGesture`. The translation is relative
    /// to the drag start position (captured automatically on first call).
    ///
    /// If panning hasn't been started, this method automatically initializes the
    /// baseline offset.
    ///
    /// - Parameter translation: The translation value from `DragGesture`
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var interactionVM = ImageInteractionViewModel()
    ///
    /// var body: some View {
    ///     Image(...)
    ///         .offset(interactionVM.offset)
    ///         .gesture(
    ///             DragGesture()
    ///                 .onChanged { value in
    ///                     interactionVM.updatePan(translation: value.translation)
    ///                 }
    ///                 .onEnded { _ in
    ///                     interactionVM.endPan()
    ///                 }
    ///         )
    /// }
    /// ```
    ///
    public func updatePan(translation: CGSize) {
        // Auto-start panning if not already started
        if !isPanning {
            panStartOffset = offset
            isPanning = true
            updateInteractionState()
            logger.debug("👆 Started panning")
        }

        guard let baseOffset = panStartOffset else { return }

        // Apply translation relative to start position
        let newOffset = CGSize(
            width: baseOffset.width + translation.width,
            height: baseOffset.height + translation.height
        )

        offset = newOffset
        logger.debug("🖐️ Panning: offset=(\(newOffset.width), \(newOffset.height))")
    }

    /// Sets pan offset directly.
    ///
    /// Updates the pan offset to the specified value. This method is useful for
    /// programmatic control or implementing custom pan behaviors.
    ///
    /// - Parameter offset: The new offset value
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var interactionVM = ImageInteractionViewModel()
    ///
    /// // Center image programmatically
    /// Button("Center") {
    ///     interactionVM.setPan(offset: .zero)
    /// }
    /// ```
    ///
    public func setPan(offset: CGSize) {
        logger.debug("🎯 Setting pan offset: (\(offset.width), \(offset.height))")
        self.offset = offset
    }

    /// Ends the current pan gesture.
    ///
    /// Finalizes the pan session and clears the baseline offset. Call this when the
    /// drag gesture ends (e.g., in `.onEnded`).
    ///
    public func endPan() {
        guard isPanning else { return }

        logger.debug("✋ Ending pan gesture")
        isPanning = false
        panStartOffset = nil
        updateInteractionState()
    }

    /// Resets pan to default position (zero offset).
    ///
    /// Clears the current pan offset, centering the image in its container.
    ///
    public func resetPan() {
        logger.info("🔄 Resetting pan offset")
        offset = .zero
        isPanning = false
        panStartOffset = nil
        updateInteractionState()
    }

    // MARK: - Public Interface - Zoom Gestures

    /// Updates zoom scale during magnification gesture.
    ///
    /// Applies the specified scale factor to the current zoom. This method is designed
    /// for use in `.onChanged` handlers of `MagnificationGesture`. The scale is relative
    /// to the zoom start position (captured automatically on first call).
    ///
    /// The resulting scale is clamped between `minScale` and `maxScale`.
    ///
    /// - Parameter scale: The scale value from `MagnificationGesture`
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var interactionVM = ImageInteractionViewModel()
    ///
    /// var body: some View {
    ///     Image(...)
    ///         .scaleEffect(interactionVM.scale)
    ///         .gesture(
    ///             MagnificationGesture()
    ///                 .onChanged { value in
    ///                     interactionVM.updateZoom(scale: value)
    ///                 }
    ///                 .onEnded { _ in
    ///                     interactionVM.endZoom()
    ///                 }
    ///         )
    /// }
    /// ```
    ///
    public func updateZoom(scale: CGFloat) {
        // Auto-start zooming if not already started
        if !isZooming {
            zoomStartScale = self.scale
            isZooming = true
            updateInteractionState()
            logger.debug("🔍 Started zooming")
        }

        guard let baseScale = zoomStartScale else { return }

        // Apply scale relative to start position, clamped to limits
        let newScale = min(max(baseScale * scale, minScale), maxScale)

        self.scale = newScale
        logger.debug("🔎 Zooming: scale=\(newScale) (\(Int(newScale * 100))%)")
    }

    /// Sets zoom scale directly.
    ///
    /// Updates the zoom scale to the specified value, clamped between `minScale`
    /// and `maxScale`. This method is useful for implementing preset zoom levels
    /// (e.g., fit-to-view, 100%, 200%).
    ///
    /// - Parameter scale: The new scale value (1.0 = 100%)
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var interactionVM = ImageInteractionViewModel()
    ///
    /// HStack {
    ///     Button("50%") { interactionVM.setZoom(to: 0.5) }
    ///     Button("100%") { interactionVM.setZoom(to: 1.0) }
    ///     Button("200%") { interactionVM.setZoom(to: 2.0) }
    /// }
    /// ```
    ///
    public func setZoom(to scale: CGFloat) {
        let clampedScale = min(max(scale, minScale), maxScale)
        logger.info("🎯 Setting zoom: \(Int(clampedScale * 100))%")
        self.scale = clampedScale
    }

    /// Increases zoom by 50% (capped at maxScale).
    ///
    public func zoomIn() {
        let newScale = min(scale * 1.5, maxScale)
        logger.info("➕ Zooming in: \(Int(self.scale * 100))% → \(Int(newScale * 100))%")
        scale = newScale
    }

    /// Decreases zoom by 33% (capped at minScale).
    ///
    public func zoomOut() {
        let newScale = max(scale / 1.5, minScale)
        logger.info("➖ Zooming out: \(Int(self.scale * 100))% → \(Int(newScale * 100))%")
        scale = newScale
    }

    /// Resets zoom to fit-to-view (1.0x scale).
    ///
    /// This is a convenience method that sets scale to 1.0, which typically
    /// corresponds to fitting the image to the available view space when using
    /// `.aspectRatio(contentMode: .fit)`.
    ///
    public func fitToView() {
        logger.info("📐 Fitting to view")
        scale = 1.0
    }

    /// Ends the current zoom gesture.
    ///
    /// Finalizes the zoom session and clears the baseline scale. Call this when the
    /// magnification gesture ends (e.g., in `.onEnded`).
    ///
    public func endZoom() {
        guard isZooming else { return }

        logger.debug("✋ Ending zoom gesture")
        isZooming = false
        zoomStartScale = nil
        updateInteractionState()
    }

    /// Resets zoom to default scale (1.0).
    ///
    public func resetZoom() {
        logger.info("🔄 Resetting zoom")
        scale = 1.0
        isZooming = false
        zoomStartScale = nil
        updateInteractionState()
    }

    // MARK: - Public Interface - Rotation Gestures

    /// Updates rotation angle during rotation gesture.
    ///
    /// Applies the specified rotation angle. This method is designed for use in
    /// `.onChanged` handlers of `RotationGesture`. The angle is relative to the
    /// rotation start position (captured automatically on first call).
    ///
    /// This method only works if `enableRotation` is true.
    ///
    /// - Parameter angle: The rotation angle from `RotationGesture`
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var interactionVM = ImageInteractionViewModel(enableRotation: true)
    ///
    /// var body: some View {
    ///     Image(...)
    ///         .rotationEffect(interactionVM.rotation)
    ///         .gesture(
    ///             RotationGesture()
    ///                 .onChanged { value in
    ///                     interactionVM.updateRotation(angle: value)
    ///                 }
    ///                 .onEnded { _ in
    ///                     interactionVM.endRotation()
    ///                 }
    ///         )
    /// }
    /// ```
    ///
    public func updateRotation(angle: Angle) {
        guard enableRotation else { return }

        // Auto-start rotating if not already started
        if !isRotating {
            rotationStartAngle = rotation
            isRotating = true
            updateInteractionState()
            logger.debug("🔄 Started rotating")
        }

        guard let baseAngle = rotationStartAngle else { return }

        // Apply rotation relative to start position
        let newRotation = Angle(degrees: baseAngle.degrees + angle.degrees)

        rotation = newRotation
        logger.debug("↪️ Rotating: angle=\(newRotation.degrees)°")
    }

    /// Sets rotation angle directly.
    ///
    /// Updates the rotation to the specified angle. This method is useful for
    /// implementing preset rotations (e.g., 90°, 180°).
    ///
    /// This method only works if `enableRotation` is true.
    ///
    /// - Parameter angle: The new rotation angle
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var interactionVM = ImageInteractionViewModel(enableRotation: true)
    ///
    /// HStack {
    ///     Button("90°") { interactionVM.setRotation(angle: .degrees(90)) }
    ///     Button("180°") { interactionVM.setRotation(angle: .degrees(180)) }
    ///     Button("270°") { interactionVM.setRotation(angle: .degrees(270)) }
    /// }
    /// ```
    ///
    public func setRotation(angle: Angle) {
        guard enableRotation else { return }

        logger.info("🎯 Setting rotation: \(angle.degrees)°")
        rotation = angle
    }

    /// Ends the current rotation gesture.
    ///
    /// Finalizes the rotation session and clears the baseline angle. Call this when
    /// the rotation gesture ends (e.g., in `.onEnded`).
    ///
    public func endRotation() {
        guard isRotating else { return }

        logger.debug("✋ Ending rotation gesture")
        isRotating = false
        rotationStartAngle = nil
        updateInteractionState()
    }

    /// Resets rotation to default angle (zero).
    ///
    public func resetRotation() {
        logger.info("🔄 Resetting rotation")
        rotation = .zero
        isRotating = false
        rotationStartAngle = nil
        updateInteractionState()
    }

    // MARK: - Public Interface - Reset

    /// Resets all transformations to default values.
    ///
    /// Resets pan offset to zero, zoom scale to 1.0, and rotation to zero.
    /// This provides a complete reset to the initial view state.
    ///
    /// ## Example
    ///
    /// ```swift
    /// @StateObject private var interactionVM = ImageInteractionViewModel()
    ///
    /// Button("Reset View") {
    ///     interactionVM.reset()
    /// }
    /// ```
    ///
    public func reset() {
        logger.info("🔄 Resetting all transformations")
        offset = .zero
        scale = 1.0
        rotation = .zero
        isPanning = false
        isZooming = false
        isRotating = false
        panStartOffset = nil
        zoomStartScale = nil
        rotationStartAngle = nil
        updateInteractionState()
    }

    // MARK: - Private Methods

    private func updateInteractionState() {
        isInteracting = isPanning || isZooming || isRotating
    }
}

// MARK: - Convenience Computed Properties

extension ImageInteractionViewModel {

    /// Returns true if currently at minimum zoom
    public var isAtMinZoom: Bool {
        return scale <= minScale
    }

    /// Returns true if currently at maximum zoom
    public var isAtMaxZoom: Bool {
        return scale >= maxScale
    }

    /// Returns true if at default view (no transformations)
    public var isAtDefaultView: Bool {
        return offset == .zero && scale == 1.0 && rotation.degrees == 0.0
    }

    /// Current zoom as percentage (e.g., 150 for 1.5x scale)
    public var currentZoomPercent: Int {
        return Int(scale * 100)
    }
}
