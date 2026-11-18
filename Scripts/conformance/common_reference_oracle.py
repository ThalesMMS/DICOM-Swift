#!/usr/bin/env python3
"""Compare SC reference hierarchies with independent IOD and identity witnesses."""
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
    "empty-instances": ("(0008,1115) / (0008,114A)", "TagEmpty"),
    "empty-series": ("(0008,1115)", "TagEmpty"),
    "missing-class": ("(0008,1115) / (0008,114A) / (0008,1150)", "TagMissing"),
    "missing-instance": ("(0008,1115) / (0008,114A) / (0008,1155)", "TagMissing"),
    "missing-series-uid": ("(0008,1115) / (0020,000E)", "TagMissing"),
    "missing-study": ("(0008,1200) / (0020,000D)", "TagMissing"),
}
CONFLICTS = {"conflicting-hierarchies", "current-as-other"}
VALID = {"same-study", "other-study", "both-hierarchies"}


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
                    # An empty hierarchy fails as attributes and leaves nothing to resolve in the references layer.
                    "references": "failed" if name in CONFLICTS else "passed" if name in {"empty-series", "empty-instances"} else "incomplete",
                    "exit": 2 if name in VALID else 1}
        require(json.loads(path.with_suffix(".json").read_text()) == expected, "Changed expected outcomes")
        ds = pydicom.dcmread(path)
        require(ds.pixel_array.shape == (2, 2) and bool((ds.pixel_array == 1).all()), "Changed native pixels")
        witness = None
        if name == "current-as-other":
            require(ds.StudiesContainingOtherReferencedInstancesSequence[0].StudyInstanceUID == ds.StudyInstanceUID, "Missing other-study contradiction")
            witness = "Other-study item repeats current Study UID."
        if name == "conflicting-hierarchies":
            local = ds.ReferencedSeriesSequence[0]
            other = ds.StudiesContainingOtherReferencedInstancesSequence[0]
            remote = other.ReferencedSeriesSequence[0]
            require(other.StudyInstanceUID != ds.StudyInstanceUID and local.SeriesInstanceUID == remote.SeriesInstanceUID
                    and local.ReferencedInstanceSequence[0].ReferencedSOPInstanceUID == remote.ReferencedInstanceSequence[0].ReferencedSOPInstanceUID,
                    "Missing contradictory hierarchy")
            witness = "Same series and instance assigned to different studies."
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        require(errors == ([("Common Instance Reference", *ERRORS[name])] if name in ERRORS else []), "Changed independent errors")
        require(result.errors == len(errors) and result.status.name == ("Failed" if errors else "Passed"), "Changed independent status")
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        require(command.returncode == expected["exit"], "Changed CLI exit")
        require(all(report["outcomes"][layer] == expected[layer] for layer in ["attributes", "references"]), "Changed CLI outcome")
        codec = subprocess.run([str(args.binary), "codec", "validate", str(path), "--format", "json"], capture_output=True, text=True, timeout=30)
        codec_report = json.loads(codec.stdout)
        require(codec.returncode == (0 if codec_report["success"] else 65), "Changed codec exit")
        require(codec_report["conformance"] == report, "Changed codec conformance")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "identityWitness": witness,
            "gap": "Independent IOD validator does not compare hierarchy identity." if name in CONFLICTS else
                   "External IOD acceptance does not prove target availability or inventory completeness." if name in VALID else None})
    args.output.write_text(json.dumps({"versions": versions, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    print(f"PASS: {len(records)} hierarchy cases, independent IOD/identity evidence and real CLI parity")


if __name__ == "__main__":
    main()
