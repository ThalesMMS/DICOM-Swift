# DICOM Conformance Statement

Comprehensive DICOM conformance documentation detailing supported transfer syntaxes, SOP classes, and implementation capabilities.

## Overview

This DICOM Conformance Statement describes the capabilities and limitations of the DicomCore library (version 1.2.0) in accordance with DICOM Part 2: Conformance. DicomCore is a Swift DICOM file library for iOS 18+ and macOS 15+ that parses DICOM medical imaging files, extracts metadata, provides pixel data access with optional GPU-accelerated image processing, writes controlled Part 10 datasets, and exposes transport-injected DICOMweb service helpers covered by package tests.

**Implementation Type:** DICOM File Decoder/Writer Library with transport-injected DICOMweb helpers and JPIP progressive pixel streaming

**Primary Use Case:** Local DICOM file parsing, metadata extraction, media-directory import, dataset writing, image processing, scoped DICOMweb client/server helper tests, and progressive JPIP pixel update integration for iOS and macOS applications

**Regulatory Status:** This library is provided for development purposes and explicitly disclaims medical diagnostic use. Organizations integrating this library into medical devices are responsible for their own regulatory compliance and validation.

---

## 1. Implementation Model

### 1.1 Application Data Flow

DicomCore operates primarily as a file-level DICOM decoder. DICOMweb and JPIP helpers are opt-in surfaces with injected transports so applications can provide their own network stack:

```
DICOM File(s) → DCMDecoder → Metadata Extraction
                          → Pixel Data Extraction
                          → DCMWindowingProcessor → Display-Ready Image
```

**Key Characteristics:**
- **Local file access by default** - no production PACS server, persistent archive, TLS termination, authorization policy, or audit trail is implemented by the package
- **Scoped DICOMweb helpers** - QIDO-RS, WADO-RS, WADO-URI, STOW-RS, BulkDataURI, auth-header, pagination, multipart, and stable-error behavior are described by ``DicomWebConformanceMatrix``
- **JPIP referenced pixel data** - metadata parsing recognizes Pixel Data Provider URL and streams progressive updates through caller-provided transport
- **Controlled write operations** - Part 10 dataset writing and DICOMDIR writing for native and deflated local media workflows
- **Native image frame access** - optimized for CT/MR single-frame images and uncompressed Enhanced Multi-frame metadata/frame workflows
- **Modality-agnostic parsing** - reads any valid DICOM file format

### 1.2 Functional Definition

DicomCore provides the following functional capabilities:

| Capability | Description | Status |
|------------|-------------|--------|
| **File Format Parsing** | Read DICOM Part 10 files with preamble and File Meta Information | ✅ Supported |
| **Metadata Extraction** | Extract DICOM data elements by tag ID | ✅ Supported |
| **Sequence Element Parsing** | Parse explicit/undefined SQ values, nested items, and delimiter errors | ✅ SQ |
| **Pixel Data Decoding** | Decompress and decode pixel data to raw buffers | ✅ Supported |
| **Image Processing** | Apply window/level transformations with CPU or GPU | ✅ Supported |
| **Series Loading** | Load/order package-only single-frame uncompressed 8/16/32-bit MONOCHROME1/2 grayscale series into `Int16` volumes; reject compressed/color/multiframe inputs with pixel context | Scoped grayscale matrix |
| **DICOMDIR Media Import** | Read/write DICOMDIR records and resolve local file references | ✅ Supported |
| **Enhanced Multi-frame Functional Groups** | Parse shared/per-frame geometry, timing, pixel measures, and source references | ✅ Supported for uncompressed native pixel data |
| **Quantitative Values** | Parse Real World Value Mapping linear/LUT items and calculate PET SUV variants when required metadata is present | ✅ Supported for uncompressed native pixel data |
| **Encapsulated Pixel Data Indexing** | Parse Basic Offset Table, Extended Offset Table, fragments, and frame-to-fragment mappings | Supported before codec decode |
| **DICOM Segmentation** | Parse binary/fractional SEG frames, preserve segment/source/geometry metadata, and build synthetic SEG datasets | ✅ Synthetic binary and fractional |
| **Radiotherapy Objects** | Parse RTSTRUCT contours, RTDOSE scaled volumes, and RTPLAN beam/control point metadata | ✅ Synthetic RT objects |
| **Parametric Map** | Parse integer, Float Pixel Data, and Double Float Pixel Data scalar maps with units, quantity definitions, RWV, geometry, and source references | ✅ Synthetic PM |
| **Structured Reports and Key Objects** | Parse SR/KOS content trees, measurements, ROI/source references, CAD findings, and key image references; build controlled SR/KOS datasets; validate Enhanced/Comprehensive SR TID 1500 and KOS references through an explicit support matrix | ✅ Synthetic SR/KOS with scoped semantics |
| **Secondary Capture Objects** | Build RGB/monochrome snapshot datasets, parse SC metadata/source references, and write Part 10 SC files | ✅ Synthetic SC |
| **Inference Output Objects** | Build external inference outputs as SR findings, SEG masks, GSPS graphics, and derived images with source references and tracking identifiers | ✅ Synthetic SR/SEG/GSPS |
| **Encapsulated Documents** | Build, parse, and export Encapsulated PDF/CDA/STL payloads with MIME, title, concept, and source instance metadata | ✅ Synthetic DOC |
| **Waveform Objects** | Build and parse ECG/related temporal signal objects with channel samples, sampling frequency, units, and waveform references | ✅ Synthetic ECG |
| **Video Objects** | Build and parse Video Endoscopic/Microscopic/Photographic objects, preserving MPEG-2/H.264/H.265 streams and timing metadata for player handoff | ✅ Synthetic video |
| **JPEG 2000 Part 2 Volume Documents** | Decode multi-component component collections into `DicomSeriesVolume` buffers with geometry metadata | ⚠️ Best-Effort OpenJPEG runtime |
| **JPIP Progressive Pixel Data** | Recognize referenced pixel URLs and expose ordered progressive volume update streams with cancellation/backpressure | ⚠️ Transport-injected client |
| **Transfer Syntax Conversion** | Plan safe conversion paths and execute qualified explicit-intent codec routes, including experimental JPEG XL | Planning API, typed guards, and `DicomTranscoder` |
| **DICOMweb Service Helpers** | Serialize and test scoped QIDO-RS, WADO-RS, WADO-URI, STOW-RS, BulkDataURI, auth-header, pagination, multipart, and stable-error behavior | Scoped matrix |
| **Production PACS Networking** | Persistent archive, full UPS, server-side rendered frames, JPIP proxying, authorization policy, PHI audit logging, TLS termination, and zero-copy large-payload streaming | ❌ Not Supported |
| **DICOM File Creation** | Write native/Deflated Part 10 datasets, referenced JPIP metadata, DICOMDIR files, and caller-provided encapsulated pixel/video streams without recompression | ✅ Supported with scoped writer matrix |

### 1.3 DICOMweb Service Helper Matrix

The DICOMweb surface is a helper API, not a complete production PACS client or
server. The authoritative runtime matrix is
``DicomWebConformanceMatrix/packageDefault`` and is exposed by
``DicomWebServer`` at `/dicom-web/conformance`.

| Feature | Client | Server | Responsibility | Notes |
| --- | --- | --- | --- | --- |
| QIDO-RS | supported | study-level supported | `DicomWebClient`/`DicomWebServer` | Study search supports tested metadata filters plus `limit`/`offset` pagination. |
| WADO-RS metadata | supported | supported | `DicomWebClient`/`DicomWebServer` | Client parses DICOM JSON; server emits DICOM JSON or XML. |
| WADO-RS instance | supported | supported | `DicomWebClient`/`DicomWebServer` | Instance retrieval uses `multipart/related` `application/dicom` payloads. |
| WADO-RS frame | transport-injected | stable 501 | Remote DICOMweb service or caller transport | Client serializes frame retrieval; in-memory server returns `DICOMWEB_FRAME_RETRIEVAL_UNSUPPORTED`. |
| WADO-RS rendered frame | transport-injected | stable 501 | Remote DICOMweb service or caller renderer | Client serializes rendered-frame retrieval; in-memory server returns `DICOMWEB_RENDERED_FRAME_UNSUPPORTED`. |
| WADO-URI | supported | supported | `DicomWebClient`/`DicomWebServer` | Object retrieval is covered by HTTP serialization tests. |
| STOW-RS | supported | supported for Part 10 payloads | `DicomWebClient`/`DicomWebServer` | Multipart boundaries and payload preservation are covered by tests. |
| UPS-RS | deferred | stable 501 | Deferred P2 work | UPS routes return `DICOMWEB_UPS_DEFERRED`. |
| BulkDataURI | transport-injected | unsupported | `DicomWebClient` or caller transport | DICOM JSON values are preserved; `retrieveBulkData` fetches absolute or relative URIs through the configured transport. |
| JPIP | caller-supplied transport | unsupported | `DicomJPIPClient` with `DicomJPIPTransport` | JPIP progressive pixel delivery is not proxied through `DicomWebServer`. |
| Multipart | supported | supported | `DicomWebMultipartParser` and STOW/WADO helpers | `multipart/related` parsing and emission are tested, including large payload preservation. |
| Authentication | caller headers | optional bearer token | Application security layer | No authorization policy, TLS termination, or PHI audit trail is implemented by the in-memory server. |
| Pagination | `limit`/`offset` query items | `limit`/`offset` applied | `DicomWebQuery` and server QIDO | Server pagination is deterministic over the in-memory study list. |
| Error semantics | stable typed errors | stable HTTP status and error-code headers | `DicomWebClientError` and `DicomWebServerErrorCode` | Unsupported routes use `501` plus `X-DICOMweb-Error-Code`; missing resources use HTTP status codes. |
| Large payload streaming | Data-backed request bodies | Data-backed responses | Caller-provided transport for zero-copy streaming | The package preserves large multipart payloads, but true streaming is outside this helper API. |

