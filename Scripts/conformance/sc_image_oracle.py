#!/usr/bin/env python3
"""Compare synthetic SC calibration cases using exact source witnesses and pinned IOD diagnostics."""

import argparse
from decimal import Decimal
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path

from pydicom import dcmread
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo

from image_iod_oracle import VERSIONS, require


REQUIRED_VERSIONS = {**VERSIONS, "numpy": "2.5.3"}
PASSED = {"baseline", "delimiter-only-spacing", "calibrated", "matching-spacing", "inferred-calibration", "matching-aspect",
          "zero-single-row", "document-code"}
INCOMPLETE = {"unknown-calibration", "decimal-underflow"}
ERRORS = {
    "missing-description": [("SC Image", "(0028,0A04)", "TagMissing")],
    "empty-description": [("SC Image", "(0028,0A04)", "TagEmpty")],
    "invalid-type": [("SC Image", "(0028,0A02)", "EnumValueNotAllowed")],
    "document-missing-meaning": [("SC Image", "(0040,E008) / (0008,0104)", "TagMissing")],
}
GAPS = {
    "missing-spacing": "Oracle does not receive the caller's known calibrated-image fact.",
    "unknown-calibration": "Oracle does not retain an unresolved calibration condition.",
    "contradictory-fact": "Oracle does not receive the caller's uncalibrated-image fact.",
    "mismatching-spacing": "Oracle does not receive the caller fact or compare acquisition spacing.",
    "reversed-aspect": "Oracle does not compare Nominal Scanned Pixel Spacing with Pixel Aspect Ratio.",
    "precise-aspect": "Oracle does not check the exact ratio; no floating-point tolerance is appropriate.",
    "zero-invalid": "Oracle does not condition zero spacing on the corresponding dimension being one.",
    "decimal-underflow": "Exact source value is positive, but outside the component's decimal arithmetic range.",
    "document-empty": "Oracle accepts an empty optional Document Class Code Sequence.",
}
CASES = PASSED | INCOMPLETE | set(ERRORS) | set(GAPS)


def fact(name):
    if name in {"unknown-calibration", "calibrated", "missing-description", "empty-description", "inferred-calibration"}:
        return "undetermined"
    return "satisfied" if name in {"missing-spacing", "invalid-type"} else "unsatisfied"


def decimals(values):
    return [Decimal(value.original_string) for value in values]


def witness(name, ds):
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.7", "Wrong carrier IOD")
    pixels = ds.pixel_array
    require(pixels.shape == (ds.Rows, 2) and bool((pixels == 1).all()), "Changed independent pixel decode")
    if name in {"baseline", "unknown-calibration", "missing-spacing"}:
        require(all(tag not in ds for tag in [0x00280030, 0x00280A02, 0x00182010, 0x00181164]), "Changed absent calibration evidence")
    elif name == "delimiter-only-spacing":
        require(list(ds.NominalScannedPixelSpacing) == ["", ""], "Missing delimiter-only empty value witness")
    elif name == "contradictory-fact":
        require(ds.PixelSpacingCalibrationType == "FIDUCIAL" and len(ds.PixelSpacing) == 2, "Missing calibration declaration")
    elif name in {"matching-spacing", "mismatching-spacing", "inferred-calibration"}:
        require((decimals(ds.PixelSpacing) == decimals(ds.NominalScannedPixelSpacing)) == (name == "matching-spacing"),
                "Changed exact acquisition-spacing comparison")
    elif name in {"matching-aspect", "reversed-aspect", "precise-aspect"}:
        row, column = decimals(ds.NominalScannedPixelSpacing)
        vertical, horizontal = map(int, ds.PixelAspectRatio)
        require((row * horizontal == column * vertical) == (name == "matching-aspect"), "Changed exact aspect comparison")
    elif name in {"zero-invalid", "zero-single-row", "decimal-underflow"}:
        row, column = decimals(ds.NominalScannedPixelSpacing)
        require(column == 1 and ds.Rows == (2 if name == "zero-invalid" else 1), "Changed spacing dimension witness")
        require(row == (Decimal("1E-999") if name == "decimal-underflow" else 0), "Changed exact zero/underflow witness")
    elif name == "document-empty":
        require(len(ds.DocumentClassCodeSequence) == 0, "Changed empty sequence witness")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in REQUIRED_VERSIONS}
    require(versions == REQUIRED_VERSIONS and args.standard_json.parent.name == "2026c", "Unexpected oracle/standard versions")
    require({p.stem for p in args.corpus.glob("*.dcm")} == CASES, "Missing or unexpected cases")
    filenames = ["dict_info.json", "iod_info.json", "module_info.json"]
    info = DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in filenames))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for name in sorted(CASES):
        path = args.corpus / (name + ".dcm")
        own = json.loads(path.with_suffix(".json").read_text())
        expected = "passed" if name in PASSED else "incomplete" if name in INCOMPLETE else "failed"
        require(own == {"attributes": expected, "instanceAttributes": expected,
                        "calibratedImage": fact(name)}, "Changed component/instance outcome: " + name)
        witness(name, dcmread(path))
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items()
                        for tag, error in tags.items())
        require(errors == sorted(ERRORS.get(name, [])) and result.errors == len(errors), "Changed independent diagnostics: " + name)
        require(result.status.name == ("Failed" if errors else "Passed"), "Changed independent outcome")
        results.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **own,
                        "independentOutcome": result.status.name, "errors": errors, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in filenames},
        "scope": "SC calibration attributes and code structure; not acquisition physics, complete IOD or operation qualification.",
        "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} SC cases, exact spacing witnesses and independent IOD diagnostics and pixel decodes")


if __name__ == "__main__":
    main()
