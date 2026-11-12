#!/usr/bin/env python3
"""Compare the synthetic C.18.1 numeric corpus with the pinned 2026c IOD oracle."""

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

POSITIVE = {"baseline", "empty-qualified", "rational-valid", "float-required-present"}
DIVERGENCES = {
    "empty-unqualified": "Oracle does not enforce qualifier presence for an empty Measured Value Sequence.",
    "qualifier-with-value": "Oracle does not enforce the qualifier Type 1C otherwise-absent condition.",
    "multiple-values": "Oracle uses dictionary VM 1-n without the macro's single-value restriction.",
    "rational-zero": "Oracle does not reject a zero rational denominator.",
    "rational-orphan-denominator": "Oracle permits a denominator without its conditional numerator.",
    "float-required-missing": "Oracle has no external source-precision fact to enforce the required FD value.",
}
MISSING = {
    "missing-measured": "(0040,A730) / (0040,A300)",
    "rational-missing-denominator": "(0040,A730) / (0040,A300) / (0040,A163)",
}


def witness(ds, case):
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88.22", "Unexpected SOP class")
    require(ds.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1", "Unexpected transfer syntax")
    require(len(ds.ContentSequence) == 1 and ds.ContentSequence[0].ValueType == "NUM", "Expected one NUM item")
    item = ds.ContentSequence[0]
    require(("MeasuredValueSequence" in item) == (case != "missing-measured"), "Missing sequence witness")
    qualified = case in {"empty-qualified", "qualifier-with-value"}
    require(("NumericValueQualifierCodeSequence" in item) == qualified, "Unexpected qualifier presence")
    if qualified:
        seq = item.NumericValueQualifierCodeSequence
        require(len(seq) == 1 and seq[0].CodeValue == "114007" and seq[0].CodingSchemeDesignator == "DCM",
                "Unexpected qualifier witness")
    if case == "missing-measured":
        return
    seq = item.MeasuredValueSequence
    require(len(seq) == (0 if case.startswith("empty-") else 1), "Unexpected measurement item count")
    if not seq:
        return
    value = seq[0]
    require(value[0x0040A30A].VM == (2 if case == "multiple-values" else 1), "Unexpected numeric VM")
    require(list(value.NumericValue) == [1, 2] if case == "multiple-values" else value.NumericValue == 42,
            "Unexpected numeric value witness")
    units = value.MeasurementUnitsCodeSequence
    require(len(units) == 1 and units[0].CodeValue == "mm" and units[0].CodingSchemeDesignator == "UCUM",
            "Unexpected units witness")
    has_numerator = case.startswith("rational-") and case != "rational-orphan-denominator"
    has_denominator = case.startswith("rational-") and case != "rational-missing-denominator"
    require(("RationalNumeratorValue" in value) == has_numerator, "Unexpected numerator presence")
    require(("RationalDenominatorValue" in value) == has_denominator, "Unexpected denominator presence")
    if has_numerator:
        require(value.RationalNumeratorValue == 84, "Unexpected numerator value")
    if has_denominator:
        require(value.RationalDenominatorValue == (0 if case == "rational-zero" else 2), "Unexpected denominator")
    require(("FloatingPointValue" in value) == (case == "float-required-present"), "Unexpected FD presence")
    if case == "float-required-present":
        require(value.FloatingPointValue == 42.000000000000014, "Unexpected precision witness")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS, "Unexpected oracle dependency versions")
    require(args.standard_json.parent.name == "2026c", "DICOM 2026c cache required")
    files = {p.stem: p for p in args.corpus.glob("*.dcm")}
    require(set(files) == POSITIVE | set(DIVERGENCES) | set(MISSING), "Unexpected corpus cases")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    hashes = {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        source = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in source, "Unexpected docbook edition")
        hashes[name] = hashlib.sha256(source).hexdigest()
    info = DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in names))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for case, path in sorted(files.items()):
        witness(dcmread(path), case)
        expected = "passed" if case in POSITIVE else "failed"
        combined = "incomplete" if case in POSITIVE else "failed"
        metadata = json.loads(path.with_suffix(".json").read_text())
        require(metadata == {"numericAttributes": expected, "combinedAttributes": combined,
                             "floatingPointRequired": case.startswith("float-required-")}, "Unexpected producer evidence")
        result = validator.validate(path)[str(path)]
        errors = [{"module": module, "tag": str(tag), "code": error.code.name}
                  for module, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        expected_errors = ([{"module": "SR Document Content", "tag": MISSING[case], "code": "TagMissing"}]
                           if case in MISSING else [])
        require(errors == expected_errors and result.errors == len(errors), "Changed independent diagnostics: " + case)
        require(result.status.name == ("Failed" if expected_errors else "Passed"), "Changed independent outcome")
        results.append({"case": case, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "ownNumericAttributeOutcome": expected, "ownCombinedAttributeOutcome": combined,
                        "independentIODOutcome": result.status.name, "independentErrors": errors,
                        "divergence": DIVERGENCES.get(case)})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes, "cases": results,
              "scope": "C.18.1 attribute requirements with caller-supplied precision; terminology, representation equivalence and full IOD/TID remain unqualified",
              "agreements": len(results) - len(DIVERGENCES), "documentedDivergences": len(DIVERGENCES)}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} cases, {report['agreements']} agreements, {len(DIVERGENCES)} documented divergences")


if __name__ == "__main__":
    main()
