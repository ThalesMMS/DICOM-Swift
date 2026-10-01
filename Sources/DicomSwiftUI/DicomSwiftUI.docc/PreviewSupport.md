# Preview Support

Use Xcode Previews with DicomSwiftUI components for instant design iteration without requiring actual DICOM files.

## Overview

DicomSwiftUI provides comprehensive preview support to enable rapid UI development and iteration in Xcode Canvas. The preview infrastructure includes:

- **Mock DICOM Decoders**: Lightweight decoders that generate synthetic medical imaging data
- **Sample Data Providers**: Pre-configured samples for CT, MRI, X-Ray, and Ultrasound modalities
- **Preview Helper APIs**: Factory methods for quick preview setup with realistic data
- **Performance Optimized**: All previews load in <50ms for responsive iteration

Preview support eliminates the need for actual DICOM files during UI development, making it easy to test different medical imaging scenarios, windowing presets, and layout variations.

## Platform Requirements

- **iOS / visionOS / macOS**: 26.0 or later
- **Xcode**: 26.0 or later (for Canvas support)

## Quick Start

### Basic Preview

The simplest way to preview a DICOM view is using the preview helper methods:

```swift
import SwiftUI
import DicomSwiftUI

#Preview("CT Lung Window") {
    let viewModel = DicomImageViewModel.preview(.ctLung)
    DicomImageView(viewModel: viewModel)
        .frame(width: 512, height: 512)
}
```

### Multiple Configurations

Preview different windowing presets side by side:

```swift
#Preview("Medical Presets") {
    HStack {
        DicomImageView(viewModel: .preview(.ctLung))
            .previewSize(.medium)

        DicomImageView(viewModel: .preview(.ctBone))
            .previewSize(.medium)

        DicomImageView(viewModel: .preview(.mrBrain))
            .previewSize(.medium)
    }
}
```

## Available Sample Modalities

The preview infrastructure includes realistic sample data for common medical imaging modalities:

### CT (Computed Tomography)

```swift
#Preview("CT Samples") {
    VStack {
        // Lung window preset
        DicomImageView(viewModel: .preview(.ctLung))
            .previewSize(.small)

        // Bone window preset
        DicomImageView(viewModel: .preview(.ctBone))
            .previewSize(.small)

        // Brain window preset
        DicomImageView(viewModel: .preview(.ctBrain))
            .previewSize(.small)

        // Abdomen soft tissue preset
        DicomImageView(viewModel: .preview(.ctAbdomen))
            .previewSize(.small)
    }
}
```

**Common CT Presets:**
- `.ctLung` - Lung window (center: -600, width: 1500)
- `.ctBone` - Bone window (center: 400, width: 1800)
- `.ctBrain` - Brain window (center: 40, width: 80)
- `.ctAbdomen` - Soft tissue window (center: 40, width: 400)

### MRI (Magnetic Resonance Imaging)

```swift
#Preview("MRI Samples") {
    HStack {
        // T1-weighted brain
        DicomImageView(viewModel: .preview(.mrBrain))
            .previewSize(.medium)

        // T2-weighted spine
        DicomImageView(viewModel: .preview(.mrSpine))
            .previewSize(.medium)
    }
}
```

**Common MRI Presets:**
- `.mrBrain` - T1-weighted brain (center: 600, width: 1200)
- `.mrSpine` - T2-weighted spine (center: 600, width: 1200)

### X-Ray (Radiography)

```swift
#Preview("X-Ray Sample") {
    DicomImageView(viewModel: .preview(.xrayChest))
        .previewSize(.large)
        .background(Color.black)
}
```

**X-Ray Configuration:**
- `.xrayChest` - Chest PA view (center: 2000, width: 4000)

### Ultrasound

```swift
#Preview("Ultrasound Sample") {
    DicomImageView(viewModel: .preview(.ultrasound))
        .previewSize(.medium)
}
```

**Ultrasound Configuration:**
- `.ultrasound` - Abdominal scan (center: 128, width: 256)

## Preview Helper APIs

### DicomImageViewModel Factory Methods

Create preview-ready view models with pre-loaded sample data:

```swift
// Pre-configured medical scenarios
let lungViewModel = DicomImageViewModel.preview(.ctLung)
let brainViewModel = DicomImageViewModel.preview(.mrBrain)

// Custom modality with specific window settings
let customViewModel = DicomImageViewModel.preview(
    modality: .ct,
    windowSettings: WindowSettings(center: 50, width: 400)
)

// Automatic windowing
let autoViewModel = DicomImageViewModel.previewWithAutoWindowing(.ct)

// Specific medical preset
let presetViewModel = DicomImageViewModel.preview(preset: .lung, modality: .ct)
```

