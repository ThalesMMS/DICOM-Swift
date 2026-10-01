import SwiftUI
import DicomCore

struct DicomImageIdleStateView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Ready to load DICOM image")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No image loaded")
        .accessibilityHint("Waiting for DICOM file to load")
    }
}

struct DicomImageLoadingStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
                .progressViewStyle(CircularProgressViewStyle())

            Text("Loading DICOM image...")
                .font(.callout)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading")
        .accessibilityHint("DICOM image is being loaded")
    }
}

struct DicomImageLoadedStateView: View {
    let image: CGImage?
    let imageWidth: Int
    let imageHeight: Int

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .accessibilityLabel("DICOM medical image")
                    .accessibilityHint("Medical image, dimensions \(imageWidth) by \(imageHeight) pixels")
                    .accessibilityAddTraits(.isImage)
            } else {
                Text("Image loaded but not available")
                    .foregroundColor(.secondary)
                    .accessibilityLabel("Error")
                    .accessibilityHint("Image loaded but display failed")
            }
        }
    }
}

struct DicomImageErrorStateView: View {
    let error: DICOMError

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)

            VStack(spacing: 8) {
                Text("Failed to Load Image")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error loading image")
        .accessibilityHint(error.localizedDescription)
    }
}
