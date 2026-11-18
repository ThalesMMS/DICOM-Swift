#!/usr/bin/env python3
"""Independent check of `dicomtool deidentify` against PS3.15 Table E.1-1 with pydicom 3.0.2.

Table E.1-1 is parsed here from the DocBook source (never from the toolkit's JSON). A synthetic cohort of
two instances that reference each other carries sentinel identifiers in patient/study attributes, dates,
private elements, sequences, structured content and an overlay. `dicomtool deidentify` runs the Basic
Profile and each retain/clean option; pydicom then checks, attribute by attribute present in the input,
that the output honours the code the table assigns (X absent, Z empty, D non-empty and changed, U a fresh
UID, K unchanged), that every UID replacement is consistent across the cohort and inside references, that
no sentinel survives anywhere in the bytes and that the PS3.15 markers are recorded. Only counts are kept.
"""
import argparse
import importlib.metadata
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

import pydicom
from pydicom.dataset import Dataset, FileMetaDataset
from pydicom.sequence import Sequence
from pydicom.uid import ExplicitVRLittleEndian, generate_uid
from image_iod_oracle import require

NS = {"d": "http://docbook.org/ns/docbook"}
OPTION_COLUMNS = ["retainSafePrivate", "retainUIDs", "retainDeviceIdentity", "retainInstitutionIdentity", "retainPatientCharacteristics",
                  "retainLongitudinalFullDates", "retainLongitudinalModifiedDates", "cleanDescriptors", "cleanStructuredContent", "cleanGraphics"]
# Sentinels that every profile must remove, plus the ones an option may legitimately retain.
ALWAYS_REMOVED = [b"SENTINEL^PATIENT", b"SENT-ID-77", b"SENTINEL-PRIVATE", b"SENTINEL OVERLAY", b"SENTINEL TEXT ITEM", b"SENTINEL^REFERRER"]
RETAINABLE = {b"SENTINEL STUDY DESC": "cleanDescriptors", b"SENTINEL HOSPITAL": "retainInstitutionIdentity", b"SERIAL-SENT-1": "retainDeviceIdentity"}


def text(element):
    return " ".join("".join(element.itertext()).split())


def load_table(part15):
    root = ET.parse(part15).getroot()
    table = next(t for t in root.iter("{http://docbook.org/ns/docbook}table") if t.get("label") == "E.1-1")
    rows = {}
    for row in table.findall(".//d:tbody/d:tr", NS):
        cells = [text(td) for td in row.findall("d:td", NS)]
        match = re.fullmatch(r"\(([0-9A-Fa-fx]{4}),([0-9A-Fa-fx]{4})\)", cells[1])
        if not match:
            continue
        key = (match.group(1) + match.group(2)).upper().replace("X", "x")
        rows[key] = {"basic": cells[4], "options": {c: v for c, v in zip(OPTION_COLUMNS, cells[5:]) if v}}
    return rows


def action_for(rows, tag, options):
    key = f"{tag.group:04X}{tag.element:04X}"
    row = rows.get(key)
    if row is None:
        for pattern, candidate in rows.items():
            if "x" in pattern and re.fullmatch(pattern.replace("x", "[0-9A-F]"), key):
                row = candidate
                break
    if row is None:
        return None
    applicable = [row["options"][o] for o in options if o in row["options"]]
    if "K" in applicable:
        return "K"
    if "C" in applicable:
        return "C"
    return row["basic"]


