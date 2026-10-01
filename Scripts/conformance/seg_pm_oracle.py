#!/usr/bin/env python3
"""Compare the Segmentation/Parametric Map corpus with the independent IOD validator.

Each case carries the engine's expected outcome, CLI exit code and whether the object declares a
Common Instance Reference, written by DicomSegmentationParametricMapCorpusTests. The pinned
dicom-validator/PS3.3 2026c cache gives an independent module verdict (its cache lists no
functional group macros for the image IODs, so functional group findings are engine-only);
pydicom and numpy supply pixel and surface geometry witnesses. Disagreements are recorded
with their reason, never masked.
Requires requirements-iod.txt.
"""
import argparse
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path
import subprocess

import numpy as np
import pydicom
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

FACTS = ["animal=no", "non-bipedal=no", "paired-body-part=no", "temporally-related-series=no", "calibrated-image=no"]
# The oracle's IOD cache lists no functional group macros for the Segmentation and Parametric Map IODs,
# so it reports every group in (5200,9229)/(5200,9230) as unexpected; those entries are excluded from
# the agreement count and recorded per case.
FUNCTIONAL_GROUP_FALSE_POSITIVE = ("Multi-frame Functional Groups", "TagUnexpected")
# The oracle reads the Palette Color Lookup Table UID condition (C.8.32.2) as unconditional on COLOR_RANGE,
# although it applies only when the Palette Color Lookup Table module is absent.
PALETTE_UID_FALSE_POSITIVE = ("Parametric Map Image", "(0028,1199)", "TagMissing")
# Pixel-metadata negatives that pydicom itself refuses to decode; the refusal is their structural witness.
PIXEL_DECODE_REFUSALS = {"seg-binary-bits-8", "pm-float-bits-16", "pm-integer-missing-bits-stored", "seg-labelmap-bits-1"}
LABELMAP_SOP_CLASS = "1.2.840.10008.5.1.4.1.1.66.7"
SURFACE_SOP_CLASS = "1.2.840.10008.5.1.4.1.1.66.5"
INDEPENDENT_ERRORS = {
    "seg-labelmap-8": [],
    "seg-labelmap-16": [],
    "seg-labelmap-palette": [],
    "seg-labelmap-padding": [],
    "seg-labelmap-bits-1": [("Segmentation Image", "(0028,0100)", "EnumValueNotAllowed")],
    "seg-labelmap-bits-stored": [("Segmentation Image", "(0028,0101)", "EnumValueNotAllowed")],
    "seg-labelmap-high-bit": [("Segmentation Image", "(0028,0102)", "EnumValueNotAllowed")],
    "seg-labelmap-photometric": [("Segmentation Image", "(0028,0004)", "EnumValueNotAllowed")],
    "seg-labelmap-padding-range": [("General Equipment", "(0028,0120)", "TagMissing")],
    "seg-labelmap-palette-missing-icc": [("ICC Profile", "(0028,2000)", "TagMissing")],
    "seg-labelmap-palette-missing-lut": [
        ("Image Pixel", "(0028,1101)", "TagMissing"), ("Image Pixel", "(0028,1102)", "TagMissing"),
        ("Image Pixel", "(0028,1103)", "TagMissing"), ("Image Pixel", "(0028,1201)", "TagMissing"),
        ("Image Pixel", "(0028,1202)", "TagMissing"), ("Image Pixel", "(0028,1203)", "TagMissing"),
        ("Palette Color Lookup Table", "(0028,1101)", "TagMissing"),
        ("Palette Color Lookup Table", "(0028,1102)", "TagMissing"),
        ("Palette Color Lookup Table", "(0028,1103)", "TagMissing")],
    "surface-cube": [],
    "surface-primitives-empty": [("Surface Mesh", f"(0066,0002) / (0066,0013) / (0066,{tag})", "TagMissing")
                                 for tag in ("0026", "0027", "0028", "0034", "0041", "0042", "0043")],
    "surface-primitives-empty-list": [("Surface Mesh", f"(0066,0002) / (0066,0013) / (0066,{tag})", "TagMissing")
                                      for tag in ("0026", "0027", "0028", "0034", "0042", "0043")],
    "surface-finite-invalid": [("Surface Mesh", "(0066,0002) / (0066,000E)", "EnumValueNotAllowed")],
    "surface-manifold-invalid": [("Surface Mesh", "(0066,0002) / (0066,0010)", "EnumValueNotAllowed")],
    "surface-processing-required": [
        ("Surface Mesh", "(0066,0002) / (0066,000A)", "TagMissing"),
        ("Surface Mesh", "(0066,0002) / (0066,0035)", "TagMissing")],
    "seg-algorithm-name-missing": [("Segmentation Image", "(0062,0002) / (0062,0009)", "TagMissing")],
    "seg-binary-bits-8": [("Segmentation Image", "(0028,0100)", "EnumValueNotAllowed"), ("Segmentation Image", "(0028,0101)", "EnumValueNotAllowed"),
                          ("Segmentation Image", "(0028,0102)", "EnumValueNotAllowed")],
    "seg-fractional-missing-maximum": [("Segmentation Image", "(0062,000E)", "TagMissing")],
    "seg-voi-lut": [("General", "(0028,1050)", "TagUnexpected"), ("General", "(0028,1051)", "TagUnexpected")],
    "pm-color-range": [PALETTE_UID_FALSE_POSITIVE],
    "pm-color-range-without-palette": [
        ("Palette Color Lookup Table", "(0028,1101)", "TagMissing"), ("Palette Color Lookup Table", "(0028,1102)", "TagMissing"),
        ("Palette Color Lookup Table", "(0028,1103)", "TagMissing"),
        ("Parametric Map Image", "(0028,1199)", "TagMissing"), ("Parametric Map Image", "(0028,2000)", "TagMissing")],
    "pm-float-bits-16": [("Floating Point Image Pixel", "(0028,0100)", "EnumValueNotAllowed"), ("Parametric Map Image", "(0028,0100)", "EnumValueNotAllowed")],
    "pm-image-type-original": [("Parametric Map Image", "(0008,0008)", "EnumValueNotAllowed")],
    "pm-integer-missing-bits-stored": [("Image Pixel", "(0028,0101)", "TagMissing"), ("Parametric Map Image", "(0028,0101)", "TagMissing")],
    "pm-missing-frame-of-reference": [("Frame of Reference", "(0020,0052)", "TagMissing"), ("Frame of Reference", "(0020,1040)", "TagMissing")],
}
GAPS = {
    "seg-labelmap-overlap-yes": "Oracle cache permits YES/UNDEFINED/NO without the LABELMAP-specific NO restriction.",
    "seg-labelmap-overlap-missing": "Oracle cache marks Segments Overlap as Type 3 without the LABELMAP requirement.",
    "seg-labelmap-maximum-fractional": "Oracle cache requires Maximum Fractional Value for FRACTIONAL but allows it otherwise.",
    "seg-labelmap-fractional-type": "Oracle cache requires Segmentation Fractional Type for FRACTIONAL but allows it otherwise.",
    "seg-labelmap-segment-identification": "Oracle lists no functional group macros and cannot enforce their LABELMAP exclusions.",
    "seg-labelmap-palette-cielab": "Oracle cache marks Recommended Display CIELab Value as Type 3 without the PALETTE COLOR exclusion.",
    "surface-count": "Oracle does not compare Number of Surfaces with the Surface Sequence item count.",
    "surface-normals-count": "Oracle does not compare Number of Vectors with the normal data length and surface point count.",
    "surface-index-bounds": "Oracle does not decode primitive indices to check the 1-based surface point bounds.",
    "seg-missing-segment-identification": "Oracle lists no functional group macros for the Segmentation IOD.",
    "seg-unknown-referenced-segment": "Oracle does not resolve Referenced Segment Number against the Segment Sequence.",
    "seg-segment-numbers-gap": "Oracle does not check the C.8.20.2.4 segment numbering.",
    "seg-image-type-original": "Oracle does not enforce the DERIVED/PRIMARY Image Type of the Segmentation IOD.",
    "seg-pixel-padding": "Oracle does not apply the A.51.4 pixel padding exclusion.",
    "seg-no-frame-of-reference-no-derivation": "Oracle does not evaluate the Frame of Reference condition on the Derivation Image group.",
    "seg-geometry-without-frame-of-reference": "Oracle lists no functional group macros for the Segmentation IOD.",
    "seg-derivation-without-instance-reference": "Oracle does not derive the Common Instance Reference condition from functional groups.",
    "seg-derivation-wrong-code": "Oracle does not check the A.51.5.1 derivation codes.",
    "seg-frame-content-shared": "Oracle lists no functional group macros for the Segmentation IOD.",
    "pm-missing-real-world-value-mapping": "Oracle lists no functional group macros for the Parametric Map IOD.",
    "pm-rescale-slope-2": "Oracle does not enforce the identity transformation values.",
    "pm-missing-frame-voi-lut": "Oracle lists no functional group macros for the Parametric Map IOD.",
    "pm-mixed-frame-type": "Oracle lists no functional group macros for the Parametric Map IOD.",
    "pm-missing-plane-position": "Oracle lists no functional group macros for the Parametric Map IOD.",
    "pm-unassigned-shared-per-frame": "Oracle lists no functional group macros for the Parametric Map IOD.",
    "pm-derivation-without-instance-reference": "Oracle does not derive the Common Instance Reference condition from functional groups.",
}


