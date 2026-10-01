#!/usr/bin/env python3
"""Compare the Enhanced CT/MR/XA image corpus with the independent IOD validator.

Each case carries the engine's expected outcome and CLI exit code, written by
DicomEnhancedImageCorpusTests. The pinned dicom-validator/PS3.3 2026c cache gives an
independent module and functional-group verdict; pydicom supplies structural witnesses.
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
         "sar-capable=no", "gradient-output-capable=no", "operating-mode-regulated=no"]
# The oracle reads the Filter Material condition (C.8.15.3.9) as unconditional on ORIGINAL frames,
# although it applies only when Filter Type is other than NONE; every ORIGINAL CT object here uses NONE.
FILTER_MATERIAL_FALSE_POSITIVE = ("CT X-Ray Details", "(5200,9229) / (0018,9325) / (0018,7050)", "TagMissing")
INDEPENDENT_ERRORS = {
    "ct-frame-content-shared": [("Frame Content", "(5200,9229) / (0020,9111)", "TagNotAllowed")],
    "ct-missing-acquisition-type": [("CT Acquisition Type", "(5200,9229) / (0018,9301)", "TagMissing")],
    "ct-missing-pixel-measures": [("Pixel Measures", "(5200,9229) / (0028,9110)", "TagMissing")],
    "ct-multi-energy-without-module": [
        ("CT Acquisition Details", "(5200,9229) / (0018,9304) / (0018,9378)", "TagMissing"),
        ("CT Exposure", "(5200,9229) / (0018,9321) / (0018,9377)", "TagMissing"),
        ("CT Geometry", "(5200,9229) / (0018,9312) / (0018,9378)", "TagMissing"),
        ("CT X-Ray Details", "(5200,9229) / (0018,9325) / (0018,9378)", "TagMissing"),
        ("Enhanced Multi-energy CT Acquisition", "(0018,9365)", "TagMissing"),
        ("Enhanced Multi-energy CT Acquisition", "(0018,936F)", "TagMissing"),
        ("Enhanced Multi-energy CT Acquisition", "(0018,9379)", "TagMissing"),
        ("Real World Value Mapping", "(5200,9229) / (0040,9096)", "TagMissing")],
    "ct-other-iod-macro": [("Multi-frame Functional Groups", "(5200,9229) / (0018,9114)", "TagUnexpected")],
    "ct-spiral-missing-pitch": [("CT Table Dynamics", "(5200,9229) / (0018,9308) / (0018,9311)", "TagMissing")],
    "mr-missing-pulse-sequence-name": [("MR Pulse Sequence", "(0018,9005)", "TagMissing")],
    "xa-carm-relationship-without-frame-of-reference": [
        ("Enhanced XA/XRF Image", "(0054,0410)", "TagMissing"), ("Enhanced XA/XRF Image", "(0054,0414)", "TagMissing"),
        ("Frame of Reference", "(0020,0052)", "TagMissing"), ("Frame of Reference", "(0020,1040)", "TagMissing"),
        ("Patient Orientation in Frame", "(5200,9229) / (0020,9450)", "TagMissing"),
        ("Synchronization", "(0018,106A)", "TagMissing"), ("Synchronization", "(0018,1800)", "TagMissing"),
        ("Synchronization", "(0020,0200)", "TagMissing"),
        ("X-Ray Positioner", "(5200,9229) / (0018,9405)", "TagMissing"),
        ("X-Ray Projection Pixel Calibration", "(5200,9229) / (0018,9401)", "TagMissing"),
        ("X-Ray Table Position", "(5200,9229) / (0018,9406)", "TagMissing")],
    "xa-missing-collimator": [("X-Ray Collimator", "(5200,9229) / (0018,9407)", "TagMissing")],
    "xa-plane-identification-missing": [("Enhanced XA/XRF Image", "(0018,9457)", "TagMissing")],
}
GAPS = {
    "ct-bits-stored-8": "Oracle does not enforce the A.38.1.3 bit depth of the IOD.",
    "ct-dimension-values-count": "Oracle does not compare Dimension Index Values with the Dimension Index Sequence.",
    "ct-image-type-contradiction": "Oracle does not check that Image Type summarizes the frame types.",
    "ct-non-orthogonal-orientation": "Oracle does not evaluate direction cosine orthogonality.",
    "mr-invalid-acquisition-type": "Oracle does not enforce the MR Acquisition Type Enumerated Values.",
    "mr-diffusion-missing-macro": "Oracle did not extract the Acquisition Contrast condition of the MR Diffusion macro.",
}


def witness(name, ds):
    shared = ds.SharedFunctionalGroupsSequence[0]
    frames = ds.PerFrameFunctionalGroupsSequence
    require(int(ds.NumberOfFrames) == len(frames) == 2, "Changed frame count witness")
    if "CTXRayDetailsSequence" in shared:
        require(shared.CTXRayDetailsSequence[0].FilterType == "NONE", "Changed filter type witness")
    if name == "ct-frame-content-shared":
        require("FrameContentSequence" in shared, "Changed shared frame content witness")
    if name == "ct-missing-pixel-measures":
        require("PixelMeasuresSequence" not in shared and all("PixelMeasuresSequence" not in f for f in frames), "Changed pixel measures witness")
    if name == "ct-dimension-values-count":
        require(list(frames[0].FrameContentSequence[0].DimensionIndexValues) == [1, 1] and len(ds.DimensionIndexSequence) == 1,
                "Changed dimension index witness")
    if name == "ct-non-orthogonal-orientation":
        require([float(v) for v in shared.PlaneOrientationSequence[0].ImageOrientationPatient] == [1, 0, 0, 0.5, 0.5, 0], "Changed orientation witness")
    if name == "ct-image-type-contradiction":
        require(ds.ImageType[0] == "DERIVED" and shared.CTImageFrameTypeSequence[0].FrameType[0] == "ORIGINAL", "Changed image type witness")
    if name == "ct-other-iod-macro":
        require("MREchoSequence" in shared, "Changed foreign macro witness")
    if name == "ct-spiral-missing-pitch":
        require(shared.CTAcquisitionTypeSequence[0].AcquisitionType == "SPIRAL" and "SpiralPitchFactor" not in shared.CTTableDynamicsSequence[0],
                "Changed spiral witness")
    if name == "xa-carm-relationship-without-frame-of-reference":
        require(ds.CArmPositionerTabletopRelationship == "YES" and "FrameOfReferenceUID" not in ds, "Changed C-arm witness")


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
        require(ds.SOPClassUID == expected["sopClass"] and ds.pixel_array.shape == (2, 2, 2), "Changed native pixel witness")
        witness(name, ds)
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        shared = ds.SharedFunctionalGroupsSequence[0]
        original_ct = "CTImageFrameTypeSequence" in shared and shared.CTImageFrameTypeSequence[0].FrameType[0] == "ORIGINAL"
        false_positives = [FILTER_MATERIAL_FALSE_POSITIVE] if original_ct else []
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
            "independentOutcome": result.status.name, "errors": errors, "filterMaterialFalsePositive": bool(false_positives),
            "falsePositives": len(false_positives),
            "cliLayers": layers, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} Enhanced CT/MR/XA cases, {agreements} independent agreements after the documented false positive, "
          f"{len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
