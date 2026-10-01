//
//  WindowingPresetButtonsView.swift
//
//  Scrollable row of windowing preset buttons.
//

import SwiftUI
import DicomCore

struct WindowingPresetButtonsView: View {
    let presets: [MedicalPreset]
    let selectedPreset: MedicalPreset?
    let layout: WindowingControlView.Layout
    let onSelectPreset: (MedicalPreset) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: layout == .compact ? 6 : 8) {
                ForEach(presets, id: \.self) { preset in
                    WindowingPresetButton(
                        preset: preset,
                        isSelected: selectedPreset == preset,
                        layout: layout,
                        action: { onSelectPreset(preset) }
                    )
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Window presets")
    }
}
