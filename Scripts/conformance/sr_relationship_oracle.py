#!/usr/bin/env python3
"""Compare SR relationship fixtures with the pinned oracle, retaining by-reference diagnostic gaps."""

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

POSITIVE = {"22-baseline", "33-baseline", "59-baseline", "33-forward", "33-backward", "33-observation"}
REFERENCES = {
    "22-forward": [(0, [1, 2], "INFERRED FROM")],
    "33-forward": [(0, [1, 2], "INFERRED FROM")],
    "59-forward": [(0, [1, 2], "INFERRED FROM")],
    "33-backward": [(1, [1, 1], "INFERRED FROM")],
    "33-missing": [(0, [1, 99], "INFERRED FROM")],
    "33-invalid-root": [(0, [2], "INFERRED FROM")],
    "33-ancestor": [(0, [1], "INFERRED FROM")],
    "33-reference-target": [(0, [1, 2, 1], "INFERRED FROM"), (1, [1, 1], "INFERRED FROM")],
    "33-reference-contains": [(0, [1, 2], "CONTAINS")],
}
OTHER_NEGATIVE = {"22-observation", "33-invalid-pair"}


def witness(ds, case):
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88." + case[:2], "Unexpected SOP class")
    require(ds.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1", "Unexpected transfer syntax")
    require(ds.ContentSequence[-1].ValueType == "IMAGE", "Missing external object witness")
    evidence = ds.CurrentRequestedProcedureEvidenceSequence[0].ReferencedSeriesSequence[0].ReferencedSOPSequence[0]
    require(evidence.ReferencedSOPInstanceUID == ds.ContentSequence[-1].ReferencedSOPSequence[0].ReferencedSOPInstanceUID,
            "External evidence no longer matches")
    actual = []
    for index, item in enumerate(ds.ContentSequence):
        for child in item.get("ContentSequence", []):
            if "ReferencedContentItemIdentifier" in child:
                require("ValueType" not in child and "TextValue" not in child, "Reference must omit by-value attributes")
                element = child[0x0040DB73]
                values = list(element.value) if element.VM > 1 else [element.value]
                actual.append((index, values, child.RelationshipType))
    require(actual == REFERENCES.get(case, []), "Unexpected reference identifier witness")
    if case.endswith("observation") or case == "33-invalid-pair":
        source = ds.ContentSequence[0]
        child = source.ContentSequence[0]
        require(source.ValueType == child.ValueType == "TEXT", "Unexpected source/target types")
        require(child.RelationshipType == ("SELECTED FROM" if case == "33-invalid-pair" else "HAS OBS CONTEXT"),
                "Unexpected relationship witness")
    if case == "33-reference-contains":
        require(ds.ContentSequence[0].ValueType == "CONTAINER", "Missing container witness")
    if case.endswith("baseline"):
        require(len(ds.ContentSequence) == 2 and ds.ContentSequence[0].ValueType == "TEXT", "Unexpected baseline")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS, "Unexpected oracle dependency versions")
    require(args.standard_json.parent.name == "2026c", "DICOM 2026c cache required")
    files = {p.stem: p for p in args.corpus.glob("*.dcm")}
    require(set(files) == POSITIVE | set(REFERENCES) | OTHER_NEGATIVE, "Unexpected corpus cases")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    hashes = {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        source = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in source, "Unexpected docbook edition")
        hashes[name] = hashlib.sha256(source).hexdigest()
    info = DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for case, path in sorted(files.items()):
        witness(dcmread(path), case)
        expected = "passed" if case in POSITIVE else "failed"
        metadata = json.loads(path.with_suffix(".json").read_text())
        require(metadata == {"relationships": expected, "objects": "passed", "structureAndVRVM": "passed"},
                "Unexpected producer evidence")
        result = validator.validate(path)[str(path)]
        errors = [{"module": module, "tag": str(tag), "code": error.code.name}
                  for module, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        tags = ["(0040,A040)", "(0040,A050)" if case == "33-reference-contains" else "(0040,A160)"]
        expected_errors = ([{"module": "SR Document Content", "tag": "(0040,A730) / (0040,A730) / " + tag,
                             "code": "TagMissing"} for tag in tags] if case in REFERENCES else [])
        require(errors == expected_errors and result.errors == len(errors), "Changed independent diagnostics: " + case)
        require(result.status.name == ("Failed" if expected_errors else "Passed"), "Changed independent outcome")
        limitation = None
        if case in REFERENCES:
            limitation = "Oracle incorrectly requires by-value macros on a by-reference item; its missing-value errors do not test target resolution or the IOD relationship table."
        elif case in OTHER_NEGATIVE:
            limitation = "Oracle accepts a source/relationship/target combination forbidden by the IOD relationship table."
        results.append({"case": case, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "ownRelationshipOutcome": expected, "independentIODOutcome": result.status.name,
                        "independentErrors": errors, "diagnosticLimitation": limitation,
                        "outcomeAgreement": (expected == "passed") == (result.status.name == "Passed")})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes, "cases": results,
              "scope": "Intradocument identifiers and three IOD relationship tables, composed with external object evidence; full content/IOD/TID and geometry remain unqualified",
              "outcomeAgreements": sum(r["outcomeAgreement"] for r in results),
              "documentedDiagnosticLimitations": sum(r["diagnosticLimitation"] is not None for r in results)}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} cases, {report['outcomeAgreements']} outcome agreements, {report['documentedDiagnosticLimitations']} documented diagnostic limitations")


if __name__ == "__main__":
    main()
