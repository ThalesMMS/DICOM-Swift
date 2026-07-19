# Swift DICOM Decoder

Pure Swift DICOM toolkit for iOS and macOS. The package is now core-only and ships:

- `DicomCore` for parsing, pixel access, windowing, export, and DICOMweb/DIMSE helpers.
- `dicomtool` for command-line inspection and export workflows.

## Screenshot

Decoded-image output generated with `DicomCore`. The viewer surface shown is not
shipped as part of this package.

<p align="center">
  <img src="screenshot/screenshot.png" alt="DICOM image decoded with DicomCore" width="800">
</p>

## What is included

- DICOM parsing, metadata, pixel extraction, and validation
- Encapsulated pixel data, codecs, and transfer syntax handling
- Window/level, preset suggestions, and related image-processing helpers
- Directory, file, and ZIP series loading
- Image export to PNG, JPEG, TIFF, 16-bit TIFF, and sidecar metadata
- Structured Report, SEG, GSPS, PDF, CDA, STL, ECG, waveform, and video helpers
- DICOMweb and DIMSE helpers with typed diagnostics
- Documentation and tests for the core package and CLI

## What is not included

- No shipped viewer UI module
- No example app
- No SwiftUI, UIKit, or AppKit product surface

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ThalesMMS/DICOM-Swift.git", from: "1.0.0")
]
```

Then depend on the products you need:

```swift
.product(name: "DicomCore", package: "DICOM-Swift")
.product(name: "dicomtool", package: "DICOM-Swift")
```

## Usage

Use `DicomCore` for file parsing and processing:

```swift
import DicomCore

let decoder = try DCMDecoder(contentsOf: URL(fileURLWithPath: "/path/to/image.dcm"))
print(decoder.width, decoder.height)
```

For CLI workflows, build or run `dicomtool`:

```bash
swift run dicomtool --help
```

## Documentation

- Build API docs for `DicomCore` with `swift package generate-documentation --target DicomCore`
- Build API docs for `dicomtool` with `swift package generate-documentation --target dicomtool`

## Core support contracts

- Inspect `DicomTransferSyntaxRegistry.standard.compressedPixelSupportMatrix`
  before decoding compressed pixel data and
  `DicomTransferSyntaxRegistry.standard.writeSupportMatrix` before writing a
  dataset.
- Inspect `DicomWebConformanceMatrix.packageDefault` before using the DICOMweb
  helpers as an integration interface.
- Optional codec runtimes are reported by
  `DicomCodecRuntimePreflight.status(for: .charLS)` and
  `DicomCodecRuntimePreflight.status(for: .openJPEG)`.
- DIMSE scope includes package-tested C-ECHO, C-FIND, C-GET, C-MOVE, C-STORE,
  Storage SCP, Storage Commitment, MPPS, and Basic Grayscale Print helpers.
  They are not a managed PACS service; deployment, authorization, auditing,
  monitoring, and archive qualification remain caller-owned.
- DIMSE helpers for tested C-ECHO and related workflows follow the same scope.
  They are not a managed PACS service.
- `DicomDecodedSeries` is the package's decoded-series output interface.
  Converting it to a renderer-specific data type is the caller's
  responsibility.

## Testing

```bash
swift build
swift test
swift build -c release
```
