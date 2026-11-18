#!/usr/bin/env python3
"""Use exact rational geometry and storage-rounding witnesses on synthetic C.18.6/C.18.9 shapes."""

import argparse
import hashlib
import importlib.metadata
import json
import logging
from fractions import Fraction as F
from pathlib import Path

from pydicom import dcmread
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

POSITIVE = {"2d-ellipse", "2d-circle", "3d-ellipse", "3d-ellipsoid", "3d-plane", "3d-leading-collinear", "3d-self-intersecting", "3d-polyline", "3d-huge", "3d-subnormal"}
INVALID = {"2d-center", "2d-oblique", "2d-order", "3d-center", "3d-oblique", "3d-nonplanar"}
DEGENERATE = {"2d-zero-axis", "2d-zero-radius", "3d-zero-axis", "3d-collinear"}
ROUNDING = {"2d-rounding", "3d-rounding"}


def sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def add(a, b):
    return tuple(x + y for x, y in zip(a, b))


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def exact_shape(graphic, points):
    if graphic in {"POINT", "MULTIPOINT", "POLYLINE"}:
        return "valid"
    if graphic == "CIRCLE":
        return "degenerate" if points[0] == points[1] else "valid"
    if graphic in {"ELLIPSE", "ELLIPSOID"}:
        axes = [sub(points[i + 1], points[i]) for i in range(0, len(points), 2)]
        if any(dot(axis, axis) == 0 for axis in axes):
            return "degenerate"
        centers = [add(points[i], points[i + 1]) for i in range(0, len(points), 2)]
        valid = all(c == centers[0] for c in centers) and all(dot(a, b) == 0 for i, a in enumerate(axes) for b in axes[:i])
        if graphic == "ELLIPSE":
            valid = valid and dot(axes[0], axes[0]) >= dot(axes[1], axes[1])
        return "valid" if valid else "invalid"
    require(graphic == "POLYGON" and points[0] == points[-1], "Unexpected polygon witness")
    vectors = [sub(p, points[0]) for p in points[1:]]
    # Independent choice: first non-collinear pair, rather than the implementation's longest baseline/normal.
    normal = next((cross(a, b) for i, a in enumerate(vectors) for b in vectors[:i] if cross(a, b) != (0, 0, 0)), None)
    if normal is None:
        return "degenerate"
    return "valid" if all(dot(normal, v) == 0 for v in vectors) else "invalid"


