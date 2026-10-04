# Changelog

All notable changes to the DICOM-Swift project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `DicomTiledSliceLayout` (Isis issue #2827) detects an image whose pixel grid tiles the slices of a volume and gives each tile's position.
  - **Siemens MOSAIC:** ImageType ends in MOSAIC. The count comes from CSA `NumberOfImagesInMosaic` or (0019,xx0A), and the slice normal from `SliceNormalVector`. The first tile is centred in the mosaic.
  - **United Imaging grid:** (0065,xx50/xx51) of "Image Private Header".
  - `slices(fromImage:columns:bytesPerSample:)` reorders the tiles into a stack along row × column.
  - Formulas are ported from GDCM's SplitMosaicFilter and SplitGridFilter (BSD-3-Clause). `SiemensCSAHeader.numericValues(named:)` is now public.

- `DicomSegmentationBuildOptions.seriesDescription` and `specificCharacterSet` write Series Description (0008,103E) and Specific Character Set (0008,0005), and `DCMDecoder.segmentationReferencedSeriesInstanceUIDs` reads the Referenced Series Sequence without decoding a frame (Isis issue #2504).
- Frame VOI preservation for Enhanced CT/MR Functional Groups, including
  Shared/Per-Frame precedence, spatially ordered per-slice windows, and a
  deterministic default-window fallback.

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

### Changed

- A linear Real World Value Mapping item without First/Last Value Mapped is read as mapping every stored value (Isis issue #2842). `DicomRealWorldValueMap.declaresMappedRange` is false for such an item, and the profile reports `real_world_value_mapping_without_range`. Philips MR conversions write it that way, and GDCM reads it the same. Items with a LUT, or with a slope but no intercept, stay refused.

- Label maps at TotalSegmentator scale (Isis issue #2501). `DicomSegmentationPixelData.labelmap` now carries a `DicomLabelmapPlane` that keeps 8-bit planes 8-bit through build, write and parse. `DicomSegmentation.labelmapsBySegment` is built on access instead of in `init`, which expanded one full volume per declared segment (~18 GB for 117 segments on 512×512×300); use `labelmap(forSegment:)` for one segment. Parsing copies frames in bulk and checks declared labels in one histogram pass. `backgroundSegmentNumber` resolves the Pixel Padding Value background (PS3.3 C.8.20.2.4). `DicomDataSetWriter.write(_:to:)` streams large values to the file, and `part10Data` encodes into a single buffer.
- Validation severities (Isis issue #2487): a Bits Stored that differs from the codestream precision while the precision fits Bits Allocated, chroma sampling that disagrees with the declared `YBR_FULL_422`/`YBR_FULL`/`RGB`, an OB Pixel Data header over word samples under little endian, and direction cosines within 1e-3 of an orthonormal basis but outside their own rounding bound are warnings; the errors remain for a precision above Bits Allocated, a wrong component count, OB word samples under big endian, and larger geometry departures.

- Added release-prep guidance, including a first-stable-release gate checklist in `RELEASING.md`.
- Reduced DIMSE receive overhead by waiting for complete requested chunks and retaining decoded P-DATA payloads as zero-copy buffer slices.

### Fixed

- A UID with a single component (`0`, `99`) is a valid UI value, as in DCMTK's `tchval.cc` UI-01 and UI-10; the reader refused it as `invalidTextValue` (Isis issue #2845). `DicomDCMTKTextValueVectorTests` checks the 204 DCMTK value cases, and the divergences it keeps are recorded in the vector file.
- `DicomTCPAssociationTransport` bounds only P-DATA-TF by the configured maximum PDU length (PS3.8 §9.3.1); association and release PDUs are read up to a fixed 1 MiB ceiling. The SCP refused an A-ASSOCIATE-RQ above 16 KB, such as 128 presentation contexts with four transfer syntaxes each (Isis issue #2791).
- `DicomJ2KCodestreamInspector` and `DicomJPEGFrameInspector` accept the single even-length pad byte after EOC/EOI whatever its value (GDCM and GE write `0xFF`); such frames were reported as `invalidCodestream` (Isis issue #2487).
- The JPEG encoder writes SOF1 for 8-bit frames under the JPEG Extended syntax (`1.2.840.10008.1.2.4.51`, Process 2 & 4) through `JLIEncoderConfiguration.extendedSequential`; it wrote a Process 1 (SOF0) frame the validator refuses.

### Deprecated

- `setDicomFilename(_:)` and `dicomFileReadSuccess` - use throwing initializers
- `loadDICOMFileAsync(_:)` - use async throwing initializers
- `windowSettings` tuple - use `windowSettingsV2`
- `pixelSpacing` tuple - use `pixelSpacingV2`
- `rescaleParameters` tuple - use `rescaleParametersV2`
- Tuple-returning windowing methods - use V2 variants

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

[Unreleased]: https://github.com/ThalesMMS/DICOM-Swift/compare/1.0.1...HEAD
[1.0.1]: https://github.com/ThalesMMS/DICOM-Swift/compare/1.0.0...1.0.1
[1.0.0]: https://github.com/ThalesMMS/DICOM-Swift/releases/tag/1.0.0
