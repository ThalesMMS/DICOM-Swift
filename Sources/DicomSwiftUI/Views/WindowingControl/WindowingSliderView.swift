//
//  WindowingSliderView.swift
//
//  A labeled slider used by the windowing control panel.
//

import SwiftUI

struct WindowingSliderView: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let minLabel: String
    let maxLabel: String
    let accessibilityLabel: String
    let accessibilityUnit: String
    let accessibilityHint: String
    let layout: WindowingControlView.Layout
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(layout == .compact ? .caption2 : .caption)
                .foregroundColor(.secondary)

            HStack {
                Text(minLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)

                Slider(
                    value: $value,
                    in: range,
                    step: step,
                    onEditingChanged: onEditingChanged
                )
                .accentColor(.accentColor)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue("\(Int(value)) \(accessibilityUnit)")
                .accessibilityHint(accessibilityHint)

                Text(maxLabel)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
    }
}
