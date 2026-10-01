#!/usr/bin/env python3
"""Compare Spatial/Deformable Registration with the pinned independent IOD validator.

PS3.3 2026c module verdicts are distinct from the numpy point-mapping witnesses.
No inverse deformation or image resampling is performed. Requires requirements-iod.txt.
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
from image_iod_oracle import VERSIONS as IOD_VERSIONS, require

VERSIONS = {**IOD_VERSIONS, "numpy": "2.5.3"}

FACTS = ["animal=no", "non-bipedal=no", "paired-body-part=no", "temporally-related-series=no", "calibrated-image=no"]
FALSE_POSITIVES = []
INDEPENDENT_ERRORS = {
    "reg-type-unknown": [("Spatial Registration", "(0070,0308) / (0070,0309) / (0070,030A) / (0070,030C)", "EnumValueNotAllowed")],
    "reg-modality-wrong": [("Spatial Registration Series", "(0008,0060)", "EnumValueNotAllowed")],
    "reg-missing-frame-and-images": [
        ("Spatial Registration", "(0070,0308) / (0020,0052)", "TagMissing")],
}
GAPS = {
    "reg-matrix-15-values": "Independent IOD validator does not check matrix value count.",
    "reg-matrix-last-row": "Independent IOD validator does not check homogeneous last row.",
    "reg-two-matrix-registration-items": "Independent IOD validator does not check this sequence cardinality.",
    "dreg-vector-length-mismatch": "Independent IOD validator does not compare vector bytes with grid dimensions.",
    "dreg-no-grid-anywhere": "Independent IOD validator does not require a grid in at least one registration item.",
    "dreg-resolution-zero": "Independent IOD validator does not check positive grid resolution.",
    "dreg-dimensions-two-values": "Independent IOD validator does not check the dimensions triple.",
}
CASES = {
    "reg-rigid-single", "reg-rigid-two-items-common-frame", "reg-rigid-scale", "reg-affine",
    "reg-rigid-three-matrices-ordered", "reg-with-used-fiducials-segments-rois", "dreg-grid-only",
    "dreg-pre-post-grid", "dreg-nan-undefined", "dreg-matrix-item-plus-grid-item",
    "reg-matrix-15-values", "reg-matrix-last-row", "reg-type-unknown", "reg-two-matrix-registration-items",
    "reg-missing-frame-and-images", "reg-modality-wrong", "dreg-vector-length-mismatch",
    "dreg-no-grid-anywhere", "dreg-resolution-zero", "dreg-dimensions-two-values",
}


def witness(name, ds, expected):
    if name == "reg-rigid-three-matrices-ordered":
        point = np.append(np.asarray(expected["probePoint"], dtype=np.float64), 1)
        matrices = ds.RegistrationSequence[0].MatrixRegistrationSequence[0].MatrixSequence
        require(len(matrices) == 3, "Three ordered matrices required")
        for item in matrices:
            point = np.asarray(item.FrameOfReferenceTransformationMatrix, dtype=np.float64).reshape(4, 4) @ point
        np.testing.assert_allclose(point[:3], expected["expectedMappedPoint"], rtol=0, atol=1e-6)
    if name in ("dreg-pre-post-grid", "dreg-nan-undefined"):
        item = ds.DeformableRegistrationSequence[0]
        grid = item.DeformableRegistrationGridSequence[0]
        dims = np.asarray(grid.GridDimensions, dtype=int)
        vectors = np.frombuffer(grid.VectorGridData, dtype="<f4").reshape(dims[2], dims[1], dims[0], 3)
        if name == "dreg-nan-undefined":
            count = int(np.all(np.isnan(vectors), axis=-1).sum())
            require(count == expected["undefinedVectorCount"] == 1, "Undefined NaN triple witness changed")
            return
        orientation = np.asarray(grid.ImageOrientationPatient, dtype=np.float64)
        basis = np.column_stack((orientation[:3], orientation[3:], np.cross(orientation[:3], orientation[3:])))
        origin = np.asarray(grid.ImagePositionPatient, dtype=np.float64)
        resolution = np.asarray(grid.GridResolution, dtype=np.float64)
        pre = np.asarray(item.PreDeformationMatrixRegistrationSequence[0].FrameOfReferenceTransformationMatrix, dtype=np.float64).reshape(4, 4)
        post = np.asarray(item.PostDeformationMatrixRegistrationSequence[0].FrameOfReferenceTransformationMatrix, dtype=np.float64).reshape(4, 4)
        for probe, mapped in zip(expected["probePoints"], expected["expectedMappedPoints"], strict=True):
            point = np.asarray(probe, dtype=np.float64)
            coordinate = np.linalg.solve(basis, point - origin) / resolution
            lo = np.floor(coordinate).astype(int)
            hi = np.minimum(lo + 1, dims - 1)
            fraction = coordinate - lo
            displacement = np.zeros(3)
            for k in (0, 1):
                for j in (0, 1):
                    for i in (0, 1):
                        corners = np.asarray([i, j, k])
                        index = np.where(corners, hi, lo)
                        weight = np.prod(np.where(corners, fraction, 1 - fraction))
                        displacement += vectors[index[2], index[1], index[0]] * weight
            result = post @ (pre @ np.append(point, 1) + np.append(displacement, 0))
            np.testing.assert_allclose(result[:3], mapped, rtol=0, atol=1e-6)


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
    paths = sorted(args.corpus.glob("*.dcm"))
    require({path.stem for path in paths} == CASES, "Changed corpus case set")
    records = []
    for path in paths:
        name = path.stem
        expected = json.loads(path.with_suffix(".json").read_text())
        ds = pydicom.dcmread(path)
        require(ds.SOPClassUID == expected["sopClass"] and "PixelData" not in ds, "Changed SOP Class witness")
        witness(name, ds, expected)
        result = validator.validate(path)[str(path)]
        all_errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        false_positives = [e for e in all_errors if e in FALSE_POSITIVES]
        errors = [e for e in all_errors if e not in false_positives]
        require(errors == sorted(INDEPENDENT_ERRORS.get(name, [])), f"Changed independent errors for {name}: {errors}")
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"]
                                 + [flag for fact in FACTS for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        layers = {layer: outcome for layer, outcome in report["outcomes"].items() if layer != "operation"}
        limitations = sorted({d["code"] for d in report["diagnostics"] if d["severity"] == "limitation" and d["layer"] != "operation"})
        if name == "reg-with-used-fiducials-segments-rois":
            require(command.returncode == 2 and layers["references"] == "incomplete" and limitations == ["referenceTargetUnavailable"]
                    and all(outcome == "passed" for layer, outcome in layers.items() if layer != "references"),
                    f"Changed CLI outcome for {name}: {layers} {limitations}")
        else:
            require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode} {layers} {limitations}")
        agreement = (expected["outcome"] == "failed") == bool(errors)
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}")
        require(not agreement or name not in GAPS, f"Stale gap for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "falsePositives": len(false_positives),
            "cliLayers": layers, "cliLimitations": limitations, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} Spatial/Deformable Registration cases, {agreements} independent agreements after the documented "
          f"false positives, {len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
