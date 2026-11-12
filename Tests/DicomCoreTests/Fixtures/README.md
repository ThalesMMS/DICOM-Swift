# DICOM Test Fixtures

This directory contains DICOM sample files for integration testing. Small synthetic non-PHI fixtures are committed for
deterministic default CI. Larger public or locally generated optional fixtures can be added locally for extended
conformance testing.

## Curated parity fixtures (issue #1224)

`DecoderParity/jpeg_lossless_sv1_parity.dcm`, `DecoderParity/rle_parity.dcm`,
`StructuredReports/sr_tid1500_measurement_report.dcm` and
`StructuredReports/kos_key_object_selection.dcm` are committed curated
fixtures bound to `ClinicalParityFixtureManifest.json`.

- **Provenance/license**: generated in-repo by the deterministic builders in
  `ClinicalParityCuratedFixtureTests` (no external data; same license as the
  repository). Regenerate with `DICOM_REGENERATE_PARITY_FIXTURES=1 swift test
  --filter ClinicalParityCuratedFixtureTests`.
- **Privacy**: synthetic non-PHI; identifiers use `PARITY` placeholders only.
- **Drift gates**: the same suite fails when the committed bytes, expected
  UIDs, frame counts, pixel hashes, or SR tree content change.
- The September 2026 reconciliation regenerates SR/KOS after #2297 corrected
  Content Label to CS, Content Description to LO and Tracking ID to UT. Values
  remain unchanged. The release manifest also records the already corrected
  SEG/GSPS fixture bytes; all four file checksums are checked by XCTest.
- The #2321 package gate also reconciles the SR fixture's Mapping Resource
  `(0008,0105)` VR from SH to the dictionary-correct CS. Only the two VR bytes
  change; the report values remain identical and the release checksum is updated.
- The compressed parity files live under `DecoderParity/` (not
  `Compressed/`) so the JPEG Lossless conformance-sample scanner keeps
  targeting real conformance files only.

## Purpose

Integration tests use these fixtures to verify:
- Different DICOM modalities (CT, MR, XR, US, etc.)
- Various transfer syntaxes (Little/Big Endian, Explicit/Implicit VR, compressed formats)
- Different image dimensions and bit depths
- Real-world DICOM files from medical imaging systems

## Quick Start

1. Use the committed synthetic fixtures for default tests.
2. Download optional public DICOM samples from sources below when running extended conformance tests.
3. Place optional files in this directory: `Tests/DicomCoreTests/Fixtures/`
4. Run integration tests: `swift test --filter Integration`

## Where to Obtain DICOM Samples

### The Cancer Imaging Archive (TCIA)

- **URL:** https://www.cancerimagingarchive.net/
- **License:** Most datasets are public domain or CC-BY
- **Recommended:** LIDC-IDRI (CT lung), TCGA-BRCA (breast MRI), CT COLONOGRAPHY

### OsiriX DICOM Sample Files

- **URL:** https://www.osirix-viewer.com/resources/dicom-image-library/
- **License:** Public domain samples
- **Recommended:** MANIX (multi-modality), KNEE (MRI series), CARDIX (cardiac CT)

### dcm4che Test Data

- **URL:** https://github.com/dcm4che/dcm4che/tree/master/dcm4che-test-data
- **License:** Apache 2.0 or public domain
- **Includes:** Various transfer syntaxes, JPEG Lossless files

```bash
git clone https://github.com/dcm4che/dcm4che.git
cp dcm4che/dcm4che-test-data/src/main/data/*.dcm Tests/DicomCoreTests/Fixtures/
```

### DICOM Library

- **URL:** https://dicomlibrary.com/
- **License:** Public samples

### JPEG Lossless Test Files

The library supports JPEG Lossless (Process 14, all selection values 0-7). To obtain test files:

1. **dcm4che** (recommended): Clone the dcm4che repository above; look for files with transfer syntax `1.2.840.10008.1.2.4.70`
2. **Convert existing files** with DCMTK: `dcmcjpeg +e14 input.dcm output_lossless.dcm`
3. **Verify**: `dcmdump --print-short file.dcm | grep "TransferSyntaxUID"` should show `1.2.840.10008.1.2.4.70`

## Directory Structure

Committed synthetic fixtures:

```
Fixtures/
├── CT/
│   └── ct_synthetic.dcm
├── MR/
│   └── mr_synthetic.dcm
├── XR/
│   └── xr_synthetic.dcm
├── US/
│   └── us_synthetic.dcm
├── Compressed/
│   └── jpeg_baseline_synthetic.dcm
└── DecoderParity/
    ├── ct_explicit_vr_le_rescale.dcm
    ├── ct_missing_optional_voi.dcm
    ├── mr_implicit_vr_le.dcm
    ├── mr_utf8_specific_charset.dcm
    ├── secondary_capture_rgb.dcm
    └── us_multiframe_metadata.dcm
```

