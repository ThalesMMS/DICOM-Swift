//
//  InteractiveImageView.swift
//
//  Interactive image viewer with pan and zoom gestures
//
//  This view provides pan and zoom functionality for any SwiftUI content,
//  particularly useful for medical image viewing where users need to inspect
//  details at different zoom levels and pan across large images.
//
//  The view supports:
//  - Pinch-to-zoom gesture (two-finger pinch)
//  - Pan gesture (drag to move)
//  - Windowing gesture (drag to adjust window/level when enabled)
//  - Double-tap to reset to original position and scale
//  - Simultaneous pan and zoom for fluid interaction
//
//  Platform Availability:
//
//  iOS, visionOS, and macOS 26+ - Built with SwiftUI gesture recognizers.
//
//  Accessibility:
//
//  The view preserves accessibility elements from the wrapped content.
//  Zoom and pan states are maintained across accessibility interactions.
//

import SwiftUI
import DicomCore

/// A SwiftUI view that wraps content with interactive pan and zoom gestures.
///
/// ## Overview
///
/// ``InteractiveImageView`` provides intuitive pan and zoom functionality for any
/// SwiftUI view content. It's particularly useful for medical image viewing where
/// users need to inspect fine details at different magnification levels.
///
/// **Key Features:**
/// - Pinch-to-zoom gesture for scaling (1.0× to 4.0× default range)
/// - Pan/drag gesture for moving around zoomed content
/// - Windowing gesture for adjusting window center and width (optional)
/// - Double-tap to reset to original position and scale
/// - Smooth gesture interactions with state preservation
/// - Works with any SwiftUI content via generic ViewBuilder
/// - Configurable minimum and maximum zoom levels
///
/// **Gesture Behavior:**
/// - Pinch: Two-finger pinch to zoom in/out
/// - Pan: Single-finger drag to move (when windowing disabled)
/// - Windowing: Drag vertically to adjust center, horizontally to adjust width (when enabled)
/// - Double-tap: Reset zoom, position, and windowing to defaults
/// - Simultaneous: Can pan while zooming for fluid navigation
///
/// ## Usage
///
/// Wrap a DicomImageView with interactive gestures:
///
/// ```swift
/// struct ContentView: View {
///     let dicomURL: URL
///
///     var body: some View {
///         InteractiveImageView {
///             DicomImageView(url: dicomURL)
///         }
///         .frame(maxWidth: .infinity, maxHeight: .infinity)
///     }
/// }
/// ```
///
/// Configure custom zoom limits:
///
/// ```swift
/// InteractiveImageView(minScale: 0.5, maxScale: 8.0) {
///     DicomImageView(
///         url: dicomURL,
///         windowingMode: .preset(.lung)
///     )
/// }
/// ```
///
/// Use with any SwiftUI content:
///
/// ```swift
/// InteractiveImageView {
///     Image(systemName: "photo")
///         .resizable()
///         .aspectRatio(contentMode: .fit)
/// }
/// ```
///
/// Enable windowing gesture controls:
///
/// ```swift
/// @State private var windowSettings = WindowSettings(center: 50, width: 400)
///
/// InteractiveImageView(
///     windowSettings: windowSettings,
///     onWindowingChanged: { newSettings in
///         windowSettings = newSettings
///         // Update DICOM image with new windowing
///     }
/// ) {
///     DicomImageView(url: dicomURL)
/// }
/// ```
///
/// ## Topics
///
/// ### Creating a View
///
/// - ``init(minScale:maxScale:content:)``
///
/// ### Gesture Controls
///
/// - Pinch to zoom in and out
/// - Drag to pan across the content (or adjust windowing when enabled)
/// - Double-tap to reset position, zoom, and windowing
///
/// ### Windowing
///
/// - Drag vertically to adjust window center (brightness)
/// - Drag horizontally to adjust window width (contrast)
/// - Automatically enabled when `onWindowingChanged` callback is provided
///
struct InteractiveImageView<Content: View>: View {

    // MARK: - Properties

    /// The content to display with interactive gestures
    private let content: Content

    /// Minimum allowed scale factor (default 1.0)
    private let minScale: CGFloat

    /// Maximum allowed scale factor (default 4.0)
    private let maxScale: CGFloat

    /// Initial window settings for windowing gesture (optional)
    private let initialWindowSettings: WindowSettings?

    /// Callback invoked when windowing values change via gesture (optional)
    private let onWindowingChanged: ((WindowSettings) -> Void)?

    /// Current scale during active gesture
    @State private var currentScale: CGFloat = 1.0

    /// Final scale after gesture completes
    @State private var finalScale: CGFloat = 1.0

    /// Current offset during active gesture
    @State private var currentOffset: CGSize = .zero

    /// Final offset after gesture completes
    @State private var finalOffset: CGSize = .zero

    /// Current window center during windowing gesture
    @State private var currentWindowCenter: Double = 0

    /// Current window width during windowing gesture
    @State private var currentWindowWidth: Double = 0

