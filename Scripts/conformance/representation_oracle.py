#!/usr/bin/env python3
"""Compare the DICOM JSON / Native XML representations with pydicom and the XML standard library.

The fidelity corpus (Part 10, JSON, XML written by DicomRepresentationFidelityTests) is read by pydicom;
its own `to_json_dict` is compared semantically with the toolkit's JSON, and `Dataset.from_json` of the
toolkit's JSON is compared element by element with the Part 10 dataset. The XML is checked against the
PS3.19 namespace and element shapes with the standard library parser. Real sample files under --samples
go through `dicomtool convert` and the same pydicom comparison; only counts and hashes are recorded.
Requires requirements-iod.txt (pydicom 3.0.2).
"""
import argparse
import base64
from decimal import Decimal
import hashlib
import importlib.metadata
import json
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET

import pydicom
from image_iod_oracle import require

NAMESPACE = "http://dicom.nema.org/PS3.19/models/NativeDICOM"
INTEGER = {"IS", "SL", "SS", "UL", "US", "SV", "UV"}
NUMERIC = INTEGER | {"DS", "FL", "FD"}
BINARY = {"OB", "OD", "OF", "OL", "OV", "OW", "UN"}


def numeric(value, vr):
    if value is None:
        return None
    if vr in INTEGER:
        return int(value)
    if vr == "DS":
        return Decimal(str(value))
    return float(value)


def normalize(obj):
    """A DICOM JSON object into a comparable form: exact integers/decimals, PN as group dicts, binaries as bytes."""
    out = {}
    for key, element in obj.items():
        vr = element["vr"]
        if "InlineBinary" in element:
            out[key] = (vr, "bin", hashlib.sha256(base64.b64decode(element["InlineBinary"])).hexdigest())
        elif "BulkDataURI" in element:
            out[key] = (vr, "bulk", element["BulkDataURI"])
        elif "Value" not in element or element["Value"] in ([], None):
            out[key] = (vr, "empty")
        elif vr == "SQ":
            out[key] = (vr, "sq", tuple(tuple(sorted(normalize(item).items())) for item in element["Value"]))
        elif vr in NUMERIC:
            out[key] = (vr, "num", tuple(numeric(v, vr) for v in element["Value"]))
        elif vr == "PN":
            out[key] = (vr, "pn", tuple(None if v is None else tuple(sorted((k, s) for k, s in v.items() if s)) for v in element["Value"]))
        else:
            # PS3.18 writes an empty multi-valued string as null; pydicom writes ""; both mean an empty value.
            out[key] = (vr, "str", tuple(None if v is None or str(v).rstrip(" ") == "" else str(v).rstrip(" ") for v in element["Value"]))
    return out


def compare(ours, theirs, label):
    a, b = normalize(ours), normalize(theirs)
    require(set(a) == set(b), f"{label}: tag sets differ: {sorted(set(a) ^ set(b))}")
    for key in sorted(a):
        require(a[key][0] == b[key][0], f"{label}: VR differs for {key}: {a[key][0]} vs {b[key][0]}")
        require(a[key] == b[key], f"{label}: value differs for {key}: {a[key]} vs {b[key]}")
    return len(a)


def xml_shape(data, expected_count):
    root = ET.fromstring(data)
    require(root.tag == f"{{{NAMESPACE}}}NativeDicomModel", "XML root is not NativeDicomModel in the PS3.19 namespace")
    attributes = list(root)
    require(all(a.tag == f"{{{NAMESPACE}}}DicomAttribute" for a in attributes), "XML children are not DicomAttribute")
    # The Part 10 view carries the file meta group; the comparison covers the data set proper.
    attributes = [a for a in attributes if not a.get("tag", "").startswith("0002")]
    require(len(attributes) == expected_count, f"XML attribute count {len(attributes)} != {expected_count}")
    for attribute in attributes:
        require(len(attribute.get("tag", "")) == 8 and len(attribute.get("vr", "")) == 2, "XML attribute without tag/vr")
        children = {c.tag.split("}")[1] for c in attribute}
        require(children <= {"Value", "Item", "PersonName", "InlineBinary", "BulkData"}, f"unexpected child in {attribute.get('tag')}")
        require(len(children) <= 1, f"mixed children in {attribute.get('tag')}")
    return len(attributes)


