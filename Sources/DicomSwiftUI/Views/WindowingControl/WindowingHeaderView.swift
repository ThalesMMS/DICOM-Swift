//
//  WindowingHeaderView.swift
//
//  Displays current window/level preset name and numeric values.
//

import SwiftUI

struct WindowingHeaderView: View {
    let presetName: String
    let center: Double
    let width: Double
    let layout: WindowingControlView.Layout

    var body: some View {
        VStack(spacing: 4) {
            Text(presetName)
                .font(layout == .compact ? .caption : .headline)
                .foregroundColor(.primary)
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: layout == .compact ? 8 : 12) {
                Text("C: \(Int(center))")
                    .font(layout == .compact ? .caption2 : .caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Text("W: \(Int(width))")
                    .font(layout == .compact ? .caption2 : .caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Center \(Int(center)), Width \(Int(width))")
        }
    }
}
