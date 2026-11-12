#!/usr/bin/env python3
"""Witness SR reference-macro fixtures and external conditions without masking oracle gaps."""

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

POSITIVE = {"image-all", "image-subset-selected", "segment-subset-selected", "wave-all",
            "wave-subset-selected", "ps-valid", "rwvm-valid"}
UNKNOWN = {"image-unknown", "wave-unknown"}
NEGATIVE = {"image-subset-missing", "image-all-selected", "segment-subset-missing", "segment-both",
            "wave-subset-missing", "wave-all-selected", "ps-missing-uid", "ps-empty", "ps-multiple",
            "rwvm-missing-uid", "rwvm-empty", "rwvm-multiple"}
SELECTORS = {0x00081160: ("IS", [3]), 0x0062000B: ("US", [7]), 0x0040A0B0: ("US", [1, 0])}


def witness(ds, case):
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88.33", "Unexpected source SOP class")
    require(ds.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1", "Unexpected transfer syntax")
    require(len(ds.ContentSequence) == 1, "Unexpected content cardinality")
    child = ds.ContentSequence[0]
    require(child.ValueType == ("WAVEFORM" if case.startswith("wave-") else "IMAGE"), "Wrong content type")
    require(len(child.ReferencedSOPSequence) == 1, "Wrong primary reference shape")
    pair = child.ReferencedSOPSequence[0]
    suffix = "9.1.1" if case.startswith("wave-") else "66.4" if case.startswith("segment-") else "2.1"
    require(pair.ReferencedSOPClassUID == "1.2.840.10008.5.1.4.1.1." + suffix and
            pair.ReferencedSOPInstanceUID == "2.25.23212003", "Wrong primary reference identity")
    expected_selectors = set()
    if case.endswith("selected"):
        expected_selectors = {0x0040A0B0 if case.startswith("wave-") else
                              0x0062000B if case.startswith("segment-") else 0x00081160}
    if case == "segment-both":
        expected_selectors = {0x00081160, 0x0062000B}
    require({tag for tag in SELECTORS if tag in pair} == expected_selectors, "Wrong selector presence")
    require(all(tag not in child for tag in SELECTORS), "Misplaced selector")
    for tag in expected_selectors:
        element = pair[tag]
        values = list(element.value) if element.VM > 1 else [element.value]
        require(element.VR == SELECTORS[tag][0] and [int(v) for v in values] == SELECTORS[tag][1], "Wrong selector values")
    unexpected_tags = [f"({tag >> 16:04X},{tag & 0xffff:04X})" for tag in expected_selectors]
    auxiliary_tag = 0x00081199 if case.startswith("ps-") else 0x0008114B if case.startswith("rwvm-") else None
    require({tag for tag in [0x00081199, 0x0008114B] if tag in pair} ==
            ({auxiliary_tag} if auxiliary_tag else set()), "Wrong accompanying reference presence")
    evidence = ds.CurrentRequestedProcedureEvidenceSequence[0].ReferencedSeriesSequence[0].ReferencedSOPSequence
    require(len(evidence) == (2 if auxiliary_tag else 1), "Wrong evidence count")
    require(evidence[0].ReferencedSOPClassUID == pair.ReferencedSOPClassUID and
            evidence[0].ReferencedSOPInstanceUID == pair.ReferencedSOPInstanceUID, "Contradictory primary evidence")
    if auxiliary_tag:
        require(pair[auxiliary_tag].VR == "SQ", "Wrong accompanying sequence VR")
        items = pair[auxiliary_tag].value
        require(len(items) == (0 if case.endswith("empty") else 2 if case.endswith("multiple") else 1),
                "Wrong accompanying sequence cardinality")
        expected_class = "1.2.840.10008.5.1.4.1.1." + ("11.1" if case.startswith("ps-") else "67")
        require(evidence[1].ReferencedSOPClassUID == expected_class and
                evidence[1].ReferencedSOPInstanceUID == "2.25.23215007", "Wrong accompanying evidence")
        for item in items:
            require(item.ReferencedSOPClassUID == expected_class, "Wrong accompanying class")
            require(("ReferencedSOPInstanceUID" not in item) if case.endswith("missing-uid") else
                    item.ReferencedSOPInstanceUID == "2.25.23215007", "Wrong accompanying instance witness")
        unexpected_tags.append(f"({auxiliary_tag >> 16:04X},{auxiliary_tag & 0xffff:04X})")
    return unexpected_tags


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS, "Unexpected oracle dependency versions")
    require(args.standard_json.parent.name == "2026c", "DICOM 2026c cache required")
    cases = POSITIVE | UNKNOWN | NEGATIVE
    require({p.name for p in args.corpus.iterdir() if p.is_file()} ==
            {case + suffix for case in cases for suffix in [".dcm", ".json"]}, "Unexpected corpus files")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    hashes = {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in data, "Unexpected DocBook edition")
        hashes[name] = hashlib.sha256(data).hexdigest()
    info = DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for case in sorted(cases):
        path = args.corpus / (case + ".dcm")
        unexpected_tags = witness(dcmread(path), case)
        # An absent selector denotes the whole object, so unknown intent leaves nothing required (C.18.4/C.18.5 2026c).
        expected = "passed" if case in POSITIVE or case in UNKNOWN else "failed"
        condition = "unknown" if case in UNKNOWN else "multiple-subset" if "subset" in case or case == "segment-both" else "multiple-all"
        metadata_path = path.with_suffix(".json")
        require(json.loads(metadata_path.read_text()) == {"attributes": expected, "structureAndVRVM": "passed",
                "conditionEvidence": condition}, "Wrong producer result or external condition witness")
        result = validator.validate(path)[str(path)]
        errors = [{"module": module, "tag": str(tag), "code": error.code.name}
                  for module, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        expected_errors = [{"module": "SR Document Content", "tag": "(0040,A730) / (0008,1199) / " + tag,
                            "code": "TagUnexpected"} for tag in unexpected_tags]
        require(sorted(errors, key=str) == sorted(expected_errors, key=str) and result.errors == len(expected_errors) and
                result.status.name == ("Failed" if expected_errors else "Passed"), "Changed oracle diagnostics: " + case)
        limitation = None
        if unexpected_tags:
            limitation = "Oracle loses included-macro nesting; its unexpected-tag errors do not test selector conditions or accompanying pair cardinality/identity."
        elif case not in POSITIVE and case not in UNKNOWN:
            limitation = "Oracle does not evaluate the external target/selection intent; absent selectors do not establish a false condition."
        results.append({"case": case, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "conditionEvidenceSHA256": hashlib.sha256(metadata_path.read_bytes()).hexdigest(),
                        "externalConditionEvidence": condition, "ownAttributeOutcome": expected,
                        "independentIODOutcome": result.status.name, "independentErrors": errors,
                        "diagnosticLimitation": limitation})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes, "cases": results,
              "scope": "C.18.3/4/5 attribute subset with explicit external condition fixtures; target SOP applicability, payloads, icons, signatures and full IOD remain unqualified",
              "documentedDiagnosticLimitations": sum(r["diagnosticLimitation"] is not None for r in results)}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} cases; {report['documentedDiagnosticLimitations']} documented oracle diagnostic limitations")


if __name__ == "__main__":
    main()
