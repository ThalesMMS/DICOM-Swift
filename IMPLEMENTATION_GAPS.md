# DICOM-Swift Implementation Gaps Audit

Date: 2026-08-30

Scope: local package under `DICOM-Swift/` inside the Isis DICOM Viewer
workspace. This audit looked for explicit incomplete markers, TODOs,
placeholders, mocks, unsupported branches, runtime traps, stale documentation,
and test coverage gaps that affect whether this package can be treated as a
complete DICOM parsing, pixel, UI, DICOMweb, or DIMSE replacement.

## Method

- Skimmed the parent Isis `README.md` and `DISTRIBUTION.md` to confirm the
  current project stance: DICOM-Swift is an optional metadata/networking
  parity track, while GDCM remains the primary pixel/volume source in Isis.
- Read `DICOM-Swift/AGENTS.md`, `README.md`, and `Package.swift`.
- Scanned `DICOM-Swift/Sources`, `Tests`, `Examples`, and `Scripts` with
  `rg` for `TODO`, `FIXME`, `placeholder`, `not implemented`, `unsupported`,
  `mock`, `fake`, `fatalError`, `XCTSkip`, and related terms.
- Built the SwiftPM test manifest with
  `swift test --package-path DICOM-Swift --list-tests`.

Audit counts from the scan:

- 326 source/test/example/script files were in the audited set.
- 52 explicit incomplete-marker hits were found, including docs and examples.
- 109 `unsupported`-style source hits were found. Many are valid validation
  errors, but the material ones are listed below.
- 77 `XCTSkip` or `XCTSkipIf` hits were found in tests.
- 2 `preconditionFailure` hits remain in `Sources`; both guard transfer syntax
  registry invariants covered by tests. No `fatalError` hits remain in
  `Sources`.

`swift test --package-path DICOM-Swift --list-tests` completed successfully,
but SwiftPM emitted package-manifest warnings for unhandled files.

## Priority Legend

- P0: blocks use as a dependable production replacement.
- P1: core clinical/DICOM feature gap or runtime safety gap.
- P2: useful feature completion or correctness hardening.
- P3: docs, examples, cleanup, or test hygiene.

## Executive Summary

The package is not just a minimal decoder: it contains a broad DICOM toolkit
surface with file parsing, codecs, SwiftUI views, CLI, DICOMweb, DIMSE, SR, RT,
SEG, SC, waveform, video, and benchmark code. The main incomplete areas are:

1. Compressed transfer syntax behavior is explicit but conditional. HTJ2K
   decoding requires preflighted OpenJPEG 2.5+ with its HT block decoder;
   qualified JPEG 2000 and JPEG-LS shapes can use the linked J2KSwift and
   JLSwift async routes according to their rollout policies. Legacy routes use
   ImageIO/OpenJPEG and CharLS. JPEG Extended 12-bit grayscale has a native
   decoder. JPEG Lossless supports conformant restart intervals and interleaved
   RGB8 but not separate scans or other color shapes. Video remains a stream
   rather than native decoded frames. `DicomTransferSyntaxRegistry` separates
   static support from runtime and pixel-profile qualification.
2. Writing/transcoding scope is explicit. Native and Deflated datasets,
   referenced JPIP metadata, and encapsulated Pixel Data passthrough are covered.
   Async `DicomTranscoder` also executes qualified JPEG 2000/HTJ2K encoding via
   J2KSwift and JPEG-LS encoding via JLSwift with explicit encoding intent.
   JPEG XL remains experimental and opt-in; other compressed encoders remain
   unavailable. Source decoding and requested output verification impose their
   own runtime requirements.
3. `DicomSeriesLoader` now declares and tests its package-only volume scope:
   single-frame, uncompressed 8/16/32-bit MONOCHROME1/2 grayscale inputs are
   normalized into `Int16` buffers, while compressed, color, explicit planar,
   and multiframe inputs are rejected with typed pixel metadata.
4. Networking is implemented beyond what older docs claimed, but it still needs
   a parity audit before Isis can rely on it as a DICOM-Swift replacement.
   DICOMweb now has a tested helper matrix for QIDO/WADO/STOW/BulkDataURI,
   UPS-RS, auth hooks, TLS trust choices, pagination, multipart handling,
   streamed bodies, and stable error semantics; production persistence,
   authorization and audit policy, and JPIP proxying remain intentionally
   outside that scope.
5. Example and SwiftUI preview support is now explicitly scoped: the macOS
   document picker and thumbnail-backed slice shortcut strip are implemented,
   while preview mocks remain public preview-only API rather than clinical
   decoder support.
6. Test coverage is broad, but many tests skip without local fixtures or
   external runtimes such as OpenJPEG, CharLS, DICOM-Swift, `opj_compress`, Metal, or
   network smoke-test env vars.
7. A preview mock is shipped from `Sources/DicomSwiftUI`, not only from tests.
   That is now intentionally accepted and documented as preview-only public API.

## Codec/Volume Implementation Order (issue #1225)

Decision of record for the codec/volume robustness series. GDCM remains the
production pixel/volume backend in Isis; this order makes DICOM-Swift more
robust as a toolkit and never flips a path to "supported" without
fixture-backed tests landing first. Typed unsupported behavior is preserved
until each step genuinely implements its path
(`CodecVolumeRobustnessBaselineTests` pins the pre-implementation state).

1. **#1226 — Encapsulated pixel frame extraction primitives.** DONE:
   `DicomEncapsulatedPixelFrameReader` (via
   `DCMDecoder.makeEncapsulatedPixelFrameReader()`) gives codec-agnostic
   per-frame payload access for every encapsulated syntax with typed
   errors; #1227's codec resolver and #1233's series loader consume it.
