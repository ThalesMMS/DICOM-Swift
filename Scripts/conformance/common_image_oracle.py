#!/usr/bin/env python3
"""Compare common CT/MR/SC attribute components using synthetic SC carriers.

The independent validator does not receive caller-only subject/series facts.
Exact diagnostics below preserve known oracle gaps instead of masking them.
"""

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


PASSED = {"baseline", "missing-modality", "defined-conversion", "calendar-custom", "deid-method",
          "animal-valid", "responsible-empty"}
ERRORS = {
    "missing-modality": [("General Series", "(0008,0060)", "TagMissing")],
    "missing-conversion": [("SC Equipment", "(0008,0064)", "TagMissing")],
    "missing-patient-id": [("Patient", "(0010,0020)", "TagMissing")],
    "missing-study-id": [("General Study", "(0020,0010)", "TagMissing")],
    "empty-study-uid": [("General Study", "(0020,000D)", "TagEmpty")],
    "missing-series-uid": [("General Series", "(0020,000E)", "TagMissing")],
    "invalid-sex": [("Patient", "(0010,0040)", "EnumValueNotAllowed")],
    "calendar-missing": [("Patient", "(0010,0035)", "TagMissing")],
    "calendar-custom": [("Patient", "(0010,0035)", "EnumValueNotAllowed")],
    "deid-missing": [("Patient", "(0012,0063)", "TagMissing"), ("Patient", "(0012,0064)", "TagMissing")],
    "animal-valid": [("Patient", "(0010,2298)", "TagMissing")],
    "animal-breed-missing": [("Patient", "(0010,2298)", "TagMissing")],
    "responsible-empty": [("Patient", "(0010,2298)", "TagMissing")],
    "responsible-missing-role": [("Patient", "(0010,2298)", "TagMissing")],
    "reference-missing": [("Image Plane", "(0018,0050)", "TagMissing"),
                          ("Image Plane", "(0020,0032)", "TagMissing"), ("Image Plane", "(0028,0030)", "TagMissing")],
}
CASES = PASSED | set(ERRORS) | {"unknown-subject", "animal-missing", "laterality-missing", "laterality-conflict"}
GAPS = {
    "missing-modality": "C.8.6.1 overrides General Series Modality to Type 3 for SC.",
    "calendar-custom": "C.7.1.5 calendar names are extensible Defined Terms, not Enumerated Values.",
    "unknown-subject": "The oracle does not evaluate caller-only animal and paired-structure conditions.",
    "animal-missing": "The oracle does not receive the explicit animal/non-bipedal facts.",
    "animal-valid": "Responsible Person Role is not required for an empty Responsible Person.",
    "animal-breed-missing": "Oracle reports missing role for empty person, but misses required empty-breed description.",
    "responsible-empty": "The oracle confuses present with present and having a value.",
    "laterality-missing": "The oracle does not receive the explicit paired-structure fact.",
    "laterality-conflict": "The oracle does not compare Series and Image Laterality.",
    "reference-missing": "Oracle checks Image Plane attributes but does not enforce SC's conditional Frame of Reference module.",
}


def witness(name, ds, facts):
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.7", "Wrong carrier IOD")
    require(ds.PixelData == bytes([1, 2, 3, 4]), "Synthetic pixel payload changed")
    expected = {"nonHumanPatient": "unsatisfied", "nonBipedalAnatomy": "undetermined", "pairedBodyPart": "unsatisfied"}
    if name.startswith("animal-"):
        expected.update(nonHumanPatient="satisfied", nonBipedalAnatomy="satisfied")
    elif name.startswith("laterality-"):
        expected["pairedBodyPart"] = "satisfied"
    elif name == "unknown-subject":
        expected = dict.fromkeys(expected, "undetermined")
    require(facts == expected, "Changed caller-only conditions")
    if name == "missing-modality":
        require("Modality" not in ds, "Missing SC override witness")
    elif name == "calendar-custom":
        require(ds.PatientAlternativeCalendar == "LOCAL" and "PatientBirthDateInAlternativeCalendar" in ds,
                "Missing extensible calendar witness")
    elif name in {"animal-valid", "animal-breed-missing", "responsible-empty"}:
        require(not str(ds.ResponsiblePerson) and "ResponsiblePersonRole" not in ds, "Missing empty-person witness")
        if name.startswith("animal-"):
            require(len(ds.PatientBreedCodeSequence) == 0, "Missing empty-breed witness")
            require(("PatientBreedDescription" not in ds) == (name == "animal-breed-missing"), "Wrong breed description")
    elif name == "laterality-conflict":
        require(ds.Laterality == "R" and ds.ImageLaterality == "L", "Missing laterality contradiction")
    elif name == "reference-missing":
        require(len(ds.ImageOrientationPatient) == 6 and "FrameOfReferenceUID" not in ds, "Missing spatial module witness")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Unexpected oracle/standard versions")
    require({p.stem for p in args.corpus.glob("*.dcm")} == CASES, "Missing or unexpected corpus cases")
    filenames = ["dict_info.json", "iod_info.json", "module_info.json"]
    info = DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in filenames))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for name in sorted(CASES):
        path = args.corpus / (name + ".dcm")
        own = json.loads(path.with_suffix(".json").read_text())
        outcome = "passed" if name in PASSED else "incomplete" if name == "unknown-subject" else "failed"
        require(own["attributes"] == outcome and own["instanceAttributes"] == ("failed" if outcome == "failed" else "incomplete"),
                "Changed own component/instance outcome: " + name)
        witness(name, dcmread(path), own["conditions"])
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items()
                        for tag, error in tags.items())
        require(errors == sorted(ERRORS.get(name, [])) and result.errors == len(errors), "Changed independent diagnostics: " + name)
        require(result.status.name == ("Failed" if errors else "Passed"), "Changed independent outcome")
        results.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **own,
                        "independentOutcome": result.status.name, "errors": errors, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in filenames},
        "scope": "Common attributes in SC carriers, not complete CT/MR/SC IOD or pixel/geometry qualification.",
        "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} common-image cases, with exact independent diagnostics and explicit gaps")


if __name__ == "__main__":
    main()
