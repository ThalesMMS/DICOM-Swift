#!/usr/bin/env python3
"""Compare the single-frame Secondary Capture profile corpus with the independent IOD validator.

Each corpus case carries the engine's expected outcome and CLI exit code, written by
DicomSCProfileCorpusTests. The pinned dicom-validator/PS3.3 2026c cache provides an
independent module-level verdict; pydicom supplies byte witnesses for negative cases.
Disagreements are recorded with their reason, never masked. Requires requirements-iod.txt.
"""
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

FACTS = ["animal=no", "non-bipedal=no", "paired-body-part=no", "temporally-related-series=no", "calibrated-image=no"]

# Independent module errors expected per case; absent entries mean the oracle reports no error.
INDEPENDENT_ERRORS = {
    "sync-missing-trigger": [("Synchronization", "(0018,106A)", "TagMissing")],
    "specimen-missing-container": [("Specimen", "(0040,0512)", "TagMissing")],
    "orientation-missing-equipment": [("Enhanced Patient Orientation", "(3010,0030)", "TagMissing")],
    "rwvm-missing-units": [("General Image", "(0040,9096) / (0040,08EA)", "TagMissing")],
    "other-patient-ids-missing-type": [("Patient", "(0010,1002) / (0010,0022)", "TagMissing")],
    "request-missing-issuer-type": [("General Series", "(0040,0275) / (0008,0051) / (0040,0033)", "TagMissing")],
    "conversion-source-missing-instance": [("SOP Common", "(0020,9172) / (0008,1155)", "TagMissing")],
    "patient-study-pregnancy": [("Patient Study", "(0010,21C0)", "EnumValueNotAllowed")],
    # The oracle treats the original attribute kept inside Modified Attributes Sequence as unexpected,
    # although C.12.1.1.9 defines that sequence as the container of the original values.
    "declared-common": [("SOP Common", "(0400,0561) / (0400,0550) / (0008,0080)", "TagUnexpected")],
    "original-attributes-missing-reason": [("SOP Common", "(0400,0561) / (0400,0550) / (0008,0080)", "TagUnexpected"),
                                           ("SOP Common", "(0400,0561) / (0400,0565)", "TagMissing")],
}
# Cases the engine rejects or leaves incomplete for a rule the oracle does not evaluate.
GAPS = {
    "patient-study-neutered-human": "Oracle cannot evaluate the non-human patient condition; the stated fact forbids the attribute.",
    "sync-channel-without-waveform": "Oracle does not evaluate the waveform-presence condition of Synchronization Channel.",
    "specimen-localization-required": "Oracle does not derive the multiple-specimen condition from the description count.",
    "icc-truncated": "Oracle does not inspect the ICC header size field.",
    "icc-wrong-class": "Oracle does not check the C.11.15.1 input-device class constraint.",
    "icc-label-contradiction": "Oracle does not compare Color Space with the profile description.",
    "icc-unknown-label": "Only well-known labels can be matched against the profile description.",
    "acquisition-negative-duration": "Oracle does not check the sign of Acquisition Duration.",
    "anatomic-region-two-items": "Oracle does not enforce single-item cardinality of Anatomic Region Sequence.",
    "reference-missing-in-hierarchy": "Oracle does not cross-check General Reference instances against C.12.2.",
    "spatial-geometry-mismatch": "Oracle has no target metadata; the engine compares supplied geometry.",
    "contributing-equipment-terminology": "Defined context group membership is not qualified by either validator.",
    "private-scheme-version": "Private coding scheme version requirements are unknown to both validators.",
    "terminology-orientation": "Defined context group membership is not qualified by either validator.",
    "specimen-container-type": "Defined context group membership is not qualified by either validator.",
    "signature-unverified": "Cryptographic verification of Digital Signatures is not an attribute check.",
    "declared-references": "CLI has no target metadata, so supplied-target checks stay incomplete there.",
    "declared-common": "Oracle false positive: original values inside Modified Attributes Sequence are reported as unexpected.",
}


def witness(name, ds):
    """Byte-level facts for negative cases, read independently of the engine."""
    if name == "icc-wrong-class":
        require(bytes(ds.ICCProfile[12:16]) == b"mntr", "Changed ICC class witness")
    if name == "icc-truncated":
        require(int.from_bytes(bytes(ds.ICCProfile[:4]), "big") > len(ds.ICCProfile), "Changed ICC size witness")
    if name == "sync-channel-without-waveform":
        require("SynchronizationChannel" in ds and "WaveformSequence" not in ds, "Changed synchronization witness")
    if name == "specimen-localization-required":
        require(len(ds.SpecimenDescriptionSequence) == 2 and "SpecimenLocalizationContentItemSequence" not in ds.SpecimenDescriptionSequence[0],
                "Changed specimen witness")
    if name == "reference-missing-in-hierarchy":
        listed = {i.ReferencedSOPInstanceUID for s in ds.ReferencedSeriesSequence for i in s.ReferencedInstanceSequence}
        require(ds.SourceImageSequence[0].ReferencedSOPInstanceUID not in listed, "Changed hierarchy witness")


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
        require(ds.pixel_array.shape == (2, 2, 3) and bool((ds.pixel_array == 1).all()), "Changed native pixels")
        witness(name, ds)
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        require(errors == INDEPENDENT_ERRORS.get(name, []), f"Changed independent errors for {name}: {errors}")
        require(result.status.name == ("Failed" if errors else "Passed"), "Changed independent status")
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
                                 + [flag for fact in FACTS for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode}")
        layers = {layer: outcome for layer, outcome in report["outcomes"].items() if layer != "operation"}
        if command.returncode == 1:
            require("failed" in layers.values(), f"CLI failure has no failed conformance layer for {name}: {layers}")
        if expected["exit"] == 0:
            require(all(outcome == "passed" for outcome in layers.values()), "Changed CLI outcome")
        codec = subprocess.run([str(args.binary), "codec", "validate", str(path), "--format", "json"], capture_output=True, text=True, timeout=30)
        require(codec.returncode in (0, 65), f"codec validate failed for {name}: exit {codec.returncode}: {codec.stderr[:200]}")
        require("conformance" in json.loads(codec.stdout), "Changed codec conformance")
        agreement = (expected["outcome"] == "failed") == bool(errors) or (expected["outcome"] == "passed" and not errors)
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "cliLayers": layers, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} SC profile cases, {agreements} independent agreements, {len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
