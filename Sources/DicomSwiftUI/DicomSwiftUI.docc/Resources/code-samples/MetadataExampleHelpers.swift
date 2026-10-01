import SwiftUI
import DicomCore
#if os(iOS) || os(visionOS)
import UIKit
#endif

@MainActor
final class AsyncDecoderLoader: ObservableObject {
    @Published var decoder: DCMDecoder?
    @Published var error: Error?
    @Published var isLoading = false

    var loadError: String? {
        error?.localizedDescription
    }

    /// Loads a `DCMDecoder` from the provided filesystem path and updates the loader's published state.
    /// The method clears any previous decoder and error, sets `isLoading` while the load is in progress, assigns `decoder` on success, and assigns `error` on failure.
    /// - Parameters:
    ///   - filePath: The filesystem path of the DICOM file to load.
    func load(filePath: String) async {
        decoder = nil
        error = nil
        isLoading = true

        do {
            decoder = try await DCMDecoder(contentsOfFile: filePath)
            isLoading = false
        } catch {
            decoder = nil
            self.error = error
            isLoading = false
        }
    }

    /// Loads a `DCMDecoder` from the file at the given URL and updates the loader's published state (`decoder`, `error`, `isLoading`).
    /// - Parameter url: The file URL whose path will be used to load the decoder; on success `decoder` is set, on failure `error` is set and `decoder` is cleared.
    func load(url: URL) async {
        await load(filePath: url.path)
    }

    /// Clears the loader's state by removing any loaded decoder and error, and marks loading as not in progress.
    func reset() {
        decoder = nil
        error = nil
        isLoading = false
    }
}

struct DecoderLoadingView<Content: View>: View {
    @ObservedObject var loader: AsyncDecoderLoader
    let loadingText: String
    let errorPrefix: String
    let content: (DCMDecoder) -> Content

    init(
        loader: AsyncDecoderLoader,
        loadingText: String = "Loading metadata...",
        errorPrefix: String = "Error loading metadata",
        @ViewBuilder content: @escaping (DCMDecoder) -> Content
    ) {
        self.loader = loader
        self.loadingText = loadingText
        self.errorPrefix = errorPrefix
        self.content = content
    }

    var body: some View {
        Group {
            if let decoder = loader.decoder {
                content(decoder)
            } else if let loadError = loader.loadError {
                Text("\(errorPrefix): \(loadError)")
                    .multilineTextAlignment(.center)
                    .padding()
            } else if loader.isLoading {
                ProgressView(loadingText)
            } else {
                EmptyView()
            }
        }
    }
}

struct MetadataRow: View {
    let label: String
    let value: String
    var valueColor: Color = .secondary

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundColor(valueColor)
        }
    }
}

#if os(iOS) || os(visionOS)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    init(items: [Any]) {
        self.items = items
    }

    /// Create a UIActivityViewController configured with the view's activity items.
    /// - Parameters:
    ///   - context: Context provided by `UIViewControllerRepresentable` containing environment and coordinator.
    /// Creates and returns a UIActivityViewController configured with the provided activity items.
    /// Creates and returns a UIActivityViewController configured with the view's activity items.
    /// - Returns: A `UIActivityViewController` initialized with `items` and no application activities.
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    /// Updates the presented `UIActivityViewController` to reflect any changed SwiftUI state.
    /// - Parameters:
    ///   - uiViewController: The activity view controller instance managed by this representable.
    ///   - context: Contextual information about the representable's update cycle.
    /// No-op update; the activity view controller does not require runtime updates.
/// - Parameters:
///   - uiViewController: The `UIActivityViewController` instance managed by SwiftUI.
///   - context: Context provided by SwiftUI for updates; unused.
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#else
struct ShareSheet: View {
    let items: [Any]

    init(items: [Any]) {
        self.items = items
    }

    var body: some View {
        Text("Sharing is unavailable on this platform.")
            .padding()
    }
}
#endif
