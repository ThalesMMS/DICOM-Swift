#!/usr/bin/env python3
"""Offline, independent CDA R2 oracle; JSON stdin or argv[1], JSON stdout.

Uses lxml (libxml2) only: XSD validation against the locally installed CDA_SDTC.xsd
set, structural inventory (template ids, section codes, entry counts, narrative
ID/IDREF pairs) and exclusive C14N hashes. No imports from the Swift implementation,
no network access, no entity resolution. Output never contains narrative text or
patient values: only OIDs, codes, counts and hashes.
"""
import base64
import hashlib
import importlib.metadata
import json
import os
import sys
from pathlib import Path

EXPECTED = {"lxml": "6.1.3"}
HL7 = "urn:hl7-org:v3"
DEFAULT_XSD_DIR = "/System/Library/Frameworks/HealthKit.framework/Versions/A/Resources/cda_validation"


def dependencies():
    found, unavailable = {}, []
    for name, expected in EXPECTED.items():
        try:
            version = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            unavailable.append(name)
            continue
        found[name] = version
        if version != expected:
            unavailable.append(name)
    return found, unavailable


def load(item):
    if "base64" in item:
        return base64.b64decode(item["base64"])
    return Path(item["path"]).read_bytes()


def inventory(root):
    ns = {"hl7": HL7}
    templates = sorted({e.get("root") for e in root.iter("{%s}templateId" % HL7) if e.get("root")})
    sections = root.findall(".//hl7:section", ns)
    codes = sorted({s.find("hl7:code", ns).get("code") for s in sections
                    if s.find("hl7:code", ns) is not None and s.find("hl7:code", ns).get("code")})
    entries = len(root.findall(".//hl7:entry", ns))
    ids = {e.get("ID") for e in root.iter() if e.get("ID")}
    refs = [e.get("value") for e in root.iter("{%s}reference" % HL7) if e.get("value")]
    dangling = sum(1 for value in refs if value.startswith("#") and value[1:] not in ids)
    return {"root": root.tag.split("}")[-1], "templateIDs": templates, "sectionCodes": codes,
            "entryCount": entries, "narrativeIDCount": len(ids), "referenceCount": len(refs),
            "danglingReferenceCount": dangling}


def canonical_hash(tree):
    from lxml import etree
    data = etree.tostring(tree, method="c14n2", with_comments=False, strip_text=False)
    return hashlib.sha256(data).hexdigest()


def examine(item, checks, schema):
    from lxml import etree
    result = {"id": item["id"]}
    parser = etree.XMLParser(resolve_entities=False, no_network=True, load_dtd=False,
                             huge_tree=False, remove_comments=False)
    try:
        raw = load(item)
        if b"<!DOCTYPE" in raw or b"<!ENTITY" in raw:
            result["refused"] = "dtd"
            return result
        tree = etree.fromstring(raw, parser)
    except (etree.XMLSyntaxError, ValueError):
        result["refused"] = "malformed"
        return result
    result.update(inventory(tree))
    if "c14n" in checks:
        result["canonicalSHA256"] = canonical_hash(tree)
    if "xsd" in checks and schema is not None:
        valid = schema.validate(tree)
        result["xsdValid"] = bool(valid)
        result["xsdErrorCount"] = len(schema.error_log)
    return result


def main():
    request = json.loads(sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read())
    found, unavailable = dependencies()
    output = {"ready": not unavailable, "dependencies": found, "unavailable": unavailable, "documents": []}
    checks = set(request.get("checks", ["xsd", "c14n"]))
    xsd_dir = request.get("xsd_dir") or os.environ.get("CDA_XSD_DIR") or DEFAULT_XSD_DIR
    schema = None
    if output["ready"]:
        from lxml import etree
        xsd_path = Path(xsd_dir) / "CDA_SDTC.xsd"
        if xsd_path.exists():
            schema = etree.XMLSchema(etree.parse(str(xsd_path)))
            output["xsd"] = "CDA_SDTC.xsd"
        else:
            output["xsd"] = None
            if "xsd" in checks:
                output["unavailable"].append("CDA_SDTC.xsd")
                output["ready"] = False
        for item in request.get("documents", []):
            output["documents"].append(examine(item, checks, schema))
    if request.get("result_path"):
        temp = Path(request["result_path"] + ".tmp")
        temp.write_text(json.dumps(output))
        temp.replace(request["result_path"])
    print(json.dumps(output))


if __name__ == "__main__":
    main()
