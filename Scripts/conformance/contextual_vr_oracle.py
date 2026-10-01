#!/usr/bin/env python3
"""Check contextual VR fixtures with independent pydicom parsing and Decimal/struct rules."""

import argparse
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import struct

import pydicom
from pydicom.datadict import add_private_dict_entries


SYNTAXES = ["1.2.840.10008.1.2", "1.2.840.10008.1.2.1", "1.2.840.10008.1.2.2", "1.2.840.10008.1.2.1.99"]
FIRST_MAPPED_VALUES = [-1024, 65000, -1, 65000, 65000, -1, 65000, 65000, 65000, -1, -1, 65000, 65000, -1]


def record(path):
    return {"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "state": "passed"}


def verify(directory):
    records = []
    # Separate test schema: private resolution must use each item's reservations,
    # including creator relocation and a child with no creator at all.
    add_private_dict_entries("ISIS_NUM", {0x77771001: ("US", "1", "Synthetic number", ""),
                                          0x77771099: ("SQ", "1", "Synthetic items", "")})
    add_private_dict_entries("ISIS_TEXT", {0x77771001: ("LO", "1", "Synthetic text", "")})
    for syntax in SYNTAXES:
        path = directory / f"private-{syntax}.dcm"
        data_set = pydicom.dcmread(path)
        assert str(data_set.file_meta.TransferSyntaxUID) == syntax
        assert data_set[0x77771101].VR == "US" and data_set[0x77771101].value == 123
        assert data_set[0x77771201].VR == "LO" and data_set[0x77771201].value == "root"
        items = data_set[0x77771199].value
        assert len(items) == 3
        assert items[0][0x77771101].VR == "LO" and items[0][0x77771101].value == "item"
        assert items[1][0x77771101].VR == "UN" and items[1][0x77771101].value == bytes([42, 0])
        assert items[2][0x7777FE01].VR == "US" and items[2][0x7777FE01].value == 321
        result = record(path)
        result.update(verification="pydicom private creator/block/item resolution", pydicom_semantic_agreement=True)
        records.append(result)
    for index, first_mapped in enumerate(FIRST_MAPPED_VALUES):
        for syntax in SYNTAXES:
            path = directory / f"voi-{index}-{syntax}.dcm"
            data_set = pydicom.dcmread(path)
            assert str(data_set.file_meta.TransferSyntaxUID) == syntax
            bits = int(data_set.BitsStored)
            signed = int(data_set.PixelRepresentation) == 1
            lower = -(1 << (bits - 1)) if signed else 0
            upper = (1 << (bits - int(signed))) - 1
            slope = Decimal(data_set.RescaleSlope.original_string)
            intercept = Decimal(data_set.RescaleIntercept.original_string)
            output_minimum = min(Decimal(lower) * slope + intercept, Decimal(upper) * slope + intercept)
            expected_vr = "SS" if output_minimum < 0 else "US"
            item = data_set.VOILUTSequence[0]
            raw = item.get_item(0x00283002, keep_deferred=True)
            assert raw.is_implicit_VR == (syntax == SYNTAXES[0])
            if not raw.is_implicit_VR:
                assert raw.VR == expected_vr
            endian = "<" if raw.is_little_endian else ">"
            actual = struct.unpack(endian + ("HhH" if expected_vr == "SS" else "HHH"), raw.value)
            assert actual == (65535, first_mapped, 16), (path.name, actual)
            # Access the semantic value only after retaining independently parsed
            # bytes: pydicom 3.0.1 may infer SS from stored pixels instead of the
            # post-rescale VOI input, and may sign-extend the first descriptor word.
            observed = list(item[0x00283002].value)
            result = record(path)
            result.update(expected_vr=expected_vr, expected_values=list(actual),
                          pydicom_vr=item[0x00283002].VR, pydicom_values=observed,
                          pydicom_semantic_agreement=(observed == list(actual) and item[0x00283002].VR == expected_vr),
                          verification="independent parsed raw bytes, Decimal output range and struct words")
            records.append(result)
    for bits in [8, 16, 32, 64]:
        for syntax in SYNTAXES:
            path = directory / f"waveform-{bits}-{syntax}.dcm"
            data_set = pydicom.dcmread(path)
            assert str(data_set.file_meta.TransferSyntaxUID) == syntax
            assert data_set.WaveformBitsAllocated == bits
            expected_vr = "OB" if bits == 8 and syntax != SYNTAXES[0] else "OW"
            channel = data_set.ChannelDefinitionSequence[0]
            for item, tag in [(channel, 0x54000110), (channel, 0x54000112),
                              (data_set, 0x5400100A), (data_set, 0x54001010)]:
                element = item[tag]
                assert element.VR == expected_vr, (path.name, tag, element.VR)
                endian = ">" if syntax == SYNTAXES[2] else "<"
                expected_words = tuple(0x0100 + word for word in range(1, max(1, bits // 16) + 1))
                assert struct.unpack(endian + "H" * len(expected_words), element.value) == expected_words
            result = record(path)
            result.update(verification="pydicom VR and independent struct sample words", pydicom_semantic_agreement=True)
            records.append(result)
    return {"issue": 2320, "oracle": "pydicom plus Python Decimal and struct", "version": pydicom.__version__,
            "scope": "VOI input sign after rescale; waveform VR and item inheritance; four dataset syntaxes",
            "limits": "Raw checks remain authoritative where the external reader's semantic inference disagrees; see each record.",
            "normative_sources": [
                "https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_C.11.2.html",
                "https://dicom.nema.org/medical/dicom/current/output/chtml/part05/chapter_A.html"],
            "files": records}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    result = verify(args.directory)
    args.report.write_text(json.dumps(result, indent=2) + "\n")
    agreements = sum(item["pydicom_semantic_agreement"] for item in result["files"])
    print(f"Verified {len(result['files'])} contextual artifacts; {agreements} semantic agreements; all raw checks passed")