### SeriesNavigatorViewModel Factory Methods

Create series navigation previews:

```swift
#Preview("CT Series Navigator") {
    let navigator = SeriesNavigatorViewModel.preview(modality: .ct, slices: 10)
    SeriesNavigatorView(navigatorViewModel: navigator)
}

#Preview("MRI Series Navigator") {
    let navigator = SeriesNavigatorViewModel.previewMRISeries(slices: 20)
    SeriesNavigatorView(navigatorViewModel: navigator)
}
```

### PreviewSize Presets

Use predefined size presets for consistent preview layouts:

```swift
#Preview("Size Presets") {
    VStack {
        DicomImageView(viewModel: .preview(.ctLung))
            .previewSize(.thumbnail)  // 128×128

        DicomImageView(viewModel: .preview(.ctLung))
            .previewSize(.small)      // 256×256

        DicomImageView(viewModel: .preview(.ctLung))
            .previewSize(.medium)     // 512×512

        DicomImageView(viewModel: .preview(.ctLung))
            .previewSize(.large)      // 1024×1024
    }
}
```

Available sizes:
- `.thumbnail` - 128×128 points (list items, galleries)
- `.small` - 256×256 points (compact displays)
- `.medium` - 512×512 points (standard previews)
- `.large` - 1024×1024 points (detailed inspection)
- `.custom(width:height:)` - Custom dimensions

### PreviewHelpers Utilities

Access collections of sample data for testing list views and complex layouts:

```swift
#Preview("Multiple Modalities") {
    let decoders = PreviewHelpers.sampleDecoders()
    List(0..<decoders.count, id: \.self) { index in
        HStack {
            Text(decoders[index].modality ?? "Unknown")
            Text("\(decoders[index].width) × \(decoders[index].height)")
        }
    }
}

#Preview("View Model Collection") {
    let viewModels = PreviewHelpers.sampleViewModels()
    ScrollView(.horizontal) {
        HStack {
            ForEach(0..<viewModels.count, id: \.self) { index in
                DicomImageView(viewModel: viewModels[index])
                    .previewSize(.small)
            }
        }
    }
}
```

### Preview Mock Scope

`MockDicomDecoderForPreviews`, `DicomSampleData`, and `PreviewHelpers` are
supported public preview APIs for Xcode canvases and example-only UI states.
They are not clinical/runtime decoders and must not be used for production
decode, validation, conformance, or patient-data workflows. Production code
should use `DCMDecoder` or a caller-owned `DicomDecoderProtocol`
implementation backed by real DICOM data.

### State Testing Helpers

Test loading and error states:

```swift
#Preview("Loading State") {
    let loadingViewModel = PreviewHelpers.loadingViewModel()
    DicomImageView(viewModel: loadingViewModel)
        .frame(width: 512, height: 512)
}

#Preview("Error State") {
    let errorViewModel = PreviewHelpers.errorViewModel()
    DicomImageView(viewModel: errorViewModel)
        .frame(width: 512, height: 512)
}
```

## Complete Component Previews

### DicomImageView Previews

```swift
#Preview("CT with Different Presets") {
    VStack(spacing: 20) {
        DicomImageView(viewModel: .preview(.ctLung))
            .previewConfiguration(.ctLung, size: .medium)

        DicomImageView(viewModel: .preview(.ctBone))
            .previewConfiguration(.ctBone, size: .medium)
    }
}

#Preview("Dark Mode") {
    DicomImageView(viewModel: .preview(.mrBrain))
        .previewSize(.large)
        .preferredColorScheme(.dark)
}

#Preview("Light Mode") {
    DicomImageView(viewModel: .preview(.xrayChest))
        .previewSize(.large)
        .preferredColorScheme(.light)
}
```

### SeriesNavigatorView Previews

```swift
#Preview("Series Navigation") {
    let navigator = SeriesNavigatorViewModel.preview(modality: .ct, slices: 15)
    SeriesNavigatorView(navigatorViewModel: navigator)
}

#Preview("Large Series") {
    let navigator = SeriesNavigatorViewModel.previewCTSeries(slices: 50)
    SeriesNavigatorView(navigatorViewModel: navigator)
        .frame(height: 120)
}
```

### WindowingControlView Previews

```swift
#Preview("Windowing Controls") {
    let windowingViewModel = WindowingViewModel(preset: .lung)

    VStack {
        DicomImageView(
            viewModel: .preview(.ctLung)
        )
        .previewSize(.medium)

        WindowingControlView(
            windowingViewModel: windowingViewModel
        )
        .padding()
    }
}
```

