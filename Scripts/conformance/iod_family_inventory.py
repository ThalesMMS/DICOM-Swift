#!/usr/bin/env python3
"""Per-family module inventory for the #2321 IOD union, from the pinned PS3.3 JSON cache.

Counts the distinct PS3.3 modules each family declares (M/C/U usage) and which of
them already have a composed helper in `DicomInstanceValidator`. A helper that
exists is not a qualified module: the helper sets below are a work inventory,
not a conformance declaration. Output is Markdown for Docs/QA.

Usage:
  python3 iod_family_inventory.py --standard-json /tmp/isis-2321-dicom-standard/2026c/json
"""
from __future__ import annotations

import argparse
import json
import pathlib

PREFIX = "1.2.840.10008.5.1.4.1.1."

# SOP Class UID suffixes per family. Sources: #2321 body, the reference confrontation in
# Docs/QA/DICOMValidationAcceptance.md and the SOP lists actually present in DICOM-Swift.
FAMILIES: dict[str, list[str]] = {
    "SC single-frame": ["7"],
    "SC multi-frame": ["7.1", "7.2", "7.3", "7.4"],
    "CT/MR clássico": ["2", "4"],
    "CR": ["1"],
    "US": ["6.1"],
    "SR/KOS": ["88.11", "88.22", "88.33", "88.34", "88.35", "88.59", "88.50", "88.65", "88.69",
               "88.67", "88.76", "88.68", "88.73", "88.71", "88.72", "88.70", "88.74", "88.75"],
    "Enhanced CT/MR/XA": ["2.1", "4.1", "12.1.1"],
    "SEG": ["66.4"],
    "PM": ["30"],
    "PS": ["11.1", "11.2", "11.3", "11.4"],
    "RT": ["481.2", "481.3", "481.5"],
    "Waveform (15 próprios)": ["9.1.1", "9.1.2", "9.1.3", "9.1.4", "9.2.1", "9.3.1", "9.4.1", "9.4.2",
                               "9.5.1", "9.6.1", "9.6.2", "9.7.1", "9.7.2", "9.7.3", "9.7.4"],
    "Documentos": ["104.1", "104.2", "104.3", "104.4", "104.5"],
    "Vídeo": ["77.1.1.1", "77.1.2.1", "77.1.4.1"],
}

# PS3.3 section references with a composed helper on the published branch (partial composition).
COMPOSED_PUBLISHED = {
    "C.7.1.1", "C.7.2.1", "C.7.3.1", "C.7.4.1", "C.7.5.1", "C.7.6.1", "C.7.6.2", "C.7.6.3",
    "C.8.2.1", "C.8.3.1", "C.8.6.1", "C.8.6.2", "C.11.1", "C.11.2", "C.12.1", "C.12.2", "C.12.4",
    "C.17.2", "C.17.3", "C.17.6",
}
# Helpers present only in the uncommitted SC lot.
COMPOSED_LOCAL = {"C.7.1.3", "C.7.2.3", "C.7.3.2", "C.7.6.12", "C.9.2"}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--standard-json", required=True, type=pathlib.Path,
                        help="directory containing iod_info.json from dicom-validator's PS3.3 cache")
    parser.add_argument("--names", action="store_true", help="also list uncomposed module names per family")
    args = parser.parse_args()

    iod = json.loads((args.standard_json / "iod_info.json").read_text())
    union_modules: set[str] = set()
    associations = 0
    rows = []
    details = []
    for family, suffixes in FAMILIES.items():
        modules: dict[str, tuple[str, set[str]]] = {}
        for suffix in suffixes:
            entry = iod.get(PREFIX + suffix)
            if entry is None:
                raise SystemExit(f"{family}: {PREFIX + suffix} absent from iod_info.json")
            for name, module in entry["modules"].items():
                modules.setdefault(module["ref"], (name, set()))[1].add(module["use"][0])
                associations += 1
        union_modules |= set(modules)
        mandatory = sum(1 for _, usage in modules.values() if "M" in usage)
        conditional = sum(1 for _, usage in modules.values() if "C" in usage and "M" not in usage)
        composed = sum(1 for ref in modules if ref in COMPOSED_PUBLISHED)
        local = sum(1 for ref in modules if ref in COMPOSED_LOCAL)
        missing = sorted((ref, name, "".join(sorted(usage))) for ref, (name, usage) in modules.items()
                         if ref not in COMPOSED_PUBLISHED and ref not in COMPOSED_LOCAL)
        rows.append((family, len(suffixes), len(modules), mandatory, conditional,
                     len(modules) - mandatory - conditional, composed, local, len(missing)))
        details.append((family, missing))

    print("| Família | SOPs | Módulos | M | C | U | Helper publicado | Helper local | Sem composição |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for row in rows:
        print("| " + " | ".join(str(cell) for cell in row) + " |")
    total_sops = sum(len(s) for s in FAMILIES.values())
    print(f"\nSOPs: {total_sops}; módulos distintos na união: {len(union_modules)}; "
          f"associações módulo–IOD: {associations}")
    if args.names:
        for family, missing in details:
            print(f"\n**{family}** ({len(missing)} sem composição): "
                  + ", ".join(f"{name} {ref} [{usage}]" for ref, name, usage in missing))


if __name__ == "__main__":
    main()