    /// Final window center after windowing gesture completes
    @State private var finalWindowCenter: Double = 0

    /// Final window width after windowing gesture completes
    @State private var finalWindowWidth: Double = 0

    /// Whether windowing mode is enabled (based on callback presence)
    private var windowingEnabled: Bool {
        onWindowingChanged != nil
    }

    // MARK: - Initializers

    /// Creates an interactive view with pan and zoom gestures.
    ///
    /// Wraps the provided content with gesture recognizers for pinch-to-zoom,
    /// pan/drag, and double-tap reset. The content can be any SwiftUI view.
    ///
    /// When `onWindowingChanged` is provided, drag gestures adjust window center
    /// and width instead of panning. Drag vertically to adjust center (brightness),
    /// horizontally to adjust width (contrast).
    ///
    /// - Parameters:
    ///   - minScale: Minimum zoom scale factor (default 1.0)
    ///   - maxScale: Maximum zoom scale factor (default 4.0)
    ///   - windowSettings: Initial window settings for windowing gesture (optional)
    ///   - onWindowingChanged: Callback invoked when windowing changes (optional)
    ///   - content: SwiftUI view builder providing the content to wrap
    ///
    /// ## Example
    ///
    /// ```swift
    /// // Default zoom limits (1× to 4×)
    /// InteractiveImageView {
    ///     DicomImageView(url: url)
    /// }
    ///
    /// // Custom zoom limits (0.5× to 8×)
    /// InteractiveImageView(minScale: 0.5, maxScale: 8.0) {
    ///     Image("medical-scan")
    ///         .resizable()
    ///         .aspectRatio(contentMode: .fit)
    /// }
    ///
    /// // With windowing gesture controls
    /// InteractiveImageView(
    ///     windowSettings: WindowSettings(center: 50, width: 400),
    ///     onWindowingChanged: { settings in
    ///         // Update image with new windowing
    ///     }
    /// ) {
    ///     DicomImageView(url: url)
    /// }
    /// ```
    ///
    init(
        minScale: CGFloat = 1.0,
        maxScale: CGFloat = 4.0,
        windowSettings: WindowSettings? = nil,
        onWindowingChanged: ((WindowSettings) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.minScale = minScale
        self.maxScale = maxScale
        self.initialWindowSettings = windowSettings
        self.onWindowingChanged = onWindowingChanged
        self.content = content()

        // Initialize windowing state if provided
        if let settings = windowSettings {
            _finalWindowCenter = State(initialValue: settings.center)
            _finalWindowWidth = State(initialValue: settings.width)
        }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            if windowingEnabled {
                content
                    .scaleEffect(finalScale * currentScale)
                    .offset(x: finalOffset.width + currentOffset.width,
                           y: finalOffset.height + currentOffset.height)
                    .gesture(magnificationGesture)
                    .simultaneousGesture(windowingGesture)
                    .gesture(doubleTapGesture)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Interactive image viewer")
                    .accessibilityHint("Pinch to zoom, drag to adjust windowing, double-tap to reset")
            } else {
                content
                    .scaleEffect(finalScale * currentScale)
                    .offset(x: finalOffset.width + currentOffset.width,
                           y: finalOffset.height + currentOffset.height)
                    .gesture(magnificationGesture)
                    .simultaneousGesture(dragGesture)
                    .gesture(doubleTapGesture)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Interactive image viewer")
                    .accessibilityHint("Pinch to zoom, drag to pan, double-tap to reset")
            }
        }
    }

    // MARK: - Gestures

    /// Magnification gesture for pinch-to-zoom
    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                // Update current scale during gesture
                currentScale = value
            }
            .onEnded { value in
                // Finalize scale and clamp to min/max bounds
                let newScale = finalScale * value
                finalScale = min(max(newScale, minScale), maxScale)
                currentScale = 1.0
            }
    }

    /// Drag gesture for panning
    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Update current offset during gesture
                currentOffset = CGSize(
                    width: value.translation.width,
                    height: value.translation.height
                )
            }
            .onEnded { value in
                // Finalize offset
                finalOffset = CGSize(
                    width: finalOffset.width + value.translation.width,
                    height: finalOffset.height + value.translation.height
                )
                currentOffset = .zero
            }
    }

    /// Windowing gesture for adjusting window center and width
    ///
    /// Medical imaging convention:
    /// - Drag vertically: adjust window center (up = brighter, down = darker)
    /// - Drag horizontally: adjust window width (right = wider, left = narrower)
    private var windowingGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                // Sensitivity factor: pixels of drag per unit of window change
                let sensitivity: CGFloat = 1.5

                // Vertical drag adjusts center (inverted: up = increase center)
                let centerDelta = -Double(value.translation.height) * Double(sensitivity)
                currentWindowCenter = centerDelta

                // Horizontal drag adjusts width (right = increase width)
                let widthDelta = Double(value.translation.width) * Double(sensitivity)
                currentWindowWidth = widthDelta
            }
            .onEnded { value in
                // Finalize windowing values
                let sensitivity: CGFloat = 1.5

                let centerDelta = -Double(value.translation.height) * Double(sensitivity)
                let widthDelta = Double(value.translation.width) * Double(sensitivity)

                finalWindowCenter += centerDelta
                finalWindowWidth += widthDelta

                // Clamp width to positive values (minimum 1)
                finalWindowWidth = max(finalWindowWidth, 1.0)

                // Reset current deltas
                currentWindowCenter = 0
                currentWindowWidth = 0

                // Notify callback of new windowing settings
                let newSettings = WindowSettings(
                    center: finalWindowCenter,
                    width: finalWindowWidth
                )
                onWindowingChanged?(newSettings)
            }
    }

    /// Double-tap gesture to reset zoom and position
    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                withAnimation(.easeInOut(duration: 0.3)) {
                    resetTransform()
                }
            }
    }

    // MARK: - Helper Methods

    /// Resets zoom, pan, and windowing to original state
    private func resetTransform() {
        currentScale = 1.0
        finalScale = 1.0
        currentOffset = .zero
        finalOffset = .zero

        // Reset windowing to initial values if enabled
        if windowingEnabled, let settings = initialWindowSettings {
            finalWindowCenter = settings.center
            finalWindowWidth = settings.width
            currentWindowCenter = 0
            currentWindowWidth = 0

            // Notify callback of reset windowing
            onWindowingChanged?(settings)
        }
    }
}

