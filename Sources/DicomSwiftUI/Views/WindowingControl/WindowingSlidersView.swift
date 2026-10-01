//
//  WindowingSlidersView.swift
//
//  Center/width slider section for windowing controls.
//

import SwiftUI

struct WindowingSlidersView: View {
    let layout: WindowingControlView.Layout
    let accessibilityUnit: String

    @Binding var tempCenter: Double
    @Binding var tempWidth: Double

    @Binding var isEditingCenter: Bool
    @Binding var isEditingWidth: Bool

    let onCommit: () -> Void

    var body: some View {
        VStack(spacing: layout == .compact ? 8 : 12) {
            WindowingSliderView(
                title: "Center (Level)",
                value: $tempCenter,
                range: -1000...3000,
                step: 1.0,
                minLabel: "-1000",
                maxLabel: "3000",
                accessibilityLabel: "Window center slider",
                accessibilityUnit: accessibilityUnit,
                accessibilityHint: "Swipe up or down to adjust window center. Range is -1000 to 3000 \(accessibilityUnit)",
                layout: layout,
                onEditingChanged: { editing in
                    isEditingCenter = editing
                    if !editing { onCommit() }
                }
            )

            WindowingSliderView(
                title: "Width",
                value: $tempWidth,
                range: 1...4000,
                step: 1.0,
                minLabel: "1",
                maxLabel: "4000",
                accessibilityLabel: "Window width slider",
                accessibilityUnit: accessibilityUnit,
                accessibilityHint: "Swipe up or down to adjust window width. Range is 1 to 4000 \(accessibilityUnit)",
                layout: layout,
                onEditingChanged: { editing in
                    isEditingWidth = editing
                    if !editing { onCommit() }
                }
            )
        }
    }
}
