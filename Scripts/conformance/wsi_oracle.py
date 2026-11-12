#!/usr/bin/env python3
"""Compare the WSI corpus with the pinned independent PS3.3 2026c IOD validator.

Separate numpy/pydicom witnesses verify tile order, sparse coordinates, compressed-frame
identity and derived origin. Requires requirements-iod.txt; never applies ICC or recompresses.
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
    "wsi-missing-icc": [("Optical Path", "(0048,0105) / (0028,2000)", "TagMissing")],
}
GAPS = {
    "wsi-tiled-full-frame-count": "Independent validator does not compare frame count with the full tile grid.",
    "wsi-sparse-without-positions": "Independent validator does not require per-frame groups for sparse tiling.",
    "wsi-position-outside-matrix": "Independent validator does not compare tile positions with matrix bounds.",
    "wsi-unknown-optical-path": "Independent validator does not resolve optical path identifiers.",
    "wsi-label-multiframe": "Independent validator does not apply the single-frame flavor constraint.",
    "wsi-volume-depth-zero": "Independent validator does not reject zero imaged depth.",
    "wsi-bits-mismatch": "Independent validator does not compare Bits Stored with Bits Allocated.",
    "wsi-flavor-unknown": "Independent validator does not restrict Image Type defined terms to the qualified flavors.",
}
CASES = {
    "wsi-tiled-full-pyramid-base", "wsi-tiled-full-level2", "wsi-tiled-full-two-paths-two-planes",
    "wsi-tiled-sparse-out-of-order", "wsi-tiled-sparse-missing-tile", "wsi-partial-edge-tiles",
    "wsi-label", "wsi-overview", "wsi-thumbnail", "wsi-monochrome-fluorescence",
    "wsi-encapsulated-passthrough", "wsi-region-derived", "wsi-rewrapped-container",
    "wsi-tiled-full-frame-count", "wsi-sparse-without-positions", "wsi-position-outside-matrix",
    "wsi-unknown-optical-path", "wsi-missing-icc", "wsi-label-multiframe", "wsi-volume-depth-zero",
    "wsi-bits-mismatch", "wsi-flavor-unknown",
}


def witness(name, ds, expected):
    if name == "wsi-tiled-full-two-paths-two-planes":
        cols = (int(ds.TotalPixelMatrixColumns) + int(ds.Columns) - 1) // int(ds.Columns)
        rows = (int(ds.TotalPixelMatrixRows) + int(ds.Rows) - 1) // int(ds.Rows)
        planes = int(ds.TotalPixelMatrixFocalPlanes)
        tiles = []
        for path in range(len(ds.OpticalPathSequence)):
            for plane in range(planes):
                for row in range(rows):
                    for col in range(cols):
                        tiles.append([len(tiles), col * int(ds.Columns), row * int(ds.Rows), plane, path])
        require(len(tiles) == int(ds.NumberOfFrames), "Independent full-grid frame count mismatch")
        np.testing.assert_array_equal(tiles, expected["tiles"])
    if name == "wsi-tiled-sparse-out-of-order":
        paths = [str(p.OpticalPathIdentifier) for p in ds.OpticalPathSequence]
        tiles = []
        for index, frame in enumerate(ds.PerFrameFunctionalGroupsSequence):
            pos = frame.PlanePositionSlideSequence[0]
            path = paths.index(str(frame.OpticalPathIdentificationSequence[0].OpticalPathIdentifier))
            tiles.append([index, int(pos.ColumnPositionInTotalImagePixelMatrix) - 1,
                          int(pos.RowPositionInTotalImagePixelMatrix) - 1, 0, path])
        np.testing.assert_array_equal(tiles, expected["tiles"])
    if name == "wsi-encapsulated-passthrough":
        frames = list(pydicom.encaps.generate_frames(ds.PixelData, number_of_frames=int(ds.NumberOfFrames)))
        hashes = [hashlib.sha256(frame).hexdigest() for frame in frames]
        require(hashes == expected["sourceFrameSHA256"], "Pass-through frame bytes changed")
        # Also prove the supplied fragments are actual decodable RLE, independently of the toolkit.
        require(ds.pixel_array.shape == (4, 2, 2, 3), "RLE witness shape changed")
    if name == "wsi-region-derived":
        origin = np.asarray(expected["sourceOrigin"], dtype=float)
        col, row = np.asarray(expected["firstSourceTile"], dtype=float) - 1
        spacing = np.asarray(ds.SharedFunctionalGroupsSequence[0].PixelMeasuresSequence[0].PixelSpacing, dtype=float)
        orientation = np.asarray(ds.ImageOrientationSlide, dtype=float)
        delta = col * spacing[1] * orientation[:3] + row * spacing[0] * orientation[3:]
        delta[2] *= 1000
        point = origin + delta
        actual = ds.TotalPixelMatrixOriginSequence[0]
        np.testing.assert_allclose(point, expected["expectedOrigin"], rtol=0, atol=1e-8)
        np.testing.assert_allclose(point, [float(actual.XOffsetInSlideCoordinateSystem), float(actual.YOffsetInSlideCoordinateSystem),
                                         float(actual.ZOffsetInSlideCoordinateSystem)], rtol=0, atol=1e-8)


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
        require(ds.SOPClassUID == expected["sopClass"] and "PixelData" in ds, "Changed SOP Class witness")
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
        if command.returncode == 1:
            require("failed" in layers.values(), f"CLI failure has no failed conformance layer for {name}: {layers}")
        limitations = sorted({d["code"] for d in report["diagnostics"] if d["severity"] == "limitation" and d["layer"] != "operation"})
        require(command.returncode == expected["exit"], f"Changed CLI exit for {name}: {command.returncode} {layers} {limitations}")
        if expected["exit"] == 2:
            require(layers["references"] == "incomplete" and limitations == ["referenceTargetUnavailable"]
                    and all(outcome == "passed" for layer, outcome in layers.items() if layer != "references"),
                    f"Changed reference-only incompleteness for {name}: {layers} {limitations}")
        agreement = (expected["outcome"] == "failed") == bool(errors)
        require(agreement or name in GAPS, f"Unexplained disagreement for {name}")
        require(not agreement or name not in GAPS, f"Stale gap for {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected,
            "independentOutcome": result.status.name, "errors": errors, "falsePositives": len(false_positives),
            "cliLayers": layers, "cliLimitations": limitations, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": versions, "facts": FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(1 for record in records if record["gap"] is None)
    print(f"PASS: {len(records)} Whole Slide Microscopy cases, {agreements} independent agreements after the documented "
          f"false positives, {len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
