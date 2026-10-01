#!/usr/bin/env python3
"""Compare the RT Dose/Structure Set/Plan corpus with the independent IOD validator.

Each case carries the engine's expected outcome, CLI exit code, whether a dose is grid-based and whether references remain,
written by DicomRTCorpusTests. The pinned dicom-validator/PS3.3 2026c cache gives an independent
module verdict; pydicom supplies structural witnesses. The CLI has no target metadata, so every RT
object is incomplete on its references there. Disagreements are recorded with their reason, never
masked. Requires requirements-iod.txt.
"""
import argparse
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path
import subprocess

import numpy as np
import pydicom
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

FACTS = ["animal=no", "non-bipedal=no", "paired-body-part=no", "temporally-related-series=no", "calibrated-image=no"]
# Negatives settled only by the supplied target metadata, which the CLI does not receive.
TARGET_DEPENDENT = {"rtdose-plan-class-mismatch", "rtstruct-image-frame-out-of-range"}
FALSE_POSITIVES = []
INDEPENDENT_ERRORS = {
    "rtdose-signed-physical": [("RT Dose", "(0028,0103)", "EnumValueNotAllowed")],
    "rtdose-beam-without-fraction-group": [("RT Dose", "(300C,0002) / (300C,0020)", "TagMissing")],
    "rtdose-bits-12": [("RT Dose", "(0028,0100)", "EnumValueNotAllowed")],
    "rtdose-grid-without-scaling": [("RT Dose", "(3004,000E)", "TagMissing")],
    "rtdose-missing-dose-units": [("RT Dose", "(3004,0002)", "TagMissing")],
    "rtdose-missing-frame-of-reference": [("Frame of Reference", "(0020,0052)", "TagMissing"), ("Frame of Reference", "(0020,1040)", "TagMissing")],
    "rtdose-plan-without-reference": [("RT Dose", "(300C,0002)", "TagMissing")],
    "rtplan-brachy-stepwise-without-step": [("RT Brachy Application Setups", "(300A,0230) / (300A,0280) / (300A,02A0)", "TagMissing")],
    "rtplan-patient-geometry-without-structure-set": [("RT General Plan", "(300C,0060)", "TagMissing")],
    "rtplan-prescription-point-without-roi": [("RT Prescription", "(300A,0010) / (3006,0084)", "TagMissing")],
    "rtplan-rejected-without-date": [("Approval", "(300E,0004)", "TagMissing")],
    "rtplan-rotation-direction-wrong": [("RT Beams", "(300A,00B0) / (300A,0111) / (300A,011F)", "EnumValueNotAllowed")],
    "rtplan-setup-without-position": [("RT Patient Setup", "(300A,0180) / (0018,5100)", "TagMissing"), ("RT Patient Setup", "(300A,0180) / (300A,0184)", "TagMissing")],
    "rtplan-wedges-without-sequence": [("RT Beams", "(300A,00B0) / (300A,00D1)", "TagMissing")],
    "rtstruct-approved-without-reviewer": [("Approval", "(300E,0004)", "TagMissing"), ("Approval", "(300E,0005)", "TagMissing"), ("Approval", "(300E,0008)", "TagMissing")],
    "rtstruct-geometric-type-wrong": [("ROI Contour", "(3006,0039) / (3006,0040) / (3006,0042)", "EnumValueNotAllowed")],
}
GAPS = {
    "rtdose-dvh-data-count": "Typed parser rejects DVH bin/data count mismatch and raw engine rejects odd multiplicity; independent IOD validator does not check these counts.",
    "rtdose-absolute-z-oblique": "Typed parser rejects absolute-Z offsets with oblique orientation; raw engine and independent IOD validator do not check option b geometry.",
    "rtdose-modality-wrong": "Oracle accepts any RT Series modality; the IOD-specific value is engine-only.",
    "rtdose-multiple-plans-for-plan": "Oracle does not tie the referenced plan count to the Dose Summation Type.",
    "rtdose-offsets-count": "Oracle does not compare Grid Frame Offset Vector with Number of Frames.",
    "rtdose-offsets-not-monotonic": "Oracle does not check the monotonic frame offsets.",
    "rtdose-plan-class-mismatch": "Oracle has no target metadata for the referenced plan.",
    "rtplan-brachy-final-time-weight-missing": "Oracle does not read the Final Cumulative Time Weight condition on the control points.",
    "rtplan-brachy-with-beams": "Oracle does not apply the beam/brachy module exclusion.",
    "rtplan-control-point-count": "Oracle does not compare Number of Control Points with the sequence.",
    "rtplan-final-meterset-missing": "Oracle does not read the Final Cumulative Meterset Weight condition on the control points.",
    "rtplan-first-control-point-without-gantry": "Oracle does not evaluate the first control point requirements.",
    "rtplan-fraction-beams-without-module": "Oracle does not derive the RT Beams module condition from the fraction groups.",
    "rtplan-referenced-beam-unknown": "Oracle does not resolve referenced beams in the RT Beams module.",
    "rtplan-wedge-without-first-position": "Oracle does not evaluate the wedge position of the first control point.",
    "rtstruct-contour-points-mismatch": "Oracle does not compare Contour Data with Number of Contour Points.",
    "rtstruct-contour-unknown-roi": "Oracle does not resolve referenced ROIs in the Structure Set ROI Sequence.",
    "rtstruct-duplicate-roi-number": "Oracle does not check ROI Number uniqueness.",
    "rtstruct-image-frame-out-of-range": "Oracle has no target metadata for the referenced image frames.",
    "rtstruct-observation-unknown-roi": "Oracle does not resolve referenced ROIs in the Structure Set ROI Sequence.",
    "rtstruct-roi-unknown-frame-of-reference": "Oracle does not resolve the ROI Frame of Reference in the Referenced Frame of Reference Sequence.",
}