### 1.4 DIMSE and Storage SCP Helper Matrix

The DIMSE surface is a package helper for tested SCU/SCP workflows and
DICOM-Swift-parity validation, not a full managed PACS service. Applications still
own deployment, archive policy, PHI audit logging, operator authorization, and
remote archive qualification.

| Feature | Supported Surface | Responsibility | Notes |
| --- | --- | --- | --- |
| C-ECHO | Verification SCU | `DicomDIMSEServiceSCU.verify` | Association negotiation, progress, retry, timeout, and success status are covered by package tests. |
| C-FIND | Study Root and Modality Worklist SCU | `DicomDIMSEServiceSCU.find` and `findModalityWorklist` | Pending identifiers, final status, and scheduled procedure step mapping are tested. |
| C-GET | Study Root retrieve SCU with C-STORE suboperation handling | `DicomDIMSEServiceSCU.get` | Per-instance delivery after the C-STORE response and collector compatibility are tested. |
| C-MOVE | Study Root retrieve SCU | `DicomDIMSEServiceSCU.move` | Pending/completed suboperation progress and move destination AE title propagation are tested. |
| C-STORE | Storage SCU and Storage SCP | `DicomDIMSEServiceSCU.store`, `DicomStorageSCPService`, `DicomStorageSCPServer` | Part 10 payload parsing, transfer-syntax mismatch rejection, file cache writes, and association handling are tested. |
| Storage Commitment | Push-model tracking/report helpers | `DicomStorageCommitmentTracker` and `DicomStorageSCPService` | Commitment event report datasets and partial success reports are tested; production archive policy is caller-owned. |
| MPPS | N-CREATE and N-SET SCU helpers | `DicomDIMSEServiceSCU.createMPPS` and `updateMPPS` | Modality worklist-derived create/update datasets are covered by package tests. |
| Basic Grayscale Print | Basic Grayscale Print Management Meta SOP Class | `DicomPrintJob` and `DicomDIMSEServiceSCU.sendPrintJob` | Color print, Presentation LUT service, annotation boxes, printer configuration/status services, and storage commitment remain unsupported. |
| TLS | Client and Storage SCP listener configuration | `DicomTLSConfiguration` and `DicomTLSOptionsFactory` | Certificate, private-key, trust-store, server-name, BCP 195 profile, and handshake behavior are tested where Network/Security are available. |
| User identity | Association user identity negotiation | `DicomUserIdentity` | User identity is rejected before association setup when TLS is disabled. |
| Pooling/retry/cancellation | Association pooling, retry policy, circuit breaker, operation handle, progress, and audit log | `DicomDIMSEAssociationPool`, `DicomNetworkRetryPolicy`, `DicomNetworkCircuitBreaker`, `DicomDIMSEOperationHandle` | Cancellation avoids retries and circuit-breaker trips; pooling keys include node, AE titles, TLS, identity, transfer syntaxes, timeout, and bandwidth settings. |
| External archive interop | Optional smoke tests and scripts | `DicomInteropSmokeTests` and interop tooling | Orthanc/dcm4che/DICOM-Swift smoke tests require caller-provided endpoints and are not bundled production services. |

### 1.5 Export and Non-Image Object Matrix

Export, Secondary Capture, print, waveform, and video helpers are scoped by
``DicomExportSupportMatrix/packageDefault``. The package supports controlled
local export/build/parse helpers; it does not implement full print-service
operation coverage, native video frame decode, video transcoding, or rendered
frame generation. Print, waveform, and video helper scope is additionally
enumerated by ``DicomPrintManagementSupport``, ``DicomWaveformStorageKind``,
and ``DicomVideoCodec``.

| Feature | Supported IODs | Required Tags | Transfer Syntaxes | Payload Rules | Metadata Preservation | Unsupported Cases | Typed Failure |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Image export | Native pixel-bearing image instances through `DCMDecoder` and `DicomImageExporter` | Pixel Data, Rows, Columns, Samples per Pixel, Photometric Interpretation, Bits Allocated, Bits Stored, High Bit, Pixel Representation | Native uncompressed Part 10 datasets addressable by `DicomPixelDataDescriptor` | `display8` exports PNG/JPEG/TIFF with resize and annotation burn-in; `native16Bit` exports unsigned single-sample TIFF only | Optional non-PHI sidecars preserve frame number, modality, dimensions, windowing, spacing, and transfer syntax context | Native 16-bit RGB, signed `native16Bit` TIFF, resize/annotations in `native16Bit` mode, compressed/video/referenced pixel export | `DicomImageExportError.unsupportedPixelMode` or `invalidPixelData` |
| Secondary Capture | Secondary Capture Image Storage synthetic snapshots | Clinical export validation requires SOP Instance UID, Study Instance UID, Series Instance UID, Patient Name, Patient ID, Study ID, Study Date, Series Number, Instance Number, and the Image Pixel module | Explicit VR Little Endian Part 10 with native uncompressed Pixel Data | 8/16-bit unsigned MONOCHROME2 or 8-bit interleaved RGB with planar configuration 0 | Patient, study, series, instance, device, derivation, and source image references are preserved when supplied | Signed stored pixels, planar RGB, non-RGB three-sample payloads, unsupported bit depths, missing clinical context in strict export validation | `DicomSecondaryCaptureError.missingRequiredMetadata` or `unsupportedPixelLayout` |
| Print management | Basic Grayscale Print Management Meta SOP Class with Basic Film Session, Basic Film Box, and Basic Grayscale Image Box | Film session copy/priority/medium/destination, film box layout/orientation/size, image box position, and grayscale 8-bit image pixel attributes | Negotiated DIMSE presentation context, defaulting to Explicit VR Little Endian when absent | Rendered RGB bitmaps and PNG snapshots are converted to 8-bit MONOCHROME2 Basic Grayscale Image Box payloads | Film session label, film box display settings, queue status, and returned image box SOP Instance UIDs are preserved | Color print, Presentation LUT service, annotation boxes, printer configuration/status services, and storage commitment | `DicomPrintManagementError.unsupportedService` |
| Waveform | 12-lead ECG, General ECG, Ambulatory ECG, General 32-bit ECG, Hemodynamic, Cardiac Electrophysiology, Arterial Pulse, and Respiratory Waveform Storage | Waveform Sequence, Number of Channels, Number of Samples, Sampling Frequency, Channel Definition Sequence, Waveform Bits Allocated, Waveform Sample Interpretation, and Waveform Data | Native dataset and Part 10 writing through `DicomDataSetWriter`; compressed waveform encodings are not implemented | SB, UB, SS, US, SL, and UL integer samples are interleaved by sample then channel with range checks | Channel labels, source concepts, units, sensitivity, filters, timing offsets, and source waveform references are preserved | Float/double samples, audio waveforms, vendor-specific packed encodings, inconsistent channel sample counts, and malformed payload lengths | `DicomWaveformError.unsupportedSampleInterpretation`, `sampleOutOfRange`, or `invalidWaveformData` |
| Video | Video Endoscopic, Video Microscopic, and Video Photographic Image Storage | SOP Class UID, Rows, Columns, Number of Frames, timing metadata when available, transfer syntax UID, and encapsulated Pixel Data | MPEG-2, MPEG-4 AVC/H.264, and HEVC/H.265 DICOM video transfer syntaxes | Encoded streams and indexed encoded frame fragments are preserved for caller/player handoff; native frame decode and video encoding are not implemented | Codec, timing, frame rate, duration, source references, lossy compression method, and raw stream bytes are preserved | Non-video transfer syntaxes, native video frame decoding, video transcoding, and server-side DICOMweb rendered frames | `DicomVideoError.unsupportedTransferSyntax`, `nativeFrameDecodeUnsupported`, `transcodingUnsupported`, or `DICOMWEB_RENDERED_FRAME_UNSUPPORTED` |

### 1.6 Sequencing of Real-World Activities

`DicomSeriesLoader` declares its volume scope through
``DicomSeriesLoaderSupportMatrix``. The standard matrix accepts Bits Allocated
8, 16, or 32; Bits Stored 8, 16, or 32; High Bit from the source metadata;
Pixel Representation 0 or 1; Samples per Pixel 1; MONOCHROME1 or MONOCHROME2;
absent Planar Configuration; one frame per file; and native uncompressed or
compressed pixel transfer syntaxes whose decode backend is active (compressed
slices decode once per slice through ``DicomDecodedFrameReader``). It preserves
rescale slope/intercept, VOI/window metadata, pixel spacing, orientation,
origin, image instance metadata, and slice ordering by Image Position
projection, then Instance Number, then localized filename. Compressed transfer
syntaxes without an active decode backend, color/multi-sample data, explicit
planar configuration, unsupported Bits Stored values, and multiframe images
fail with typed errors carrying transfer syntax and pixel metadata.
Enhanced CT/MR multiframe objects assemble through
`DicomSeriesLoader.loadEnhancedMultiframeVolume(at:)`: Shared and Per-Frame
Functional Groups provide geometry (Plane Position/Orientation, Pixel
Measures) and per-frame rescale (Pixel Value Transformation), frames order by
position along the normal, and each frame decodes one at a time through
``DicomDecodedFrameReader`` — so compressed multiframe objects use exactly the
same path as native ones when the transfer syntax has an active backend.
Unsupported multiframe shapes fail typed with SOP Class, frame count,
transfer syntax, and the missing functional-group context.

