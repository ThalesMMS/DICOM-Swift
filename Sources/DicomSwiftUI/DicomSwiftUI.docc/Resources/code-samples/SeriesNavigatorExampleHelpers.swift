import SwiftUI
import DicomSwiftUI
import DicomCore
#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#endif
#if os(macOS)
import AppKit
#endif

var platformSystemBackground: Color {
#if os(iOS) || os(tvOS) || os(visionOS)
    return Color(UIColor.systemBackground)
#elseif os(macOS)
    return Color(NSColor.windowBackgroundColor)
#else
    return Color.secondary
#endif
}

/// Creates file URLs for sample DICOM slices located under the given series path.
///
/// The returned URLs are runnable only when `seriesPath` points to a real directory
/// containing DICOM files named `slice1.dcm`, `slice2.dcm`, and so on.
/// - Parameters:
///   - count: The number of sample slice URLs to generate.
///   - seriesPath: The directory path for the series; a trailing slash, if present, will be removed before composing file URLs.
/// - Returns: An array of file URLs named `slice1.dcm` … `sliceN.dcm` placed under the normalized `seriesPath`. Returns an empty array if `count` is less than or equal to zero.
func makeSampleSliceURLs(count: Int, seriesPath: String) -> [URL] {
    guard count > 0 else { return [] }

    let normalizedPath = seriesPath.hasSuffix("/")
        ? String(seriesPath.dropLast())
        : seriesPath

    return (1...count).map {
        URL(fileURLWithPath: "\(normalizedPath)/slice\($0).dcm")
    }
}

private struct InitialSeriesLoaderModifier: ViewModifier {
    let seriesURLs: [URL]
    @ObservedObject var navigatorVM: SeriesNavigatorViewModel
    @ObservedObject var imageVM: DicomImageViewModel
    let onFirstURL: ((URL) -> Void)?

    /// Attaches an `onAppear` handler to `content` that initializes the series navigator and triggers loading of the first image.
    /// - Parameter content: The view being modified.
    /// - Returns: The modified view that performs series initialization and, if a first URL is available, invokes the optional `onFirstURL` callback and starts loading the first image.
    func body(content: Content) -> some View {
        content.onAppear {
            let didSetSeries = navigatorVM.seriesURLs != seriesURLs
            if didSetSeries {
                navigatorVM.setSeriesURLs(seriesURLs)
            }

            if let firstURL = navigatorVM.currentURL,
               didSetSeries || imageVM.image == nil {
                onFirstURL?(firstURL)
                Task {
                    await imageVM.loadImage(from: firstURL)
                }
            }
        }
    }
}

extension View {
    /// Attaches behavior to the view that initializes the series navigator with the provided URLs and begins loading the first image.
    /// - Parameters:
    ///   - seriesURLs: The list of file URLs representing the image series to set on the navigator.
    ///   - navigatorVM: The series navigator view model that will receive `seriesURLs` and expose the current URL/count.
    ///   - imageVM: The image view model used to start loading the first image from the series.
    ///   - onFirstURL: An optional callback invoked with the first available URL after the navigator is initialized.
    /// - Returns: The view with initial-series loading behavior applied.
    func loadInitialSeries(
        _ seriesURLs: [URL],
        navigatorVM: SeriesNavigatorViewModel,
        imageVM: DicomImageViewModel,
        onFirstURL: ((URL) -> Void)? = nil
    ) -> some View {
        modifier(
            InitialSeriesLoaderModifier(
                seriesURLs: seriesURLs,
                navigatorVM: navigatorVM,
                imageVM: imageVM,
                onFirstURL: onFirstURL
            )
        )
    }
}

struct SeriesInfoBanner: View {
    @ObservedObject var navigatorVM: SeriesNavigatorViewModel
    @Binding var isPresented: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Series Information")
                    .font(.headline)
                Text("\(navigatorVM.totalCount) images")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button("Hide") {
                isPresented = false
            }
            .font(.caption)
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
    }
}

struct SeriesToolbarMenu: View {
    @Binding var showingSeriesInfo: Bool
    @Binding var showingMetadata: Bool

    var body: some View {
        Menu {
            Button(action: { showingSeriesInfo.toggle() }) {
                Label("Series Info", systemImage: "info.circle")
            }

            Button(action: { showingMetadata = true }) {
                Label("Metadata", systemImage: "doc.text")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

struct MetadataSheetContent: View {
    let decoder: DCMDecoder?
    let isLoading: Bool
    let error: Error?
    @Binding var isPresented: Bool

    var body: some View {
        NavigationView {
            Group {
                if let decoder = decoder {
                    MetadataView(decoder: decoder)
                } else if isLoading {
                    ProgressView("Loading metadata...")
                } else if let error = error {
                    Text("Failed to load metadata: \(error.localizedDescription)")
                        .foregroundColor(.red)
                        .padding()
                } else {
                    Text("No metadata available")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Current Image Metadata")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}