### MetadataView Previews

```swift
#Preview("Patient Metadata") {
    let decoder = MockDicomDecoderForPreviews.sampleCT()
    MetadataView(decoder: decoder)
        .frame(height: 300)
}

#Preview("Different Modalities") {
    VStack {
        MetadataView(decoder: MockDicomDecoderForPreviews.sampleCT())
        Divider()
        MetadataView(decoder: MockDicomDecoderForPreviews.sampleMRI())
        Divider()
        MetadataView(decoder: MockDicomDecoderForPreviews.sampleXRay())
    }
}
```

## Custom Preview Configurations

### Custom Window Settings

Create previews with specific window/level parameters:

```swift
#Preview("Custom Windowing") {
    let customSettings = WindowSettings(center: 500, width: 1500)
    let viewModel = DicomImageViewModel.preview(
        modality: .ct,
        windowSettings: customSettings
    )

    DicomImageView(viewModel: viewModel)
        .previewSize(.large)
}
```

### Custom Modality Configuration

```swift
#Preview("Custom Configuration") {
    let config = PreviewConfiguration.custom(
        modality: .ct,
        windowSettings: WindowSettings(center: 100, width: 800),
        description: "Custom CT Window"
    )

    let viewModel = DicomImageViewModel.preview(config)
    DicomImageView(viewModel: viewModel)
        .previewSize(.medium)
}
```

### Complete Viewer Preview

Combine multiple components in a realistic viewer layout:

```swift
#Preview("Complete DICOM Viewer") {
    struct ViewerPreview: View {
        @StateObject private var viewModel = DicomImageViewModel.preview(.ctLung)
        let navigator = SeriesNavigatorViewModel.previewCTSeries(slices: 10)
        let windowingViewModel = WindowingViewModel(preset: .lung)

        var body: some View {
            VStack(spacing: 0) {
                DicomImageView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                MetadataView(decoder: MockDicomDecoderForPreviews.sampleCT())
                    .frame(height: 150)

                Divider()

                WindowingControlView(
                    windowingViewModel: windowingViewModel
                )
                .padding()

                Divider()

                SeriesNavigatorView(navigatorViewModel: navigator)
                    .frame(height: 80)
            }
        }
    }

    return ViewerPreview()
}
```

## Performance Considerations

### Load Time

All preview helpers are optimized for instant loading:
- Mock decoders generate synthetic data in <10ms
- Sample patient data created in <50ms total
- No file I/O or network access required
- Previews refresh in <1 second for responsive iteration

### Memory Efficiency

Preview data is lightweight:
- 512×512 sample images: ~512KB memory
- 1024×1024 sample images: ~2MB memory
- Mock decoders share common metadata tables
- No actual DICOM file parsing overhead

### CPU Backend

Previews use CPU-based windowing (`.vdsp`) for reliability:
```swift
// Automatically uses CPU backend for preview stability
let viewModel = DicomImageViewModel.preview(.ctLung)
// processingMode: .vdsp is set internally
```

## Troubleshooting

### Preview Not Rendering

If previews fail to render:

1. **Check Xcode Canvas**: Enable Canvas with Cmd+Option+Enter
2. **Verify Import**: Ensure `import DicomSwiftUI` is present
3. **Check macOS Target**: Preview requires the macOS 26+ deployment target
4. **Restart Canvas**: Resume preview or click "Try Again"

### Slow Preview Loading

If previews load slowly:

1. **Use Smaller Sizes**: Start with `.thumbnail` or `.small` sizes
2. **Reduce Sample Count**: Limit series to 5-10 slices for navigation
3. **Check Build**: Ensure project builds without errors
4. **Clear Derived Data**: Product > Clean Build Folder

### Missing Sample Data

If sample data doesn't appear:

1. **Check Factory Method**: Verify using `.preview()` methods
2. **Verify Modality**: Ensure modality is supported (CT, MR, CR, US)
3. **Inspect View Model**: Check that view model loaded successfully

## Example Code

For comprehensive examples of preview usage, see:
- `Sources/DicomSwiftUI/Views/DicomImageView.swift` - DicomImageView previews
- `Sources/DicomSwiftUI/Views/SeriesNavigatorView.swift` - Series navigation previews
- `Sources/DicomSwiftUI/Views/MetadataView.swift` - Metadata display previews
- `Sources/DicomSwiftUI/Views/WindowingControlView.swift` - Windowing control previews

## See Also

- ``DicomImageViewModel``
- ``SeriesNavigatorViewModel``
- ``PreviewSize``
- ``PreviewConfiguration``
- ``PreviewHelpers``
- <doc:GettingStarted>