Typical usage sequence:

1. **File Validation (Optional):** Verify file is valid DICOM format
2. **File Loading:** Parse DICOM header and metadata
3. **Metadata Access:** Query specific data elements by tag ID
4. **Pixel Loading (Lazy):** Load and decompress pixel data on demand
5. **Image Processing (Optional):** Apply window/level for display
6. **Display:** Present processed image to user

---

## 2. Transfer Syntax Support

DicomCore supports the following DICOM Transfer Syntaxes for reading:

Use ``DicomTransferSyntaxRegistry`` to inspect encapsulation, fragmentation, decoder/encoder availability, and safe transcode planning before converting pixel data. Use ``DicomEncapsulatedPixelDataParser`` or `DCMDecoder.getEncapsulatedFrame(_:)` to extract a compressed frame payload before passing it to a codec.

### 2.1 Uncompressed Transfer Syntaxes

| Transfer Syntax Name | UID | Endianness | VR | Support Level |
|---------------------|-----|------------|-----|---------------|
| **Implicit VR Little Endian** | 1.2.840.10008.1.2 | Little | Implicit | ✅ Full Support |
| **Explicit VR Little Endian** | 1.2.840.10008.1.2.1 | Little | Explicit | ✅ Full Support |
| **Explicit VR Big Endian** | 1.2.840.10008.1.2.2 | Big | Explicit | ✅ Full Support |

### 2.2 Compressed Transfer Syntaxes

| Transfer Syntax Name | UID | Compression | Pixel Status | Support Detail |
|---------------------|-----|-------------|--------------|----------------|
| **Deflated Explicit VR Little Endian** | 1.2.840.10008.1.2.1.99 | Dataset deflate | out-of-scope | zlib handles dataset compression, not a compressed pixel codec |
| **JPEG Lossless, Non-Hierarchical, First-Order Prediction (Process 14, Selection Value 1)** | 1.2.840.10008.1.2.4.70 | JPEG Lossless | decoded | Native `JPEGLosslessDecoder`, including restart intervals (DRI/RSTn) and 8-bit interleaved RGB; other color shapes are tested rejections |
| **JPEG Lossless, Non-Hierarchical (Process 14)** | 1.2.840.10008.1.2.4.57 | JPEG Lossless | decoded | Native `JPEGLosslessDecoder`; all selection values 0-7 |
| **JPEG Baseline (Process 1)** | 1.2.840.10008.1.2.4.50 | JPEG Lossy | delegated | ImageIO for platform-supported 8-bit payloads |
| **JPEG Extended (Process 2 & 4)** | 1.2.840.10008.1.2.4.51 | JPEG Lossy | decoded | Native 12-bit grayscale decode preserves precision; <=8-bit payloads delegate to ImageIO |
| **JPEG-LS Lossless Image Compression** | 1.2.840.10008.1.2.4.80 | JPEG-LS | delegated | Async JLSwift 0.9.0 candidate with CharLS shadow/fallback; reversible JLSwift encode route for qualified shapes |
| **JPEG-LS Lossy (Near-Lossless) Image Compression** | 1.2.840.10008.1.2.4.81 | JPEG-LS | delegated | Async JLSwift 0.9.0 candidate with CharLS shadow/fallback; encode requires explicit NEAR intent and records lossy metadata |
| **JPEG 2000 Image Compression (Lossless Only)** | 1.2.840.10008.1.2.4.90 | JPEG 2000 | delegated | Decode: async J2KSwift candidate with OpenJPEG shadow/fallback. Encode: explicit reversible J2KSwift CPU route. |
| **JPEG 2000 Image Compression** | 1.2.840.10008.1.2.4.91 | JPEG 2000 | delegated | Decode: async J2KSwift candidate with OpenJPEG shadow/fallback. Encode: explicit reversible/irreversible J2KSwift CPU route. |
| **JPEG 2000 Part 2 Multi-component Image Compression (Lossless Only)** | 1.2.840.10008.1.2.4.92 | JPEG 2000 Part 2 | delegated | Preflighted OpenJPEG through `DicomJP3DVolumeDocument` |
| **JPEG 2000 Part 2 Multi-component Image Compression** | 1.2.840.10008.1.2.4.93 | JPEG 2000 Part 2 | delegated | Preflighted OpenJPEG through `DicomJP3DVolumeDocument` |
| **JPEG XL Lossless** | 1.2.840.10008.1.2.4.110 | JPEG XL | experimental | JXLSwift 1.4.0 reversible 8/16-bit grayscale and RGB8; disabled by default |
| **JPEG XL JPEG Recompression** | 1.2.840.10008.1.2.4.111 | JPEG XL | experimental | Qualified JPEG Baseline reconstructs byte-for-byte; disabled by default |
| **JPEG XL** | 1.2.840.10008.1.2.4.112 | JPEG XL | experimental | Explicit reversible or irreversible JXLSwift route; disabled by default |
| **DICOM JPIP Referenced Transfer Syntax** | 1.2.840.10008.1.2.4.94 | JPIP referenced pixel data | streamed-only | Metadata and Pixel Data Provider URL; transport supplied by application |
| **DICOM JPIP Referenced Deflate Transfer Syntax** | 1.2.840.10008.1.2.4.95 | JPIP referenced pixel data with dataset deflate | streamed-only | Dataset inflate plus Pixel Data Provider URL; transport supplied by application |
| **MPEG-2 Video Transfer Syntaxes** | 1.2.840.10008.1.2.4.100-.101.1 | MPEG-2 video | streamed-only | Encoded stream exposed for player backend; native frame decode is not implemented |
| **MPEG-4 AVC/H.264 Video Transfer Syntaxes** | 1.2.840.10008.1.2.4.102-.106.1 | H.264 video | streamed-only | Encoded stream exposed for player backend; native frame decode is not implemented |
| **HEVC/H.265 Video Transfer Syntaxes** | 1.2.840.10008.1.2.4.107-.108 | HEVC video | streamed-only | Encoded stream exposed for player backend; native frame decode is not implemented |
| **HTJ2K Image Compression (Lossless Only)** | 1.2.840.10008.1.2.4.201 | HTJ2K | delegated | Decode: OpenJPEG >= 2.5 production. Encode: explicit reversible J2KSwift CPU route. |
| **HTJ2K Image Compression (Lossless RPCL)** | 1.2.840.10008.1.2.4.202 | HTJ2K | delegated | Decode: OpenJPEG >= 2.5 production. Encode: explicit reversible J2KSwift CPU RPCL route. |
| **HTJ2K Image Compression** | 1.2.840.10008.1.2.4.203 | HTJ2K | delegated | Decode: OpenJPEG >= 2.5 production. Encode: explicit reversible/irreversible J2KSwift CPU route. |
| **RLE Lossless** | 1.2.840.10008.1.2.5 | RLE | decoded | Native `DicomRLELosslessDecoder` |

**Pixel Status Values:** `decoded`, `delegated`, `experimental`, `streamed-only`, `unsupported`, and `out-of-scope`.
The same rows are available programmatically through
`DicomTransferSyntaxRegistry.standard.compressedPixelSupportMatrix`.

**Writing Status Values:** `native-dataset`, `deflated-dataset`, `referenced-dataset`,
`encapsulated-pass-through`, and `unsupported`. Use
`DicomTransferSyntaxRegistry.standard.writeSupportMatrix` before calling
`DicomDataSetWriter`. Dataset writing serializes elements for a requested transfer
syntax, file writing adds Part 10 file meta information, and pixel recompression is
not performed by the writer. Native pixels cannot be written as compressed transfer
syntaxes without an encoder, and encapsulated payloads cannot be silently rewritten
as native pixels.

### 2.3 JPEG Lossless Implementation Details

DicomCore includes a native JPEG Lossless decoder supporting DICOM's most common lossless compression format:

**Supported Features:**
- **Process 14, Selection Values 0-7:** All 8 predictor modes (no prediction, left, top, diagonal, planar, and gradient-based predictors)
- **Precision:** 8-bit, 12-bit, and 16-bit samples
- **Color Space:** Grayscale and RGB (single-frame)
- **Huffman Coding:** Both default and custom Huffman tables

**Limitations:**
- **Multi-frame encapsulated images:** Frame indexing and compressed frame extraction are supported; full decode still depends on the codec for the transfer syntax.
- **Hierarchical encoding:** Not supported (Process 14 non-hierarchical only)
- **Other JPEG processes:** Only Process 14 is supported

---

## 3. SOP Class Support

DicomCore can read and parse DICOM files, write controlled Part 10 datasets for uncompressed local workflows, and provide DICOMweb/DIMSE service helpers covered by package tests.

This conformance table focuses on the file-level decoder surface. DicomCore can successfully parse and extract data from DICOM files conforming to the following SOP Classes:

### 3.1 Image Storage SOP Classes

DicomCore can read files from any DICOM Image Storage SOP Class. The library is modality-agnostic and will attempt to parse any valid DICOM file format, regardless of the SOP Class UID. The following table lists commonly encountered Image Storage SOP Classes:

**Cross-Sectional Imaging:**