# Pixel-metadata negatives that pydicom itself refuses to decode; the refusal is their structural witness.
PIXEL_DECODE_REFUSALS = {"rtdose-bits-12"}


def witness(name, ds):
    require(ds.Modality in ("RTDOSE", "RTSTRUCT", "RTPLAN"), "Changed modality witness")
    if ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.481.2" and "PixelData" in ds:
        if name in PIXEL_DECODE_REFUSALS:
            try:
                ds.pixel_array
            except (ValueError, AttributeError, KeyError):
                pass
            else:
                require(False, f"Changed pixel refusal witness for {name}")
        else:
            require(ds.pixel_array.shape[-2:] == (2, 2), "Changed dose grid witness")
    if name == "rtdose-offsets-not-monotonic":
        require(list(ds.GridFrameOffsetVector) == [0, 2, 1], "Changed offsets witness")
    if name == "rtstruct-contour-points-mismatch":
        contour = ds.ROIContourSequence[0].ContourSequence[0]
        require(int(contour.NumberOfContourPoints) * 3 != len(contour.ContourData), "Changed contour witness")
    if name == "rtplan-brachy-with-beams":
        require("BeamSequence" in ds and "BrachyTreatmentTechnique" in ds, "Changed beam/brachy witness")
    if name == "rtplan-control-point-count":
        beam = ds.BeamSequence[0]
        require(int(beam.NumberOfControlPoints) != len(beam.ControlPointSequence), "Changed control point count witness")
    if name == "rtplan-first-control-point-without-gantry":
        require("GantryAngle" not in ds.BeamSequence[0].ControlPointSequence[0], "Changed gantry witness")


