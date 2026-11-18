#!/usr/bin/env python3
"""Witness C.18.6/C.18.9 serialized coordinate attributes and exact whole-IOD oracle gaps."""

import argparse
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path

from pydicom import dcmread
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

VALUES = {
    "scoord": {"point": [1, 1], "multipoint": [1, 1, 2, 2], "polyline": [0, 0, 1, 0, 1, 1],
               "circle": [2, 2, 3, 2], "ellipse": [0, 2, 4, 2, 2, 1, 2, 3]},
    "scoord3d": {"point": [-1, 0, 1], "multipoint": [-1, 0, 1, 2, 3, 4], "polyline": [0, 0, 0, 1, 0, 0, 1, 1, 1],
                 "polygon": [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 0, 0], "ellipse": [-2, 0, 0, 2, 0, 0, 0, -1, 0, 0, 1, 0],
                 "ellipsoid": [-3, 0, 0, 3, 0, 0, 0, -2, 0, 0, 2, 0, 0, 0, -1, 0, 0, 1]}}
EXTRAS = {"scoord-negative", "scoord-missing-data", "scoord-missing-type", "scoord-origin-unproven", "scoord-origin-frame",
          "scoord-origin-volume", "scoord-origin-invalid", "scoord-fiducial-empty", "scoord3d-missing-reference", "scoord3d-empty-reference", "scoord3d-polygon-open"}


