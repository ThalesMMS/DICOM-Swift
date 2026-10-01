#!/usr/bin/env python3
"""Check declared padding metadata without inferring the unpadded acquisition region."""

import argparse
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
PASSED = {"baseline", "single", "range", "mono1-range", "signed"}
ERRORS = {"missing-value": "TagMissing", "empty-value": "TagEmpty"}
GAPS = {"overflow", "range-overflow", "signed-underflow", "reversed", "mono1-reversed"}
CASES = PASSED | ERRORS.keys() | GAPS


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
        require(own == {"attributes": "passed" if name in PASSED else "failed",
                        "instanceAttributes": "incomplete" if name in PASSED else "failed",
                        "instanceGeometry": "passed"}, "Changed composed evidence: " + name)
        ds = dcmread(path)
        require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.7" and "Manufacturer" in ds, "Wrong carrier IOD")
        require(ds.pixel_array.shape == (2, 2) and bool((ds.pixel_array == 1).all()), "Changed independent pixel decode")
        values = [getattr(ds, key, None) for key in ["PixelPaddingValue", "PixelPaddingRangeLimit"]]
        expected = {"baseline": [None, None], "single": [0, None], "range": [0, 10], "overflow": [256, None],
                    "range-overflow": [0, 256], "reversed": [10, 0], "missing-value": [None, 10],
                    "empty-value": [None, 10], "mono1-range": [255, 250], "mono1-reversed": [250, 255],
                    "signed": [-128, None], "signed-underflow": [-129, None]}[name]
        require(values == expected and ds.BitsStored == 8, "Changed original numeric witness")
        require(ds.PixelRepresentation == int(name.startswith("signed")), "Changed signedness")
        require(ds.PhotometricInterpretation == ("MONOCHROME1" if name.startswith("mono1") else "MONOCHROME2"), "Changed polarity")
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items()
                        for tag, error in tags.items())
        expected_errors = [("General Equipment", "(0028,0120)", ERRORS[name])] if name in ERRORS else []
        require(errors == expected_errors and result.errors == len(errors), "Changed independent diagnostics: " + name)
        require(result.status.name == ("Failed" if errors else "Passed"), "Changed independent outcome")
        results.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **own,
                        "independentOutcome": result.status.name, "errors": errors, "paddingValues": values,
                        "gap": "Oracle does not enforce stored-domain bounds or photometric interval order." if name in GAPS else None})
    args.output.write_text(json.dumps({"versions": versions,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in filenames},
        "scope": "Declared integer padding in classic images; not acquisition-region, floating padding or complete IOD qualification.",
        "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} padding cases, independent numeric witnesses, IOD diagnostics and pixel decodes")


if __name__ == "__main__":
    main()