| SOP Class | UID | Typical Use | Tested |
|-----------|-----|-------------|--------|
| **CT Image Storage** | 1.2.840.10008.5.1.4.1.1.2 | Computed Tomography | ✅ Yes |
| **Enhanced CT Image Storage** | 1.2.840.10008.5.1.4.1.1.2.1 | CT with enhanced metadata | ✅ Synthetic Functional Groups |
| **MR Image Storage** | 1.2.840.10008.5.1.4.1.1.4 | Magnetic Resonance Imaging | ✅ Yes |
| **Enhanced MR Image Storage** | 1.2.840.10008.5.1.4.1.1.4.1 | MR with enhanced metadata | ✅ Synthetic Functional Groups |
| **Enhanced MR Color Image Storage** | 1.2.840.10008.5.1.4.1.1.4.3 | Color MR images | ⚠️ Limited |
| **Segmentation Storage** | 1.2.840.10008.5.1.4.1.1.66.4 | Binary and fractional labelmaps | ✅ Synthetic SEG |
| **RT Structure Set Storage** | 1.2.840.10008.5.1.4.1.1.481.3 | Structure contours | ✅ Synthetic RTSTRUCT |
| **RT Dose Storage** | 1.2.840.10008.5.1.4.1.1.481.2 | Scaled dose grids | ✅ Synthetic RTDOSE |
| **RT Plan Storage** | 1.2.840.10008.5.1.4.1.1.481.5 | Beam/control point inspection | ✅ Synthetic RTPLAN |
| **Parametric Map Storage** | 1.2.840.10008.5.1.4.1.1.30 | Quantitative scalar maps | ✅ Synthetic PM |
| **Basic Text SR Storage** | 1.2.840.10008.5.1.4.1.1.88.11 | Navigable text SR content trees | ⚠️ Syntax only |
| **Enhanced SR Storage** | 1.2.840.10008.5.1.4.1.1.88.22 | TID 1500 measurements and references | ✅ Synthetic SR + semantic TID 1500 |
| **Comprehensive SR Storage** | 1.2.840.10008.5.1.4.1.1.88.33 | TID 1500 measurements and ROIs | ✅ Synthetic SR + semantic TID 1500 |
| **Comprehensive 3D SR Storage** | 1.2.840.10008.5.1.4.1.1.88.34 | 3D SR content tree metadata | ⚠️ Syntax only |
| **Extensible SR Storage** | 1.2.840.10008.5.1.4.1.1.88.35 | Extensible SR content tree metadata | ⚠️ Syntax only |
| **Mammography CAD SR Storage** | 1.2.840.10008.5.1.4.1.1.88.50 | CAD finding containers | ⚠️ Syntax and extraction only |
| **Chest CAD SR Storage** | 1.2.840.10008.5.1.4.1.1.88.65 | CAD finding containers | ⚠️ Syntax and extraction only |
| **Colon CAD SR Storage** | 1.2.840.10008.5.1.4.1.1.88.69 | CAD finding containers | ⚠️ Syntax and extraction only |
| **Key Object Selection Document Storage** | 1.2.840.10008.5.1.4.1.1.88.59 | Key image/object references | ✅ Synthetic KOS + semantic references |
| **Grayscale Softcopy Presentation State Storage** | 1.2.840.10008.5.1.4.1.1.11.1 | Image-relative graphic annotations | ✅ Synthetic GSPS |
| **Encapsulated PDF Storage** | 1.2.840.10008.5.1.4.1.1.104.1 | Encapsulated PDF documents | ✅ Synthetic DOC |
| **Encapsulated CDA Storage** | 1.2.840.10008.5.1.4.1.1.104.2 | Encapsulated CDA documents | ✅ Synthetic DOC |
| **Encapsulated STL Storage** | 1.2.840.10008.5.1.4.1.1.104.3 | Encapsulated STL models | ✅ Synthetic DOC |
| **12-lead ECG Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.1.1 | ECG temporal samples | ✅ Synthetic ECG |
| **General ECG Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.1.2 | ECG temporal samples | ✅ Synthetic ECG |
| **Ambulatory ECG Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.1.3 | Ambulatory ECG temporal samples | ✅ Synthetic ECG |
| **Hemodynamic Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.2.1 | Hemodynamic temporal samples | ⚠️ Parser model |
| **Video Endoscopic Image Storage** | 1.2.840.10008.5.1.4.1.1.77.1.1.1 | Encoded visible-light video stream | ✅ Synthetic video |
| **Video Microscopic Image Storage** | 1.2.840.10008.5.1.4.1.1.77.1.2.1 | Encoded visible-light video stream | ✅ Synthetic video |
| **Video Photographic Image Storage** | 1.2.840.10008.5.1.4.1.1.77.1.4.1 | Encoded visible-light video stream | ✅ Synthetic video |

**Projection Radiography:**

| SOP Class | UID | Typical Use | Tested |
|-----------|-----|-------------|--------|
| **Computed Radiography Image Storage** | 1.2.840.10008.5.1.4.1.1.1 | Computed Radiography (CR) | ⚠️ Limited |
| **Digital X-Ray Image Storage - For Presentation** | 1.2.840.10008.5.1.4.1.1.1.1 | Digital Radiography (DX) | ⚠️ Limited |
| **Digital X-Ray Image Storage - For Processing** | 1.2.840.10008.5.1.4.1.1.1.1.1 | Raw DX images | ⚠️ Limited |
| **Digital Mammography X-Ray Image Storage - For Presentation** | 1.2.840.10008.5.1.4.1.1.1.2 | Mammography (MG) | ⚠️ Limited |
| **Digital Mammography X-Ray Image Storage - For Processing** | 1.2.840.10008.5.1.4.1.1.1.2.1 | Raw mammography | ⚠️ Limited |

**Ultrasound:**

| SOP Class | UID | Typical Use | Tested |
|-----------|-----|-------------|--------|
| **Ultrasound Image Storage** | 1.2.840.10008.5.1.4.1.1.6.1 | 2D Ultrasound | ⚠️ Limited |
| **Ultrasound Multi-frame Image Storage** | 1.2.840.10008.5.1.4.1.1.3.1 | Cine ultrasound loops | ⚠️ Limited |
| **Enhanced US Volume Storage** | 1.2.840.10008.5.1.4.1.1.6.2 | 3D ultrasound volumes | ⚠️ Limited |

**Nuclear Medicine & PET:**

| SOP Class | UID | Typical Use | Tested |
|-----------|-----|-------------|--------|
| **Nuclear Medicine Image Storage** | 1.2.840.10008.5.1.4.1.1.20 | Planar scintigraphy, SPECT | ⚠️ Limited |
| **PET Image Storage** | 1.2.840.10008.5.1.4.1.1.128 | Positron Emission Tomography | ⚠️ Limited |
| **Enhanced PET Image Storage** | 1.2.840.10008.5.1.4.1.1.130 | PET with enhanced metadata | ✅ Synthetic Functional Groups |

**Fluoroscopy & Angiography:**

| SOP Class | UID | Typical Use | Tested |
|-----------|-----|-------------|--------|
| **X-Ray Angiographic Image Storage** | 1.2.840.10008.5.1.4.1.1.12.1 | Angiography (XA) | ⚠️ Limited |
| **X-Ray Radiofluoroscopic Image Storage** | 1.2.840.10008.5.1.4.1.1.12.2 | Fluoroscopy (RF) | ⚠️ Limited |
| **Enhanced XA Image Storage** | 1.2.840.10008.5.1.4.1.1.12.1.1 | Enhanced angiography | ⚠️ Limited |

**Other Modalities:**

| SOP Class | UID | Typical Use | Tested |
|-----------|-----|-------------|--------|
| **Secondary Capture Image Storage** | 1.2.840.10008.5.1.4.1.1.7 | Screen captures, processed images | ✅ Synthetic SC |
| **Multi-frame Single Bit Secondary Capture Image Storage** | 1.2.840.10008.5.1.4.1.1.7.1 | Binary images (e.g., CAD) | ⚠️ Limited |
| **RT Image Storage** | 1.2.840.10008.5.1.4.1.1.481.1 | Radiation therapy portal images | ⚠️ Limited |
| **Ophthalmic Photography 8 Bit Image Storage** | 1.2.840.10008.5.1.4.1.1.77.1.5.1 | Fundus photography | ⚠️ Limited |
| **VL Endoscopic Image Storage** | 1.2.840.10008.5.1.4.1.1.77.1.1.1 | Endoscopy | ⚠️ Limited |
| **VL Microscopic Image Storage** | 1.2.840.10008.5.1.4.1.1.77.1.2.1 | Pathology microscopy | ⚠️ Limited |
| **VL Photographic Image Storage** | 1.2.840.10008.5.1.4.1.1.77.1.4.1 | Clinical photography | ⚠️ Limited |

### 3.2 Media Storage SOP Classes

| SOP Class | UID | Typical Use | Tested |
|-----------|-----|-------------|--------|
| **Media Storage Directory Storage** | 1.2.840.10008.1.3.10 | DICOMDIR patient/study/series/image directory records | ✅ Yes |

**Testing Legend:**
- **✅ Yes:** Extensively tested with real-world datasets
- **⚠️ Limited:** Basic compatibility verified, but not extensively tested
- **❌ No:** Known incompatibilities or not tested

**Note:** DicomCore's modality-agnostic parser can read any DICOM Image Storage SOP Class not explicitly listed above. The primary compatibility factor is the Transfer Syntax (see Section 2) and Photometric Interpretation (see Section 4), not the SOP Class UID itself.

