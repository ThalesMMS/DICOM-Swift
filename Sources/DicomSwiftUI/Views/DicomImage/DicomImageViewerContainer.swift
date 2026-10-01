import SwiftUI
import DicomCore

struct DicomImageViewerContainer: View {
    @EnvironmentObject private var viewModel: DicomImageViewModel

    let state: DicomImageLoadingState

    var body: some View {
        ZStack {
            Color.black
                .modifier(FullScreenBackgroundModifier())
                .accessibilityHidden(true)

            switch state {
            case .idle:
                DicomImageIdleStateView()

            case .loading:
                DicomImageLoadingStateView()

            case .loaded:
                DicomImageLoadedStateView(
                    image: viewModel.image,
                    imageWidth: viewModel.imageWidth,
                    imageHeight: viewModel.imageHeight
                )

            case .failed(let error):
                DicomImageErrorStateView(error: error)
            }
        }
    }
}
