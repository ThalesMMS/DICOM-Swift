#!/usr/bin/env python3
"""Witness SR icon bytes and native decoded samples, retaining IOD nesting and excess-padding gaps."""

import argparse
import copy
import hashlib
import importlib.metadata
import json
import logging
import warnings
from pathlib import Path

from pydicom import dcmread
from pydicom.pixels import pixel_array, apply_color_lut
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

POSITIVE = {"mono8-valid": [[0, 17], [129, 255]], "mono1-valid": [[1, 0, 1, 0, 1, 0, 1, 0, 1]],
            "mono8-odd-valid": [[7, 19, 201]], "palette-valid": [[0, 1], [1, 0]]}
MUTATIONS = {
    "rows-oversize": {0x00280010: 129}, "columns-zero": {0x00280011: 0},
    "rgb-prohibited": {0x00280004: "RGB"}, "signed-prohibited": {0x00280103: 1},
    "bits-prohibited": {0x00280100: 16}, "stored-exceeds": {0x00280101: 8, 0x00280102: 7},
    "highbit-wrong": {0x00280102: 6}, "planar-prohibited": {0x00280006: 0},
    "aspect-prohibited": {0x00280034: [1, 1]}, "pixels-missing": {0x7FE00010: None},
    "pixels-empty": {0x7FE00010: b""}, "pixels-short": {0x7FE00010: bytes([0, 17])},
    "pixels-long": {0x7FE00010: bytes([0, 17, 129, 255, 1, 2])},
    "palette-data-short": {0x00281202: b""}, "palette-descriptor-mismatch": {0x00281102: [2, 1, 8]},
    "palette-depth-invalid": {0x00281101: [2, 0, 12]}, "palette-data-missing": {0x00281202: None},
}
PIXEL_FAILED = {"rows-oversize", "columns-zero", "bits-prohibited", "pixels-empty", "pixels-short", "pixels-long",
                "palette-data-short", "palette-descriptor-mismatch", "palette-depth-invalid"}
PIXEL_INCOMPLETE = {"pixels-missing", "palette-data-missing"}


def witness(ds, case):
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88.33" and
            ds.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1", "Unexpected source class or transfer syntax")
    require(len(ds.ContentSequence) == 1 and ds.ContentSequence[0].ValueType == "IMAGE", "Wrong content shape")
    pairs = ds.ContentSequence[0].ReferencedSOPSequence
    require(len(pairs) == 1 and len(pairs[0].IconImageSequence) == 1, "Wrong icon nesting/cardinality")
    require(pairs[0].ReferencedSOPClassUID == "1.2.840.10008.5.1.4.1.1.2.1" and
            pairs[0].ReferencedSOPInstanceUID == "2.25.23212003", "Wrong referenced image identity")
    icon = pairs[0].IconImageSequence[0]
    expected = {0x00280002: 1, 0x00280004: "MONOCHROME2", 0x00280010: 2, 0x00280011: 2,
                0x00280100: 8, 0x00280101: 8, 0x00280102: 7, 0x00280103: 0, 0x7FE00010: bytes([0, 17, 129, 255])}
    if case in {"mono1-valid", "stored-exceeds"}:
        expected.update({0x00280010: 1, 0x00280011: 9, 0x00280100: 1, 0x00280101: 1, 0x00280102: 0,
                         0x7FE00010: bytes([0x55, 0x01])})
    if case == "mono8-odd-valid":
        expected.update({0x00280010: 1, 0x00280011: 3, 0x7FE00010: bytes([7, 19, 201, 0])})
    if case.startswith("palette-"):
        expected.update({0x00280004: "PALETTE COLOR", 0x7FE00010: bytes([0, 1, 1, 0])})
        for channel in range(1, 4):
            expected[0x00281100 + channel] = [2, 0, 8]
            expected[0x00281200 + channel] = bytes([0, 255])
    expected.update(MUTATIONS.get(case, {}))
    require(set(icon.keys()) == {tag for tag, value in expected.items() if value is not None}, "Unexpected icon tags")
    for tag, value in expected.items():
        if value is None:
            continue
        element = icon[tag]
        vr = "OB" if tag == 0x7FE00010 else "OW" if tag in range(0x00281201, 0x00281204) else \
             "IS" if tag == 0x00280034 else "CS" if tag == 0x00280004 else "US"
        actual = list(element.value) if isinstance(value, list) else element.value
        if isinstance(value, bytes) and element.is_empty:
            actual = b""  # pydicom represents a present, zero-length binary value as None.
        require(element.VR == vr and actual == value, f"Wrong icon witness: {case}/{tag:08X}")
    return icon