def dataset_json(ds):
    """pydicom's JSON of a dataset, element by element; pydicom 3.0.2 cannot serialize a person name whose
    alphabetic group is empty, so those elements are rebuilt from PersonName's group accessors (documented gap)."""
    out = {}
    for element in ds:
        key = f"{element.tag:08X}"
        if element.VR == "DS" and not element.is_empty:
            values = element.value if element.VM > 1 else [element.value]
            out[key] = {"vr": "DS", "Value": [Decimal(str(value)) for value in values]}
            continue
        if element.VR == "SQ":
            out[key] = {"vr": "SQ", "Value": [dataset_json(item) for item in element.value]}
            continue
        try:
            out[key] = element.to_json_dict(bulk_data_element_handler=None, bulk_data_threshold=10 ** 9)
        except IndexError:
            require(element.VR == "PN", f"pydicom could not serialize {key}")
            values = element.value if element.VM > 1 else [element.value]
            names = []
            for value in values:
                groups = {k: v for k, v in [("Alphabetic", value.alphabetic), ("Ideographic", value.ideographic), ("Phonetic", value.phonetic)] if v}
                names.append(groups or None)
            out[key] = {"vr": "PN", "Value": names}
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--samples", type=Path, help="Directory of real DICOM files (read locally, never copied)")
    parser.add_argument("--sample-limit", type=int, default=12)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    records = []

    ds = pydicom.dcmread(args.corpus / "corpus.dcm")
    ours = json.loads((args.corpus / "corpus.json").read_text(), parse_float=Decimal)
    ours_numbers = json.loads((args.corpus / "corpus-numbers.json").read_text(), parse_float=Decimal)
    theirs = dataset_json(ds)
    count = compare(ours, theirs, "corpus")
    compare(ours_numbers, theirs, "corpus-numbers")
    # pydicom must read the toolkit JSON back into the same elements it read from Part 10.
    back = pydicom.Dataset.from_json(ours)
    for element in ds:
        require(element.tag in back, f"from_json lost {element.tag}")
        require(back[element.tag].VR == element.VR, f"from_json VR differs for {element.tag}")
        if element.VR in BINARY:
            require(bytes(back[element.tag].value) == bytes(element.value), f"from_json bytes differ for {element.tag}")
        elif element.VR != "SQ":
            # pydicom strips the even-length padding space of text VRs on read; the JSON keeps the value verbatim.
            def plain(value):
                items = list(value) if isinstance(value, (list, tuple, pydicom.multival.MultiValue)) else [value]
                if element.VR in NUMERIC:
                    return [numeric(v, element.VR) for v in items]
                return [str(v).rstrip(" ") if isinstance(v, (str, pydicom.valuerep.PersonName)) else v for v in items]
            require(plain(back[element.tag].value) == plain(element.value), f"from_json value differs for {element.tag}: {back[element.tag].value!r} vs {element.value!r}")
    xml_count = xml_shape((args.corpus / "corpus.xml").read_bytes(), count)
    records.append({"case": "corpus", "elements": count, "xmlAttributes": xml_count,
                    "sha256": {name: hashlib.sha256((args.corpus / name).read_bytes()).hexdigest() for name in ["corpus.dcm", "corpus.json", "corpus.xml"]}})

    if args.samples:
        files = sorted(p for p in args.samples.rglob("*") if p.is_file() and p.stat().st_size > 132 and p.open("rb").read(132)[128:] == b"DICM")
        for path in files[: args.sample_limit]:
            sample = pydicom.dcmread(path)
            produced = subprocess.run([str(args.binary), "convert", str(path), "--to", "json"], capture_output=True, timeout=120)
            require(produced.returncode == 0, f"convert failed for a sample: {produced.stderr.decode(errors='replace')[:200]}")
            ours = json.loads(produced.stdout, parse_float=Decimal)
            theirs = dataset_json(sample)
            # File meta (group 0002) is part of the toolkit's Part 10 view but not of pydicom's dataset JSON.
            ours = {k: v for k, v in ours.items() if not k.startswith("0002")}
            n = compare(ours, theirs, path.name)
            xml = subprocess.run([str(args.binary), "convert", str(path), "--to", "xml"], capture_output=True, timeout=120)
            require(xml.returncode == 0, "xml convert failed for a sample")
            xml_shape(xml.stdout, len([k for k in ours]))
            records.append({"case": hashlib.sha256(path.read_bytes()).hexdigest()[:16], "elements": n, "transferSyntax": str(sample.file_meta.TransferSyntaxUID)})
    args.output.write_text(json.dumps({"pydicomVersion": version, "cases": records}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(records)} representation cases agree with pydicom JSON and the PS3.19 XML shape")


if __name__ == "__main__":
    main()
