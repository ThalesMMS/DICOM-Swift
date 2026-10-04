# Changelog

All notable changes to the DICOM-Swift project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- QIDO-RS searches keep the comma between the values of one key literal, for
  UID lists and for multiple values of any other VR; a comma inside a value is
  still percent-encoded. dcm4chee read `%2C` as part of a single value and
  found nothing. `DicomWebSearchParameters` now accepts several values for a
  key of any VR, and `dicomtool web qido --key` splits values on commas.
- A retrieve with a `DicomWebAcceptList` also moves to the next range after a
  500, once per retrieve and only when the refused first range names a
  transfer syntax. Orthanc and dcm4chee answer 500, not 406, to a syntax they
  cannot convert to. The default `fallbackStatuses` is now `[406, 500]`.

---

## [2.0.1] - 2026-10-04

Patch release of the `DicomWebClient` product; the executed validation and
the known limits are in RELEASE_NOTES.md.

### Fixed

- `URLSessionDicomWebHTTPTransport` sends every request to the server, and
  DICOMweb responses are no longer stored in the URL cache. dcm4chee gives all
  representations of an instance one `ETag` without `Vary: Accept`, so a cached
  answer could be another representation than the one asked for.

### Changed

- The interop compose file uses existing dcm4chee 5.35.2 tags, and
  `run_interop_smoke.sh` falls back to the standalone `docker-compose`.

---

## [2.0.0] - 2026-10-04

First stable 2.x release. It consolidates 2.0.0-rc.1 to 2.0.0-rc.3; the
summary since 1.5.0, the executed validation and the known limits are in
RELEASE_NOTES.md.

### Changed

- The package compiles in Swift 6 language mode. Swift tools 6.2 and iOS,
  visionOS or macOS 26.0+ are unchanged from 1.5.0.
- Module and API ownership are split into separate library products. The
  DICOMweb client is the independent `DicomWebClient` product, and DICOM
  datasets, Part 10, UIDs and DICOM JSON/XML live in `DicomData`.
- The JPEG 2000, JPEG-LS and JPEG XL codecs are incorporated sources; the
  J2KSwift, JLSwift and JXLSwift package dependencies are gone.
- DICOMweb HTTP failures of the legacy study search, metadata and UPS calls
  are reported as `DicomWebError`.

### Added

- DICOMweb client: file-backed and streamed STOW-RS, ordered transfer syntax
  fallback after 406, opt-in retries, QIDO paging, bulk-data ranges, rendered
  and thumbnail options, streamed metadata decoding, per-request
  authorization, server trust anchors or a pinned leaf, and client
  certificates.
- `DicomWebOIDC`: OpenID Connect sign-in for a public client.
- DICOMweb server in `DicomCore`: provider-backed QIDO paging, 405 and 204
  answers, dictionary keyword matching, Warning 299 for ignored parameters,
  and URLs from a public base URL or forwarded headers.

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

[Unreleased]: https://github.com/ThalesMMS/DICOM-Swift/compare/2.0.1...HEAD
[1.0.1]: https://github.com/ThalesMMS/DICOM-Swift/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/ThalesMMS/DICOM-Swift/releases/tag/1.0.0