def make_instance(uid, referenced_uid, work):
    ds = Dataset()
    ds.SpecificCharacterSet = "ISO_IR 100"
    ds.SOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ds.SOPInstanceUID = uid
    ds.StudyInstanceUID = "2.25.23389001"
    ds.SeriesInstanceUID = "2.25.23389002"
    ds.FrameOfReferenceUID = "2.25.23389003"
    ds.PatientName = "SENTINEL^PATIENT"
    ds.PatientID = "SENT-ID-77"
    ds.PatientBirthDate = "19700215"
    ds.PatientSex = "M"
    ds.PatientAge = "054Y"
    ds.StudyDate = "20240115"
    ds.StudyTime = "101530"
    ds.SeriesDate = "20240115"
    ds.ContentDate = "20240115"
    ds.ContentTime = "101600"
    ds.AcquisitionDateTime = "20240115101530+0100"
    ds.ReferringPhysicianName = "SENTINEL^REFERRER"
    ds.InstitutionName = "SENTINEL HOSPITAL"
    ds.DeviceSerialNumber = "SERIAL-SENT-1"
    ds.StudyDescription = "SENTINEL STUDY DESC"
    ds.Modality = "OT"
    ds.ConversionType = "WSD"
    ds.StudyID = "ST-1"
    ds.SeriesNumber = "1"
    ds.InstanceNumber = "1"
    ds.AccessionNumber = "ACC-SENT"
    ds.Manufacturer = "Vendor"
    ds.BurnedInAnnotation = "NO"
    ref = Dataset()
    ref.ReferencedSOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    ref.ReferencedSOPInstanceUID = referenced_uid
    ds.ReferencedImageSequence = Sequence([ref])
    ds.add_new((0x0009, 0x0010), "LO", "SENTINEL CREATOR")
    ds.add_new((0x0009, 0x1001), "LO", "SENTINEL-PRIVATE")
    ds.add_new((0x7053, 0x0010), "LO", "Philips PET Private Group")
    ds.add_new((0x7053, 0x1000), "DS", "1.5")
    ds.add_new((0x6000, 0x0010), "US", 2)
    ds.add_new((0x6000, 0x0011), "US", 2)
    ds.add_new((0x6000, 0x0040), "CS", "G")
    ds.add_new((0x6000, 0x4000), "LT", "SENTINEL OVERLAY")
    ds.add_new((0x6000, 0x3000), "OW", b"\xff\x00")
    item = Dataset()
    item.RelationshipType = "CONTAINS"
    item.ValueType = "TEXT"
    item.TextValue = "SENTINEL TEXT ITEM"
    ds.ContentSequence = Sequence([item])
    ds.SamplesPerPixel = 1
    ds.PhotometricInterpretation = "MONOCHROME2"
    ds.Rows = 2
    ds.Columns = 2
    ds.BitsAllocated = 8
    ds.BitsStored = 8
    ds.HighBit = 7
    ds.PixelRepresentation = 0
    ds.PixelData = b"\x01\x02\x03\x04"
    ds.file_meta = FileMetaDataset()
    ds.file_meta.MediaStorageSOPClassUID = ds.SOPClassUID
    ds.file_meta.MediaStorageSOPInstanceUID = uid
    ds.file_meta.TransferSyntaxUID = ExplicitVRLittleEndian
    ds.is_little_endian = True
    ds.is_implicit_VR = False
    path = work / f"{uid}.dcm"
    ds.save_as(path, enforce_file_format=True)
    return path


def check_element(rows, options, original, output, path, uid_map):
    """One element of the input against the output per its table code; returns the code applied."""
    code = action_for(rows, original.tag, options)
    if code is None:
        return None
    present = original.tag in output
    if code == "X":
        require(not present, f"{path}{original.tag}: X but present")
    elif code == "K":
        require(present and output[original.tag].value == original.value, f"{path}{original.tag}: K but changed")
    elif code == "Z":
        require(present and output[original.tag].VM == 0, f"{path}{original.tag}: Z but not empty")
    elif code == "U":
        require(present and str(output[original.tag].value) != str(original.value), f"{path}{original.tag}: U but unchanged")
        uid_map.setdefault(str(original.value), set()).add(str(output[original.tag].value))
    elif code in ("D", "X/D", "Z/D", "X/Z/D"):
        if original.VR == "SQ":
            require(present and len(output[original.tag].value) == 0, f"{path}{original.tag}: D on a sequence leaves items")
        elif original.VR == "UI":
            require(present and str(output[original.tag].value) != str(original.value), f"{path}{original.tag}: D on a UID unchanged")
        else:
            require(present and output[original.tag].VM > 0 and output[original.tag].value != original.value, f"{path}{original.tag}: D but empty or unchanged")
    elif code == "X/Z":
        require(present and output[original.tag].VM == 0, f"{path}{original.tag}: X/Z but not empty")
    elif code == "X/Z/U*":
        require(present, f"{path}{original.tag}: X/Z/U* removed a sequence the toolkit rewrites")
    elif code == "C":
        if 0x6000 <= original.tag.group <= 0x601E:
            # Documented toolkit choice: overlay bitmaps are not inspected, Clean Graphics removes them.
            require(not present, f"{path}{original.tag}: C on an overlay should remove the bitmap")
        else:
            require(present, f"{path}{original.tag}: C but removed")
    return code


def check_dataset(rows, options, original, output, uid_map, path=""):
    counts = {}
    for element in original:
        if element.tag.group == 0x0002 or element.tag.element == 0:
            continue
        if element.tag.is_private:
            continue
        code = check_element(rows, options, element, output, path, uid_map)
        if code:
            counts[code] = counts.get(code, 0) + 1
        if element.VR == "SQ" and element.tag in output and code in ("K", "C", "X/Z/U*", "U"):
            for index, (item, out_item) in enumerate(zip(element.value, output[element.tag].value)):
                for k, v in check_dataset(rows, options, item, out_item, uid_map, f"{path}{element.tag}[{index}]/").items():
                    counts[k] = counts.get(k, 0) + v
    return counts


