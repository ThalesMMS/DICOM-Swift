#!/usr/bin/env python3
"""Compare the Softcopy Presentation State corpus with the independent IOD validator.

Each case carries the engine's expected outcome and CLI exit code, written by
DicomPresentationStateCorpusTests. The pinned dicom-validator/PS3.3 2026c cache gives an
independent module verdict; pydicom supplies structural witnesses. The CLI has no target
metadata, so every presentation state is incomplete on its references there. Disagreements are
recorded with their reason, never masked. Requires requirements-iod.txt.
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
# The oracle's Presentation State Mask table lists only Mask Operation and Contrast Frame Averaging, although
# C.11.13 defers the other item attributes to the Mask module (C.7.6.10); Mask Frame Numbers is reported as unexpected.
MASK_FALSE_POSITIVE = ("Presentation State Mask", "(0028,6100) / (0028,6110)", "TagUnexpected")
# Negatives settled only by the supplied target metadata, which the CLI does not receive.
TARGET_DEPENDENT = {"gsps-frame-out-of-range", "gsps-sop-class-mismatch"}
INDEPENDENT_ERRORS = {
    "blending-with-overlay": [("General", f"(6000,{element})", "TagUnexpected") for element in
                              ["0010", "0011", "0040", "0050", "0100", "0102", "1001", "3000"]],
    "color-missing-icc": [("ICC Profile", "(0028,2000)", "TagMissing")],
    "gsps-magnify-without-ratio": [("Displayed Area", "(0070,005A) / (0070,0103)", "TagMissing")],
    "gsps-mask": [MASK_FALSE_POSITIVE],
    "gsps-mask-without-averaging": [MASK_FALSE_POSITIVE],
    "gsps-missing-displayed-area": [("Displayed Area", "(0070,005A)", "TagMissing")],
    "gsps-missing-presentation-lut": [("Softcopy Presentation LUT", "(2050,0010)", "TagMissing"), ("Softcopy Presentation LUT", "(2050,0020)", "TagMissing")],
    "gsps-modality-lut-both": [("Modality LUT", "(0028,1052)", "TagNotAllowed"), ("Modality LUT", "(0028,3000)", "TagNotAllowed")],
    "gsps-modality-ot": [("Presentation Series", "(0008,0060)", "EnumValueNotAllowed")],
    "gsps-rotation-45": [("Spatial Transformation", "(0070,0042)", "EnumValueNotAllowed")],
    "gsps-text-without-anchor-or-box": [("Graphic Annotation", "(0070,0001) / (0070,0008) / (0070,0014)", "TagMissing")],
    "gsps-true-size-without-spacing": [("Displayed Area", "(0070,005A) / (0070,0101)", "TagMissing")],
    "pseudo-color-missing-palette": [("Palette Color Lookup Table", "(0028,1101)", "TagMissing"), ("Palette Color Lookup Table", "(0028,1102)", "TagMissing"),
                                     ("Palette Color Lookup Table", "(0028,1103)", "TagMissing")],
    "pseudo-color-with-presentation-lut": [("General", "(2050,0020)", "TagUnexpected")],
}
GAPS = {
    "blending-one-item": "Oracle does not enforce the two items of the Blending Sequence.",
    "blending-opacity-2": "Oracle does not bound Relative Opacity.",
    "blending-same-position": "Oracle does not check one SUPERIMPOSED and one UNDERLYING item.",
    "gsps-activation-unknown-layer": "Oracle does not resolve Overlay Activation Layer against the Graphic Layer Sequence.",
    "gsps-annotation-without-layer-module": "Oracle does not evaluate the Graphic Layer module condition on annotations.",
    "gsps-bitmap-shutter-without-overlay": "Oracle does not require the overlay group named by the Bitmap Display Shutter.",
    "gsps-closed-polyline-unfilled": "Oracle does not evaluate Graphic Filled for closed polylines.",
    "gsps-displayed-area-inverted": "Oracle does not compare the displayed area corners.",
    "gsps-frame-out-of-range": "Oracle has no target metadata for the referenced frames.",
    "gsps-graphic-data-count": "Oracle does not compare Graphic Data with Number of Graphic Points.",
    "gsps-mask-without-averaging": "Oracle does not read the Contrast Frame Averaging condition on several mask frames.",
    "gsps-overlay-without-activation": "Oracle does not evaluate the repeating-group Overlay Activation module.",
    "gsps-reference-outside-relationship": "Oracle does not check annotation references against the relationship module.",
    "gsps-shutter-without-presentation-value": "Oracle does not evaluate the Shutter Presentation Value condition on a shutter.",
    "gsps-sop-class-mismatch": "Oracle has no target metadata for the referenced SOP Class.",
    "gsps-unknown-layer": "Oracle does not resolve annotation layers against the Graphic Layer Sequence.",
}


def witness(name, ds):
    require(ds.Modality in ("PR", "OT"), "Changed modality witness")
    if name == "gsps-graphic-data-count":
        require(len(ds.GraphicAnnotationSequence[0].GraphicObjectSequence[0].GraphicData) == 3, "Changed graphic data witness")
    if name == "gsps-closed-polyline-unfilled":
        data = ds.GraphicAnnotationSequence[0].GraphicObjectSequence[0].GraphicData
        require(list(data[:2]) == list(data[-2:]) and "GraphicFilled" not in ds.GraphicAnnotationSequence[0].GraphicObjectSequence[0],
                "Changed closed polyline witness")
    if name == "gsps-unknown-layer":
        require(ds.GraphicAnnotationSequence[0].GraphicLayer not in [item.GraphicLayer for item in ds.GraphicLayerSequence], "Changed layer witness")
    if name == "gsps-displayed-area-inverted":
        area = ds.DisplayedAreaSelectionSequence[0]
        require(list(area.DisplayedAreaTopLeftHandCorner) == [3, 3] and list(area.DisplayedAreaBottomRightHandCorner) == [2, 2], "Changed area witness")
    if name == "gsps-frame-out-of-range":
        require(ds.ReferencedSeriesSequence[0].ReferencedImageSequence[0].ReferencedFrameNumber == 3, "Changed frame witness")
    if name == "gsps-overlay-without-activation":
        require((0x6000, 0x3000) in ds and (0x6000, 0x1001) not in ds, "Changed overlay activation witness")
    if name == "blending-with-overlay":
        require((0x6000, 0x3000) in ds and ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.11.4", "Changed blending overlay witness")
    if name == "blending-same-position":
        require([item.BlendingPosition for item in ds.BlendingSequence] == ["UNDERLYING", "UNDERLYING"], "Changed blending position witness")


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
        independent = [e for e in errors if e != MASK_FALSE_POSITIVE]
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
                                 + [flag for fact in FACTS for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        layers = {layer: outcome for layer, outcome in report["outcomes"].items() if layer != "operation"}
        if command.returncode == 1:
            require("failed" in layers.values(), f"CLI failure has no failed conformance layer for {name}: {layers}")
        limitations = sorted({d["code"] for d in report["diagnostics"] if d["severity"] == "limitation" and d["layer"] != "operation"})
        if expected["outcome"] == "passed" or name in TARGET_DEPENDENT:
            # The CLI has no target metadata, so supplied-target checks are the only incomplete source.
            require(command.returncode == 2 and layers["references"] == "incomplete" and limitations == ["referenceTargetUnavailable"]
                    and all(outcome == "passed" for layer, outcome in layers.items() if layer != "references"),
                    f"Changed CLI outcome for {name}: {layers} {limitations}")
        else:
            require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode}")
        agreement = (expected["outcome"] == "failed") == bool(independent)
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "maskFalsePositive": MASK_FALSE_POSITIVE in errors,
            "falsePositives": sum(e == MASK_FALSE_POSITIVE for e in errors),
            "cliLayers": layers, "cliLimitations": limitations, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} Softcopy Presentation State cases, {agreements} independent agreements after the documented "
          f"false positive, {len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
