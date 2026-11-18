#!/usr/bin/env python3
"""Compare classic Image Plane evidence without mistaking IOD presence checks for geometry validation."""

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


GEOMETRY_PASSED = {"baseline", "rational-oblique", "negative-position", "zero-spacing-single-row", "missing-thickness", "rounded-oblique"}
GEOMETRY_FAILED = {"negative-slice-spacing", "negative-pixel-spacing", "zero-spacing-invalid", "orientation-range",
                   "zero-vector", "parallel-vectors", "nonorthogonal-unit-vectors", "nonunit-vectors"}
ERRORS = {
    "missing-position": [("Image Plane", "(0020,0032)", "TagMissing")],
    "missing-orientation": [("Image Plane", "(0020,0037)", "TagMissing")],
    "missing-spacing": [("Image Plane", "(0028,0030)", "TagMissing")],
    "missing-thickness": [("Image Plane", "(0018,0050)", "TagMissing")],
}
GAPS = {
    "negative-slice-spacing": "Oracle does not enforce nonnegative spacing for this classic image profile.",
    "negative-pixel-spacing": "Oracle does not check positive pixel spacing.",
    "zero-spacing-invalid": "Oracle does not condition zero spacing on the corresponding dimension.",
    "orientation-range": "Oracle does not check direction cosine range.",
    "zero-vector": "Oracle does not check nonzero basis vectors.",
    "parallel-vectors": "Oracle does not detect a degenerate encoded basis.",
    "nonorthogonal-unit-vectors": "Oracle does not compare exact unit-vector orthogonality.",
    "nonunit-vectors": "Oracle does not check unit length; the engine bounds the deviation by the encoded decimal precision.",
    "position-underflow": "Source decimal is valid but outside the component's exact arithmetic range.",
    "position-multiplicity": "Oracle does not report invalid position VM; our original-byte VR/VM layer fails it.",
}
CASES = GEOMETRY_PASSED | GEOMETRY_FAILED | set(ERRORS) | set(GAPS)


def decimals(values):
    return [Decimal(value.original_string) for value in values]


def witness(name, ds):
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.7", "Wrong carrier IOD")
    pixels = ds.pixel_array
    require(pixels.shape == (ds.Rows, 2) and bool((pixels == 1).all()), "Changed independent pixel decode")
    if name == "negative-slice-spacing":
        require(Decimal(ds.SpacingBetweenSlices.original_string) < 0, "Missing negative slice spacing")
    elif name == "negative-pixel-spacing":
        require(decimals(ds.PixelSpacing)[0] < 0, "Missing negative pixel spacing")
    elif name in {"zero-spacing-invalid", "zero-spacing-single-row"}:
        require(decimals(ds.PixelSpacing) == [0, 1] and ds.Rows == (1 if name.endswith("single-row") else 2), "Wrong zero dimension")
    elif name == "position-underflow":
        require(decimals(ds.ImagePositionPatient) == [Decimal("1E-999"), 0, 0], "Missing exact underflow witness")
    elif name == "position-multiplicity":
        require(len(ds.ImagePositionPatient) == 2, "Missing source VM violation")
    if "ImageOrientationPatient" not in ds:
        return None
    values = decimals(ds.ImageOrientationPatient)
    row, column = values[:3], values[3:]
    dot = sum(a * b for a, b in zip(row, column))
    norm_row, norm_column = sum(a * a for a in row), sum(a * a for a in column)
    cross = [row[a] * column[b] - row[b] * column[a] for a, b in [(1, 2), (2, 0), (0, 1)]]
    if name == "orientation-range":
        require(any(abs(value) > 1 for value in values), "Missing cosine range violation")
    elif name == "zero-vector":
        require(norm_row == 0, "Missing zero vector")
    elif name == "parallel-vectors":
        require(cross == [0, 0, 0] and norm_row > 0 and norm_column > 0, "Missing degenerate basis")
    elif name == "nonorthogonal-unit-vectors":
        require(norm_row == norm_column == 1 and dot != 0, "Missing exact orthogonality violation")
    elif name == "rounded-oblique":
        # Eight encoded decimals bound each cosine by 5E-9; the squared norm deviates by less than that bound allows.
        require(norm_row != 1 and abs(norm_row - 1) <= 4 * Decimal("0.70710678") * Decimal("5E-9") + 2 * Decimal("5E-9") ** 2
                and dot == 0, "Missing rounded-basis witness")
    elif name == "nonunit-vectors":
        require(norm_row == norm_column == Decimal("0.25") and dot == 0, "Missing non-unit witness")
    else:
        require(norm_row == norm_column == 1 and dot == 0, "Changed exact baseline basis")
    return {"rowSquared": str(norm_row), "columnSquared": str(norm_column), "dot": str(dot), "cross": list(map(str, cross))}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Unexpected oracle/standard versions")
    require({p.stem for p in args.corpus.glob("*.dcm")} == CASES, "Missing or unexpected cases")
    filenames = ["dict_info.json", "iod_info.json", "module_info.json"]
    info = DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in filenames))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for name in sorted(CASES):
        path = args.corpus / (name + ".dcm")
        own = json.loads(path.with_suffix(".json").read_text())
        geometry = "passed" if name in GEOMETRY_PASSED else "failed" if name in GEOMETRY_FAILED else "incomplete"
        attributes = "failed" if name in ERRORS else "incomplete" if name == "position-multiplicity" else "passed"
        require(own == {"attributes": attributes, "geometry": geometry, "instanceGeometry": geometry,
                        "instanceAttributes": "failed" if name in ERRORS or name in {"negative-pixel-spacing", "zero-spacing-invalid"} else attributes,
                        "instanceVRVM": "failed" if name == "position-multiplicity" else "passed"}, "Changed composed evidence: " + name)
        math = witness(name, dcmread(path))
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items()
                        for tag, error in tags.items())
        require(errors == sorted(ERRORS.get(name, [])) and result.errors == len(errors), "Changed independent diagnostics: " + name)
        require(result.status.name == ("Failed" if errors else "Passed"), "Changed independent outcome")
        results.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **own,
                        "independentOutcome": result.status.name, "errors": errors, "decimalWitness": math, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": {**versions, "numpy": importlib.metadata.version("numpy")},
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in filenames},
        "scope": "Single-plane attributes and exact encoded basis checks; not complete IOD, rounding, series or operation qualification.",
        "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} Image Plane cases, exact decimal witnesses, independent IOD diagnostics and pixel decodes")


if __name__ == "__main__":
    main()