### 3.3 Parsed Attributes

DicomCore can extract any DICOM attribute present in the file. Commonly accessed attributes include:

SQ values are parsed for both explicit-length and undefined-length encodings,
including undefined-length items and nested undefined-length sequences. Item and
sequence delimiter tags must use zero length; malformed nesting, missing
delimiters, invalid item tags, and unexpected EOF produce parser errors.
Undefined-length non-SQ element values remain unsupported.

**Patient Module:**
- Patient Name (0010,0010)
- Patient ID (0010,0020)
- Patient Birth Date (0010,0030)
- Patient Sex (0010,0040)

**Study Module:**
- Study Instance UID (0020,000D)
- Study Date (0020,0008)
- Study Time (0020,0009)
- Study Description (0008,1030)
- Accession Number (0008,0050)

**Series Module:**
- Series Instance UID (0020,000E)
- Series Number (0020,0011)
- Modality (0008,0060)
- Series Description (0008,103E)

**Image Module:**
- SOP Instance UID (0008,0018)
- Image Position (Patient) (0020,0032)
- Image Orientation (Patient) (0020,0037)
- Slice Thickness (0018,0050)
- Slice Location (0020,1041)

**Image Pixel Module:**
- Rows (0028,0010)
- Columns (0028,0011)
- Bits Allocated (0028,0100)
- Bits Stored (0028,0101)
- High Bit (0028,0102)
- Pixel Representation (0028,0103)
- Samples Per Pixel (0028,0002)
- Photometric Interpretation (0028,0004)
- Pixel Data (7FE0,0010)

**Segmentation Module:**
- Segmentation Type (0062,0001)
- Segment Sequence (0062,0002)
- Segment Identification Sequence (0062,000A)
- Tracking UID (0062,0021)
- Segmentation Fractional Type (0062,0010)
- Maximum Fractional Value (0062,000E)

**Radiotherapy Modules:**
- Structure Set ROI Sequence (3006,0020)
- ROI Contour Sequence (3006,0039)
- Contour Data (3006,0050)
- Dose Units (3004,0002)
- Dose Grid Scaling (3004,000E)
- Beam Sequence (300A,00B0)
- Control Point Sequence (300A,0111)

**Structured Reporting Modules:**
- Content Sequence (0040,A730)
- Relationship Type (0040,A010)
- Value Type (0040,A040)
- Concept Name Code Sequence (0040,A043)
- Measured Value Sequence (0040,A300)
- Content Template Sequence (0040,A504)
- Current Requested Procedure Evidence Sequence (0040,A375)
- Graphic Data (0070,0022)
- Graphic Type (0070,0023)

SR parsing remains syntactic for every SR SOP Class UID listed above. Semantic validation is explicit and scoped to
Enhanced SR and Comprehensive SR TID 1500 measurement reports plus Key Object Selection references through
``DicomSRSupportMatrix`` and ``DicomSRSemanticValidator``. Other templates or relationship patterns return stable
validation errors instead of partial semantic success.

**Presentation State Modules:**
- Referenced Series Sequence (0008,1115)
- Referenced Image Sequence (0008,1140)
- Graphic Annotation Sequence (0070,0001)
- Graphic Object Sequence (0070,0009)
- Graphic Layer Sequence (0070,0060)
- Displayed Area Selection Sequence (0070,005A)
- Presentation LUT Shape (2050,0020)

**Secondary Capture Modules:**
- Image Type (0008,0008)
- Conversion Type (0008,0064)
- Source Image Sequence (0008,2112)
- Date of Secondary Capture (0018,1012)
- Time of Secondary Capture (0018,1014)
- Secondary Capture Device ID (0018,1010)
- Secondary Capture Device Manufacturer (0018,1016)
- Secondary Capture Device Manufacturer's Model Name (0018,1018)
- Secondary Capture Device Software Version(s) (0018,1019)

**Encapsulated Document Modules:**
- Document Title (0042,0010)
- Encapsulated Document (0042,0011)
- MIME Type of Encapsulated Document (0042,0012)
- Source Instance Sequence (0042,0013)
- List of MIME Types (0042,0014)
- Encapsulated Document Length (0042,0015)
- Concept Name Code Sequence (0040,A043)

**Waveform Modules:**
- Waveform Sequence (5400,0100)
- Number of Waveform Channels (003A,0005)
- Number of Waveform Samples (003A,0010)
- Sampling Frequency (003A,001A)
- Channel Definition Sequence (003A,0200)
- Channel Source Sequence (003A,0208)
- Channel Sensitivity Units Sequence (003A,0211)
- Waveform Bits Allocated (5400,1004)
- Waveform Sample Interpretation (5400,1006)
- Waveform Data (5400,1010)
- Source Waveform Sequence (003A,020A)

**VOI LUT Module:**
- Window Center (0028,1050)
- Window Width (0028,1051)
- Rescale Intercept (0028,1052)
- Rescale Slope (0028,1053)

### 3.4 Private Attributes

DicomCore preserves private data elements (odd group numbers) as typed dataset
elements and models private creator namespaces through `DicomPrivateCreator`.
Unknown private payloads remain accessible as raw string or binary values.

Known private dictionaries are intentionally small and clinically scoped. The
current built-in dictionary identifies Siemens CSA image/series headers and
selected Siemens MR diffusion fields. `SiemensCSAParser` can extract common CSA
values such as b-value, diffusion gradient direction, and image orientation
from CSA payloads without coupling renderer code to private tag details.

---

## 4. Pixel Data Formats

### 4.1 Display Color Conversion Matrix

Use ``DicomColorDisplayConversionMatrix`` for the display conversion contract.
This matrix is separate from compressed pixel codec support: transfer syntax
decoding determines whether native frame bytes are available, while display
conversion determines whether those native bytes can be converted to RGB8 for
rendering.

| Photometric Interpretation | Samples / Bits | Planar Configuration | ICC Profile | Display Status |
|----------------------------|----------------|----------------------|-------------|----------------|
| **MONOCHROME1** | 1 sample, 8 or 16 bits | Absent | Not applicable | Display RGB, inverted grayscale |
| **MONOCHROME2** | 1 sample, 8 or 16 bits | Absent | Not applicable | Display RGB, grayscale |
| **RGB** | 3 samples, 8 or 16 bits | Absent, 0, or 1 | Preserved | Display RGB (16-bit scales by Bits Stored; `displayRGB48PixelBuffer` preserves full precision) |
| **PALETTE COLOR** | 1 index, 8 or 16 bits | Absent | Preserved if present | Display RGB with RGB lookup tables |
| **YBR_FULL** | 3 samples, 8 bits | Absent, 0, or 1 | Preserved | Display RGB |
| **YBR_FULL_422** | 3 samples, 8 bits | Absent or 0 | Preserved | Display RGB |
| **YBR_PARTIAL_420** | 3 samples, 8 bits | Absent or 0 | Not preserved | Unsupported |
| **YBR_RCT** | 3 samples, 8 bits | Absent or 0 | Not preserved | Native display conversion rejected; JPEG 2000 codestreams decode to RGB through the OpenJPEG backend (`DicomDecodedFrameReader`) |
| **YBR_ICT** | 3 samples, 8 bits | Absent or 0 | Not preserved | Native display conversion rejected; lossy JPEG 2000 codestreams decode to RGB through the OpenJPEG backend (`DicomDecodedFrameReader`) |

Unsupported display paths throw
``DicomColorConversionError/unsupportedColorPath(context:reason:)`` with
Photometric Interpretation, Samples per Pixel, Planar Configuration, Bits
Allocated, and Transfer Syntax context. RGB alpha or extra samples are rejected
explicitly rather than displayed as grayscale.

### 4.2 Pixel Data Processing

**Supported Operations:**
- **Rescale Slope/Intercept:** Automatic application to convert to modality units (e.g., Hounsfield Units for CT)
- **Window/Level:** CPU (vDSP) and GPU (Metal) accelerated windowing with 13 medical presets
- **Bit Depth Conversion:** 16-bit to 8-bit conversion for display
- **Inversion:** MONOCHROME1 to MONOCHROME2 conversion

**Image Processing Performance:**

| Image Size | vDSP (CPU) | Metal (GPU) | Use Case |
|------------|------------|-------------|----------|
| 256×256 | ~0.5ms | ~0.3ms | Preview/Thumbnail |
| 512×512 | ~2ms | ~1.16ms | Standard View |
| 1024×1024 | ~8.67ms | ~2.20ms | High-Res Display |
| 2048×2048 | ~35ms | ~8ms | Full-Resolution Export |

**Auto-Selection Threshold:** Images ≥800×800 pixels automatically use Metal GPU acceleration if available, with graceful fallback to vDSP.

---

## 5. Character Set Support

### 5.1 Default Character Repertoire

DicomCore decodes textual VRs through `DicomSpecificCharacterSet` and exposes
`DicomTextSanitizer` helpers for display-safe strings. Display sanitization
removes control characters and normalizes Unicode form; it does not redact or
anonymize values.

| Character Set | Specific Character Set (0008,0005) | Support |
|---------------|-----------------------------------|---------|
| **ASCII** | ISO_IR 6 (default) | ✅ Full Support |
| **UTF-8** | ISO_IR 192 | ✅ Full Support |
| **Latin-1** | ISO_IR 100 | ✅ Full Support |
| **Latin-2** | ISO_IR 101 | ✅ Foundation-backed |
| **Japanese** | ISO 2022 IR 13, 87, 159 | ⚠️ Foundation-backed best effort |
| **Korean** | ISO 2022 IR 149 | ⚠️ Best-Effort |
| **Chinese** | GB18030, GBK | ⚠️ Best-Effort |

