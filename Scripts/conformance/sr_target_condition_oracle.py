#!/usr/bin/env python3
"""Witness target-derived SR conditions separately from explicit author subset intent."""

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
from sr_sop_applicability_oracle import PREFIX, content_facts, traits

DOSE = {"dose-absent": None, "dose-one": 1, "dose-three": 3, "dose-zero": 0}
WAVE = {"wave-absent": None, "wave-empty": [], "wave-one": [(1, 1)], "wave-two": [(2, 2)],
        "wave-two-groups": [(1, 1), (1, 1)], "wave-zero": [(0, 0)], "wave-missing-count": [(None, 1)],
        "wave-missing-definitions": [(1, None)], "wave-conflicting-count": [(2, 1)]}


def witness(case, path, expected_traits):
    source = dcmread(path)
    target = dcmread(path.with_suffix(".target.dcm"))
    wave = case in WAVE
    uid = PREFIX + ("9.1.1" if wave else "481.2")
    require(source.SOPClassUID == PREFIX + "88.33" and target.SOPClassUID == uid, "Wrong SOP class")
    require(source.file_meta.TransferSyntaxUID == target.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1", "Wrong syntax")
    require(len(source.ContentSequence) == 1 and source.ContentSequence[0].ValueType == ("WAVEFORM" if wave else "IMAGE"), "Wrong value type")
    require(len(source.ContentSequence[0].ReferencedSOPSequence) == 1, "Wrong reference cardinality")
    pair = source.ContentSequence[0].ReferencedSOPSequence[0]
    require(set(pair.keys()) == {0x00081150, 0x00081155}, "Unexpected selector or companion")
    require(pair.ReferencedSOPClassUID == uid and pair.ReferencedSOPInstanceUID == target.SOPInstanceUID == "2.25.23212003", "Wrong target identity")
    studies = source.CurrentRequestedProcedureEvidenceSequence
    require(len(studies) == 1 and studies[0].StudyInstanceUID == target.StudyInstanceUID == "2.25.23212001", "Wrong study")
    series = studies[0].ReferencedSeriesSequence
    require(len(series) == 1 and series[0].SeriesInstanceUID == target.SeriesInstanceUID == "2.25.23212002", "Wrong series")
    evidence = series[0].ReferencedSOPSequence
    require(len(evidence) == 1 and evidence[0] == pair, "Contradictory evidence")
    facts = content_facts(expected_traits[uid])
    expected_shape = WAVE[case] if wave else DOSE[case]
    geometry_tag = 0x54000100 if wave else 0x00280008
    require(set(target.keys()) == {0x00080016, 0x00080018, 0x0020000D, 0x0020000E} |
            ({geometry_tag} if expected_shape is not None else set()), "Wrong geometry presence")
    if wave:
        groups = target.get("WaveformSequence", None)
        if groups is not None:
            require(len(groups) == len(expected_shape), "Wrong multiplex group count")
            for group, (count, definitions) in zip(groups, expected_shape):
                require(group.get("NumberOfWaveformChannels", None) == count, "Wrong declared channel count")
                require(set(group.keys()) == ({0x003A0005} if count is not None else set()) |
                        ({0x003A0200} if definitions is not None else set()), "Wrong channel metadata presence")
                if definitions is not None:
                    require(len(group.ChannelDefinitionSequence) == definitions and all(len(item) == 0 for item in group.ChannelDefinitionSequence),
                            "Wrong channel definition shape")
        coherent = bool(groups) and all(group.get("NumberOfWaveformChannels", 0) > 0 and
                    len(group.get("ChannelDefinitionSequence", [])) == group.NumberOfWaveformChannels for group in groups)
        if coherent:
            facts["multipleChannels"] = "satisfied" if sum(g.NumberOfWaveformChannels for g in groups) > 1 else "unsatisfied"
    else:
        count = target.get("NumberOfFrames", None)
        require((None if count is None else int(count)) == expected_shape, "Wrong frame count")
        if count is not None and count > 0:
            facts["multiframe"] = "satisfied"
    condition = facts["multipleChannels" if wave else "multiframe"]
    expected = {"undetermined": "incomplete", "satisfied": "failed", "unsatisfied": "passed"}[condition]
    return facts, expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Wrong oracle or standard version")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    standard = {name: json.loads((args.standard_json / name).read_text()) for name in names}
    expected_traits = {uid: traits(iod) for uid, iod in standard["iod_info.json"].items()}
    hashes = {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in data, "Unexpected DocBook edition")
        hashes[name] = hashlib.sha256(data).hexdigest()
    cases = sorted(DOSE.keys() | WAVE.keys())
    require({p.name for p in args.corpus.iterdir() if p.is_file()} ==
            {case + suffix for case in cases for suffix in [".dcm", ".target.dcm", ".json"]}, "Wrong corpus files")
    validator = DicomFileValidator(DicomInfo(*(standard[name] for name in names)), log_level=logging.CRITICAL)
    results = []
    for case in cases:
        path = args.corpus / (case + ".dcm")
        facts, expected = witness(case, path, expected_traits)
        require(json.loads(path.with_suffix(".json").read_text()) == {"contentFacts": facts, "authorIntent": "subset",
                "attributes": expected, "contentAttributes": "failed" if expected == "failed" else "incomplete", "structureAndVRVM": "passed"}, "Wrong derived facts or composed outcome: " + case)
        result = validator.validate(path)[str(path)]
        require(result.status.name == "Passed" and result.errors == 0 and not result.module_errors,
                "Changed whole-IOD oracle diagnostics: " + case)
        results.append({"case": case, "contentFacts": facts, "authorIntent": "subset", "ownAttributes": expected,
                        "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "targetSHA256": hashlib.sha256(path.with_suffix(".target.dcm").read_bytes()).hexdigest(),
                        "wholeIODOutcome": result.status.name, "wholeIODDiagnostics": [], "limitation": None if expected == "passed" else
                        "Whole-IOD oracle cannot derive cross-object counts or the author's explicit subset intent."})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes,
              "scope": "Target metadata and explicit author intent only; complete target IODs and payload geometry remain separate.",
              "independentConditionWitnesses": len(results), "wholeIODAgreements": sum(r["limitation"] is None for r in results),
              "documentedWholeIODGaps": sum(r["limitation"] is not None for r in results), "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} condition witnesses, {report['wholeIODAgreements']} whole-IOD agreement, "
          f"{report['documentedWholeIODGaps']} documented gaps")


if __name__ == "__main__":
    main()
