#!/usr/bin/env python3
"""Witness the mandatory SCOORD/TCOORD selection graph and exact whole-IOD oracle gaps."""

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

POSITIVE = {"spatial-by-value", "spatial-backward", "spatial-forward", "spatial-multiple",
            "temporal-image", "temporal-waveform", "temporal-spatial", "temporal-backward"}
MISSING = {"spatial-missing", "spatial-empty", "spatial-unrelated", "temporal-missing", "temporal-empty"}
WRONG = {"spatial-wrong-relationship", "spatial-wrong-target", "temporal-wrong-target"}
BROKEN = {"spatial-target-missing": "contentReferenceTargetMissing", "spatial-identifier-invalid": "contentReferenceIdentifierInvalid"}
REFERENCES = {"spatial-backward": [1, 1], "spatial-forward": [1, 2], "spatial-target-missing": [1, 99],
              "spatial-identifier-invalid": [0], "temporal-backward": [1, 1]}


def witness(case, source):
    require(source.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88.33" and source.ValueType == "CONTAINER", "Wrong source profile/root")
    require(source.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1" and len(source.ContentSequence) == 2, "Wrong source encoding/shape")
    coordinate_index = 0 if case == "spatial-forward" else 1
    source_item = source.ContentSequence[coordinate_index]
    image = source.ContentSequence[1 - coordinate_index]
    require(image.ValueType == "IMAGE" and image.RelationshipType == "CONTAINS", "Wrong independent image target")
    spatial = case.startswith("spatial-")
    require(source_item.ValueType == ("SCOORD" if spatial else "TCOORD") and source_item.RelationshipType == "CONTAINS", "Wrong coordinate type")
    if spatial:
        require(source_item.GraphicType == "POINT" and list(source_item.GraphicData) == [1, 1], "Wrong spatial value witness")
    else:
        require(source_item.TemporalRangeType == "POINT" and source_item.ReferencedTimeOffsets == 0, "Wrong temporal value witness")
    children = source_item.get("ContentSequence", [])
    require(("ContentSequence" in source_item) == (not case.endswith("-missing") or case == "spatial-target-missing"), "Wrong sequence presence")
    require(len(children) == (0 if case in {"spatial-missing", "spatial-empty", "temporal-missing", "temporal-empty"} else
                            2 if case == "spatial-multiple" else 1), "Wrong selection count")
    if case in REFERENCES:
        child = children[0]
        values = list(child.ReferencedContentItemIdentifier) if child[0x0040DB73].VM > 1 else [child.ReferencedContentItemIdentifier]
        require([int(v) for v in values] == REFERENCES[case] and child.RelationshipType == "SELECTED FROM" and
                set(child.keys()) == {0x0040A010, 0x0040DB73}, "Wrong by-reference witness")
    else:
        for child in children:
            expected_type = "CODE" if case == "spatial-unrelated" else "TEXT" if case.endswith("wrong-target") else \
                            "WAVEFORM" if case == "temporal-waveform" else "SCOORD" if case == "temporal-spatial" else "IMAGE"
            expected_relationship = "HAS CONCEPT MOD" if case == "spatial-unrelated" else "HAS PROPERTIES" if case == "spatial-wrong-relationship" else "SELECTED FROM"
            require(child.ValueType == expected_type and child.RelationshipType == expected_relationship, "Wrong target type or relationship")
            if expected_type == "SCOORD":
                require(child.GraphicType == "POINT" and list(child.GraphicData) == [1, 1] and len(child.ContentSequence) == 1 and
                        child.ContentSequence[0].ValueType == "IMAGE" and child.ContentSequence[0].RelationshipType == "SELECTED FROM", "Wrong temporal-to-spatial chain")
    # Independently index the serialized graph; identifiers retain original one-based positions.
    nodes, edges = {}, []
    def walk(item, identifier):
        nodes[identifier] = item
        for index, child in enumerate(item.get("ContentSequence", []), 1):
            child_id = identifier + (index,)
            if "ReferencedContentItemIdentifier" in child:
                value = child.ReferencedContentItemIdentifier
                target = tuple(int(v) for v in (value if child[0x0040DB73].VM > 1 else [value]))
                edges.append((identifier, target, child.RelationshipType))
            else:
                edges.append((identifier, child_id, child.RelationshipType))
            walk(child, child_id)
    walk(source, (1,))
    valid_selections = 0
    for source_id, item in nodes.items():
        if item.get("ValueType") not in {"SCOORD", "TCOORD"}:
            continue
        allowed = {"IMAGE"} if item.ValueType == "SCOORD" else {"SCOORD", "IMAGE", "WAVEFORM"}
        count = sum(edge_source == source_id and relationship == "SELECTED FROM" and target in nodes and
                    nodes[target].get("ValueType") in allowed for edge_source, target, relationship in edges)
        valid_selections += count
    require(valid_selections == (2 if case in {"spatial-multiple", "temporal-spatial"} else 1 if case in POSITIVE else 0), "Unexpected resolved selection witness")
    evidence = source.CurrentRequestedProcedureEvidenceSequence[0].ReferencedSeriesSequence[0].ReferencedSOPSequence
    require(len(evidence) == (2 if case == "temporal-waveform" else 1), "Wrong evidence count")
    for item in nodes.values():
        if item.get("ValueType") in {"IMAGE", "WAVEFORM"}:
            require(len(item.ReferencedSOPSequence) == 1, "Wrong target pair count")
            pair = item.ReferencedSOPSequence[0]
            waveform = item.ValueType == "WAVEFORM"
            require(pair.ReferencedSOPClassUID == "1.2.840.10008.5.1.4.1.1." + ("9.1.1" if waveform else "2.1") and
                    pair.ReferencedSOPInstanceUID == ("2.25.23220007" if waveform else "2.25.23212003"), "Wrong external object identity")
            require(any(e == pair for e in evidence), "Missing object evidence")
    return valid_selections


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Wrong oracle/standard version")
    cases = POSITIVE | MISSING | WRONG | BROKEN.keys()
    require(len(cases) == 18 and {p.name for p in args.corpus.iterdir() if p.is_file()} ==
            {case + suffix for case in cases for suffix in [".dcm", ".json"]}, "Unexpected corpus files")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    hashes = {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in data, "Wrong DocBook edition")
        hashes[name] = hashlib.sha256(data).hexdigest()
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json / n).read_text()) for n in names)), log_level=logging.CRITICAL)
    results = []
    for case in sorted(cases):
        path = args.corpus / (case + ".dcm")
        selections = witness(case, dcmread(path))
        own = [] if case in POSITIVE else [BROKEN[case]] if case in BROKEN else \
              (["relationshipNotAllowed"] if case in WRONG else []) + ["requiredRelationshipMissing"]
        expected = "passed" if case in POSITIVE else "failed"
        require(json.loads(path.with_suffix(".json").read_text()) ==
                {"relationships": expected, "diagnostics": own, "structureAndVRVM": "passed"}, "Wrong graph result: " + case)
        result = validator.validate(path)[str(path)]
        errors = [{"module": m, "tag": str(t), "code": e.code.name} for m, tags in (result.module_errors or {}).items() for t, e in tags.items()]
        expected_errors = []
        if case in REFERENCES:
            tags = ["(0040,A040)", "(0040,A130)", "(0040,A138)"] if case.startswith("temporal") else ["(0040,A040)", "(0070,0022)", "(0070,0023)"]
            expected_errors = [{"module": "SR Document Content", "tag": "(0040,A730) / (0040,A730) / " + tag, "code": "TagMissing"} for tag in tags]
        elif case.endswith("-empty"):
            expected_errors = [{"module": "SR Document Content", "tag": "(0040,A730) / (0040,A730)", "code": "TagEmpty"}]
        require(errors == expected_errors and result.errors == len(errors) and result.status.name == ("Failed" if errors else "Passed"),
                "Changed whole-IOD oracle diagnostics: " + case)
        gap = None
        if case in REFERENCES:
            gap = "Oracle applies by-value coordinate macros to reference items; its errors do not test reference identifiers or target resolution."
        elif case.endswith("-empty"):
            gap = "Oracle rejects the empty sequence structurally but does not establish the mandatory coordinate selection rule."
        elif case not in POSITIVE:
            gap = "Oracle does not enforce the required SELECTED FROM relationship or compatible target type."
        results.append({"case": case, "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(), "independentResolvedSelections": selections,
                        "ownRelationships": expected, "ownDiagnostics": own, "wholeIODOutcome": result.status.name,
                        "wholeIODDiagnostics": errors, "limitation": gap})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes,
              "scope": "SCOORD/TCOORD selection relationships; coordinate values and external object geometry remain separate.",
              "independentGraphWitnesses": len(results), "wholeIODSelectionAgreements": sum(r["limitation"] is None for r in results),
              "documentedWholeIODGaps": sum(r["limitation"] is not None for r in results), "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} graph witnesses, {report['wholeIODSelectionAgreements']} selection agreements, {report['documentedWholeIODGaps']} documented gaps")


if __name__ == "__main__":
    main()
