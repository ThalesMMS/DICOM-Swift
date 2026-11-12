#!/usr/bin/env python3
"""Witness serialized C.18.7 values/condition provenance and exact whole-IOD oracle gaps."""

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

RANGES = {"point": (1, 2), "begin": (1, 2), "end": (1, 2), "segment": (2, 1), "multipoint": (3, 1), "multisegment": (4, 3)}
TAGS = [0x0040A132, 0x0040A138, 0x0040A13A]
KINDS = ["samples", "offsets", "dates"]
EXTRAS = {"choice-0-1", "choice-0-2", "choice-1-2", "missing-range", "unknown-range", "empty-0", "empty-1", "empty-2",
          "samples-zero", "samples-nonwave", "samples-multigroup", "samples-unproven"}


def witness(case, source, own):
    require(source.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88.33" and source.ValueType == "CONTAINER" and
            source.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1" and len(source.ContentSequence) == 1, "Wrong source identity/encoding")
    item = source.ContentSequence[0]
    require(item.ValueType == "TCOORD" and item.RelationshipType == "CONTAINS" and len(item.ContentSequence) == 1, "Wrong temporal item")
    pieces = case.split("-")
    ordinary = pieces[0] in RANGES
    kind = KINDS.index(pieces[1]) if ordinary else int(pieces[1]) if pieces[0] in {"empty", "choice"} else 0 if pieces[0] == "samples" else 1
    count = RANGES[pieces[0]][int(case.endswith("-count"))] if ordinary else 1
    selected = {kind, int(pieces[2])} if pieces[0] == "choice" else {kind}
    require({i for i, tag in enumerate(TAGS) if tag in item} == selected, "Wrong representation choice")
    if case == "missing-range":
        require("TemporalRangeType" not in item, "Unexpected range")
    else:
        expected_range = pieces[0].upper() if ordinary else "FUTURE" if case == "unknown-range" else "POINT"
        require(item.TemporalRangeType == expected_range, "Wrong temporal range")
    counts = {}
    for index in selected:
        element = item[TAGS[index]]
        require(element.VR == ["UL", "DS", "DT"][index], "Wrong representation VR")
        if pieces[0] == "empty":
            require(element.is_empty and element.VM == 0, "Wrong empty representation")
            counts[index] = 0
            continue
        actual = list(element.value) if element.VM > 1 else [element.value]
        expected = list(range(1, count + 1)) if index == 0 else list(range(count)) if index == 1 else ["2026090812000" + str(i) for i in range(count)]
        if case == "samples-zero":
            expected = [0]
        normalized = [int(v) if index == 0 else float(v) if index == 1 else str(v) for v in actual]
        require(normalized == expected, "Wrong temporal values")
        counts[index] = len(actual)
    target = item.ContentSequence[0]
    waveform = kind == 0 and case != "samples-nonwave"
    require(target.ValueType == ("WAVEFORM" if waveform else "IMAGE") and target.RelationshipType == "SELECTED FROM" and
            len(target.ReferencedSOPSequence) == 1, "Wrong SELECTED FROM target")
    pair = target.ReferencedSOPSequence[0]
    require(pair.ReferencedSOPClassUID == "1.2.840.10008.5.1.4.1.1." + ("9.1.1" if waveform else "2.1") and
            pair.ReferencedSOPInstanceUID == ("2.25.23220007" if waveform else "2.25.23212003"), "Wrong target identity")
    if waveform:
        require(list(pair.ReferencedWaveformChannels) == ([1, 1, 2, 1] if case == "samples-multigroup" else [1, 1, 1, 2]), "Wrong multiplex selection")
    else:
        require("ReferencedWaveformChannels" not in pair, "Unexpected waveform channels")
    evidence = source.CurrentRequestedProcedureEvidenceSequence[0].ReferencedSeriesSequence[0].ReferencedSOPSequence
    require(len(evidence) == 1 and evidence[0].ReferencedSOPClassUID == pair.ReferencedSOPClassUID and
            evidence[0].ReferencedSOPInstanceUID == pair.ReferencedSOPInstanceUID, "Wrong target evidence")
    wave_fact = "unknown" if case == "samples-unproven" else "true" if waveform else "false"
    group_fact = "unknown" if case == "samples-unproven" or not waveform else "false" if case == "samples-multigroup" else "true"
    require(own["referencesWaveform"] == wave_fact and own["singleMultiplexGroup"] == group_fact, "Wrong external condition provenance")
    return {"componentCounts": counts, "selectedTarget": target.ValueType, "range": item.get("TemporalRangeType")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Wrong oracle/standard version")
    cases = {r + "-" + k + suffix for r in RANGES for k in KINDS for suffix in ["", "-count"]} | EXTRAS
    require(len(cases) == 48 and {p.name for p in args.corpus.iterdir() if p.is_file()} ==
            {case + suffix for case in cases for suffix in [".dcm", ".json"]}, "Wrong corpus files")
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
        own = json.loads(path.with_suffix(".json").read_text())
        observed = witness(case, dcmread(path), own)
        diagnostics = []
        if case.endswith("-count"):
            diagnostics = ["invalidMultiplicity"]
        elif case.startswith("choice-"):
            diagnostics = ["exclusiveAttributeChoiceInvalid", "conditionalAttributeForbidden", "conditionalAttributeForbidden"]
        elif case in {"missing-range", "unknown-range"}:
            diagnostics = ["requiredAttributeMissing" if case == "missing-range" else "attributeValueNotAllowed", "valueUnavailable"]
        elif case.startswith("empty-"):
            diagnostics = ["requiredValueEmpty"]
        elif case.startswith("samples-"):
            diagnostics = {"samples-zero": ["attributeValueNotAllowed"], "samples-nonwave": ["conditionalAttributeForbidden", "conditionUndetermined"],
                           "samples-multigroup": ["attributeValueContradiction"], "samples-unproven": ["conditionUndetermined", "conditionUndetermined"]}[case]
        expected = "incomplete" if case == "samples-unproven" else "failed" if diagnostics else "passed"
        require(own["attributes"] == expected and own["diagnostics"] == diagnostics and own["structureAndVRVM"] == "passed", "Wrong own result: " + case)
        result = validator.validate(path)[str(path)]
        errors = [{"module": m, "tag": str(t), "code": e.code.name} for m, tags in (result.module_errors or {}).items() for t, e in tags.items()]
        wanted = []
        waveform = observed["selectedTarget"] == "WAVEFORM"
        if waveform:
            wanted.append({"module": "SR Document Content", "tag": "(0040,A730) / (0040,A730) / (0008,1199) / (0040,A0B0)", "code": "TagUnexpected"})
        if case.startswith("empty-"):
            tag = ["(0040,A132)", "(0040,A138)", "(0040,A13A)"][int(case[-1])]
            wanted.append({"module": "SR Document Content", "tag": "(0040,A730) / " + tag, "code": "TagEmpty"})
        if case in {"missing-range", "unknown-range"}:
            wanted.append({"module": "SR Document Content", "tag": "(0040,A730) / (0040,A130)",
                           "code": "TagMissing" if case == "missing-range" else "EnumValueNotAllowed"})
        require(errors == wanted and result.errors == len(errors) and result.status.name == ("Failed" if errors else "Passed"), "Changed whole-IOD diagnostics: " + case)
        gap = "Oracle wrongly excludes waveform channel selectors from their nested reference macro." if waveform else \
              "Oracle does not enforce temporal cardinality, exclusive representations or waveform-only sample positions." if \
              case.endswith("-count") or case.startswith("choice-") or case == "samples-nonwave" else None
        results.append({"case": case, "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(), "witness": observed,
                        "own": own, "wholeIODOutcome": result.status.name, "wholeIODDiagnostics": errors, "limitation": gap})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes,
              "scope": "C.18.7 attribute choice, cardinality, representation values and explicit condition provenance; target bounds/alignment are separate.",
              "independentWitnesses": len(results), "wholeIODAgreements": sum(r["limitation"] is None for r in results),
              "documentedWholeIODGaps": sum(r["limitation"] is not None for r in results), "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} temporal witnesses, {report['wholeIODAgreements']} agreements, {report['documentedWholeIODGaps']} documented gaps")


if __name__ == "__main__":
    main()
