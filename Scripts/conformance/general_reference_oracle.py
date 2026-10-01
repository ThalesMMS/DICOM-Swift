#!/usr/bin/env python3
"""Compare General Reference with independent IOD and identity witnesses."""
import argparse
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path
import subprocess

import pydicom
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

ERRORS = {
    "missing-class": ("(0008,1140) / (0008,1150)", "TagMissing"),
    "missing-instance": ("(0042,0013) / (0008,1155)", "TagMissing"),
    "missing-purpose": ("(0008,114A) / (0040,A170)", "TagMissing"),
    "reoriented-missing-orientation": ("(0008,2112) / (0020,0020)", "TagMissing"),
    "invalid-preservation": ("(0008,2112) / (0028,135A)", "EnumValueNotAllowed"),
}
CONFLICTS = {"wrong-image-role", "wrong-instance-role"}
VALID = {"image", "instance", "source-image", "source-instance", "reoriented"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Changed oracle versions")
    require({p.stem for p in args.corpus.glob("*.dcm")} == set(ERRORS) | CONFLICTS | VALID, "Changed corpus")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names)), log_level=logging.CRITICAL)
    records = []
    for path in sorted(args.corpus.glob("*.dcm")):
        name = path.stem
        expected = {"attributes": "failed" if name in ERRORS else "incomplete",
                    "references": "failed" if name in CONFLICTS else "incomplete", "exit": 2 if name in VALID else 1}
        require(json.loads(path.with_suffix(".json").read_text()) == expected, "Changed expected outcomes")
        ds = pydicom.dcmread(path)
        require(ds.pixel_array.shape == (2, 2) and bool((ds.pixel_array == 1).all()), "Changed native pixels")
        witness = None
        if name == "wrong-image-role":
            require(ds.ReferencedImageSequence[0].ReferencedSOPClassUID == "1.2.840.10008.5.1.4.1.1.88.33", "Changed non-image witness")
            witness = "Comprehensive SR is a document, not an image SOP Class."
        if name == "wrong-instance-role":
            require(ds.ReferencedInstanceSequence[0].ReferencedSOPClassUID == "1.2.840.10008.5.1.4.1.1.7", "Changed image witness")
            witness = "SC Image is an image SOP Class, not a non-image instance."
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        require(errors == ([("General Reference", *ERRORS[name])] if name in ERRORS else []), "Changed independent errors")
        require(result.errors == len(errors) and result.status.name == ("Failed" if errors else "Passed"), "Changed independent status")
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        require(command.returncode == expected["exit"], "Changed CLI exit")
        require(all(report["outcomes"][layer] == expected[layer] for layer in ["attributes", "references"]), "Changed CLI outcome")
        codec = subprocess.run([str(args.binary), "codec", "validate", str(path), "--format", "json"], capture_output=True, text=True, timeout=30)
        require(json.loads(codec.stdout)["conformance"] == report, "Changed codec conformance")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "roleWitness": witness,
            "gap": "Independent IOD validator does not check image/non-image SOP applicability." if name in CONFLICTS else
                   "External IOD acceptance does not prove target availability or reference purpose/derivation meaning." if name in VALID else None})
    args.output.write_text(json.dumps({"versions": versions, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    print(f"PASS: {len(records)} general reference cases, independent IOD/role evidence and real CLI parity")


if __name__ == "__main__":
    main()
