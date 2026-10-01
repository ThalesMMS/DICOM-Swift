import SwiftUI

struct SeriesNavigatorSliderView: View {
    @ObservedObject var navigatorViewModel: SeriesNavigatorViewModel
    let layout: SeriesNavigatorView.Layout

    @Binding var tempSliderValue: Double
    @Binding var isEditingSlider: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Slice Navigation")
                .font(layout == .compact ? .caption2 : .caption)
                .foregroundColor(.secondary)

            HStack {
                Text("1")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)

                Slider(
                    value: $tempSliderValue,
                    in: 0...Double(max(0, navigatorViewModel.totalCount - 1)),
                    step: 1.0,
                    onEditingChanged: { editing in
                        isEditingSlider = editing
                        if !editing {
                            navigatorViewModel.goToIndex(Int(tempSliderValue))
                        }
                    }
                )
                .accentColor(.accentColor)
                .accessibilityLabel("Slice navigation slider")
                .accessibilityValue("Slice \(Int(tempSliderValue) + 1) of \(navigatorViewModel.totalCount)")
                .accessibilityHint("Swipe up or down to navigate directly to any slice in the series")

                Text("\(navigatorViewModel.totalCount)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
                    .accessibilityHidden(true)
            }
        }
    }
}