def labelmap_witness(name, ds):
    require(ds.SegmentationType == "LABELMAP", "Changed LABELMAP type witness")
    bits = 16 if name == "seg-labelmap-16" else 8
    require(int(ds.BitsAllocated) == (1 if name == "seg-labelmap-bits-1" else bits),
            "Changed LABELMAP allocation witness")
    if name not in PIXEL_DECODE_REFUSALS:
        numbers = [int(item.SegmentNumber) for item in ds.SegmentSequence]
        require(np.isin(ds.pixel_array, numbers).all(), "Changed LABELMAP pixel membership witness")
    require(int(ds.BitsStored) == (7 if name == "seg-labelmap-bits-stored" else bits),
            "Changed LABELMAP bits stored witness")
    require(int(ds.HighBit) == (8 if name == "seg-labelmap-high-bit" else bits - 1),
            "Changed LABELMAP high bit witness")
    photometric = "PALETTE COLOR" if name.startswith("seg-labelmap-palette") else "MONOCHROME1" if name == "seg-labelmap-photometric" else "MONOCHROME2"
    require(ds.PhotometricInterpretation == photometric, "Changed LABELMAP photometric witness")
    require(("PixelPaddingValue" in ds) == (name == "seg-labelmap-padding"), "Changed LABELMAP padding witness")
    require(("PixelPaddingRangeLimit" in ds) == (name == "seg-labelmap-padding-range"), "Changed LABELMAP padding range witness")
    require(("MaximumFractionalValue" in ds) == (name == "seg-labelmap-maximum-fractional"),
            "Changed LABELMAP maximum fractional witness")
    require(("SegmentationFractionalType" in ds) == (name == "seg-labelmap-fractional-type"),
            "Changed LABELMAP fractional type witness")
    require(("SegmentIdentificationSequence" in ds.PerFrameFunctionalGroupsSequence[0])
            == (name == "seg-labelmap-segment-identification"), "Changed LABELMAP segment identification witness")
    require(("RecommendedDisplayCIELabValue" in ds.SegmentSequence[0]) == (name == "seg-labelmap-palette-cielab"),
            "Changed LABELMAP CIELab witness")
    if name == "seg-labelmap-overlap-missing":
        require("SegmentsOverlap" not in ds, "Changed missing overlap witness")
    elif "SegmentsOverlap" in ds:
        require(ds.SegmentsOverlap == ("YES" if name == "seg-labelmap-overlap-yes" else "NO"),
                "Changed LABELMAP overlap witness")
    if ds.PhotometricInterpretation == "PALETTE COLOR":
        for color in ("Red", "Green", "Blue"):
            for suffix in ("Descriptor", "Data"):
                require((color + "PaletteColorLookupTable" + suffix in ds)
                        == (name != "seg-labelmap-palette-missing-lut"), "Changed LABELMAP palette witness")
        require(("ICCProfile" in ds) == (name != "seg-labelmap-palette-missing-icc"),
                "Changed LABELMAP ICC witness")


