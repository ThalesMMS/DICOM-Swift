#!/usr/bin/env python3
"""Compare the classic CT/MR/CR image corpus with the independent IOD validator.

Each case carries the engine's expected outcome and CLI exit code, written by
DicomClassicImageCorpusTests. The pinned dicom-validator/PS3.3 2026c cache gives an
independent verdict; pydicom supplies geometry and attribute witnesses. Disagreements
are recorded with their reason, never masked. Requires requirements-iod.txt.
"""
import argparse
import hashlib
import importlib.metadata
import json
import logging
from decimal import Decimal
from pathlib import Path
import subprocess

import pydicom
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

FACTS = ["animal=no", "non-bipedal=no", "paired-body-part=no", "temporally-related-series=no", "calibrated-image=no",
         "rescale-hu=yes", "cardiac-gating=no"]

# The oracle reads the CT Acquisition Details conditions on Rotation Direction and Revolution Time
# as prohibitions when Acquisition Type is absent, although both are "may be present otherwise".
ACQUISITION_DETAILS_FALSE_POSITIVES = [
    ("Multi-energy CT Image", "(0018,9362) / (0018,9304) / (0018,1140)", "TagNotAllowed"),
    ("Multi-energy CT Image", "(0018,9362) / (0018,9304) / (0018,9305)", "TagNotAllowed"),
]
INDEPENDENT_ERRORS = {
    "cr-missing-view-position": [("CR Series", "(0018,5101)", "TagMissing")],
    "cr-photometric-rgb": [("CR Image", "(0028,0004)", "EnumValueNotAllowed")],
    "cr-shutter-missing-edge": [("Display Shutter", "(0018,1608)", "TagMissing")],
    "ct-bits-stored-8": [("CT Image", "(0028,0101)", "EnumValueNotAllowed")],
    "ct-contrast-missing-agent": [("Contrast/Bolus", "(0018,0010)", "TagMissing")],
    "ct-multi-energy-missing-detector": [("Multi-energy CT Image", "(0018,9362) / (0018,936F)", "TagMissing")],
    "ct-presentation-intent-invalid": [("Single-Frame CT Series", "(0008,0068)", "EnumValueNotAllowed")],
    "mr-missing-frame-of-reference": [("Frame of Reference", "(0020,0052)", "TagMissing")],
}
MULTI_ENERGY = {"ct-multi-energy", "ct-multi-energy-missing-detector", "ct-multi-energy-bad-path"}
GAPS = {
    "cr-shutter-duplicate-shape": "Oracle does not enforce at most one occurrence of each Shutter Shape value.",
    "ct-multi-energy-bad-path": "Oracle does not cross-check path source/detector indexes.",
    "ct-non-orthogonal": "Oracle does not evaluate direction cosine orthogonality.",
    "ct-oblique-beyond-precision": "Oracle does not evaluate unit length; the engine bounds it by the encoded precision.",
    "ct-orientation-contradiction": "Oracle does not compare Patient Orientation with Image Orientation (Patient).",
    "mr-ir-missing-inversion": "Oracle did not extract the Inversion Time condition from PS3.3.",
}


def witness(name, ds):
    if name == "ct-oblique-beyond-precision":
        cosines = [Decimal(v.original_string) for v in ds.ImageOrientationPatient]
        require(sum(c * c for c in cosines[:3]) - 1 > 2 * 2 * Decimal("0.72") * Decimal("0.005") + 2 * Decimal("0.005") ** 2,
                "Changed precision witness")
    if name == "ct-oblique-within-precision":
        cosines = [Decimal(v.original_string) for v in ds.ImageOrientationPatient]
        require(abs(sum(c * c for c in cosines[:3]) - 1) <= 4 * Decimal("0.70710678") * Decimal("5E-9") + 2 * Decimal("5E-9") ** 2,
                "Changed rounded witness")
    if name == "ct-orientation-contradiction":
        require(list(ds.PatientOrientation) == ["R", "P"] and list(ds.ImageOrientationPatient)[:3] == [1, 0, 0], "Changed orientation witness")
    if name == "ct-multi-energy-bad-path":
        acquisition = ds.MultienergyCTAcquisitionSequence[0]
        sources = {item.XRaySourceIndex for item in acquisition.MultienergyCTXRaySourceSequence}
        require(acquisition.MultienergyCTPathSequence[0].ReferencedXRaySourceIndex not in sources, "Changed path witness")
    if name == "cr-shutter-duplicate-shape":
        require(list(ds.ShutterShape) == ["RECTANGULAR", "RECTANGULAR"], "Changed shutter witness")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Changed oracle versions")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names)), log_level=logging.CRITICAL)
    records = []
    files = sorted(args.corpus.glob("*.dcm"))
    require(files, f"No DICOM files found in corpus: {args.corpus}")
    for path in files:
        name = path.stem
        expected = json.loads(path.with_suffix(".json").read_text())
        ds = pydicom.dcmread(path)
        require(ds.pixel_array.shape == (2, 2), "Changed native pixels")
        witness(name, ds)
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        false_positives = ACQUISITION_DETAILS_FALSE_POSITIVES if name in MULTI_ENERGY else []
        require(errors == sorted(INDEPENDENT_ERRORS.get(name, []) + false_positives), f"Changed independent errors for {name}: {errors}")
        independent = sorted(set(errors) - set(false_positives))
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
                                 + [flag for fact in FACTS for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode} {command.stderr}")
        report = json.loads(command.stdout)
        layers = {layer: outcome for layer, outcome in report["outcomes"].items() if layer != "operation"}
        if command.returncode == 1:
            require("failed" in layers.values(), f"CLI failure has no failed conformance layer for {name}: {layers}")
        if expected["exit"] == 0:
            require(all(outcome == "passed" for outcome in layers.values()), "Changed CLI outcome")
        agreement = (expected["outcome"] == "failed") == bool(independent)
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "acquisitionDetailsFalsePositives": bool(false_positives),
            "falsePositives": len(false_positives),
            "cliLayers": layers, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} classic CT/MR/CR cases, {agreements} independent agreements after documented false positives, "
          f"{len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
