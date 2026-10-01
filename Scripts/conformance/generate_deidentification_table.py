#!/usr/bin/env python3
"""Generate the versioned PS3.15 Annex E table used by DicomDeidentifier.

Reads the DocBook source of PS3.15 (Table E.1-1 Application Level Confidentiality Profile Attributes and
Table E.3.10-1 Safe Private Attributes) and writes DicomData's resource JSON. Every attribute row keeps its
basic-profile action code and the per-option codes verbatim (X, Z, D, U, K, C and the compound codes); the
JSON is the single source the toolkit consults, so a standard revision is a regeneration, not a code change.

    python3 generate_deidentification_table.py --part15 part15.xml --version 2026c --output ../../Sources/DicomData/Resources/DicomDeidentificationTable.json
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

NS = {"d": "http://docbook.org/ns/docbook"}
OPTION_COLUMNS = [
    "retainSafePrivate", "retainUIDs", "retainDeviceIdentity", "retainInstitutionIdentity",
    "retainPatientCharacteristics", "retainLongitudinalFullDates", "retainLongitudinalModifiedDates",
    "cleanDescriptors", "cleanStructuredContent", "cleanGraphics",
]
CODES = {"X", "Z", "D", "U", "K", "C", "X/Z", "X/D", "Z/D", "X/Z/D", "X/Z/U*"}


def text(element):
    return " ".join("".join(element.itertext()).split())


def table(root, label):
    for candidate in root.iter("{http://docbook.org/ns/docbook}table"):
        if candidate.get("label") == label:
            return candidate
    raise SystemExit(f"table {label} not found")


def rows(element):
    return [[text(td) for td in row.findall("d:td", NS)] for row in element.findall(".//d:tbody/d:tr", NS)]


def pattern(tag_text):
    match = re.fullmatch(r"\(([0-9A-Fa-fx]{4}),([0-9A-Fa-fx]{4})\)", tag_text)
    if not match:
        return None
    return (match.group(1) + match.group(2)).upper().replace("X", "x")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--part15", type=Path, required=True)
    parser.add_argument("--version", required=True, help="Standard edition, e.g. 2026c")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = ET.parse(args.part15).getroot()

    attributes = []
    e11 = table(root, "E.1-1")
    header = [text(th) for th in e11.find(".//d:thead", NS).iter("{http://docbook.org/ns/docbook}th")]
    if len(header) != 5 + len(OPTION_COLUMNS):
        raise SystemExit(f"E.1-1 has an unexpected header: {header!r}")
    for row in rows(e11):
        if len(row) != len(header):
            raise SystemExit(f"E.1-1 row has an unexpected column count: {row!r}")
        name, tag_text, retired, in_iod, basic = row[:5]
        options = {column: code for column, code in zip(OPTION_COLUMNS, row[5:]) if code}
        if basic not in CODES:
            raise SystemExit(f"E.1-1 row {name!r} has invalid basic action {basic!r}")
        if not all(code in {"K", "C"} for code in options.values()):
            raise SystemExit(f"E.1-1 row {name!r} has invalid option actions {options!r}")
        entry = {"name": name, "basic": basic, "retired": retired == "Y", "inStandardIOD": in_iod == "Y"}
        if options:
            entry["options"] = options
        tag_pattern = pattern(tag_text)
        if tag_pattern:
            entry["tag"] = tag_pattern
        elif "odd" in tag_text:
            entry["tag"] = "private"
        else:
            raise SystemExit(f"unrecognised tag {tag_text!r}")
        attributes.append(entry)

    safe_private = []
    for row in rows(table(root, "E.3.10-1")):
        element, creator, vr, vm, meaning = row[:5]
        tag_pattern = pattern(element)
        if not tag_pattern or tag_pattern[4:6] != "xx":
            raise SystemExit(f"E.3.10-1 row has an invalid private element: {element!r}")
        safe_private.append({"element": tag_pattern, "creator": creator, "vr": vr, "vm": vm, "meaning": meaning})

    document = {
        "standard": "PS3.15", "version": args.version,
        "sourceSHA256": hashlib.sha256(args.part15.read_bytes()).hexdigest(),
        "optionColumns": OPTION_COLUMNS,
        "attributes": sorted(attributes, key=lambda e: (e["tag"], e["name"])),
        "safePrivateAttributes": sorted(safe_private, key=lambda e: (e["creator"], e["element"])),
    }
    args.output.write_text(json.dumps(document, indent=1, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"{len(attributes)} attributes, {len(safe_private)} safe private attributes -> {args.output}")


if __name__ == "__main__":
    main()
