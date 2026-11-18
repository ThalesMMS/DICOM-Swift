#!/usr/bin/env python3
"""Compare the multi-frame Secondary Capture corpus (A.8.2–A.8.5) with the independent IOD validator.

Each case carries the engine's expected outcome and CLI exit code, written by
DicomSCMultiframeCorpusTests. The pinned dicom-validator/PS3.3 2026c cache gives an
independent verdict; pydicom supplies frame shapes and raw sample witnesses.
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
SINGLE_BIT = "1.2.840.10008.5.1.4.1.1.7.1"

# The oracle treats the optional Multi-frame Functional Groups module as declared whenever
# Number of Frames or Instance Number is present, although those attributes also belong to the
# mandatory Multi-frame and General Image modules; it then reports the module's Type 1 fields.
FUNCTIONAL_GROUP_FALSE_POSITIVES = [
    ("Multi-frame Functional Groups", "(0008,0023)", "TagMissing"),
    ("Multi-frame Functional Groups", "(0008,0033)", "TagMissing"),
    ("Multi-frame Functional Groups", "(0020,0013)", "TagEmpty"),
    ("Multi-frame Functional Groups", "(5200,9229)", "TagMissing"),
]
INDEPENDENT_ERRORS = {
    "missing-frame-increment": [("Multi-frame", "(0028,0009)", "TagMissing"), ("SC Multi-frame Image", "(0028,0009)", "TagMissing")],
    "pointer-target-missing": [("Cine", "(0018,1065)", "TagMissing"), ("SC Multi-frame Vector", "(0018,1065)", "TagMissing")],
    "playback-invalid": [("Cine", "(0018,1244)", "EnumValueNotAllowed")],
    "dimension-index-missing": [("Multi-frame Dimension", "(0020,9222)", "TagMissing")],
    "single-bit-voi-forbidden": [("General", "(0028,1050)", "TagUnexpected"), ("General", "(0028,1051)", "TagUnexpected")],
    "byte-overlay-forbidden": [("General", f"(6000,{element})", "TagUnexpected")
                               for element in ["0010", "0011", "0040", "0050", "0100", "0102", "3000"]],
}
GAPS = {
    "vector-length-mismatch": "Oracle does not compare vector multiplicity with Number of Frames.",
    "single-bit-wrong-allocation": "Oracle does not evaluate the A.8.2.4 pixel description constraints.",
    "byte-rescale-slope": "Oracle does not evaluate the A.8.3.4 rescale constants.",
    "word-high-bit": "Oracle does not evaluate High Bit = Bits Stored - 1 for A.8.4.4.",
    "word-unused-high-bits": "Oracle does not inspect sample bits above Bits Stored.",
    "true-color-planar": "Oracle does not evaluate the A.8.5.4 planar configuration constraint.",
    "true-color-ybr-native": "Oracle does not tie Photometric Interpretation to the transfer syntax family.",
    "representative-frame-out-of-range": "Oracle does not compare Representative Frame Number with Number of Frames.",
    "foi-description-count": "Oracle does not compare Frame of Interest description count with the FOI count.",
    "frame-extraction-two-lists": "Oracle does not enforce the single retrieve list of C.12.3.",
    "byte-functional-groups": "Functional group macro content is deferred to the Enhanced lot on both sides.",
}


def witness(name, ds):
    frames = int(ds.NumberOfFrames)
    if name != "single-bit-wrong-allocation":
        shape = ds.pixel_array.shape
        require(shape[0] == frames, "Changed frame count witness")
        if ds.SOPClassUID == SINGLE_BIT:
            require(shape == (frames, 4, 4), "Changed single-bit frame shape")
    if name == "word-unused-high-bits":
        require(any(int.from_bytes(bytes(ds.PixelData[i:i + 2]), "little") & 0xF000 for i in range(0, len(ds.PixelData), 2)),
                "Changed unused-high-bit witness")
    if name == "grayscale-word":
        require(all(int.from_bytes(bytes(ds.PixelData[i:i + 2]), "little") < 4096 for i in range(0, len(ds.PixelData), 2)),
                "Changed grayscale word witness")
    if name == "vector-length-mismatch":
        require(len(ds.SliceLocationVector) != frames, "Changed vector witness")


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
        witness(name, ds)
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        false_positives = [] if expected["variant"] == SINGLE_BIT or name == "byte-functional-groups" else FUNCTIONAL_GROUP_FALSE_POSITIVES
        require(errors == sorted(INDEPENDENT_ERRORS.get(name, []) + false_positives), f"Changed independent errors for {name}: {errors}")
        independent = sorted(set(errors) - set(false_positives))
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
                                 + [flag for fact in FACTS for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode}")
        layers = {layer: outcome for layer, outcome in report["outcomes"].items() if layer != "operation"}
        if command.returncode == 1:
            require("failed" in layers.values(), f"CLI failure has no failed conformance layer for {name}: {layers}")
        if expected["exit"] == 0:
            require(all(outcome == "passed" for outcome in layers.values()), "Changed CLI outcome")
        agreement = (expected["outcome"] == "failed") == bool(independent)
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "functionalGroupFalsePositives": bool(false_positives),
            "falsePositives": len(false_positives),
            "cliLayers": layers, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} multi-frame SC cases, {agreements} independent agreements after documented false positives, "
          f"{len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
