# Changelog

All notable changes to the DICOM-Swift project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [3.0.0] - 2026-10-16

Major release of the reviewed canonical sources since 2.0.4. Swift tools 6.2, Swift 6 language mode,
Apple-platform 26.0 minimums and the announced products are unchanged; the major version is for the public
enumerations that gained cases and for series and palette inputs that used to throw and now load. The
`DicomWebClient` and `DicomWebOIDC` sources are unchanged; the executed validation and the known limits are in
RELEASE_NOTES.md.

### Breaking

- `DicomSeriesLoader` builds a single-frame series whose slice positions are unevenly spaced (a missing slice, two
  stacks in one series) at the median interval, as GDCM and Horos build one, instead of throwing
  `variableSliceSpacing` (IsiX issue #3116). The volume reports it in the new
  `DicomSeriesVolumeGeometryProvenance.SliceSpacingSource.irregularImagePositionPatient`; its out-of-plane geometry
  is approximate. Exhaustive switches over `SliceSpacingSource` need the new case.
- `DicomSeriesLoader` builds a series whose Bits Stored and High Bit vary between slices instead of throwing
  `unsupportedPixelFormat` (IsiX issue #3113). Bits Allocated, Pixel Representation, samples, photometric
  interpretation and planar configuration must still match.
- `DCMDecoder.displayRGB8(decodedFrame:)` displays signed PALETTE COLOR indices (Pixel Representation 1) like
  unsigned ones instead of refusing them, a negative index taking the first entry, as Horos does (IsiX issue #3117).
- `DicomIngestJournalEntry.Disposition` gains `lost`: replay closes once an ingest whose temporary and final files
  are both gone instead of retrying it at every launch (IsiX issue #3070). Exhaustive switches need the new case.

### Added

- `DicomSourceFrameSession.storedSampleFrame(at:)` returns a `DicomStoredSampleFrame` for native monochrome 8- and
  16-bit frames (`DicomSourceFrameIndex.readsStoredSamplesDirectly`), read at their offset in the stored-sample
  convention without a Part 10 copy or a second parse, byte-identical to `frame(at:)` followed by
  `storedSampleData()`. Frame metadata of a series whose headers differ only in per-instance identity, time and
  position is parsed once (IsiX issue #3111).
- `DicomByteSource.fileIdentity` (`DicomFileIdentity`) exposes the status a local file had when it was opened, which
  every validating read of the source checks (IsiX issue #3111).
- `DicomIngestJournalEntry.expectedChecksum` records the SHA-256 of validated batch bytes. A read-back mismatch closes
  the item as discarded, and replay never publishes staged bytes that do not hash to it (IsiX issue #3080).
- The public `DicomJ2KFallbackLedger` also counts the JPEG-LS frames that CharLS decodes because the own decoder
  declined them in `preferred` mode (IsiX issue #3086).

### Changed

- `DicomSourceMetadata.readPart10` parses memory and buffered-file headers out of 16 KiB blocks instead of awaiting
  one read per element; the read ranges, budget and parsed result are unchanged (IsiX issue #3111).
- The JPEG 2000 EBCOT code-block decoder runs in plain C in `DicomJPEG2000NEON`, output bit-exact (IsiX issue #3078).
- Faster JPEG lossless decode and series build (IsiX issue #3079). `DicomSeriesLoader` maps slice files and releases
  each slice's decoder once its samples are copied, lowering the peak memory of a full build (IsiX issue #3092), and
  parses the series in parallel (IsiX issue #3041).
- `DicomDecodedFrameReader` no longer probes every optional codec runtime on each frame, and the standard dictionary
  indexes load lazily (IsiX issues #3082 and #3041).
- Ingest replay pins only the studies of open ingests against eviction, and a catalog intent without a receipt closes
  as rejected once (IsiX issues #3080 and #3070).
- Faster JPEG 2000 decode and per-file open, output bit-exact (IsiX issue #3051): the code-block decoders take the
  next block from a shared cursor instead of fixed buckets; the significance-propagation pass skips stripe columns
  with nothing to code; the inverse 5/3 transform lifts columns row by row without transposes and rows from their
  halves; `DicomDecodedFrame.storedSampleData()` converts 16-bit samples without per-sample branches; the Part 10
  metadata scan reads one block per refill on buffered local files with one revision check at the end of the scan
  (requested ranges and received bytes unchanged), and the single-frame Part 10 bridge encodes its metadata once.
- The standard VR/VM definitions are read from a compiled table instead of decoding `DCMDictionary-Definitions.json`
  on the first parse of a process (IsiX issue #3041). `Scripts/Dictionary/generate_dictionary.py` emits the table
  from the same data as the JSON, which stays the reviewed source and the bundled resource; `--check` covers both,
  and `DicomStandardDictionaryTableTests` checks that they are equal. Lookups are unchanged.

### Fixed

- The generated tables of `DicomData` compile in about 0.5 GB per frontend instead of exhausting memory (more than
  12 GB for the dictionary table and more than 30 GB for the enhanced IOD tables per frontend on every platform; IsiX
  issue #3094). `DicomStandardDictionaryTable` is one string literal decoded once per process, and
  `DicomEnhancedImageTables` builds each IOD and table in its own statement instead of one dictionary literal.
- The JPEG 2000 decoder no longer refuses a tile-part header that only restates the main header (IsiX issue #3076).
  The GDCM/OpenJPEG 2.0 encoder writes a COC and a QCC for every component in each tile-part; a tile-part COD, COC,
  QCD or QCC whose parameters equal the main header's COD/QCD is now skipped. Real per-tile overrides, and any
  tile-part override when the main header carries its own COC/QCC, are still refused typed.
- The JPEG 2000 entropy-integrity check no longer refuses a valid code-block whose encoder dropped the trailing
  0xFF 0x7F run of its segment (IsiX issue #3077). The MQ decoder reads that all-ones tail past the declared bytes, so
  the over-read limit is now 64 bytes instead of 16. A MELANIX CT slice read 21 bytes past and was refused. In
  `preferred` mode, a JPEG 2000 frame that OpenJPEG decodes in place of the own decoder now logs a warning and is
  counted by the new public `DicomJ2KFallbackLedger`.
- The JPEG 2000 entropy-integrity check no longer refuses a code-block cut by rate control whose last pass was also
  cut short (IsiX issue #3095). Such a block declares fewer passes than its bit-planes hold, and Annex C decodes the
  rest of its last pass from the 0xFF fill, as OpenJPEG does. For such a block, the reads past the end during its last
  pass no longer count toward the over-read limit; a block with every pass declared is checked as before. A
  Gruselambix XA frame (lossy 5/3, ratio 4) read 202 bytes past a 134-byte block and was refused.
- Seven structures that GDCM reads are no longer refused; conformant objects take the same path and lossless output
  stays bit-exact (IsiX issue #3053). The encapsulated parser keeps an odd fragment length as declared and ignores a
  Basic Offset Table that addresses no item start only when the JPEG markers or J2K codestream ends delimit every
  frame, with a warning diagnostic. Compatibility reads walk group 0002 to its end when the File Meta Group Length
  ends inside an element or overruns the group; strict and recover modes still refuse it. Encapsulated Pixel Data
  under a defined length is read as items when its value starts with an item tag. JPEG Lossless ignores Se in a
  lossless scan and retries a failing 16-bit stream with the libjpeg reading of SSSS 16. Compressed Bits Allocated 12
  decodes into 16-bit words.
- `DCMDecoder` reads Rescale Slope 0 as 1, as GDCM does, and logs that the data was corrected; `info(for:)` keeps
  the stored value (IsiX issue #3053).
- The single-frame codec input keeps ASCII text, such as Rescale Type, when the declared Specific Character Set is
  not a defined term; text outside ASCII is still left out (IsiX issue #3097).

---

## [2.0.2] - 2026-10-04

Patch release of DICOMweb client and server fixes; the executed validation and
the known limits are in RELEASE_NOTES.md.

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
- The DICOMweb HTTP listener no longer cuts a response that is still being
  written when `connectionLifetime` (120 s) runs out. A large retrieve to a slow
  client ended without its final boundary. The limit now covers waiting for
  and reading a request, and a response with no completed write for that long.
- A QIDO-RS code string key with several values, such as
  `ModalitiesInStudy=CT,MR`, matches any listed value in the DICOMweb server,
  and a repeated code string or UID key is read as the same list.
- The DICOMweb server streams a WADO-RS retrieve past 1 GiB to the closing
  boundary, and renders `rendered` and `thumbnail` of compressed instances
  after decoding them instead of answering 406.

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
