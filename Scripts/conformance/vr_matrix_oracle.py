#!/usr/bin/env python3
"""Read all 34 VR writer fixtures independently with test-only pydicom 3.0.1."""

import argparse
import hashlib
import json
from pathlib import Path
import struct

import pydicom
from pydicom.datadict import add_private_dict_entries


VRS = "AE AS AT CS DA DS DT FD FL IS LO LT OB OD OF OL OV OW PN SH SL SQ SS ST SV TM UC UI UL UN UR US UT UV".split()
SYNTAXES = ["1.2.840.10008.1.2", "1.2.840.10008.1.2.1", "1.2.840.10008.1.2.2", "1.2.840.10008.1.2.1.99"]


def require(condition, context):
    if not condition:
        raise ValueError(context)


def verify(directory):
    require(pydicom.__version__ == "3.0.1", "This oracle requires pydicom 3.0.1")
    # Test-only private schema; pydicom still performs independent header, charset,
    # sequence, endian and deflate parsing. No production dictionary is imported.
    add_private_dict_entries("ISIS VR MATRIX", {
        0x77771000 + index: (vr, "1-n", "Synthetic " + vr, "")
        for index, vr in enumerate(VRS)
    })
    records = []
    for uid in SYNTAXES:
        endian = ">" if uid.endswith(".2.2") else "<"
        path = directory / f"all-vr-{uid}.dcm"
        ds = pydicom.dcmread(path)
        require(str(ds.file_meta.TransferSyntaxUID) == uid, (uid, "Transfer Syntax UID"))
        elements = {vr: ds[0x77771000 + index] for index, vr in enumerate(VRS)}
        require(all(element.VR == vr for vr, element in elements.items()), (uid, "VR matrix"))
        require(list(elements["AE"].value) == ["SOURCE", "DESTINATION"], (uid, "AE"))
        require(elements["AS"].value == "018Y", (uid, "AS"))
        require(list(elements["AT"].value) == [0x00100010, 0x00280103], (uid, "AT"))
        require(list(elements["CS"].value) == ["ORIGINAL", "PRIMARY"], (uid, "CS"))
        require(elements["DA"].value == "20260908", (uid, "DA"))
        require([value.original_string for value in elements["DS"].value] == ["1.23456789012345", "-1.23456789E-123"],
                (uid, "DS"))
        require(elements["DT"].value == "20260908010203.123456-0300", (uid, "DT"))
        require(list(elements["FD"].value) == [-1.25, 1e200], (uid, "FD"))
        require(list(elements["FL"].value) == [-1.25, 65536], (uid, "FL"))
        require(list(elements["IS"].value) == [-(1 << 31), (1 << 31) - 1], (uid, "IS"))
        require(list(elements["LO"].value) == ["García", "", "漢字"], (uid, "LO"))
        require(elements["LT"].value == "  first\\second\r\nthird", (uid, "LT"))
        require(elements["OB"].value == bytes([1, 128, 255, 0]), (uid, "OB"))
        require(struct.unpack(endian + "dd", elements["OD"].value) == (-1.25, 1e200), (uid, "OD"))
        require(struct.unpack(endian + "ff", elements["OF"].value) == (-1.25, 65536), (uid, "OF"))
        require(struct.unpack(endian + "II", elements["OL"].value) == (0, (1 << 32) - 1), (uid, "OL"))
        require(struct.unpack(endian + "Q", elements["OV"].value) == (0x0102030405060708,), (uid, "OV"))
        require(struct.unpack(endian + "HH", elements["OW"].value) == (0x1234, 0xABCD), (uid, "OW"))
        require([str(value) for value in elements["PN"].value] == ["Yamada^Taro=山田^太郎=ヤマダ^タロウ", "García^José"],
                (uid, "PN"))
        require(elements["SH"].value == "Résumé", (uid, "SH"))
        require(list(elements["SL"].value) == [-(1 << 31), (1 << 31) - 1], (uid, "SL"))
        require(elements["SQ"].value[0].CodeMeaning == "García", (uid, "SQ"))
        require(list(elements["SS"].value) == [-(1 << 15), (1 << 15) - 1], (uid, "SS"))
        require(elements["ST"].value == "  first\\second", (uid, "ST"))
        require(list(elements["SV"].value) == [-(1 << 63), -1, (1 << 63) - 1], (uid, "SV"))
        require(elements["TM"].value == "010203.123456", (uid, "TM"))
        require(list(elements["UC"].value) == ["漢字", "", "Résumé"], (uid, "UC"))
        require(list(elements["UI"].value) == ["2.25.23201", "2.25.23202"], (uid, "UI"))
        require(list(elements["UL"].value) == [0, (1 << 32) - 1], (uid, "UL"))
        require(elements["UN"].value == bytes([255, 254, 253, 252]), (uid, "UN"))
        require(elements["UR"].value == "https://example.invalid/a%20b", (uid, "UR"))
        require(list(elements["US"].value) == [0, (1 << 16) - 1], (uid, "US"))
        require(elements["UT"].value == "  first\\second\r\nthird", (uid, "UT"))
        require(list(elements["UV"].value) == [0, (1 << 64) - 1], (uid, "UV"))
        records.append(record(path))
        path = directory / f"empty-vr-{uid}.dcm"
        ds = pydicom.dcmread(path)
        require(str(ds.file_meta.TransferSyntaxUID) == uid, (uid, "Transfer Syntax UID"))
        for index, vr in enumerate(VRS):
            element = ds[0x77771000 + index]
            require(element.VR == vr, (uid, vr, element.VR))
            require(element.is_empty, (uid, vr, element))
        records.append(record(path))
    return {"issue": 2320, "oracle": "pydicom and Python struct", "version": pydicom.__version__,
            "standard_vrs": VRS, "transfer_syntaxes": SYNTAXES, "files": records}


def record(path):
    return {"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "state": "passed"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    args.report.write_text(json.dumps(verify(args.directory), indent=2) + "\n")
    print("Independent verification passed: 34 VRs, 4 syntaxes, populated and empty values")
