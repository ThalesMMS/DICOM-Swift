# ``DicomSwiftUI``

Production-ready SwiftUI components for DICOM medical imaging. Build medical image viewers with automatic windowing, series navigation, and interactive controls.

## Overview

DicomSwiftUI provides high-level SwiftUI components for displaying and interacting with DICOM medical images. Built on top of `DicomCore`, it handles common tasks like image display with automatic scaling, interactive windowing controls, series navigation, and metadata presentation.

All components follow SwiftUI best practices, support dark mode, include accessibility features, and are optimized for iOS, visionOS, and macOS 26+ deployment targets.

### Key Features

- **Ready-to-use Views**: Drop-in components for image display, windowing controls, series navigation, and metadata
- **Automatic Image Processing**: Built-in windowing and rendering with GPU acceleration support
- **Modern SwiftUI**: Uses @StateObject, async/await, and SwiftUI lifecycle
- **Customizable**: Extensive styling and configuration options to match your app's design
- **Accessible**: VoiceOver support, Dynamic Type, and keyboard shortcuts
- **Dark Mode**: Automatic adaptation to light and dark appearance

## Topics

### Getting Started

- <doc:GettingStarted>
- <doc:PreviewSupport>

### Image Display

- ``DicomImageView``
- ``DicomImageViewModel``

### Windowing Controls

- ``WindowingControlView``
- ``WindowingViewModel``

### Series Navigation

- ``SeriesNavigatorView``
- ``SeriesNavigatorViewModel``

### Metadata Display

- ``MetadataView``

### Rendering Utilities

- ``CGImageFactory``
- ``DicomImageRenderer``
