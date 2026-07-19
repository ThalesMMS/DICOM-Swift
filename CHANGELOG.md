# Changelog

All notable changes to the Swift DICOM Decoder project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Added release-prep guidance, including a first-stable-release gate checklist in `RELEASING.md`.
- Reduced DIMSE receive overhead by waiting for complete requested chunks and retaining decoded P-DATA payloads as zero-copy buffer slices.

### Added

- **Swift-idiomatic throwing initializers** for DICOM file loading:
  - `try DCMDecoder(contentsOf: url)` and `try DCMDecoder(contentsOfFile: path)`
  - `try await DCMDecoder(contentsOf: url)` and `try await DCMDecoder(contentsOfFile: path)`
  - Static factory methods: `DCMDecoder.load(from:)`, `DCMDecoder.load(fromFile:)`
  - Typed error handling via `DICOMError` cases

- **Type-safe DicomTag enum** for metadata access:
  - Enum cases for all standard DICOM tags (`.patientName`, `.modality`, `.rows`, etc.)
  - `info(for: DicomTag)`, `intValue(for: DicomTag)`, `doubleValue(for: DicomTag)`
  - Raw hex values still supported for custom/private tags

- **Type-safe value types (V2 APIs)**:
  - `WindowSettings` struct replacing `windowSettings` tuple
  - `PixelSpacing` struct replacing `pixelSpacing` tuple
  - `RescaleParameters` struct replacing `rescaleParameters` tuple
  - All V2 types are Codable and Sendable
  - V2 variants for windowing methods (`calculateOptimalWindowLevelV2`, `getPresetValuesV2`, etc.)

- **Metal GPU acceleration** for window/level operations:
  - `MetalWindowingProcessor` using Metal compute shaders
  - `processingMode` parameter (`.vdsp`, `.metal`, `.auto`)
  - 3.94x speedup on 1024x1024 images (Apple M4)
  - Automatic fallback to vDSP if Metal is unavailable

- **getDownsampledPixels8** method for 8-bit thumbnail generation

- **Thread-safe concurrency support** with Swift structured concurrency:
  - All public types are thread-safe and can be used concurrently
  - `Sendable` conformance for value types (`WindowSettings`, `PixelSpacing`, `RescaleParameters`)
  - `Sendable` conformance for data models (`PatientModel`, `StudyModel`, `SeriesModel`, `ImageModel`)
  - Internal synchronization in `DCMDecoder` for safe concurrent access
  - Actor isolation for `MetalWindowingProcessor` GPU command buffer access

- **Batch loading APIs** for concurrent multi-file processing:
  - `DicomSeriesLoader.loadMultipleSeries(seriesPaths:)` - concurrent series loading with `TaskGroup`
  - `StudyDataService.scanStudies(at:)` - concurrent directory scanning
  - Automatic parallelization with graceful error handling
  - Result arrays with partial success support

- **Concurrent processing performance** (4-core benchmarks):
  - Load 10 series (100 files): 3.2s → 0.9s (3.6× speedup)
  - Scan study directory (50 files): 1.8s → 0.5s (3.6× speedup)
  - Load + window level (20 files): 2.1s → 0.6s (3.5× speedup)

### Deprecated

- `setDicomFilename(_:)` and `dicomFileReadSuccess` - use throwing initializers
- `loadDICOMFileAsync(_:)` - use async throwing initializers
- `windowSettings` tuple - use `windowSettingsV2`
- `pixelSpacing` tuple - use `pixelSpacingV2`
- `rescaleParameters` tuple - use `rescaleParametersV2`
- Tuple-returning windowing methods - use V2 variants

---

## [1.0.1] - DICOM Streaming & Security

### Added

- **Native JPEG Lossless Decoder** (Process 14, Selection Value 1):
  - Support for transfer syntaxes 1.2.840.10008.1.2.4.57 and 1.2.840.10008.1.2.4.70
  - Full JPEG marker parsing, Huffman table decoding, first-order prediction
  - Support for 8-bit, 12-bit, and 16-bit precision

- **Range-based pixel access** for streaming without loading entire files into memory

- **Protocol-based dependency injection**:
  - `DicomDecoderProtocol`, `StudyDataServiceProtocol`, `DicomDictionaryProtocol`
  - `DicomSeriesLoaderProtocol`, `FileImportServiceProtocol`
  - Decoder factory pattern for thread-safe concurrent processing
  - `MockDicomDecoder` for testing

- **Validation methods**: `validateDICOMFile(_:)`, `isValid()`, `getValidationStatus()`

- **Async/await support** (iOS 13+, macOS 10.15+):
  - `loadDICOMFileAsync(_:)`, `getPixels16Async()`, `getPixels8Async()`
  - `getPixels24Async()`, `getDownsampledPixels16Async(maxDimension:)`

- **Convenience methods**: `intValue(for:)`, `doubleValue(for:)`, `getAllTags()`
  - `getPatientInfo()`, `getStudyInfo()`, `getSeriesInfo()`
  - `isGrayscale`, `isColorImage`, `isMultiFrame`, `imageDimensions`
  - `applyRescale(to:)`, `calculateOptimalWindow()`, `getQualityMetrics()`

- **Extended medical presets** (13 total):
  - CT: mediastinum, abdomen, spine, pelvis
  - Angiography: angiography, pulmonaryEmbolism
  - Other: mammography, petScan
  - `suggestPresets(for:bodyPart:)` for context-aware recommendations

- **Comprehensive test suite**: validation, convenience methods, windowing, presets, security

- **Documentation**: USAGE_EXAMPLES.md, CHANGELOG.md, Getting Started guide, Glossary, Troubleshooting guide

### Improved

- Refactored decoder with modular reader architecture (DCMBinaryReader, DCMPixelReader, DCMTagParser)
- Optimized range-based reading for memory-mapped file access
- Enhanced lung preset window width (1200 -> 1500 HU)
- Replaced print statements with structured logging

### Fixed

- Comprehensive security validation: bounds checking, sequence depth tracking, pixel buffer allocation validation, malicious length detection
- Platform-specific test compatibility (macOS-only reference decoder tests)
- Improved error messages and recovery suggestions

---

## [1.0.0] - Initial Release

### Added

- Core DICOM decoder (`DCMDecoder`):
  - Little/big endian, explicit/implicit VR
  - 8-bit and 16-bit grayscale, 24-bit RGB
  - Uncompressed transfer syntaxes
  - Memory-mapped file I/O for large files (>10MB)
  - Downsampled pixel reading for thumbnails

- Window/level processor (`DCMWindowingProcessor`):
  - Medical imaging window/level transformations
  - Basic medical presets (lung, bone, soft tissue, brain, liver)
  - Image enhancement (global histogram equalization, noise reduction)
  - Statistical analysis and quality metrics
  - Batch processing and Hounsfield unit conversion

- Error handling system (`DICOMError`)
- Study data service (`StudyDataService`)
- DICOM tag dictionary (`DCMDictionary`)

### Technical Details

- Swift 5.9+, iOS 13+, macOS 12+
- Pure Swift, zero external dependencies
- SwiftPM package structure

---

[Unreleased]: https://github.com/ThalesMMS/DICOM-Swift/compare/1.0.1...HEAD
[1.0.1]: https://github.com/ThalesMMS/DICOM-Swift/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/ThalesMMS/DICOM-Swift/releases/tag/1.0.0