2. **#1227 — Production decoded frame reader API.** DONE:
   `DicomDecodedFrameReader` opens a Part 10 file/dataset and returns
   typed decoded frames (gray8/gray16/rgb8 plus renderer metadata) with
   one `ReadError` surface for native, RLE, JPEG, JPEG-LS, JPEG 2000 and
   unsupported syntaxes; per-frame extraction keeps multiframe access
   memory-bounded and the async paths honor cancellation. Later codec
   steps (#1228-#1231) plug into its backend resolver.
3. **#1228 — JPEG Extended 12-bit precision-preserving decode.** DONE:
   `JPEGExtendedDecoder` decodes SOF0/SOF1 single-component sequential
   Huffman scans natively (restart intervals included); the backend
   resolver routes by BitsStored — >8-bit grayscale decodes natively at
   full precision, <=8-bit stays on ImageIO, and color/high-bit-depth
   combinations fail typed naming transfer syntax, bit depth,
   photometric interpretation, and samples per pixel.
4. **#1229 — JPEG Lossless restart intervals + multicomponent.** DONE:
   `JPEGLosslessDecoder` parses DRI, validates RSTn order, resets
   prediction per T.81 H.1.2 at interval boundaries (interval first line
   uses Ra for every selection value), and decodes single interleaved
   scans of 1 or 3 components; 8-bit interleaved RGB flows through to
   `pixels24`, while other color shapes fail with diagnostics naming
   transfer syntax, photometric interpretation, and samples per pixel.
5. **#1230 — JPEG-LS/CharLS and JPEG 2000/OpenJPEG release determinism.**
   DONE: decision of record — CharLS/OpenJPEG are system dependencies
   loaded dynamically (never bundled), overridable per runtime via
   `DICOM_DECODER_<RUNTIME>_LIBRARY_PATH`. `DicomCodecCapabilities` is
   the single capability API (backend, version, path, source, bit
   depths, unsupported reason); `require()` adds a major-version (2.x)
   compatibility check to the existing missing-library/invalid-path/
   missing-symbols typed errors; `test_gates.sh release` exports
   `DICOM_REQUIRE_CHARLS=1`/`DICOM_REQUIRE_OPENJPEG=1` so release
   candidates fail fast without active backends.
6. **#1231 — HTJ2K backend behind explicit capability checks.** DONE:
   HTJ2K decodes through the preflighted OpenJPEG runtime only when it
   includes the HT block decoder (version 2.5+, checked explicitly via
   `DicomJPEG2000Codec.supportsHTJ2K`); the ImageIO JPEG 2000 fallback is
   never used. Curated reversible fixture
   (`DecoderParity/htj2k_lossless_parity.dcm`, generated with OpenJPH)
   pins the decoded pixel hash.
7. **#1232 — High-bit-depth color and YBR display conversion.** DONE:
   RGB display conversion accepts 16-bit-allocated samples (scaled by
   Bits Stored; interleaved and planar) and `displayRGB48PixelBuffer`
   preserves the full stored precision; palette LUT descriptor offsets
   clamp deterministically; YBR_PARTIAL_420 stays a typed rejection;
   YBR_RCT/YBR_ICT are owned by the JPEG 2000 codec backend (OpenJPEG
   reverses the transform and outputs RGB through the decoded-frame
   path) and native data with those labels is rejected; color images
   never surface as grayscale buffers.
8. **#1233 — Feed DicomSeriesLoader from supported compressed decoders.**
   DONE: compressed single-frame grayscale slices decode once per slice
   through `DicomDecodedFrameReader` straight into the Int16 volume
   buffer (no whole-image pixel cache), with the same geometry, rescale,
   ordering, and stored-value semantics as uncompressed series (parity
   tested). The support matrix flips `supportsCompressedTransferSyntaxes`
   to true; syntaxes without an active decode backend fail typed with
   transfer syntax and pixel metadata.
9. **#1234 — Enhanced CT/MR multiframe volume assembly.** DONE:
   `DicomSeriesLoader.loadEnhancedMultiframeVolume(at:)` assembles one
   multiframe object using Shared/Per-Frame Functional Groups (Plane
   Position ordering along the normal, Plane Orientation consistency,
   Pixel Measures spacing, per-frame Pixel Value Transformation rescale
   with top-level fallback); frames decode one at a time through
   `DicomDecodedFrameReader`, so compressed multiframe objects share the
   native path. Shared and Per-Frame Frame VOI values are preserved per
   spatially ordered slice, with the first valid Frame VOI window used as the
   deterministic volume default and top-level Window Center/Width as fallback.
   Unsupported shapes fail typed with SOP Class, frame
   count, transfer syntax, and missing functional-group context. The qualified
   scope is one spatial stack; Dimension Organization / multi-stack
   partitioning (#1554) remains a follow-up.

Compressed dataset writing preserves caller-provided encapsulated payloads;
that writer contract is separate from the executable async encoding routes.
`DicomTransferSyntaxRegistry` exposes per-entry `encoderSupport` alongside
`writeSupportMatrix`; `DicomTranscoder.preflight` qualifies the actual source,
destination, encoding intent, pixel shape, runtime, and verification request.

## Implementation Gaps

### 1. Compressed Pixel Codec Parity

Priority: P0 if DICOM-Swift is expected to replace production pixel decoding;
P1 if it remains an optional metadata/networking track.

Status: #1065 establishes a tested compressed pixel support matrix with explicit
`decoded`, `delegated`, `streamed-only`, `unsupported`, and `out-of-scope`
statuses. Remaining items below are future backend decisions, not implicit
claims of current support.

Evidence:

- `Sources/DicomData/DicomTransferSyntaxRegistry.swift` exposes
  `compressedPixelSupportMatrix` for every compressed, referenced, and video
  pixel transfer syntax tracked by the package.
- `Tests/DicomCoreTests/DicomCompressedPixelCodecMatrixTests.swift` asserts the
  matrix, fixture-backed positive paths, stable unsupported diagnostics, and
  multi-component context.
- `Sources/DicomCore/DicomCompressedPixelBackendRegistry.swift` resolves native
  JPEG Extended 12-bit grayscale, ImageIO 8-bit JPEG/JPEG 2000, and preflighted
  OpenJPEG/CharLS paths with explicit pixel-profile limits.
- `Sources/DicomCore/DicomJ2KSwiftBackend.swift` qualifies JPEG 2000 CPU decode
  and JPEG 2000/HTJ2K encode for aligned 1–16-bit grayscale and unsigned RGB8.
  HTJ2K candidate decoding is not qualified for production selection.
- `Sources/DicomCore/DicomCodecCapabilities+Resolution.swift` applies rollout,
  preference, intent, and runtime gates. HTJ2K `.201`–`.203` production decode
  requires OpenJPEG 2.5+; there is no ImageIO fallback for HTJ2K.
- `Sources/DicomData/DicomTransferSyntaxRegistry.swift` records conditional
  `decoderSupport` and `encoderSupport` separately from `writeSupportMatrix`.
  JPIP `.204/.205` is streamed-only, and video frame encoding is unavailable.

Future backend work, if DICOM-Swift needs broader native pixel replacement:

- Qualify a J2KSwift HTJ2K decoder against independent fixtures before enabling
  it in production; retain OpenJPEG as the established route until then.
- Make standalone OpenJPEG/CharLS runtime availability deterministic where the
  selected decode or verification route requires those libraries.
- Qualify JPEG 2000 color output above 8 bits per component if required.
- Decide whether video syntaxes should gain native frame decode.
- Add encoders for the remaining unsupported families only when required;
  preserve the existing explicit intent and pixel-fidelity qualification gates.

### 2. JPEG Lossless Restart Intervals and Multi-Component Images

Priority: P1.

Status: the native decoder supports Process 14 DRI/RSTn restart intervals and
single interleaved scans with one grayscale or three 1x1-sampled components.
The decoded-frame path exposes qualified 8-bit RGB; unsupported color shapes
retain typed diagnostics with transfer-syntax and pixel metadata context.

Evidence:

- `Sources/DicomCore/JPEGLosslessDecoder+MarkerParsing.swift` requires the
  exact two-byte DRI payload and reads the big-endian MCU interval.
- `Sources/DicomCore/JPEGLosslessDecoder+PixelDecoding.swift` requires
  row-aligned lossless intervals, consumes RST0 through RST7 in sequence, and
  resets prediction independently for every component.
- `Sources/DicomCore/BitStreamReader.swift` permits JPEG fill bytes but rejects
  entropy garbage, invalid padding, missing RSTn, and non-RST markers at an
  interval boundary.
- `Tests/DicomCoreTests/JPEGLosslessRestartIntervalTests.swift` verifies exact
  8-, 12-, and 16-bit output across multiple intervals, unchanged no-restart
  output, and typed malformed-stream failures.
- `Tests/DicomCoreTests/JLISwiftJPEGLosslessQualificationTests.swift`
  cross-decodes row-aligned 8-, 12-, and 16-bit streams with the independent
  test-only JLISwift implementation.

Remaining scope is explicit: separate-component scans, non-RGB photometric
interpretations, and color above 8 bits per component require a different
qualified route. Point-transform and multi-scan expansion must land with an
independent oracle before their support status changes.

### 3. JPEG-LS and JPEG 2000 Runtime Dependency Handling

Priority: P1.

Evidence:

- `Sources/DicomCore/DicomJPEG2000Codec.swift` requires OpenJPEG at runtime.
- `Sources/DicomCore/DicomJPEGLSCodec.swift` requires CharLS at runtime.
- Tests such as `Tests/DicomCoreTests/DicomLosslessCodecTests.swift:94` and
  `Tests/DicomCoreTests/DicomLossyCodecBackendTests.swift:28` skip when these
  runtimes are unavailable.

Implement:

- Replace lazy `fatalError` symbol fallbacks with full symbol validation before
  `isAvailable` becomes true.
- Decide whether OpenJPEG and CharLS are optional developer dependencies or
  bundled/release dependencies.
- Add an install/diagnostic command that clearly reports which codec paths are
  active on the current machine.

Mitigation added for #1076:

- OpenJPEG and CharLS loaders validate required symbols before reporting
  availability. Missing runtimes or missing symbols now throw
  `DICOMError.unsupportedTransferSyntax` instead of aborting at call sites.

Mitigation added for #1066:

- `DicomCodecRuntimePreflight` is the package-level capability API for CharLS
  and OpenJPEG. It reports available, missing-library, invalid-path, and
  missing-symbol states and supports `DICOM_DECODER_CHARLS_LIBRARY_PATH` and
  `DICOM_DECODER_OPENJPEG_LIBRARY_PATH` overrides for local and CI installs.
- `DicomJPEGLSCodec`, `DicomJPEG2000Codec`, and `DicomTestRuntimePreflight`
  now resolve codec runtime availability through that shared API.
- `DicomCodecRuntimePreflightTests` cover present libraries, absent library
  candidates, invalid override paths, unsupported symbol sets, and typed decode
  failure behavior.

### 4. Transfer Syntax Writing and Transcoding

Priority: P1 for interchange workflows, P2 for read-only workflows.

Evidence:

- `Sources/DicomData/DicomDataSetWriter.swift` validates writer support before
  generating Part 10 or raw dataset bytes.
- `Sources/DicomData/DicomTransferSyntaxRegistry.swift` exposes
  `writeSupportMatrix` with `native-dataset`, `deflated-dataset`,
  `referenced-dataset`, and `encapsulated-pass-through` statuses.
- `Tests/DicomCoreTests/DicomDataSetWriterTests.swift` covers native round-trip,
  Deflated round-trip, compressed passthrough, unsupported compressed write,
  unsupported decompression-to-native reserialization, referenced JPIP metadata,
  and metadata preservation.
- `Tests/DicomCoreTests/DicomTransferSyntaxRegistryTests.swift` verifies writer
  matrix coverage for every recognized transfer syntax.
- `Sources/DicomCore/DicomTranscoder.swift` executes native rewriting,
  decompression, and qualified async compressed encoding after preflight.
- `Sources/DicomCore/DicomJ2KSwiftBackend.swift` provides JPEG 2000 and HTJ2K
  encoders; `Sources/DicomCore/DicomJLSwiftBackend.swift` provides JPEG-LS
  encoding. JPEG XL encoding remains an explicit experimental route.
- `Tests/DicomCoreTests/DicomJ2KSwiftEncoderTests.swift` and
  `Tests/DicomCoreTests/DicomCodecWorkflowEngineTests.swift` exercise encoded
  artifacts, transfer syntax, metadata, and decoded pixel parity.

Future backend work:

- Expand encoder coverage only for additional required syntaxes and shapes.
- Qualify each new source/destination route with metadata and pixel-fidelity
  round trips, including the runtime needed for output verification.

### 5. Volume Assembly Scope Is Declared and Package-Only

Priority: P0 if DICOM-Swift should feed Isis/MTK volumes directly; P2 if GDCM
continues to own production volume decoding.

Status: #1068 expands the package loader to signed and unsigned 8-bit,
16-bit, and 32-bit grayscale inputs where they can be normalized into the
existing `Int16` volume model. It also exposes `DicomSeriesLoaderSupportMatrix`
and contextual pixel-format errors, and keeps Isis production rendering on GDCM.

Evidence:

- `Sources/DicomCore/DicomSeriesLoader.swift` defines
  `DicomSeriesLoaderSupportMatrix.standard` for Bits Allocated 8/16/32,
  Bits Stored 1 up to Bits Allocated with High Bit = Bits Stored − 1 (#2781),
  Pixel Representation 0/1, Samples per Pixel 1,
  MONOCHROME1/2, absent Planar Configuration, single-frame files, uncompressed
  transfer syntaxes, rescale, spacing, orientation, and slice ordering
  behavior.
- `Sources/DicomCore/DicomSeriesLoader+Helpers.swift` normalizes supported
  source samples into `Int16` output voxels and clamps 32-bit values to the
  buffer representation.
- `Tests/DicomCoreTests/DicomSeriesLoaderTests.swift` covers supported 8-bit and
  32-bit signed/unsigned grayscale assembly plus typed rejection of compressed,
  multiframe, and RGB input contexts.

Future backend work:

- Route compressed frames through the codec resolver before volume assembly if
  DICOM-Swift becomes a production volume source.
- Add multiframe volume assembly and color/parametric-map handling only after a
  runtime consumer needs those shapes.
- Implement or remove the `intermediateData` progress payload.
- Add clinical fixture tests for any future expanded compressed or multiframe
  volume path.

### 6. Color Display Conversion Coverage

Priority: P1 for color modalities and secondary capture; P2 for grayscale-only
workflows.

Status: #1069 establishes an explicit display conversion matrix with
fixture-backed positive checks and contextual unsupported-path errors. Remaining
items below are future color conversion backend decisions, not implicit display
support claims.

Evidence:

- `Sources/DicomCore/DicomColorPixelData.swift` exposes
  `DicomColorDisplayConversionMatrix.standard` for MONOCHROME1, MONOCHROME2,
  RGB, PALETTE COLOR, YBR_FULL, YBR_FULL_422, YBR_PARTIAL_420, YBR_RCT, and
  YBR_ICT.
- `DicomColorConversionError.unsupportedColorPath` reports Photometric
  Interpretation, Samples per Pixel, Planar Configuration, Bits Allocated, and
  Transfer Syntax context for unsupported display paths.
- `Tests/DicomCoreTests/DicomColorPixelDataTests.swift` asserts the matrix,
  MONOCHROME expected RGB output, RGB interleaved and planar output, PALETTE
  COLOR lookup output, YBR_FULL output, YBR_FULL_422 output, and contextual
  errors for unsupported YBR, alpha/extra samples, planar layout, and bit depth.
- `Sources/DicomCore/DicomImagePreprocessor.swift` routes color frames through
  `displayRGBPixelBuffer(frame:)`; unsupported color images throw instead of
  being presented as successfully decoded grayscale output.

Future backend work, if broader color display conversion becomes in scope:

- Add high-bit-depth RGB/YBR display conversion if 10/12/16-bit color output is
  required.
- Add real YBR_PARTIAL_420, YBR_RCT, or YBR_ICT conversion only when a validated
  use case and fixtures exist.
- Add clinical non-PHI color fixtures beyond the synthetic Part 10 fixtures
  when color modalities become part of the package release gate.

### 7. DICOMweb Is Scoped to Tested Helpers, Not a Full Production PACS Stack

Status: scoped and guarded. This is no longer an ambiguous conformance gap, but
it remains a deliberate product limitation unless DICOM-Swift is later chosen
as the production DICOMweb stack.

Current tested scope:

- `Sources/DicomCore/DicomWebServer.swift` exposes
  `DicomWebConformanceMatrix.packageDefault`, and `/dicom-web/conformance`
  emits the matrix for QIDO-RS, WADO-RS metadata/instance/frame/rendered-frame,
  WADO-URI, STOW-RS, UPS-RS, BulkDataURI, JPIP, multipart, authentication,
  pagination, error semantics, and large-payload streaming responsibility.
- `Sources/DicomWebClient/` (the `DicomWebClient` product) serializes QIDO-RS
  at study, series and instance level with a pager that returns each result
  once and stops at configured limits; WADO-RS metadata, decoded one data set
  at a time and read tolerantly; study, series, instance, frame, rendered and
  thumbnail retrieval into sinks, with ordered Accept lists that ask again
  after a fallback status; WADO-URI; STOW-RS; and BulkDataURI retrieval,
  including relative references and byte ranges, through the configured
  `DicomWebHTTPTransport`. STOW bodies held in memory use an exact
  configurable budget with a 128 MiB default; files stream from disk, and
  `storeFiles` reports each file of a batch from the Annex I response. Their
  Part 10 File Meta transfer syntax is derived for a `nil` declaration or
  checked against an explicit declaration. Raw non-Part-10 payload labeling
  remains caller-owned. The client also carries the opt-in retry policy,
  per-request authorization providers (`DicomWebOIDC` supplies one), and HTTPS
  trust and mutual TLS choices.
- `Sources/DicomCore/DicomWebServer*.swift` implements provider-backed QIDO at
  the three levels with limit/offset pagination and Warning 299, WADO metadata,
  instance, frame, rendered and thumbnail retrieval, WADO-URI, provider-backed
  BulkDataURI routes, streaming STOW of Part 10 payloads with the Annex I
  response, UPS-RS when a service is injected, injected bearer, Basic or JWT
  authentication, content negotiation, multipart handling, and cache
  diagnostics. `Sources/DicomWebHTTP/` adds an optional HTTP listener that can
  terminate TLS.
- `Tests/DicomWebClientTests/`, `Tests/DicomWebHTTPTests/`, and the
  `Tests/DicomCoreTests/DicomWeb*Tests.swift` suites cover HTTP serialization,
  multipart parsing and boundaries, content negotiation and Accept fallback,
  status codes and retries, auth hooks and TLS trust, BulkDataURI
  preservation/retrieval, QIDO pagination, STOW batches, conformance matrix
  contents, and large multipart payload preservation.
- `Tests/DicomCoreTests/DicomInteropSmokeTests.swift`, run by
  `Scripts/interop/run_interop_smoke.sh`, exercises the client against
  Orthanc and dcm4chee: STOW-RS in batches with one refused instance, paged
  QIDO-RS with `limit=1`, WADO-RS retrieve of a study, series and instance,
  frames with `transfer-syntax=*` and plain `application/octet-stream`, a
  refused Accept followed by the fallback request, the pixel data and palette
  color LUT `BulkDataURI` values, and, on a second Orthanc, Basic
  authentication. The script rejects
  the smoke study on dcm4chee (`113039^DCM`) after each run so it can be
  repeated. Recorded runs, 2026-10-04: Orthanc 1.13.0 with DICOMweb plugin
  1.24 passed all 11 smoke tests in three consecutive runs without Docker, and
  dcm4chee 5.35.2 with Orthanc 1.13.0 in Docker passed them in two consecutive
  runs, with the rejection cleanup between them. dcm4chee refuses an Accept it
  cannot transcode with 500 instead of 406, which a `DicomWebAcceptList`
  follows to its next range since 2.0.2, and gives all representations of an
  instance one `ETag` without `Vary: Accept`; since 2.0.1 the client's
  URLSession transport neither reads nor writes the URL cache.
- `DicomWebIndependentClientTests` (dicomweb-client 0.61.2) and
  `DicomWebUPSRSIndependentTests` (`requests`, `websockets` 17.1) are
  independent Python witnesses of the package's DICOMweb listener; both passed
  without skip on 2026-10-04.
- `Sources/DicomCore/DicomCore.docc/Articles/ConformanceStatement.md` documents
  that the DICOMweb surface is a helper API, not a complete production PACS
  client/server.

Future backend work, if a production DICOMweb stack becomes the target:

- Add persistent storage, production authorization, PHI audit logging,
  deployment guidance, and operational metrics.
- Add JPIP proxying through DICOMweb only if the package should own that network
  path; the current JPIP design remains caller-supplied `DicomJPIPTransport`.

### 8. DIMSE and Network Scope Is Reconciled to Tested Helpers

Priority: P0 for production PACS replacement planning; P2 for package helper
maintenance.

Status: scoped and guarded. DIMSE is no longer an ambiguous documentation gap,
but it remains a helper/parity surface rather than a managed PACS service.

Current tested scope:

- `Sources/DicomNetwork/DicomDIMSENetwork.swift`, the
  `Sources/DicomCore/DicomDIMSEServiceSCU*.swift` facade and operation files,
  `Sources/DicomCore/DicomDIMSEMessageReader.swift`, and
  `Sources/DicomCore/DicomTCPAssociationTransport.swift` implement association,
  PDU parsing and transport, C-ECHO, C-FIND, C-MOVE, C-GET, C-STORE, MPPS,
  Basic Grayscale Print, progress, cancellation, retry, circuit-breaker,
  user-identity, and TLS configuration behavior.
- `Sources/DicomCore/DicomStorageSCP.swift` implements Storage SCP handling,
  file cache writes, Storage Commitment tracking/report datasets, listener
  configuration, and TLS listener preflight where platform support is present.
- `Tests/DicomCoreTests/DicomDIMSEServiceSCUTests.swift`,
  `Tests/DicomCoreTests/DicomStorageSCPTests.swift`, and interop smoke tests
  cover the helper scope and external-archive prerequisites.
- `Sources/DicomCore/DicomCore.docc/Articles/ConformanceStatement.md` now
  contains a DIMSE and Storage SCP helper matrix that matches this tested scope.

Future backend work, if DICOM-Swift becomes a production PACS/network stack:

- Add always-on external archive CI against the chosen Orthanc/dcm4che/DICOM-Swift
  targets instead of optional smoke endpoints.
- Add production authorization, PHI audit policy, deployment monitoring,
  archive retention policy, and operational metrics.
- Expand Storage Commitment and print services only where product workflows
  require those DIMSE services.

### 9. Structured Report Semantics Are Explicitly Scoped

Priority: P2 for templates outside TID 1500 and KOS.

Evidence:

- `Sources/DicomCore/DicomStructuredReportValidation.swift` declares the
  semantic support matrix for Enhanced SR and Comprehensive SR TID 1500 plus
  Key Object Selection references.
- `Tests/DicomCoreTests/DicomStructuredReportTests.swift` validates supported
  TID 1500/KOS content, unsupported templates, unsupported relationship
  patterns, coded concepts, measurement units, observation context, and
  syntactic parsing without semantic success.

Implement:

- Add additional SR template validators only when a workflow claims semantic
  support for that template.
- Expand CAD SR, Comprehensive 3D SR, and Extensible SR semantics beyond
  syntactic tree parsing and extraction.
- Add fixture-backed validation for each newly supported SR template.

### 10. Undefined-Length Non-SQ Elements Remain Unsupported

Priority: P2.

Evidence:

- `Sources/DicomData/DicomSequenceValueParser.swift` supports
  undefined-length SQ values, undefined-length items, item delimiters, sequence
  delimiters, and nested undefined-length SQ parsing.
- `Tests/DicomCoreTests/DicomSequenceValueParserTests.swift` covers explicit
  length sequences, undefined-length sequences/items, nested undefined-length
  sequences, malformed delimiters, missing delimiters, invalid item tags,
  decoder metadata caching, and following-tag parsing.
- Undefined-length non-SQ values inside parsed sequence content still throw
  `unsupportedUndefinedLengthElement`.

Implement:

- Decide whether unsupported undefined-length non-SQ values should remain a
  hard failure or gain VR-specific parsing/skip behavior with diagnostics.

### 11. Export, Secondary Capture, Print, Waveform, and Video Are Scoped

Priority: P2 unless these become broader target product workflows.

Status: scoped and guarded.

Evidence:

- `Sources/DicomCore/DicomExportSupportMatrix.swift` lists the package scope for
  image export, Secondary Capture, print management, waveform, and video.
- `Sources/DicomCore/DicomImageExporter.swift` keeps native 16-bit export scoped
  to unsigned single-sample TIFF; display export owns resize and annotation
  burn-in.
- `Sources/DicomCore/DicomSecondaryCapture.swift` keeps synthetic SC creation
  available and adds strict clinical export validation for required
  patient/study/series/instance context.
- `Sources/DicomCore/DicomPrintManagement.swift` scopes print to Basic
  Grayscale and Color Film Session, Film Box, and matching Image Box operations,
  with Basic Annotation Box and optional Printer Status support. Presentation
  LUT, Printer Configuration, Print Job monitoring, and storage commitment
  remain explicitly outside the implemented surface.
- `Sources/DicomObjects/DicomWaveform.swift` covers the listed ECG/related waveform
  IODs and SB/UB/SS/US/SL/UL integer sample interpretations.
- `Sources/DicomCore/DicomVideo.swift` preserves MPEG-2/H.264/H.265 streams and
  indexed encoded frame payloads for player handoff; native frame decode and
  transcoding fail with typed errors.

Implement:

- Expand export modes only where product workflows require them.
- Add signed 16-bit TIFF export if quantitative images must be preserved.
- Add secondary capture layouts beyond unsigned monochrome/RGB if needed.
- Add Presentation LUT, Printer Configuration, or Print Job monitoring only
  when a real print workflow needs those DIMSE services.
- Add native video frame decode/transcode only if caller/player forwarding is
  insufficient.
- Add waveform sample interpretations beyond the currently covered integer
  layouts if required by target modalities.

### 12. SwiftUI and Example Application Placeholders Are Resolved

Priority: P2 for demo/app completeness.

Evidence:

- `Examples/DicomSwiftUIExample/Services/DocumentPickerService.swift`
  provides an `NSOpenPanel`-backed macOS `DocumentPickerView` for files,
  folders, and mixed import presets.
- `SeriesNavigatorView` expanded layout uses
  `SeriesNavigatorSliceShortcutStripView`, which loads
  `SeriesNavigatorThumbnail` values through `SeriesNavigatorViewModel` and
  shows an explicit unavailable-thumbnail state when a slice cannot be decoded.
- Empty-state placeholder views exist in example views such as
  `Examples/DicomSwiftUIExample/Views/ImageViewExample.swift:108-109` and
  `SeriesNavigatorExample.swift:99-100`; these are normal UI states, not
  necessarily gaps.

Implement:

- Keep the picker and thumbnail strip covered by SwiftUI/example smoke tests.
- Keep empty-state placeholders as-is unless product design requires richer
  states.

### 13. Preview Mock Is Explicit Preview API

Priority: P2.

Evidence:

- `Sources/DicomSwiftUI/Preview/MockDicomDecoderForPreviews.swift:1-61`
  declares a public preview-only mock inside `Sources`; it is intentionally
  supported as Xcode preview API, not as a clinical/runtime decoder.
- `Sources/DicomSwiftUI/DicomSwiftUI.docc/PreviewSupport.md` documents
  `MockDicomDecoderForPreviews`, `DicomSampleData`, and `PreviewHelpers` as
  preview-only APIs and forbids clinical/runtime decoding, validation,
  conformance, or patient-data workflows.
- Test mocks under `Tests/DicomTestSupport/MockDicomDecoder.swift` and
  `Tests/DicomCoreTests/Mocks/MockLogger.swift` are legitimate test utilities.

Implement:

- Keep `MockDicomDecoderForPreviews` public only for preview support and keep
  docs/tests asserting that it is not a clinical/runtime decoder.
- Keep a single test mock source of truth for tests.

### 14. Tests Depend on Optional Fixtures, Runtime Libraries, and Environment

Priority: P1 for CI confidence, P2 for local developer convenience.

Evidence:

- The scan found 77 `XCTSkip` or `XCTSkipIf` calls in tests.
- `Tests/DicomCoreTests/Fixtures/README.md:1-34` says real DICOM fixtures are
  not included and must be downloaded.
- Existing fixture folders contain only small synthetic files:
  `CT/ct_synthetic.dcm`, `MR/mr_synthetic.dcm`, `US/us_synthetic.dcm`,
  `XR/xr_synthetic.dcm`, and `Compressed/jpeg_baseline_synthetic.dcm`.
- OpenJPEG, CharLS, DICOM-Swift, `opj_compress`, Metal, and network smoke-test
  environment variables gate parts of the suite.

Implement:

- Split tests into deterministic unit tests, deterministic bundled-fixture
  integration tests, and optional external interop tests.
- Add a CI fixture strategy for representative public DICOMs without PHI.
- Make optional codec/runtime test skips visible in CI summaries.
- Add a one-command fixture/runtime preflight.

Mitigation added for #1075:

- `Tests/DicomCoreTests/Resources/ReleaseGates/OptionalRuntimeFixtureManifest.json` declares bundled fixtures,
  optional JPEG Lossless fixtures, CharLS, OpenJPEG, `opj_compress`, DICOM-Swift
  `dcmdjpeg`, Metal, and network smoke-test preflights with CI behavior.
- `DicomTestRuntimePreflightTests` verifies the manifest and status
  classifications. Tests can require optional capabilities with
  `DICOM_REQUIRE_<CAPABILITY>=1` or `DICOM_REQUIRE_OPTIONAL_RUNTIMES=1`.
- Bundled synthetic fixtures are required in default CI; absence now fails
  instead of being hidden behind generic fixture skips.

Mitigation added for #1066:

- CharLS and OpenJPEG runtime preflight entries now point to
  `DicomCodecRuntimePreflight`, include path override variables, and list the
  focused runtime dependency tests.

### 15. SwiftPM Manifest Has Unhandled Files

Priority: P2.

Evidence from `swift test --package-path DICOM-Swift --list-tests`:

- Unhandled test files:
  `Tests/DicomCoreTests/validate_jpeg_lossless_bitperfect.sh`,
  `Tests/DicomCoreTests/PerformanceBenchmarks/Baselines/baseline-fast.json`,
  `baseline_template.json`, and `baseline-macos-arm64.json`.
- Unhandled source file:
  `Sources/DicomCore/JPEGLossless_ALGORITHM.md`.
- Unhandled example files:
  `Examples/DicomSwiftUIExample/Info.plist`, `README.md`,
  `Assets.xcassets`, and `Resources/sample.dcm`.

Implement:

- Declare real resources with `.process` or `.copy`.
- Exclude documentation/scripts that should not be packaged.
- Decide whether the example target should be a SwiftPM executable target or an
  Xcode app example with a separate project/manifest strategy.

Mitigation added for #1075:

- `Package.swift` excludes source-only docs and helper scripts, processes test
  benchmark baselines, and declares the SwiftUI example assets/resources while
  excluding its app-only `Info.plist` and README from SwiftPM target handling.

### 16. Runtime Traps Should Be Hardened

Priority: P1 for library consumers.

Evidence:

- `Sources/DicomData/DicomTransferSyntaxRegistry.swift:207` and `293` use
  `preconditionFailure` if registry coverage drifts.

Implement:

- Mark unavailable NSCoder initializers with `@available(*, unavailable)` where
  possible.
- Replace generic buffer traps with constrained APIs, typed overloads, or
  throwing/error-returning behavior.
- Validate dynamic-library symbols before claiming codec availability.
- Keep registry coverage tests, but prefer test failures over runtime
  preconditions for public API paths.

Mitigation added for #1076:

- `DICOMErrorObjC` decoding now initializes to a typed `.unknown` error instead
  of aborting.
- Unsupported generic `BufferPool` acquisitions now return an unpooled empty
  buffer with reserved capacity instead of aborting.
- `DCMWindowingProcessor` unresolved `.auto` dispatch falls back to vDSP.
- OpenJPEG and CharLS missing-symbol paths now throw typed unsupported-transfer
  errors instead of using fatal fallbacks.
- The two remaining `preconditionFailure` hits are internal registry invariants
  covered by `DicomTransferSyntaxRegistryTests`.

### 17. Dead or Deferred Internal Code

Priority: P3.

Evidence:

- `Sources/DicomCore/Synchronization.swift:87-90` keeps an unused read-write
  lock as a future optimization reference.

Implement:

- Either remove it after confirmation or add profiling-backed usage.
- Do not keep unused concurrency primitives indefinitely without a measured
  contention problem.

Mitigation added for #1076:

- Reviewed as non-production deferred code rather than a runtime trap. It
  remains tracked here as a P3 follow-up so removal can be confirmed separately.

### 18. Documentation Drift and Migration Checklist Reconciled

Priority: P2.

Status: reconciled and guarded by #1077.

Evidence:

- `Sources/DicomCore/DicomCore.docc/Articles/ConformanceStatement.md` mirrors
  the current codec, writer, DICOMweb, DIMSE, Storage SCP, SR, parser, export,
  waveform, video, SwiftUI preview, and MTK/Isis backlog boundaries.
- `Sources/DicomCore/DicomCore.docc/Articles/MigrationGuide.md` now presents a
  migration status table instead of stale unchecked project checklist items.
- `README.md` lists the same support matrices and limitations as the
  conformance statement for codecs, writing, DICOMweb, DIMSE, SR, parser, UI,
  preview mocks, and optional runtimes.
- `Tests/DicomCoreTests/DocumentationReconciliationTests.swift` fails when
  feature-table references, registry diagnostics, or migration checklist status
  drift from the documented support matrices.

Maintain:

- Keep README claims, conformance statements, and registry diagnostics aligned.
- Add or update issue references when package limitations become planned work
  instead of explicit out-of-scope behavior.

Mitigation added for #1076:

- Removed the stale network-service statement from the conformance overview;
  it now points to the tested DICOMweb/DIMSE service helpers while keeping the
  SOP table focused on file-level decoding.

## Warning Policy (Swift 6 readiness, issue #1221)

Internal code does not use deprecated DICOM-Swift APIs: the decoder
extensions read the legacy success flag through the internal
`fileReadSucceeded` accessor, and the async legacy loader goes through the
throwing `loadDicomFile(at:)`. TLS certificate and private-key material is
imported into process memory and combined with `SecIdentityCreate`, without a
temporary file-based keychain or app-level keychain entitlements.

Warnings that remain are deliberate:

- **Deprecated public APIs stay covered by tests** — suites that
  intentionally exercise the legacy surface (`setDicomFilename`,
  `dicomFileReadSuccess`, tuple-based V1 accessors, the parameterless
  decoder factory, the synchronous `Image(dicomURL:)` initializer) are
  annotated `@available(*, deprecated)` so the deliberate usage compiles
  warning-free without hiding new deprecations elsewhere.

## Mocks and Placeholders Inventory

Intentional test/support mocks:

- `Tests/DicomTestSupport/MockDicomDecoder.swift`
- `Tests/DicomCoreTests/Mocks/MockLogger.swift`
- `Tests/DicomCoreTests/TestHelpers/MockDecoderBuilder.swift`
- Inline test mocks such as `MockDicomValidator`, `MockBatchFileLoader`, and
  `FakeJPIPTransport`

Potential product-surface mock:

- `Sources/DicomSwiftUI/Preview/MockDicomDecoderForPreviews.swift`

Real placeholders or incomplete UI:

- None currently tracked in the package audit after #1074.

Stale/inaccurate placeholder-like test comments:

- `Tests/DicomCoreTests/JPEGLosslessHuffmanTests.swift:93` says full pixel
  decoding is not implemented, but current tests and source indicate JPEG
  Lossless pixel decoding exists. This comment should be updated or the missing
  case should be made explicit.
- `Tests/DicomCoreTests/Metal/MetalWindowingTests.swift:140` says Metal
  windowing in `DCMWindowingProcessor` is pending, while
  `Sources/DicomCore/DCMWindowingProcessor.swift:380-407` includes a Metal
  processing route. The test should assert the integrated behavior or the source
  should clarify what remains unintegrated.

## Recommended Implementation Order

1. Reconcile DICOM-Swift's intended role for Isis: metadata/networking parity
   only, or production pixel/volume replacement.
2. Keep documentation guardrails current when networking, DICOMweb, conformance,
   and compressed codec support change.
3. Make codec runtime availability deterministic in CI summaries when optional
   runtime coverage is expected.
4. Decide the compressed transfer syntax matrix that must be supported for the
   target product. Expand the qualified HTJ2K/JPEG 2000/JPEG-LS shapes, JPIP
   transport profile, video frame decode, and remaining encoders only as required.
5. If DICOM-Swift will feed volumes, expand `DicomSeriesLoader` beyond
   uncompressed single-channel 16-bit.
6. Keep product-target preview mocks documented as preview-only public API.
7. Add deterministic fixtures and CI preflights so optional runtime skips do not
   hide missing coverage.
8. Keep the macOS example picker and SwiftUI thumbnail strip covered by focused
   smoke tests when example app behavior changes.
