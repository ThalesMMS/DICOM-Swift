#!/usr/bin/env python3
"""Independently verify XCTest writer artifacts using test-only pydicom 3.0.1."""

import argparse
import hashlib
import json
import struct
from pathlib import Path

import pydicom


def verify(directory):
    evidence = []
    for name, uid in [("modern-le", "1.2.840.10008.1.2.1"), ("modern-be", "1.2.840.10008.1.2.2")]:
        path = directory / (name + ".dcm")
        ds = pydicom.dcmread(path)
        assert str(ds.file_meta.TransferSyntaxUID) == uid
        assert ds[0x77771001].VR == "SV"
        assert list(ds[0x77771001].value) == [-(1 << 63), -1, (1 << 63) - 1]
        assert ds[0x77771002].VR == "UV"
        assert list(ds[0x77771002].value) == [0, (1 << 64) - 1]
        assert ds[0x77771003].VR == "UC"
        assert list(ds[0x77771003].value) == ["first", "", "last"]
        evidence.append(record(path))
    for vr in ["LT", "ST", "UT"]:
        path = directory / f"text-{vr}.dcm"
        ds = pydicom.dcmread(path)
        assert ds[0x77771001].VR == vr
        assert ds[0x77771001].value == "  first\\second\nthird"
        assert ds[0x77771001].VM == 1
        evidence.append(record(path))
    path = directory / "nested-charset.dcm"
    ds = pydicom.dcmread(path)
    assert str(ds.SpecificCharacterSet) == "ISO_IR 100"
    assert str(ds.PatientName) == "García"
    item = ds[0x00081032].value[0]
    assert str(item.SpecificCharacterSet) == "ISO_IR 192"
    assert item.CodeMeaning == "García"
    evidence.append(record(path))
    path = directory / "context-implicit.dcm"
    ds = pydicom.dcmread(path)
    assert ds.PixelPaddingValue == -1024
    assert ds[0x00189810].value == -3
    items = ds[0x00081032].value
    assert items[0].PixelPaddingValue == -9
    assert items[1].PixelPaddingValue == 65000
    evidence.append(record(path))
    for name in ["lut-le", "lut-be"]:
        path = directory / (name + ".dcm")
        ds = pydicom.dcmread(path)
        assert ds[0x00283002].VR == "SS"
        assert list(ds[0x00283002].value) == [65535, -1, 16]
        evidence.append(record(path))
    path = directory / "lut-implicit.dcm"
    ds = pydicom.dcmread(path)
    raw = ds.get_item(0x00283002, keep_deferred=True)
    assert raw.is_implicit_VR and raw.is_little_endian
    # PS3.3 C.11.1.1.1 and PS3.5 A.1: first and third words are
    # unsigned even when the second word selects SS for the descriptor.
    assert struct.unpack("<HhH", raw.value) == (65535, -1, 16)
    observed = list(ds[0x00283002].value)
    assert observed in ([65535, -1, 16], [-1, -1, 16])
    result = record(path)
    result["verification"] = "pydicom raw element plus independent struct HhH"
    result["pydicom_semantic_values"] = observed
    result["pydicom_semantic_agreement"] = observed == [65535, -1, 16]
    result["normative_reference"] = "https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_C.11.html"
    result["normative_edition_observed"] = "2026c"
    evidence.append(result)
    return {"issue": 2320, "oracle": "pydicom and Python struct", "version": pydicom.__version__, "files": evidence}


def record(path):
    return {"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "state": "passed"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    report = verify(args.directory)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Independent verification passed for {len(report['files'])} writer artifacts; see report for oracle limitations")
