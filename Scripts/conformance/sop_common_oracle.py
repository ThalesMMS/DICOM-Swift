#!/usr/bin/env python3
"""Compare selected SOP Common rules with pinned independent IOD validation."""

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


ENUMS = {
    "status-invalid": (0x01000410, "LOCAL"),
    "synthetic-invalid": (0x0008001C, "MAYBE"),
    "origin-invalid": (0x04000600, "REMOTE"),
    "qualification-invalid": (0x00189004, "CLINICAL"),
    "temporal-invalid": (0x00280303, "YES"),
}
MISSING = {
    "equipment-manufacturer-missing": (0x0018A001, 0x00080070),
    "equipment-purpose-missing": (0x0018A001, 0x0040A170),
    "mapping-resource-missing": (0x00080124, 0x00080105),
    "scheme-designator-missing": (0x00080110, 0x00080102),
}
TIMEZONES = {"timezone-negative-zero": b"-0000 ", "timezone-leading-space": b" +0000", "timezone-range": b"+1401 "}
CASES = {"baseline", "status-valid", "timezone-valid", "equipment-valid"} | ENUMS.keys() | MISSING.keys() | TIMEZONES.keys()


def tag_name(tag):
    return f"({tag >> 16:04X},{tag & 0xFFFF:04X})"


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
        source = path.read_bytes()
        own = json.loads(path.with_suffix(".json").read_text())
        expected = "failed" if name in ENUMS or name in MISSING or name in TIMEZONES else "incomplete" if name == "equipment-valid" else "passed"
        require(own == {"attributes": expected, "instanceAttributes": "failed" if expected == "failed" else "incomplete",
                        "instanceGeometry": "passed"}, "Changed composed evidence: " + name)
        ds = dcmread(path)
        require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.7", "Wrong carrier IOD")
        require(ds.pixel_array.shape == (2, 2) and bool((ds.pixel_array == 1).all()), "Changed independent pixel decode")
        expected_errors = []
        if name in ENUMS:
            tag, value = ENUMS[name]
            require(ds[tag].value == value, "Missing enum witness")
            expected_errors = [("SOP Common", tag_name(tag), "EnumValueNotAllowed")]
        elif name in MISSING:
            parent, child = MISSING[name]
            require(child not in ds[parent].value[0], "Missing sequence witness")
            expected_errors = [("SOP Common", tag_name(parent) + " / " + tag_name(child), "TagMissing")]
        elif name in TIMEZONES:
            # pydicom trims SH; inspect the explicit-VR source rather than accepting that repair.
            header = bytes.fromhex("0800010253480600")
            require(source.count(header) == 1 and source.split(header)[1][:6] == TIMEZONES[name], "Missing original timezone witness")
        elif name == "status-valid":
            require(ds.SOPInstanceStatus == "OR", "Changed valid status")
        elif name == "timezone-valid":
            require(ds.TimezoneOffsetFromUTC == "+0545", "Changed valid timezone")
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items()
                        for tag, error in tags.items())
        require(errors == expected_errors and result.errors == len(errors), "Changed independent diagnostics: " + name)
        require(result.status.name == ("Failed" if errors else "Passed"), "Changed independent outcome")
        gap = "Oracle does not enforce C.12.1.1.8 timezone grammar/range." if name in TIMEZONES else (
            "Code meaning and registry membership remain unqualified in our component." if name == "equipment-valid" else None)
        results.append({"case": name, "sha256": hashlib.sha256(source).hexdigest(), **own,
                        "independentOutcome": result.status.name, "errors": errors, "gap": gap})
    args.output.write_text(json.dumps({"versions": versions,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in filenames},
        "scope": "Selected SOP Common attributes; not complete IOD, history, registry or security qualification.",
        "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} SOP Common cases, original timezone bytes, independent IOD diagnostics and pixel decodes")


if __name__ == "__main__":
    main()
