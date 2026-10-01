import SwiftUI

struct SeriesNavigatorPositionIndicatorView: View {
    let navigatorViewModel: SeriesNavigatorViewModel
    let layout: SeriesNavigatorView.Layout

    var body: some View {
        VStack(spacing: 4) {
            if navigatorViewModel.isEmpty {
                Text("No Series Loaded")
                    .font(layout == .compact ? .caption : .headline)
                    .foregroundColor(.secondary)
                    .accessibilityLabel("No series loaded")
            } else {
                Text(navigatorViewModel.positionString)
                    .font(layout == .compact ? .title3 : .title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                    .monospacedDigit()
                    .accessibilityLabel(
                        "Slice \(navigatorViewModel.currentIndex + 1) of \(navigatorViewModel.totalCount)"
                    )

                if layout == .expanded {
                    Text("\(Int(navigatorViewModel.progressPercentage * 100))% complete")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityLabel(
                            "\(Int(navigatorViewModel.progressPercentage * 100)) percent complete"
                        )
                }
            }
        }
    }
}
