#!/usr/bin/env python3
"""Generate standard VR/VM definitions and legacy lookup plists from pinned data.

No upstream Python is executed and no network or installed pydicom is required.
Use --check for a read-only reproducibility gate. To update, replace the source,
version and license snapshots together, then review their manifest and output diffs.
Own transcriptions of newer standard entries live in the separately hashed
supplement; they must never replace entries in the pinned snapshot.
"""

import argparse
import ast
import hashlib
import json
from pathlib import Path
import plistlib


ROOT = Path(__file__).resolve().parents[2]
MANIFEST = Path(__file__).with_name("manifest.json")
RESOURCES = ROOT / "Sources/DicomData/Resources"


def literal_assignments(source, names):
    result = {}
    for node in ast.parse(source).body:
        if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.target.id in names:
            if node.target.id in result:
                raise ValueError("Duplicate source table")
            result[node.target.id] = ast.literal_eval(node.value)
    if result.keys() != names:
        raise ValueError("Missing source table")
    return result


def legacy_vr(vr):
    # These APIs historically expose one implicit-VR decoding hint. The full
    # alternatives are retained separately; contextual resolution owns their use.
    if "OW" in vr.split(" or "):
        return "OW"
    return vr.split(" or ")[0]


def resource_name(tag):
    group = tag >> 16
    if group < 0x0020:
        return "Core"
    return "RTAndSpecial" if 0x3000 <= group < 0x5000 else "Imaging"


def generate():
    manifest = json.loads(MANIFEST.read_text())
    if manifest["schemaVersion"] != 1 or len(manifest["commit"]) != 40:
        raise ValueError("Invalid source manifest")
    inputs = {}
    for item in manifest["inputs"]:
        path = (ROOT / item["path"]).resolve()
        if not path.is_relative_to(ROOT) or hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("Source or license digest mismatch: " + item["path"])
        inputs[item["upstreamPath"]] = path.read_text()
    version = literal_assignments(inputs["src/pydicom/_version.py"], {"__dicom_version__"})["__dicom_version__"]
    if version != manifest["dicomEdition"]:
        raise ValueError("Declared DICOM edition differs from source")
    tables = literal_assignments(inputs["src/pydicom/_dicom_dict.py"], {"DicomDictionary", "RepeatersDictionary"})
    definitions = {}
    plists = {name: {} for name in ["Core", "Imaging", "RTAndSpecial"]}
    for table in tables.values():
        for tag, (vr, vm, name, retired, keyword) in table.items():
            # Item/delimiter tags have no VR and are handled structurally by the parser.
            if vr == "NONE":
                continue
            key = f"{tag:08X}" if isinstance(tag, int) else tag.upper()
            if key in definitions:
                raise ValueError("Duplicate standard definition: " + key)
            definitions[key] = {"vrs": vr.split(" or "), "vm": vm, "name": name,
                                "keyword": keyword, "retired": bool(retired)}
            # Keep the legacy 6000 overlay base entries. Other wildcard patterns
            # remain patterns in the full dictionary, never invented concrete tags.
            if isinstance(tag, int) or key.startswith("60XX"):
                concrete = int(key.replace("X", "0"), 16)
                plists[resource_name(concrete)][f"{concrete:08X}"] = legacy_vr(vr) + name
    snapshot_keys = {f"{tag:08X}" if isinstance(tag, int) else tag.upper()
                     for table in tables.values() for tag in table}
    for item in manifest["ownInputs"]:
        path = (ROOT / item["path"]).resolve()
        if not path.is_relative_to(ROOT) or hashlib.sha256(path.read_bytes()).hexdigest() != item["sha256"]:
            raise ValueError("Own source digest mismatch: " + item["path"])
        for entry in json.loads(path.read_text()):
            key = entry["tag"]
            if len(key) != 8 or any(c not in "0123456789ABCDEF" for c in key):
                raise ValueError("Invalid supplement tag: " + key)
            if key in snapshot_keys or key in definitions:
                raise ValueError("Duplicate supplement definition: " + key)
            if entry["source"] != item["source"]:
                raise ValueError("Supplement source differs from manifest: " + key)
            definitions[key] = {field: entry[field] for field in ["vrs", "vm", "name", "keyword", "retired"]}
            plists[resource_name(int(key, 16))][key] = legacy_vr(" or ".join(entry["vrs"])) + entry["name"]
    header = {"schemaVersion": 1, "dicomEdition": version, "sourceCommit": manifest["commit"]}
    # One definition per line makes a standards update reviewable by tag.
    lines = ["{", *[f"  {json.dumps(k)}: {json.dumps(v)}," for k, v in header.items()], '  "definitions": {']
    ordered = sorted(definitions.items())
    for index, (key, definition) in enumerate(ordered):
        suffix = "," if index + 1 < len(ordered) else ""
        lines.append(f"    {json.dumps(key)}: {json.dumps(definition, ensure_ascii=False)}{suffix}")
    lines.extend(["  }", "}", ""])
    outputs = {RESOURCES / "DCMDictionary-Definitions.json": "\n".join(lines).encode()}
    for name, values in plists.items():
        outputs[RESOURCES / f"DCMDictionary-{name}.plist"] = plistlib.dumps(values, sort_keys=True)
    return outputs, len(definitions)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    outputs, count = generate()
    for path, expected in outputs.items():
        if args.check:
            if not path.exists() or path.read_bytes() != expected:
                raise SystemExit("Generated dictionary drift: " + str(path))
        else:
            path.write_bytes(expected)
    print(f"{'Verified' if args.check else 'Generated'} {count} standard definitions in {len(outputs)} resources")
