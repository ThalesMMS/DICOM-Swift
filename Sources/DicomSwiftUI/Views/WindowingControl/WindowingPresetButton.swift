//
//  WindowingPresetButton.swift
//
//  A single selectable windowing preset button.
//

import SwiftUI
import DicomCore

struct WindowingPresetButton: View {
    let preset: MedicalPreset
    let isSelected: Bool
    let layout: WindowingControlView.Layout
    let action: () -> Void

    var body: some View {
        let buttonBackgroundColor = isSelected ? Color.accentColor : Color.secondary.opacity(0.15)
        let buttonTextColor = isSelected ? Color.white : Color.primary

        Button(action: action) {
            Text(preset.displayName)
                .font(layout == .compact ? .caption : .footnote)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(buttonTextColor)
                .padding(.horizontal, layout == .compact ? 8 : 12)
                .padding(.vertical, layout == .compact ? 4 : 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(buttonBackgroundColor)
                )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(preset.displayName + " preset")
        .accessibilityHint("Double tap to apply \(preset.displayName) window settings")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