def witness(case, source):
    two = case.startswith("2d-")
    require(source.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88." + ("33" if two else "34") and
            source.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1" and source.ValueType == "CONTAINER" and len(source.ContentSequence) == 1,
            "Wrong SOP/encoding/root")
    item = source.ContentSequence[0]
    require(item.ValueType == ("SCOORD" if two else "SCOORD3D") and item.RelationshipType == "CONTAINS" and item[0x00700022].VR == "FL", "Wrong coordinate source")
    dimension = 2 if two else 3
    values = [F(float(v)) for v in item.GraphicData]
    require(len(values) % dimension == 0, "Incomplete coordinate tuple")
    points = [tuple(values[i:i + dimension]) + ((F(0),) if two else ()) for i in range(0, len(values), dimension)]
    expected_type = "CIRCLE" if case in {"2d-circle", "2d-zero-radius"} else "ELLIPSE" if two or case == "3d-ellipse" else \
                    "ELLIPSOID" if case in {"3d-ellipsoid", "3d-center", "3d-oblique", "3d-zero-axis", "3d-huge", "3d-subnormal"} else \
                    "POLYLINE" if case == "3d-polyline" else "POLYGON"
    require(item.GraphicType == expected_type and len(points) >= 2, "Wrong graphic type/count")
    if expected_type in {"ELLIPSE", "ELLIPSOID", "CIRCLE"}:
        require(len(points) == {"ELLIPSE": 4, "ELLIPSOID": 6, "CIRCLE": 2}[expected_type], "Wrong axis count")
    if two:
        require(all(v >= 0 for v in values) and "ReferencedFrameOfReferenceUID" not in item and len(item.ContentSequence) == 1, "Wrong 2D domain/relationship")
        target = item.ContentSequence[0]
        require(target.ValueType == "IMAGE" and target.RelationshipType == "SELECTED FROM" and len(target.ReferencedSOPSequence) == 1, "Wrong image target")
        pair = target.ReferencedSOPSequence[0]
        require(pair.ReferencedSOPClassUID == "1.2.840.10008.5.1.4.1.1.2.1" and pair.ReferencedSOPInstanceUID == "2.25.23212003", "Wrong image identity")
        require(list(source.CurrentRequestedProcedureEvidenceSequence[0].ReferencedSeriesSequence[0].ReferencedSOPSequence) == [pair], "Wrong evidence")
    else:
        require(item.ReferencedFrameOfReferenceUID == "2.25.232199" and "ContentSequence" not in item and "CurrentRequestedProcedureEvidenceSequence" not in source, "Wrong 3D independence/reference frame")
    if case in {"2d-center", "3d-center", "2d-oblique", "3d-oblique", "2d-order"}:
        axes = [sub(points[i+1], points[i]) for i in range(0, len(points), 2)]
        centers = [add(points[i+1], points[i]) for i in range(0, len(points), 2)]
        same_center = all(c == centers[0] for c in centers)
        orthogonal = all(dot(a, b) == 0 for i, a in enumerate(axes) for b in axes[:i])
        require(same_center == ("center" not in case) and orthogonal == ("oblique" not in case), "Wrong targeted axis contradiction")
        if case == "2d-order":
            require(dot(axes[0], axes[0]) < dot(axes[1], axes[1]), "Missing major/minor ordering contradiction")
    exact = exact_shape(expected_type, points)
    require(exact == ("valid" if case in POSITIVE else "degenerate" if case in DEGENERATE else "invalid"), "Wrong exact rational geometry: " + case)
    rounding_witness = False
    if case == "2d-rounding":
        require(values == [F(0), F(2), F(4), F(2), F(2), F(1), F(2), F(3) + F(2) ** -22], "Wrong one-ULP perturbation")
        corrected = list(points)
        # Each major-axis endpoint can originate at its rounding midpoint (half an FL ULP at 2).
        corrected[0] = (F(0), F(2) + F(2) ** -23, F(0))
        corrected[1] = (F(4), F(2) + F(2) ** -23, F(0))
        rounding_witness = exact_shape(expected_type, corrected) == "valid"
    elif case == "3d-rounding":
        quantum = F(2) ** -149
        require(points == [(F(0), F(0), F(0)), (F(1), F(0), F(0)), (F(1), F(1), F(0)), (F(0), F(1), quantum), (F(0), F(0), F(0))], "Wrong subnormal perturbation")
        corrected = [(x, y, quantum * (1 - 2*x + 2*y) / 4) for x, y, _ in points]
        rounding_witness = exact_shape(expected_type, corrected) == "valid" and all(abs(a[2] - b[2]) <= quantum / 2 for a, b in zip(points, corrected))
    require(rounding_witness == (case in ROUNDING), "Missing storage-rounding witness")
    if case in {"3d-huge", "3d-subnormal"}:
        scale = F(2) ** (100 if case == "3d-huge" else -149)
        require(values == [F(v) * scale for v in [-3, 0, 0, 3, 0, 0, 0, -2, 0, 0, 2, 0, 0, 0, -1, 0, 0, 1]], "Wrong extreme-scale witness")
    return {"exactRationalShape": exact, "roundingWitness": rounding_witness, "pointCount": len(points)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Wrong oracle/standard version")
    cases = POSITIVE | INVALID | DEGENERATE | ROUNDING
    require(len(cases) == 22 and {p.name for p in args.corpus.iterdir() if p.is_file()} == {c+s for c in cases for s in [".dcm", ".json"]}, "Wrong corpus files")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    hashes = {n: hashlib.sha256((args.standard_json/n).read_bytes()).hexdigest() for n in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in data, "Wrong DocBook edition")
        hashes[name] = hashlib.sha256(data).hexdigest()
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json/n).read_text()) for n in names)), log_level=logging.CRITICAL)
    results = []
    for case in sorted(cases):
        path = args.corpus/(case + ".dcm")
        proof = witness(case, dcmread(path))
        own = json.loads(path.with_suffix(".json").read_text())
        shape = "passed" if case in POSITIVE else "failed" if case in INVALID else "incomplete"
        code = [] if case in POSITIVE else ["spatialGeometryInvalid" if case in INVALID else "spatialGeometryDegenerate" if case in DEGENERATE else "spatialGeometryPrecisionUnavailable"]
        require(own == {"attributes": "passed", "structureAndVRVM": "passed", "shape": shape, "diagnostics": code,
                        "composedGeometry": "incomplete" if case.startswith("2d-") and shape == "passed" else shape}, "Wrong scoped result: " + case)
        result = validator.validate(path)[str(path)]
        require(result.status.name == "Passed" and result.errors == 0 and not result.module_errors, "Changed whole-IOD oracle result: " + case)
        results.append({"case": case, "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(), "proof": proof, "own": own,
                        "wholeIODOutcome": "Passed", "limitation": None if case in POSITIVE else "Whole-IOD oracle does not qualify shape geometry or numerical ambiguity."})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes, "independentRationalWitnesses": len(results),
              "scope": "Intrinsic geometry only; references, image bounds and full IOD qualification remain separate.",
              "wholeIODAgreements": len(POSITIVE), "documentedWholeIODGaps": len(cases - POSITIVE), "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} rational witnesses, {len(POSITIVE)} agreements, {len(cases-POSITIVE)} documented gaps")


if __name__ == "__main__":
    main()