Optional downloaded fixtures go into the matching modality folder (`CT/`, `MR/`, `XR/`, `US/`, `Compressed/`); additional local-only folders can be created as needed.

## Recommended Test Coverage

### By Transfer Syntax
- Little Endian Implicit VR (1.2.840.10008.1.2) - Most common
- Little Endian Explicit VR (1.2.840.10008.1.2.1) - Standard
- Big Endian Explicit VR (1.2.840.10008.1.2.2) - Legacy
- JPEG Lossless, First-Order Prediction (1.2.840.10008.1.2.4.70) - Process 14
- JPEG Baseline (1.2.840.10008.1.2.4.50)
- JPEG 2000 (1.2.840.10008.1.2.4.90 / .91)

### By Image Properties
- 8-bit grayscale, 16-bit grayscale, 24-bit RGB
- Large (512x512+) and small (<256x256) dimensions
- Multi-frame sequences

## Usage in Tests

Integration tests skip gracefully if fixtures are missing:

```swift
func testLoadRealCTImage() throws {
    let fixturesPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CT")

    guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
        throw XCTSkip("DICOM fixtures not available. See Fixtures/README.md")
    }

    let files = try FileManager.default.contentsOfDirectory(at: fixturesPath,
        includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "dcm" }

    guard let firstFile = files.first else {
        throw XCTSkip("No .dcm files found in Fixtures/CT")
    }

    let decoder = try DCMDecoder(contentsOf: firstFile)
    XCTAssertEqual(decoder.info(for: .modality), "CT")
    XCTAssertGreaterThan(decoder.width, 0)
}
```

## File Size and Privacy

- **Do not commit** large or clinical DICOM files to the repository.
- Small synthetic fixtures listed in `Tests/DicomCoreTests/Resources/ReleaseGates/OptionalRuntimeFixtureManifest.json` and
  `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` are intentionally versioned.
- **Never use real patient data** without proper de-identification
- **Verify license terms** for public datasets
- Use anonymization tools if handling clinical data (DICOM Anonymizer, dcm4che deid, CTP)

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Tests skipped | Download samples from sources above |
| Transfer syntax not supported | Convert: `dcmconv input.dcm output.dcm --write-xfer-little` |
| Files too large for repo | `git rm --cached Tests/DicomCoreTests/Fixtures/*.dcm` |
| Integration tests fail | Validate: `dcmdump --print-short file.dcm` |

## Resources