def surface_witness(name, ds):
    require(all(tag not in ds for tag in ("PixelData", "FloatPixelData", "DoubleFloatPixelData")),
            "Changed surface pixel absence witness")
    require((int(ds.NumberOfSurfaces) == len(ds.SurfaceSequence)) == (name != "surface-count"),
            "Changed surface count witness")
    endian = "<" if ds.file_meta.TransferSyntaxUID.is_little_endian else ">"
    for surface in ds.SurfaceSequence:
        point_set = surface.SurfacePointsSequence[0]
        points = np.frombuffer(point_set.PointCoordinatesData, dtype=endian + "f4").astype(np.float64).reshape(-1, 3)
        require(len(points) == int(point_set.NumberOfSurfacePoints), "Changed point count witness")
        normals = surface.SurfacePointsNormalsSequence[0]
        vectors = np.frombuffer(normals.VectorCoordinateData, dtype=endian + "f4").reshape(-1, 3)
        require(int(normals.VectorDimensionality) == 3 and len(vectors) == len(points), "Changed normal data witness")
        require((int(normals.NumberOfVectors) == len(vectors)) == (name != "surface-normals-count"),
                "Changed normal count witness")
        primitives = surface.SurfaceMeshPrimitivesSequence[0]
        if name == "surface-primitives-empty":
            require(len(primitives) == 0, "Changed empty primitive item witness")
        elif name == "surface-primitives-empty-list":
            require(len(primitives) == 1 and "LongTrianglePointIndexList" in primitives
                    and primitives.LongTrianglePointIndexList is None, "Changed empty primitive list witness")
        else:
            indices = np.frombuffer(primitives.LongTrianglePointIndexList, dtype=endian + "u4").reshape(-1, 3)
            require(bool(np.all((indices >= 1) & (indices <= len(points)))) == (name != "surface-index-bounds"),
                    "Changed primitive index bounds witness")
        require(surface.FiniteVolume == ("MAYBE" if name == "surface-finite-invalid" else "YES"),
                "Changed finite volume witness")
        require(surface.Manifold == ("MAYBE" if name == "surface-manifold-invalid" else "YES"),
                "Changed manifold witness")
        require(surface.SurfaceProcessing == ("YES" if name == "surface-processing-required" else "NO"),
                "Changed surface processing witness")
        if name == "surface-processing-required":
            require("SurfaceProcessingRatio" not in surface and "SurfaceProcessingAlgorithmIdentificationSequence" not in surface,
                    "Changed missing surface processing witness")
        if name == "surface-cube":
            p0, p1, p2 = points[indices.astype(np.int64) - 1].transpose(1, 0, 2)
            area = np.linalg.norm(np.cross(p1 - p0, p2 - p0), axis=1).sum() / 2
            volume = np.einsum("ij,ij->i", p0, np.cross(p1, p2)).sum() / 6
            require(np.isclose(area, 600, rtol=0, atol=1e-6), f"Changed cube area witness: {area}")
            require(np.isclose(volume, 1000, rtol=0, atol=1e-6), f"Changed cube signed volume witness: {volume}")