def decode(ds, icon, case):
    if case not in POSITIVE and case not in {"pixels-short", "pixels-long"}:
        return None
    icon = copy.deepcopy(icon)
    icon.file_meta = copy.deepcopy(ds.file_meta)
    result = {}
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        try:
            array = pixel_array(icon, allow_excess_frames=False)
        except ValueError as error:
            require(case == "pixels-short" and "(2 vs 4 bytes)" in str(error), "Unexpected independent decoder error")
            result["error"] = str(error)
        else:
            require(case != "pixels-short", "Truncated native icon unexpectedly decoded")
            require(array.dtype.name == "uint8", "Unexpected native pixel precision")
            samples = array.tolist()
            require(samples == POSITIVE.get(case, POSITIVE["mono8-valid"]), "Decoded samples differ")
            result.update({"samples": samples, "shape": list(array.shape), "dtype": array.dtype.name})
            if case == "palette-valid":
                rgb = apply_color_lut(array, icon)
                require(rgb.tolist() == [[[0, 0, 0], [255, 255, 255]], [[255, 255, 255], [0, 0, 0]]], "Wrong palette colors")
                result["paletteRGB"] = rgb.tolist()
        messages = [str(w.message) for w in caught]
        require(messages == (["The pixel data is 6 bytes long, which indicates it contains 2 bytes of excess padding to be removed"]
                             if case == "pixels-long" else []), "Changed independent decoder warnings")
        result["warnings"] = messages
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    required_versions = VERSIONS | {"numpy": "2.5.3"}
    versions = {name: importlib.metadata.version(name) for name in required_versions}
    require(versions == required_versions, "Unexpected oracle dependency versions")
    require(args.standard_json.parent.name == "2026c", "DICOM 2026c cache required")
    cases = set(POSITIVE) | set(MUTATIONS)
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
        ds = dcmread(path)
        icon = witness(ds, case)
        expected = "passed" if case in POSITIVE else "failed"
        native = "failed" if case in PIXEL_FAILED else "incomplete" if case in PIXEL_INCOMPLETE else "passed"
        metadata = path.with_suffix(".json")
        require(json.loads(metadata.read_text()) == {"icon": expected, "structure": "passed",
                "metadataPixelData": "omitted", "nativePixels": native}, "Unexpected producer evidence")
        result = validator.validate(path)[str(path)]
        errors = [{"module": module, "tag": str(tag), "code": error.code.name}
                  for module, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        require(errors == [{"module": "SR Document Content", "tag": "(0040,A730) / (0008,1199) / (0088,0200)",
                            "code": "TagUnexpected"}] and result.errors == 1 and result.status.name == "Failed",
                "Changed independent IOD diagnostics: " + case)
        results.append({"case": case, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "producerEvidenceSHA256": hashlib.sha256(metadata.read_bytes()).hexdigest(),
                        "ownIconOutcome": expected, "independentIODOutcome": result.status.name,
                        "independentErrors": errors, "independentDecode": decode(ds, icon, case),
                        "diagnosticLimitation": "IOD oracle loses icon nesting from the included composite macro; its unexpected-tag error does not test icon metadata or payloads."})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes, "cases": results,
              "scope": "SR native icon metadata, value lengths and palette consistency; four exact independent decoded baselines and two malformed native lengths; no encapsulated/ICC/extrema/full IOD qualification",
              "nativeDecoderDivergence": "pydicom removes excess native bytes with a warning; this validator fails the encoded value-length mismatch."}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} byte witnesses, 4 exact decoded baselines, 2 native-length decoder checks; IOD nesting gaps retained")


if __name__ == "__main__":
    main()