def run_case(binary, rows, inputs, options, work, case_name):
    out = work / case_name
    args = [str(binary), "deidentify", *map(str, inputs), "--output", str(out), "--date-shift=-30", "--report", str(work / f"{case_name}.json")]
    for option in options:
        args += ["--option", option]
    completed = subprocess.run(args, capture_output=True, timeout=600)
    require(completed.returncode == 0, f"{case_name}: dicomtool failed: {completed.stderr.decode(errors='replace')[:300]}")
    uid_map = {}
    totals = {}
    outputs = {}
    for source in inputs:
        original = pydicom.dcmread(source)
        produced = pydicom.dcmread(out / source.name)
        outputs[str(original.SOPInstanceUID)] = produced
        raw = (out / source.name).read_bytes()
        for sentinel in ALWAYS_REMOVED:
            require(sentinel not in raw, f"{case_name}: sentinel survived in {source.name}")
        for sentinel, option in RETAINABLE.items():
            require((sentinel in raw) == (option in options), f"{case_name}: {sentinel!r} retention differs from option {option}")
        for k, v in check_dataset(rows, options, original, produced, uid_map).items():
            totals[k] = totals.get(k, 0) + v
        private_kept = [e for e in produced if e.tag.is_private]
        if "retainSafePrivate" in options:
            require({(e.tag.group, e.tag.element) for e in private_kept} == {(0x7053, 0x0010), (0x7053, 0x1000)}, f"{case_name}: safe private set differs")
        else:
            require(not private_kept, f"{case_name}: private elements survived")
        require(produced.PatientIdentityRemoved == "YES", f"{case_name}: marker missing")
        codes = [item.CodeValue for item in produced.DeidentificationMethodCodeSequence]
        require(codes[0] == "113100" and len(codes) == 1 + len(options), f"{case_name}: method codes {codes}")
        require(produced.PixelData == original.PixelData, f"{case_name}: pixels changed")
    for original_uid, replacements in uid_map.items():
        require(len(replacements) == 1, f"{case_name}: {original_uid} mapped to several values")
    if "retainUIDs" not in options:
        uids = list(outputs)
        first, second = outputs[uids[0]], outputs[uids[1]]
        require(first.ReferencedImageSequence[0].ReferencedSOPInstanceUID == second.SOPInstanceUID, f"{case_name}: cross reference not coherent")
        require(second.ReferencedImageSequence[0].ReferencedSOPInstanceUID == first.SOPInstanceUID, f"{case_name}: cross reference not coherent")
        require(first.StudyInstanceUID == second.StudyInstanceUID != "2.25.23389001", f"{case_name}: study identity")
    if "retainLongitudinalModifiedDates" in options:
        require(str(outputs[uids[0]].StudyDate) == "20231216", f"{case_name}: date shift")
        require(str(outputs[uids[0]].AcquisitionDateTime) == "20231216101530+0100", f"{case_name}: datetime shift")
        require(outputs[uids[0]].LongitudinalTemporalInformationModified == "MODIFIED", f"{case_name}: temporal marker")
    return totals


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--part15", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    rows = load_table(args.part15)
    require(len(rows) >= 650, "Table E.1-1 incomplete")
    work = Path(tempfile.mkdtemp(prefix="isis-deid-oracle-"))
    try:
        inputs = [make_instance("2.25.23389011", "2.25.23389012", work), make_instance("2.25.23389012", "2.25.23389011", work)]
        cases = {"basic": [], "retainUIDs": ["retainUIDs"], "modifiedDates": ["retainLongitudinalModifiedDates"],
                 "fullDates": ["retainLongitudinalFullDates"], "safePrivate": ["retainSafePrivate"],
                 "characteristics": ["retainPatientCharacteristics", "retainDeviceIdentity", "retainInstitutionIdentity"],
                 "descriptors": ["cleanDescriptors"], "structured": ["cleanStructuredContent"], "graphics": ["cleanGraphics"]}
        results = {name: run_case(args.binary, rows, inputs, options, work, name) for name, options in cases.items()}
    finally:
        shutil.rmtree(work, ignore_errors=True)
    args.output.write_text(json.dumps({"pydicomVersion": version, "tableRows": len(rows), "cases": results}, indent=2, sort_keys=True) + "\n")
    checked = sum(sum(c.values()) for c in results.values())
    print(f"PASS: {len(results)} de-identification cases, {checked} attribute dispositions agree with PS3.15 Table E.1-1 parsed independently")


if __name__ == "__main__":
    main()
