# DICOM Conformance Statement

## Optional LDAP authentication

`DicomLDAPAuthenticationService` and `dicomtool ldap` provide optional LDAPv3
simple bind, exact user lookup and direct group membership search. LDAPS uses
the existing TLS 1.2+ factory with certificate and hostname validation. Explicit
numeric-loopback plaintext exists for tests; there is no TLS downgrade or
unverified-certificate option. Only completed, bounded searches and a nonempty
successful user bind can produce an identity. Explicit injected mappings turn
groups into scopes/roles, and the existing injected `DicomAuthorizing` decides
each requested operation. Authentication and decisions use existing audit events.
Credentials are supplied transiently, outside configuration and process arguments.
This is an independent RFC 4511/4513/4515 implementation, not incorporated Mayam
source. SASL, StartTLS, paging, referrals, nested groups and complete AD support
are outside this profile. It does not replace the host's local principal.

Comprehensive DICOM conformance documentation detailing supported transfer syntaxes, SOP classes, and implementation capabilities.

## Overview

This DICOM Conformance Statement describes the capabilities and limitations of the DicomCore library (version 2.0.1) in accordance with DICOM Part 2: Conformance. DicomCore is a Swift DICOM file library for iOS, visionOS, and macOS 26+ that parses DICOM medical imaging files, extracts metadata, provides pixel data access with optional GPU-accelerated image processing, writes controlled Part 10 datasets, and exposes transport-injected DICOMweb service helpers covered by package tests.

**Implementation Type:** DICOM File Decoder/Writer Library with transport-injected DICOMweb helpers and bounded stateless JPIP progressive pixel streaming

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
- **Local file access by default** - no production PACS server or persistent archive is implemented by the package; authorization and audit policy are supplied by the application
- **Scoped DICOMweb helpers** - QIDO-RS, WADO-RS, WADO-URI, STOW-RS, BulkDataURI, auth-header, pagination, multipart, and stable-error behavior are described by ``DicomWebConformanceMatrix``
- **JPIP referenced pixel data** - metadata parsing recognizes Pixel Data Provider URL and the HTTPS-first stateless transport requests bounded cumulative classic JPEG 2000 or HTJ2K image entities with origin policy, authorization, cancellation, and pull backpressure
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
| **Enhanced Multi-frame Functional Groups** | Parse shared/per-frame geometry, timing, pixel measures, Frame VOI, and source references | ✅ Synthetic Enhanced CT/MR, native or decodable compressed pixel data |
| **Enhanced CT/MR Classic Conversion** | Convert the qualified single-stack profile into one validated classic CT/MR Part 10 instance per frame | ✅ Native and RLE Lossless MONOCHROME1/2, aligned 8/16-bit |
| **Quantitative Values** | Parse Real World Value Mapping linear/LUT items and calculate PET SUV variants when required metadata is present | ✅ Supported for uncompressed native pixel data |
| **Encapsulated Pixel Data Indexing** | Parse Basic Offset Table, Extended Offset Table, fragments, and frame-to-fragment mappings | Supported before codec decode |
| **DICOM Segmentation** | Parse binary/fractional SEG frames, preserve segment/source/geometry metadata, and build synthetic SEG datasets | ✅ Synthetic binary and fractional |
| **Radiotherapy Objects** | Parse RTSTRUCT contours, RTDOSE scaled volumes, and RTPLAN beam/control point metadata | ✅ Synthetic RT objects |
| **Parametric Map** | Parse integer, Float Pixel Data, and Double Float Pixel Data scalar maps with units, quantity definitions, RWV, geometry, and source references | ✅ Synthetic PM |
| **Overlay Plane** | Parse all repeating groups 6000-601E as frame-specific one-bit masks, including retired embedded native overlays | ✅ Standalone and native single-sample embedded overlays |
| **Structured Reports and Key Objects** | Parse SR/KOS content trees, measurements, ROI/source references, CAD findings, and key image references; build controlled SR/KOS datasets; validate Enhanced/Comprehensive SR TID 1500 and KOS references through an explicit support matrix | ✅ Synthetic SR/KOS with scoped semantics |
| **Secondary Capture Objects** | Build RGB/monochrome snapshot datasets, parse SC metadata/source references, and write Part 10 SC files | ✅ Synthetic SC |
| **Inference Output Objects** | Build external inference outputs as SR findings, SEG masks, GSPS graphics, and derived images with source references and tracking identifiers | ✅ Synthetic SR/SEG/GSPS |
| **Encapsulated Documents** | Build, parse, and export Encapsulated PDF/CDA/STL payloads with MIME, title, concept, and source instance metadata | ✅ Synthetic DOC |
| **Waveform Objects** | Build and parse ECG/related temporal signal objects with channel samples, sampling frequency, units, and waveform references | ✅ Synthetic ECG |
| **Video Objects** | Build and parse Video Endoscopic/Microscopic/Photographic objects, preserving MPEG-2/H.264/H.265 streams and timing metadata for player handoff | ✅ Synthetic video |
| **JPEG 2000 Part 2 Volume Documents** | Decode multi-component component collections into `DicomSeriesVolume` buffers with geometry metadata | ⚠️ Best-Effort OpenJPEG runtime |
| **JPIP Progressive Pixel Data** | Recognize `.94/.95/.204/.205` referenced pixel URLs and expose bounded complete-entity updates with cancellation/backpressure | ⚠️ Stateless complete-entity profile |
| **Transfer Syntax Conversion** | Plan safe conversion paths and execute qualified explicit-intent codec routes, including experimental JPEG XL | Planning API, typed guards, and `DicomTranscoder` |
| **DICOMweb Service Helpers** | Serialize and test scoped QIDO-RS, WADO-RS, WADO-URI, STOW-RS, BulkDataURI, auth-header, pagination, multipart, and stable-error behavior | Scoped matrix |
| **Production PACS Networking** | Persistent archive, managed authorization and PHI audit policy, JPIP proxying, and archive operations | ❌ Not Supported |
| **DICOM File Creation** | Write native/Deflated Part 10 datasets, referenced JPIP metadata, DICOMDIR files, and caller-provided encapsulated pixel/video streams without recompression | ✅ Supported with scoped writer matrix |

### 1.3 DICOMweb Service Helper Matrix

The DICOMweb surface is a helper API, not a complete production PACS client or
server. The authoritative runtime matrix is
``DicomWebConformanceMatrix/packageDefault`` and is exposed by
``DicomWebServer`` at `/dicom-web/conformance`.

| Feature | Client | Server | Responsibility | Notes |
| --- | --- | --- | --- | --- |
| QIDO-RS | supported | study, series and instance searches | `DicomWebClient`/`DicomWebServer` | The client searches all three levels with attribute matches, `includefield`, `fuzzymatching`, `limit` and `offset`. The server applies PS3.4 matching, projection and `limit`/`offset` through injected search providers and announces further results with Warning 299. |
| WADO-RS metadata | supported | supported | `DicomWebClient`/`DicomWebServer` | The client decodes DICOM JSON one data set at a time, reads elements outside the DICOM JSON model tolerantly, and lists `BulkDataURI` values for `resolveBulkData(in:)`. The server emits study, series and instance metadata as DICOM JSON or multipart XML with server-owned `BulkDataURI` references. |
| WADO-RS instance | supported | supported | `DicomWebClient`/`DicomWebServer` | The client retrieves studies, series and instances into a `DicomWebRetrieveSink` as parts arrive, with one Accept or a `DicomWebAcceptList` that asks again without the refused ranges after a fallback status (406 by default, and 500 once per retrieve after a range that names a transfer syntax). The server labels the stored transfer syntax and uses exact entity/per-part lengths plus part `Content-Location`. It streams a study, series or instance one part at a time, without a limit on the total response size. |
| WADO-RS frame | supported | supported | `DicomWebClient`/`DicomWebServer` | The client asks for `application/octet-stream` frames with `transfer-syntax=*` by default, or with the caller's Accept. The server answers strict ascending one-based frame lists with bounded native or compressed `multipart/related` representations. |
| WADO-RS rendered frame | supported | supported | `DicomWebClient`/`DicomWebServer` | The client's `DicomWebRenderedOptions` set `quality`, `viewport`, `window` and one image type by default for rendered and thumbnail retrieves of a study, series, instance or frame list. The server renders native grayscale and color frames as direct or multipart JPEG, PNG, or GIF representations. |
| WADO-URI | supported | supported | `DicomWebClient`/`DicomWebServer` | Object retrieval is covered by HTTP serialization tests. |
| STOW-RS | supported | supported for Part 10 payloads | `DicomWebClient`/`DicomWebServer` | Client part headers carry bare `application/dicom` plus an optional canonical ASCII transfer syntax UID. Part 10 File Meta Information supplies a missing UID or must match an explicit UID; opaque non-Part-10 data retains caller-owned labeling. Instances given as data or data sets form a body held in memory within `maximumSTOWRequestBodyBytes` (128 MiB by default); files go straight from disk through a `DicomWebStreamedBodyTransport`, each within `maximumSTOWInstanceBytes` (4 GiB by default). `storeFiles` sends batches and reports every file from the Annex I response, including partial 202 and 409 answers, 4xx answers that carry a Failed SOP Sequence, and the `Warning` header. The server validates Part 10 identity and transfer syntax while streaming and returns the Annex I response module. |
| UPS-RS | Worklist operations and reconnecting notification client | A1 engine-backed Worklist Service | `DicomWebServer`, `DicomWebHTTP` | PS3.18 chapter 11 transactions, JSON and multipart XML; RFC 6455 notification connections. |
| BulkDataURI | transport-injected | provider-backed opaque routes | `DicomWebClient` or caller transport, `DicomWebServer` | The client resolves absolute and relative references through the origin policy, relative ones against the request that returned them, fails a reference answered in several parts instead of keeping one, and can fetch a byte range with HTTP `Range`. The server references bulk payload tags, and other binary values above `inlineBinaryThresholdBytes`, through provider-backed routes. |
| JPIP | HTTPS-first stateless complete-entity transport | conditional on an injected `DicomJPIPServer` | `DicomJPIPHTTPTransport` and `DicomJPIPClient` | Exact-origin allowlisting, finite byte/layer limits, authorization port, same-origin redirects, pull backpressure, and cancellation are implemented; JPP/JPT parsing, sparse caching, reconstruction and HTTP channels are experimental opt-in paths with incomplete qualification; see the JPIP qualification note below. `DicomWebServer` serves JPIP under its configured service path when a `DicomJPIPServer` is injected. |
| Multipart | supported | supported | `DicomWebMultipartStreamParser` and STOW/WADO helpers | Emitters use exact entity/per-part lengths and WADO resource locations. The incremental parser validates declared lengths, tolerates legacy missing part length/location headers, and marks the root part that `start` names by `Content-ID`. The current PS3.18 audit is recorded in the repository's `../../../../DISTRIBUTION.md`. |
| Authentication | caller headers and per-request provider | injected bearer, Basic or JWT verifier | Application security layer | The client sends its configured headers to the base origin only, and can ask a `DicomWebAuthorizationProvider` (for example `DicomWebOIDCAuthorization` from the `DicomWebOIDC` product) for credentials before each request, renewing them once after a 401. HTTPS trust follows the system evaluation, which an added anchor or a server certificate SHA-256 can extend while the host name check stays, and a configured client certificate answers mutual TLS. Applications own authorization and audit policy. |
| Pagination | `limit`/`offset` query items and `searchPages` | `limit`/`offset` applied | `DicomWebSearchPager` and server QIDO | The pager follows `offset`, returns each result once by the UID of its level, and ends with a stop reason on a repeated page or at `DicomWebSearchPagingLimits`. The server pages every QIDO level. |
| Error semantics | stable typed errors and opt-in retries | stable HTTP status and error-code headers | `DicomWebError`, `DicomWebRetryPolicy` and `DicomWebServerErrorCode` | `DicomWebError` keeps the status, `Retry-After`, `Warning`, a credential-free body preview and the Accepts a fallback sent. `DicomWebRetryPolicy`, off by default, repeats GETs on 408, 429, 502, 503, 504 and transient connection failures, and STOW only on 429 or 503 or when the connection failed before any byte of the answer arrived. Cancelling the caller task cancels the request. Frame routes use typed `400`, `404`, `406`, `413`, and `422`; UPS-RS uses transaction-specific status and Warning headers. |
| Large payload streaming | streaming transport and bounded staging | incremental STOW and multipart instance output | `DicomWebClient`, `DicomWebServer` and optional `DicomWebHTTP` | `URLSessionDicomWebHTTPTransport` streams request and response bodies: retrieves hand parts to a sink as they arrive, metadata is decoded one data set at a time, and STOW files stream from disk. Server STOW and aggregate retrieval materialize at most one instance payload at a time; `send` remains a buffered compatibility adapter. |

