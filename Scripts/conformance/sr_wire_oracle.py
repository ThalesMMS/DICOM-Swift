#!/usr/bin/env python3
"""Audit the synthetic SR/KOS wire corpus; full IOD conformance remains incomplete."""

import argparse
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path

from pydicom import dcmread
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo
from image_iod_oracle import VERSIONS, require

SYNTAXES = ["1.2.840.10008.1.2", "1.2.840.10008.1.2.1", "1.2.840.10008.1.2.2", "1.2.840.10008.1.2.1.99"]
CASES = {f"report-{sop}-{syntax}": (sop, syntax, False) for sop in ["22", "33", "59"] for syntax in SYNTAXES}
CASES.update({f"historical-sh-{syntax}": ("22", syntax, True) for syntax in SYNTAXES[1:]})
COMMON_MISSING = {
    # The builder emits the Patient, General Study, General Equipment and series Type 2 attributes
    # empty and the mandated KOS root template (lot L3 of #2321); only Type 1 values stay missing.
}


def expected_errors(is_ko):
    missing = dict(COMMON_MISSING)
    missing["Key Object Document" if is_ko else "SR Document General"] = ["(0008,0023)", "(0008,0033)", "(0020,0013)"]
    # The builder has emitted an empty Type 2 Performed Procedure Code Sequence since 994e1ae51; the
    # oracle no longer reports (0040,A372) missing on the SR objects.
    missing["Key Object Document Series" if is_ko else "SR Document Series"] = ["(0020,0011)"]
    return sorted([(module, tag, "TagMissing") for module, tags in missing.items() for tag in tags] + [
        ("SR Document Content", "(0040,A730) / (0008,1199) / (0008,1160)", "TagUnexpected")])


def validate_witness(path, sop, syntax, historical):
    ds = dcmread(path)
    require(str(ds.file_meta.TransferSyntaxUID) == syntax, "Unexpected transfer syntax")
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88." + sop, "Unexpected SOP class")
    content = ds.ContentSequence[0].ReferencedSOPSequence[0]
    require(content.ReferencedSOPClassUID == "1.2.840.10008.5.1.4.1.1.2.1"
            and int(content.ReferencedFrameNumber) == 1, "Missing Enhanced CT frame selection")
    evidence = ds.CurrentRequestedProcedureEvidenceSequence[0].ReferencedSeriesSequence[0].ReferencedSOPSequence[0]
    require("ReferencedFrameNumber" not in evidence and evidence.ReferencedSOPInstanceUID == content.ReferencedSOPInstanceUID,
            "Unexpected hierarchical evidence frame scope")
    if sop == "59":
        require(all(key not in ds for key in ["CompletionFlag", "VerificationFlag"]),
                "Unexpected SR-only builder attributes in KOS")
        require(ds.ContentTemplateSequence[0].MappingResource == "DCMR" and ds.ContentTemplateSequence[0].TemplateIdentifier == "2010",
                "Missing mandated KOS root template")
    else:
        template = ds.ContentTemplateSequence[0]
        require(template[0x00080105].VR == ("SH" if historical else "CS")
                and template.MappingResource == "DCMR" and template.TemplateIdentifier == "1500",
                "Missing actual template VR witness")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS, "Oracle dependency versions differ from the qualified set")
    require(args.standard_json.parent.name == "2026c", "DICOM 2026c cache required")
    files = {path.stem: path for path in args.corpus.glob("*.dcm")}
    require(set(files) == set(CASES), "Missing or unexpected corpus instances")
    source_hashes = {}
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    for name in names:
        source_hashes[name] = hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest()
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in data, "Unexpected standard edition in docbook")
        source_hashes[name] = hashlib.sha256(data).hexdigest()
    info = DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for name, (sop, syntax, historical) in CASES.items():
        path = files[name]
        validate_witness(path, sop, syntax, historical)
        result = validator.validate(path)[str(path)]
        errors = [{"module": module, "tag": str(tag), "code": error.code.name,
                   "requirement": getattr(error.type, "value", error.type)}
                  for module, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        require(result.status.name == "Failed" and result.errors == len(errors), "Unexpected whole-IOD result")
        require(sorted((e["module"], e["tag"], e["code"]) for e in errors) == expected_errors(sop == "59"),
                "Independent diagnostics changed for " + name)
        results.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "expectedSwiftVRVM": "failed" if historical else "passed",
                        "independentIODOutcome": result.status.name, "independentErrors": errors})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": source_hashes, "cases": results,
              "scope": "Wire VR/VM and existing application semantic subset, not complete SR/KOS IOD or TID validation",
              "limitations": ["Builder omits mandatory common and document attributes; all independent IOD checks fail.",
                              "Oracle loses C.18.4 nested macro hierarchy and reports the IMAGE frame selector as unexpected.",
                              "Oracle does not reject explicit SH Mapping Resource; pydicom independently witnesses its actual VR.",
                              "Referenced image bytes are absent; frame count and external reference conditions remain unknown."]}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} wire witnesses; all whole-IOD failures preserved")


if __name__ == "__main__":
    main()
