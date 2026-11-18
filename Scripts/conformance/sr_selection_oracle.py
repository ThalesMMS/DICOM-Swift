#!/usr/bin/env python3
"""Witness paired SR selector bytes and retain exact independent IOD diagnostic gaps.

Target fixtures qualify identity/selection metadata only, not complete target IODs.
The independent IOD validator does not resolve references across these files.
"""

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

# Each tuple fixes selector values and the distinguishing target metadata.
CASES = {
    "frame-valid": ("passed", [3], 3),
    "frame-outside": ("failed", [4], 3),
    "frame-zero": ("failed", [0], 3),
    "frame-unknown": ("incomplete", [1], None),
    "frame-wrong-identity": ("failed", [4], 3),
    "segment-valid": ("passed", [42], [7, 42]),
    "segment-missing": ("failed", [1], [7, 42]),
    "segment-unknown": ("incomplete", [42], [7, None]),
    "segment-duplicate": ("failed", [7], [7, 7]),
    "wave-valid": ("passed", [1, 0, 2, 2], [(2, 2), (3, 3)]),
    "wave-group-outside": ("failed", [3, 1], [(2, 2), (3, 3)]),
    "wave-channel-outside": ("failed", [1, 3], [(2, 2), (3, 3)]),
    "wave-unknown": ("incomplete", [1, 1], [(2, None)]),
    "wave-count-conflict": ("failed", [1, 1], [(3, 2)]),
}
SELECTORS = {"frame": (0x00081160, "IS", "2.1"), "segment": (0x0062000B, "US", "66.4"),
             "wave": (0x0040A0B0, "US", "9.1.1")}


def witness(source, target, case):
    family = case.split("-")[0]
    tag, vr, suffix = SELECTORS[family]
    expected, selection, geometry = CASES[case]
    for ds in [source, target]:
        require(ds.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1", "Unexpected transfer syntax")
        require(ds.file_meta.MediaStorageSOPClassUID == ds.SOPClassUID and
                ds.file_meta.MediaStorageSOPInstanceUID == ds.SOPInstanceUID, "File meta identity mismatch")
    require(source.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88.33", "Unexpected source class")
    require(len(source.ContentSequence) == 1, "Unexpected content cardinality")
    item = source.ContentSequence[0]
    require(item.ValueType == ("WAVEFORM" if family == "wave" else "IMAGE"), "Wrong content type")
    require(len(item.ReferencedSOPSequence) == 1, "Unexpected reference cardinality")
    pair = item.ReferencedSOPSequence[0]
    element = pair[tag]
    values = list(element.value) if element.VM > 1 else [element.value]
    require(element.VR == vr and [int(v) for v in values] == selection, "Wrong selector bytes")
    require(all(t not in item for t, _, _ in SELECTORS.values()), "Misplaced selector")
    require({t for t, _, _ in SELECTORS.values() if t in pair} == {tag}, "Unexpected alternate selector")
    require(pair.ReferencedSOPClassUID == target.SOPClassUID == "1.2.840.10008.5.1.4.1.1." + suffix,
            "Wrong referenced class")
    require(pair.ReferencedSOPInstanceUID == "2.25.23212003", "Wrong referenced instance")
    require(target.SOPInstanceUID == ("2.25.999" if case == "frame-wrong-identity" else "2.25.23212003"),
            "Wrong target identity witness")
    evidence = source.CurrentRequestedProcedureEvidenceSequence
    require(len(evidence) == 1 and len(evidence[0].ReferencedSeriesSequence) == 1, "Wrong evidence shape")
    series = evidence[0].ReferencedSeriesSequence[0]
    require(evidence[0].StudyInstanceUID == target.StudyInstanceUID and
            series.SeriesInstanceUID == target.SeriesInstanceUID, "Wrong evidence identity")
    require(len(series.ReferencedSOPSequence) == 1, "Wrong evidence cardinality")
    ref = series.ReferencedSOPSequence[0]
    require(ref.ReferencedSOPClassUID == pair.ReferencedSOPClassUID and
            ref.ReferencedSOPInstanceUID == pair.ReferencedSOPInstanceUID, "Wrong evidence pair")
    if family == "frame":
        actual = int(target.NumberOfFrames) if "NumberOfFrames" in target else None
    elif family == "segment":
        actual = [int(s.SegmentNumber) if "SegmentNumber" in s else None for s in target.SegmentSequence]
    else:
        actual = [(int(g.NumberOfWaveformChannels), len(g.ChannelDefinitionSequence)
                   if "ChannelDefinitionSequence" in g else None) for g in target.WaveformSequence]
    require(actual == geometry, "Wrong target geometry witness")
    return {"selectorTag": f"{tag:08X}", "selectorValues": selection, "targetMetadata": actual,
            "identityMatches": case != "frame-wrong-identity"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS, "Unexpected oracle dependency versions")
    require(args.standard_json.parent.name == "2026c", "DICOM 2026c cache required")
    expected_files = {case + suffix for case in CASES for suffix in [".source.dcm", ".target.dcm", ".json"]}
    require({p.name for p in args.corpus.iterdir() if p.is_file()} == expected_files, "Unexpected paired corpus files")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    hashes = {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in data, "Unexpected DocBook edition")
        hashes[name] = hashlib.sha256(data).hexdigest()
    info = DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for case, (expected, _, _) in sorted(CASES.items()):
        files = {suffix: args.corpus / (case + "." + suffix) for suffix in ["source.dcm", "target.dcm", "json"]}
        facts = witness(dcmread(files["source.dcm"]), dcmread(files["target.dcm"]), case)
        require(json.loads(files["json"].read_text()) == {"references": expected, "sourceAndTargetWire": "passed",
                "targetScope": "identity and selection metadata only"}, "Unexpected producer evidence")
        path = files["source.dcm"]
        result = validator.validate(path)[str(path)]
        errors = [{"module": module, "tag": str(tag), "code": error.code.name}
                  for module, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        tag = facts["selectorTag"]
        require(errors == [{"module": "SR Document Content", "tag": "(0040,A730) / (0008,1199) / " +
                f"({tag[:4]},{tag[4:]})", "code": "TagUnexpected"}] and result.errors == 1 and
                result.status.name == "Failed", "Changed independent diagnostics: " + case)
        results.append({"case": case, "sha256": {suffix: hashlib.sha256(p.read_bytes()).hexdigest()
                        for suffix, p in files.items()}, "independentByteWitness": facts,
                        "ownReferenceOutcome": expected, "independentSourceIODOutcome": result.status.name,
                        "independentErrors": errors,
                        "diagnosticLimitation": "Oracle loses selector nesting from the included composite macro. Its unexpected-tag error does not validate cross-file selector bounds or target identity."})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes, "cases": results,
              "scope": "Explicit selectors against target identity/selection metadata; target IODs, payloads, selector conditions and full source IOD are not qualified.",
              "independentCrossObjectValidation": "not supported by this oracle"}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} paired byte witnesses; {len(results)} exact documented oracle diagnostic gaps")


if __name__ == "__main__":
    main()
