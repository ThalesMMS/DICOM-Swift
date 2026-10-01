# DICOM-Swift

<p align="center">
  <img src="https://img.shields.io/badge/Swift-6.2+-orange.svg" />
  <img src="https://img.shields.io/badge/iOS-26.0+-blue.svg" />
  <img src="https://img.shields.io/badge/macOS-26.0+-blue.svg" />
  <img src="https://img.shields.io/badge/license-Apache%202.0-blue.svg" />
  <br/>
</p>

DICOM-Swift is a pure Swift DICOM decoder toolkit for iOS, visionOS, and macOS. Parse DICOM
metadata, extract pixel buffers, apply medical windowing, embed SwiftUI viewer
components, script inspection/export workflows with the bundled CLI, and
optionally remux encoded DICOM video for Apple playback.

Suitable for lightweight DICOM viewers, PACS clients, telemedicine apps, and research tools.

- Public source releases: [`ThalesMMS/DICOM-Swift`](https://github.com/ThalesMMS/DICOM-Swift)
- Guides: [Getting Started](GETTING_STARTED.md) | [Usage Examples](USAGE_EXAMPLES.md) | [Glossary](DICOM_GLOSSARY.md) | [Troubleshooting](TROUBLESHOOTING.md)
- API docs: Generate locally for `DicomWebClient`, `DicomCore`, `DicomAppleMedia`, or `DicomSwiftUI`
- Related projects: [MTK](https://github.com/ThalesMMS/MTK) | [MTKDicomBridge](https://github.com/ThalesMMS/MTKDicomBridge) | [MTK-Demo](https://github.com/ThalesMMS/MTK-Demo)

## Table of Contents

- [Overview](#overview)
- [Development Provenance](#development-provenance)
- [Features](#features)
- [Performance](#performance)
- [Release Status](#release-status)
- [Quick Start](#quick-start)
- [Installation](#installation)
- [Usage Examples](#usage-examples)
- [Command-Line Tool](#command-line-tool)
- [SwiftUI Components](#swiftui-components)
- [Architecture](#architecture)
- [Documentation](#documentation)
- [Integration](#integration)
- [Contributing](#contributing)
- [License](#license)
- [Support](#support)

---

## Development Provenance

The public repository is a manually published source mirror. Maintainers develop
and review package changes with the application that consumes the canonical
source; publication preserves the mirror history without importing application
history. Consumers need only this package and its public SwiftPM dependencies.
See [Distribution](DISTRIBUTION.md) for content, attribution, validation limits
and [Releasing](RELEASING.md) for the publication procedure.

---

## Overview

This project is a full DICOM decoder written in Swift, modernized from a legacy medical viewer. It provides:

- Complete DICOM file parsing (metadata and pixels)
- Pixel extraction for 8-bit, 16-bit grayscale, RGB, PALETTE COLOR, and YBR images
- Color display conversion matrix for MONOCHROME, RGB, PALETTE COLOR, YBR_FULL, YBR_FULL_422, and explicit unsupported YBR paths
- Image export API and CLI for PNG, JPEG, TIFF, 16-bit TIFF, multiframe output, and optional non-PHI metadata sidecars
- UI-independent print/export preprocessing pipeline for windowing, resize, and explicit annotation burn-in
- Export support matrix for image export, Secondary Capture, print management, waveform, and video helpers with typed unsupported-path diagnostics
- Window/level with medical presets and automatic suggestions
- Modern async/await APIs for non-blocking operations
- File validation before processing
- Directory, selected-file, and ZIP series loading through `DicomDecodedSeries`
- Optional Apple media remuxing for MPEG-2, H.264, and H.265 DICOM video
  without re-encoding

DICOM (Digital Imaging and Communications in Medicine) is the standard for medical imaging used by CT, MRI, X-ray, ultrasound, and hospital PACS systems.

### HL7v3 CDA

The XML preflight rejects DTD/entity declarations while permitting declaration-like
text inside comments, CDATA and processing instructions; external entities remain disabled.

The `HL7v3CDA` product contains a lossless CDA R2 XML model plus the
structural template layer.  `CDATemplateLibrary` ships a versioned, PHI-free
C-CDA R2.1 subset; `CDAValidator` reports deterministic structural findings and
coverage without copying narrative content.  `CDADocumentBuilder` wires
generated narrative IDs to entry references, while `CDADocumentComparator`,
`CDADocumentMerger`, and `CDADocumentVersioning` provide path diffs,
conflict-aware merge, and RPLC/APND lineage operations.  These profiles are a
checkable subset and are not a claim of full C-CDA conformance.  See
`Tests/HL7v3CDATests/Fixtures/templates/manifest.json` for the template inventory and the
`CDA_SDTC.xsd` oracle fixture set. `CDATransformer` maps ADT/ORU/ORM to CDA and back with a
loss report, `CDAEncapsulation` wraps documents as Encapsulated CDA, and the optional
`HL7v3Transport` product adds bounded SOAP/REST clients; see `DISTRIBUTION.md`.
Document rendering includes nested sections and preserves spaces around inline narrative elements.
The base profile accepts multiple record targets and optional, paired version identifiers.

### FHIR R4

The loopback test oracle commits transactions atomically, checks each Bundle entry's
SMART resource/action scopes and restricts patient scopes to the selected patient's
resources. Rest-hook delivery requires explicit loopback origins in `behaviors.webhook_origins`
and never follows redirects or uses environment proxies.

The optional `FHIR` product keeps resources as a lossless ordered JSON tree with typed
views, converts FHIR XML, validates structure/profiles/FHIRPath invariants, talks to
FHIR servers through a bounded REST client with typed search and rest-hook
subscriptions, and maps DICOM datasets to `ImagingStudy`/`Patient`/`Endpoint`;
`hl7tool fhir` is the CLI. See `DISTRIBUTION.md`.

### SMART on FHIR and clinical mappings

Automatic order links and result supersession require matching patient identity,
even when different patients reuse accession, placer, filler or result identifiers.

`FHIR/SMART` implements SMART App Launch (discovery, PKCE code flow, refresh,
revocation, sessions for `FHIRClient`); the optional `ClinicalMapping` product maps
patients, orders, studies and results between HL7 v2, DICOM (MWL/MPPS/SR) and FHIR with
provenance and an idempotent order→study→result workflow (`hl7tool workflow`,
`hl7tool smart`). See `DISTRIBUTION.md`.
Patient matching requires shared identity evidence and checks given names and
alternate identifiers; mixed-patient DICOM studies are refused. Id-less sources
use digest/entity retry detection, and SMART issuer checks include the complete URL.
Workflow identity conflicts take precedence over matches, corrected results supersede the
highest stored numeric version, and arriving studies clear their pending references.

---

## Features

### DICOM Decoding

- Little/Big Endian, Explicit/Implicit VR
- Explicit-length and undefined-length SQ parsing, including nested items and strict delimiter diagnostics
- Structurally bounded dataset parsing through `DicomDataSetParseLimits`; the default inclusive budget permits
  64 nested sequences, 1,000,000 element headers, and 500,000 sequence items across one dataset tree, with
  deterministic `DicomDataSetParseError` failures when a limit is exceeded
- `DicomDataSetParser.read` adds strict VR/VM/encoding checks and bounded scalar recovery with owned UN bytes;
  `DCMDictionary(extendingWith:)` accepts public extensions without shadowing standard definitions, while
  `DicomPrivateDictionary` resolves creator/block/item scope. The 5,274 standard definitions are generated from
  a pinned, licensed DICOM 2024d source; run `python3 Scripts/Dictionary/generate_dictionary.py --check` offline.
  The writer preserves all 34 standard VRs and rejects lossy text/numeric conversion. See
  [dataset fidelity](DISTRIBUTION.md) for tested syntax profiles and remaining qualification limits.
  Validated ISO 2022 conversion checks declared escapes, PN and item boundaries, and single-byte/Japanese/Korean/Chinese
  repertoires; independent charset artifacts record external-reader limitations explicitly.
  Validated reading and opt-in writing distinguish stored values from query keys using
  `DicomDataSetPurpose`, checking lexical text, PN groups, dates, precision and structural budgets.
- Grayscale 8/16-bit, RGB 24-bit, PALETTE COLOR, YBR_FULL/YBR_FULL_422, and ICC profile metadata
- Real World Value Mapping for linear/LUT quantitative maps with physical units and ranges
- Parametric Map Storage parsing for scalar layers with units, quantity definitions, RWV, geometry, and source references
- Structured Report and Key Object Selection parsing for navigable content trees, measurements, ROI references, CAD findings,
  and key image references; content flattening and source-reference aggregation use iterative preorder traversal with
  first-occurrence identity deduplication
- SR template Mapping Resource uses `CS`. Frame selection is carried by IMAGE
  content, with study/series context recovered from instance evidence; KOS writing
  omits SR completion/verification flags. The validated SR builder rejects framed
  evidence with no matching content reference instead of losing its scope.
  Builder validation remains an application semantic subset, not full IOD or TID
  validation: mandatory common/document metadata must still be supplied by callers.
- `DicomSRDocumentModule` composes bounded SR/KOS document-attribute rules with
  explicit unknown external conditions, nested observer/request/evidence macros,
  and the VERIFIED/COMPLETE relationship. It leaves content, complete IOD and
  reference semantics to their separate validation layers. The synthetic module
  corpus is compared with the pinned independent IOD oracle.
- `DicomSRReferenceValidator` compares raw content/evidence membership, checks
  supplied target identities, derives graph-provable document conditions and
  preserves nested item paths. Explicit frame/segment/channel selectors are checked
  against matching target metadata, including waveform channel zero and declared
  segment numbers. `DicomSOPReferenceTraits` audits 171 standard classes for
  IMAGE/WAVEFORM/COMPOSITE applicability and distinguishes Softcopy Presentation
  States from volumetric/waveform states. Accompanying RWVM references require the
  mapping class; unknown classes remain limitations. A 539-case corpus independently
  checks the role catalogue and records whole-IOD oracle gaps. Full target geometry remains unqualified.
  Unavailable targets and unsupported reference
  semantics remain explicit limitations; it does not fetch or qualify target IODs.
- `DicomContentReferenceMacro` checks conditional IMAGE/WAVEFORM selectors using
  explicit target and all/subset facts, retaining unknown conditions. It requires
  single complete accompanying SOP pairs and composes into `DicomSRContentValidator`
  through original item paths. A 21-case corpus records independent macro-nesting
  and external-condition gaps; compose the reference component for SOP applicability.
  `contentReferenceConditions` derives single/multiframe/segmentation and coherent
  waveform channel facts from identity-matched primary targets. Conditional
  multiframe classes remain unknown without usable Number of Frames; all/subset
  intent is never inferred. A separate 13-pair wire corpus composes these facts
  with explicit author intent and records independent-validator condition gaps.
  Full target IODs remain pending.
- `DicomSRIconImageValidator` checks the 128×128 SR icon bounds, unsigned 1/8-bit
  monochrome/palette metadata, native encoded pixel lengths and palette consistency.
  Callers explicitly distinguish native, encapsulated and omitted pixels. Its
  21-case corpus includes exact independent decoded pixels/palette colors; ICC,
  stated extrema and encapsulated icon decoding remain unqualified.
- `DicomSRContentItemMacro` enforces base SR item/relationship requirements,
  conditional scalar values, incompatible macro exclusions, heading/reference-purpose
  and observation-time conditions, plus conditional container template identification.
  Text uses CR LF without formatting controls; DCMR template identifiers are
  unprefixed digits without leading zeroes. Its 43-case wire corpus records exact
  independent-validator gaps. Per-item provenance enters `DicomSRContentValidator`
  through `contentConditions`; unknown facts remain unknown. Typed value macros,
  template semantics and full IOD rules remain separate.
- `DicomSRRelationshipValidator` also requires compatible SELECTED FROM targets
  for SCOORD/TCOORD, including resolved forward/backward references. Missing links
  use `requiredRelationshipMissing` at the original source Content Sequence path;
  opaque or interrupted graphs cannot prove absence. An 18-case wire corpus
  records independent graph witnesses and whole-IOD oracle limitations. This
  does not impose the 2D image-reference requirement on independent SCOORD3D data.
- `DicomTemporalCoordinatesMacro` enforces C.18.7 representation choices, temporal
  range cardinality, positive sample positions and usable finite offset/date values.
  Waveform/single-multiplex-group conditions require explicit evidence; absent
  provenance stays incomplete. It composes into `DicomSRContentValidator` through
  original per-item `temporalConditions` paths, with a shared component-work budget.
  A 48-case wire corpus records 16 whole-IOD oracle agreements and 32 documented
  gaps. Target sample bounds, temporal alignment and full SR qualification remain separate.
- `DicomSpatialCoordinatesMacro` separates SCOORD pairs from signed SCOORD3D
  triplets, enforces Graphic Type cardinalities, finite FL values, required 3D
  frame-of-reference identity, and exact 3D polygon closure. Pixel Origin
  Interpretation uses an explicit tri-state tiled-image fact. The Core traversal
  accepts these facts through original per-item `spatialConditions` paths; scans
  share the work budget. A 44-case wire corpus documents 19 oracle agreements and
  25 gaps. Coplanarity, axis geometry and target-image bounds remain separate.
- `DicomSpatialGeometryValidator` separately checks polygon coplanarity and
  ellipse/ellipsoid axis centers, orthogonality and major/minor order. Exact
  binary32 predicates prevent cancellation from approving contradictory shapes;
  storage-rounding ambiguity and degenerate shapes remain incomplete. A 22-case
  wire corpus has independent exact-rational witnesses, including extreme scales.
  The Core traversal preserves geometric diagnostic paths and still marks absent
  image/frame/matrix bounds incomplete for SCOORD. Full IOD scope remains separate.
- `DicomSRSpatialReferenceValidator` resolves SCOORD image selections against actual
  SOP identities and checks inclusive column/row bounds using frame or Total Pixel
  Matrix dimensions. It reuses explicit frame/segment selector checks and derives
  tiled-image conditions from target metadata. Core accepts `targets`, preserves
  original paths and rejects contradictory caller facts. Missing targets, incomplete
  metadata and interrupted graph traversal remain incomplete. Fourteen synthetic
  source/target pairs have independent numeric witnesses and documented oracle gaps;
  these checks do not qualify the target's full IOD or pixel payload.
- `DicomSRCoordinateReferenceValidator` extends the same graph/target engine to
  TCOORD. It derives waveform and single-multiplex-group conditions, follows
  spatial/image selection chains and checks one-based sample positions against
  Number of Waveform Samples. Cross-instance group identity uses Multiplex Group
  UID; equal item ordinals alone prove nothing across objects. Core consumes these
  facts and rejects contradictions. Missing selectors/targets and offset/absolute
  acquisition-time alignment remain incomplete. An 18-case wire corpus records
  independent metadata witnesses and exact whole-IOD oracle gaps.
- `DicomSRContentValidator` checks raw projection prerequisites and reuses the
  existing semantic identity/item checks with PHI-free tag/item diagnostics.
  It preserves sibling indexes, shares evaluation budgets, and reports opaque,
  by-reference and long/URN-code projection limitations. Full content/TID rules
  remain unqualified, independently of application semantic acceptance.
  Both legacy and composed SR semantic checks reject negative/non-finite SCOORD
  values; referenced-image upper bounds remain a separate geometry requirement.
- `DicomInstanceValidator` composes original Part 10 structure/VR-VM, file-meta
  identity, the classic CT/MR/SC modules (all 26 single-frame SC modules, including
  Patient Study, Synchronization, Specimen, Enhanced Patient Orientation, ICC Profile,
  General Acquisition, Clinical Trial, Device and Overlay Plane), the multi-frame SC
  modules (`DicomSCMultiframeModules`: Multi-frame, SC Multi-frame Image/Vector, Cine,
  Frame Pointers, Frame Extraction, Dimension and A.8 content constraints), SR/KOS
  modules, the classic CT/MR/CR modules (Contrast/Bolus, Multi-energy CT with index
  cross-references, Single-Frame CT Series, CR Series/Image, Display Shutter, Image
  Plane geometry bounded by the encoded precision and Patient Orientation against the
  cosines), the SR/KOS series, document, IOD value-type and KOS root-template rules
  (`DicomSRSeriesModule`, `DicomSRProfileConstraints`), SR and image reference evidence
  and actual RLE/JPEG frames. The SR builder emits the Patient/Study/Equipment/Series
  Type 2 attributes and the mandated KOS TID 2010 template. `DicomEnhancedImageModules`
  composes the Enhanced CT/MR/XA IODs from tables generated from PS3.3 2026c
  (`DicomEnhancedImageTables`, curated conditions in `DicomEnhancedImageConditions`):
  modules, shared/per-frame functional group usage, macro content per frame, dimension
  coherence and frame geometry. SC, multi-frame SC, classic CT/MR/CR, the offered
  Enhanced SR, Comprehensive SR and KOS SOP Classes, Enhanced CT/MR/XA, Segmentation, Parametric Map, the four Softcopy Presentation States, RT Dose/Structure Set/Plan, the fifteen waveform SOP Classes and the five encapsulated documents are the `qualifiedProfiles`; other SOP Classes keep the global
  `moduleRuleUnavailable`. `DicomCodecWorkflowEngine.validateInstance` and
  `dicomtool validate --composed --fact name=yes|no` share it; codec
  validation/transcode reports carry the same evidence in `conformance`. `DicomNativePixelValidator` checks original native value lengths,
  allocation/VR, packed one-bit frames, YBR_FULL_422 storage and OF/OD prerequisites.
  Deflated Explicit VR Little Endian is inflated within `Limits.maximumInflatedBytes`
  and validated as Explicit VR Little Endian. Objects of any size are validated at a
  cost linear in their frames; only the per-frame codestream checks keep a frame and
  byte budget, and the frames past it are declared unevaluated. Without supplied
  targets, an object's references are one `referenceTargetUnavailable` limitation
  (Isis #2516). Incomplete IODs, patient-space geometry and unsupported codestreams
  remain explicit.
  Composed CLI exits distinguish failed (1) and incomplete (2). `dicomtool profiles`
  prints `DicomQualifiedProfileCatalog`, the exact set of qualified SOP Classes; the
  generated declaration in `DISTRIBUTION.md` names that scope only.
  `DicomCompositeImageModules` composes common Patient/Study/Series requirements
  for classic CT/MR/SC, equipment and conditional Frame of Reference attributes.
  SC Modality stays optional; caller-only animal/anatomy/laterality conditions
  default to unknown. Missing common attributes fail independently of valid pixels.
  `DicomGeneralImageModule` adds General Image attributes and shared icon checks;
  temporal-series conditions default to unknown. Classic CT/MR/SC remain single-frame.
  General icons retain the common icon restrictions without SR's extra 128-pixel limit.
  Patient-space orientation and source compression history remain unqualified.
  `DicomSCImageModule` adds classic SC calibration conditions, exact decimal
  spacing/aspect comparisons and document/view code structure. `calibratedImage`
  caller facts default to unknown; arithmetic range and coded-view limitations
  remain explicit, independently of successful pixel decoding.
  `DicomImagePlaneModule` adds mandatory plane attributes for classic CT/MR and
  SC with patient position/orientation, plus bounded exact decimal basis and
  spacing checks. Non-unit bases, rounding and series geometry remain unqualified.
- `DicomJPEGFrameValidator` compares actual SOF/SOS evidence with JPEG Baseline,
  Extended and Lossless metadata, including precision, dimensions, component count
  and SV1 prediction across scans, DQT/DHT presence per scan and chroma sampling
  against `YBR_FULL_422`. `DicomJPEGFrameInspector` rejects malformed or incomplete
  marker streams without decoding pixels; extended and lossless frames are then
  decoded natively so their codestream layer passes, while baseline frames stay
  delegated and unverified (`codestreamPayloadUnverified`). `DicomJPEGLSFrameValidator`
  (SOF55/LSE/SOS, NEAR 0 under `.80`) and `DicomJ2KFrameValidator` (SIZ/COD/QCD/CAP:
  dimensions, precision, sign, MCT against `YBR_RCT`/`YBR_ICT`, reversible coding under
  the lossless-only syntaxes, RPCL under `.202`, Part 15 capabilities under HTJ2K)
  compose the same evidence for JPEG-LS, JPEG 2000 and HTJ2K without decoding packets.
  A 16-case JPEG corpus and a 40-case codestream corpus from independent encoders
  (OpenJPEG, CharLS) exercise positive frames and metadata/profile contradictions.
- `DicomRLEFrameValidator` composes the RLE pixel-attribute table with actual
  segment count, offsets, PackBits output lengths, row boundaries, required
  replicate runs and even segment padding. `DicomRLECodec` in `DicomCodecs` shares
  packet processing with the production decoder, which rejects trailing sample
  payload and invalid unused offsets but still decodes odd segments. Inspection
  does not allocate pixel planes. One-bit padded samples and 8/16-bit monochrome,
  palette and color metadata have a 20-case wire corpus;
  display support and complete IOD conformance remain separate from frame validity.
- `DicomNumericMeasurementMacro` adds C.18.1 measurement/qualifier cardinalities,
  single numeric values, explicit source-precision conditions and nonzero rational
  denominators. Content validation accepts precision facts by original item path;
  unavailable precision, terminology and representation equivalence remain unqualified.
- `DicomSRRelationshipValidator` resolves original intradocument item identifiers
  and checks the Enhanced SR, Comprehensive SR and KOS relationship tables.
  Compose it with external object-reference validation; opaque targets and other
  SOP profiles remain unqualified, and the application semantic model still has
  a separate limitation for by-reference content.
- Secondary Capture snapshot dataset building and parsing with patient/study/series context and source image references
- External inference builders for SR findings, SEG masks, GSPS graphic annotations, and derived images with source references and tracking identifiers
- `DicomSegmentationBuilder.encodedDataSet(from:studyInstanceUID:seriesInstanceUID:sopInstanceUID:contentLabel:encoding:options:)`
  writes SEG Pixel Data natively, with the dataset deflated (`.1.99`), in RLE Lossless (`.5`) or with each frame
  deflated (`.8.1`), and returns the transfer syntax to write it with. Encapsulated frames are encoded one at a
  time, concurrently; RLE keeps BINARY segmentations native (Annex G has no one-bit samples). `DCMDecoder.segmentation`
  decodes RLE (including unambiguous packed/byte BINARY), frame-deflated, JPEG-LS Lossless, reversible JPEG 2000
  (`.90/.91`) and HTJ2K Lossless (`.201/.202`) SEG frames one at a time as stored values. Unsupported or lossy
  encodings return diagnostics and no frames (Isis issues #2513, #2520)
- `DicomSegmentationBuilder.binaryPlan(forLabelmap:)` and
  `binaryDataSet(convertingLabelmap:plan:studyInstanceUID:seriesInstanceUID:sopInstanceUID:contentLabel:options:)`
  turn a LABELMAP segmentation into BINARY Segmentation Storage for a receiver without Label Map Segmentation
  Storage: one segment per declared, non-background label present, numbered from 1, and one frame per label and
  slice, packed in one pass over the label planes (Isis issue #2514). Label Map Segmentation Storage is part of
  `DicomStorageSOPClassUIDs.commonClinicalStorage` and an IMAGE record of `DicomFileSet`; contexts that carry
  identifiers only (query/retrieve, verification, workflow, print) are proposed and accepted in native transfer
  syntaxes (`DicomStorageSOPClassUIDs.transferSyntaxes(_:forAbstractSyntax:)`)
  `DicomAIInferenceBuilder.presentationStateDataSet` requires a nonblank Series Instance UID
  in every source image reference. Its existing `throws` API propagates
  `DICOMError.missingRequiredTag` for absent, empty, or whitespace-only series UIDs;
  valid references retain series grouping, deduplication, SOP identity, and frame numbers.
- Grayscale Softcopy Presentation State building/parsing for referenced image
  and frame applicability, Displayed Area Selection, scoped Softcopy VOI,
  spatial transforms, geometric/bitmap shutters and presentation value,
  ordered graphic layers, graphic/text objects, and ICC payload preservation
- Presentation State sources live in `Sources/DicomCore/PresentationState/`:
  value types are in `Models/`, the GSPS builder owns writing helpers, and the
  `DCMDecoder` extension keeps its parser private. The existing reader supports
  Grayscale, Color, and Pseudo-Color families through the same public API;
  shared text normalization stays internal to `DicomCore`.
  GSPS/SR/SEG writers use `CS` for Content Label and `LO` for Content Description
  when present, and encode Tracking ID as `UT`. GSPS Graphic Layer Description
  uses `LO`; compound-graphic Rotation Angle is encoded as `FD`, preserving
  double precision. These VRs follow the
  [DICOM PS3.6 data dictionary](https://dicom.nema.org/medical/dicom/current/output/pdf/part06.pdf).
- Encapsulated PDF, CDA, and STL document dataset building/parsing with MIME, title, concept, payload, and source instance metadata
- ECG and waveform dataset building/parsing with channel samples, sampling frequency, units, and waveform source references
  - Explicit legacy display scales must agree across multiplex groups; unspecified scales inherit that value,
    and explicit root presentation settings override them.
- Video Endoscopic/Microscopic/Photographic dataset building/parsing with MPEG-2, H.264, and H.265 stream forwarding; native frame decode and transcoding fail with typed errors
  - MPEG-2 header inspection preserves raw bytes; NAL unescaping remains enabled for H.264 and H.265.
- PET SUVbw/SUVlbm/SUVbsa/SUVibw helpers with required-metadata diagnostics;
  already-normalized GML values are accepted as SUVbw only when SUV Type is
  absent (the DICOM BW default) or explicitly BW
- Transfer syntax registry and conservative transcode planning with codec diagnostics
- `Transcoding/` separates shared execution-route resolution, preflight, pixel/Part 10 helpers,
  and JPEG-LS, JPEG 2000/HTJ2K, and JPEG XL implementations. Preflight and async
  execution use the same prepared descriptors and intent validation; the sync API
  preserves its JPEG-LS, RLE and deflated-frame reversible encoders. Preflight recognizes explicit
  JPEG-LS NEAR and still requires a source decoder when output verification is off.
  Both decompression APIs share native writing, remove encapsulated offset tables,
  and record RGB metadata for decoded interleaved color bytes.
- Compressed pixel support matrix with `decoded`, `delegated`, `experimental`, `streamed-only`, `unsupported`, and `out-of-scope` statuses
- Color display conversion matrix with stable diagnostics for unsupported photometric interpretation, sample count, planar layout, bit depth, alpha/extra samples, and transfer syntax context
- `DicomImageComparison` and `dicomtool image compare` (issue #2836) compare a test image with a reference, like
  DCMTK's `dcmicmp`:
  - stored values (before MONOCHROME1 display inversion), modality values (the default) or a linear VOI window;
  - maximum absolute error, MAE, RMSE, PSNR and SNR, per frame and in total;
  - a typed refusal when rows, columns, frames or samples differ, including incomplete decoded frames;
  - `--check-*` limits that exit with status 65, and an amplified difference image (`--save-diff`, `--amplify`).
- Transfer syntax writing matrix for native datasets, Deflated datasets, referenced datasets, and encapsulated Pixel Data passthrough
- A value over 65 535 bytes in a VR with a 16-bit length (a large Contour Data, say) is written in Explicit VR as UN with a
  32-bit length and a logged warning, as GDCM and DCMTK do. On reading, an explicit UN on a public tag whose dictionary
  entry has a single VR is decoded with that VR as Implicit VR Little Endian; multi-VR tags keep their contextual rules
  (issue #2835).
- Encapsulated Pixel Data parsing for Basic Offset Table, Extended Offset Table,
  fragments, and frame extraction, with one linear fragment-offset index shared
  by BOT and EOT mapping. Transcoder EOT lengths exclude final item padding;
  readers remain compatible with older padded lengths (see
  [validation evidence](DISTRIBUTION.md)).
  Without a usable table, the fragments of a multi-frame object are grouped into frames by their codestream markers:
  - a frame starts at a fragment opening with SOI (JPEG, JPEG-LS) or SOC (JPEG 2000, HTJ2K), right after a fragment
    closing with EOI/EOC;
  - RLE keeps one fragment per frame;
  - a grouping that does not match Number of Frames is refused as `unusableFrameMap` (issue #2814).
- Deflated Explicit VR Little Endian dataset read/write support through zlib
- Native JPEG Lossless decoding (Process 14, all selection values 0-7) for transfer syntaxes 1.2.840.10008.1.2.4.57 and 1.2.840.10008.1.2.4.70
- Own sequential JPEG decode supports separate and mixed component scans, per-scan Huffman/restart state and odd block grids; full/reduced pixels match the interleaved equivalent, including `.50`/`.111` recompression routes ([qualification](DISTRIBUTION.md)).
- Own JPEG SOF0/SOF1/SOF2/SOF3 support through the internal DicomJPEG target, with incorporated-source attribution and current profile qualification; the earlier external JLISwift candidate review remains historical evidence
- Native RLE Lossless decoding and Annex G encoding, Deflated Image Frame Compression (1.2.840.10008.1.2.8.1) decode/encode through the own per-frame DEFLATE codec, plus JPEG-LS .80/.81 through the internal DicomJPEGLS target preferred by default, with optional CharLS fallback
- Explicit JPEG Baseline, JPEG 2000, and diagnostic unsupported-path handling when the selected backend cannot preserve pixel precision
- Internal DicomJPEG2000 CPU adapter for direct-Data JPEG 2000/HTJ2K decode, with optional OpenJPEG comparison/fallback, telemetry and runtime rollback
- Neutral `DicomJPEG2000EncodingOptions` for cumulative resolution-detail layers,
  wavelet decompositions and LRCP/RLCP packets through async `DicomTranscoder`,
  `DicomCodecWorkflowEngine.plan`/streamed execution and `dicomtool codec transcode`
  (`--j2k-layers`, `--j2k-decompositions`, `--j2k-progression`). Omitted options keep
  byte-identical one-layer defaults. `.202` keeps its own single-layer RPCL profile;
  explicit invalid values are refused before output. See the DocC progressive-encoding guide
  and [independent qualification](DISTRIBUTION.md).
- Internal DicomJPEGLS CPU adapter for direct-Data JPEG-LS decode/encode, optional CharLS comparison, explicit NEAR intent and runtime rollback
- Vendored DicomJPEGXL codec (JXLSwift 1.4.0 core, own reference-exact Modular decoder and own VarDCT decoder at libjxl parity) for JPEG XL .110/.111/.112: Bits Stored 1–16, either sign, RGB8, ICC passthrough, progressive/upsampled/noisy lossy streams, explicit lossy encoding for 8/12/16-bit grayscale and RGB8 through `DicomEncodingIntent.jpegXL(options:)` (`--distance`, effective `--effort` 1–9), byte-identical JPEG recompression (`.111`, own reconstruction reader/writer: baseline, extended 8-bit and progressive JPEG, restart intervals, metadata segments) with the reverse `.111` → `.50`/`.51` route restricted to SOF0/SOF1 respectively (progressive SOF2 remains codec-level reconstruction and is refused under those UIDs); experimental and disabled by default
- Qualified ROI, resolution, and cumulative quality-layer decode for JPEG 2000 .90/.91 through `DicomDecodedFrameReader`, with explicit combination limits and cancellation
- Sendable Data-backed decoded frames with explicit format, byte order, lifetime, stride, compatibility copying, and pull-based bounded multiframe iteration
- Explicit-intent J2KSwift CPU encoding and shared DICOM transcoding for JPEG 2000 .90/.91 and HTJ2K .201-.203, with BOT/EOT encapsulation and deterministic lossy metadata
- Recognition and byte preservation for JPEG 2000 Part 2 multi-component UIDs `.92/.93`; the executable frame matrix does not claim an Annex J decoder merely because OpenJPEG or a separate JP3D volume adapter exists
- JPIP referenced pixel data for classic JPEG 2000 `.94/.95` and HTJ2K `.204/.205`, with a concrete HTTPS-first stateless transport for bounded cumulative `image/jp2`, `image/jph`, or `image/jphc` entities, exact origin allowlisting, asynchronous authorization, same-origin redirect policy, pull backpressure, and cancellation
- PS3.18 DICOM JSON and PS3.19 Native DICOM Model XML codecs (`DicomJSONCodec`, `DicomNativeXMLCodec`) with lossless VR storage, textual DS/IS/SV/UV, explicit bulk-data references resolved only through an injected resolver with limits, DTD/entity refusal and nesting limits for XML, shared by the DICOMweb client/server and `dicomtool convert`; see `DISTRIBUTION.md`.
- QIDO responses require `application/dicom+json` or compatibility `application/json`; 204 has no MIME requirement. Search pages expose `contentType`. The optional transfer-syntax checking sink validates File Meta even when the header matches; wildcard permits any concrete File Meta syntax. Generic retrieve/file sinks still support rendered and bulk representations. See `DISTRIBUTION.md` for the Isis object consumer policy.
- DICOMweb helpers with an explicit conformance matrix: QIDO-RS study search, WADO-RS metadata/instance/frame/rendered-frame retrieval, WADO-URI, STOW-RS multipart Part 10 storage, BulkDataURI retrieval through injected transport, optional bearer-token auth in the in-memory server, limit/offset pagination, bounded frame/render budgets, and stable typed errors. The default URLSession transport binds every request to caller-task cancellation. Raw frame retrieval preserves qualified native or encapsulated representations; native grayscale and color frames render as PNG, JPEG, or GIF. Wire requests, multipart bodies, HTTP statuses, and DICOM JSON run against the same canonical corpus as Isis, with intentional differences declared in the fixture.
- DIMSE helpers for tested C-ECHO SCU/SCP, C-FIND, C-GET, C-MOVE, C-STORE, Storage SCP, Storage Commitment, MPPS, and Basic Grayscale/Color Print workflows, including automatic color-first negotiation with grayscale fallback, explicit color refusal without conversion, RGB8 Color Image Box payloads, and optional Printer N-GET and N-EVENT-REPORT status handling, with negotiated incoming/outgoing PDU limits, per-instance C-GET delivery, separate C-STORE presentation contexts per proposed transfer syntax, typed presentation-context refusals, raw compressed dataset preservation in the Storage SCP, per-instance failure responses that keep the association alive, Specific Character Set decoding, caller-provided durable checkpoints before successful C-STORE/N-ACTION responses, reverse-role N-EVENT-REPORT delivery, TLS/user-identity configuration, persistent association pooling keyed by connection and presentation contexts, retries, cancellation, circuit breaker, progress, and audit hooks
- `DicomImageDisplayFormat` models every Image Display Format family (2010,0010) — `STANDARD\C,R`, the non-uniform `ROW`/`COL` bands (kept as bands, never coerced into a grid), `SLIDE`, `SUPERSLIDE`, and `CUSTOM\id` — with a strict, round-trip-safe parser (exact segment counts, no token silently dropped, checked capacity arithmetic) and typed image-box counts that bound print jobs before an association opens; `SLIDE`/`SUPERSLIDE`/`CUSTOM` capacities are printer-defined and stay unbounded
- Automatic memory mapping for large files (>10MB)
- Downsampling for fast thumbnail generation

### Geometry & Metadata

- Parses Image Orientation (Patient) (0020,0037) and Image Position (Patient) (0020,0032); exposes normalized row/column vectors and origin.
- Reads Pixel Spacing (0028,0030) and slice spacing/thickness; exposes spacingX/Y/Z.
- Exposes width/height, bitsAllocated, pixelRepresentation (signed/unsigned), rescale slope/intercept.
- Returns Series Description and raw tag access via `info(for:)`.
- Parses all 16 repeating Overlay Plane groups (6000-601E), including
  multi-frame standalone Overlay Data and retired overlays embedded in native
  single-sample Pixel Data, through `overlayPlanes(forFrame:)`.

### Series Loading

- Directory-level loader that scans `.dcm` files, orders slices by IPP projection on the IOP normal (fallback: Instance Number), and computes Z spacing from IPP deltas.
- Validates single-channel 16-bit geometry consistency and assembles a contiguous volume buffer (signed/unsigned preserved).
- Progress callback per slice and lightweight `DicomSeriesVolume` with voxels, spacing, orientation matrix, origin, rescale parameters, and description.

### Image Processing

- Window/Level with medical presets (CT, mammography, PET, and more)
- Automatic preset suggestions based on modality and body part
- Quality metrics (SNR, contrast, dynamic range)
- Basic helpers for contrast stretching and noise reduction
- Hounsfield Unit conversions for CT images

### Modern APIs

- **Swift-idiomatic throwing initializers** for type-safe error handling
- **Type-safe DicomTag enum** for metadata access (preferred over raw hex values)
- **Type-safe value types** (WindowSettings, PixelSpacing, RescaleParameters) with Codable support
- **Quantitative pixel values** exposing stored, modality-transformed, and physical values for RWV maps and PET SUV workflows
- **V2 APIs** returning structs instead of tuples for better type safety
- **Async/await** support on all supported platforms with async throwing
  initializers and cooperative cancellation before and after synchronous decoder
  work; a header parse cancelled midway throws `CancellationError` and leaves no
  partially loaded decoder (Isis #2517)
- **Static factory methods** for alternative initialization patterns
- **Validation** before loading
- **Convenience metadata helpers** (patient, study, series)
- **Tag caching** for frequent lookups

### Developer Experience

- Complete documentation with practical examples
- DICOM glossary
- Troubleshooting guide for common issues
- Tests covering parsing and series loading

---

## Performance

Clinical codec, partial-decode, and JPIP performance evidence uses the
correctness-first #1436 manifest and reporter under
`Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalPerformanceBudgetManifest.json`
and `Tests/DicomCoreTests/PerformanceBenchmarks/`. The integrated Isis runner
adds MTK and JP3D tiers and emits host/mode/fixture-specific JSON, CSV, and
Markdown; see `DISTRIBUTION.md`.

The active JPIP interoperability profile and its opt-in external reference
reconstruction harness are documented in
`DISTRIBUTION.md`. JPP/JPT message streams remain
rejected until a bounded T.808 databin parser and cache are implemented.

The opt-in encapsulated-frame assembly benchmark compares per-fragment intermediate `Data` values with direct range
appends, including p50/p95 and transient-memory metrics. Its reproducible command and metric definitions live in the
DocC `PerformanceGuide` under “Encapsulated Frame Assembly Benchmark.”

The in-memory DICOMweb STOW helper validates every part header before capacity
planning: the media type must be bare `application/dicom` (ASCII,
case-insensitive) and each non-`nil` transfer syntax must be a canonical ASCII
DICOM UID of at most 64 bytes. For recognizable Part 10 payloads, the helper
reads Transfer Syntax UID from File Meta Information: a `nil` value derives the
MIME parameter, while an explicit value must match. Invalid File Meta Information
and mismatches fail with indexed typed errors before transport. Non-Part-10 data
remains opaque: `nil` omits the parameter and a valid explicit UID is treated as
the caller's assertion. The initializer retains its Explicit VR Little Endian
default; callers storing compressed or otherwise different Part 10 data pass its
matching UID or `nil` to request derivation. Accepted payload bytes are preserved
exactly.
File-backed `storeInstances(files:)` and batched `storeFiles` use a separate,
fixed 64 KiB limit on the bytes declared by File Meta Information Group Length.
Excessive lengths fail with `invalidStorePart10FileMeta(instanceIndex:)` after
only the fixed 144-byte prefix has been read, even when the file and staging
budgets allow more. Accepted preflight reads at most 65,688 bytes (144-byte
prefix, 65,536-byte group and eight-byte dataset lookahead); truncated or
inconsistent groups and overlong UIDs produce the same indexed error. Payloads
continue to stream from the original files into the staged request unchanged.
Invalid files fail individually in `storeFiles`, while valid neighbours retain
their order and batching. Staging files are removed on success or failure.

The helper then checks the exact complete multipart byte count for overflow and
against `maximumSTOWRequestBodyBytes` before allocation. The default is 128 MiB;
callers that deliberately accept higher in-memory usage can opt up, including to
`Int.max` for the former address-space-only behavior. The accepted size includes
boundaries, MIME headers, per-part `Content-Length`, CRLF framing, and payloads.
The request declares the same exact top-level `Content-Length`. WADO instance
responses declare top-level and per-part lengths plus the retrieved resource's
`Content-Location` and stored transfer syntax. The multipart parser consumes an
exact declared part length and rejects mismatches or, for legacy peers that omit
the length/location headers, recognizes only a CRLF-prefixed delimiter line.
The in-memory server derives the stored syntax from Part 10 File Meta Information
so a later WADO response cannot relabel compressed bytes as the default syntax.
The helper profile omits multipart `start`; received `start`/`Content-ID` root
resolution is not implemented. The helper reserves the final `Data` once and honors
cancellation before its large allocation. Run
`Scripts/benchmark_stow_multipart.sh` for isolated legacy/preallocated Release
timing, explicit component-buffer, body-hash, and peak-RSS evidence. The Isis
application uses its separate file-backed streaming uploader for production
STOW-RS sends.

`DicomWebClient.storeInstances(files:)` stages its multipart body on disk and
copies source files in 64 KiB reads. On platforms with Objective-C, each read
and its synchronous sink write run inside an autorelease pool that drains
before the next read. Other platforms use the same bounded read loop without
Objective-C APIs. Framing, File Meta-derived transfer syntax, cancellation and
staging cleanup keep their existing contracts. The file-backed loopback test
and measurement recipe are documented in
[the STOW benchmark guide](DISTRIBUTION.md).

### Window/Level Processing Performance

The library uses **vDSP** (Accelerate framework) as the baseline CPU implementation for window/level operations. vDSP leverages hand-tuned **ARM NEON assembly** for SIMD operations, providing optimal CPU performance on Apple Silicon and Intel processors.

For applications requiring higher throughput, **Metal GPU acceleration** delivers significant performance gains over the vDSP baseline:

| Image Size | vDSP (CPU) | Metal (GPU) | Speedup |
|------------|------------|-------------|---------|
| 512×512    | 2.14 ms    | 1.16 ms     | 1.84×   |
| 1024×1024  | 8.67 ms    | 2.20 ms     | **3.94×** |

**Benchmark Environment:**
- Hardware: Apple M4 (2024)
- OS: macOS 26+
- Iterations: 100 (after 20 warmup iterations)
- Algorithm: Window/level transformation on 16-bit grayscale DICOM pixels

**Key Findings:**
- **vDSP baseline is optimal** - Uses ARM NEON assembly; further CPU SIMD optimizations yield negligible gains
- **Metal GPU shines on larger images** - 3.94× speedup on 1024×1024 images (typical CT/MRI size)
- **Small images favor CPU** - 512×512 images show 1.84× speedup due to GPU setup overhead
- **Production recommendation** - Use `.auto` mode for automatic backend selection, or choose `.metal`/`.vdsp` explicitly

**Usage:**

Metal GPU acceleration is integrated into `DCMWindowingProcessor.applyWindowLevel()` via the `processingMode` parameter:

```swift
// Default behavior (backward compatible) - uses vDSP
let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 50.0,
    width: 400.0
)

// Explicit Metal GPU acceleration
let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 50.0,
    width: 400.0,
    processingMode: .metal  // Force GPU (falls back to vDSP if unavailable)
)

// Automatic selection (recommended)
let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 50.0,
    width: 400.0,
    processingMode: .auto  // Auto-selects Metal for ≥800×800 images
)
```

For more examples, see the windowing snippets in this README and the runnable code under `MetalBenchmark/`.

**Benchmark notes:** The benchmark harness used for these measurements lives in `MetalBenchmark/`, so the performance setup can be inspected and reproduced directly from this repository. Rerun benchmarks on the target hardware before making release or clinical-performance claims.

---

## Quick Start

### Fast Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ThalesMMS/DICOM-Swift.git", exact: "2.0.0-rc.2")
]
```

Link the `DicomCore` product for DICOM parsing and reusable media-attachment
dataset authoring. Applications that play encoded DICOM video or convert Apple
encoder output from AVCC to Annex-B can additionally link the optional
`DicomAppleMedia` product. Keeping that product separate means core-only and
metadata-only integrations do not acquire AVFoundation or CoreMedia APIs.

### DICOMweb without codecs or a server

Select the `DicomWebClient` product for QIDO/WADO/STOW. Its only toolkit target
dependency is `DicomData`; it uses Foundation for HTTP and file streaming. It
does not compile Core, codecs, DIMSE, the listener, ZIPFoundation, SwiftUI or
Metal. SwiftPM can still resolve package-level dependencies. If your code uses
datasets or writers directly, also select and import `DicomData` explicitly.
The deployment floor remains Apple OS 26, with Swift tools 6.2 and Swift 6.

```swift
import DicomWebClient
import DicomData
import Foundation

let client = DicomWebClient(configuration: .init(baseURL: archiveURL))
let page = try await client.search(parameters: .init(level: .study, limit: 20))
let wire = try await client.searchResponse(parameters: .init(level: .study, limit: 20))
let sink = try DicomWebFileRetrieveSink(directory: stagingDirectory)
try await client.retrieveInstance(studyInstanceUID: studyUID, seriesInstanceUID: seriesUID,
                                  sopInstanceUID: instanceUID, sink: sink)
let results = await client.storeFiles(files)
```

`page` uses canonical datasets. `wire` retains bounded response bytes, status
and headers when a host needs the original JSON document (including members
or values normalized by dataset decoding). Metadata BulkData references remain
explicit; parsing JSON/XML does not fetch them. File-backed STOW preserves
encoded pixels without decoding or transcoding.

Inject `DicomWebHTTPTransport` to apply host credentials, staging budgets and
HTTP policy; implement its `stream` method for backpressure. Its send-based
fallback can buffer responses. The Foundation default preserves system TLS
trust and refuses unsupported `connectAddress` with
`DicomWebClientError.unsupportedConnectAddress`; set `followsRedirects` explicitly
for hosts that refuse redirects. Credential storage/renewal stays in the host.

`DicomCore` reexports the client for its server and workflow consumers. UPS and
codec-dependent frame negotiation remain in Core. The repository's existing
`Tools/Scripts/validate_toolkit_consumers.sh --dicomweb-only` check runs a public
consumer in Debug and Release and inspects its isolated build outputs.

### First Example (Modern API)

```swift
import DicomCore

do {
    // Load DICOM file with throwing initializer (recommended)
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")

    print("Dimensions: \(decoder.width) x \(decoder.height)")

    // Recommended: Use type-safe DicomTag enum
    print("Modality: \(decoder.info(for: .modality))")
    print("Patient: \(decoder.info(for: .patientName))")

    // Legacy (deprecated): Raw hex values (still supported for custom/private tags)
    // print("Modality: \(decoder.info(for: 0x00080060))")

    if let pixels = decoder.getPixels16() {
        print("\(pixels.count) pixels loaded")
    }
} catch DICOMError.fileNotFound(let path) {
    print("File not found: \(path)")
} catch DICOMError.invalidDICOMFormat(let path, let reason) {
    print("Invalid DICOM file: \(reason)")
} catch {
    print("Error: \(error)")
}
```

**Alternative patterns:**

```swift
// Static factory method
let decoder = try DCMDecoder.load(fromFile: "/path/to/image.dcm")

// Async for non-blocking load
let decoder = try await DCMDecoder(contentsOfFile: "/path/to/image.dcm")

// URL-based initialization
let url = URL(fileURLWithPath: "/path/to/image.dcm")
let decoder = try DCMDecoder(contentsOf: url)
```

For a detailed walkthrough, see [GETTING_STARTED.md](GETTING_STARTED.md) and [USAGE_EXAMPLES.md](USAGE_EXAMPLES.md).

### Bounded Metadata Dataset Parsing

`DicomDataSetParser` applies `DicomDataSetParseLimits.default` when no policy is supplied. Custom limits are useful
for a trusted workflow with a known dataset shape or for a stricter network boundary:

```swift
let limits = DicomDataSetParseLimits(
    maximumSequenceDepth: 32,
    maximumElementCount: 250_000,
    maximumItemCount: 100_000
)
let dataSet = try DicomDataSetParser.dataSet(
    from: encodedDataSet,
    transferSyntax: .explicitVRLittleEndian,
    limits: limits
)
```

Depth starts at zero for the root dataset. Element and sequence-item counts are cumulative across all nested items,
and each configured maximum is inclusive. The Storage SCP uses the same default policy unless
`DicomStorageSCPConfiguration.dataSetParseLimits` supplies another budget.

### Safe Part 10 Metadata Rewrite

`DicomPart10Rewriter` applies typed top-level `DicomDataElement` replacements
and exact recursive UID-value mappings. It rejects unknown transfer syntaxes
and pixel-structure edits, preserves the source transfer syntax and SOP Class,
copies native or encapsulated Pixel Data byte-for-byte, then reopens and
validates the result before returning it. Deflated sources preserve the
inflated Pixel Data value; the zlib stream itself can be re-encoded.

```swift
let result = try DicomPart10Rewriter().rewrite(
    sourceData,
    replacing: [DicomDataElement(
        tag: DicomTag.patientID.rawValue,
        vr: .LO,
        value: .strings(["UPDATED-ID"])
    )],
    uidValueReplacements: [oldStudyUID: newStudyUID]
)
try result.fileData.write(to: destinationURL)
```

### Type-Safe Metadata Access

The library provides a **type-safe `DicomTag` enum** for accessing DICOM metadata, eliminating the need for raw hex values:

```swift
// Recommended: Type-safe and discoverable via autocomplete
let patientName = decoder.info(for: .patientName)
let modality = decoder.info(for: .modality)
let studyUID = decoder.info(for: .studyInstanceUID)
let rows = decoder.intValue(for: .rows) ?? 0
let windowCenter = decoder.doubleValue(for: .windowCenter)

// Legacy (deprecated): Raw hex values (still supported for custom/private tags)
let customTag = decoder.info(for: 0x00091001)  // Private tag
```

**Benefits:**
- **Type safety** - Compiler-checked tag names
- **Discoverability** - Autocomplete shows all available tags
- **Readability** - Semantic names instead of hex codes
- **Backward compatible** - Raw hex values still work for custom/private tags

See [Common DICOM Tags](#common-dicom-tags) for a full list of supported tags.

### Type-Safe Value Types (V2 APIs)

The library provides dedicated structs for common DICOM parameters, offering better type safety and Codable conformance than tuple-based APIs:

```swift
// Window settings as a struct (recommended)
let settings = decoder.windowSettingsV2  // WindowSettings struct
if settings.isValid {
    print("Window: center=\(settings.center), width=\(settings.width)")
}

// Pixel spacing as a struct (recommended)
let spacing = decoder.pixelSpacingV2  // PixelSpacing struct
if spacing.isValid {
    print("Spacing: \(spacing.x) × \(spacing.y) × \(spacing.z) mm")
}

// Rescale parameters as a struct (recommended)
let rescale = decoder.rescaleParametersV2  // RescaleParameters struct
if !rescale.isIdentity {
    let hounsfieldValue = rescale.apply(to: pixelValue)
}

// V2 windowing methods return WindowSettings
let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)
let preset = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)

// Legacy (deprecated): Tuple-based APIs (deprecated but still supported)
let (center, width) = decoder.windowSettings  // Returns tuple
```

**Benefits of V2 APIs:**
- **Type safety** - Structs prevent parameter order mistakes
- **Codable support** - Serialize to JSON for persistence
- **Sendable conformance** - Safe across concurrency boundaries
- **Computed properties** - `.isValid`, `.isIdentity` checks
- **Methods** - `.apply(to:)` for transformations
- **Better autocomplete** - Named properties instead of tuple labels

See [USAGE_EXAMPLES.md](USAGE_EXAMPLES.md#type-safe-value-types-v2-apis) for detailed migration examples.

---

## Installation

### Via Xcode

1. File -> Add Packages...
2. Paste `https://github.com/ThalesMMS/DICOM-Swift.git`
3. Select version `1.0.0` or later
4. Add Package

### Via Package.swift

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/ThalesMMS/DICOM-Swift.git", exact: "2.0.0-rc.2")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "DicomCore", package: "DICOM-Swift")
        ]
    )
]
```

### Requirements

- Swift 6.2+ toolchain. DICOM-Swift targets compile in Swift 6 language mode, which enables complete
  strict-concurrency checking; consuming targets retain their own language-mode setting.
- iOS 26.0+, visionOS 26.0+, or macOS 26.0+
- Xcode 26.0+

---

## Usage Examples

### 1. Basic Reading

```swift
import DicomCore

do {
    // Recommended: Use throwing initializer
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

    // Use type-safe DicomTag enum for metadata access
    print("Patient: \(decoder.info(for: .patientName))")
    print("Modality: \(decoder.info(for: .modality))")
    print("Dimensions: \(decoder.width) x \(decoder.height)")

    if let pixels = decoder.getPixels16() {
        // Process image...
    }
} catch {
    print("Load error: \(error)")
}
```

### 2. Async/Await

```swift
func loadDICOM() async {
    do {
        let decoder = try await DCMDecoder(contentsOfFile: "/path/to/image.dcm")

        if let pixels = await decoder.getPixels16Async() {
            await showImage(pixels, decoder.width, decoder.height)
        }
    } catch {
        print("Error: \(error)")
    }
}
```

### 3. Window/Level with Medical Presets

```swift
guard let pixels = decoder.getPixels16() else { return }

// Use type-safe DicomTag enum
let modality = decoder.info(for: .modality)
let suggestions = DCMWindowingProcessor.suggestPresets(for: modality)

let lungPreset = DCMWindowingProcessor.getPresetValues(preset: .lung)
let lungImage = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels,
    center: lungPreset.center,
    width: lungPreset.width
)

if let optimal = decoder.calculateOptimalWindow() {
    let optimizedImage = DCMWindowingProcessor.applyWindowLevel(
        pixels16: pixels,
        center: optimal.center,
        width: optimal.width
    )
}
```

### 4. Validate Before Loading

```swift
let tempDecoder = DCMDecoder()
let validation = tempDecoder.validateDICOMFile("/path/to/image.dcm")

if !validation.isValid {
    print("Invalid file:")
    for issue in validation.issues {
        print("  - \(issue)")
    }
    return
}

let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")
```

### 5. Structured Metadata

```swift
let patient = decoder.getPatientInfo()
let study = decoder.getStudyInfo()
let series = decoder.getSeriesInfo()
```

### 6. Fast Thumbnail

```swift
if let thumb = decoder.getDownsampledPixels16(maxDimension: 150) {
    let thumbWindowed = DCMWindowingProcessor.applyWindowLevel(
        pixels16: thumb.pixels,
        center: 40.0,
        width: 80.0
    )
}
```

### 7. Quality Metrics

```swift
if let metrics = decoder.getQualityMetrics() {
    print("Image quality:")
    print("  Mean: \(metrics["mean"] ?? 0)")
    print("  Standard deviation: \(metrics["std_deviation"] ?? 0)")
    print("  SNR: \(metrics["snr"] ?? 0)")
    print("  Contrast: \(metrics["contrast"] ?? 0)")
    print("  Dynamic range: \(metrics["dynamic_range"] ?? 0) dB")
}
```

### 8. Hounsfield Units (CT)

```swift
let pixelValue: Double = 1024.0
let hu = decoder.applyRescale(to: pixelValue)

if hu < -500 {
    print("Likely air or lung")
} else if hu > 700 {
    print("Likely bone")
}
```

More examples: [USAGE_EXAMPLES.md](USAGE_EXAMPLES.md).

---

## Command-Line Tool

`dicomtool ldap --config directory-policy.json --username alice` is an optional
LDAPv3 authentication and authorization consumer. Passwords arrive through a pipe
on stdin, never arguments or configuration JSON. LDAPS validates the peer through
the existing TLS factory; plaintext is restricted to explicit numeric loopback.
`DicomLDAPAuthenticationService` accepts injected identity mapping, authorizer and
audit recorder. Group membership without a configured grant denies. See the
parent repository's [profile and independent recipe](DISTRIBUTION.md)
for limits, synthetic OpenLDAP evidence and the host credential-store boundary.
No directory is contacted by other CLI commands or application startup.

DIMSE servers default to `bindAddress = ""` (all interfaces). Server exposure
policies are optional for legacy compatibility; hosts exposed beyond loopback
MUST supply a `DicomExposurePolicy`. The product and `dicomtool` supply policies.
The CLI defaults to `127.0.0.1` with `.localOnly`; `--intranet-lab` explicitly
opts into laboratory exposure, and other non-loopback binds require TLS and
authentication. Explicit binds retain the configured host when port `0` lets the
system select an ephemeral port.
The HTTP listener retains its legacy `loopbackOnly` configuration default.

QIDO searches fetch provider pages of at most 128 candidates and apply the requested
offset only to authorized results. `maximumSearchResults` caps the response, while
`maximumSearchCandidates` caps all examined rows, including denied rows and the
lookahead used for Warning 299 (default 10,000). A request that exhausts this budget
returns HTTP 413 and must be narrowed. Storage providers must honor finite limits
after matching and deduplication, with stable ordering while their contents are unchanged.
The in-memory and directory providers maintain search ordering and aggregate counts
on insertion so a small page does not materialize the complete matching result set.

The `dicomtool` command-line utility provides fast DICOM file inspection, validation, and image export capabilities for developer workflows, scripting, and CI integration.

### Installation

**Homebrew formula:**

```bash
# From the repository checkout
brew install ./dicomtool.rb
```

**Build from source:**

```bash
git clone https://github.com/ThalesMMS/DICOM-Swift.git
cd DICOM-Swift
swift build -c release
cp .build/release/dicomtool /usr/local/bin/
```

### Quick Reference

```bash
# Inspect DICOM metadata
dicomtool inspect image.dcm

# Validate DICOM file conformance
dicomtool validate image.dcm

# Extract image with lung preset
dicomtool extract ct.dcm --output lung.png --preset lung

# Export every frame to predictable files
dicomtool extract perfusion.dcm --output ./frames --all-frames --metadata

# Batch process directory
dicomtool batch --pattern "*.dcm" --operation validate --format json

# Shared codec workflow (same engine/renderers as the app adapter)
dicomtool codec inspect image.dcm --format json
dicomtool codec decode image.dcm --frames 0,2 --output pixels.raw
dicomtool codec transcode image.dcm \
  --transfer-syntax 1.2.840.10008.1.2.4.90 --output encoded.dcm
```

### Commands

#### `codec` - Shared Codec and Transcoding Workflow

`codec capabilities`, `inspect`, `validate`, `decode`, `compare`, and
`transcode` are thin CLI adapters over `DicomCodecWorkflowEngine`. Operations
use in-memory artifacts and the same stable, PHI-free text/JSON renderers as
the Isis AppShell adapter. Decode can select frames; compare runs exact
candidate/oracle decoded-pixel parity for JPEG-LS and JPEG 2000/HTJ2K;
transcode writes and validates a complete Part 10 artifact. `DicomCodecCapabilities.resolve` returns
profile-specific preserve/decode/encode decisions with stable refusal reasons and separate production/shadow
qualification. `capabilities --file` uses that file's pixel metadata; without a file it explicitly probes
2×2 unsigned 8-bit MONOCHROME2 with reversible intent. General `.91`, `.203`, and `.112` UIDs do not
imply lossy intent.

Strict legacy decoder preferences are resolved before automatic backend selection.
In J2KSwift `preferred` mode, unsupported candidate features can retry qualified
OpenJPEG when fallback is allowed; corrupt-stream errors and cancellation propagate
without retrying, and strict requests never switch backends.

```bash
dicomtool codec capabilities --format json
dicomtool codec capabilities --file image.dcm --format json
dicomtool codec validate image.dcm
dicomtool codec compare image.dcm --frame 0 --format json
dicomtool codec transcode image.dcm --transfer-syntax 1.2.840.10008.1.2 \
  --output native.dcm
```

Exit states are `64` for unsupported/invalid arguments, `65` for invalid or
corrupt DICOM/validation failures, `69` for unavailable backends, `70` for
unexpected failures, and `74` for artifact I/O failures. The Isis repository
documents the parity contract in `DISTRIBUTION.md`.

#### `inspect` - Extract Metadata

Display DICOM metadata in human-readable or JSON format.

```bash
# Show common metadata tags
dicomtool inspect image.dcm

# Show all available tags
dicomtool inspect image.dcm --all

# Show specific tags
dicomtool inspect image.dcm --tags PatientName,Modality,StudyDate

# JSON output for scripting
dicomtool inspect image.dcm --format json
```

**Example output (text):**

```text
DICOM File: image.dcm
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Patient Information:
  Patient Name:     DOE^JOHN
  Patient ID:       12345
  Patient Birth:    1970-01-01

Study Information:
  Study Date:       2024-01-15
  Study Description: CT Chest with Contrast
  Modality:         CT

Image Properties:
  Dimensions:       512 × 512
  Bits Allocated:   16
  Pixel Spacing:    0.742 × 0.742 mm
```

#### `validate` - DICOM Conformance

Validate DICOM file structure and report issues.

```bash
# Validate single file
dicomtool validate image.dcm

# JSON output with detailed errors
dicomtool validate image.dcm --format json
```

**Example output:**

```text
✓ Valid DICOM file: image.dcm

Validation Results:
  • File size: 524,288 bytes
  • DICOM prefix: Present
  • Transfer syntax: 1.2.840.10008.1.2.1 (Explicit VR Little Endian)
  • Required tags: Complete
```

#### `extract` - Export Images

Extract pixel data with medical windowing presets or custom parameters. Supported output formats are PNG, JPEG, and TIFF; TIFF can preserve unsigned 16-bit stored samples when requested.

**Medical presets available:**
- `lung` - Lung tissue (-600/1500 HU)
- `bone` - Bone structures (400/1800 HU)
- `brain` - Brain tissue (40/80 HU)
- `softtissue` - Soft tissue (50/350 HU)
- `liver` - Liver imaging (80/150 HU)
- `mediastinum` - Mediastinum (50/350 HU)
- `abdomen` - Abdominal organs (60/400 HU)
- `spine` - Spine imaging (40/400 HU)
- `pelvis` - Pelvic structures (40/400 HU)
- `angiography` - Vascular imaging (300/600 HU)
- `pulmonaryembolism` - PE protocol (100/700 HU)
- `mammography` - Breast imaging (50/500 HU)
- `petscan` - PET imaging (0/5000)

```bash
# Extract with medical preset
dicomtool extract ct.dcm --output lung.png --preset lung

# Custom window/level
dicomtool extract ct.dcm --output custom.png \
  --window-center 50 --window-width 400

# Automatic optimal windowing
dicomtool extract ct.dcm --output auto.png

# JPEG export with explicit quality
dicomtool extract ct.dcm --output preview.jpg \
  --format jpeg --jpeg-quality 0.9

# TIFF export preserving unsigned 16-bit stored samples
dicomtool extract ct.dcm --output native.tiff \
  --format tiff --preserve-16-bit

# Export all frames with predictable names and non-PHI metadata sidecars
dicomtool extract perfusion.dcm --output ./frames \
  --all-frames --metadata

# Overwrite existing file
dicomtool extract ct.dcm --output result.png --overwrite
```

**Frame and metadata options:**
- `--frame <index>` exports one zero-based frame; default is frame 0.
- `--all-frames` treats `--output` as a directory and writes `base_frame0001.ext`, `base_frame0002.ext`, and so on.
- `--metadata` writes a JSON sidecar next to each image with non-PHI image attributes such as dimensions, frame number, modality, spacing, and display window.

#### `batch` - Batch Processing

Process multiple DICOM files using glob patterns with concurrent execution.

```bash
# Inspect all DICOM files in directory
dicomtool batch --pattern "*.dcm" --operation inspect

# Validate all files recursively with JSON output
dicomtool batch --pattern "**/*.dcm" --operation validate --format json

# Extract all files with lung preset to exports directory
dicomtool batch --pattern "studies/*/*.dcm" --operation extract \
  --output-dir ./exports --preset lung --image-format png

# Export all frames and sidecars during batch extraction
dicomtool batch --pattern "studies/*/*.dcm" --operation extract \
  --output-dir ./frames --all-frames --metadata --image-format jpeg

# Sequential processing (no concurrency)
dicomtool batch --pattern "*.dcm" --operation inspect --max-concurrent 1

# Custom windowing for batch extraction
dicomtool batch --pattern "*.dcm" --operation extract \
  --output-dir ./out --window-center 40 --window-width 80
```

**Glob pattern examples:**
- `*.dcm` - All .dcm files in current directory
- `**/*.dcm` - All .dcm files recursively
- `study_*/series_*/*.dcm` - Complex patterns with wildcards
- `{CT,MR}/*.dcm` - Multiple alternatives (brace expansion)

**Example output:**

```text
Processing 48 files with pattern: *.dcm
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Progress: [████████████████████] 48/48 (100%)

Summary:
  Total files:   48
  Successful:    46
  Failed:        2
  Duration:      3.2s

Failed files:
  • corrupt.dcm: Invalid DICOM format
  • partial.dcm: Unexpected EOF
```

### Use Cases

**Developer workflows:**

```bash
# Quick file inspection during debugging
dicomtool inspect mysterious_file.dcm

# Verify DICOM conformance before processing
if dicomtool validate input.dcm --format json | jq -e '.valid'; then
  echo "Processing valid DICOM file"
fi

# Generate preview images for web display
dicomtool batch --pattern "series/*.dcm" --operation extract \
  --output-dir ./previews --preset softtissue
```

**CI/CD integration:**

```bash
#!/bin/bash
# Validate DICOM test fixtures in CI pipeline

echo "Validating DICOM test files..."
if dicomtool batch --pattern "tests/fixtures/**/*.dcm" \
                    --operation validate \
                    --format json > validation.json; then
  echo "✓ All DICOM files valid"
  exit 0
else
  echo "✗ DICOM validation failed"
  cat validation.json | jq '.errors'
  exit 1
fi
```

**Batch conversion scripts:**

```bash
#!/bin/bash
# Convert hospital study archive to PNG previews

for study_dir in /mnt/pacs/studies/*; do
  study_id=$(basename "$study_dir")
  echo "Processing study: $study_id"

  dicomtool batch \
    --pattern "$study_dir/**/*.dcm" \
    --operation extract \
    --output-dir "./previews/$study_id" \
    --preset softtissue \
    --max-concurrent 8
done
```

**Research data validation:**

```bash
# Validate and report on research dataset
dicomtool batch --pattern "dataset/**/*.dcm" \
                --operation validate \
                --format json | \
  jq -r '.results[] | select(.valid == false) | .file' > invalid_files.txt

echo "Found $(wc -l < invalid_files.txt) invalid files"
```

### JSON Output Format

All commands support `--format json` for programmatic parsing:

```json
{
  "file": "image.dcm",
  "valid": true,
  "metadata": {
    "PatientName": "DOE^JOHN",
    "Modality": "CT",
    "StudyDate": "20240115",
    "Rows": "512",
    "Columns": "512"
  }
}
```

### Performance

- **Concurrent processing**: Default 4 concurrent operations (configurable with `--max-concurrent`)
- **Memory efficient**: Processes files individually, no bulk loading
- **Frame-addressable export**: Extract operations can write one frame or all frames without bulk series loading

### Requirements

- macOS 26.0+
- Swift 6.2+
- Xcode 26.0+ (for building from source)

---


## SwiftUI Components

The library includes **DicomSwiftUI**, a complete set of pre-built SwiftUI components for building DICOM medical image viewers with minimal code.
> Requires iOS 26+ / visionOS 26+ / macOS 26+.

### Available Components

| Component | Description | Key Features |
|-----------|-------------|--------------|
| **DicomImageView** | Display DICOM images | Automatic scaling, windowing modes, GPU acceleration |
| **WindowingControlView** | Interactive window/level controls | 13 medical presets, sliders, automatic optimization |
| **SeriesNavigatorView** | Navigate DICOM series | Slice navigation, progress indicator, thumbnail strip, keyboard shortcuts |
| **MetadataView** | Display DICOM metadata | Organized sections, formatted values, accessibility |

### Installation

Add DicomSwiftUI to your SwiftUI project:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/ThalesMMS/DICOM-Swift.git", exact: "2.0.0-rc.2")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "DicomSwiftUI", package: "DICOM-Swift")
        ]
    )
]
```

```swift
import SwiftUI
import DicomSwiftUI
```

### Quick Start Examples

#### 1. Basic DICOM Image Display

Display a DICOM image with automatic windowing:

```swift
import SwiftUI
import DicomSwiftUI

struct ContentView: View {
    let dicomURL: URL

    var body: some View {
        DicomImageView(url: dicomURL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**Features:**
- Automatic file loading
- Optimal window/level calculation
- Aspect ratio preservation
- Loading and error states

#### 2. Interactive Windowing Controls

Add medical preset buttons and interactive sliders:

```swift
struct DicomViewerView: View {
    let dicomURL: URL
    @StateObject private var imageViewModel = DicomImageViewModel()
    @StateObject private var windowingViewModel = WindowingViewModel()

    var body: some View {
        VStack {
            // Display image
            DicomImageView(url: dicomURL, viewModel: imageViewModel)

            // Windowing controls with presets
            if let decoder = imageViewModel.decoder {
                WindowingControlView(
                    decoder: decoder,
                    viewModel: windowingViewModel,
                    onWindowChange: { center, width in
                        imageViewModel.updateWindowing(.custom(center: center, width: width))
                    }
                )
            }
        }
    }
}
```

**Available presets:**
- **CT**: Lung, Bone, Brain, Liver, Mediastinum, Abdomen, Spine, Pelvis
- **Specialized**: Angiography, Pulmonary Embolism, Mammography, PET Scan

#### 3. Series Navigation

Navigate through multi-slice DICOM series:

```swift
struct SeriesViewerView: View {
    let seriesURLs: [URL]
    @State private var currentIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            // Display current slice
            DicomImageView(url: seriesURLs[currentIndex])
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Navigation controls
            SeriesNavigatorView(
                currentIndex: $currentIndex,
                totalCount: seriesURLs.count,
                onNavigate: { newIndex in
                    // Optional: Preload adjacent slices
                    preloadSlice(at: newIndex)
                }
            )
            .frame(height: 80)
        }
    }

    func preloadSlice(at index: Int) {
        // Preload logic here
    }
}
```

**Features:**
- First/Previous/Next/Last buttons
- Interactive slider
- Slice counter with progress percentage
- Keyboard shortcuts support

#### 4. Metadata Display

Show formatted DICOM metadata:

```swift
struct MetadataDisplayView: View {
    let dicomURL: URL

    var body: some View {
        VStack(spacing: 0) {
            DicomImageView(url: dicomURL)
                .frame(maxHeight: 400)

            Divider()

            MetadataView(url: dicomURL)
                .frame(maxHeight: 250)
        }
    }
}
```

**Displayed information:**
- **Patient**: Name, ID, Age, Sex, Birth Date
- **Study**: Date, Time, Description, Modality, Study UID
- **Series**: Number, Description, Series UID
- **Image**: Dimensions, Spacing, Position, Window/Level settings

#### 5. Complete DICOM Viewer

Combine all components into a full-featured viewer:

```swift
struct CompleteDicomViewerView: View {
    let seriesURLs: [URL]
    @State private var currentIndex = 0
    @StateObject private var imageViewModel = DicomImageViewModel()
    @StateObject private var windowingViewModel = WindowingViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Main image display
            DicomImageView(
                url: seriesURLs[currentIndex],
                viewModel: imageViewModel,
                windowingMode: .custom(
                    center: windowingViewModel.center,
                    width: windowingViewModel.width
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Metadata panel
            MetadataView(url: seriesURLs[currentIndex])
                .frame(height: 150)

            Divider()

            // Windowing controls
            if let decoder = imageViewModel.decoder {
                WindowingControlView(
                    decoder: decoder,
                    viewModel: windowingViewModel,
                    layout: .compact,
                    onWindowChange: { center, width in
                        imageViewModel.updateWindowing(.custom(center: center, width: width))
                    }
                )
                .padding()
            }

            Divider()

            // Series navigation
            SeriesNavigatorView(
                currentIndex: $currentIndex,
                totalCount: seriesURLs.count
            )
            .frame(height: 80)
        }
    }
}
```

### Windowing Modes

DicomImageView supports multiple windowing strategies:

```swift
// Automatic optimal window calculation
DicomImageView(url: dicomURL, windowingMode: .automatic)

// Medical preset (13 presets available)
DicomImageView(url: dicomURL, windowingMode: .preset(.lung))
DicomImageView(url: dicomURL, windowingMode: .preset(.bone))
DicomImageView(url: dicomURL, windowingMode: .preset(.brain))

// Custom window/level values
DicomImageView(url: dicomURL, windowingMode: .custom(center: 50.0, width: 400.0))

// Use window/level from DICOM file tags
DicomImageView(url: dicomURL, windowingMode: .fromDecoder)
```

### GPU Acceleration

Enable GPU acceleration for large images:

```swift
// Automatic selection (recommended)
DicomImageView(
    url: dicomURL,
    processingMode: .auto  // Uses Metal for ≥800×800 images
)

// Force GPU processing
DicomImageView(
    url: dicomURL,
    processingMode: .metal  // Always use Metal (falls back to vDSP if unavailable)
)

// Force CPU processing
DicomImageView(
    url: dicomURL,
    processingMode: .vdsp  // Always use vDSP (Accelerate framework)
)
```

**Performance benefits:**
- 3.94× speedup for 1024×1024 images on Apple Silicon
- Automatic fallback to vDSP if Metal unavailable
- See [Performance](#performance) section for benchmarks

### Customization

All components support customization:

```swift
// Custom styling
DicomImageView(url: dicomURL)
    .background(Color.black)
    .cornerRadius(8)
    .shadow(radius: 4)

// Compact layout
WindowingControlView(decoder: decoder, layout: .compact)

// Expanded layout with more controls
WindowingControlView(decoder: decoder, layout: .expanded)

// Custom error handling
DicomImageView(url: dicomURL)
    .overlay {
        if let error = viewModel.error {
            ErrorView(error: error)
        }
    }
```

### Accessibility & Dark Mode

All components include comprehensive accessibility support:

- VoiceOver labels and hints
- Dynamic Type text scaling
- Keyboard navigation support
- Dark mode adaptive colors
- High contrast compatibility
- Reduced motion preferences

### Example Application

A complete reference implementation is available in `Examples/DicomSwiftUIExample/`:

```bash
# Run the example app
swift run DicomSwiftUIExample
```

**Demonstrates:**
- All four SwiftUI components
- Multiple windowing modes (automatic, presets, custom, GPU)
- Series loading and navigation
- Metadata display with different layouts
- Dark mode and accessibility features

See [Examples/DicomSwiftUIExample/README.md](Examples/DicomSwiftUIExample/README.md) for detailed usage.

### Documentation

- **Getting Started**: `Sources/DicomSwiftUI/DicomSwiftUI.docc/GettingStarted.md`
- **API Reference**: Run `swift package generate-documentation --target DicomSwiftUI --warnings-as-errors`
- **Code Samples**: `Sources/DicomSwiftUI/DicomSwiftUI.docc/Resources/code-samples/`
- **Example App**: `Examples/DicomSwiftUIExample/`

### Platform Support

- **Core and SwiftUI**: the package supports iOS 26.0+ / visionOS 26.0+ / macOS 26.0+.
- **Concurrency**: async frame decode uses native async/await and does not bridge through semaphores.

---

## Architecture

### Minimum products and compatibility

`DicomData` owns typed datasets, dictionary resources, text encoding, bounded
metadata parsing, dataset/Part 10 writing and the declarative syntax catalog.
`DicomCodecs` contains the own raw JPEG Extended implementation. `DicomObjects`
contains coded concepts and waveform models/authoring. `DicomNetwork` contains
PDU/command encoding, association state and neutral transport contracts.
Their minimum consumers do not link UI or Raster codec products. The existing
`DicomCore` product reexports these public APIs and retains the remaining adapters;
`DicomAppleMedia` and `DicomSwiftUI` remain optional. Deployment floors are unchanged.
Resolving the package's declared dependencies is distinct from linking a product.

Run `python3 Scripts/validate_target_boundaries.py` to check the evaluated graph,
cycles, minimum imports and linkage. `DicomDataTests`, `DicomCodecsTests`,
`DicomObjectsTests` and `DicomNetworkTests` exercise consumers with only their
selected product; the existing DicomCore suites check compatibility. The extraction
does not claim completed codec internalization or new profile qualification.

### Main Components

| Component | Description | Primary Use |
|-----------|-------------|-------------|
| `DCMDecoder` | Core DICOM decoder | Load files, extract pixels and metadata |
| `DicomVideoRemuxer` | Optional Apple media adapter | Remux encoded DICOM video without re-encoding |
| `DCMWindowingProcessor` | Image processing | Window/level, presets, quality metrics |
| `StudyDataService` | Data service | Scan directories, group studies |
| `DICOMError` | Error system | Typed error handling |
| `DCMDictionary` | Tag dictionary | Map numeric tags to names |

### Workflow

```
1. DICOM file
        |
2. validateDICOMFile() (optional)
        |
3. try DCMDecoder(contentsOfFile:) or try await DCMDecoder(contentsOfFile:)
        |
4. Decoder parses:
   - Header (128 bytes + "DICM")
   - Meta Information
   - Dataset (tags + values)
   - Pixel Data (lazy loading)
        |
5. Access data:
   - info(for: .modality) -> Metadata
   - getPixels16() -> Pixel buffer
   - applyWindowLevel() -> Processed pixels
```

### Project Structure

```
DICOM-Swift/
|-- Package.swift
|-- Sources/DicomData/
|   |-- DicomDataSet.swift        # Typed values and datasets
|   |-- DicomSequenceValueParser.swift # Bounded metadata dataset parser
|   |-- DicomDataSetWriter.swift  # Dataset and Part 10 writing
|   |-- DicomConstants.swift      # DicomTag, VR and syntax identifiers
|   |-- DCMBinaryReader.swift     # Package-scoped primitive reader
|   |-- DCMDictionary.swift       # Tag dictionary
|   |-- Logging/                 # Private-message logging boundary
|   `-- Resources/DCMDictionary-*.plist
|-- Sources/DicomCodecs/
|   `-- JPEGExtendedDecoder.swift # Own precision-preserving raw codec
|-- Sources/DicomObjects/
|   |-- DicomCodedConcept.swift   # Typed coded values
|   `-- DicomWaveform.swift       # Waveform values and authoring
|-- Sources/DicomNetwork/
|   |-- DicomDIMSENetwork.swift   # PDU, command and association contracts
|   `-- DicomUserIdentity.swift   # Association identity negotiation values
|-- Sources/DicomCore/
|   |-- DicomCoreExports.swift    # Compatibility imports for the smaller products
|   |-- DCMDecoder+DataSet.swift  # File decoder to typed dataset adapter
|   |-- DCMDecoder+Waveform.swift # File decoder to waveform adapter
|   |-- DCMDecoder.swift          # Core DICOM parser
|   |-- DCMDecoder+Async.swift    # Async/await extensions
|   |-- DCMWindowingProcessor.swift # Window/level processing
|   |-- MetalWindowingProcessor.swift # GPU-accelerated windowing
|   |-- DCMPixelReader.swift      # Pixel data extraction
|   |-- DCMTagParser.swift        # Tag parsing logic
|   |-- DICOMError.swift          # Typed error definitions
|   |-- DicomSeriesLoader.swift   # Series/volume loading
|   |-- DicomRLELosslessDecoder.swift # Native RLE Lossless decoder
|   |-- DicomJPEGLSCodec.swift    # CharLS JPEG-LS runtime bridge
|   |-- DicomJLSwiftBackend.swift # Package-linked JPEG-LS adapter
|   |-- DicomJXLSwiftBackend.swift # Feature-gated JPEG XL adapter
|   |-- JPEGLosslessDecoder.swift # Native JPEG Lossless decoder
|   |-- PatientModel.swift        # Data model structures
|   |-- StudyDataService.swift    # Study/series grouping
|   |-- ValueTypes.swift          # V2 type-safe value types
|   |-- Protocols/                # Protocol abstractions
|   |-- TagHandlers/              # Per-VR tag handling
|   |-- DicomCore.docc/           # DocC documentation
|   `-- Resources/WindowingShaders.metal.txt
|-- Sources/DicomAppleMedia/
|   |-- DicomVideoRemuxer.swift   # Apple playback-container remuxing
|   `-- DicomAppleMedia.docc/     # Apple media DocC documentation
|-- Tests/DicomDataTests/
|-- Tests/DicomCodecsTests/
|-- Tests/DicomObjectsTests/
|-- Tests/DicomNetworkTests/
|-- Tests/DicomCoreTests/
`-- Tests/DicomAppleMediaTests/
```

### Common DICOM Tags

Use the type-safe `DicomTag` enum for accessing standard DICOM tags:

**Patient Information:**
```swift
.patientName                 // (0010,0010) - Patient Name
.patientID                   // (0010,0020) - Patient ID
.patientBirthDate            // (0010,0030) - Patient Birth Date
.patientSex                  // (0010,0040) - Patient Sex
.patientAge                  // (0010,1010) - Patient Age
```

**Study/Series Information:**
```swift
.studyInstanceUID            // (0020,000D) - Study Instance UID
.seriesInstanceUID           // (0020,000E) - Series Instance UID
.modality                    // (0008,0060) - Modality (CT, MR, XR, etc.)
.studyDescription            // (0008,1030) - Study Description
.seriesDescription           // (0008,103E) - Series Description
```

**Image Properties:**
```swift
.rows                        // (0028,0010) - Rows (height)
.columns                     // (0028,0011) - Columns (width)
.bitsAllocated               // (0028,0100) - Bits Allocated
.bitsStored                  // (0028,0101) - Bits Stored
.pixelRepresentation         // (0028,0103) - Pixel Representation
```

**Spatial Information:**
```swift
.imagePositionPatient        // (0020,0032) - Image Position (Patient)
.imageOrientationPatient     // (0020,0037) - Image Orientation (Patient)
.pixelSpacing                // (0028,0030) - Pixel Spacing
.sliceThickness              // (0018,0050) - Slice Thickness
```

**Window/Level:**
```swift
.windowCenter                // (0028,1050) - Window Center
.windowWidth                 // (0028,1051) - Window Width
.rescaleSlope                // (0028,1053) - Rescale Slope
.rescaleIntercept            // (0028,1052) - Rescale Intercept
```

For custom or private tags not in the enum, use raw hex values:
```swift
let privateTag = decoder.info(for: 0x00091001)  // Private manufacturer tag
```

---

## Documentation

### API Reference

This repository includes DocC documentation sources for `DicomCore`,
`DicomAppleMedia`, and `DicomSwiftUI`.

Generate the API reference locally with:

```bash
swift package generate-documentation --target DicomCore
swift package generate-documentation --target DicomAppleMedia
swift package generate-documentation --target DicomSwiftUI --warnings-as-errors
```

The API reference includes:
- Detailed class and method documentation
- Code examples and usage patterns
- Type definitions and protocols
- Complete symbol index

### Beginner Guides

| Document | Description | Best For |
|----------|-------------|----------|
| [Getting Started](GETTING_STARTED.md) | End-to-end tutorial | New to DICOM |
| [DICOM Glossary](DICOM_GLOSSARY.md) | Terminology reference | Understanding terms |
| [Troubleshooting](TROUBLESHOOTING.md) | Common issues and fixes | Debugging problems |

### Advanced Guides

| Document | Description | Best For |
|----------|-------------|----------|
| [Usage Examples](USAGE_EXAMPLES.md) | Complete, ready-to-use code samples | Copy and adapt |
| [CHANGELOG](CHANGELOG.md) | Release history | Tracking changes |

### Key Concepts

#### Window/Level

Controls brightness and contrast of DICOM images:
- Level (Center): brightness
- Width: contrast

```swift
// Lung: Center -600 HU, Width 1500 HU
// Bone: Center  400 HU, Width 1800 HU
// Brain: Center  40 HU, Width   80 HU
```

#### DICOM Tags

The library provides a type-safe `DicomTag` enum for accessing metadata:

```swift
// Recommended: Type-safe DicomTag enum
decoder.info(for: .patientName)       // Patient Name
decoder.info(for: .modality)          // Modality (CT, MR, etc.)
decoder.info(for: .rows)              // Image height
decoder.intValue(for: .columns)       // Image width (as Int)
decoder.doubleValue(for: .windowCenter)  // Window center (as Double)

// Legacy (deprecated): Raw hex values (still supported for custom/private tags)
decoder.info(for: 0x00100010)  // Patient Name
decoder.info(for: 0x00080060)  // Modality
decoder.info(for: 0x00280010)  // Rows
```

#### Hounsfield Units (CT)

Density scale in CT imaging:
- Air: -1000 HU
- Lung: -500 HU
- Water: 0 HU
- Muscle: +40 HU
- Bone: +700 to +3000 HU

---

## Integration

### Integration Tips

- Use background processing for large files:
```swift
Task.detached {
    let decoder = try await DCMDecoder(contentsOfFile: path)
}
```

- Validate before loading to improve UX:
```swift
let validation = decoder.validateDICOMFile(path)
if !validation.isValid {
    showError(validation.issues)
}
```

- Use thumbnails for image lists:
```swift
let thumb = decoder.getDownsampledPixels16(maxDimension: 150)
```

- Cache decoder instances per study:
```swift
var decoders: [String: DCMDecoder] = [:]
decoders[studyUID] = decoder
```

- Release memory during batch processing:
```swift
autoreleasepool {
    // Process file
}
```

### Known Limitations

- Compressed and referenced transfer syntaxes: inspect `DicomTransferSyntaxRegistry.standard.compressedPixelSupportMatrix` for the explicit status of every compressed pixel syntax. JPEG Lossless, RLE, and JPEG Extended 12-bit grayscale are `decoded` natively. JPEG Baseline, JPEG Extended <=8-bit, JPEG-LS, JPEG 2000, and JPEG 2000 Part 2 are `delegated` to ImageIO, JLSwift, CharLS, J2KSwift, OpenJPEG, or `DicomJP3DVolumeDocument` with documented limits. JLSwift 0.9.1 is qualified for async JPEG-LS .80/.81 on aligned 8–16-bit grayscale and RGB8, defaults to the own DicomJPEGLS backend, and can be disabled with `DICOM_JLSWIFT_MODE=disabled`; lower-depth grayscale and >8-bit color remain typed exclusions. J2KSwift 11.0.2 is qualified for the two JPEG 2000 frame UIDs through the async reader, defaults to the own DicomJPEG2000 backend, and can be disabled with `DICOM_J2KSWIFT_MODE=disabled`. The same .90/.91 path supports ROI, resolution and cumulative quality-layer requests, including the qualified combined profiles recorded in the partial-decode evidence. These operations consume a complete local codestream and are not JPIP or arbitrary-prefix streaming. HTJ2K .201–.203 decode uses the own qualified CPU backend; OpenJPEG is an optional fallback for other eligible profiles. Encoding is a separate CPU-only qualification: the async `DicomTranscoder` accepts reversible or explicit NEAR intent for JPEG-LS .80/.81 and explicit reversible or irreversible intent for JPEG 2000 .90/.91 and HTJ2K .201-.203; JPEG 2000 Part 2 .92/.93 uses the bounded multi-component profiles described by `DicomJ2KPart2Profile`; arbitrary Part 2 transforms are not implied. JPIP `.94/.95/.204/.205` uses the bounded stateless complete-entity profile documented in `DISTRIBUTION.md`; JPIP and video syntaxes are `streamed-only`, and Deflated Explicit VR Little Endian is dataset-level zlib compression.
- The external Raster-Lab packages are absent from the production and test resolution graph. Selected JLISwift source is incorporated as DicomJPEG; the previous candidate DEFER review retains historical GDCM EOT-only evidence. Current JPEG support and refusals are documented in `DISTRIBUTION.md`. `DISTRIBUTION.md` records preserved Apache-2.0, libjxl and IJG materials and distinguishes the unknown original libjpeg port revision from the retained comparison snapshot.
- JPEG XL UIDs .110/.111/.112 are explicitly `experimental`. The vendored DicomJPEGXL codec remains disabled unless `DICOM_JXLSWIFT_MODE=experimental`; the own Modular lossless routes cover Bits Stored 1–16 grayscale (signed through a Pixel Representation level shift), RGB8 (colour above 8 bits at codec level only), the DICOM ICC Profile embedded in the codestream, and byte-identical JPEG recompression (own reconstruction reader/writer for SOF0/SOF1/SOF2 Huffman JPEG, exact against the source and `djxl` in every direction, `.111` ↔ `.50`/`.51` without decoding for SOF0/SOF1 respectively; progressive SOF2 is refused under both UIDs), exact against libjxl in both directions; the own VarDCT decoder reads lossy `.112` streams (progressive DC/AC, resampling, noise, lossy Modular, custom quantisation) within one code of libjxl and lossy output is written only for an explicit `DicomEncodingIntent.jpegXL(options:)` distance with the derivation record; the 8/12/16-bit grayscale and RGB8 encoder meets size ≤ 1.25× cjxl and PSNR ≥ cjxl − 0.5 dB on the declared 68-case corpus at the same distance and effort 7 (`DISTRIBUTION.md`). The decoder meets the eight-case single-thread Release budget of ≤ 3× `djxl` (maximum 2.464×, process/PNM IO included for `djxl`), preserving all 68 decoded output hashes and DC/AC group cancellation. The `.111` bridge also meets its eight-case Release budget of ≤ 5× cjxl/djxl (maximum 4.727× to recompress and 2.925× to reconstruct), with 25/25 accepted JXL output hashes unchanged and exact JPEG reconstruction (`DISTRIBUTION.md`). The #2378 matrix cell `codec.jxl.vardct.excluded-profiles` lists tested refusals for patches/splines, nonzero AC in six DCT128/256 strategies, upsampled extra channels, custom geometry/opsin, standalone DC extraction, more than eight DC frames, lossy animation beyond its first image, blending and Modular XYB EPF; RGB above 8 bits stays outside the DICOM frame contract. Implicit DIMSE negotiation and sole clinical archive use remain excluded.
- Color display conversion: inspect `DicomColorDisplayConversionMatrix.standard` separately from compressed pixel support. `displayRGBPixelBuffer(frame:)` converts supported MONOCHROME1, MONOCHROME2, RGB, PALETTE COLOR, YBR_FULL, and YBR_FULL_422 native frames to interleaved RGB8 display data. Unsupported YBR variants, alpha/extra samples, unsupported planar layouts, and unsupported bit depths throw `DicomColorConversionError.unsupportedColorPath` with photometric interpretation, samples per pixel, planar configuration, bits allocated, and transfer syntax context.
- Dataset and file writing: inspect `DicomTransferSyntaxRegistry.standard.writeSupportMatrix` before writing. `DicomDataSetWriter` writes native and Deflated datasets, writes referenced JPIP metadata only when Pixel Data Provider URL is present, and preserves already encapsulated Pixel Data for compressed/video syntaxes. It does not recompress native pixels or decompress encapsulated payloads during reserialization; those attempts return stable `DicomDataSetWriterError` values before Part 10 output is generated.
- Safe metadata rewrite: `DicomPart10Rewriter` accepts only recognized writable source transfer syntaxes and top-level non-structural edits. It recursively replaces exact UI values while preserving path order and multiplicity, SOP Class, file-meta implementation identity, and native or encapsulated Pixel Data bytes. Other element ordering, padding, and the Deflated zlib bitstream can be normalized by reserialization.
- DICOMweb scope: inspect `DicomWebConformanceMatrix.packageDefault` before treating the package helpers as a production integration surface. `DicomWebClient` serializes tested QIDO-RS, WADO-RS, WADO-URI, STOW-RS, single/multiple frame, rendered-frame, and BulkDataURI requests through the configured transport. Its complete in-memory STOW body defaults to a 128 MiB `maximumSTOWRequestBodyBytes` budget; callers needing larger requests must opt up or supply a streaming transport. `DicomWebServer` is an in-memory test/demo server for QIDO study search, WADO metadata/instance/frame/rendered-frame, WADO-URI, and STOW Part 10 payloads. Raw byte-aligned native frames are emitted Little Endian in one representation; supported encapsulated syntaxes are passed through as one part per frame. Rendering covers native grayscale and color pixels with optional `quality`, two-dimensional `viewport`, and center/width `window` parameters. One-bit native repacking, compressed/video rendering, crop annotations, UPS, JPIP proxying, authorization policy, audit logging, persistent storage, and zero-copy streaming remain caller-owned or unsupported. Configure `maximumFrameListLength`, `maximumFramesPerRequest`, `maximumFrameResponseBytes`, `maximumRenderedPixels`, and `maximumRenderedResponseBytes` for deployment-specific limits.
- DIMSE scope: `DicomDIMSEServiceSCU`, `DicomStorageSCPService`, and `DicomStorageSCPServer` cover package-tested SCU/SCP helper workflows. The SCU remains the public facade while operation extensions, association/session support, message parsing, and TCP transport live in focused source files under `Sources/DicomCore/`. Value-type datasets parsed from C-GET or C-STORE bytes are metadata-only: Pixel Data remains in `DicomRetrievedInstance.data` or `DicomStorageReceivedInstance.rawDataSetData`, while metadata following Pixel Data is still parsed. They are not a managed PACS service; archive qualification, operational authorization, PHI audit policy, deployment monitoring, and external endpoint validation remain caller-owned.
- Thread safety: `DCMDecoder` uses internal locking for public API access, and batch/series services create isolated decoder instances for concurrent work.
- Waveform scope: ECG and related waveform objects expose temporal samples and metadata; they are not converted into image-volume slices by `DicomSeriesLoader`.
- Video scope: `DicomCore` exposes MPEG-2/H.264/H.265 encoded streams and
  timing metadata without importing AVFoundation or CoreMedia. The optional
  `DicomAppleMedia` product remuxes streams into Apple-playable MPEG-2
  transport-stream or ISO base media containers. It supports H.264 B-picture
  reordering for progressive Main/High 8-bit 4:2:0, POC type 0, single-slice
  pictures in closed IDR GOPs with non-reference B pictures and unchanged
  parameter sets. See the [media module contract](Sources/DicomAppleMedia/DicomAppleMedia.docc/DicomAppleMedia.md)
  for the exact profile restrictions and timestamp policy. It reports malformed
  streams, missing parameter sets, unqualified reordering, empty access-unit sets, and writer failures through
  `DicomVideoRemuxError`. `DCMDecoder.video` retains indexed frame payloads for
  compatibility; forwarding consumers can call `video(payloadMode: .streamOnly)`
  to retain only the byte-identical elementary stream. Run
  `Scripts/benchmark_video_parsing.sh` for isolated Release startup, allocation,
  retained-payload, and process-memory metrics for both modes. It does
  not decode video into volume slices, transcode codecs, or re-encode frames.
- Very large files (>1GB): May consume significant memory. Process in chunks or downsample.
- `SeriesNavigatorView` loads thumbnail-backed slice shortcuts in its expanded layout and keeps an explicit unavailable-thumbnail state when a slice cannot be decoded.
- `MockDicomDecoderForPreviews`, `DicomSampleData`, and `PreviewHelpers` are supported preview APIs only; do not use them for clinical/runtime decoding, validation, conformance, or patient-data workflows.

### Frameworks Used

Core Apple frameworks:
- `Foundation`
- `CoreGraphics`
- `ImageIO`
- `Accelerate`

Deflated Explicit VR Little Endian uses system zlib. JPEG-LS defaults to the internal DicomJPEGLS target. CharLS is an optional dynamically loaded oracle/fallback when `DicomCodecRuntimePreflight.status(for: .charLS)` reports availability.
JPEG 2000 and JPEG 2000 Part 2 multi-component volume decoding can use OpenJPEG when `DicomCodecRuntimePreflight.status(for: .openJPEG)` reports availability; it is loaded dynamically rather than added as a Swift package dependency.
JPEG 2000 and HTJ2K frame decoding use the internal DicomJPEG2000 target for qualified full/partial profiles. The same source supplies the CPU-only J2K encode routes; see `DISTRIBUTION.md`, `DISTRIBUTION.md`, and `DISTRIBUTION.md` in the Isis repository for decode rollout, partial execution/fallback, and encode/transcode qualification.
JPEG-LS qualification, rollback, cross-library evidence, and performance tradeoffs are documented in `DISTRIBUTION.md`.
The historical external JLISwift candidate review is in `DISTRIBUTION.md`; current incorporated-source decisions and codec qualification are in `DISTRIBUTION.md` and `DISTRIBUTION.md`.
JPEG XL qualification, disabled-by-default policy, libjxl parity, and archive/network boundaries are documented in `DISTRIBUTION.md`; the own Modular lossless codec (#2332) in `DISTRIBUTION.md`.
The cross-codec clinical fixture matrix, exact/NEAR/lossy comparison rules, backend verdicts, machine-readable reports, visible corpus gaps, and optional pinned DICOMKit cross-read/write harness are documented in `DISTRIBUTION.md` in the Isis repository.
The #2366 independent corpus and adversarial gate are documented in `DISTRIBUTION.md`.
Bounded Data/file/injected-range sources, explicit leases and selective metadata/native-frame APIs are documented in
`DISTRIBUTION.md`; use `dicomtool inspect --bounded --read-metrics` to inspect their actual I/O.
`DicomSourceFrameSession` reuses one revision-bound native/BOT/EOT index and shares compatible raw, decoded and partial
frame requests with independent cancellation and bounded reservations. `dicomtool extract --bounded` uses this path;
see [Selective frame sessions](DISTRIBUTION.md) for codec boundaries, raw wide/float qualification,
independent fixtures and measured memory. Existing full-buffer APIs remain available.
It compares all frames/components and metadata with pinned pydicom-generated expectations, independently rereads Swift
rewrites, detects deliberate pixel/frame/geometry changes, and exercises parser, RLE and remote-origin failures.
The external Python reader is test tooling only and requires Python 3.12 or newer for the pinned
NumPy dependency. Set `DICOM_DIFFERENTIAL_PYTHON` when `python3` selects an older interpreter;
ordinary fixture tests use the committed non-PHI corpus.

Optional codec runtimes and oracle tools are developer/CI-provisioned, not bundled production dependencies. Use `brew install charls openjpeg jpeg-xl` for the common Homebrew setup, or set `DICOM_DECODER_CHARLS_LIBRARY_PATH` and `DICOM_DECODER_OPENJPEG_LIBRARY_PATH` to explicit dynamic-library paths. Default CI skips optional runtime/tool tests with classified messages; set `DICOM_REQUIRE_CHARLS=1`, `DICOM_REQUIRE_OPENJPEG=1`, `DICOM_REQUIRE_OPJ_COMPRESS=1`, `DICOM_REQUIRE_LIBJXL_TOOLS=1`, `DICOM_REQUIRE_DICOMKIT_INTEROP=1`, or `DICOM_REQUIRE_OPTIONAL_RUNTIMES=1` when CI provisions them and should fail if they are absent.

---

## Contributing

Contributions required by Isis are reviewed and integrated in the Isis DICOM
Viewer repository so the package and its callers remain on one tested commit.

### How to Contribute

1. File or select an issue in
   [`ThalesMMS/Isis-DICOM-Viewer`](https://github.com/ThalesMMS/Isis-DICOM-Viewer/issues).
2. Fork or clone the Isis DICOM Viewer repository.
3. Create a feature branch (`git checkout -b feature/MyFeature`).
4. Update code under `DICOM-Swift/Sources/DicomCore/` and add tests under
   `DICOM-Swift/Tests/`.
5. Run the tests:
   ```bash
   swift test --package-path DICOM-Swift
   swift build --package-path DICOM-Swift
   ```
6. Commit with a clear message.
7. Push to your branch.
8. Open the pull request against `ThalesMMS/Isis-DICOM-Viewer`.

Do not develop the Isis package change directly in the public DICOM-Swift
mirror. Mirror synchronization is a separate owner-operated release task.

### Areas That Need Help

- Documentation improvements
- Additional test cases
- Bug fixes
- Performance optimizations
- New medical presets
- Internationalization

### Code of Conduct

- Be respectful and constructive.
- Follow Swift code conventions.
- Add tests for new functionality.
- Preserve backward compatibility.

---

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the full text.

Package-linked implementations retain their own licenses and original port
attributions in [ThirdPartyNotices.txt](ThirdPartyNotices.txt), including OpenJPH,
libjxl and Brotli materials. A wrapper license does not replace those notices.

---

## Acknowledgments

This project originates from the Objective-C DICOM decoder by [kesalin](https://github.com/kesalin/DicomViewer). The Swift package modernizes that codebase while preserving credit to the original author.

---

## Support

- Documentation: [GETTING_STARTED.md](GETTING_STARTED.md)
- Bug reports and Isis-required changes:
  [Isis DICOM Viewer issues](https://github.com/ThalesMMS/Isis-DICOM-Viewer/issues)
- Standalone release questions:
  [DICOM-Swift discussions](https://github.com/ThalesMMS/DICOM-Swift/discussions)

---

If this project is useful, consider starring the repository or contributing improvements.

## HL7 v2 schemas, profiles, validation and builders

The independent `HL7v2` product uses the loss-preserving parser/model together
with data-driven schema tables in `Sources/HL7v2/Schema/Tables/`. It does not
import DicomCore or DicomData and adds no package dependencies.

Serialization checks preserved raw field values before writing them, including
models restored from JSON, so they cannot inject HL7 delimiters or new segments.
Batch joining rejects envelope segments embedded inside individual messages.

Covered schema versions are **2.3.1, 2.4, 2.5, 2.5.1 and 2.6**. The registry
returns the nearest lower covered schema for newer numeric versions, recording
`versionMismatch` in the returned schema's diagnostics. There is no fallback
below 2.3.1 or for an unparseable version. Validation also reports a message/schema
version mismatch; builders reject versions without an exact table, even with
`allowInvalid`.

| Events | Structure in the supported subset | Versions |
| --- | --- | --- |
| ADT A01/A04/A08 | ADT_A01 | All five |
| ADT A03 | ADT_A03 | All five |
| ORM O01 | ORM_O01 | All five |
| ORU R01 | ORU_R01 | All five |
| ACK | ACK | All five |
| QRY A19 | QRY_A19 | All five |
| QBP Q22 | QBP_Q21 | 2.4, 2.5, 2.5.1, 2.6 |
| RSP K22 | RSP_K22 | 2.4, 2.5, 2.5.1, 2.6 |

The segment tables cover MSH, EVN, PID, PD1, NK1, PV1, PV2, AL1, DG1, OBR, OBX,
ORC, NTE, IN1, GT1, MSA, ERR, QRD, QRF, QAK and DSC; QPD/RCP start at 2.4.
ZXX is a placeholder, not permission to accept arbitrary Z segments. The ordered
structures intentionally contain this supported segment subset; they are not
claims to implement every optional segment in the full HL7 standard.
Field introduction/deprecation annotations are relative to the covered version
range. Attribute facts were checked against the version-specific
[HL7 Europe tables](https://www.hl7.eu/HL7v2x/v251/hl7v251segmPID.htm).

`HL7Validator(schema:profile:options:)` returns `HL7ValidationReport` with stable
codes, one-based `HL7Path`s, a separate `segmentOccurrence`, severity and details.
A report is valid only when it has no errors. Default details contain no message
values. `includeValues` explicitly enables the offending code value in value-set
findings. Matching is greedy with bounded backtracking; budget exhaustion is an
error, not a successful partial match. Required/forbidden fields, repetition
limits, lengths, primitive syntax, required composite components, segment order
and group cardinality are checked. OBX-5 uses OBX-2's version-available type and
its declared result-status condition. Other context-dependent C fields can carry
an explicit `HL7FieldCondition`; a C annotation alone is not an executable
clinical workflow predicate.

Included code sets cover the common administrative/message/result tables 0001,
0003, 0004, 0008, 0076, 0078, 0085, 0103, 0119, 0125, 0155, 0206, 0207, 0357,
0396 and 0516 where published for that version. Field references to other tables
remain available as metadata; hosts supply local or additional code sets through
profiles. An absent code set is not treated as an empty set or as proof that a
locally assigned code is invalid.

`HL7Profile` is JSON Codable, with a string `baseVersion`. It supports field
optionality/length/value-set overrides, custom sets, unknown segment/field
policies, and Z-segment definitions inserted after a named segment within a
specified structure's containing group. `HL7ProfileRegistry` loads and stores
profiles without global mutable validation state. Invalid placements/overrides
and profile/schema version mismatches produce errors.

```swift
import HL7v2

var pid = HL7SegmentBuilder("PID")
pid.set(3, HL7ExtendedID(id: "SYNTHETIC", identifierType: "MR"))
pid.set(5, HL7PersonName(family: "Example", given: "Test"))
var pv1 = HL7SegmentBuilder("PV1")
pv1.set(2, .text("I"))

var builder = HL7MessageBuilder(version: .v2_5_1)
builder.msh(sendingApp: "APP", receivingApp: "RECEIVER", messageType: "ADT^A01")
builder.adt(event: .A01, pid: pid.segment, pv1: pv1.segment)
let message = try builder.build() // Throws HL7BuildError.invalid(report) on errors.
let wire = try HL7Serializer().serialize(message)
```

Conveniences also build orders, observation results, versioned ACKs, QRY A19 and
QBP Q22/RSP K22 exchanges. ACK mirrors the original control ID into MSA-2 and
swaps sender/receiver fields; ERR uses ELD in 2.3.1/2.4 and ERL/CWE/severity in
2.5+. `allowInvalid` is an explicit opt-out from build validation.
Typed values cover timestamps with retained precision/fraction/time-zone spelling,
HL7 numbers, coded elements with alternates, XPN, CX, HD, XAD and XTN; composite
wrappers retain components that do not have named convenience accessors.

The original lot A corpus is preserved. Some upstream `valid/` files are valid
parser examples but have schema errors. Tests lock down those original error
paths and separately validate corrected synthetic copies documented in
[lot B fixture provenance](Tests/HL7v2Tests/Fixtures/lotB/PROVENANCE.md).
The focused verification command is:

```sh
swift test --filter 'HL7' 2>&1 | tail -30
```

### Optional target boundary and independent oracle

`HL7v2`, `HL7MLLP` and `hl7tool` (and future CDA/FHIR targets) are optional products.
DICOM library products, `dicomtool`, MTK and Isis Packages must not depend on
them without a future issue authorizing an explicit optional integration.
HL7kit remains reference-only, apart from its attributed synthetic test fixtures.

Set `HL7V2_ORACLE_PYTHON` to a Python executable with **hl7apy 1.3.5** and
**python-hl7 0.4.5** installed. With no usable oracle, the live cross-parse tests
skip explicitly; `HL7V2_REQUIRE_ORACLE=1` makes unavailability a failure. There
is no network access or dependency installation in the harness. Results are
transient and never checked in. See the [toolkit guide](DISTRIBUTION.md)
and [interop harness](Scripts/interop/README.md).

```bash
cd DICOM-Swift
HL7V2_ORACLE_PYTHON=/tmp/isis-2321-iod-oracle/bin/python HL7V2_REQUIRE_ORACLE=1 swift test --filter 'HL7OracleCrossParse|HL7ToolCommand' 2>&1 | tail -30
```

### Optional MLLP transport (#2361)

`HL7MLLP` adds bounded framing, Network.framework client/listener, ACK policies,
optional inbound in-memory/JSONL ledger and per-destination retransmission
policy. `hl7tool mllp send` and `hl7tool mllp listen` are its CLI consumers;
Isis `Packages` and `dicomtool` do not consume it. Recorded ACKs replay after a
crash without processing the message again. Caught failures after processing
reserve an uncertain outcome without a successful ACK. JSONL replay reads new
appends incrementally and reloads after journal replacement or truncation.
Unknown ACKs for non-idempotent
orders require reconciliation. TLS and loopback exposure defaults reuse the
DicomCore security types. No host database or automatic clinical reconciliation
is provided. See the [MLLP guide](DISTRIBUTION.md)
for limits, CLI options, test map and plain-TCP python-hl7/hl7apy oracle recipe.

## CLI parity commands (#2365)

`dicomtool uid|dump|image|measure|pixel|report|study|script|bench` and `hl7tool bench` are thin adapters over
`DicomElementDump`, `DicomPixelMeasurement`, `DicomPixelEditor`, `DicomStructuredReportRenderer`,
`DicomStudyOrganizer`, `DicomPipelineRunner`, `DicomDecodeBenchmark`, `DicomContactSheet` and `HL7Benchmark`.
Metadata-only, pixel-decode, network and mutating operations are separated; mutations never run in place,
offer `--dry-run` where meaningful and write derived objects with new SOP Instance UIDs. Pipelines are declarative
JSON (no code evaluation) whose secrets are `env:NAME` references resolved through `DicomPipelineSecretProvider`
and never reported. Benchmarks name the corpus, per-file SHA-256 and toolkit version and carry a disclaimer.
Pixel statistics and histograms use stored samples within `BitsStored`, undoing display normalization
for signed and MONOCHROME1 frames; negative rescale slopes still produce ordered minimum and maximum bounds.
Pipeline dry runs apply metadata, UID, de-identification and pixel edits to the in-memory working
object so later steps observe the same sequence of changes, while filesystem writes stay suppressed.
The reference `dicom-*`/HL7CLI family mapping belongs to application
qualification records. Standalone consumers use the command descriptions here
and the package scripts; see [Distribution](DISTRIBUTION.md) for the limits.
