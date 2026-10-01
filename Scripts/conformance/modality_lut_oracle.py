#!/usr/bin/env python3
"""Compare SC Modality LUT requirements, exact rescale and original table evidence."""
import argparse
from decimal import Decimal
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path

import pydicom
from pydicom.pixels import apply_modality_lut
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

PASSED = {"rescale", "zero-slope", "private-units", "lut16"}
FAILED = {"missing-slope", "missing-type", "missing-intercept", "missing-lut-type", "short-data", "extra-data", "lut12", "both", "two-items"}
ERRORS = {
    "missing-slope": [("(0028,1053)", "TagMissing")],
    "missing-type": [("(0028,1054)", "TagMissing")],
    "missing-intercept": [("(0028,1052)", "TagMissing")],
    "missing-lut-type": [("(0028,3000) / (0028,3004)", "TagMissing")],
    "both": [("(0028,1052)", "TagNotAllowed"), ("(0028,3000)", "TagNotAllowed")],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Changed oracle versions")
    require({p.stem for p in args.corpus.glob("*.dcm")} == PASSED | FAILED | {"underflow"}, "Changed corpus")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names)),
                                  log_level=logging.CRITICAL)
    records = []
    for path in sorted(args.corpus.glob("*.dcm")):
        name = path.stem
        own = json.loads(path.with_suffix(".json").read_text())
        expected = "passed" if name in PASSED else "failed" if name in FAILED else "incomplete"
        require(own == {"attributes": expected, "instanceAttributes": "failed" if name in FAILED else "incomplete"}, "Changed own outcomes")
        ds = pydicom.dcmread(path)
        pixels = ds.pixel_array
        require(pixels.shape == (2, 2) and bool((pixels == 1).all()), "Changed native pixels")
        witness = {}
        if "RescaleSlope" in ds:
            slope = Decimal(ds.RescaleSlope.original_string)
            require(slope == Decimal("0" if name == "zero-slope" else "1E-999" if name == "underflow" else ".5"), "Changed slope")
            witness["slope"] = str(slope)
        if "ModalityLUTSequence" in ds:
            items = ds.ModalityLUTSequence
            require(len(items) == (2 if name == "two-items" else 1), "Changed item count")
            require(list(items[0].LUTDescriptor) == [2, 0, 12 if name == "lut12" else 16], "Changed descriptor")
            value = items[0].LUTData
            count = len(value) if hasattr(value, "__len__") else 1
            require(count == (1 if name == "short-data" else 3 if name == "extra-data" else 2), "Changed LUT source length")
            witness["entries"] = count
        if name in PASSED:
            rendered = apply_modality_lut(pixels, ds)
            require(bool((rendered == (65535 if name == "lut16" else -1 if name == "zero-slope" else -.5)).all()), "Changed independent transform")
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        expected_errors = [("Modality LUT", tag, code) for tag, code in ERRORS.get(name, [])]
        require(errors == expected_errors and result.errors == len(errors), "Changed independent diagnostics")
        require(result.status.name == ("Failed" if errors else "Passed"), "Changed independent status")
        gap = "Independent IOD validator does not enforce this table length/precision/cardinality rule." if name in FAILED and not errors else None
        if name == "underflow":
            gap = "Exact positive DS exceeds local Decimal precision; independent IOD presence validation does not qualify arithmetic."
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **own,
                        "independentOutcome": result.status.name, "errors": errors, "witness": witness, "gap": gap})
    args.output.write_text(json.dumps({"versions": versions, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    print(f"PASS: {len(records)} SC modality cases, independent IOD checks and four exact transform results")


if __name__ == "__main__":
    main()
