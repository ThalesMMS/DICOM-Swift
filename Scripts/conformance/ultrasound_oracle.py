#!/usr/bin/env python3
"""Compare the .6.1 US corpus with pinned dicom-validator and independent pydicom pixel/palette witnesses."""
import argparse
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path
import subprocess

import pydicom
from pydicom.pixels import apply_color_lut
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

ERRORS = {
    "us-components-2-missing-required": [("US Region Calibration", "(0018,6011) / (0018,605A)", "TagMissing")],
    "us-components-3-missing-required": [("US Region Calibration", "(0018,6011) / (0040,9098)", "TagMissing")],
    "us-contrast-missing-agent": [("Contrast/Bolus", "(0018,0010)", "TagMissing")],
    "us-empty-regions": [("US Region Calibration", "(0018,6011)", "TagEmpty")],
    "us-ivus-missing-acquisition-time": [("US Image", "(0008,002A)", "TagMissing")],
    "us-ivus-missing-rate": [("US Image", "(0018,3101)", "TagMissing")],
    "us-missing-image-type": [("US Image", "(0008,0008)", "TagMissing")],
    "us-palette-missing-green": [("Image Pixel", "(0028,1202)", "TagMissing")],
    "us-palette-short-data": [("Image Pixel", "(0028,1203)", "TagEmpty"), ("Palette Color Lookup Table", "(0028,1203)", "TagEmpty")],
    "us-region-invalid-data-type": [("US Region Calibration", "(0018,6011) / (0018,6014)", "EnumValueNotAllowed")],
    "us-region-invalid-unit": [("US Region Calibration", "(0018,6011) / (0018,6024)", "EnumValueNotAllowed")],
    "us-region-missing-delta": [("US Region Calibration", "(0018,6011) / (0018,602C)", "TagMissing")],
    "us-signed-pixels": [("US Image", "(0028,0103)", "EnumValueNotAllowed")],
    "us-sync-missing-uid": [("Synchronization", "(0018,106A)", "TagMissing"), ("Synchronization", "(0020,0200)", "TagMissing")],
    "us-voi-missing-width": [("VOI LUT", "(0028,1051)", "TagMissing")],
}
PALETTE_FALSE_POSITIVES = [("Image Pixel", f"(0028,120{channel})", "TagMissing") for channel in range(1, 4)]
GAPS = {
    "us-bits-16": "C.8.5.6.1.13 requires 8 allocated bits for MONOCHROME2; the oracle does not compose this specialization.",
    "us-bits-stored": "C.8.5.6.1.14 requires Bits Stored to equal Bits Allocated; the oracle does not cross-check them.",
    "us-components-0-missing-required": "The oracle does not extract the Bit aligned organization condition for the mask.",
    "us-components-1-missing-required": "The oracle does not extract the Ranges organization condition for range endpoints.",
    "us-components-table-count": "The oracle does not compare table lengths with Number of Table Entries.",
    "us-contrast-missing-module": "Contrast administration is a stated acquisition fact unavailable to the independent validator.",
    "us-invalid-icc": "The oracle checks the presence of ICC Profile, without interpreting its binary header.",
    "us-overlay-missing-subtype": "The oracle does not resolve Active Image Area Overlay Group to the repeated Overlay Subtype.",
    "us-overlay-missing-target": "The oracle does not resolve the overlay group referenced by a calibrated region.",
    "us-overlay-offset": "The oracle does not compare the one-based overlay origin with the zero-based region bounds.",
    "us-region-component-without-organization": "C.8.5.5.1.4 defines absent organization as no component calibration; the oracle misses the prohibition.",
    "us-region-outside-image": "The oracle does not compare region coordinates with Rows and Columns.",
    "us-region-reserved-flags": "The oracle does not enforce the reserved bits of Region Flags (bits 5-31 shall be zero).",
    "us-region-reversed": "The oracle does not compare the minimum and maximum region coordinates.",
    "us-short-pixels": "The IOD validator does not inspect Pixel Data length; pydicom independently rejects the truncated pixels.",
    "us-staged-missing-counts": "Staged protocol acquisition is a stated fact unavailable to the independent validator.",
    "us-reference-target-unavailable": "The independent validator does not resolve referenced instances; the engine explicitly keeps them incomplete.",
    "us-unknown-acquisition-facts": "The independent validator skips conditions it cannot derive; the engine keeps unstated facts incomplete.",
}


