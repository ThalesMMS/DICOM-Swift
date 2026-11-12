#!/usr/bin/env python3
"""Witness C.18.6 identity, frame/Total Pixel Matrix bounds and exact external-validator gaps."""

import argparse
import hashlib
import importlib.metadata
import json
import logging
from fractions import Fraction
from pathlib import Path

from pydicom import dcmread
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

POINTS = {
    "frame-zero": (0, 0), "frame-edge": (9, 7), "frame-column-out": (10, 7), "frame-row-out": (9, 8),
    "tiled-frame-out": (50, 60), "tiled-volume": (90, 70), "tiled-volume-out": (91, 70),
    "tiled-origin-missing": (9, 7), "volume-matrix-missing": (1, 1), "target-missing": (1, 1),
    "target-wrong-identity": (1, 1), "target-row-missing": (1, 1), "target-row-zero": (1, 1), "target-frame-out": (1, 1),
}
AGREEMENTS = {"frame-zero", "frame-edge", "tiled-volume"}


def witness(case, source, target):
    require(source.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88.33" and source.ValueType == "CONTAINER" and
            len(source.ContentSequence) == 1, "Wrong source SOP/root")
    for data in [source, target]:
        require(data.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1" and
                data.file_meta.MediaStorageSOPClassUID == data.SOPClassUID and
                data.file_meta.MediaStorageSOPInstanceUID == data.SOPInstanceUID, "Wrong Part 10 identity/encoding")
    item = source.ContentSequence[0]
    require(item.ValueType == "SCOORD" and item.RelationshipType == "CONTAINS" and item.GraphicType == "POINT" and
            item[0x00700022].VR == "FL" and len(item.ContentSequence) == 1, "Wrong coordinate item")
    point = tuple(Fraction(float(value)) for value in item.GraphicData)
    require(point == POINTS[case], "Wrong serialized coordinates")
    selected = item.ContentSequence[0]
    require(selected.ValueType == "IMAGE" and selected.RelationshipType == "SELECTED FROM" and
            len(selected.ReferencedSOPSequence) == 1, "Wrong selection graph")
    pair = selected.ReferencedSOPSequence[0]
    require(pair.ReferencedSOPClassUID == target.SOPClassUID == "1.2.840.10008.5.1.4.1.1.2.1" and
            pair.ReferencedSOPInstanceUID == "2.25.23212003", "Wrong target class/reference")
    require(target.SOPInstanceUID == ("2.25.23219999" if case == "target-wrong-identity" else "2.25.23212003"), "Wrong actual identity")
    require(target.Columns == 9 and target[0x00280011].VR == "US" and target.NumberOfFrames == 2, "Wrong frame metadata")
    require(target.get("Rows") == (None if case == "target-row-missing" else 0 if case == "target-row-zero" else 7), "Wrong rows witness")
    tiled = case.startswith("tiled-")
    require(("TotalPixelMatrixColumns" in target) == tiled and ("TotalPixelMatrixRows" in target) == tiled, "Wrong matrix presence")
    if tiled:
        require(target.TotalPixelMatrixColumns == 90 and target.TotalPixelMatrixRows == 70 and
                target[0x00480006].VR == target[0x00480007].VR == "UL", "Wrong matrix dimensions")
    origin = "VOLUME" if case in {"tiled-volume", "tiled-volume-out", "volume-matrix-missing"} else "FRAME" if case == "tiled-frame-out" else None
    require(item.get("PixelOriginInterpretation") == origin, "Wrong explicit/default origin")
    require(pair.get("ReferencedFrameNumber") == (3 if case == "target-frame-out" else None), "Wrong frame selector")
    identity = pair.ReferencedSOPInstanceUID == target.SOPInstanceUID
    available = case != "target-missing"  # File exists as a control; deliberately withheld from the resolver.
    references = "incomplete" if not available else "failed" if not identity or case == "target-frame-out" else "passed"
    diagnostics = []
    if not available:
        bounds, diagnostics = "incomplete", ["referenceTargetUnavailable", "referenceTargetUnavailable"]
    elif not identity:
        bounds, diagnostics = "incomplete", ["referenceIdentityContradiction", "referenceTargetUnavailable"]
    elif case == "target-frame-out":
        require(int(pair.ReferencedFrameNumber) > int(target.NumberOfFrames), "Missing frame contradiction")
        bounds, diagnostics = "incomplete", ["referenceSelectionOutOfRange", "referenceTargetUnavailable"]
    else:
        columns = target.get("TotalPixelMatrixColumns") if origin == "VOLUME" else target.Columns
        rows = target.get("TotalPixelMatrixRows") if origin == "VOLUME" else target.get("Rows")
        if columns is None or rows is None:
            bounds, diagnostics = "incomplete", ["valueUnavailable", "referenceTargetUnavailable"]
        elif columns <= 0 or rows <= 0:
            bounds, diagnostics = "failed", ["referenceTargetGeometryInvalid", "referenceTargetUnavailable"]
        else:
            bounds = "passed" if 0 <= point[0] <= columns and 0 <= point[1] <= rows else "failed"
            if bounds == "failed": diagnostics = ["spatialCoordinateOutOfRange"]
    facts = "undetermined" if not available or not identity else "satisfied" if tiled else "unsatisfied"
    return {"structureAndVRVM": "passed", "bounds": bounds, "references": references, "composedGeometry": bounds,
            "tiled": facts, "diagnostics": diagnostics}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Wrong oracle/standard version")
    require({p.name for p in args.corpus.iterdir() if p.is_file()} ==
            {case + suffix for case in POINTS for suffix in [".dcm", ".target.dcm", ".json"]}, "Wrong corpus files")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    hashes = {name: hashlib.sha256((args.standard_json/name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent/"docbook"/name).read_bytes()
        require(b"2026c" in data, "Wrong DocBook edition")
        hashes[name] = hashlib.sha256(data).hexdigest()
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json/name).read_text()) for name in names)), log_level=logging.CRITICAL)
    results = []
    for case in sorted(POINTS):
        path, target_path = args.corpus/(case + ".dcm"), args.corpus/(case + ".target.dcm")
        own = witness(case, dcmread(path), dcmread(target_path))
        require(json.loads(path.with_suffix(".json").read_text()) == own, "Wrong scoped result: " + case)
        result = validator.validate(path)[str(path)]
        errors = [{"module": module, "tag": str(tag), "code": error.code.name}
                  for module, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        expected = [{"module": "SR Document Content", "tag": "(0040,A730) / (0040,A730) / (0008,1199) / (0008,1160)",
                     "code": "TagUnexpected"}] if case == "target-frame-out" else []
        require(errors == expected and result.errors == len(expected) and result.status.name == ("Failed" if expected else "Passed"),
                "Changed whole-IOD diagnostics: " + case)
        gap = None if case in AGREEMENTS else "Whole-IOD oracle does not resolve external image metadata or enforce derived origin/bounds."
        if case == "target-frame-out":
            gap = "Oracle rejects the selector as unexpected; this is not evidence that it checked the target frame count."
        results.append({"case": case, "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "targetSHA256": hashlib.sha256(target_path.read_bytes()).hexdigest(), "own": own,
                        "wholeIODOutcome": result.status.name, "wholeIODDiagnostics": errors, "limitation": gap})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes,
              "scope": "Coordinate references and metadata bounds only. Synthetic target metadata does not establish full target IOD or pixel conformance.",
              "independentPairWitnesses": len(results), "wholeIODAgreements": len(AGREEMENTS),
              "documentedWholeIODGaps": len(POINTS)-len(AGREEMENTS), "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} pair witnesses, {len(AGREEMENTS)} agreements, {len(POINTS)-len(AGREEMENTS)} documented gaps")


if __name__ == "__main__":
    main()