Raw frame retrieval requires `Accept`. Byte-aligned native Pixel Data is returned
Little Endian in one multipart part with requested frames concatenated in ascending
order. JPEG, JPEG-LS, JPEG 2000, HTJ2K, JPEG XL, and RLE Lossless encapsulated
representations are passed through without relabeling or transcoding, one part per
frame. Native rendered retrieval accepts JPEG, PNG, or GIF and supports JPEG
`quality`, a width/height `viewport`, and a center/width `window` with an optional
`linear` function. A rendered study or series returns the first frame of each
instance, and thumbnails are served for studies, series, instances and frames. One-bit native
repacking, compressed or video rendering, viewport cropping, and annotation burn-in
are explicit exclusions. ``DicomWebServerConfiguration`` bounds frame-list length,
frames per request, raw response bytes, rendered pixels, and rendered response bytes.

#### Experimental JPIP databin client qualification

Complete-entity negotiation remains the default: classic referenced syntaxes
select `image/jp2`, while HTJ2K referenced syntaxes select `image/jph` or
`image/jphc`. Dataset Deflate does not alter HTTP or codestream encoding.
Explicit stream modes and configuration allow `image/jpp-stream` and
`image/jpt-stream`; this is not a declaration of completed T.808 conformance.

The incremental parser retains incomplete messages across chunks, recognizes
EOR and enforces finite message/bin/response limits. The cache retains sparse
ranges and completion lengths, rejects conflicting overlaps and mixed JPP/JPT
representations, and reports useful/redundant databin bytes. Active-window
protection derives overlapping precincts from the main header, including partial
border overlaps; headers of the active codestream remain pinned. Cache imports
parse model/need descriptors as negotiation metadata, never fabricated received
bytes. Exports advertise only actual contiguous prefixes. `need` is stateless
and mutually exclusive with `model`/`tpmodel`.

`DicomJPIPWindow` exposes typed window and quality fields. `DicomJPIPSession`
retains a channel/cache, reports first-preview/final timestamps and peak cache
bytes, and closes via `cclose` alone. The request scheduler cancels superseded
URLSession work, retaining parsed messages. An interrupted session reissues its
window on the same channel; if the server returns completed EOR while bytes are
still missing, a stateless repair advertises the actual cache and retains the
channel. Peers such as OpenJPIP 1.5.2 must explicitly disable unsupported cache
model fields (`supportsCacheModel: false`); their repair can retransmit data.

JPT reconstruction preserves complete tile-parts. JPP reconstruction emits
packets in progression order, using PLT lengths or extended-precinct packet
boundaries where available and substituting empty packets for unavailable
complete packets. Five progression orders have hermetic PLT first-layer and
final pixel goldens. Class-0 precincts without packet boundaries preserve their
contiguous bytes for decoder truncation; not every such partial stream is
decodable. LRCP/RLCP with multiple layers requires packet boundaries. Tile
COD/COC/POC overrides remain rejected with a typed error. CAP/CPF bytes are
preserved; a hermetic HTJ2K JPT passthrough preserves the complete codestream and
pixels, but lacks independent JPIP-server evidence.

A stream payload is final only with EOR 1 or 2 and complete window coverage.
Complete-entity finality retains its existing scheduling semantics.
Sparse/unknown coverage fractions are byte-coverage estimates, not clinical
quality measurements.

The supplied OpenJPIP 1.5.2 qualification executes within 46 JPIP tests, with
zero failures and one unrelated legacy reference-endpoint skip. Cumulative JPP
updates 1/3/5, JPT updates 1/2/3/5, reduced resolution, and interruption/repair
have passing pixel comparisons. JPP layer 2 has matching reconstructed bytes
but remains undecodable in both client and oracle. The ROI client/oracle crops
match; the server omits required lower-resolution precincts and their crop
differs from the original. Original layer-limited decodes also differ from the
server's partial quality behavior. These tool/tool discrepancies are explicit
versioned expected failures, not waived client/oracle comparisons or proof of
complete T.808 interoperability. Overlapping windows use 166260 then 3 response
bytes. Reconnect retains 318950 useful bytes, replays 124195 bytes and reaches
a matching final image. `stream`, cache-model peer negotiation and HTJ2K retain
"pending independent evidence" status. See `DICOM-Swift/Scripts/interop/README.md`
for the oracle procedure, fixtures, measured accounting and limitations.

## 1.4 DIMSE and Storage SCP Helper Matrix

The DIMSE surface is a package helper for tested SCU/SCP workflows and
DICOM-Swift-parity validation, not a full managed PACS service. Applications still
own deployment, archive policy, PHI audit logging, operator authorization, and
remote archive qualification.

| Feature | Supported Surface | Responsibility | Notes |
| --- | --- | --- | --- |
| C-ECHO | Verification SCU and SCP | `DicomDIMSEServiceSCU.verify` and `DicomStorageSCPService` | Association negotiation, listener response, progress, retry, timeout, and success status are covered by package tests. |
| C-FIND | Study Root and Modality Worklist SCU | `DicomDIMSEServiceSCU.find` and `findModalityWorklist` | Pending identifiers, final status, and scheduled procedure step mapping are tested. |
| C-GET | Study Root retrieve SCU with C-STORE suboperation handling | `DicomDIMSEServiceSCU.get` | Per-instance delivery after the C-STORE response and collector compatibility are tested. |
| C-MOVE | Study Root retrieve SCU | `DicomDIMSEServiceSCU.move` | Pending/completed suboperation progress and move destination AE title propagation are tested. |
| C-STORE | Storage SCU and Storage SCP | `DicomDIMSEServiceSCU.store`, `DicomStorageSCPService`, `DicomStorageSCPServer` | Part 10 payload parsing, transfer-syntax mismatch rejection, file cache writes, and association handling are tested. |
| Storage Commitment | Push Model SCP request handling and N-EVENT-REPORT SCU delivery | `DicomStorageSCPService`, `DicomStorageCommitmentPersistence`, and `DicomDIMSEServiceSCU.reportStorageCommitment` | The package supports caller-provided durable checkpoints before successful C-STORE/N-ACTION responses, per-reference failure reasons, Event Type 1/2 datasets, mandatory reverse-role negotiation, and response validation. Transaction storage, destination resolution, and retry policy remain caller-owned. |
| MPPS | N-CREATE and N-SET SCU helpers | `DicomDIMSEServiceSCU.createMPPS` and `updateMPPS` | Modality worklist-derived create/update datasets are covered by package tests. |
| Basic Grayscale/Color Print | Basic Grayscale and Basic Color Print Management Meta, matching Image Box, and Printer SOP Classes | `DicomPrintJob` and `DicomDIMSEServiceSCU.sendPrintJob` | Auto proposes both modes and prefers color; explicit color never falls back to grayscale. Grayscale image boxes carry MONOCHROME2 and color image boxes carry color-by-plane RGB8 with Planar Configuration 1. The SCU optionally queries Printer Status with N-GET before and after film acceptance and confirms Printer N-EVENT-REPORT Event Types 1/2/3. Printers that reject or refuse this optional status path retain the print flow. Presentation LUT shape/table, optional Print Job monitoring with N-GET/N-EVENT-REPORT, Printer Configuration Retrieval, Annotation Box and per-film partial results are supported; storage commitment is a separate service. A printer that grants fewer image boxes than the job requested fails the job with `DicomPrintManagementError.insufficientImageBoxes(requested:granted:)` before any N-SET; the SCU never invents image box SOP Instance UIDs. |
| TLS | Client and Storage SCP listener configuration | `DicomTLSConfiguration` and `DicomTLSOptionsFactory` | Certificate, private-key, trust-store, server-name, and the DICOM PS3.15 B.12 BCP 195 RFC 8996/9325 profile are tested where Network/Security are available. TLS 1.2 is the minimum; newer protocol and cipher negotiation remains system-managed. Retired serialized profile identifiers decode as B.12. |
| User identity | Association user identity negotiation | `DicomUserIdentity` | User identity is rejected before association setup when TLS is disabled. |
| Pooling/retry/cancellation | Association pooling, retry policy, circuit breaker, operation handle, progress, and audit log | `DicomDIMSEAssociationPool`, `DicomNetworkRetryPolicy`, `DicomNetworkCircuitBreaker`, `DicomDIMSEOperationHandle` | Cancellation avoids retries and circuit-breaker trips; pooling keys include node, AE titles, TLS, identity, transfer syntaxes, timeout, and bandwidth settings. |
| External archive interop | Optional smoke tests and scripts | `DicomInteropSmokeTests` and interop tooling | Orthanc/dcm4che/DICOM-Swift smoke tests require caller-provided endpoints and are not bundled production services. The DICOMweb smoke covers STOW-RS in batches with a refused instance, paged QIDO-RS, WADO-RS retrieve of a study, series and instance, frames, an Accept fallback, and `BulkDataURI` values of pixel data and palette color LUTs. On 2026-10-04 it passed against dcm4chee 5.35.2 and Orthanc 1.13.0 in two consecutive runs, with the dcm4chee study rejected (`113039^DCM`) between them. dcm4chee refuses an Accept it cannot transcode with 500 instead of 406, and gives all representations of an instance one `ETag` without `Vary: Accept`, so the client's URLSession transport sends every request to the server and stores no response in the URL cache. |

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
| Overlay Plane | Pixel-bearing image instances using repeating groups 6000-601E | Overlay Rows, Columns, Type, Origin, Bits Allocated, and Bit Position; Overlay Data for standalone planes | Standalone OB/OW Overlay Data in native or encapsulated image instances; embedded planes require native 8/16/32-bit single-sample Pixel Data | Up to 16 planes; LSB-first continuous multi-frame bits; one-based and non-positive origins; Image Frame Origin alignment; single overlays apply to every image frame | Group, type, source, origin, dimensions, and bit position are preserved in the normalized result | Embedded overlays in compressed or multi-sample Pixel Data, malformed/truncated data, and overlay color without a Presentation State | Malformed or non-applicable planes are omitted from `overlayPlanes(forFrame:)` |
| Image export | Native pixel-bearing image instances through `DCMDecoder` and `DicomImageExporter` | Pixel Data, Rows, Columns, Samples per Pixel, Photometric Interpretation, Bits Allocated, Bits Stored, High Bit, Pixel Representation | Native uncompressed Part 10 datasets addressable by `DicomPixelDataDescriptor` | `display8` exports PNG/JPEG/TIFF with resize and annotation burn-in; `native16Bit` exports unsigned single-sample TIFF only | Optional non-PHI sidecars preserve frame number, modality, dimensions, windowing, spacing, and transfer syntax context | Native 16-bit RGB, signed `native16Bit` TIFF, resize/annotations in `native16Bit` mode, compressed/video/referenced pixel export | `DicomImageExportError.unsupportedPixelMode` or `invalidPixelData` |
| Secondary Capture | Secondary Capture Image Storage synthetic snapshots | Clinical export validation requires SOP Instance UID, Study Instance UID, Series Instance UID, Patient Name, Patient ID, Study ID, Study Date, Series Number, Instance Number, and the Image Pixel module | Explicit VR Little Endian Part 10 with native uncompressed Pixel Data | 8/16-bit unsigned MONOCHROME2 or 8-bit interleaved RGB with planar configuration 0 | Patient, study, series, instance, device, derivation, and source image references are preserved when supplied; media-attachment authoring writes required Type 2 patient/study/manufacturer elements even when empty | Signed stored pixels, planar RGB, non-RGB three-sample payloads, unsupported bit depths, missing clinical context in strict export validation | `DicomSecondaryCaptureError.missingRequiredMetadata` or `unsupportedPixelLayout` |
| Print management | Basic Grayscale and Color Print Management Meta SOP Classes with Basic Film Session, Basic Film Box, matching Image Box, Basic Annotation Box, and Printer | Film session copy/priority/medium/destination, film box layout/orientation/size, image box position, and grayscale or RGB 8-bit image pixel attributes | Negotiated DIMSE presentation context, defaulting to Explicit VR Little Endian when absent | Grayscale jobs send 8-bit MONOCHROME2; color jobs send color-by-plane RGB8 with Planar Configuration 1; automatic mode prefers color and falls back to grayscale | Film session label, film box display settings, queue status, and returned image box SOP Instance UIDs are preserved | Retired Print Image Overlay/Combined Print Image; film boxes for which the printer grants fewer image boxes than the highest requested position | `DicomPrintManagementError.unsupportedService`, `printModeNotNegotiated(_:)`, or `insufficientImageBoxes(requested:granted:)` |
| Waveform | 12-lead ECG, General ECG, Ambulatory ECG, General 32-bit ECG, Hemodynamic, Cardiac Electrophysiology, Arterial Pulse, Respiratory, Multi-channel Respiratory, Routine Scalp EEG, EMG, EOG, Sleep EEG, Basic Voice Audio, and General Audio Waveform Storage | Waveform Sequence, Number of Channels, Number of Samples, Sampling Frequency, Channel Definition Sequence, Waveform Bits Allocated, Waveform Sample Interpretation, and Waveform Data | Native dataset and Part 10 writing through `DicomDataSetWriter`; compressed waveform encodings are not implemented | SB, UB, SS, US, SL, UL, MB, and AB samples are interleaved by sample then channel with range checks; Multi-channel Respiratory is constrained to SS or SL | Channel labels, source concepts, units, sensitivity, filters, timing offsets, display scale, and source waveform references are preserved | Float/double samples, vendor-specific packed encodings, inconsistent channel sample counts, malformed payload lengths, and non-SS/SL Multi-channel Respiratory samples | `DicomWaveformError.unsupportedSampleInterpretation`, `sampleOutOfRange`, or `invalidWaveformData` |
| Video | Video Endoscopic, Video Microscopic, and Video Photographic Image Storage | SOP Class UID, Rows, Columns, Number of Frames, timing metadata when available, transfer syntax UID, and encapsulated Pixel Data | MPEG-2, MPEG-4 AVC/H.264, and HEVC/H.265 DICOM video transfer syntaxes | Encoded streams and indexed encoded frame fragments are preserved by default for caller handoff; forwarding callers can select stream-only retention; native frame decode and video encoding are not implemented | Codec, timing, frame rate, duration, source references, lossy compression method, and raw stream bytes are preserved; media-attachment authoring writes required Type 2 patient/study/manufacturer elements even when empty | Non-video transfer syntaxes, native video frame decoding, video transcoding, and server-side DICOMweb rendered frames | `DicomVideoError.unsupportedTransferSyntax`, `nativeFrameDecodeUnsupported`, `transcodingUnsupported`, or `DICOMWEB_RENDERED_FRAME_UNSUPPORTED` |