EXPECTED_CASES = {
    "us-bits-16", "us-bits-stored", "us-components-0", "us-components-0-missing-required", "us-components-1",
    "us-components-1-missing-required", "us-components-2", "us-components-2-missing-required", "us-components-3",
    "us-components-3-missing-required", "us-components-table-count", "us-contrast", "us-contrast-missing-agent",
    "us-contrast-missing-module", "us-empty-regions", "us-invalid-icc", "us-ivus-gated",
    "us-ivus-missing-acquisition-time", "us-ivus-missing-rate", "us-ivus-motor", "us-missing-image-type",
    "us-monochrome", "us-negative-delta-and-outside-reference", "us-non-square-pixels", "us-overlay",
    "us-overlay-missing-subtype", "us-overlay-missing-target", "us-overlay-offset", "us-palette-16", "us-palette-8",
    "us-palette-missing-green", "us-palette-short-data", "us-reference-target-unavailable", "us-region",
    "us-region-component-without-organization", "us-region-invalid-data-type", "us-region-invalid-unit",
    "us-region-missing-delta", "us-region-outside-image", "us-region-reserved-flags", "us-region-reversed",
    "us-rgb", "us-segmented-palette", "us-short-pixels", "us-signed-pixels", "us-staged",
    "us-staged-missing-counts", "us-sync-missing-uid", "us-unknown-acquisition-facts", "us-voi",
    "us-voi-missing-width",
}


def witness(name, ds):
    if name == "us-short-pixels":
        try:
            _ = ds.pixel_array
        except ValueError:
            return "pixel-length-rejected"
        raise AssertionError("pydicom must independently reject the short pixel payload")
    pixels = ds.pixel_array
    require(pixels.shape[:2] == (2, 2), "Changed source pixel geometry")
    if name == "us-bits-16":
        require(ds.PhotometricInterpretation == "MONOCHROME2" and ds.BitsAllocated == 16, "Changed bit-depth witness")
    if name == "us-bits-stored":
        require(ds.BitsStored != ds.BitsAllocated, "Changed stored-depth witness")
    if name.startswith("us-components-") or name.startswith("us-region-"):
        regions = ds.get("SequenceOfUltrasoundRegions", [])
        if name == "us-region-reserved-flags":
            require(regions[0].RegionFlags & ~31 != 0, "Changed reserved flag witness")
        if name == "us-region-outside-image":
            require(regions[0].RegionLocationMaxX1 >= ds.Columns, "Changed region extent witness")
        if name == "us-region-reversed":
            require(regions[0].RegionLocationMinX0 > regions[0].RegionLocationMaxX1, "Changed region order witness")
        if name == "us-components-table-count":
            require(len(regions[0].TableOfPixelValues) != regions[0].NumberOfTableEntries, "Changed table count witness")
    if name in ["us-palette-8", "us-palette-16", "us-segmented-palette"]:
        rgb = apply_color_lut(pixels, ds)
        require(rgb.shape == (2, 2, 3) and (rgb[0, 0] == 0).all(), "Changed independently expanded palette")
        require((rgb[0, 1] == (255 if name == "us-palette-8" else 65535)).all(), "Changed palette endpoint")
        return "pixels-and-palette-decoded"
    return "pixels-decoded"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    paths = sorted(args.corpus.glob("*.dcm"))
    require({path.stem for path in paths} == EXPECTED_CASES, "Changed corpus membership")
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Changed oracle versions")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names)), log_level=logging.CRITICAL)
    records = []
    for path in paths:
        name = path.stem
        expected = json.loads(path.with_suffix(".json").read_text())
        ds = pydicom.dcmread(path)
        require(str(ds.SOPClassUID) == "1.2.840.10008.5.1.4.1.1.6.1", "Corpus must contain only the qualified US SOP Class")
        decoded = witness(name, ds)
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        false_positives = PALETTE_FALSE_POSITIVES if name == "us-segmented-palette" else []
        require(errors == sorted(ERRORS.get(name, []) + false_positives), f"Changed independent errors for {name}: {errors}")
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
            + [flag for fact in expected["facts"] for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode}: {command.stderr}")
        report = json.loads(command.stdout)
        layers = {key: value for key, value in report["outcomes"].items() if key != "operation"}
        if expected["exit"] == 0:
            require(all(value == "passed" for value in layers.values()), f"Changed CLI layers for {name}")
        independent = sorted(set(errors) - set(false_positives))
        require((expected["outcome"] == "passed") == (not independent) or name in GAPS, f"Unexplained disagreement for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "cliLayers": layers,
            "pixelWitness": decoded, "gap": GAPS.get(name), "paletteFalsePositives": bool(false_positives)})
    require(len(records) == 51, "Changed corpus membership")
    args.output.write_text(json.dumps({"versions": versions, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    print(f"PASS: {len(records)} US cases, CLI exits and layer evidence; {len(GAPS)} documented oracle gaps; "
          "C.7.9 palette precedence checked against independently expanded pixel values")


if __name__ == "__main__":
    main()