// MARK: - SwiftUI Previews

#if DEBUG
struct InteractiveImageView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            // Basic usage with placeholder
            InteractiveImageView {
                VStack {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 100))
                        .foregroundColor(.blue)

                    Text("Pinch to zoom, drag to pan")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .previewDisplayName("Basic - Placeholder")

            // With custom zoom limits
            InteractiveImageView(minScale: 0.5, maxScale: 8.0) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 200, height: 300)
                    .overlay(
                        Text("Zoom: 0.5× - 8.0×")
                            .foregroundColor(.white)
                            .font(.headline)
                    )
            }
            .previewDisplayName("Custom Zoom Limits")

            // Simulated medical image
            InteractiveImageView {
                ZStack {
                    Color.black

                    VStack(spacing: 20) {
                        Text("Medical Image Placeholder")
                            .foregroundColor(.white)
                            .font(.title2)

                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.gray, .white, .gray],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 300, height: 300)
                            .cornerRadius(10)

                        Text("Double-tap to reset")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }
            .previewDisplayName("Simulated Medical Image")

            // Different aspect ratios
            InteractiveImageView {
                Rectangle()
                    .fill(Color.green.opacity(0.3))
                    .overlay(
                        Text("Wide Image\n16:9")
                            .multilineTextAlignment(.center)
                    )
                    .frame(width: 400, height: 225)
            }
            .previewDisplayName("Wide Aspect Ratio")

            InteractiveImageView {
                Rectangle()
                    .fill(Color.orange.opacity(0.3))
                    .overlay(
                        Text("Tall Image\n9:16")
                            .multilineTextAlignment(.center)
                    )
                    .frame(width: 225, height: 400)
            }
            .previewDisplayName("Tall Aspect Ratio")

            // With windowing gesture controls
            WindowingPreviewWrapper()
                .previewDisplayName("Windowing Gestures")
        }
    }
}

// MARK: - Windowing Preview Helper

#if DEBUG
/// Helper view for previewing windowing gesture functionality
private struct WindowingPreviewWrapper: View {
    @State private var windowSettings = WindowSettings(center: 128, width: 256)

    var body: some View {
        VStack(spacing: 0) {
            // Image with windowing gestures
            InteractiveImageView(
                windowSettings: windowSettings,
                onWindowingChanged: { newSettings in
                    windowSettings = newSettings
                }
            ) {
                ZStack {
                    // Simulated grayscale medical image
                    LinearGradient(
                        colors: [.black, .gray, .white],
                        startPoint: .leading,
                        endPoint: .trailing
                    )

                    VStack(spacing: 12) {
                        Text("Windowing Enabled")
                            .foregroundColor(.white)
                            .font(.headline)
                            .shadow(color: .black, radius: 2)

                        Text("Drag to adjust")
                            .foregroundColor(.white)
                            .font(.caption)
                            .shadow(color: .black, radius: 2)
                    }
                }
            }
            .frame(height: 300)

            // Display current windowing values
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Window Center:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f", windowSettings.center))
                        .font(.caption.monospaced())
                }

                HStack {
                    Text("Window Width:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(String(format: "%.1f", windowSettings.width))
                        .font(.caption.monospaced())
                }

                Divider()

                Text("↕️ Drag vertically to adjust center (brightness)")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text("↔️ Drag horizontally to adjust width (contrast)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding()
            #if os(iOS)
            .background(Color(.systemBackground))
            #else
            .background(Color(NSColor.windowBackgroundColor))
            #endif
        }
    }
}
#endif
#endif
