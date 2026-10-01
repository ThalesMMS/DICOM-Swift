#!/usr/bin/env python3
"""Independently witness temporal sample/group metadata and exact whole-SR oracle gaps."""

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

CASES = {"sample-first", "sample-last", "sample-out", "sample-zero", "channels-zero", "channels-missing", "channels-out",
         "groups-two", "group-missing", "sample-count-missing", "sample-count-zero", "target-missing", "target-identity",
         "shared-group", "different-groups", "unknown-shared-group", "offset-alignment", "date-alignment"}
MULTIPLE = {"shared-group", "different-groups", "unknown-shared-group"}


def witness(case, source, targets):
    require(source.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88.33" and source.ValueType == "CONTAINER" and
            len(source.ContentSequence) == 1, "Wrong SR root/profile")
    for data in [source] + targets:
        require(data.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1" and
                data.file_meta.MediaStorageSOPClassUID == data.SOPClassUID and
                data.file_meta.MediaStorageSOPInstanceUID == data.SOPInstanceUID, "Wrong Part 10 encoding/identity")
    item = source.ContentSequence[0]
    require(item.ValueType == "TCOORD" and item.RelationshipType == "CONTAINS" and item.TemporalRangeType == "POINT" and
            len(item.ContentSequence) == len(targets) == (2 if case in MULTIPLE else 1), "Wrong temporal selection graph")
    sample = 1 if case == "sample-first" else 0 if case == "sample-zero" else 8 if case == "sample-out" else 7
    if case.endswith("-alignment"):
        require("ReferencedSamplePositions" not in item, "Unexpected sample representation")
        require(item.get("ReferencedTimeOffsets") == (-1 if case == "offset-alignment" else None) and
                item.get("ReferencedDateTime") == ("20260908" if case == "date-alignment" else None), "Wrong time representation")
    else:
        require(item[0x0040A132].VR == "UL" and item.ReferencedSamplePositions == sample, "Wrong serialized sample position")
    groups = []
    for index, (selection, target) in enumerate(zip(item.ContentSequence, targets)):
        require(selection.ValueType == "WAVEFORM" and selection.RelationshipType == "SELECTED FROM" and
                len(selection.ReferencedSOPSequence) == 1, "Wrong waveform reference")
        pair = selection.ReferencedSOPSequence[0]
        expected_uid = "2.25.23212003" if index == 0 else "2.25.23212006"
        require(pair.ReferencedSOPClassUID == target.SOPClassUID == "1.2.840.10008.5.1.4.1.1.9.1.1" and
                pair.ReferencedSOPInstanceUID == expected_uid and target.SOPInstanceUID ==
                ("2.25.999" if case == "target-identity" else expected_uid), "Wrong actual/reference identity")
        expected = None if case == "channels-missing" else [1, 0] if case == "channels-zero" else [1, 3] if case == "channels-out" else \
                   [3, 1] if case == "group-missing" else [1, 1, 2, 1] if case == "groups-two" else [1, 1]
        channels = pair.get("ReferencedWaveformChannels")
        require((None if channels is None else list(channels)) == expected, "Wrong channel selection")
        require(len(target.WaveformSequence) == (2 if case == "groups-two" else 1), "Wrong multiplex group count")
        for ordinal, group in enumerate(target.WaveformSequence, 1):
            require(group.NumberOfWaveformChannels == len(group.ChannelDefinitionSequence) == 2 and
                    group.get("NumberOfWaveformSamples") == (None if case == "sample-count-missing" else 0 if case == "sample-count-zero" else 7),
                    "Wrong target channel/sample metadata")
            uid = "2.25.2321880" + ("2" if case == "different-groups" and index == 1 else "1") if case in MULTIPLE and case != "unknown-shared-group" else None
            require(group.get("MultiplexGroupUID") == uid, "Wrong cross-instance group identity")
            if channels is not None and ordinal in list(channels)[::2]:
                groups.append((str(target.SOPInstanceUID), ordinal, uid, group.get("NumberOfWaveformSamples")))
    facts = "unknown" if case in {"target-missing", "target-identity"} else "true"
    single = "unknown" if case in {"channels-missing", "channels-out", "group-missing", "target-missing", "target-identity"} else "true"
    if single == "true":
        locations = {(instance, ordinal) for instance, ordinal, _, _ in groups}
        declared = {uid for _, _, uid, _ in groups if uid is not None}
        if len(locations) > 1:
            single = "false" if len(declared) > 1 or len({instance for instance, _ in locations}) == 1 else \
                     "true" if len(declared) == 1 and all(uid is not None for _, _, uid, _ in groups) else "unknown"
    references, diagnostics = "passed", []
    if case == "target-missing": references, diagnostics = "incomplete", ["referenceTargetUnavailable", "referenceTargetUnavailable"]
    elif case == "target-identity": references, diagnostics = "failed", ["referenceIdentityContradiction", "referenceTargetUnavailable"]
    elif case in {"channels-out", "group-missing"}: references, diagnostics = "failed", ["referenceSelectionOutOfRange", "referenceTargetUnavailable"]
    elif case == "channels-missing": diagnostics = ["valueUnavailable", "referenceTargetUnavailable"]
    elif case.endswith("-alignment"): diagnostics = ["temporalAlignmentUnavailable"]
    elif single == "false": diagnostics = ["attributeValueContradiction"]
    elif single == "unknown": diagnostics = ["referenceTargetUnavailable"]
    elif any(count is None for _, _, _, count in groups): diagnostics = ["valueUnavailable"]
    elif any(count <= 0 for _, _, _, count in groups): diagnostics = ["referenceTargetGeometryInvalid"]
    elif sample < 1: diagnostics = ["attributeValueNotAllowed"]
    elif any(sample > count for _, _, _, count in groups): diagnostics = ["temporalCoordinateOutOfRange"]
    errors = {"attributeValueContradiction", "referenceTargetGeometryInvalid", "attributeValueNotAllowed", "temporalCoordinateOutOfRange"}
    bounds = "failed" if errors.intersection(diagnostics) else "incomplete" if diagnostics else "passed"
    return {"structureAndVRVM": "passed", "bounds": bounds, "composedGeometry": bounds, "references": references,
            "referencesWaveform": facts, "singleGroup": single, "diagnostics": diagnostics}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Wrong oracle/standard version")
    files = {case + suffix for case in CASES for suffix in [".dcm", ".target-0.dcm", ".json"]} | {case + ".target-1.dcm" for case in MULTIPLE}
    require({p.name for p in args.corpus.iterdir() if p.is_file()} == files, "Wrong corpus files")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    hashes = {name: hashlib.sha256((args.standard_json/name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent/"docbook"/name).read_bytes()
        require(b"2026c" in data, "Wrong DocBook edition")
        hashes[name] = hashlib.sha256(data).hexdigest()
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json/name).read_text()) for name in names)), log_level=logging.CRITICAL)
    results = []
    for case in sorted(CASES):
        path = args.corpus/(case + ".dcm")
        target_paths = [args.corpus/(case + f".target-{index}.dcm") for index in range(2 if case in MULTIPLE else 1)]
        own = witness(case, dcmread(path), [dcmread(target) for target in target_paths])
        require(json.loads(path.with_suffix(".json").read_text()) == own, "Wrong scoped outcome: " + case)
        result = validator.validate(path)[str(path)]
        errors = [{"module": module, "tag": str(tag), "code": error.code.name}
                  for module, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        expected = [] if case == "channels-missing" else [{"module": "SR Document Content",
            "tag": "(0040,A730) / (0040,A730) / (0008,1199) / (0040,A0B0)", "code": "TagUnexpected"}]
        require(errors == expected and result.errors == len(expected) and result.status.name == ("Failed" if expected else "Passed"),
                "Changed whole-IOD diagnostics: " + case)
        results.append({"case": case, "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "targetSHA256": [hashlib.sha256(target.read_bytes()).hexdigest() for target in target_paths], "own": own,
                        "wholeIODOutcome": result.status.name, "wholeIODDiagnostics": errors,
                        "limitation": "Oracle does not resolve target sample/group metadata; unexpected-selector errors are not bound or group validation."})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes, "independentMetadataWitnesses": len(results),
              "wholeIODAgreements": 0, "documentedWholeIODGaps": len(results),
              "scope": "Sample positions, group identities and explicit alignment limitations. Target metadata fixtures do not establish target IOD/payload validity.", "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} metadata witnesses; all {len(results)} whole-IOD differences documented")


if __name__ == "__main__":
    main()