### 1.6 Sequencing of Real-World Activities

`DicomSeriesLoader` declares its volume scope through
``DicomSeriesLoaderSupportMatrix``. The standard matrix accepts Bits Allocated
8, 16, or 32; any Bits Stored up to Bits Allocated with High Bit = Bits Stored − 1
(the unused high bits are masked and a signed sample's sign is its top stored bit);
Pixel Representation 0 or 1; Samples per Pixel 1; MONOCHROME1 or MONOCHROME2;
absent Planar Configuration; one frame per file; and native uncompressed or
compressed pixel transfer syntaxes whose decode backend is active (compressed
slices decode once per slice through ``DicomDecodedFrameReader``). It preserves
rescale slope/intercept, VOI/window metadata, pixel spacing, orientation,
origin, image instance metadata, and slice ordering by Image Position
projection, then Instance Number, then localized filename. Compressed transfer
syntaxes without an active decode backend, color/multi-sample data, explicit
planar configuration, Bits Stored above Bits Allocated or not starting at bit 0, and
multiframe images
fail with typed errors carrying transfer syntax and pixel metadata.
Enhanced CT/MR multiframe objects assemble through
`DicomSeriesLoader.loadEnhancedMultiframeVolume(at:)`: Shared and Per-Frame
Functional Groups provide geometry (Plane Position/Orientation, Pixel
Measures), per-frame rescale (Pixel Value Transformation), and Frame VOI;
frames order by position along the normal, and each frame decodes one at a time through
``DicomDecodedFrameReader`` — so compressed multiframe objects use exactly the
same path as native ones when the transfer syntax has an active backend.
Frame VOI uses Per-Frame-over-Shared precedence and remains available for each
spatially ordered slice. The first valid Frame VOI window in that order is the
deterministic volume default; top-level Window Center/Width is used only when
no Frame VOI window is valid.
Unsupported multiframe shapes fail typed with SOP Class, frame count,
transfer syntax, and the missing functional-group context. This qualification
is limited to one spatial stack. Dimension Organization is not interpreted to
partition multiple stacks; callers must
reject or isolate those inputs before volume assembly.

``DicomEnhancedMultiframeConverter`` additionally converts qualified Enhanced
CT/MR single-stack objects to classic CT/MR Image Storage. It requires native
uncompressed or RLE Lossless MONOCHROME1/2 with one sample, aligned 8/16-bit
stored values, Study/Series/SOP and Frame of Reference UIDs, complete plane
geometry, positive Pixel Spacing, and at most the single Stack ID/In-Stack
Position dimension pair. Output frames are spatially ordered, carry fresh
Series/SOP UIDs, `DERIVED\SECONDARY`, and a one-based source-frame reference,
and are written as native Explicit VR Little Endian. Shared/Per-Frame geometry,
Pixel Measures, rescale, and Frame VOI are flattened with Per-Frame-over-Shared
precedence. Each output is reopened and its identities, provenance, attributes,
pixels, transfer syntax and absence of multiframe/dimension/offset-table tags
are checked before the result is returned. RGB, wider storage, extra stacks or
dimensions, incomplete geometry and every other SOP Class/transfer syntax fail
without producing a result. Catalog replacement, reference policy and audit are
application responsibilities outside DicomCore.

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
| **JPEG-LS Lossless Image Compression** | 1.2.840.10008.1.2.4.80 | JPEG-LS | decoded | Own DicomJPEGLS codec (vendored JLSwift 0.9.1 core, ILV none/line/sample, restart lines) with CharLS fallback; reversible encode with interleave/restart options |
| **JPEG-LS Lossy (Near-Lossless) Image Compression** | 1.2.840.10008.1.2.4.81 | JPEG-LS | decoded | Own DicomJPEGLS codec with CharLS fallback; encode requires an explicit NEAR, verifies the bound after signed normalisation and records lossy metadata |
| **JPEG 2000 Image Compression (Lossless Only)** | 1.2.840.10008.1.2.4.90 | JPEG 2000 | decoded | Own DicomJPEG2000 codec (vendored J2KSwift 11.0.2 CPU core, exact against OpenJPEG on independent inputs, JP2/JPX/JPH unwrapped) with OpenJPEG fallback; explicit reversible encode route. |
| **JPEG 2000 Image Compression** | 1.2.840.10008.1.2.4.91 | JPEG 2000 | decoded | Own DicomJPEG2000 codec (9/7 through the reference inverse, within 2 LSB of OpenJPEG) with OpenJPEG fallback; explicit reversible/irreversible encode route with loss provenance. |
| **JPEG 2000 Part 2 Multi-component Image Compression (Lossless Only)** | 1.2.840.10008.1.2.4.92 | JPEG 2000 Part 2 | experimental | Own DicomJPEG2000 Annex J array-based collection codec (frames as components, one fragment per collection); no independent Part 2 decoder verified the objects |
| **JPEG 2000 Part 2 Multi-component Image Compression** | 1.2.840.10008.1.2.4.93 | JPEG 2000 Part 2 | experimental | Own DicomJPEG2000 Annex J array-based collection codec with explicit reversible or irreversible intent; no independent Part 2 decoder verified the objects |
| **JPEG XL Lossless** | 1.2.840.10008.1.2.4.110 | JPEG XL | experimental | Own DicomJPEGXL Modular lossless codec: Bits Stored 1–16 grayscale (signed or unsigned), RGB8 (colour above 8 bits at codec level only), ICC passthrough; exact against libjxl; disabled by default (#2332) |
| **JPEG XL JPEG Recompression** | 1.2.840.10008.1.2.4.111 | JPEG XL | experimental | Qualified JPEG Baseline (.50/SOF0) and 8-bit Extended Huffman (.51/SOF1) reconstruct byte-for-byte; disabled by default |
| **JPEG XL** | 1.2.840.10008.1.2.4.112 | JPEG XL | experimental | Reversible route on the own Modular codec (as .110); explicit irreversible VarDCT route on the own decoder and encoder; disabled by default |
| **DICOM JPIP Referenced Transfer Syntax** | 1.2.840.10008.1.2.4.94 | JPIP referenced pixel data | streamed-only | Bounded stateless `image/jp2` complete entities |
| **DICOM JPIP Referenced Deflate Transfer Syntax** | 1.2.840.10008.1.2.4.95 | JPIP referenced pixel data with dataset deflate | streamed-only | Dataset inflate plus bounded stateless `image/jp2` complete entities |
| **MPEG-2 Video Transfer Syntaxes** | 1.2.840.10008.1.2.4.100-.101.1 | MPEG-2 video | streamed-only | Encoded stream exposed for player backend; native frame decode is not implemented |
| **MPEG-4 AVC/H.264 Video Transfer Syntaxes** | 1.2.840.10008.1.2.4.102-.106.1 | H.264 video | streamed-only | Encoded stream exposed for player backend; native frame decode is not implemented |
| **HEVC/H.265 Video Transfer Syntaxes** | 1.2.840.10008.1.2.4.107-.108 | HEVC video | streamed-only | Encoded stream exposed for player backend; native frame decode is not implemented |
| **HTJ2K Image Compression (Lossless Only)** | 1.2.840.10008.1.2.4.201 | HTJ2K | delegated | Decode: synchronous uses preflighted OpenJPEG >= 2.5; asynchronous prefers the own DicomJPEG2000 HT decoder with OpenJPEG fallback. Encode: explicit reversible own route. |
| **HTJ2K Image Compression (Lossless RPCL)** | 1.2.840.10008.1.2.4.202 | HTJ2K | delegated | Decode: synchronous uses preflighted OpenJPEG >= 2.5; asynchronous prefers the own DicomJPEG2000 HT decoder with OpenJPEG fallback; PS3.5 10.18.1 options validated. Encode: explicit reversible own route with RPCL, TLM and a <= 64-sample base resolution. |
| **HTJ2K Image Compression** | 1.2.840.10008.1.2.4.203 | HTJ2K | delegated | Decode: synchronous uses preflighted OpenJPEG >= 2.5; asynchronous prefers the own DicomJPEG2000 HT decoder with OpenJPEG fallback. Encode: explicit reversible or irreversible own route; loss follows the intent, not the UID. |
| **DICOM JPIP HTJ2K Referenced Transfer Syntax** | 1.2.840.10008.1.2.4.204 | JPIP referenced HTJ2K pixel data | streamed-only | Bounded stateless `image/jph` or `image/jphc` complete entities |
| **DICOM JPIP HTJ2K Referenced Deflate Transfer Syntax** | 1.2.840.10008.1.2.4.205 | JPIP referenced HTJ2K pixel data with dataset deflate | streamed-only | Dataset inflate plus bounded stateless `image/jph` or `image/jphc` complete entities |
| **RLE Lossless** | 1.2.840.10008.1.2.5 | RLE | decoded | Native `DicomRLELosslessDecoder` (8/16-bit grey, 8-bit RGB/YBR_FULL); own Annex G encoder for the same shapes |
| **Deflated Image Frame Compression** | 1.2.840.10008.1.2.8.1 | Deflate per frame | decoded | Own `DicomDeflatedFrameCodec`: one raw DEFLATE fragment per frame inflated to the exact native frame length; native sources deflate verbatim at any Bits Allocated (#2335) |

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
| **Enhanced CT Image Storage** | 1.2.840.10008.5.1.4.1.1.2.1 | CT with enhanced metadata | ✅ Synthetic single-stack Functional Groups |
| **MR Image Storage** | 1.2.840.10008.5.1.4.1.1.4 | Magnetic Resonance Imaging | ✅ Yes |
| **Enhanced MR Image Storage** | 1.2.840.10008.5.1.4.1.1.4.1 | MR with enhanced metadata | ✅ Synthetic single-stack Functional Groups |
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
| **Color Softcopy Presentation State Storage** | 1.2.840.10008.5.1.4.1.1.11.2 | Color image presentation transforms | ✅ Synthetic Color PR |
| **Pseudo-Color Softcopy Presentation State Storage** | 1.2.840.10008.5.1.4.1.1.11.3 | VOI followed by Palette Color LUT | ✅ Synthetic Pseudo-Color PR |
| **Blending Softcopy Presentation State Storage** | 1.2.840.10008.5.1.4.1.1.11.4 | Underlying/superimposed series with relative opacity | ✅ Synthetic Blending PR |
| **Encapsulated PDF Storage** | 1.2.840.10008.5.1.4.1.1.104.1 | Encapsulated PDF documents | ✅ Synthetic DOC |
| **Encapsulated CDA Storage** | 1.2.840.10008.5.1.4.1.1.104.2 | Encapsulated CDA documents | ✅ Synthetic DOC |
| **Encapsulated STL Storage** | 1.2.840.10008.5.1.4.1.1.104.3 | Encapsulated STL models | ✅ Synthetic DOC |
| **12-lead ECG Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.1.1 | ECG temporal samples | ✅ Synthetic ECG |
| **General ECG Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.1.2 | ECG temporal samples | ✅ Synthetic ECG |
| **Ambulatory ECG Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.1.3 | Ambulatory ECG temporal samples | ✅ Synthetic ECG |
| **General 32-bit ECG Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.1.4 | 32-bit ECG temporal samples | ✅ Synthetic ECG |
| **Hemodynamic Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.2.1 | Hemodynamic temporal samples | ⚠️ Parser model |
| **Cardiac Electrophysiology Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.3.1 | Electrophysiology temporal samples | ⚠️ Parser model |
| **Basic Voice Audio Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.4.1 | Voice audio samples | ✅ Synthetic audio |
| **General Audio Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.4.2 | Mono/stereo audio samples | ✅ Synthetic audio |
| **Arterial Pulse Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.5.1 | Arterial pulse temporal samples | ⚠️ Parser model |
| **Respiratory Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.6.1 | Respiratory temporal samples | ⚠️ Parser model |
| **Multi-channel Respiratory Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.6.2 | Multi-channel respiratory temporal samples | ✅ Synthetic respiratory waveform |
| **Routine Scalp Electroencephalogram Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.7.1 | EEG temporal samples | ✅ Synthetic EEG |
| **Electromyogram Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.7.2 | EMG temporal samples | ✅ Synthetic EMG |
| **Electrooculogram Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.7.3 | EOG temporal samples | ✅ Synthetic EOG |
| **Sleep Electroencephalogram Waveform Storage** | 1.2.840.10008.5.1.4.1.1.9.7.4 | Sleep EEG temporal samples | ✅ Synthetic EEG |
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

``DicomDataSetParser`` applies ``DicomDataSetParseLimits/default`` to the complete
dataset tree. The inclusive default permits a sequence depth of 64, 1,000,000
encoded element headers, and 500,000 sequence items. The root dataset has depth
zero; element and item counts are cumulative across nested sequences. Callers
can supply a custom ``DicomDataSetParseLimits`` value, and structural refusals
produce ``DicomDataSetParseError``. ``DicomStorageSCPConfiguration`` applies the
same default to C-STORE and Storage Commitment datasets unless configured with
another budget.

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
- Compound Graphic Sequence (0070,0209), including standard primitive geometry,
  linked simple fallbacks, tick attributes, and text/line/fill style sequences
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
| **Network Security** | JPIP defaults to HTTPS, exact-origin allowlisting, ephemeral URLSession state, and a configurable redirect policy that rejects redirects by default and otherwise permits only bounded same-origin hops. The DICOMweb client keeps credentials on the configured origin, trusts HTTPS servers through the system evaluation, optionally extended by an added anchor or a server certificate SHA-256, and presents a client certificate for mutual TLS when configured; the optional `DicomWebHTTPListener` can terminate TLS with `DicomTLSConfiguration`. DICOMweb/DIMSE deployment policy remains caller-owned |
| **File Access** | Application sandbox only, respects iOS/macOS file permissions |
| **Data Encryption** | Files are read as-is; encryption/decryption is the caller's responsibility |
| **Authentication** | JPIP obtains a complete Authorization value through an asynchronous origin-scoped provider and never puts it in the query; refresh and authorization policy remain caller-owned. The DICOMweb client sends caller headers and can obtain per-request credentials from a `DicomWebAuthorizationProvider` such as the `DicomWebOIDC` product's; `DicomWebServer` accepts an injected bearer, Basic or JWT authenticator. |
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
| **Adversarial Dataset Structure** | Inclusive limits bound nested sequence depth, total element headers, and total sequence items before further allocation or recursion |
| **Memory Exhaustion** | Memory mapping for large files (>10MB) |
| **Decompression Bombs** | Pixel data size validation against declared dimensions |

---

## 7. Configuration

### 7.1 Build-Time Configuration

DicomCore requires:
- **Minimum iOS Version:** 26.0
- **Minimum visionOS Version:** 26.0
- **Minimum macOS Version:** 26.0
- **Swift Toolchain:** 6.2 or later
- **DICOM-Swift Language Mode:** Swift 6, with complete strict-concurrency checking
- **Xcode Version:** 26.0 or later

The package does not change the Swift language-mode setting of a consuming target.

### 7.2 Runtime Configuration

No runtime configuration files are required. Optional features:

| Feature | Default | Configuration |
|---------|---------|---------------|
| **Memory Mapping Threshold** | 10 MB | Hard-coded, not configurable |
| **Metal GPU Acceleration** | Auto-detect | Configurable per-call via `processingMode` parameter |
| **Tag Caching** | Enabled | Always enabled, not configurable |
| **CharLS runtime path** | Auto-detect | Optional `DICOM_DECODER_CHARLS_LIBRARY_PATH` override |
| **OpenJPEG runtime path** | Auto-detect | Optional `DICOM_DECODER_OPENJPEG_LIBRARY_PATH` override |
| **JLSwift rollout** | `preferred` | `DICOM_JLSWIFT_MODE=disabled`, `shadow`, `preferred`, or `forced-for-tests` |
| **J2KSwift rollout** | `preferred` | `DICOM_J2KSWIFT_MODE=disabled`, `shadow`, `preferred`, or `forced-for-tests` |
| **JXLSwift rollout** | `disabled` | `DICOM_JXLSWIFT_MODE=disabled`, `experimental`, or `forced-for-tests` |

### 7.3 Framework Dependencies

DicomCore uses Apple-provided frameworks for its core pipeline:

- **Foundation:** Core Swift types, file I/O
- **CoreGraphics:** Image representation (CGImage)
- **ImageIO:** Explicit JPEG Baseline decompression backend and 8-bit JPEG 2000 fallback
- **Accelerate (vDSP):** CPU-based image processing
- **Metal:** GPU-based image processing (optional)

Deflated Explicit VR Little Endian uses system zlib. JPEG, JPEG-LS, JPEG 2000
and JPEG XL implementations live in internal DicomJPEG, DicomJPEGLS,
DicomJPEG2000 and DicomJPEGXL targets, with original incorporated-source
attribution in `ThirdPartyNotices.txt`. There is no Raster-Lab package dependency.
Own JPEG/JPEG-LS/JPEG 2000 backends default to `preferred`; JPEG XL remains
explicitly experimental and disabled by default. JPEG-LS .80/.81 covers aligned
8–16-bit grayscale and RGB8, including qualified scan/restart profiles; encoding
requires reversible or explicit NEAR intent. JPEG 2000 .90/.91 and HTJ2K
.201–.203 use the own CPU backend within their qualified profiles, including
explicit reversible/irreversible encoding and typed lossless-only restrictions.

CharLS and OpenJPEG are optional dynamically loaded package adapters when
`DicomCodecRuntimePreflight` reports availability. Their Homebrew, `/usr/local`
and per-runtime override candidates are developer-installed dependencies, not
bundled by DICOM-Swift or required by its qualified own routes. Isis separately
ships the documented GDCM/OpenJPEG binary exception behind its own boundary.
Unavailable or unsupported routes fail with typed diagnostics.
`DicomCodecCapabilities.backendStatuses()` reports availability, source, bit
depths and operations; `resolve` evaluates the actual requested profile.

---

## 8. Known Limitations

### 8.1 Format Limitations

| Limitation | Impact | Workaround |
|------------|--------|------------|
| **Encapsulated multi-frame images** | Frame indexing is supported; full decode depends on codec support for the transfer syntax | Extract frames with `getEncapsulatedFrame(_:)` and decode with a supported codec |
| **JPEG Lossless Non-RGB Color and Separate-Scan Frames** | Native Process 14 decode handles restart intervals and single interleaved scans of 1 or 3 components; non-RGB photometric interpretations, >8-bit color, and separate-scan multicomponent streams are rejected with stable diagnostics | Convert to interleaved 8-bit RGB or grayscale Process 14, or use another validated backend |
| **JPEG-LS Runtime Availability** | Qualified own async routes do not require CharLS; the synchronous legacy encoder and explicit fallback routes do | Use the qualified async route or explicitly provision the required fallback |
| **JLSwift JPEG-LS shapes** | Grayscale below 8 Bits Stored, color above 8 Bits Stored, and non-RGB color are not qualified | Use CharLS through the synchronous path or convert to aligned 8–16-bit grayscale/RGB8 |
| **Experimental JPEG XL shapes** | 24-bit containers, extra channels (alpha), XYB/lossy Modular, YCbCr, upsampled or patched frames and oversized frames are refused typed; Modular lossless covers Bits Stored 1–16 grayscale (either sign), RGB8 (colour above 8 bits at codec level only) and embedded ICC | Use another qualified syntax for those shapes |
| **JPEG 2000 Runtime Availability** | Qualified Part 1/HTJ2K own routes include 8–16-bit samples without OpenJPEG; general Part 2 or other fallback-only profiles can require it | Query the descriptor-specific capability decision before execution |
| **HTJ2K Pixel Decode** | Own .201–.203 CPU routes are qualified by #2330 for the declared sample/codestream profiles; unsupported shapes are not promoted | Consult HTJ2KCodec.md and the profile-specific capability result |
| **JPEG Hierarchical** | Hierarchical JPEG processes remain unsupported | Convert to a qualified transfer syntax |
| **Unsupported color combinations** | `DicomColorConversionError.unsupportedColorPath` reports photometric interpretation, sample count, planar layout, bit depth, and transfer syntax context | Convert through a supported transfer syntax/color layout |
| **Undefined-length non-SQ** | Non-SQ undefined values inside sequences throw parser errors | Use explicit lengths |
| **Incomplete PET SUV metadata** | SUV helpers return no physical value and report missing DICOM tags; GML passthrough to SUVbw also rejects an explicit non-BW SUV Type | Preserve Units, SUV Type, Patient Weight/Size/Sex, radiopharmaceutical dose, decay, and timing metadata |
| **Large Files** | Files >1GB may consume significant memory | Use memory-efficient workflows, process in chunks |

### 8.2 Functional Limitations

| Limitation | Impact |
|------------|--------|
| **No production DICOMweb/PACS stack** | DICOMweb helpers cover the tested matrix only; persistent storage, authorization and PHI audit policy, JPIP proxying, and archive operations are caller-owned or unsupported |
| **Limited Writing Scope** | General dataset writing is limited to native/Deflated datasets, JPIP metadata references, DICOMDIR media records, and caller-provided encapsulated payload passthrough; pixel recompression is not implemented |
| **Limited Structured Report Semantics** | Semantic validation is scoped to Enhanced/Comprehensive SR TID 1500 and KOS references; other SR SOP classes/templates parse syntactically and return stable validation errors for semantic use |
| **Limited Secondary Capture Pixel Inputs** | SC writing supports native unsigned monochrome and interleaved RGB pixel payloads, including CGImage snapshots converted to RGB8 |
| **Limited Encapsulated Document Scope** | Document object writing is limited to Encapsulated PDF, CDA, and STL Part 10 datasets; embedded document contents are preserved but not rendered or semantically parsed |
| **Limited Waveform Sample Scope** | Waveform writing/parsing covers linear 8/16/32-bit integer sample interpretations and exposes temporal samples without converting them to image volumes |
| **Limited Video Scope** | Video writing/parsing encapsulates and exposes caller-provided MPEG-2/H.264/H.265 streams with metadata; native video decoding is delegated to the application/player backend |
| **Limited Presentation State Scope** | The four Softcopy Presentation State IODs (Grayscale, Color, Pseudo-Color, Blending) are parsed/built for object exchange, including Modality LUT/rescale, tabular Presentation LUT, plain/segmented palettes, ICC and blending items; `DicomDisplayTransformProfile` evaluates the scalar display transform (PS3.3 LINEAR window, truncating quantization), while composition of graphics, shutters and blending remains caller-owned |

### 8.3 Backlog Alignment

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
- SwiftUI preview mocks and sample data are documented as preview-only support
  API and are not clinical/runtime decoder surfaces.
- Isis-level decoder parity documentation was closed separately in issue #1064;
  package documentation reconciliation is covered by issue #1077.
- MTK rendering and viewer workflow limitations are outside DICOM-Swift
  package conformance and are tracked by the open MTK issues #1078 through
  #1090.

### 8.4 Performance Considerations

| Scenario | Expected Performance | Recommendation |
|----------|---------------------|----------------|
| **File Opening** | <50ms for typical files | Use async APIs for UI responsiveness |
| **Pixel Loading** | 100-500ms for compressed data | Load pixels in background task |
| **Series Loading** | 2-5s for 100-slice CT series | Use progress callbacks, enable concurrency |
| **Window/Level (CPU)** | ~2ms per 512×512 image | Acceptable for interactive UI |
| **Window/Level (GPU)** | ~2.2ms per 1024×1024 image | Use for high-res or batch processing |

---

## 9. Version History

### Version 2.0.1 (Current)

**Release Date:** 2026-10-04

**Key Features:**
- DICOMweb client: the URLSession transport sends every request to the server and stores no response in the URL cache
- Interop smoke recorded against dcm4chee 5.35.2 and Orthanc 1.13.0

**Conformance Changes:**
- None beyond the client's URL cache use; DICOMweb behaviour is otherwise that of 2.0.0

### Version 2.0.0

**Release Date:** 2026-10-04

**Key Features:**
- Swift 6 language mode; Swift tools 6.2 and iOS, visionOS or macOS 26.0+ unchanged
- Separate library products, including the independent `DicomWebClient` and `DicomWebOIDC`
- DICOMweb client: file-backed and streamed STOW-RS, ordered transfer syntax fallback, opt-in retries, QIDO paging, rendered and thumbnail options, per-request authorization, server trust and client certificates
- DICOMweb server: provider-backed QIDO paging, 405 and 204 answers, dictionary keyword matching and public base URLs

**Conformance Changes:**
- DICOMweb client and server behaviour as described in section 1.3
- Transfer syntax and SOP class support as listed in sections 2 and 3

### Version 1.2.0

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
- Library version (e.g., 2.0.1)
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

`DicomPart10Rewriter` is the generic metadata-rewrite primitive. It accepts
typed top-level element replacements and recursive exact UI-value mappings,
rejects file-meta, group-length, Pixel Data, SOP Class, and pixel-structure
edits, and never falls back when the source transfer syntax is missing or
unknown. Before returning, it reopens the output and verifies the transfer
syntax, UID values by dataset path and multiplicity, SOP Class, exact edited
VR/value pairs, and the complete Pixel Data value. Native values include their
declared bytes; encapsulated values include the Basic Offset Table, item
headers, fragments, and sequence delimiter. Deflated files preserve the
inflated Pixel Data value, not the zlib bitstream or whole-file bytes.

`DicomAnonymizer` (issue #1236) rewrites Part 10 files under a
`DicomRewritePolicy` of per-tag keep/remove/replace/remapUID actions plus
private-tag and Overlay Plane switches. Rules apply recursively inside sequence items. The
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

The `defaultAnonymization` policy is an Isis PS3.15 Basic Confidentiality
baseline, not a claim of complete Basic Application Level Confidentiality
Profile conformance. It replaces or removes patient, personnel, institution,
device, procedure, common descriptor, and SR text fields; removes private
attributes and every element in repeating Overlay Plane groups 6000-601E;
removes unoverridden DA, DT, and TM values recursively; and remaps
the UID attributes assigned the Basic Profile `U` action in PS3.15 2026c Table
E.1-1. Exact replacements can seed top-level Study, Series, and SOP Instance
UIDs while every nested reference uses the same map. Output records Patient
Identity Removed (0012,0062), De-identification Method (0012,0063), and
Longitudinal Temporal Information Modified (0028,0303).

Pixel Data remains byte-for-byte unchanged, including retired overlay bits
embedded in native Pixel Data; removing the corresponding 60xx group makes
those bits undiscoverable as a DICOM Overlay Plane but is not pixel cleaning.
The result warns when Burned In
Annotation (0028,0301) is `YES`, missing, or unrecognized; only `NO` clears the
warning. Clean Pixel Data, Clean Recognizable Visual Features, Clean Graphics,
Clean Structured Content, Clean Descriptors, retention options, and cleaning
of encapsulated documents are not implemented. SR text redaction is
conservative and is not a claim of the Clean Structured Content Option.

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
  the own DicomJPEGLS codec writes lossless .80 for reversible intent (or
  ``DicomEncodingIntent/jpegLS(options:)`` with interleave and restart lines) and
  near-lossless .81 only for an explicit NEAR value, verified after signed
  normalisation. Aligned 8–16-bit grayscale and RGB8 encode per frame through
  the shared encapsulation path. The synchronous compatibility route remains
  CharLS lossless.
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
  history. JPEG 2000 Part 2 .92/.93 use the experimental own Annex J collection
  codec for qualified decode/encode shapes; ambiguous color/bit layouts stay
  typed unsupported.
- **JPEG XL encoding** is experimental and disabled by default. With
  `DICOM_JXLSWIFT_MODE=experimental`, async overloads write reversible .110,
  reversible or explicit irreversible .112, and reversible JPEG Baseline / 8-bit Extended Huffman
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
| 1.2.840.10008.1.2.4.92 | JPEG 2000 Part 2 Multi-component Image Compression (Lossless Only) | experimental own Annex J collection codec |
| 1.2.840.10008.1.2.4.93 | JPEG 2000 Part 2 Multi-component Image Compression | experimental own Annex J collection codec |
| 1.2.840.10008.1.2.4.110 | JPEG XL Lossless | experimental own Modular lossless decode/encode (libjxl-exact); disabled by default |
| 1.2.840.10008.1.2.4.111 | JPEG XL JPEG Recompression | experimental byte-identical JPEG Baseline (.50/SOF0) and 8-bit Extended Huffman (.51/SOF1) bridge; disabled by default |
| 1.2.840.10008.1.2.4.112 | JPEG XL | experimental reversible (own Modular) / irreversible (VarDCT) decode/encode; disabled by default |
| 1.2.840.10008.1.2.4.94 | JPIP Referenced Transfer Syntax | streamed-only |
| 1.2.840.10008.1.2.4.95 | JPIP Referenced Deflate Transfer Syntax | streamed-only |
| 1.2.840.10008.1.2.4.100-.108 | MPEG-2/H.264/HEVC video families | streamed-only |
| 1.2.840.10008.1.2.4.201 | HTJ2K Image Compression (Lossless Only) | OpenJPEG decode; reversible CPU encode/transcode |
| 1.2.840.10008.1.2.4.202 | HTJ2K Image Compression (Lossless RPCL) | OpenJPEG decode; reversible CPU RPCL encode/transcode |
| 1.2.840.10008.1.2.4.203 | HTJ2K Image Compression | OpenJPEG decode; reversible or irreversible CPU encode/transcode |
| 1.2.840.10008.1.2.4.204 | JPIP HTJ2K Referenced Transfer Syntax | streamed-only stateless complete-entity profile |
| 1.2.840.10008.1.2.4.205 | JPIP HTJ2K Referenced Deflate Transfer Syntax | streamed-only stateless complete-entity profile |
| 1.2.840.10008.1.2.5 | RLE Lossless | decoded native; own encoder |
| 1.2.840.10008.1.2.8.1 | Deflated Image Frame Compression | decoded and encoded natively (own frame deflate) |

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

## DIMSE Unified Procedure Step — Lot A1 (PS3.4 2026c CC.4)

`DicomUnifiedProcedureStepService` supplies transport-neutral state management with
an injected atomic store. `DicomDIMSEServer` accepts Push, Pull, Watch, Event and
Query contexts when that service is installed. Push supports N-CREATE, N-GET and
Request Cancel; Pull supports C-FIND, N-GET, N-SET and Change State; Watch supports
C-FIND, N-GET, Request Cancel and subscription actions; Query supports C-FIND.
The Event context delivers N-EVENT-REPORT on a new association. Incoming Event
reports require a service event receiver. DIMSE-N command SOP Class UIDs and stored
instances use Push; C-FIND commands use the negotiated Pull/Watch/Query UID.
The transport-neutral engine also backs the UPS-RS Worklist Service described below.

Creation accepts SCHEDULED, rejects duplicate instance UIDs, keeps the Transaction
UID empty, sets Modification DateTime, and supplies the configured default Worklist
Label when empty. No automatic subscription is made for the creating AE. Existing
global and filtered global subscriptions apply to newly created instances.
The engine enforces the explicit N-CREATE/N-SET table rows; embedded macro content
is supplied by the caller according to the UPS IOD. N-SET replaces whole sequences,
rejects prohibited attributes, and updates Modification DateTime. State changes
use N-ACTION, never N-SET. Transaction UID is the sole ownership token: the first
claim wins independently of calling AE or IP. N-GET and C-FIND never reveal it.
Final-state writes are refused. No post-final reconciliation/coercion is performed.

COMPLETED requires the Final State R/P/RC values and CANCELED requires R/X/RC.
The table's explicit exception permits an existing Output Information Sequence
with zero items. Cancellation DateTime is filled by the SCP when missing. Host
knowledge for RC “if known” attributes is represented by `knownFinalStateTags`;
non-ASCII text requires Specific Character Set. A scheduled cancellation request
records IN PROGRESS then CANCELED events, supplies a discontinuation reason if
needed, and commits the canceled record before delivering either event. An
in-progress cancel request reports the requesting calling AE to subscribers;
performer policy can accept, refuse (C313), or report unreachable performer (C312).

Subscriptions are per Receiving AE, with optional deletion locks. Specific
instructions override global subscriptions. Global unsubscribe removes all that
AE's locks and subscriptions; suspend stops future global subscriptions while
preserving existing instance subscriptions. Filtered subscriptions use the same
`DicomQueryMatcher` as worklist search. Unknown receiving destinations return C308;
no event sink returns C315. Host policy may refuse a deletion lock with B301 while
accepting the subscription. The toolkit does not autonomously remove locks.
Final-state instances remain retrievable while locked; the default memory store
retains them indefinitely. `purgeEligible` is true only for an unlocked final-state
record; persistent hosts define retention beyond that minimum.

Events 1–5 describe state/readiness, cancel request, progress, SCP lifecycle and
assignment. The Event table's assigned human fields are extracted from Scheduled
Human Performers. After global-with-lock subscribe the SCP sends a current-state
report for every existing matching UPS, following CC.2.4.3 even for an already
subscribed instance; subscription state itself follows CC.2.3. Start reports use
host fallback AEs plus stored subscribers, with WARM/COLD START list flags.
Snapshot/restore preserves both lists and ownership tokens. Every delivery attempt
is observed; returning successfully requires the peer's 0000 response. Failed
reports are not retried and do not undo committed state, subscriptions or locks.

C-FIND ignores priority and supports the table's matching and return keys, using
worklist search rather than query/retrieve hierarchy. Requests without Matching
Keys produce no matches; responses contain requested keys and character encoding
metadata. Optional unsupported return keys produce FF01; supported keys produce
FF00. C-CANCEL terminates with FE00. Fuzzy matching is unsupported. The existing
`DicomQueryMatcher` compares PN literally and case-sensitively; it has no
case-insensitive PN option. Matching uses decoded string values and DT offsets
encoded in the values; separate Timezone Offset From UTC matching context is not
implemented by that matcher. Those limitations are not changed by Lot A1.

The SCU invokes creation, search (Pull/Watch/Query), get/set, state changes,
cancellation and subscriptions explicitly at the caller's request. It does not
autonomously choose state transitions or retrieve input/output objects. Optional
matching and return keys and character encoding are supplied by the caller in the
identifier. It returns response statuses, warnings, datasets and pending statuses.

## Instance Availability Notification (PS3.4 2026c R.3.4)

IAN SCU sends N-CREATE; the SCP validates then delegates to an injected receiver.
The builder exposes only the R.3.2.1.1 attributes: Specific Character Set,
Referenced Performed Procedure Step Sequence (SOP Class/Instance and Performed
Workitem Code Sequence), Study Instance UID, and Referenced Series Sequence with
Series Instance UID and Referenced SOP Sequence. Each referenced instance contains
SOP Class/Instance UID, Instance Availability and Retrieve AE Title, with optional
Retrieve Location UID, Retrieve URI, Retrieve URL and Storage Media File-Set ID/UID.
The validator rejects additional attributes, including patient context, at each
supported sequence level. The workitem-code builder supports Code Value, Coding
Scheme Designator and Code Meaning (validator also accepts Coding Scheme Version).

ONLINE, NEARLINE, OFFLINE and UNAVAILABLE are per-instance values. The toolkit
makes no assertion of study completeness, durability or retrievability. The host
product must document the meaning, latency, notification trigger/frequency and
retrieval capabilities for each value, and how received notifications affect its
workflow. Referenced procedure steps identify the related performed work, but
neither the SCU nor the SCP implicitly creates or updates MPPS or UPS instances.


## UPS-RS Worklist Service and notifications (PS3.18 2026c)

`DicomWebServer` is an origin server when initialized with `unifiedProcedureSteps`.
`DicomWebClient` is a user agent. The supplied service owns the A1 state machine,
store, cancellation policy, deletion locks, subscriptions and event observer.
`/ups` is not a resource (404). All paths below are relative to `servicePath` and
use the same configured authentication as the other DICOMweb routes.

| Transaction | Method and resource | Success | Failure statuses |
| --- | --- | --- | --- |
| Create | POST /workitems?workitem={uid} | 201, Location | 400 invalid attributes, 409 duplicate, 415 media type |
| Retrieve | GET /workitems/{uid} | 200, Content-Location | 404 unknown, 406 negotiation, 410 deleted |
| Update | POST /workitems/{uid}?transaction-uid={uid} | 200 | 400 final state, transaction UID or attributes; 404, 409 inconsistent state, 410 |
| Change State | PUT /workitems/{uid}/state | 200 | 400 invalid or incorrect/missing transaction UID; 404, 409 inconsistent state/final requirements, 410 |
| Request Cancellation | POST /workitems/{uid}/cancelrequest | 202 | 400 syntax, 404, 409 C311/C312/C313 |
| Search | GET /workitems | 200, including an empty JSON array | 400 parameters, 406 negotiation, 413 configured result limit |
| Subscribe | POST /workitems/{uid}/subscribers/{ae} | 201, WebSocket Content-Location | 400 syntax, 403 policy, 404 unknown |
| Unsubscribe | DELETE /workitems/{uid}/subscribers/{ae} | 200 | 400 syntax, 404 no subscription |
| Suspend | POST /workitems/{globalUID}/subscribers/{ae}/suspend | 200 | 400 syntax, 404 no subscription |
| Open Notification Connection | GET /subscribers/{requester}, Upgrade: websocket | 101 | 400 handshake |

The worklist UID is `1.2.840.10008.5.1.4.34.5`; the filtered worklist UID appends
`.1`. Filtered subscriptions require comma-separated `filter=attribute=value`
matching keys. Suspension stops subscriptions to future workitems and retains
existing per-workitem subscriptions. Subscription authorization is injected through
`authorizeWorklistSubscription`; filtered subscription support can be disabled;
A1 `grantDeletionLock` controls whether requested locks are granted.

Create, Retrieve, Update and action payloads use `application/dicom+json` or a
single `application/dicom+xml` part in `multipart/related`. BulkDataURI references
are not accepted. Create rejects an SOP Instance UID in the payload; if `workitem`
is absent, `DicomDataSetWriter.makeUID()` supplies it. This follows 11.4.1.4 and
resolves the contradictory wording in 11.4.1.1 in favor of UID generation. The
HTTP adapter additionally checks explicit N-CREATE Type 2 presence, while A1
performs attribute and state validation. Optional top-level Update attributes
outside the transcribed UPS table are ignored with an explicit Warning.

Search uses `DicomQueryMatcher`, numeric tags and transcribed UPS keywords,
Type 1/2 return keys, `includefield`, matching keys, `offset` and `limit`. Matching
is literal. Results exceeding `maximumSearchResults` return 413; the user agent
can supply paging or narrow the query. Retrieve and Search never expose the
Transaction UID. Stores that implement `DicomUnifiedProcedureStepDeletionReporting`
can distinguish 410 from 404; the A1 in-memory store has no tombstone support.

Warning values use the exact `299 <service>: <message>` strings from chapter 11:
created/updated with modifications, unsupported optional attributes, missing or
incorrect Transaction UID, inconsistent state, already CANCELED/COMPLETED,
ungranted deletion lock, unsupported filtered subscriptions, literal fuzzy matching,
and a target URI that does not reference a claimed workitem. B304 and B306 retain
the transaction's success HTTP status. Change State follows the explicit payload
requirements of 11.7.1.4 despite the overview table's "none" entry, and returns no
success payload as required by 11.7.3.3.

`DicomWebNotificationHub` and `DicomWebNotificationEventSink` adapt A1 events to
connected HTTP subscribers. The server installs this sink only when A1 has no
sink; applications already supplying a DIMSE sink must supply a transport-routing
sink that dispatches HTTP subscribers through `DicomWebNotificationEventSink`.
The same hub must be passed to the server and event sink. Multiple connections
per AE receive the same reports. No disconnected events are retained or retried.
The A1 observer records success, `noConnection`, or `writeFailure` through its
existing outcome and error-description fields. A successful write is transport
acceptance, not an application acknowledgment or exactly-once delivery guarantee.

The notification URL is `ws(s)://authority/<service>/subscribers/{requester}`.
The HTTP listener requires WebSocket version 13 and a 16-byte base64 key; it
computes Sec-WebSocket-Accept with SHA-1 and the RFC 6455 GUID. Origin and the
DICOM JSON Content-Type are required. When a subprotocol is offered, `dicom` is
selected; unsupported offers are rejected. Without an offered protocol no protocol
header is sent, following RFC 6455's prohibition on selecting an unoffered protocol
(the PS3.18 response table marks this header mandatory while making the request
header optional). Upgrade responses contain no HTTP chunk framing. Masked incoming
frames are unmasked, ping is answered with pong, close is acknowledged, protocol
errors close with 1002, oversized frames/messages with 1009, and listener shutdown
sends 1001 and waits for connection tasks. The default frame/message bound is 1 MiB.

Each server text frame contains one DICOM JSON object: Affected SOP Class UID
`00000002 = 1.2.840.10008.5.1.4.34.6.4`, Message ID `00000110`, Affected SOP Instance
UID `00001000`, Event Type ID `00001002`, followed by A1 event attributes. Reports
cover state, cancellation request, progress, SCP status and assignment. The
`requester` parameter is included in HTTP-generated state reports via Requesting AE;
for cancellation without a requester the implementation uses `DICOMWEB`.

`DicomWebNotificationClient` uses `URLSessionWebSocketTask`, accepts a connection
factory for tests, and emits connected/event/gap signals. Reconnects use bounded
exponential backoff; every reconnect emits a gap and the consumer must retrieve
current state and re-subscribe when an initial report is needed. It pings idle
connections with a timeout and cancels the connection when its stream is canceled.
The default budget is five reconnects, 0.5–30 second backoff, a 20 second ping
interval and a 10 second ping timeout.

The independent `ups_rs_probe.py` witness uses `requests` and `websockets==17.1`.
Its Swift harness asserts all transaction results, event sequence and disconnected
observer outcomes; the in-process tests exercise status/Warning mappings, media
negotiation, subscription policies, deletion knowledge and client reconnect gaps.
The dicomweb-client 0.61.2 witness (`DicomWebIndependentClientTests`) stores,
searches and retrieves through the same listener. Both witnesses passed without
skip on 2026-10-04 with pydicom 3.0.2, pynetdicom 3.0.4 and websockets 17.1.

## Optional Print SCP and shared CPU film compositor (Lot A2)

`DicomDIMSEServer(configuration:print:printProvider:)` enables printing only when
an explicit `DicomPrintSCPConfiguration` is supplied. `DicomPrintSCPProviding`
injects the output, text rasterizer, optional printer-status stream and job-created
callback. No application target is required to enable this service. Capabilities
use the existing `DicomPrintPeerCapabilities` model. Grayscale and Color Print
Management Meta contexts accept component Film Session, Film Box, Image Box and
Printer SOP Class UIDs. Individual classes and optional Annotation Box,
Presentation LUT, Print Job and Printer Configuration Retrieval are negotiated
only when configured.

Each association owns one Film Session, ordered Film Boxes, generated image and
annotation instance UIDs, and LUTs. N-SET targets the last Film Box or its boxes.
Image UIDs have fixed, one-based slot positions in the returned sequence. Only
the last Film Box can be explicitly deleted; session deletion cascades. LUT
deletion fails while working films or outstanding jobs reference it. A job keeps
an immutable hierarchy/LUT snapshot and its original priority through terminal
confirmation, including when its working Film Box or Session is deleted.

Image ingress accepts unsigned MONOCHROME1/2 with 8-bit or 12-bit stored values,
and RGB8 with planar configuration 1. Empty image sequences erase pixels.
An incremental PDV admission scanner reads Rows, Columns, Samples per Pixel and
Bits Allocated before forwarding Pixel Data to the message accumulator. It
supports fragmented explicit/implicit little-endian headers, caps header metadata,
and drains rejected messages without retaining their pixels. Per-image, film and
session raw-byte budgets return 0213; a separate resident raster budget returns
C605. The output raster budget is checked before CPU allocation. Queue admission
is shared across associations and returns C601/C602 when full.

N-ACTION snapshots and composes the selected hierarchy, returns the Print Job
reference at (2100,0500) when negotiated, and prints collated copies. Job events
are Pending (1), Printing (2), Done (3) or Failure (4), exclusively on the creating
association. Done follows output-provider success. Terminal instances are removed
after the event response confirms success. `DicomPrintJobControl.cancel()` causes
Failure with the implementation-specific Execution Status Info `CANCELLED`;
`completedFilmIndices` records partial output. Release/abort cancels by default;
`keepJobsOnRelease` retains output work without sending events to a closed peer.
Printer Warning/Failure streams fan out to associations using the printer. N-GET
serves configured attributes and status; configuration retrieval reports installed
media, layouts, box dimensions, printer spacing, resolutions, defaults and limits.

`DicomFilmCompositor.compose(_:)` consumes `DicomFilmDescription` and returns
`DicomComposedFilm` (8-bit grayscale or RGB, geometry, raw-raster SHA-256 and fit
information). STANDARD is row-major; ROW partitions rows and COL partitions
columns, with integer boundaries covering the complete sheet without overlap.
SLIDE, SUPERSLIDE and CUSTOM require a configured STANDARD grid. The physical
size table covers 8INX10IN, 8_5INX11IN, 10INX12IN, 10INX14IN, 11INX14IN,
11INX17IN, 14INX14IN, 14INX17IN, 24CMX24CM, 24CMX30CM, A4 and A3.

REPLICATE, BILINEAR and CUBIC select nearest, bilinear and bicubic interpolation;
NONE preserves source scale. Images preserve physical aspect ratio using image
and printer spacing. Requested Image Size sets physical width; otherwise images
fit their slots. Oversized images demagnify by default (B604), crop for CROP
(B609), or decimate for DECIMATE (B60A). FAIL and NONE with DECIMATE refuse
oversized images (C603). Smoothing is recorded without changing samples. Numeric
optical densities are bounded to the configured rendering range; LIN OD uses
PS3.14's inverse GSDF/JND mapping, illumination and reflected ambient light.
IDENTITY and validated 256/4096-entry, 10–16-bit LUT tables produce P-values;
native 12-bit grayscale indices are preserved. Polarity, border/empty density,
trim, image density ranges and annotation bands participate in composition.

Identification is explicitly enabled in the description/SCP configuration. A
single-study film uses a film label only when Study Instance UID and label agree
for every image. Mixed studies and same-name/different-UID inputs use per-image
labels. Missing identification or failed/blank text rasterization throws. The
shipped `DicomCoreTextPrintRasterizer` implements `DicomPrintTextRasterizing`;
there is no silent empty-band fallback. Output paths and CLI film records contain
job UIDs, indices and hashes, never patient identity.

`DicomPrintPreview.compose(job:)` uses the same compositor and A1 wire models.
Automatic mode needs a resolved mode for pre-association preview. Peer-dependent
Requested Image Size/Decimate behavior requires the same printer configuration;
annotation geometry, output width and identification settings must also match.
`DicomFilm.init(snapshotPNGData:layout:)` adds snapshot ingestion without changing
the existing `DicomPrintJob` snapshot initializer. File output writes atomic PNGs
and can publish an atomic multi-page PDF after its final page. Raster output is
bounded by count and bytes. Physical printer integrations implement
`DicomPrintOutputProviding`; provider success must mean output confirmation.

### A2 status evidence and qualification limits

Hermetic tests in `DicomDIMSEServerPrintTests` map the following behavior:

| Status | Test (name after `test_`) |
| --- | --- |
| B600, 0120, 0106, 0110, 0118, 0112 | `sessionStatuses_missingInvalidDuplicateMemoryAndUnsupportedClass` |
| B601, B602, B603, C600, C616 | `emptyHierarchyAndCollationStatuses` |
| B604, B609, B60A, C603, 0107 | `imageFitStatuses_andLastFilmRestriction` |
| B604, B609, B60A at Session/Film N-ACTION | `actionFitWarnings_sessionAndFilmB604B609B60A` |
| B605 Film Box/Image Box | `densityClamping_filmAndImageB605` |
| C601, C602 | `fullQueue_sessionC601_andFilmC602` |
| C605, 0213 | `imageAndFilmResourceLimits_returnTypedStatuses`, `declaredPixelSize_andResidentLimit_stopBeforePixels`, `rejectedPDV_doesNotReachMessageAccumulator` |
| 0110 referenced LUT, 0211, 0112 | `lutValidationAndReferencedDeletion_andUnsupportedOperation` |
| Output confirmation and retained hierarchy | `outputConfirmation_blocksDone_andDeletionRetainsJobSnapshot` |
| Release cancellation, partial output and keep-jobs policy | `releaseMidJob_cancelsWithPartialResult_unlessKeepJobsConfigured` |
| Printer notification fanout | `printerWarning_isBroadcastToEveryUsingAssociation` |
| C613 response injection only | `injectedCombinedPrintFailure_sessionFilmAndImageC613` |
| B605 LUT response injection only | `injectedLUTB605_stillCreatesInstance` |

The last two rows are deliberately not semantic conformance claims. C613 concerns
a Combined Print Image mechanism whose overlay modules are retired and whose
SOP classes are not enabled here. The supplied LUT N-CREATE attribute table
contains shape/table, but its B605 status row refers to density attributes carried
by Film/Image Box. Natural LUT-CREATE B605 and Combined Print Image composition
remain qualification questions; fault injection does not resolve them.

`DicomPrintLoopbackTests` compares every received sheet byte and SHA-256 against
A1 preview for grayscale/color, STANDARD/ROW/COL, mixed studies and same-name,
different-UID cases. `DicomPrintSCPPynetdicomTests` uses an independent SCU for
layouts, color, annotation, LUT, configuration, job events, deletes, refused
operations, insufficient boxes, unknown attributes and cancellation/provider
failure. The independent tests require the configured Python environment.

## JPIP origin server (T.808, Lot A2)

`DicomJPIPServer` accepts transport-neutral `DicomWebHTTPRequest` values and returns
pull-driven `DicomWebHTTPStreamedResponse` bodies. Enable the optional `/jpip` GET
route with `DicomWebServer(jpip:)`; its existing authentication runs before JPIP
routing. Alternatively, pass `server.handle` through `DicomWebHTTPListener(handler:)`.
Standalone deployments can inject the same `DicomWebAuthenticating` policy.

`DicomJPIPTargetProviding` supplies one or more codestreams under a caller-supplied
byte budget. `DicomJPIPDirectoryTargetProvider` accepts J2K/JPHC, JP2/JPH containers,
and Part 10 encapsulated JPEG 2000 frames using the existing frame parser. Paths
must resolve beneath the configured directory. Target identifiers hash the ordered,
length-delimited codestreams; DICOM identity fields are neither identifiers nor CLI
output. `stream` is one-based in requests and zero-based in databin messages.

`DicomJPIPCodestreamIndexer` uses PLT when present. Without PLT,
`DicomJ2KPacketHeaderReader` measures inline Tier-2 headers using persistent inclusion
and zero-bitplane tag-trees, coding-pass counts, Lblock and segment lengths, including
SOP/EPH. LRCP, RLCP, RPCL, PCRL and CPRL map to the same precinct identities with their
respective packet ordering. The index retains source byte ranges and cumulative
per-layer ends; no pixel decode is part of indexing. COC and POC are parsed for index
geometry/order. Packed PPM/PPT headers and coding-order changes in later tile-parts
are rejected. CAP-marked HTJ2K requires PLT for JPP; without it the origin offers JPT
only, preserving opaque tile-parts. Index construction bounds target bytes, packets,
precincts and code-block allocations.

For JPP, the origin sends the main header, tile headers and precinct packet prefixes
in resolution/layer order. It consolidates tile headers and supplies a PLT from the
measured index when the source lacks one. This keeps class-0 precinct messages
usable by the OpenJPIP transcoders; the shared message writer also supports extended
classes and Aux. ROI selection includes wavelet support around the requested region.
`JPIP-fsiz`, `JPIP-rsiz`, `JPIP-roff`, `JPIP-layers`, `JPIP-comps` and `JPIP-stream`
acknowledge served windows. JPT sends whole selected tile-parts and acknowledges their
full encoded resolution, components and layers rather than claiming packet-level
quality truncation.

Cache negotiation accepts explicit/implicit `model`, `need`, and tile-part `tpmodel`
descriptors. Channel state retains byte extents, not pixel data. `cnew=http` allocates
a random 16-hex channel; `cid` continues it, `cclose` releases it, and idle expiry is
configurable. A newer request invalidates the preceding response generation on the
same channel. The consumer pulls one bounded message at a time, with no unbounded
producer queue. Target-cache invalidation is explicit via `invalidateTargets()`;
directory hosts replacing files should invalidate after the replacement.

| EOR | Meaning | Enforcement |
| --- | --- | --- |
| 1 | Image done | Full selected image data is available in the negotiated cache model |
| 2 | Window done | Selected region/resolution/layers or metadata set is served |
| 3 | Window superseded | Channel generation changed or expired before the next pull |
| 4 | Byte limit | Request `len` exhausted, reserving three bytes for EOR |
| 6 | Session limit | Per-channel byte budget exhausted |
| 7 | Response limit | Configured response budget exhausted |

Malformed requests return 400, unsupported media types 415, missing targets 404,
resource limits 413, and malformed/unsupported codestreams 422. Error responses
contain no `JPIP-*` headers. `len` below three bytes is rejected because it cannot
hold EOR. Unknown optional fields are ignored; required unknown fields are rejected.
`wait` and `srate` are scheduling hints only. Metadata selection returns an empty set;
raw media delivery and subtarget extraction are unsupported.

`dicomtool jpip serve --dir DIR --port N [--max-response-bytes N] [--bearer TOKEN]`
starts a loopback listener. `jpip fetch URL --window fsiz=W,H,roff=X,Y,rsiz=W,H,layers=N
--out FILE.j2k [--session] [--type jpp|jpt] [--dump-messages]` uses the A1 transport
and reconstruction. `jpip index FILE` prints an identity-free JSON index summary;
`jpip inspect STREAM.jpp` prints message coordinates, lengths, completion and EOR.

Independent tests require `DICOM_JPIP_OPENJPIP_BIN`, the adjacent OpenJPEG 2.5.4
binaries and `DICOM_SWIFT_PYNETDICOM_PYTHON` with `requests`. Full windows and JPT
must transcode and decode independently. The documented OpenJPIP 1.5.2/2.5.4
layer-prefix divergence ("segment too long") uses scoped expected failures only
around the transcoder result. Layer-N and ROI goldens instead compare A1
reconstruction decoded by both the toolkit runtime and `opj_decompress` against
`opj_decompress -l N` of the source, with crop comparisons for ROI. Those pixel
assertions are never expected failures. A1 expected-failure sites remain unchanged.
A1 reconstruction still rejects COC/POC and tile coding overrides; indexing those
markers does not qualify those layouts for A1 pixel reconstruction.

## Archive representations (Lot A)

`DicomRepresentationSet` models exactly one received/imported original, lossless
alternate encodings of that same SOP Instance, and explicitly authorized lossy
derivatives with distinct SOP Instance UIDs. Original means archive lineage; it
is not a claim that Image Type is ORIGINAL or that the received image has never
undergone lossy compression. The fingerprint is SHA-256 of complete Part 10
bytes. Receiving a DIMSE dataset does not preserve a sender's Part 10 file header.

The set validates source fingerprints, SOP identity, lossless-equivalent geometry
and inherited loss history. Different Part 10 hashes under one SOP Instance UID
are separate representations. Conflict classification is conservative by default;
`equivalentEncoding` requires a caller-supplied verified comparison of decoded
pixels AND non-encoding attributes, with lossless source histories. Conflict
resolution returns bytes and a retention instruction, without mutating a store.
Replacing requires a nonempty authorization. Keeping conflicting content under a
new identity preserves prior attributes in Original Attributes Sequence and adds
source-image and derivation records; this is not a new lossy compression step.
It never silently overwrites the original.

Selection never returns a transfer syntax outside peer acceptance. Its order is:
stored original, stored lossless equivalent, authorized stored lossy derivative,
then generation (lossless before lossy). Within each group, estimated bytes and
generation working-set cost precede the fixed syntax rank and content hash.
Peer preference-list ordering does not override this archive policy; permutations
of equally eligible syntax lists give identical decisions. A peer can explicitly
reject all lossy-history objects, including already-lossy originals. Merely
accepting a lossy transfer syntax does not authorize substituting a derivative.
`.lossyDerivedAllowed` requires a nonempty authorization value.

The fixed syntax rank is Explicit LE, Implicit LE, Explicit BE, dataset deflate,
JPEG 2000 Lossless, HTJ2K Lossless, HTJ2K Lossless RPCL, JPEG-LS Lossless,
JPEG Lossless First Order, JPEG Lossless, RLE, deflated frames, JPEG XL Lossless,
JPEG 2000 Part 2 Lossless, JPEG-LS Near-Lossless, JPEG Baseline, JPEG Extended,
JPEG 2000, HTJ2K, JPEG XL, JPEG XL JPEG Recompression, JPEG 2000 Part 2.
Unlisted syntaxes follow in lexical UID order. Rank does not qualify a codec.

`DicomRepresentationGenerator` performs transcoder preflight, plan and execution,
then decoded verification when preflight supports it (exact pixels for reversible
operations, shape for lossy operations). Lossless generation retains the SOP UID,
Image Type and any pre-existing Original Attributes Sequence. Lossy execution
uses the existing transcoder's `applyLossyMetadata`: a new SOP UID, DERIVED Image
Type, Source Image Sequence, Derivation Description, and appended 0028,2112/2114
history, with 0028,2110 remaining `01`. For sources with existing compression
ratios, the archive generator selects the existing buffered executor: the current
streaming ratio patch targets the first DS value rather than the appended value.
This avoids overwriting prior history without changing transcoder internals;
such generation materializes the whole output in memory. Codec identity is resolved through the
capability registry; native dataset writing uses the caller's toolkit version.
Unknown linked-backend versions use that toolkit version, not an invented runtime
version. The archive mechanism does not add SCP coercions. PS3.4 B.4 restrictions
and Warning responses remain the responsibility of a receiving SCP.

A generator actor belongs to one sink, configuration hash, toolkit version and
codec environment. Concurrent requests with the same source hash, target syntax
and typed-parameter hash share one execution and publication. Cancelling one
waiter returns typed `cancelled` only to it; removing the last waiter cancels the
shared task. Completed bytes and descriptors go to the injected store. Its atomic
publication checks the derivative limit and source fingerprint. An invalidation
revision prevents an older in-flight task from publishing after invalidation.
`DicomInMemoryRepresentationStore` has no disk, catalog or settings dependency;
it keeps stale descriptors visible as `.unavailable(.stale)`. Hosts call
`invalidateStale` with current source/configuration/codec keys and implement the
same validation and invalidation-revision contract in persistent sinks.

The C-STORE overload with a resolver proposes stored alternate syntaxes and sends
accepted stored bytes before invoking the existing rescue transcoder. It returns
`DicomRepresentationStoreOutcome`, containing the legacy outcome and a decision.
The legacy-policy bridge maps `asReceived` to `originalOnly`; `lossless` and `any`
to `losslessEquivalents`. Use the explicit loss-policy overload to authorize stored
lossy derivatives. The old rescue-transcoder seam generates only lossless
same-identity output in this overload; use the archive generator to create and
store authorized lossy derivatives. C-GET/C-MOVE's convenience initializer and
WADO-RS expose only stored same-identity equivalents, since a derivative is a
different SOP resource. WADO-RS tests each stored syntax against Accept and prefers
an acceptable stored object before considering a transcode. Without a resolver,
existing DIMSE and DICOMweb behavior is unchanged.

Decisions contain only source/representation UIDs, content hashes, transfer syntax,
cost figures, a policy snapshot hash and typed reason codes. They do not copy
patient attributes, locators, authorization text or arbitrary error descriptions.
The chosen representation is an audit projection, resolved back through the set's
UID and hash. Cost estimates are injected; default zero costs mean unspecified,
not measured zero-byte payloads. Reasons are `originalAccepted`, `storedEquivalent`,
`authorizedStoredDerivative`, `generationRequired`, `syntaxNotAccepted`,
`policyExcluded`, `lossyNotAuthorized`, `peerRejectsLossy`, `stale`, `unavailable`,
`generationDisabled`, `codecUnavailable`, and `higherCostOrRank`.

## Durable ingestion and integrity (Lot A, #2356)

`DicomIngestCoordinator` accepts original Part 10 bytes or a received DIMSE
instance. It validates the encoded dataset, SOP identity and transfer syntax.
Part 10 input remains byte-for-byte unchanged. A raw encoded DIMSE dataset is
wrapped in generated file meta without re-encoding its dataset. This mechanism
adds no coercion and does not transcode; hosts that coerce attributes must apply
PS3.4 B.4 and return the applicable Warning status.

The stages are `received`, `validated`, `staged`, `checksummed`, `published`, and
`registered`. Each stage appends an `intent` before its effect and a `done` after
completion. Staging uses `.ingest/<ingestID>.part`, file synchronization, and
synchronization of the staging directory. SHA-256 is computed over the staged
bytes. Publication uses an atomic, non-replacing rename on Darwin, followed by
synchronization of both affected directories on all platforms. Darwin attempts
`F_FULLFSYNC` and falls back to `fsync` when unsupported; other platforms use
`fsync`. The non-Darwin publication fallback is an exclusive hard link followed
by unlink, so replay may encounter both names. Neither method replaces an
existing destination. All paths must belong to the same filesystem.

The first available name is `<safe SOP UID>.dcm`, then
`<safe SOP UID>~<sha8>.dcm`; a further UUID suffix handles occupied hash-prefix
names. Same-UID, different-byte arrivals go to `.conflicts/`. Identical-content
classification requires a known SHA-256 and re-verification of the prior file
before discarding the incoming temporary. UIDs alone and unknown hashes never
establish equality. The registrar exposes the archive classification through
`DicomRepresentationConflict`; originals and conflicts are separate records.

Every coordinator sharing a registrar uses its `DicomIngestGate` across
classification, publication and registration. Registrar implementations must
serialize writes, make registration idempotent by ingest ID, preserve earlier
records and report transaction-time conflicts. The JSONL registrar and journal
require one owner per file in a process; they are not a multiprocess database.
Hosts must prevent independent owners of the same registry and run replay before
admitting new work after restart. Files in pre-existing inboxes without records
are preserved by exclusive publication and can be reconciled with the integrity
primitives. Lot A does not migrate an Isis catalog or infer hashes for old rows.

`DicomJSONLIngestJournal` and `DicomJSONLIngestRegistrar` append a JSON object
followed by LF, then synchronize the file and parent directory. Journal objects
contain `ingestID`, `stage`, `phase`, `root`, `temporaryPath`, optional `finalPath`,
`checksum`, SOP Class/Instance UIDs, transfer-syntax UID, optional conflict hash,
optional disposition and `timestamp` (Foundation Codable date representation).
Each entry repeats the complete recovery metadata; it contains no patient
attributes. The supplied root must itself be free of patient attributes.
A torn unterminated tail is ignored. Before the next append it is delimited and
followed by `{"discardedTail":true}`; malformed interior records without that
marker fail closed. A terminal disposition records duplicate disposal, partial
staging disposal, or quarantine. Registry lines contain `DicomIngestRecord`.

| Last durable journal state | Replay decision |
| --- | --- |
| Received/validated or staged intent without done | Remove only the untrusted temporary, journal disposal |
| Staged done / checksum intent | Rehash and reopen the temporary, then continue |
| Checksummed done | Verify bytes and identity, classify and publish exclusively |
| Published intent, matching final exists | Reopen, synchronize directories, continue registration |
| Published intent, temporary exists | Verify it and finish publication; if another arrival took the final name, reclassify without touching that arrival |
| Published intent, neither path exists | Report loss |
| Published done without registered done | Reverify and re-register idempotently; registrar conflict is quarantined and registered as conflict |
| Published bytes fail verification | Preserve bytes; quarantine a known published arrival, report failure for an ambiguous destination |
| Registration failed with unknown state | Preserve the object in `.quarantine/<ingestID>.dcm`, retaining journal evidence for host reconciliation |
| Quarantine move interrupted | Complete the journaled move, never delete the original |
| Registered done | No action |

A simulated `DicomIngestCrash` stops compensation and subsequent filesystem
effects. Other failures preserve recoverable journal state. ENOSPC maps to
`diskFull(required:available:)`, EACCES/EPERM to `permissionDenied(path:)`.
Incomplete staged files never become normal published objects. Failure of a
post-registration journal append does not move a confirmed registered file.
Cancellation is observed before staging; once staging starts, the transaction
finishes or leaves replayable evidence rather than deleting an uncertain original.

Durability is ordered: `receivedInMemory < fileSynced < publishedAndRegistered
< retentionConfirmed`. The in-memory journal or registrar caps results at
`fileSynced`. The JSONL implementations establish `publishedAndRegistered` after
the file, directories and registration are synchronized. Neither implementation
claims a backup or retention guarantee. `retentionConfirmed` requires an injected
host registrar/evidence provider that actually establishes safekeeping under its
retention and retrieval contract. Filesystem barriers are OS guarantees, not
qualification of every storage controller's power-loss behavior.

`DicomStorageSCPService` and `DicomDIMSEServer` accept an optional coordinator and
`DicomDurabilityPolicy`. With that injection C-STORE-RSP follows successful
ingest and satisfaction of the policy (default `publishedAndRegistered`): `0000`
for new or identical canonical bytes, `B000` for bytes retained as a conflict
(issue #2529). The file-cache provider also propagates that conflict warning
without coordinator injection. The original remains the retrievable object. Disk
full returns `A700`; other ingest failures or insufficient durability return
`C000`. The `instanceStored` callback still follows the response and optional
stored-reference persistence. `DicomFileStorageCache` now uses the JSONL ingest
core and exposes `recoverPendingIngests()`. Without a coordinator injected into
the service, its original provider-return/reference-persistence response contract
remains; that legacy contract does not assert catalog durability or retention.

Storage Commitment accepts `DicomCommitmentEvidenceProviding` either directly on
the server or through the commitment provider's optional `evidenceProvider` hook.
N-ACTION success acknowledges preparation of the request, not successful commitment
of its references. Before N-EVENT-REPORT, including redelivery of pending reports,
the server filters successful references using current evidence. Missing files
or registrations yield Failed SOP Sequence reason `0112`; checksum mismatch,
evidence errors and insufficient durability yield `0110`. The default evidence
policy requires `retentionConfirmed`. In accordance with PS3.4 J.3, a reference is
reported committed only after the injected contract establishes safekeeping.
Without an evidence provider the prior reference-only path remains explicitly
weaker: a remembered reference does not prove file presence, checksum, retention,
or retrieval availability. Hosts must supply the stronger evidence for those claims.

`DicomWebStorageResult.durability` is optional for source compatibility. A declared
level below `publishedAndRegistered` adds Warning Reason `B000` and HTTP 202 to the
Store Instances Response. An absent level preserves the legacy provider contract;
it is not evidence of persistence. `DicomWebInMemoryStorage` preserves same-UID
originals, treats identical bytes as duplicates, and records different bytes in
`conflictingInstances()` with Warning Reason `B000`, no Failure Reason, and HTTP
202 (issue #2529). Both STOW and C-STORE accept retained divergent bytes with a
warning while leaving the original retrievable. The `dicomtool web` directory
provider preserves the exact incoming bytes under
`.conflicts/<hex-encoded-UID>~<full-content-SHA256>.dcm` and excludes conflicts from
its canonical index on restart. The STOW CLI exits 0 for fully accepted batches,
including warnings, 2 for accepted plus refused instances, and 1 for all-failed
batches. Conflict expiration and size limits are outside this policy change.
The in-memory provider's legacy initializer leaves the durability field absent; `reportsDurability: true` declares `receivedInMemory` and
warns for all accepted objects. Neither mode asserts durable archival storage.

`DicomArchiveIntegrityScanner` compares streaming SHA-256 values with recorded
hashes and optionally reopens Part 10 identity. It reports missing, mismatched,
unparseable, identity-mismatched, unrecorded, temporary and conflict files without
patient attributes. Unknown recorded hashes are findings, not successful checks.
The caller supplies the complete file inventory; it must exclude journal/registry
metadata. The local hash reader uses bounded chunks; optional parse/reopen still
materializes the object. `DicomArchiveOrphanClassifier` returns a quarantine or
preservation plan, allowing deletion only after explicit per-path confirmation
of a duplicate. `DicomDerivativeRepairPlanner` returns regenerate/invalidate
plans from verified source hashes. These primitives perform no repairs or deletions
and never invalidate the durability of an original because a derivative failed.
