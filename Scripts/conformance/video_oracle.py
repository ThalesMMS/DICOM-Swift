#!/usr/bin/env python3
"""Independent Video IOD envelope and codec witnesses (PS3.3 2026c).

ffprobe is test-only. Raw elementary H.264/HEVC has no packet timestamps;
its decoded output order is compared to engine PTS order, not to fabricated clocks.
"""
import argparse
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path
import subprocess
import tempfile

import pydicom
from pydicom.encaps import generate_fragments
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require
from registration_oracle import FACTS as COMMON_FACTS

CASES = {
    "video-endoscopic-h264-pframes", "video-photographic-h264-bframes", "video-microscopic-hevc",
    "video-endoscopic-mpeg2", "video-fragmented-h264", "video-cine-full-module", "video-frame-extraction",
    "video-modality-wrong", "video-frame-count-mismatch", "video-frame-time-vector-length",
    "video-dimensions-mismatch",
    "video-lossy-flag-missing", "video-forbidden-module-present", "video-timeline-open-gop",
    "video-specimen-es", "video-specimen-gm", "video-specimen-xc",
    "video-frame-extraction-microscopic", "video-frame-extraction-photographic",
}
# Every exception is matched by module, tag path and error code, never by substring.
FALSE_POSITIVES = []
INDEPENDENT_ERRORS = {"video-lossy-flag-missing": [("VL Image", "(0028,2110)", "TagMissing")]}
GAPS = {
    "video-dimensions-mismatch": "The independent IOD validator does not compare Rows/Columns with the stream header; ffprobe supplies the actual dimensions.",
    "video-modality-wrong": "The independent IOD validator does not enforce the video Modality content constraint.",
    "video-frame-count-mismatch": "The independent IOD validator does not inspect codec picture counts.",
    "video-frame-time-vector-length": "The independent IOD validator does not compare vector length with Number of Frames.",
    "video-forbidden-module-present": "The independent IOD validator does not apply the video forbidden-module content constraint.",
}
for suffix in ("microscopic", "photographic"):
    for name in ("video-modality-wrong", "video-frame-count-mismatch", "video-dimensions-mismatch",
                 "video-frame-time-vector-length", "video-lossy-flag-missing", "video-forbidden-module-present"):
        CASES.add(name + "-" + suffix)
        if name in GAPS:
            GAPS[name + "-" + suffix] = GAPS[name]
        if name in INDEPENDENT_ERRORS:
            INDEPENDENT_ERRORS[name + "-" + suffix] = INDEPENDENT_ERRORS[name]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--ffprobe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Changed oracle versions")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names)), log_level=logging.CRITICAL)
    paths = sorted(args.corpus.glob("*.dcm"))
    require({path.stem for path in paths} == CASES, "Changed corpus case set")
    records = []
    for path in paths:
        name = path.stem
        expected = json.loads(path.with_suffix(".json").read_text())
        ds = pydicom.dcmread(path)
        require(str(ds.SOPClassUID) == expected["sopClass"], "Changed SOP Class")
        fragments = list(generate_fragments(ds.PixelData))
        require(len(fragments) >= 2, "Missing encapsulated stream")
        stream = b"".join(fragments[1:])
        with tempfile.NamedTemporaryFile(suffix={"h264": ".h264", "hevc": ".hevc", "mpeg2": ".m2v"}[expected["codec"]]) as encoded:
            encoded.write(stream)
            encoded.flush()
            probe = subprocess.run([str(args.ffprobe), "-v", "error", "-show_frames", "-show_streams", "-of", "json", encoded.name],
                                   check=True, capture_output=True, text=True, timeout=30)
        facts = json.loads(probe.stdout)
        frames = [frame for frame in facts["frames"] if frame.get("media_type") == "video"]
        info = facts["streams"][0]
        require(len(frames) == expected["frameCount"], f"Codec frame count disagreement: {name}")
        require(info["width"] == expected["width"] and info["height"] == expected["height"], f"Resolution disagreement: {name}")
        if expected["profile"] != "unknown":
            require(info["profile"] == expected["profile"], f"Profile disagreement: {name}: {info['profile']}")
        if name.startswith("video-dimensions-mismatch"):
            require(ds.Rows != info["height"], "Changed dimension contradiction witness")
        order = expected["presentationOrder"]
        if min(order) >= 0:
            permutation = sorted(range(len(order)), key=lambda index: order[index])
            require([expected["sliceTypes"][index] for index in permutation] == [frame["pict_type"] for frame in frames],
                    f"Presentation slice-type disagreement: {name}")
            require(sorted(range(len(order)), key=lambda index: expected["pts"][index]) == permutation, f"PTS order disagreement: {name}")
            positions = [int(frame["pkt_pos"]) for frame in frames]
            require(len(set(positions)) == len(positions), f"Ambiguous frame packet positions: {name}")
            decode_indexes = {position: index for index, position in enumerate(sorted(positions))}
            require([decode_indexes[position] for position in positions] == permutation,
                    f"Decode/presentation order disagreement: {name}")
            if all("best_effort_timestamp" in frame for frame in frames):
                timestamps = [frame["best_effort_timestamp"] for frame in frames]
                require(timestamps == sorted(timestamps) and len(set(timestamps)) == len(timestamps),
                        f"Independent PTS order disagreement: {name}")
        else:
            require(name == "video-timeline-open-gop" and expected.get("temporalReadRefusal") == "openGOPDependencies", "Unexplained unavailable order")
        if expected["codec"] == "mpeg2":
            # Independent picture-header witness, on the pydicom-extracted bytes.
            positions = [index for index in range(len(stream) - 5) if stream[index:index + 4] == b"\x00\x00\x01\x00"]
            references = [int.from_bytes(stream[index + 4:index + 6], "big") >> 6 for index in positions]
            require(references == expected["temporalReferences"], f"MPEG-2 temporal-reference disagreement: {name}")
        result = validator.validate(path)[str(path)]
        all_errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items() for tag, error in tags.items())
        false_positives = [error for error in all_errors if error in FALSE_POSITIVES]
        errors = [error for error in all_errors if error not in false_positives]
        require(errors == sorted(INDEPENDENT_ERRORS.get(name, [])), f"Changed independent errors for {name}: {errors}")
        case_facts = COMMON_FACTS + expected["facts"]
        command = subprocess.run([str(args.binary), "validate", str(path), "--composed", "--format", "json"] +
            [flag for fact in case_facts for flag in ("--fact", fact)], capture_output=True, text=True, timeout=30)
        report = json.loads(command.stdout)
        require(command.returncode == expected["exit"], f"CLI disagreement {name}: {report}")
        if expected["exit"] == 0:
            require(all(value == "passed" for layer, value in report["outcomes"].items() if layer != "operation"),
                    f"Changed passed layers: {name}")
        agreement = (expected["outcome"] == "failed") == bool(errors)
        require(agreement or name in GAPS, f"Unexplained envelope disagreement: {name}")
        require(not agreement or name not in GAPS, f"Stale gap: {name}")
        records.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **expected, "facts": case_facts,
            "independentErrors": errors, "falsePositives": false_positives, "gap": GAPS.get(name),
            "ffprobe": info, "timestampWitnessAvailable": all("best_effort_timestamp" in frame for frame in frames)})
    args.output.write_text(json.dumps({"versions": versions, "commonFacts": COMMON_FACTS, "cases": records,
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}}, indent=2) + "\n")
    agreements = sum(record["gap"] is None for record in records)
    print(f"PASS: {len(records)} Video cases, {agreements} independent agreements after the documented false positives, {len(records) - agreements} documented gaps")


if __name__ == "__main__":
    main()
