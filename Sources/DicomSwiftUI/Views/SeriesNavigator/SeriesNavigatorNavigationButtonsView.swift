import SwiftUI

struct SeriesNavigatorNavigationButtonsView: View {
    @ObservedObject var navigatorViewModel: SeriesNavigatorViewModel
    let layout: SeriesNavigatorView.Layout

    var body: some View {
        HStack(spacing: layout == .compact ? 8 : 12) {
            Button(action: { navigatorViewModel.goToFirst() }) {
                Label(layout == .compact ? "" : "First", systemImage: "backward.end.fill")
                    .font(layout == .compact ? .body : .headline)
                    .frame(minWidth: layout == .compact ? 0 : 60)
            }
            .buttonStyle(.bordered)
            .disabled(navigatorViewModel.isEmpty || navigatorViewModel.isAtFirst)
            .accessibilityLabel("First slice")
            .accessibilityHint("Jump to first slice in series")

            Button(action: { navigatorViewModel.goToPrevious() }) {
                Label(layout == .compact ? "" : "Previous", systemImage: "chevron.left")
                    .font(layout == .compact ? .body : .headline)
                    .frame(minWidth: layout == .compact ? 0 : 80)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!navigatorViewModel.canGoPrevious)
            .accessibilityLabel("Previous slice")
            .accessibilityHint("Go to previous slice")

            Spacer()

            Button(action: { navigatorViewModel.goToNext() }) {
                Label(layout == .compact ? "" : "Next", systemImage: "chevron.right")
                    .font(layout == .compact ? .body : .headline)
                    .labelStyle(.trailingIcon)
                    .frame(minWidth: layout == .compact ? 0 : 80)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!navigatorViewModel.canGoNext)
            .accessibilityLabel("Next slice")
            .accessibilityHint("Go to next slice")

            Button(action: { navigatorViewModel.goToLast() }) {
                Label(layout == .compact ? "" : "Last", systemImage: "forward.end.fill")
                    .font(layout == .compact ? .body : .headline)
                    .labelStyle(.trailingIcon)
                    .frame(minWidth: layout == .compact ? 0 : 60)
            }
            .buttonStyle(.bordered)
            .disabled(navigatorViewModel.isEmpty || navigatorViewModel.isAtLast)
            .accessibilityLabel("Last slice")
            .accessibilityHint("Jump to last slice in series")
        }
    }
}