def witness(case, source):
    kind, name = case.split("-", 1)
    three = kind == "scoord3d"
    require(source.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88." + ("34" if three else "33") and
            source.ValueType == "CONTAINER" and source.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1" and len(source.ContentSequence) == 1,
            "Wrong source SOP/encoding/root")
    item = source.ContentSequence[0]
    require(item.ValueType == kind.upper() and item.RelationshipType == "CONTAINS", "Wrong coordinate item")
    shape = name.split("-")[0] if name.split("-")[0] in VALUES[kind] else "point"
    require(("GraphicType" not in item) if name == "missing-type" else item.GraphicType == shape.upper(), "Wrong graphic type")
    values = VALUES[kind][shape]
    if name.endswith("-tuple"):
        values = values + [0]
    elif name.endswith("-count"):
        values = values + values if shape == "point" else values[:9 if shape == "polygon" else 3 if three else 2]
    elif name == "negative":
        values = [-1, 1]
    elif name == "polygon-open":
        values = [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0]
    require(("GraphicData" not in item) if name == "missing-data" else item[0x00700022].VR == "FL" and list(item.GraphicData) == values,
            "Wrong serialized coordinates")
    if three:
        require("ContentSequence" not in item and "CurrentRequestedProcedureEvidenceSequence" not in source and
                "PixelOriginInterpretation" not in item, "Unexpected image dependency for 3D coordinates")
        require(("ReferencedFrameOfReferenceUID" not in item) if name == "missing-reference" else
                item.ReferencedFrameOfReferenceUID == ("" if name == "empty-reference" else "2.25.232199"), "Wrong frame-of-reference UID")
    else:
        require("ReferencedFrameOfReferenceUID" not in item and len(item.ContentSequence) == 1, "Wrong 2D image relationship")
        target = item.ContentSequence[0]
        require(target.ValueType == "IMAGE" and target.RelationshipType == "SELECTED FROM" and len(target.ReferencedSOPSequence) == 1, "Wrong image target")
        pair = target.ReferencedSOPSequence[0]
        require(pair.ReferencedSOPClassUID == "1.2.840.10008.5.1.4.1.1.2.1" and pair.ReferencedSOPInstanceUID == "2.25.23212003", "Wrong target identity")
        evidence = source.CurrentRequestedProcedureEvidenceSequence[0].ReferencedSeriesSequence[0].ReferencedSOPSequence
        require(len(evidence) == 1 and evidence[0] == pair, "Wrong image evidence")
        origins = {"origin-frame": "FRAME", "origin-volume": "VOLUME", "origin-invalid": "FUTURE"}
        require(item.get("PixelOriginInterpretation") == origins.get(name), "Wrong origin interpretation")
    require(("FiducialUID" in item and item[0x0070031A].is_empty) if name == "fiducial-empty" else "FiducialUID" not in item, "Wrong fiducial presence")
    return {"kind": kind, "components": len(values) if name != "missing-data" else None, "graphicType": item.get("GraphicType")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Wrong oracle/standard version")
    cases = {kind + "-" + shape + suffix for kind, shapes in VALUES.items() for shape in shapes for suffix in ["", "-count", "-tuple"]} | EXTRAS
    require(len(cases) == 44 and {p.name for p in args.corpus.iterdir() if p.is_file()} ==
            {case + suffix for case in cases for suffix in [".dcm", ".json"]}, "Wrong corpus files")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    hashes = {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in data, "Wrong DocBook edition")
        hashes[name] = hashlib.sha256(data).hexdigest()
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json / n).read_text()) for n in names)), log_level=logging.CRITICAL)
    results = []
    special = {"scoord-negative": ["attributeValueNotAllowed"], "scoord-missing-data": ["requiredAttributeMissing"],
               "scoord-missing-type": ["requiredAttributeMissing", "valueUnavailable"], "scoord-origin-unproven": ["conditionUndetermined"],
               "scoord-origin-invalid": ["attributeValueNotAllowed"], "scoord3d-missing-reference": ["requiredAttributeMissing"],
               "scoord3d-empty-reference": ["requiredValueEmpty", "invalidMultiplicity"], "scoord3d-polygon-open": ["attributeValueContradiction"]}
    oracle_errors = {"scoord-missing-data": ("(0070,0022)", "TagMissing"), "scoord-missing-type": ("(0070,0023)", "TagMissing"),
                     "scoord-origin-invalid": ("(0048,0301)", "EnumValueNotAllowed"), "scoord3d-missing-reference": ("(3006,0024)", "TagMissing"),
                     "scoord3d-empty-reference": ("(3006,0024)", "TagEmpty")}
    for case in sorted(cases):
        path = args.corpus / (case + ".dcm")
        observed = witness(case, dcmread(path))
        own = json.loads(path.with_suffix(".json").read_text())
        diagnostics = ["invalidMultiplicity"] if case.endswith(("-tuple", "-count")) else special.get(case, [])
        expected = "incomplete" if case == "scoord-origin-unproven" else "failed" if diagnostics else "passed"
        require(own == {"attributes": expected, "diagnostics": diagnostics, "structureAndVRVM": "passed", "geometry": "notEvaluated",
                        "tiled": "unknown" if case == "scoord-origin-unproven" else "false"}, "Wrong attribute result or provenance: " + case)
        result = validator.validate(path)[str(path)]
        errors = [{"module": m, "tag": str(t), "code": e.code.name} for m, tags in (result.module_errors or {}).items() for t, e in tags.items()]
        wanted = [{"module": "SR Document Content", "tag": "(0040,A730) / " + oracle_errors[case][0], "code": oracle_errors[case][1]}] if case in oracle_errors else []
        require(errors == wanted and result.errors == len(errors) and result.status.name == ("Failed" if wanted else "Passed"), "Changed whole-IOD diagnostics: " + case)
        gap = None if expected == "passed" or case in oracle_errors else \
              "Oracle accepts unverified tiled-image conditions." if expected == "incomplete" else \
              "Oracle does not enforce coordinate tuples/cardinality, nonnegative 2D values or 3D polygon closure."
        results.append({"case": case, "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(), "witness": observed,
                        "own": own, "wholeIODOutcome": result.status.name, "wholeIODDiagnostics": errors, "limitation": gap})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes,
              "scope": "Spatial attribute counts, value domains, polygon closure and explicit tiled-image provenance; mathematical shape and target bounds are separate.",
              "independentWitnesses": len(results), "wholeIODAgreements": sum(r["limitation"] is None for r in results),
              "documentedWholeIODGaps": sum(r["limitation"] is not None for r in results), "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} spatial witnesses, {report['wholeIODAgreements']} agreements, {report['documentedWholeIODGaps']} documented gaps")


if __name__ == "__main__":
    main()
