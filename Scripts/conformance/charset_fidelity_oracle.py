#!/usr/bin/env python3
"""Read synthetic XCTest charset artifacts with test-only pydicom/Python codecs."""

import argparse
import hashlib
import json
import warnings
from pathlib import Path

import pydicom


CHARACTERS = {
    100: "é", 101: "Ą", 109: "Ħ", 110: "Ā", 127: "ش", 126: "Ω", 138: "ש", 148: "Ğ",
    166: "ท", 159: "丂", 144: "Ж", 203: "€", 87: "山", 149: "홍", 58: "中", 13: "ﾔ",
}
SYNTAXES = ["1.2.840.10008.1.2", "1.2.840.10008.1.2.1", "1.2.840.10008.1.2.2", "1.2.840.10008.1.2.1.99"]


def verify(directory):
    results = []
    for registration, character in CHARACTERS.items():
        for syntax in SYNTAXES:
            path = directory / f"ir-{registration}-{syntax}.dcm"
            with warnings.catch_warnings(record=True) as caught:
                warnings.simplefilter("always")
                ds = pydicom.dcmread(path)
                assert str(ds.file_meta.TransferSyntaxUID) == syntax
                assert list(ds.SpecificCharacterSet) == ["", f"ISO 2022 IR {registration}"]
                if registration in (203, 58):
                    # Pydicom 3.0.1 lacks IR 203 and retains the IR 58 escape
                    # in decoded strings. Verify exact designations and character
                    # bytes independently, without claiming semantic agreement.
                    pn = ds.get_item(0x00100010, keep_deferred=True).value.rstrip(b" ")
                    st = ds.get_item(0x00082111, keep_deferred=True).value.rstrip(b" ")
                    codec, escape = ("iso8859_15", b"\x1b-b") if registration == 203 else ("gb2312", b"\x1b$)A")
                    encoded = escape + character.encode(codec)
                    assert pn == b"NAME=" + encoded + b"^" + encoded
                    assert st == encoded + b"\r\n" + encoded
                    verification = f"pydicom raw elements and Python {codec}; pydicom IR {registration} semantic limitation"
                    if registration == 58:
                        assert str(ds.PatientName) == "NAME=\x1b$)A中^\x1b$)A中"
                        assert ds.DerivationDescription == "\x1b$)A中\r\n\x1b$)A中"
                else:
                    assert str(ds.PatientName) == "NAME=" + character + "^" + character, path.name
                    assert ds.DerivationDescription == character + "\r\n" + character, path.name
                    verification = "pydicom semantic decode"
                    assert not caught, [str(w.message) for w in caught]
            results.append(record(path, verification))
    path = directory / "mixed-initial-g1-1.2.840.10008.1.2.1.dcm"
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        ds = pydicom.dcmread(path)
        assert [str(value) for value in ds.OperatorsName] == ["García=Ω^é", "Renée=Ω"]
        assert ds.DerivationDescription == "Ω\r\né\tΩ"
    results.append(record(path, "pydicom semantic decode"))
    path = directory / "nested-1.2.840.10008.1.2.1.dcm"
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        ds = pydicom.dcmread(path)
        assert [item.CodeMeaning for item in ds.ProcedureCodeSequence] == ["Ω", "山", "Ω"]
    results.append(record(path, "pydicom semantic decode"))
    return {"issue": 2320, "oracle": "pydicom and Python standard codecs", "version": pydicom.__version__,
            "normative_edition_observed": "2026c",
            "normative_reference": "https://dicom.nema.org/medical/dicom/current/output/chtml/part03/sect_C.12.html",
            "files": results}


def record(path, verification):
    return {"name": path.name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "state": "passed", "verification": verification}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--report", required=True, type=Path)
    args = parser.parse_args()
    report = verify(args.directory)
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Independent verification passed for {len(report['files'])} charset artifacts; see report for IR 203 and IR 58 limitations")