def typed_witness(name, ds, expected):
    if "typedOutcome" not in expected:
        return
    if "engineDoseValues" in expected:
        # pydicom decodes Pixel Representation independently, including 16/32-bit ERROR sign extension.
        stored = np.asarray(ds.pixel_array).reshape(-1)
        np.testing.assert_array_equal(stored, expected["engineStoredValues"])
        np.testing.assert_allclose(stored.astype(np.float64) * float(ds.DoseGridScaling),
                                   expected["engineDoseValues"], rtol=0, atol=1e-12)
        if "enginePlanePositions" in expected:
            origin = np.asarray(ds.ImagePositionPatient, dtype=np.float64)
            orientation = np.asarray(ds.ImageOrientationPatient, dtype=np.float64)
            offsets = np.asarray(ds.GridFrameOffsetVector, dtype=np.float64)
            if offsets[0] == 0:
                positions = origin + offsets[:, None] * np.cross(orientation[:3], orientation[3:])
            else:
                require(np.array_equal(orientation, [1, 0, 0, 0, 1, 0]) and offsets[0] == origin[2],
                        f"Invalid option b witness for {name}")
                positions = np.tile(origin, (len(offsets), 1))
                positions[:, 2] = offsets
            np.testing.assert_allclose(positions, expected["enginePlanePositions"], rtol=0, atol=1e-12)
    if name == "rtdose-dvh-data-count":
        dvh = ds.DVHSequence[0]
        require(len(dvh.DVHData) % 2 != 0 or len(dvh.DVHData) != 2 * int(dvh.DVHNumberOfBins), "DVH mismatch witness")
        require(expected["typedDiagnostics"] == ["dvhDataCountMismatch"], "Typed DVH diagnostic")
    if name == "rtdose-absolute-z-oblique":
        require(float(ds.GridFrameOffsetVector[0]) != 0 and list(ds.ImageOrientationPatient) != [1, 0, 0, 0, 1, 0],
                "Absolute-Z oblique witness")
        require(expected["typedDiagnostics"] == ["absoluteZNonTransverseOrientation"], "Typed orientation diagnostic")
    if name == "rtdose-signed-physical":
        require(int(ds.PixelRepresentation) == 1 and ds.DoseType == "PHYSICAL", "Signed PHYSICAL witness")
        require(expected["typedDiagnostics"] == ["signedNonErrorDose"], "Typed signed diagnostic")
    if name == "rtdose-dvh-full":
        require("PixelData" not in ds and [roi.DVHROIContributionType for roi in ds.DVHSequence[0].DVHReferencedROISequence]
                == ["INCLUDED", "EXCLUDED"], "DVH-only two-ROI witness")


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
        require(ds.SOPClassUID == expected["sopClass"] and ("PixelData" in ds) == expected["grid"], "Changed SOP Class witness")
        witness(name, ds)
        typed_witness(name, ds, expected)
        result = validator.validate(path)[str(path)]
        all_errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        false_positives = [e for e in all_errors if e in FALSE_POSITIVES]
        errors = [e for e in all_errors if e not in false_positives]
        require(errors == sorted(INDEPENDENT_ERRORS.get(name, [])), f"Changed independent errors for {name}: {errors}")
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
                                 + [flag for fact in FACTS for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        layers = {layer: outcome for layer, outcome in report["outcomes"].items() if layer != "operation"}
        if command.returncode == 1:
            require("failed" in layers.values(), f"CLI failure has no failed conformance layer for {name}: {layers}")
        limitations = sorted({d["code"] for d in report["diagnostics"] if d["severity"] == "limitation" and d["layer"] != "operation"})
        if expected["references"]:
            require(layers["references"] == "incomplete" and "referenceTargetUnavailable" in limitations,
                    f"Changed reference outcome for {name}: {layers} {limitations}")
        if expected["outcome"] == "passed" or name in TARGET_DEPENDENT:
            # The CLI has no target metadata, so supplied-target checks are the only incomplete source.
            require(command.returncode == 2 and layers["references"] == "incomplete" and limitations == ["referenceTargetUnavailable"]
                    and all(outcome == "passed" for layer, outcome in layers.items() if layer != "references"),
                    f"Changed CLI outcome for {name}: {layers} {limitations}")
        else:
            require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode}")
        agreement = (expected.get("typedOutcome", expected["outcome"]) == "failed") == bool(errors)
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "falsePositives": len(false_positives),
            "cliLayers": layers, "cliLimitations": limitations, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} RT Dose/Structure Set/Plan cases, {agreements} independent agreements after the documented "
          f"false positives, {len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
