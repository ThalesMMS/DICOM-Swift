#!/usr/bin/env python3
"""Compare the SR/KOS profile corpus with the independent IOD validator.

Each case carries the engine's expected outcome, whether it needs supplied target metadata,
and the CLI exit code, written by DicomSRProfileCorpusTests. The pinned dicom-validator/
PS3.3 2026c cache gives an independent module-level verdict; pydicom supplies witnesses.
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

FACTS = ["animal=no", "non-bipedal=no", "paired-body-part=no", "temporally-related-series=no", "calibrated-image=no",
         "requested-procedure=no", "predecessor-content=no", "identical-documents=no", "equivalent-cda=no",
         "observation-time-differs=no", "root-template=yes"]
INDEPENDENT_ERRORS = {
    "kos-missing-template": [("SR Document Content", "(0040,A504)", "TagEmpty")],
    "missing-manufacturer": [("General Equipment", "(0008,0070)", "TagMissing")],
    "series-modality-wrong": [("SR Document Series", "(0008,0060)", "EnumValueNotAllowed")],
    "sync-missing-trigger": [("Synchronization", "(0018,106A)", "TagMissing")],
    "verified-without-observer": [("SR Document General", "(0040,A073)", "TagMissing")],
}
# Cases the engine rejects for a rule the oracle does not evaluate.
GAPS = {
    "enhanced-scoord3d": "Oracle does not enforce the A.35.2.3.1.1 Value Type restriction of the IOD.",
    "kos-wrong-template": "Oracle does not check the A.35.4.3.1.3 mandated TID 2010 root template.",
    "requested-procedure-required": "Oracle cannot evaluate the stated requested-procedure fact.",
    "text-without-concept-name": "Oracle did not extract the Value Type condition of Concept Name Code Sequence.",
}


def witness(name, ds):
    if name == "kos":
        require(ds.ContentTemplateSequence[0].TemplateIdentifier == "2010", "Changed KOS template witness")
    if name == "kos-wrong-template":
        require(ds.ContentTemplateSequence[0].TemplateIdentifier == "1500", "Changed KOS template witness")
    if name == "kos-missing-template":
        require(len(ds.ContentTemplateSequence) == 0, "Changed KOS template witness")
    if name == "enhanced-scoord3d":
        require(ds.ContentSequence[2].ValueType == "SCOORD3D", "Changed value type witness")
    if name == "text-without-concept-name":
        require("ConceptNameCodeSequence" not in ds.ContentSequence[1], "Changed concept name witness")
    if name == "sync-missing-trigger":
        require(ds.SynchronizationFrameOfReferenceUID and "SynchronizationTrigger" not in ds, "Changed synchronization witness")
    if name == "series-modality-wrong":
        require(ds.Modality == "OT", "Changed modality witness")
    if name == "verified-without-observer":
        require(ds.VerificationFlag == "VERIFIED" and "VerifyingObserverSequence" not in ds, "Changed verification witness")


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
        require(ds.SOPClassUID == expected["sopClass"] and "PixelData" not in ds, "Changed SOP Class witness")
        witness(name, ds)
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        require(errors == sorted(INDEPENDENT_ERRORS.get(name, [])), f"Changed independent errors for {name}: {errors}")
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
                                 + [flag for fact in FACTS for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode}")
        layers = {layer: outcome for layer, outcome in report["outcomes"].items() if layer != "operation"}
        if command.returncode == 1:
            require("failed" in layers.values(), f"CLI failure has no failed conformance layer for {name}: {layers}")
        limitations = sorted({d["code"] for d in report["diagnostics"] if d["severity"] == "limitation" and d["layer"] != "operation"})
        if expected["outcome"] == "passed":
            # The CLI has no target metadata, so supplied-target checks are the only incomplete source.
            require(layers["references"] == "incomplete" and limitations == ["referenceTargetUnavailable"]
                    and all(outcome == "passed" for layer, outcome in layers.items() if layer != "references"),
                    f"Changed CLI outcome for {name}: {layers} {limitations}")
        agreement = (expected["outcome"] == "failed") == bool(errors)
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "cliLayers": layers, "cliLimitations": limitations,
            "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} SR/KOS profile cases, {agreements} independent agreements, {len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
