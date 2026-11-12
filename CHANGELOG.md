# Changelog

All notable changes to the DICOM-Swift project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.3.0] - 2026-11-12

Minor release of the reviewed canonical sources since 3.2.0. Swift tools 6.2, Swift 6 language mode, the platform
minimums (iOS and visionOS 26.0, macOS 15.0) and the announced products are unchanged. The one API change is a
parameter with a default, so existing calls compile unchanged.

### Added

- `DicomDataSetParser.dataSet(from:startingAt:...)` takes an optional `throughTag`: the root data set is read through
  that tag and the parse ends at the first element past it, so the rest is neither read nor validated. For a caller
  that needs a few leading attributes of each file, such as the Study Instance UID (IsiX issue #3277).

### Changed

- Source headers are standardized across sources, tests, examples, benchmarks and scripts: file and module name,
  purpose summary, author and creation month. Upstream copyright and license notices are retained, and ported
  sources name their origin. The dictionary and enhanced-table generators reproduce the headers of the files they
  generate. Comments only; no behaviour change.

---

## [3.2.0] - 2026-11-07

Minor release of the reviewed canonical sources since 3.1.1. Swift tools 6.2, Swift 6 language mode, the platform
minimums (iOS and visionOS 26.0, macOS 15.0) and the announced products are unchanged. New parameters have
defaults, so existing calls compile unchanged. One source-compatibility note: `DicomRepresentationRefusal` gains
`workspaceExhausted`, so an exhaustive `switch` over it without `default` needs that case.

### Added

- `DicomSeriesLoader` takes an optional `shouldCancel`, asked before each file of the concurrent parse, each slice of
  `loadSeries(in:)` (parallel or sequential) and each frame of the Enhanced and classic multi-frame loaders. True ends
  the load with `CancellationError` once each worker finishes the slice it holds, and the volume buffer is released. A
  host that builds on a thread outside any task can now stop a load, which `Task.isCancelled` could not reach; the
  task check still applies (IsiX issue #3220).
- `DicomSeriesLoader` takes an optional `maxWorkers`, the most files parsed and slices decoded at once by
  `loadSeries(in:)`. It lowers the defaults, never raises them (IsiX issue #3220).
- `DicomStorageSCPConfiguration.acceptsAnyStorageSOPClass` (default `false`) accepts every Storage SOP Class, any
  abstract syntax under `1.2.840.10008.5.1.4.1.1`, and stores the object as received. `DicomAssociationNegotiator.accept`
  takes the matching `acceptsAnyStorageSOPClass` and `sendsAnyStorageSOPClass` options, both defaulting to `false`, and
  `DicomDIMSEServer` honours the setting for storage and, with a retrieve provider, for C-GET sub-operations
  (IsiX issue #3218).
- `DicomStorageSOPClassUIDs.readableStorage`: every Storage SOP Class the toolkit reads, the roster a C-GET proposes
  for returned storage; `projectionAndVisibleLightImageStorage` and `isStorageSOPClass(_:)`, also as
  `DicomNetworkUID.isStorageSOPClass(_:)` (IsiX issue #3218).
- `DicomDIMSEServiceSCU.get` takes `encapsulatedStorageSOPClassUIDs` (default empty): each of those classes is
  proposed once in the configuration's native syntaxes and once, after every other context, in its encapsulated
  ones, so a peer that picks one syntax per context can return native and compressed objects as stored.
  `DicomStorageSOPClassUIDs.readableImageStorage` names the classes of `readableStorage` that carry Pixel Data
  (IsiX issue #3218).
- JPEG 2000 Part 2 Multi-component (.92/.93) objects open frame by frame: `DicomEncapsulatedPixelDataParser` maps each
  frame to its component collection (each fragment's SIZ component count), and `DicomSourceFrameSession` decodes a
  frame together with its collection, once for concurrent requests (IsiX issue #3256).
- `DicomDerivedVolumeBlockCoder` (`.highThroughput`, the default, or `.part1`), passed as
  `DicomDerivedVolumeEncodingOptions(blockCoder:)` to `DicomDerivedVolumeCodec.encode(..., options:)`: derived-volume
  slices are Part 15 HTJ2K by default, 2.3-4.9x faster to decode than Part 1 EBCOT; the decoder reads either (IsiX
  issue #3244).
- `DicomVerbatimText` and `DicomDataElement.verbatimText`: text that the declared Specific Character Set cannot carry
  (an undefined or unsupported declaration, or characters outside its repertoire) keeps the bytes it was read with,
  and `DicomDataSetWriter` writes them back unchanged while the value is the one read. The transcode report warns
  with `codec.transcode.verbatimText`, naming the tags (IsiX issue #3255).
- `DicomRepresentationGenerationLimits` (persistent budget, working-set and concurrency limits, `.standard`) for
  `DicomRepresentationGenerator(..., limits:)`. `Output.persisted` tells a temporary delivery from a published one
  (IsiX issue #3230).

### Changed

- The synchronous JPEG 2000 and HTJ2K volume decode (`DicomDecodedFrameReader.volumeFrame(at:)`) and the synchronous
  Part 2 collection decode run their task at the calling thread's QoS instead of `.userInitiated`, so a load on a
  `.utility` thread no longer decodes at the viewer's priority (IsiX issue #3220).
- The own JPEG XL codec is qualified against libjxl 0.12 and preferred by default: `DICOM_JXLSWIFT_MODE` unset means
  `preferred`, `disabled` rolls it back, and an unrecognized value is logged once. Streams that libjxl renders with
  information outside the DICOM frame contract (embedded-ICC XYB, EXIF orientation, layered images) are refused
  typed before decoding; a .112 frame carrying JPEG reconstruction data decodes as the JPEG it rebuilds (IsiX issue
  #3245).
- `DicomRepresentationGenerator` delivers a verified generation the persistent budget cannot hold once, as a
  temporary representation (`persisted == false`), instead of refusing it with `limitReached`. It confirms the
  source revision first, refuses with `workspaceExhausted` before the codec runs when the working set would exceed
  `maximumWorkingSetBytes`, and runs at most `maximumConcurrentGenerations` at once (two with `.standard`) (IsiX
  issue #3230).
- `dicomtool dcmdir list` prints a diagnostic without an offset as `-` instead of `Optional(...)` (IsiX issue #3268).

### Fixed

- A C-GET reads each returned object in the syntax of the presentation context its C-STORE-RQ arrived on, not the
  first context accepted for its class (IsiX issue #3218).
- Proposing exactly 128 presentation contexts no longer overflows the context ID (IsiX issue #3218).
- A failure raised on this side during a resilient operation (a `DicomDataSetWriterError`, or any
  `DicomPrintManagementError`, now including `emptyImageList`, `invalidImagePosition`, `unsupportedSnapshotData`,
  `imageCountExceedsLayout` and `invalidAnnotation`) is thrown with its cause and never replayed, instead of becoming
  `DicomNetworkError.outcomeUncertain`; that error is kept for a peer or network failure after a request left. Print
  Management encodes each data set before sending its command (IsiX issue #3261).
- `DicomCoreTextPrintRasterizer` returns text upright. It reversed the rows of a bitmap context that is already stored
  top-down, so film identification bands, annotation bands and burned-in captions printed upside down (IsiX issue
  #3248).
- JPEG 2000 Part 2 signalling follows T.801 Table A.2: `J2KMarker` codes (MCT 0xFF74, MCC 0xFF75, MCO 0xFF77,
  DCO 0xFF70) and the `J2KPart2Capabilities` Rsiz bits (MCT is 0x0100) were the J2KSwift-inherited values, so no
  other decoder read the .92/.93 objects the codec wrote. Reversible collections are now signalled as dependency
  transforms and lossy ones as irreversible matrices; dependency, SERM, matrix and pass-through kernels decode, and
  objects written before the fix are still read and flagged for rewrite. Checked against Kakadu 8.4.1 both ways
  (IsiX issue #3246). The Part 2 parser reads each main header in one bounded chunk.
- JPEG XL: lossy non-XYB Modular frames that signal Gaborish or EPF are filtered as libjxl does, and samples are
  clamped to the coded range; the EPF stages follow libjxl's arithmetic (IsiX issue #3254). Images with their own
  opsin inverse matrix decode within one code of djxl instead of being refused (IsiX issue #3259).
- Builds report no compiler warnings outside third-party checkouts; the fixes in sources are unused values, `try` and
  `await` that covered no throwing or async call, and a deprecated `flatMap` (IsiX issue #3268).

---

## [3.1.1] - 2026-11-02

Documentation-only patch release. Source comments, test descriptions and this changelog now describe the slice-gap
and signed-palette behaviour by what the package does and by GDCM, the open toolkit it is checked against. No code,
API, product, toolchain or platform changes.

---

## [3.1.0] - 2026-11-02

Minor release of the reviewed canonical sources since 3.0.1. Swift tools 6.2, Swift 6 language mode, the platform
minimums (iOS and visionOS 26.0, macOS 15.0) and the announced products are unchanged. The one API change is an
addition with a default value; existing callers compile unchanged.

### Added

- `DicomSeriesLoader` takes an optional `sliceDecodeObserver`, called with the slices decoded so far and the total
  after each slice of `loadSeries(in:)`, in the parallel build too. Unlike `progress`, whose order is part of its
  contract, it does not make the decode sequential (IsiX issue #3165).

### Fixed

- `DicomSeriesLoader` lists a symbolic link that resolves to a regular file as a candidate. A series staged as links
  across volumes was skipped and its build failed with `noDicomFiles`; a dangling link is still skipped (IsiX issue
  #3188).
- `DicomWebClient`: a STOW-RS refusal (non-2xx) whose body is no store response stays the HTTP refusal
  (`DicomWebError`) instead of becoming a decode error that implied instances may have been accepted. The error built
  from that body still redacts the credential headers the client sent if the server echoes them (IsiX issue #3188).
- `DicomFileSetExporter` scopes the Patient Name check to the study. A selection in which one Patient ID carries
  different names across studies is exported with one PATIENT record per ID and name, as `DicomFileSet.build`
  builds it, instead of being refused; conflicting names inside one study are still refused. A study whose files omit
  the Patient Name in some of them stays in one PATIENT record instead of failing with `generatedDirectoryInvalid`
  (IsiX issue #3212).

---

## [3.0.1] - 2026-10-23

The macOS minimum drops from 26.0 to 15.0; iOS and visionOS stay at 26.0. Swift tools 6.2, Swift 6 language
mode, the announced products and their APIs are unchanged.

### Changed

- `Package.swift` declares macOS 15.0.
- `J2KThermalStateMonitor` removes its observer from a plain `deinit` instead of an isolated one, which needs
  macOS 15.4.

---

## [3.0.0] - 2026-10-16

Major release of the reviewed canonical sources since 2.0.4. Swift tools 6.2, Swift 6 language mode,
Apple-platform 26.0 minimums and the announced products are unchanged; the major version is for the public
enumerations that gained cases and for series and palette inputs that used to throw and now load. The
`DicomWebClient` and `DicomWebOIDC` sources are unchanged; the executed validation and the known limits are in
RELEASE_NOTES.md.

### Breaking

- `DicomSeriesLoader` builds a single-frame series whose slice positions are unevenly spaced (a missing slice, two
  stacks in one series) at the median interval, as GDCM builds one, instead of throwing
  `variableSliceSpacing` (IsiX issue #3116). The volume reports it in the new
  `DicomSeriesVolumeGeometryProvenance.SliceSpacingSource.irregularImagePositionPatient`; its out-of-plane geometry
  is approximate. Exhaustive switches over `SliceSpacingSource` need the new case.
- `DicomSeriesLoader` builds a series whose Bits Stored and High Bit vary between slices instead of throwing
  `unsupportedPixelFormat` (IsiX issue #3113). Bits Allocated, Pixel Representation, samples, photometric
  interpretation and planar configuration must still match.
- `DCMDecoder.displayRGB8(decodedFrame:)` displays signed PALETTE COLOR indices (Pixel Representation 1) like
  unsigned ones instead of refusing them, a negative index taking the first entry (IsiX issue #3117).
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