Person Name (PN) values preserve alphabetic, ideographic, and phonetic
representation groups when present.

---

## 6. Security Features

### 6.1 Data Security

DicomCore file parsing operates within the application sandbox. Network
activity occurs only when an application uses the opt-in DICOMweb, DIMSE, or
JPIP helper APIs with caller-configured endpoints and transports:

| Security Aspect | Implementation |
|-----------------|----------------|
| **Network Security** | Caller-owned for configured DICOMweb, DIMSE, and JPIP transports; no TLS termination is implemented by the in-memory DICOMweb server |
| **File Access** | Application sandbox only, respects iOS/macOS file permissions |
| **Data Encryption** | Files are read as-is; encryption/decryption is the caller's responsibility |
| **Authentication** | DICOMweb client accepts caller headers and the in-memory server can require a bearer token; authorization policy remains caller-owned |
| **Audit Trail** | None (logging is the caller's responsibility) |

### 6.2 Patient Privacy

**PHI (Protected Health Information) Handling:**
- DicomCore reads PHI from DICOM files but does not store, transmit, or log it
- Applications using DicomCore are responsible for:
  - Secure storage of files containing PHI
  - Compliance with HIPAA, GDPR, or other applicable regulations
  - Implementing appropriate access controls and audit logging

### 6.3 Vulnerability Mitigation

| Risk | Mitigation |
|------|------------|
| **Buffer Overflows** | Swift's memory safety prevents buffer overflows |
| **Integer Overflows** | Validated array sizing with overflow checks |
| **Malformed Files** | Defensive parsing with typed error handling |
| **Memory Exhaustion** | Memory mapping for large files (>10MB) |
| **Decompression Bombs** | Pixel data size validation against declared dimensions |

---

## 7. Configuration

### 7.1 Build-Time Configuration

DicomCore requires:
- **Minimum iOS Version:** 13.0
- **Minimum macOS Version:** 12.0
- **Swift Version:** 5.7 or later
- **Xcode Version:** 14.0 or later

### 7.2 Runtime Configuration

No runtime configuration files are required. Optional features:

| Feature | Default | Configuration |
|---------|---------|---------------|
| **Memory Mapping Threshold** | 10 MB | Hard-coded, not configurable |
| **Metal GPU Acceleration** | Auto-detect | Configurable per-call via `processingMode` parameter |
| **Tag Caching** | Enabled | Always enabled, not configurable |
| **CharLS runtime path** | Auto-detect | Optional `DICOM_DECODER_CHARLS_LIBRARY_PATH` override |
| **OpenJPEG runtime path** | Auto-detect | Optional `DICOM_DECODER_OPENJPEG_LIBRARY_PATH` override |
| **JLSwift rollout** | `shadow` | `DICOM_JLSWIFT_MODE=disabled`, `shadow`, `preferred`, or `forced-for-tests` |
| **JXLSwift rollout** | `disabled` | `DICOM_JXLSWIFT_MODE=disabled`, `experimental`, or `forced-for-tests` |

### 7.3 Framework Dependencies

DicomCore uses Apple-provided frameworks for its core pipeline:

- **Foundation:** Core Swift types, file I/O
- **CoreGraphics:** Image representation (CGImage)
- **ImageIO:** Explicit JPEG Baseline decompression backend and 8-bit JPEG 2000 fallback
- **Accelerate (vDSP):** CPU-based image processing
- **Metal:** GPU-based image processing (optional)

Deflated Explicit VR Little Endian uses system zlib for raw deflate/inflate. JPEG-LS links JLSwift 0.9.0 behind the async compressed-frame adapter while CharLS remains the dynamically loaded production oracle and fallback. JLSwift defaults to shadow mode and is qualified for JPEG-LS UIDs .80/.81 on aligned 8–16-bit grayscale and RGB8; async encode supports reversible .80 and explicit-NEAR .81. JPEG 2000 decoding can use OpenJPEG when `DicomCodecRuntimePreflight.status(for: .openJPEG)` reports availability. CharLS and OpenJPEG remain SYSTEM dependencies loaded dynamically (default Homebrew//usr/local candidates, per-runtime `DICOM_DECODER_<RUNTIME>_LIBRARY_PATH` override) and are never bundled. J2KSwift 11.0.2 is a versioned SwiftPM dependency behind the JPEG 2000 adapter. Decode defaults to shadow mode and is qualified for JPEG 2000 UIDs .90/.91 while HTJ2K stays on OpenJPEG fallback. Encode is separately qualified on CPU for JPEG 2000 .90/.91 and HTJ2K .201-.203. The codec bridges return typed unsupported-transfer-syntax errors when runtimes are absent or incompatible. `DicomCodecCapabilities.backendStatuses()` reports backend availability, version, source, bit depths, operations, and deterministic unsupported reasons.

---

## 8. Known Limitations

### 8.1 Format Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| **Encapsulated multi-frame images** | Frame indexing is supported; full decode depends on codec support for the transfer syntax | Extract frames with `getEncapsulatedFrame(_:)` and decode with a supported codec |
| **JPEG Lossless Non-RGB Color and Separate-Scan Frames** | Native Process 14 decode handles restart intervals and single interleaved scans of 1 or 3 components; non-RGB photometric interpretations, >8-bit color, and separate-scan multicomponent streams are rejected with stable diagnostics | Convert to interleaved 8-bit RGB or grayscale Process 14, or use another validated backend |
| **JPEG-LS Runtime Availability** | Default shadow decode requires CharLS; JLSwift is package-linked and available in preferred/forced modes for qualified shapes | Install/set CharLS, select `preferred`, or use a qualified native syntax |
| **JLSwift JPEG-LS shapes** | Grayscale below 8 Bits Stored, color above 8 Bits Stored, and non-RGB color are not qualified | Use CharLS through the synchronous path or convert to aligned 8–16-bit grayscale/RGB8 |
| **Experimental JPEG XL shapes** | 10/12-bit, signed 8-bit, custom ICC, high-depth color, alpha, and oversized frames are not qualified | Use aligned unsigned 8/16-bit or signed 16-bit grayscale, RGB8, or another qualified syntax |
| **JPEG 2000 Runtime Availability** | JPEG 2000 >8-bit and Part 2 paths require `DicomCodecRuntimePreflight.status(for: .openJPEG)` to be available | Install OpenJPEG, set `DICOM_DECODER_OPENJPEG_LIBRARY_PATH`, or convert to a native supported syntax |
| **HTJ2K Pixel Decode** | J2KSwift 11.0.2 remains shadow-only after a pinned OpenJPH parity mismatch; production decode uses preflighted OpenJPEG 2.5+ | Install OpenJPEG >= 2.5, disable J2KSwift shadowing, or convert to a supported transfer syntax |
| **JPEG Hierarchical** | JPEG processes other than Process 14 unsupported | Convert to supported transfer syntax |
| **Unsupported color combinations** | `DicomColorConversionError.unsupportedColorPath` reports photometric interpretation, sample count, planar layout, bit depth, and transfer syntax context | Convert through a supported transfer syntax/color layout |
| **Undefined-length non-SQ** | Non-SQ undefined values inside sequences throw parser errors | Use explicit lengths |
| **Incomplete PET SUV metadata** | SUV helpers return no physical value and report missing DICOM tags | Preserve Units, Patient Weight/Size/Sex, radiopharmaceutical dose, decay, and timing metadata |
| **Large Files** | Files >1GB may consume significant memory | Use memory-efficient workflows, process in chunks |

### 8.2 Functional Limitations

| Limitation | Impact |
|------------|--------|
| **No production DICOMweb/PACS stack** | DICOMweb helpers cover the tested matrix only; persistent storage, full UPS, server-side rendered frames, JPIP proxying, authorization policy, PHI audit logging, TLS termination, and zero-copy streaming are caller-owned or unsupported |
| **Limited Writing Scope** | General dataset writing is limited to native/Deflated datasets, JPIP metadata references, DICOMDIR media records, and caller-provided encapsulated payload passthrough; pixel recompression is not implemented |
| **Limited Structured Report Semantics** | Semantic validation is scoped to Enhanced/Comprehensive SR TID 1500 and KOS references; other SR SOP classes/templates parse syntactically and return stable validation errors for semantic use |
| **Limited Secondary Capture Pixel Inputs** | SC writing supports native unsigned monochrome and interleaved RGB pixel payloads, including CGImage snapshots converted to RGB8 |
| **Limited Encapsulated Document Scope** | Document object writing is limited to Encapsulated PDF, CDA, and STL Part 10 datasets; embedded document contents are preserved but not rendered or semantically parsed |
| **Limited Waveform Sample Scope** | Waveform writing/parsing covers linear 8/16/32-bit integer sample interpretations and exposes temporal samples without converting them to image volumes |
| **Limited Video Scope** | Video writing/parsing encapsulates and exposes caller-provided MPEG-2/H.264/H.265 streams with metadata; native video decoding is delegated to the application/player backend |
| **Limited Presentation State Scope** | GSPS graphic annotations are parsed/built for object exchange; display application of GSPS transforms remains caller-owned |

### 8.3 Current Scope

Remaining limitations in this conformance statement are explicitly scoped:

- Package-level codec and writer limitations are exposed through
  `DicomTransferSyntaxRegistry.standard.compressedPixelSupportMatrix` and
  `DicomTransferSyntaxRegistry.standard.writeSupportMatrix`.
- DICOMweb limitations are exposed through
  ``DicomWebConformanceMatrix/packageDefault`` and are intentionally helper
  scope unless a future issue makes DICOM-Swift a production PACS stack.
- DIMSE limitations are limited to archive qualification and production
  operations policy; package tests cover the listed SCU/SCP helpers, while
  deployment, audit, authorization, and external archive validation remain
  caller-owned.
- Structured Report semantic validation remains scoped through
  ``DicomSRSupportMatrix`` and ``DicomSRSemanticValidator``.
- Export, print, waveform, and video limitations are exposed through
  ``DicomExportSupportMatrix/packageDefault`` and typed unsupported-path errors.
- Decoder parity documentation is covered by the package-local conformance
  manifests and reconciliation tests.
- Presentation and interaction policy is caller-owned. DICOM-Swift ends at
  decoded values, frames, series, and explicit exports.

### 8.4 Performance Considerations

| Scenario | Expected Performance | Recommendation |
|----------|---------------------|----------------|
| **File Opening** | <50ms for typical files | Use async APIs to avoid blocking callers |
| **Pixel Loading** | 100-500ms for compressed data | Load pixels in background task |
| **Series Loading** | 2-5s for 100-slice CT series | Use progress callbacks, enable concurrency |
| **Window/Level (CPU)** | ~2ms per 512×512 image | Suitable for batch or interactive consumers |
| **Window/Level (GPU)** | ~2.2ms per 1024×1024 image | Use for high-res or batch processing |

---

## 9. Version History

### Version 1.2.0 (Current)

**Release Date:** 2026-02-15

**Key Features:**
- Type-safe value types (WindowSettings, PixelSpacing, RescaleParameters)
- Enhanced concurrency support with Sendable conformance
- Batch loading APIs for concurrent file processing
- DicomTag enum for type-safe metadata access
- Improved error messages and diagnostics

**Conformance Changes:**
- No changes to transfer syntax support
- No changes to SOP class compatibility

### Version 1.1.0

**Release Date:** 2025-12-01 (estimated)

**Key Features:**
- Throwing initializers for Swift-idiomatic error handling
- Native JPEG Lossless decoder (Process 14, all selection values 0-7)
- Support for 12-bit and 16-bit precision in JPEG Lossless

**Conformance Changes:**
- Added full support for Transfer Syntax 1.2.840.10008.1.2.4.57 (JPEG Lossless, Non-Hierarchical)
- Expanded JPEG Lossless support to all selection values (0-7), not just selection value 1

### Version 1.0.0

**Release Date:** 2025-09-01 (estimated)

**Initial Release:**
- Basic DICOM parsing (Little/Big Endian, Explicit/Implicit VR)
- 8-bit, 16-bit grayscale, and 24-bit RGB support
- JPEG Lossless (Process 14, Selection Value 1) via native decoder
- JPEG Baseline explicit ImageIO-backed support and JPEG 2000 explicit OpenJPEG-backed support
- Window/Level processing with vDSP (CPU) backend

---

## 10. Support and Contact

### 10.1 Documentation

- **Architecture Overview:** See <doc:Architecture>
- **Performance Guide:** See <doc:PerformanceGuide>
- **Migration Guide:** See <doc:MigrationGuide>
- **API Reference:** See ``DCMDecoder``, ``DCMWindowingProcessor``

### 10.2 Issue Reporting

For bug reports, feature requests, or conformance issues, please file an issue on the project's GitHub repository.

**Information to Include:**
- Library version (e.g., 1.2.0)
- Platform and OS version (e.g., iOS 17.2, macOS 14.1)
- Minimal reproducible example
- Sample DICOM file (if applicable, ensure PHI is removed)
- Expected vs. actual behavior

### 10.3 Validation Testing

Organizations integrating DicomCore into medical devices should conduct their own validation testing:

**Recommended Tests:**
1. **Transfer Syntax Validation:** Test all transfer syntaxes used in your workflow
2. **Modality Coverage:** Test with representative images from all modalities in scope
3. **Edge Cases:** Test with malformed files, corrupt data, and boundary conditions
4. **Performance:** Benchmark with production-scale datasets
5. **Integration:** Validate within your application's security and privacy controls

**DICOM Test Images:**
- **NEMA DICOM Sample Images:** https://www.dicomstandard.org/resources/sample-images
- **OsiriX Sample Datasets:** https://www.osirix-viewer.com/resources/dicom-image-library/
- **TCIA (The Cancer Imaging Archive):** https://www.cancerimagingarchive.net/

---

## 11. Regulatory Disclaimer

**IMPORTANT: This library is not FDA-cleared, CE-marked, or approved for medical diagnostic use.**

DicomCore is provided as a software development library for creating applications that work with DICOM files. Organizations developing medical devices or diagnostic software using this library are solely responsible for:

- Obtaining necessary regulatory clearances (FDA 510(k), CE Mark, etc.)
- Conducting validation and verification activities
- Maintaining quality management systems (ISO 13485, FDA 21 CFR Part 820)
- Ensuring compliance with medical device software standards (IEC 62304)
- Implementing appropriate cybersecurity controls (FDA Premarket Guidance)
- Meeting privacy regulations (HIPAA, GDPR, etc.)

**Use at your own risk. No warranties are provided for fitness for any particular purpose, including medical diagnosis or patient care.**

---

### Safe Part 10 Rewrite and Anonymization

`DicomAnonymizer` (issue #1236) rewrites Part 10 files under a
`DicomRewritePolicy` of per-tag keep/remove/replace/remapUID actions plus a
private-tag switch. Rules apply recursively inside sequence items. The
transfer syntax and file meta consistency are preserved on write; Pixel Data
is always carried byte-for-byte — encapsulated payloads (Basic/Extended
Offset Tables, fragments, and delimiter) feed the writer's pass-through
unchanged, and native values copy their raw bytes. UID remapping is
deterministic (the same original UID maps to the same replacement within and
across operations), so study/series/instance and nested referenced-SOP
relationships stay consistent. The policy's UID root is validated against a
22-character budget before any output is produced (two 20-digit components
plus separators keep every remapped UID within the DICOM 64-character
maximum); oversized roots fail with the typed `uidRootTooLong` error.
Structural pixel-module elements are blocked from policy actions. Every
decision is audited (changed/removed/kept/blocked/unsupported/remapped) with
element paths and without recording original PHI values; invalid inputs fail
with typed errors.

The `defaultAnonymization` baseline replaces patient identity fields, blanks
Accession Number and Study ID, removes birth date, other patient names,
address, telephone numbers, referring physician, institution name, Station
Name, Device Serial Number, Requested Procedure ID, and private tags, and
remaps study/series/instance/frame-of-reference and referenced SOP UIDs.
Referenced Study Sequence (0008,1110) and Referenced Series Sequence
(0008,1115) are retained with their linkage UIDs remapped recursively. The
baseline is NOT the complete PS3.15 Basic De-identification Profile —
notably uncovered: dates and times beyond the birth date, operator/physician
names beyond the referring physician, free-text description and comment
fields, and the institution address.

### Executable Transfer Syntax Transcoding

`DicomTranscoder` (issue #1237) executes the routes the transcode planner
declares, as file-level operations that fail typed before producing any
output:

- **Native-to-native rewrite** and **same-syntax pass-through**: a safe
  Part 10 rewrite carrying every element and the Pixel Data bytes unchanged
  (encapsulated payloads byte-for-byte).
- **Decompression to Explicit VR Little Endian**: compressed sources whose
  decode backend is active decode frame-by-frame through
  ``DicomDecodedFrameReader`` and write native stored-value pixels with the
  pixel module, metadata, and file meta preserved. MONOCHROME2, MONOCHROME1,
  and RGB sources are supported: MONOCHROME1 display inversion is a
  full-range, self-inverse transform, so it is undone exactly during
  stored-value reconstruction and the Photometric Interpretation tag is
  preserved.
- **JPEG-LS encoding** is available through the async explicit-intent path:
  JLSwift 0.9.0 writes lossless .80 for reversible intent and near-lossless
  .81 only for an explicit NEAR value. Aligned 8–16-bit grayscale and RGB8
  encode per frame through the shared encapsulation path. The synchronous
  compatibility route remains CharLS lossless.
- **JPEG 2000/HTJ2K encoding** is exposed by async overloads that require a
  ``DicomEncodingIntent``. J2KSwift CPU writes .90/.91 and .201-.203 for
  aligned 8/16-bit grayscale (1-16 Bits Stored, signed or unsigned) and
  unsigned RGB8. Reversible routes are bit-exact and never select Metal;
  irreversible output is allowed only by general-purpose .91/.203 UIDs.
- Encapsulation writes one padded fragment per frame, a Basic Offset Table
  while 32-bit offsets fit, and Extended Offset Table/Lengths otherwise.
  The complete encoded object is assembled in memory before return.
- Irreversible output records lossy status, method, ratio, DERIVED semantics,
  derivation description, and a new SOP Instance UID in both the dataset and
  File Meta Information. Reversible output preserves any existing lossy
  history. JPEG 2000 Part 2 .92/.93 and ambiguous color/bit layouts stay
  typed unsupported.
- **JPEG XL encoding** is experimental and disabled by default. With
  `DICOM_JXLSWIFT_MODE=experimental`, async overloads write reversible .110,
  reversible or explicit irreversible .112, and reversible JPEG Baseline
  recompression .111. `.111` verifies byte-identical reconstruction and
  preserves SOP/lossy history; irreversible `.112` records `ISO_18181_1` and
  derives a new SOP Instance UID.

### Pixel Object Families and Typed Payloads

`DicomPixelObjectSupportMatrix` (issue #1238) declares how each
pixel-carrying object family is consumed, and
`DicomPixelObjectClassifier.typedPayload(from:)` extracts the typed payload
or rejects with a stable error naming the SOP Class, pixel data element type
((7FE0,0010)/(7FE0,0008)/(7FE0,0009)/none), transfer syntax, and the missing
metadata:

| Family | Role | Payload |
|--------|------|---------|
| Classic integer Pixel Data | Image display / volume input | `DicomDecodedFrameReader`, `displayRGBPixelBuffer`, `DicomSeriesLoader` |
| Segmentation Storage | Overlay/segmentation | `DicomSegmentation` (segment labels, binary/fractional payloads, labelmaps) |
| RT Dose | Dose grid | `DicomRTDoseVolume` (Dose Grid Scaling required and enforced; units, grid frame offsets, geometry) |
| Parametric Map | Volume input | `DicomParametricMap` (Float/Double Float scalar volumes with Real World Value Mapping) |
| Float Pixel Data outside Parametric Map | Out of scope | Typed rejection |
| Double Float Pixel Data outside Parametric Map | Out of scope | Typed rejection |

### Metadata Parsing Hardening Policy

Decisions of record for parser edge cases (issue #1235):

- **Undefined-length non-SQ elements** put the scanner into item mode: the
  element's value is never materialized, items are skipped structurally, and
  scanning resumes after the matching sequence delimiter. This is a safe
  skip, never a hard failure, including for values nested inside sequences.
- **Stray item/sequence delimiters** outside any open sequence reset the
  sequence state and are ignored.
- **Unknown explicit VR codes** (two uppercase ASCII letters that match no
  defined VR, e.g. retired or vendor codes) are treated as short-form
  explicit elements and skipped by their declared 16-bit length.
- **Declared lengths past the end of data** clamp to the remaining bytes;
  when that swallows the rest of the stream the load fails with a typed
  `invalidDICOMFormat` error — never a crash or silent partial success.
- **Large values stay lazy**: oversized private payloads are skipped by
  length during the metadata scan and pixel data is only materialized on
  first pixel access. Pixel module, VOI window, modality LUT, overlay, and
  geometry attributes are all readable without decoding pixels.
- **Specific Character Set** covers ISO_IR 6/13/100/101/109/110/126/127/
  138/144/148/166/192, the ISO 2022 JP escapes, and GB18030/GBK for
  patient/study metadata used by import and display.
- **Private tags**: creator blocks and their private elements survive read
  and Part 10 rewrite, including multiple creators in one group.

## Appendix A: Transfer Syntax UID Reference

Complete list of DICOM Transfer Syntax UIDs mentioned in this document:

| UID | Name | Support |
|-----|------|---------|
| 1.2.840.10008.1.2 | Implicit VR Little Endian | ✅ Full |
| 1.2.840.10008.1.2.1 | Explicit VR Little Endian | ✅ Full |
| 1.2.840.10008.1.2.1.99 | Deflated Explicit VR Little Endian | out-of-scope for pixel codecs; dataset deflate supported |
| 1.2.840.10008.1.2.2 | Explicit VR Big Endian | ✅ Full |
| 1.2.840.10008.1.2.4.50 | JPEG Baseline (Process 1) | delegated ImageIO 8-bit |
| 1.2.840.10008.1.2.4.51 | JPEG Extended (Process 2 & 4) | native 12-bit grayscale decode; <=8-bit via ImageIO |
| 1.2.840.10008.1.2.4.57 | JPEG Lossless, Non-Hierarchical (Process 14) | decoded native |
| 1.2.840.10008.1.2.4.70 | JPEG Lossless, Non-Hierarchical, First-Order Prediction | decoded native |
| 1.2.840.10008.1.2.4.80 | JPEG-LS Lossless Image Compression | async JLSwift candidate/CharLS fallback; reversible CPU encode/transcode |
| 1.2.840.10008.1.2.4.81 | JPEG-LS Lossy Near-Lossless Image Compression | async JLSwift candidate/CharLS fallback; explicit-NEAR CPU encode/transcode |
| 1.2.840.10008.1.2.4.90 | JPEG 2000 Image Compression (Lossless Only) | async decode candidate/fallback; reversible CPU encode/transcode |
| 1.2.840.10008.1.2.4.91 | JPEG 2000 Image Compression | async decode candidate/fallback; reversible or irreversible CPU encode/transcode |
| 1.2.840.10008.1.2.4.92 | JPEG 2000 Part 2 Multi-component Image Compression (Lossless Only) | delegated OpenJPEG volume document |
| 1.2.840.10008.1.2.4.93 | JPEG 2000 Part 2 Multi-component Image Compression | delegated OpenJPEG volume document |
| 1.2.840.10008.1.2.4.110 | JPEG XL Lossless | experimental JXLSwift reversible decode/encode; disabled by default |
| 1.2.840.10008.1.2.4.111 | JPEG XL JPEG Recompression | experimental byte-identical JPEG Baseline bridge; disabled by default |
| 1.2.840.10008.1.2.4.112 | JPEG XL | experimental reversible/irreversible decode/encode; disabled by default |
| 1.2.840.10008.1.2.4.94 | JPIP Referenced Transfer Syntax | streamed-only |
| 1.2.840.10008.1.2.4.95 | JPIP Referenced Deflate Transfer Syntax | streamed-only |
| 1.2.840.10008.1.2.4.100-.108 | MPEG-2/H.264/HEVC video families | streamed-only |
| 1.2.840.10008.1.2.4.201 | HTJ2K Image Compression (Lossless Only) | OpenJPEG decode; reversible CPU encode/transcode |
| 1.2.840.10008.1.2.4.202 | HTJ2K Image Compression (Lossless RPCL) | OpenJPEG decode; reversible CPU RPCL encode/transcode |
| 1.2.840.10008.1.2.4.203 | HTJ2K Image Compression | OpenJPEG decode; reversible or irreversible CPU encode/transcode |
| 1.2.840.10008.1.2.5 | RLE Lossless | decoded native |

---

## Appendix B: Standard DICOM Tag Reference

Commonly used DICOM tags with group/element numbers and VR (Value Representation):

### Patient Information Elements (0010,xxxx)

| Tag | VR | Name |
|-----|-----|------|
| (0010,0010) | PN | Patient Name |
| (0010,0020) | LO | Patient ID |
| (0010,0030) | DA | Patient Birth Date |
| (0010,0040) | CS | Patient Sex |

### Study Information Elements (0020,xxxx and 0008,xxxx)

| Tag | VR | Name |
|-----|-----|------|
| (0020,000D) | UI | Study Instance UID |
| (0008,0020) | DA | Study Date |
| (0008,0030) | TM | Study Time |
| (0008,1030) | LO | Study Description |
| (0008,0050) | SH | Accession Number |

### Series Information Elements (0020,xxxx and 0008,xxxx)

| Tag | VR | Name |
|-----|-----|------|
| (0020,000E) | UI | Series Instance UID |
| (0020,0011) | IS | Series Number |
| (0008,0060) | CS | Modality |
| (0008,103E) | LO | Series Description |

### Image Information Elements (0020,xxxx and 0018,xxxx)

| Tag | VR | Name |
|-----|-----|------|
| (0008,0018) | UI | SOP Instance UID |
| (0020,0032) | DS | Image Position (Patient) |
| (0020,0037) | DS | Image Orientation (Patient) |
| (0020,0013) | IS | Instance Number |
| (0018,0050) | DS | Slice Thickness |
| (0020,1041) | DS | Slice Location |

### Image Pixel Elements (0028,xxxx)

| Tag | VR | Name |
|-----|-----|------|
| (0028,0010) | US | Rows |
| (0028,0011) | US | Columns |
| (0028,0100) | US | Bits Allocated |
| (0028,0101) | US | Bits Stored |
| (0028,0102) | US | High Bit |
| (0028,0103) | US | Pixel Representation |
| (0028,0002) | US | Samples Per Pixel |
| (0028,0004) | CS | Photometric Interpretation |
| (0028,1050) | DS | Window Center |
| (0028,1051) | DS | Window Width |
| (0028,1052) | DS | Rescale Intercept |
| (0028,1053) | DS | Rescale Slope |
| (0062,0001) | CS | Segmentation Type |
| (0062,0002) | SQ | Segment Sequence |
| (0062,000A) | SQ | Segment Identification Sequence |
| (0062,0021) | UI | Tracking UID |
| (3004,000E) | DS | Dose Grid Scaling |
| (3006,0020) | SQ | Structure Set ROI Sequence |
| (3006,0039) | SQ | ROI Contour Sequence |
| (3006,0050) | DS | Contour Data |
| (300A,00B0) | SQ | Beam Sequence |
| (300A,0111) | SQ | Control Point Sequence |
| (7FE0,0010) | OB/OW | Pixel Data |

---

## See Also

- <doc:Architecture>
- <doc:PerformanceGuide>
- <doc:MigrationGuide>
- ``DCMDecoder``
- ``DCMWindowingProcessor``
- ``DicomSeriesLoader``
