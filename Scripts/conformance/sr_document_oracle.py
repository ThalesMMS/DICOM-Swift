#!/usr/bin/env python3
"""Qualify SR/KOS document-module fixtures against the pinned independent IOD oracle."""

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

CASES = {f"sr-{sop}-{case}": (sop, case) for sop in ["22", "33", "59"]
         for case in (["baseline", "missing-date", "missing-evidence"] +
                      ([] if sop == "59" else ["verified-complete", "verified-no-observer", "verified-partial"]))}


def validate_witness(ds, sop, case):
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88." + sop, "Unexpected SOP class")
    require(ds.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1", "Unexpected transfer syntax")
    content = ds.ContentSequence[0]
    require(content.ValueType == "IMAGE" and len(content.ReferencedSOPSequence) == 1,
            "Missing content reference witness")
    require(("ContentDate" not in ds) == (case == "missing-date"), "Missing content date mutation witness")
    require(("CurrentRequestedProcedureEvidenceSequence" not in ds) == (case == "missing-evidence"),
            "Missing evidence mutation witness")
    if case != "missing-evidence":
        evidence = ds.CurrentRequestedProcedureEvidenceSequence[0].ReferencedSeriesSequence[0].ReferencedSOPSequence[0]
        require(evidence.ReferencedSOPInstanceUID == content.ReferencedSOPSequence[0].ReferencedSOPInstanceUID,
                "Mismatched baseline reference")
    if sop != "59":
        require(ds.VerificationFlag == ("VERIFIED" if case.startswith("verified-") else "UNVERIFIED"),
                "Unexpected verification state")
        require(ds.CompletionFlag == ("PARTIAL" if case == "verified-partial" else "COMPLETE"),
                "Unexpected completion state")
        require(("VerifyingObserverSequence" in ds) == (case in ["verified-complete", "verified-partial"]),
                "Missing verifying observer witness")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS, "Oracle dependency versions differ from the qualified set")
    require(args.standard_json.parent.name == "2026c", "DICOM 2026c cache required")
    files = {path.stem: path for path in args.corpus.glob("*.dcm")}
    require(set(files) == set(CASES), "Missing or unexpected corpus instances")
    source_hashes = {}
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    for name in names:
        source_hashes[name] = hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest()
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in data, "Unexpected standard edition in docbook")
        source_hashes[name] = hashlib.sha256(data).hexdigest()
    info = DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for name, (sop, case) in CASES.items():
        path = files[name]
        validate_witness(dcmread(path), sop, case)
        metadata = json.loads(path.with_suffix(".json").read_text())
        expected = "passed" if case in ["baseline", "verified-complete"] else "failed"
        references = "failed" if case == "missing-evidence" else "passed"
        combined = "failed" if expected == "failed" else "incomplete"
        require(metadata == {"expectedAttributes": expected, "actualAttributes": expected, "structureAndVRVM": "passed",
                             "actualReferences": references, "contentAttributes": "incomplete", "relationshipReferences": "passed",
                             "combinedAttributes": combined, "semanticOperation": "passed"},
                "Unexpected producer evidence for " + name)
        module = "Key Object Document" if sop == "59" else "SR Document General"
        missing = {"missing-date": "(0008,0023)", "verified-no-observer": "(0040,A073)"}
        if sop == "59":
            missing["missing-evidence"] = "(0040,A375)"
        expected_errors = [(module, missing[case], "TagMissing")] if case in missing else []
        result = validator.validate(path)[str(path)]
        errors = [{"module": mod, "tag": str(tag), "code": error.code.name,
                   "requirement": getattr(error.type, "value", error.type)}
                  for mod, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        require(result.status.name == ("Failed" if expected_errors else "Passed") and result.errors == len(errors),
                "Unexpected independent IOD result for " + name)
        require(sorted((e["module"], e["tag"], e["code"]) for e in errors) == expected_errors,
                "Independent diagnostics changed for " + name)
        divergence = None
        if sop != "59" and case == "missing-evidence":
            divergence = "Oracle does not enforce evidence required by references in SR content."
        if case == "verified-partial":
            divergence = "Oracle does not enforce VERIFIED implies COMPLETE."
        results.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "ownAttributeOutcome": expected, "ownReferenceOutcome": references, "independentIODOutcome": result.status.name,
                        "ownCombinedAttributeOutcome": combined, "ownContentAttributeOutcome": "incomplete",
                        "ownSemanticOperationOutcome": "passed", "ownRelationshipOutcome": "passed",
                        "independentErrors": errors, "divergence": divergence})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": source_hashes, "cases": results,
              "scope": "Document attributes, wire validation, content prerequisites, existing application semantics and content/evidence target identities; complete IOD/TID and broader reference semantics pending",
              "agreements": sum(r["divergence"] is None for r in results),
              "documentedDivergences": sum(r["divergence"] is not None for r in results)}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} cases, {report['agreements']} agreements, {report['documentedDivergences']} documented divergences")


if __name__ == "__main__":
    main()