def witness(name, ds):
    if ds.SOPClassUID == SURFACE_SOP_CLASS:
        surface_witness(name, ds)
        return
    frames = ds.PerFrameFunctionalGroupsSequence
    require(int(ds.NumberOfFrames) == len(frames), "Changed frame count witness")
    if ds.SOPClassUID == LABELMAP_SOP_CLASS:
        labelmap_witness(name, ds)
    elif ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.66.4":
        require(ds.SegmentationType in ("BINARY", "FRACTIONAL"), "Changed segmentation type witness")
        if name == "seg-unknown-referenced-segment":
            numbers = {int(item.SegmentNumber) for item in ds.SegmentSequence}
            require(int(frames[0].SegmentIdentificationSequence[0].ReferencedSegmentNumber) not in numbers, "Changed referenced segment witness")
        if name == "seg-segment-numbers-gap":
            require([int(item.SegmentNumber) for item in ds.SegmentSequence] == [1, 3], "Changed segment numbering witness")
        if name == "seg-derivation-wrong-code":
            require(frames[0].DerivationImageSequence[0].DerivationCodeSequence[0].CodeValue == "113072", "Changed derivation code witness")
        if name == "seg-missing-segment-identification":
            require("SegmentIdentificationSequence" not in frames[0], "Changed segment identification witness")
    else:
        shared = ds.SharedFunctionalGroupsSequence[0]
        if name == "pm-rescale-slope-2":
            require(float(shared.PixelValueTransformationSequence[0].RescaleSlope) == 2, "Changed rescale witness")
        if name == "pm-mixed-frame-type":
            require("MIXED" in shared.ParametricMapFrameTypeSequence[0].FrameType, "Changed frame type witness")
        if name in ("pm-float", "pm-float-bits-16"):
            require("FloatPixelData" in ds and "PixelData" not in ds, "Changed float pixel witness")
        if name == "pm-double":
            require("DoubleFloatPixelData" in ds and "PixelData" not in ds, "Changed double float pixel witness")
        if name == "pm-color-range":
            require(ds.PixelPresentation == "COLOR_RANGE" and "RedPaletteColorLookupTableData" in ds and "ICCProfile" in ds,
                    "Changed color range witness")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    required_versions = {**VERSIONS, "numpy": "2.5.3"}
    versions = {name: importlib.metadata.version(name) for name in required_versions}
    require(versions == required_versions and args.standard_json.parent.name == "2026c", "Changed oracle versions")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names)), log_level=logging.CRITICAL)
    records = []
    files = sorted(args.corpus.glob("*.dcm"))
    require(files, f"No DICOM files found in corpus: {args.corpus}")
    for path in files:
        name = path.stem
        expected = json.loads(path.with_suffix(".json").read_text())
        ds = pydicom.dcmread(path)
        require(ds.SOPClassUID == expected["sopClass"], "Changed SOP Class witness")
        if ds.SOPClassUID == SURFACE_SOP_CLASS:
            pass  # Surface Segmentation stores geometry, not an image pixel array.
        elif name in PIXEL_DECODE_REFUSALS:
            try:
                ds.pixel_array
            except (ValueError, AttributeError, KeyError):
                pass
            else:
                require(False, f"Changed pixel refusal witness for {name}")
        else:
            shape = (int(ds.NumberOfFrames), int(ds.Rows), int(ds.Columns)) if ds.SOPClassUID == LABELMAP_SOP_CLASS else (2, 2, 2)
            require(ds.pixel_array.shape == shape, "Changed native pixel witness")
        witness(name, ds)
        result = validator.validate(path)[str(path)]
        all_errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        group_false_positives = [
            e for e in all_errors if (e[0], e[2]) == FUNCTIONAL_GROUP_FALSE_POSITIVE
            and e[1].startswith(("(5200,9229) / ", "(5200,9230) / "))
        ]
        errors = [e for e in all_errors if e not in group_false_positives]
        require(errors == sorted(INDEPENDENT_ERRORS.get(name, [])), f"Changed independent errors for {name}: {errors}")
        independent = [e for e in errors if e != PALETTE_UID_FALSE_POSITIVE]
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
                                 + [flag for fact in FACTS for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        layers = {layer: outcome for layer, outcome in report["outcomes"].items() if layer != "operation"}
        if command.returncode == 1:
            require("failed" in layers.values(), f"CLI failure has no failed conformance layer for {name}: {layers}")
        limitations = sorted({d["code"] for d in report["diagnostics"] if d["severity"] == "limitation" and d["layer"] != "operation"})
        if expected["outcome"] == "passed" and expected["references"]:
            # The CLI has no target metadata, so supplied-target checks are the only incomplete source.
            require(command.returncode == 2 and layers["references"] == "incomplete" and limitations == ["referenceTargetUnavailable"]
                    and all(outcome == "passed" for layer, outcome in layers.items() if layer != "references"),
                    f"Changed CLI outcome for {name}: {layers} {limitations}")
        else:
            require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode}")
            if expected["outcome"] == "passed":
                require(all(outcome == "passed" for outcome in layers.values()), f"Changed CLI outcome for {name}: {layers}")
        agreement = (expected["outcome"] == "failed") == bool(independent)
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "functionalGroupFalsePositives": len(group_false_positives),
            "falsePositives": len(group_false_positives) + sum(e == PALETTE_UID_FALSE_POSITIVE for e in errors),
            "paletteUIDFalsePositive": PALETTE_UID_FALSE_POSITIVE in errors, "cliLayers": layers, "cliLimitations": limitations,
            "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} Segmentation/Parametric Map cases, {agreements} independent agreements after the documented "
          f"false positives, {len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
