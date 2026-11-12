#!/usr/bin/env python3
"""Offline, independent HL7 v2 cross-parser; JSON stdin or argv[1], JSON stdout.

No imports from the Swift implementation and no network access. Optional readiness
and result files follow pynetdicom_peer.py. Diagnostic text never contains values.
"""
import base64
import contextlib
import hashlib
import importlib.metadata
import io
import json
import re
import sys
from pathlib import Path

EXPECTED = {"hl7apy": "1.3.5", "hl7": "0.4.5"}


def error_code(error):
    # Never forward exceptions: upstream diagnostics can contain message values.
    text = str(error)
    for prefix, code in [("Missing required child ", "requiredMissing"),
                         ("Child limit exceeded ", "cardinality")]:
        if text.startswith(prefix):
            path = text[len(prefix):]
            if re.fullmatch(r"[A-Z0-9_.]+", path):
                return {"path": path, "code": code}
    return {"path": "message", "code": type(error).__name__}


def decode_wire(raw):
    raw = raw.replace(b"\r\n", b"\r").replace(b"\n", b"\r")
    header = raw.split(b"\r", 1)[0]
    fields = header.split(header[3:4]) if header.startswith(b"MSH") and len(header) > 4 else []
    declaration = fields[17].split(header[5:6])[0].decode("ascii", errors="ignore").strip().upper() if len(fields) > 17 else ""
    codec = {"": "ascii", "ASCII": "ascii", "UNICODE UTF-8": "utf-8", "UTF-8": "utf-8",
             "UNICODE": "utf-8", "WINDOWS-1252": "cp1252", "WINDOWS 1252": "cp1252", "CP1252": "cp1252"}.get(declaration)
    if declaration.startswith("8859/") and declaration[5:] in [str(n) for n in range(1, 10)] + ["15"]:
        codec = "iso8859-" + declaration[5:]
    codec = codec or "latin-1"
    try:
        return raw.decode(codec), codec
    except UnicodeDecodeError:
        return raw.decode("latin-1"), "latin-1"


def segments(element):
    if element.classname == "Segment":
        return [element.name]
    return [name for child in element.children for name in segments(child)]


def cross_parse(item, checks):
    import hl7
    from hl7apy.parser import parse_message, get_message_info
    from hl7apy.consts import VALIDATION_LEVEL
    from hl7apy.core import Message
    from hl7apy.exceptions import InvalidName, UnsupportedVersion
    from hl7apy.validation import Validator

    result = {"id": item["id"], "hl7apy": {"parsed": False, "version": None, "message_type": None,
              "structure": None, "segments": [], "validation": {"valid": None, "errors": []},
              "serialized_sha256": None}, "python_hl7": {"segments": [], "field_counts": []}, "unsupported": []}
    a = result["hl7apy"]
    raw = Path(item["path"]).read_bytes() if "path" in item else base64.b64decode(item["base64"], validate=True)
    wire, codec = decode_wire(raw)
    try:
        structural = hl7.parse(wire)
        result["python_hl7"] = {"segments": [str(s[0]) for s in structural],
                                "field_counts": [len(s) - 1 for s in structural]}
    except Exception as error:
        result["python_hl7"]["error"] = error_code(error)
    try:
        encoding, structure, version = get_message_info(wire)
        a["version"] = version
        # Probe the schema, independently of tolerant parsing's unnamed fallback.
        try:
            if structure is None:
                result["unsupported"].append("hl7apy:structureNotIdentified")
            else:
                Message(name=structure, version=version)
        except InvalidName:
            result["unsupported"].append("hl7apy:structureUnavailable")
        flat = parse_message(wire, validation_level=VALIDATION_LEVEL.TOLERANT, find_groups=False)
        a.update(parsed=True, version=flat.version, message_type=flat.msh.msh_9.to_er7(),
                 structure=flat.name, segments=segments(flat))
        if "roundtrip" in checks:
            serialized = flat.to_er7()
            a["serialized_sha256"] = hashlib.sha256(serialized.encode(codec)).hexdigest()
        if "validate" in checks and not result["unsupported"]:
            grouped = parse_message(wire, validation_level=VALIDATION_LEVEL.TOLERANT, find_groups=True)
            # hl7apy grouping may silently drop unknown/out-of-order segments.
            # Such a verdict cannot qualify the input message.
            if segments(grouped) != segments(flat):
                result["unsupported"].append("hl7apy:groupingDropsSegments")
            else:
                try:
                    a["validation"]["valid"] = bool(Validator.validate(grouped))
                except Exception as error:
                    a["validation"] = {"valid": False, "errors": [error_code(error)]}
    except UnsupportedVersion:
        result["unsupported"].append("hl7apy:versionUnavailable")
    except Exception as error:
        a["validation"] = {"valid": False, "errors": [error_code(error)]}
    return result


def main():
    cfg = json.loads(sys.argv[1] if len(sys.argv) > 1 else sys.stdin.read())
    versions = {}
    missing = []
    for name, expected in EXPECTED.items():
        try:
            versions[name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            versions[name] = None
        if versions[name] != expected:
            missing.append(name + ":requires:" + expected)
    ready = {"ready": not missing, "dependencies": versions, "unavailable": missing}
    if cfg.get("ready_path"):
        Path(cfg["ready_path"]).write_text(json.dumps(ready))
    checks = cfg.get("checks", ["structure", "validate", "roundtrip"])
    if not set(checks) <= {"structure", "validate", "roundtrip"}:
        raise ValueError("Unknown check")
    # Some tolerant datatype constructors print diagnostics; keep stdout JSON-only.
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        results = [] if missing else [cross_parse(item, checks) for item in cfg.get("messages", [])]
    output = dict(ready, messages=results)
    payload = json.dumps(output, sort_keys=True)
    if cfg.get("result_path"):
        Path(cfg["result_path"]).write_text(payload)
    print(payload)


if __name__ == "__main__":
    main()
