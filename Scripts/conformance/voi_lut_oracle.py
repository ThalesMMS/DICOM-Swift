#!/usr/bin/env python3
"""Compare classic image VOI evidence without confusing tolerant display with conformance."""

import argparse
from decimal import Decimal
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path

from pydicom import dcmread
from pydicom.pixels import apply_windowing
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo

from image_iod_oracle import VERSIONS, require


PASSED = {"linear-threshold", "exact-fractional", "sigmoid-fractional", "lut16", "lut8-packed", "alternatives"}
FAILED = {"linear-fractional", "zero-width", "negative-width", "count-mismatch", "missing-width", "lut16-extra", "lut16-short", "lut12"}
INCOMPLETE = {"private-function", "empty-function", "width-underflow", "lut8-legacy"}
CASES = PASSED | FAILED | INCOMPLETE


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
        expected = "passed" if name in PASSED else "failed" if name in FAILED else "incomplete"
        require(own == {"attributes": expected, "instanceAttributes": "failed" if name in FAILED else "incomplete", "geometry": "passed"},
                "Changed composed evidence: " + name)
        ds = dcmread(path)
        pixels = ds.pixel_array
        require(pixels.shape == (2, 2) and bool((pixels == 1).all()), "Changed independent pixel decode")
        witness = {}
        window_result = None
        if "WindowWidth" in ds:
            width = Decimal(ds.WindowWidth.original_string)
            expected_width = {"linear-fractional": ".5", "zero-width": "0", "negative-width": "-1", "exact-fractional": ".5",
                              "sigmoid-fractional": ".5", "private-function": "-1", "width-underflow": "1E-999"}.get(name, "1")
            require(width == Decimal(expected_width), "Changed exact width witness")
            witness["width"] = str(width)
            if name == "count-mismatch":
                require(len(ds.WindowCenter) == 2, "Missing center/width cardinality violation")
            try:
                rendered = apply_windowing(pixels, ds)
                window_result = "applied"
                require(rendered.shape == (2, 2), "Changed independent window result shape")
            except ValueError:
                window_result = "rejected"
            rejected = {"linear-fractional", "zero-width", "negative-width", "private-function", "empty-function", "width-underflow"}
            require(window_result == ("rejected" if name in rejected else "applied"), "Changed independent window behavior")
        if "VOILUTSequence" in ds:
            lut = ds.VOILUTSequence[0]
            bits = 8 if name.startswith("lut8") else 12 if name == "lut12" else 16
            require(list(lut.LUTDescriptor) == [2, 0, bits], "Changed LUT descriptor witness")
            value = lut.LUTData
            length = len(value) if isinstance(value, bytes) else 2 * (len(value) if hasattr(value, "__len__") else 1)
            expected_length = {"lut16-extra": 6, "lut16-short": 2, "lut8-packed": 2}.get(name, 4)
            require(length == expected_length, "Changed original LUT length witness")
            witness.update({"bits": bits, "lutBytes": length})
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        expected_errors = [("VOI LUT", "(0028,1051)", "TagMissing")] if name == "missing-width" else []
        require(errors == expected_errors and result.errors == len(errors), "Changed independent diagnostics: " + name)
        require(result.status.name == ("Failed" if errors else "Passed"), "Changed independent outcome")
        gap = None
        if name in FAILED - {"missing-width"}:
            gap = "IOD oracle does not enforce this numeric/cardinality/LUT payload constraint."
        elif name == "width-underflow":
            gap = "Source DS is positive; pydicom's float conversion underflows and its windowing rejects zero. Exact conversion is unavailable here."
        elif name in {"private-function", "empty-function"}:
            gap = "Unsupported or unspecified function semantics are not proof of invalid Defined Terms."
        elif name == "lut8-legacy":
            gap = "Legacy word-padded 8-bit representation remains unqualified; tolerant reading does not approve its encoding."
        results.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **own,
                        "independentOutcome": result.status.name, "errors": errors, "witness": witness,
                        "independentWindowing": window_result, "gap": gap})
    args.output.write_text(json.dumps({"versions": {**versions, "numpy": importlib.metadata.version("numpy")},
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in filenames},
        "scope": "Classic image VOI attributes and source table checks; not complete grayscale pipeline or legacy/Big Endian 8-bit qualification.",
        "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} VOI cases, exact widths, LUT lengths, independent IOD/windowing and native decodes")


if __name__ == "__main__":
    main()
