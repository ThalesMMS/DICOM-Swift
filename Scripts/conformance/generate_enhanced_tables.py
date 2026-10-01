#!/usr/bin/env python3
"""Generate the PS3.3 2026c attribute tables of the Enhanced CT/MR/XA, Segmentation, Parametric Map,
Softcopy Presentation State, RT Dose/Structure Set/Plan, waveform and encapsulated document IODs as Swift data.

Reads the pinned DocBook (module and macro tables) and the dicom-validator JSON cache
(IOD module and functional group usage) and writes
Sources/DicomData/Generated/DicomEnhancedImageTables.swift. The Swift file carries only
tags, types, nesting, item cardinality wording, "may be present otherwise" wording and
include references; conditions and value constraints are curated by hand in
DicomEnhancedImageConditions. Rerun after a standard edition change and review the diff.

Usage:
  python3 generate_enhanced_tables.py --standard /tmp/isis-2321-dicom-standard/2026c \
      --output Sources/DicomData/Generated/DicomEnhancedImageTables.swift
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re

from lxml import etree

NS = {"d": "http://docbook.org/ns/docbook"}
XML = "{http://www.w3.org/XML/1998/namespace}"
IODS = {"1.2.840.10008.5.1.4.1.1.6.1": "ultrasound",
        "1.2.840.10008.5.1.4.1.1.77.1.1.1": "videoEndoscopic",
        "1.2.840.10008.5.1.4.1.1.77.1.2.1": "videoMicroscopic",
        "1.2.840.10008.5.1.4.1.1.77.1.4.1": "videoPhotographic",
        "1.2.840.10008.5.1.4.1.1.77.1.6": "vlWholeSlideMicroscopy",
        "1.2.840.10008.5.1.4.1.1.66.1": "spatialRegistration",
        "1.2.840.10008.5.1.4.1.1.66.3": "deformableSpatialRegistration", "1.2.840.10008.5.1.4.1.1.66.5": "surfaceSegmentation", "1.2.840.10008.5.1.4.1.1.2.1": "enhancedCT", "1.2.840.10008.5.1.4.1.1.4.1": "enhancedMR",
        "1.2.840.10008.5.1.4.1.1.12.1.1": "enhancedXA", "1.2.840.10008.5.1.4.1.1.66.4": "segmentation",
        "1.2.840.10008.5.1.4.1.1.30": "parametricMap", "1.2.840.10008.5.1.4.1.1.11.1": "grayscaleSoftcopyPS",
        "1.2.840.10008.5.1.4.1.1.11.2": "colorSoftcopyPS", "1.2.840.10008.5.1.4.1.1.11.3": "pseudoColorSoftcopyPS",
        "1.2.840.10008.5.1.4.1.1.11.4": "blendingSoftcopyPS", "1.2.840.10008.5.1.4.1.1.481.2": "rtDose",
        "1.2.840.10008.5.1.4.1.1.481.3": "rtStructureSet", "1.2.840.10008.5.1.4.1.1.481.5": "rtPlan",
        "1.2.840.10008.5.1.4.1.1.9.1.1": "twelveLeadECG",
        "1.2.840.10008.5.1.4.1.1.9.1.2": "generalECG",
        "1.2.840.10008.5.1.4.1.1.9.1.3": "ambulatoryECG",
        "1.2.840.10008.5.1.4.1.1.9.1.4": "general32BitECG",
        "1.2.840.10008.5.1.4.1.1.9.2.1": "hemodynamic",
        "1.2.840.10008.5.1.4.1.1.9.3.1": "cardiacElectrophysiology",
        "1.2.840.10008.5.1.4.1.1.9.4.1": "basicVoiceAudio",
        "1.2.840.10008.5.1.4.1.1.9.4.2": "generalAudio",
        "1.2.840.10008.5.1.4.1.1.9.5.1": "arterialPulse",
        "1.2.840.10008.5.1.4.1.1.9.6.1": "respiratory",
        "1.2.840.10008.5.1.4.1.1.9.6.2": "multichannelRespiratory",
        "1.2.840.10008.5.1.4.1.1.9.7.1": "routineScalpEEG",
        "1.2.840.10008.5.1.4.1.1.9.7.2": "electromyogram",
        "1.2.840.10008.5.1.4.1.1.9.7.3": "electrooculogram",
        "1.2.840.10008.5.1.4.1.1.9.7.4": "sleepEEG",
        "1.2.840.10008.5.1.4.1.1.104.1": "encapsulatedPDF",
        "1.2.840.10008.5.1.4.1.1.104.2": "encapsulatedCDA",
        "1.2.840.10008.5.1.4.1.1.104.3": "encapsulatedSTL",
        "1.2.840.10008.5.1.4.1.1.104.4": "encapsulatedOBJ",
        "1.2.840.10008.5.1.4.1.1.104.5": "encapsulatedMTL"}
# Tables composed by existing hand-written helpers; the runtime maps these references. C.11.7 (Overlay
# Activation) is a repeating group (60xx,1001) and is composed by hand.
HAND_WRITTEN = {"table_8.8-1", "table_8.8-1a", "table_8.8-1b", "table_10-1", "table_10-2", "table_10-3", "table_10-9",
                "table_10-11", "table_10-17", "table_10-19", "table_10.2.1-1", "table_C.7.6.16-12b", "table_C.17-3",
                "table_C.17-3a", "table_C.17-5", "table_C.17-6", "C.11.7"}
# Modules already composed elsewhere (common set); only their usage is recorded.
COMMON_MODULES = {"Patient", "Clinical Trial Subject", "General Study", "Patient Study", "Clinical Trial Study",
                  "General Series", "Clinical Trial Series", "General Equipment", "SOP Common",
                  "Frame of Reference", "Synchronization", "Specimen", "Device", "ICC Profile",
                  "Enhanced Patient Orientation", "Common Instance Reference", "Overlay Plane", "General Image",
                  "General Reference", "General Acquisition"}


def text(element) -> str:
    return re.sub(r"\s+", " ", "".join(element.itertext())).strip()


def item_range(description: str) -> str | None:
    d = description.lower()
    if "only a single item" in d or "only one item" in d:
        return "1...1"
    if "zero or one item" in d:
        return "0...1"
    if "one or two items" in d:
        return "1...2"
    if "two items shall be included" in d:
        return "2...2"
    if "one or more items" in d:
        return "1...Int.max"
    if "zero or more items" in d:
        return "0...Int.max"
    return None


def parse_table(table):
    rows = []
    for tr in table.iter("{%s}tr" % NS["d"]):
        tds = list(tr.iter("{%s}td" % NS["d"]))
        if not tds:
            continue
        first = text(tds[0])
        depth = len(first) - len(first.lstrip(">"))
        if first.lstrip("> ").startswith("Include") or len(tds) == 1:
            xrefs = [x.get("linkend") for x in tds[0].iter("{%s}xref" % NS["d"])]
            rows.append({"include": xrefs, "depth": depth, "context": text(tds[1]) if len(tds) > 1 else ""})
            continue
        if len(tds) < 3:
            continue
        description = text(tds[3]) if len(tds) > 3 else ""
        rows.append({"name": first.lstrip("> ").strip(), "tag": text(tds[1]), "type": text(tds[2]), "depth": depth,
                     "items": item_range(description),
                     "mayBePresent": bool(re.search(r"may be present otherwise|otherwise may be present", description, re.I)),
                     "required": "required if" in description.lower(), "description": description})
    return rows


def docbook_group_macros(title: str, tables, sections) -> list[dict]:
    """The dicom-validator cache lists no functional group macros for some IODs (Segmentation,
    Parametric Map); read the IOD's "<name> Functional Group Macros" table from the DocBook."""
    caption = title.replace(" IOD", "") + " Functional Group Macros"
    for table in tables.values():
        node = table.find("{%s}caption" % NS["d"])
        if node is None or text(node) != caption:
            continue
        macros = []
        for tr in table.iter("{%s}tr" % NS["d"]):
            tds = list(tr.iter("{%s}td" % NS["d"]))
            if len(tds) < 3:
                continue
            xrefs = [x.get("linkend") for x in tds[1].iter("{%s}xref" % NS["d"])]
            if not xrefs:
                continue
            macros.append({"name": text(tds[0]), "ref": xrefs[0].removeprefix("sect_"), "use": text(tds[2])})
        return macros
    raise SystemExit(f"Functional group macro table '{caption}' not found in the 2026c DocBook")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--standard", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--inventory", type=pathlib.Path, help="Optional JSON dump with descriptions for curation")
    args = parser.parse_args()
    if args.standard.name != "2026c":
        raise SystemExit("The generator is pinned to the PS3.3 2026c cache")
    root = etree.parse(str(args.standard / "docbook" / "part03.xml")).getroot()
    tables = {t.get(XML + "id"): t for t in root.iter("{%s}table" % NS["d"])}
    sections = {s.get(XML + "id"): s for s in root.iter("{%s}section" % NS["d"])}
    iod_info = json.loads((args.standard / "json" / "iod_info.json").read_text())

    def table_for(ref: str):
        if ref.startswith("table_"):
            return tables.get(ref)
        section = sections.get(ref if ref.startswith("sect_") else "sect_" + ref)
        return section.find(".//{%s}table" % NS["d"]) if section is not None else None

    iods, pending, seen, extracted = {}, [], set(), {}
    for uid, key in IODS.items():
        entry = iod_info[uid]
        modules = [{"name": name, "ref": info["ref"], "use": info["use"]} for name, info in entry["modules"].items()]
        macros = [{"name": name, "ref": info["ref"], "use": info["use"]} for name, info in entry["group_macros"].items()]
        if not macros and "Multi-frame Functional Groups" in entry["modules"]:
            macros = docbook_group_macros(entry["title"], tables, sections)
        iods[key] = {"uid": uid, "title": entry["title"], "modules": modules, "groupMacros": macros}
        pending += [m["ref"] for m in modules if m["name"] not in COMMON_MODULES] + [m["ref"] for m in macros]
    while pending:
        ref = pending.pop(0)
        if ref in seen or ref in HAND_WRITTEN:
            continue
        seen.add(ref)
        table = table_for(ref)
        if table is None:
            raise SystemExit(f"Table {ref} not found in the 2026c DocBook")
        rows = parse_table(table)
        extracted[ref] = {"id": table.get(XML + "id"), "caption": text(table.find("{%s}caption" % NS["d"])), "rows": rows}
        for row in rows:
            pending += [x for x in row.get("include", []) if x not in seen]
    if args.inventory:
        args.inventory.write_text(json.dumps({"iods": iods, "tables": extracted}, indent=1) + "\n")

    def swift_tag(tag: str) -> str:
        return "0x" + tag.strip("()").replace(",", "")

    lines = ["// Generated by Scripts/conformance/generate_enhanced_tables.py from PS3.3 2026c. Do not edit.",
             "// Attribute tables of the Enhanced CT, Enhanced MR, Enhanced XA, Segmentation, Parametric Map, Softcopy",
             "// Presentation State, RT Dose/Structure Set/Plan, waveform and encapsulated document IODs (modules and",
             "// functional group macros) with their include references. Conditions and value constraints are curated in",
             "// DicomEnhancedImageConditions; usage letters follow PS3.3 A.38, A.36, A.47, A.51, A.75, A.33, A.18–A.20, A.34, A.45.",
             "",
             "enum DicomEnhancedImageTables {",
             "    struct Row {",
             "        let tag: Int",
             "        let type: String",
             "        let depth: Int",
             "        let items: ClosedRange<Int>?",
             "        let mayBePresentOtherwise: Bool",
             "        let include: String?",
             "",
             "        init(_ tag: Int, _ type: String, _ depth: Int, items: ClosedRange<Int>? = nil, may: Bool = false) {",
             "            self.tag = tag; self.type = type; self.depth = depth; self.items = items",
             "            mayBePresentOtherwise = may; include = nil",
             "        }",
             "",
             "        init(include: String, _ depth: Int) {",
             "            tag = 0; type = \"\"; self.depth = depth; items = nil; mayBePresentOtherwise = false; self.include = include",
             "        }",
             "    }",
             "",
             "    struct Usage {",
             "        let name: String",
             "        let table: String",
             "        let usage: String",
             "    }",
             "",
             "    struct IOD {",
             "        let sopClassUID: String",
             "        let modules: [Usage]",
             "        let groupMacros: [Usage]",
             "    }",
             ""]
    lines.append("    static let iods: [String: IOD] = [")
    for key, iod in iods.items():
        lines.append(f"        \"{key}\": IOD(sopClassUID: \"{iod['uid']}\", modules: [")
        for m in iod["modules"]:
            usage = m["use"].split(" ")[0]
            lines.append(f"            Usage(name: \"{m['name']}\", table: \"{m['ref']}\", usage: \"{usage}\"),")
        lines.append("        ], groupMacros: [")
        for m in iod["groupMacros"]:
            usage = m["use"].split(" ")[0]
            lines.append(f"            Usage(name: \"{m['name']}\", table: \"{m['ref']}\", usage: \"{usage}\"),")
        lines.append("        ]),")
    lines.append("    ]")
    lines.append("")
    lines.append("    static let tables: [String: [Row]] = [")
    for ref in sorted(extracted):
        entry = extracted[ref]
        lines.append(f"        // {entry['caption']} ({entry['id']})")
        lines.append(f"        \"{ref}\": [")
        for row in entry["rows"]:
            # US Image repeats Overlay Subtype over 60xx; the US composer resolves each referenced group.
            if ref == "C.8.5.6" and row.get("tag") == "(60xx,0045)":
                continue
            if "include" in row:
                for target in row["include"]:
                    lines.append(f"            Row(include: \"{target}\", {row['depth']}),")
                continue
            parts = [swift_tag(row["tag"]), f"\"{row['type']}\"", str(row["depth"])]
            if row["items"]:
                parts.append(f"items: {row['items']}")
            if row["mayBePresent"]:
                parts.append("may: true")
            lines.append(f"            Row({', '.join(parts)}), // {row['name']}")
        lines.append("        ],")
    lines.append("    ]")
    lines.append("}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("\n".join(lines) + "\n")
    print(f"{len(extracted)} tables, {sum(len(t['rows']) for t in extracted.values())} rows -> {args.output}")


if __name__ == "__main__":
    main()
