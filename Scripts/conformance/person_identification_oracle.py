#!/usr/bin/env python3
"""Compare person identification structure without treating code labels as resolved identities."""

import argparse
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path

from pydicom import dcmread
from pydicom.multival import MultiValue
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo

from image_iod_oracle import VERSIONS, require


ERRORS = {
    "missing-meaning": ["(0008,0096) / (0040,1101) / (0008,0104)"],
    "referring-missing-code": ["(0008,0096) / (0040,1101)"],
    "referring-missing-institution": ["(0008,0096) / (0008,0080)", "(0008,0096) / (0008,0082)"],
}
GAPS = {"consulting-count-mismatch", "consulting-empty", "equipment-single-mismatch", "referring-multiple"}
INCOMPLETE = {"baseline", "referring-valid", "institution-code-only", "consulting-two", "consulting-single-exception", "equipment-two"}
CASES = ERRORS.keys() | GAPS | INCOMPLETE


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
        require(own == {"attributes": "incomplete" if name in INCOMPLETE else "failed", "geometry": "passed"}, "Changed composed evidence: " + name)
        ds = dcmread(path)
        require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.7", "Wrong carrier IOD")
        require(ds.pixel_array.shape == (2, 2) and bool((ds.pixel_array == 1).all()), "Changed independent pixel decode")
        counts = None
        if name.startswith("consulting"):
            item_count = len(ds.ConsultingPhysicianIdentificationSequence)
            names = ds.get("ConsultingPhysicianName")
            name_count = 0 if names is None else len(names) if isinstance(names, MultiValue) else 1
            expected = {"consulting-empty": (0, 0), "consulting-two": (2, 2),
                        "consulting-count-mismatch": (2, 1), "consulting-single-exception": (1, 2)}[name]
            counts = (item_count, name_count)
            require(counts == expected, "Changed study sequence cardinality witness")
        elif name.startswith("equipment"):
            equipment = ds.ContributingEquipmentSequence[0]
            counts = (len(equipment.OperatorIdentificationSequence), len(equipment.OperatorsName))
            require(counts == ((2, 2) if name == "equipment-two" else (1, 2)), "Changed equipment count witness")
        elif name == "referring-multiple":
            require(len(ds.ReferringPhysicianIdentificationSequence) == 2, "Missing single-item violation")
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items()
                        for tag, error in tags.items())
        expected_errors = [("General Study", tag, "TagMissing") for tag in ERRORS.get(name, [])]
        require(errors == expected_errors and result.errors == len(errors), "Changed independent diagnostics: " + name)
        require(result.status.name == ("Failed" if errors else "Passed"), "Changed independent outcome")
        results.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **own,
                        "independentOutcome": result.status.name, "errors": errors, "sequenceAndNameCounts": counts,
                        "gap": "Oracle does not enforce this sequence cardinality or PN count relation." if name in GAPS else None})
    args.output.write_text(json.dumps({"versions": versions,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in filenames},
        "scope": "Person identification structure and counts; not resolved identity/order, terminology or complete IOD qualification.",
        "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} person identification cases, independent sequence counts, IOD diagnostics and pixel decodes")


if __name__ == "__main__":
    main()
