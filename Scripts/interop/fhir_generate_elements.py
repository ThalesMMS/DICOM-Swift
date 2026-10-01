#!/usr/bin/env python3
"""Generate the compact FHIR element table used by the Swift FHIR target.

Source: fhir.resources (R4B models, pydantic v2) installed in the oracle environment.
Output: JSON with, per type, its kind (resource | complex | backbone | primitive), the ordered
element list (name, type, array, required, choice group) and, for resources, the primitive
root fields. Only structural metadata is emitted; no narrative or example content.
"""
import importlib
import inspect
import json
import pkgutil
import re
import sys
import typing

import fhir.resources.R4B as R
from fhir_core.fhirabstractmodel import FHIRAbstractModel
import importlib.metadata

PRIMITIVES = {"Boolean": "boolean", "Integer": "integer", "String": "string", "Decimal": "decimal",
              "Uri": "uri", "Url": "url", "Canonical": "canonical", "Base64Binary": "base64Binary",
              "Instant": "instant", "Date": "date", "DateTime": "dateTime", "Time": "time", "Code": "code",
              "Oid": "oid", "Id": "id", "Markdown": "markdown", "UnsignedInt": "unsignedInt",
              "PositiveInt": "positiveInt", "Uuid": "uuid", "Xhtml": "xhtml"}


def describe(annotation):
    text = str(annotation)
    array = text.startswith("typing.List[") or text.startswith("list[")
    inner = re.sub(r"^(typing\.List|list)\[(.*)\]$", r"\2", text) if array else text
    inner = inner.replace("typing.Optional[", "").replace(" | None", "")
    for meta, name in PRIMITIVES.items():
        if re.search(r"\b" + meta + r"\(", inner):
            return name, array
    if "fhir_core.types.Xhtml" in inner:
        return "xhtml", array
    if re.search(r"\bbool\b", inner):
        return "boolean", array
    if "uuid.UUID" in inner:
        return "uuid", array
    m = re.search(r"abc\.([A-Za-z0-9]+)Type", inner)
    if m:
        return m.group(1), array
    if re.fullmatch(r"(<class ')?str('>)?", inner.strip("]")):
        return "string", array
    return "unknown:" + inner, array


def main():
    types = {}
    for module_info in pkgutil.iter_modules(R.__path__):
        if module_info.name.startswith("fhir") or module_info.name in ("abc", "fhirtypes"):
            continue
        module = importlib.import_module("fhir.resources.R4B." + module_info.name)
        for _, cls in inspect.getmembers(module, inspect.isclass):
            if not issubclass(cls, FHIRAbstractModel) or cls.__module__ != module.__name__:
                continue
            name = cls.__name__
            bases = [b.__name__ for b in cls.__mro__]
            if "BackboneElement" in bases:
                kind = "backbone"
            elif "DomainResource" in bases or "Resource" in bases:
                kind = "resource"
            else:
                kind = "complex"
            elements = []
            sequence = {name: index for index, name in enumerate(cls.elements_sequence())} if hasattr(cls, "elements_sequence") else {}
            ordered = sorted(cls.model_fields.items(), key=lambda item: sequence.get(item[1].alias or item[0], len(sequence)))
            for field_name, field in ordered:
                extra = field.json_schema_extra or {}
                if not isinstance(extra, dict) or not extra.get("element_property"):
                    continue
                type_name, array = describe(field.annotation)
                entry = {"name": field.alias or field_name, "type": type_name}
                if array:
                    entry["array"] = True
                if field.is_required() or extra.get("element_required"):
                    entry["required"] = True
                if extra.get("one_of_many"):
                    entry["choice"] = extra["one_of_many"]
                    if extra.get("one_of_many_required"):
                        entry["choiceRequired"] = True
                elements.append(entry)
            types[name] = {"kind": kind, "elements": elements}
    for primitive in PRIMITIVES.values():
        types.setdefault(primitive, {"kind": "primitive", "elements": []})
    output = {"source": "fhir.resources " + importlib.metadata.version("fhir.resources") + " (FHIR R4B 4.3.0 models)",
              "generatedBy": "DICOM-Swift/Scripts/interop/fhir_generate_elements.py",
              "types": dict(sorted(types.items()))}
    json.dump(output, sys.stdout, separators=(",", ":"), sort_keys=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