- [DICOM Standard](https://www.dicomstandard.org/)
- [pydicom Documentation](https://pydicom.github.io/)

---

**Note:** The committed fixtures are synthetic and non-PHI. Optional downloaded fixtures must remain local unless a
manifest explicitly approves them for version control.

## TID 1500 ROI measurement report (issue #2345)

`StructuredReports/sr_tid1500_roi_measurement_report.dcm` is generated by
`DicomSRMeasurementReportBuilderTests.fullReport()` and checked byte-for-byte by
`ClinicalInteropFixtureExportTests`. It uses Comprehensive 3D SR, generic/planar/volumetric
measurement groups, CT image descriptors, and a TID 1420 reference to a planar group container.
All content and identifiers are synthetic PARITY data; provenance/license are the repository's.
Regenerate through `DICOM_REGENERATE_CLINICAL_INTEROP_FIXTURES=1` with the authorized focused
Swift test filter. Existing SR/KOS fixture bytes and checksums are not regenerated by this addition.

The fixture is inventoried as `sr-tid1500-roi-measurement-report` in
`Resources/ReleaseGates/ClinicalCodecConformanceManifest.json` (relative to `Tests/DicomCoreTests/`).
SHA-256: `5c12b74c0687284ca70a910328076b799a864e5330e8c89733aadd8a343eea10`.

From `DICOM-Swift/`, regenerate with:

```bash
DICOM_REGENERATE_CLINICAL_INTEROP_FIXTURES=1 swift test --filter "DicomSRTemplate|DicomSRMeasurementReportBuilder|DicomStructuredReport|DicomKeyObject|ClinicalInteropFixtureExport|ClinicalParityCuratedFixture|DicomSRProfileCorpus"
```

Run the same command without the environment variable to check the on-disk fixture against
its deterministic builder. After an intentional fixture change, update its manifest SHA-256
and this entry together; existing fixture checksums remain unchanged.

## RT and Surface geometry objects (issue #2346, Lot A2)

`ClinicalInteropFixtureExportTests.test_geometryFixtures_matchBuildersAndRegenerateWhenRequested`
checks these additional deterministic, repository-licensed, synthetic PARITY fixtures:

| File | Content |
| --- | --- |
| `ClinicalInterop/seg_labelmap.dcm` | 8-bit LABELMAP, labels 1–3, three 4×4 planes; row/column cosines rotated 30 degrees about patient Y, 0.7×0.9 mm spacing, 2.5 mm slices. |
| `ClinicalInterop/seg_fractional_sparse.dcm` | FRACTIONAL PROBABILITY with maximum 200, slices 1 and 3 only; segment 2 has no frames and yields `segmentWithoutFrames`. |
| `ClinicalInterop/rtstruct_multiloop_xor.dcm` | Oblique image references; ROI 1 has an XOR outer loop and hole, ROI 2 has two disjoint closed loops and a loop on the next plane, ROI 3 is a point. |
| `ClinicalInterop/surface_cube.dcm` | 10 mm cube, 8 points, 12 outward triangles, outward vertex normals, Finite Volume YES and Manifold YES. |

The manifest is `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalCodecConformanceManifest.json`.
Existing fixture bytes are unchanged. From `DICOM-Swift/`, regenerate through the same test path:

```bash
DICOM_REGENERATE_CLINICAL_INTEROP_FIXTURES=1 swift test --filter "DicomRT|DicomSurface|DicomGeometryCorpus|ClinicalInteropFixtureExport|ClinicalParityCuratedFixture|DicomQualifiedProfileCatalog|DicomSegmentationParametricMapCorpus"
```

The geometry corpus additionally reads the existing `seg_binary.dcm` and `rtstruct_contour.dcm`
bytes and builds a 5×3×3 binary SEG to exercise continuous bit packing across odd-sized frames.
Each `.dcm.json` sidecar records the engine's stored samples, per-frame segment voxel counts,
label histograms, fractional stored sums, contour points/types/references, or mesh points/normals/
indices. The cube's independent expected area and signed volume are 600 mm² and 1000 mm³.
`geometry_objects_oracle.py` decodes independently with pydicom and computes metrics with numpy.
The sparse segment without frames is one documented input gap, not an omitted comparison.

A.57 was added to the existing IOD source list; the generator followed the same DocBook/module
cache composition as A.51 and A.75, including C.8.23.1 and C.27.1 and their included macros.
The exact command run from the Isis repository root was:

```bash
/tmp/isis-2321-iod-oracle/bin/python DICOM-Swift/Scripts/conformance/generate_enhanced_tables.py --standard /tmp/isis-2321-dicom-standard/2026c --output DICOM-Swift/Sources/DicomData/Generated/DicomEnhancedImageTables.swift
```

Surface Segmentation Storage `.66.5` is included in the raw profile catalog. Local Surface corpus
cases cover the valid cube, invalid Finite Volume/Manifold values, Surface Processing conditions,
normals counts, primitive index bounds, and surface counts; `DICOM_SEG_PM_CORPUS_DIRECTORY`
exports those objects and outcome sidecars alongside the existing SEG/PM corpus. The existing
`seg_pm_oracle.py` has case-specific SEG/PM assumptions and has not been extended or executed
for Surface in this lot. Surface geometry is independently checked by `geometry_objects_oracle.py`;
this does not certify mesh topology or independently qualify every IOD attribute.

## Third-party compressed SEG (Isis issue #2520)

`Segmentation/` contains synthetic 16 × 20 planes over three slices, with patient
`SYNTHETIC^SEG`. The four `native-{binary,fractional,labelmap8,labelmap16}.dcm`
references were written by `DicomSegmentationBuilder`. BINARY has two segments
and six frames; the others have three frames. Labels are 0–5 (8-bit) or
0, 1, 2, 300 (16-bit); FRACTIONAL stores probabilities against maximum 255.

- GDCM 3.2.7: `gdcm-jpegls-{fractional,labelmap8,labelmap16}.dcm` (`.4.80`),
  `gdcm-j2k-{fractional,labelmap8,labelmap16}.dcm` (`.4.90`), and `gdcm-rle-fractional.dcm` (`.5`).
- OpenJPH 0.32.0: `openjph-htj2k-{fractional,labelmap8,labelmap16}.dcm` (`.4.201`).
- dcmjs 0.49.2 (commit `81e7e11`, Node 26): `dcmjs-rle-binary-as-fractional.dcm`.
  Its OHIF RLE writer rewrites BINARY as FRACTIONAL PROBABILITY, 8 bits, values
  0/1, maximum 255. Two frames have a nonzero RLE segment padding byte.
- pydicom 3.0.2: `pydicom-rle-binary-{packed,bytes}.dcm`, BINARY with one RLE
  byte segment per frame holding packed LSB-first bits or one byte per pixel.

Each compressed fixture was decoded independently with GDCM `--raw`,
`ojph_expand`, or pydicom's RLE decoder and compared with its native reference.
Attributes remain unchanged except transfer syntax and Pixel Data, plus the
six attributes rewritten by dcmjs. SHA-256 and provenance are recorded in
`Resources/ReleaseGates/ClinicalCodecConformanceManifest.json`.
`DicomSegmentationThirdPartyEncodingTests` compares every voxel, segment and frame geometry.
Regenerate from `DICOM-Swift/`, with these tool versions installed:

```bash
python3 Scripts/conformance/seg_compressed_fixtures.py Tests/DicomCoreTests/Fixtures/Segmentation --dcmjs /path/to/dcmjs
```
