#!/usr/bin/env python3
"""Compare the synthetic CT/MR image-module corpus without hiding oracle gaps.

Requires the separately installed, pinned requirements-iod.txt and an explicitly
downloaded DICOM 2026c JSON/docbook cache. Does not change or transmit instances.
"""

import argparse
import hashlib
import importlib.metadata
import json
import logging
from pathlib import Path

from pydicom import dcmread
from dicom_validator.validator.dicom_file_validator import DicomFileValidator
from dicom_validator.validator.dicom_info import DicomInfo


VERSIONS = {"dicom-validator": "0.8.3", "pydicom": "3.0.2", "lxml": "6.1.3", "pyparsing": "3.3.2"}
CASES = {
    "ct-baseline": ("passed", "Passed", None),
    "ct-missing-rescale": ("failed", "Failed", None),
    "ct-wrong-precision": ("failed", "Failed", None),
    "ct-contradictory-units": ("failed", "Passed", "Oracle does not enforce the original non-localizer HU constraint."),
    "ct-wrong-high-bit": ("failed", "Passed", "Oracle does not enforce High Bit = Bits Stored - 1."),
    "ct-derived-unknown-units": ("incomplete", "Passed", "Absent derived output units do not establish the 1C condition."),
    "ct-code-baseline": ("passed", "Passed", None),
    "ct-code-missing-meaning": ("failed", "Failed", None),
    "ct-code-missing-value": ("failed", "Failed", None),
    "ct-code-multiple-values": ("failed", "Passed", "Oracle does not enforce mutually exclusive code-value representations."),
    "ct-code-empty-phantom": ("failed", "Passed", "Oracle accepts empty Type 3 sequences contrary to PS3.5 2026c 7.4.5."),
    "ct-code-equivalent-missing-meaning": ("failed", "Failed", None),
    "mr-baseline": ("passed", "Passed", None),
    "mr-ir-empty-time": ("passed", "Passed", None),
    "mr-missing-repetition": ("failed", "Failed", None),
    "mr-ir-missing-time": ("failed", "Passed", "Oracle did not extract the Inversion Time condition from PS3.3."),
    "mr-wrong-high-bit": ("failed", "Passed", "Oracle does not enforce High Bit = Bits Stored - 1."),
    "mr-gating-unknown": ("incomplete", "Passed", "Unrecognized gating terms require evidence; oracle treats unparsed conditions as optional."),
    "mr-ep-first": ("passed", "Passed", None),
    "mr-ep-second": ("passed", "Failed", "Oracle evaluates only the first Scanning Sequence component; dicom3tools uses all components."),
    "mr-sk-second": ("failed", "Passed", "Oracle evaluates only the first Sequence Variant component; dicom3tools uses all components."),
}
EXPECTED_ERRORS = {
    "ct-missing-rescale": [("CT Image", "(0028,1053)", "TagMissing")],
    "ct-wrong-precision": [("CT Image", "(0028,0101)", "EnumValueNotAllowed")],
    "ct-code-missing-meaning": [("CT Image", "(0018,9346) / (0008,0104)", "TagMissing")],
    "ct-code-missing-value": [("CT Image", "(0018,9346) / (0008,0120)", "TagMissing")],
    "ct-code-equivalent-missing-meaning": [("CT Image", "(0018,9346) / (0008,0121) / (0008,0104)", "TagMissing")],
    "mr-missing-repetition": [("MR Image", "(0018,0080)", "TagMissing")],
    "mr-ep-second": [("MR Image", "(0018,0080)", "TagMissing")],
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def validate_witness(name, data_set):
    """Check the distinguishing source fact independently, including every divergence."""
    if name.startswith("ct-code-"):
        sequence = data_set.CTDIPhantomTypeCodeSequence
        if name == "ct-code-empty-phantom":
            require(len(sequence) == 0, "Missing empty Type 3 sequence witness")
            return
        require(len(sequence) == 1, "Missing single coded entry witness")
        code = sequence[0]
        require(code.CodingSchemeDesignator == "DCM" and "CodingSchemeVersion" not in code,
                "Missing unqualified scheme-version witness")
        if name == "ct-code-missing-meaning":
            require("CodeMeaning" not in code, "Missing code-meaning violation")
        elif name == "ct-code-missing-value":
            require(all(tag not in code for tag in [0x00080100, 0x00080119, 0x00080120]),
                    "Missing absent code alternatives witness")
        elif name == "ct-code-multiple-values":
            require(code.CodeValue == "113690" and code.URNCodeValue == "urn:example:synthetic:2321",
                    "Missing conflicting code alternatives witness")
        elif name == "ct-code-equivalent-missing-meaning":
            require(len(code.EquivalentCodeSequence) == 1 and "CodeMeaning" not in code.EquivalentCodeSequence[0],
                    "Missing nested code-meaning violation")
        else:
            require(code.CodeValue == "113690" and bool(code.CodeMeaning), "Missing baseline coded entry")
    elif name.endswith("wrong-high-bit"):
        require(data_set.HighBit != data_set.BitsStored - 1, "Missing high-bit contradiction")
    elif name == "ct-contradictory-units":
        require(data_set.ImageType[0] == "ORIGINAL" and data_set.ImageType[2] == "AXIAL"
                and 0x00189361 not in data_set and data_set.RescaleType != "HU", "Missing HU contradiction")
    elif name == "ct-derived-unknown-units":
        require(data_set.ImageType[0] == "DERIVED" and "RescaleType" not in data_set, "Missing unknown-unit condition")
    elif name == "mr-ir-missing-time":
        require(data_set.ScanningSequence == "IR" and "InversionTime" not in data_set, "Missing IR requirement violation")
    elif name == "mr-gating-unknown":
        require(data_set.ScanOptions == "LOCAL_GATING" and "TriggerTime" not in data_set, "Missing unknown gating condition")
    elif name == "ct-missing-rescale":
        require("RescaleSlope" not in data_set, "Missing rescale violation")
    elif name == "ct-wrong-precision":
        require(data_set.BitsStored == 11, "Missing CT precision violation")
    elif name == "mr-missing-repetition":
        require(data_set.ScanningSequence == "SE" and "RepetitionTime" not in data_set, "Missing repetition violation")
    elif name == "mr-ir-empty-time":
        require(data_set.ScanningSequence == "IR" and "InversionTime" in data_set
                and data_set.InversionTime is None, "Missing empty Type 2C witness")
    elif name in ("mr-ep-first", "mr-ep-second"):
        expected = ["EP", "GR"] if name == "mr-ep-first" else ["GR", "EP"]
        require(list(data_set.ScanningSequence) == expected and "RepetitionTime" not in data_set,
                "Missing multi-valued scanning-sequence witness")
    elif name == "mr-sk-second":
        require(data_set.ScanningSequence == "EP" and list(data_set.SequenceVariant) == ["MTC", "SK"]
                and "RepetitionTime" not in data_set, "Missing multi-valued sequence-variant witness")


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
    for filename in ["dict_info.json", "iod_info.json", "module_info.json"]:
        source_hashes[filename] = hashlib.sha256((args.standard_json / filename).read_bytes()).hexdigest()
    for filename in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / filename).read_bytes()
        require(b"2026c" in data, "Unexpected standard edition in docbook")
        source_hashes[filename] = hashlib.sha256(data).hexdigest()
    info = DicomInfo(*(json.loads((args.standard_json / filename).read_text())
                       for filename in ["dict_info.json", "iod_info.json", "module_info.json"]))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for name, (own, expected_oracle, divergence) in CASES.items():
        path = files[name]
        metadata = json.loads(path.with_suffix(".json").read_text())
        require(metadata["expectedAttributes"] == own, "Unexpected producer outcome")
        validate_witness(name, dcmread(path))
        result = validator.validate(path)[str(path)]
        require(result.status.name == expected_oracle, "Unexpected independent result for " + name)
        errors = [{"module": module, "tag": str(tag), "code": error.code.name,
                   "requirement": getattr(error.type, "value", error.type)}
                  for module, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        # Baseline acceptance means no errors anywhere in the independent IOD result.
        require(result.errors == len(errors), "Independent error count was not preserved")
        require(sorted((e["module"], e["tag"], e["code"]) for e in errors) == EXPECTED_ERRORS.get(name, []),
                "Independent diagnostics differ from the qualified expectation for " + name)
        results.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "ownAttributeOutcome": own, "independentIODOutcome": result.status.name,
                        "independentErrors": errors, "divergence": divergence})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": source_hashes,
              "scope": "CT/MR image-module corpus; complete own IOD conformance is not yet qualified",
              "agreements": sum(row[2] is None for row in CASES.values()),
              "documentedDivergences": sum(row[2] is not None for row in CASES.values()), "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} cases, {report['agreements']} agreements, "
          f"{report['documentedDivergences']} documented divergences")


if __name__ == "__main__":
    main()
