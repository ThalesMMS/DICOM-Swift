#!/usr/bin/env python3
"""Witness SR base item requirements without hiding external-condition or macro gaps."""

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

POSITIVE = {"text-valid", "text-crlf", "date-valid", "time-valid", "datetime-valid", "pname-valid", "uidref-valid",
            "heading-not-required-absent", "heading-required-present", "purpose-not-required-absent", "purpose-required-present",
            "observation-optional-present", "observation-required-present", "template-valid",
            # C.17.3 2026c: a heading or reference purpose is evidenced by the concept name itself and a non-root
            # template identification by its own presence when template requirements are undetermined; in that
            # case presence is never forbidden and absence needs no fact.
            "heading-not-required-present", "purpose-not-required-present", "heading-unknown", "purpose-unknown", "template-unknown"}
UNKNOWN = {"observation-unknown"}
MISSING = {"text-missing", "heading-required-missing", "purpose-required-missing", "observation-required-missing", "template-required-missing"}
FORBIDDEN = {"text-with-date", "date-with-text", "template-not-required-present"}
TEXT_ERRORS = {"text-tab", "text-formfeed", "text-lf", "text-cr"}
BYREF = {"byref-temporal": 0x0040A130, "byref-spatial": 0x30060024, "byref-table": 0x0040A801}
OTHER = {"text-empty", "observation-required-empty", "template-empty", "template-multiple", "template-leading-zero",
         "template-prefixed", "template-missing-id", "template-missing-resource"}
AGREED_FAILURES = {"text-missing": ("(0040,A160)", "TagMissing"), "text-empty": ("(0040,A160)", "TagEmpty"),
                   "observation-required-empty": ("(0040,A032)", "TagEmpty"), "template-empty": ("(0040,A504)", "TagEmpty"),
                   "template-missing-id": ("(0040,A504) / (0040,DB00)", "TagMissing"),
                   "template-missing-resource": ("(0040,A504) / (0008,0105)", "TagMissing")}


def expected_diagnostics(case):
    codes = [("conditionUndetermined", "1C")] if case in UNKNOWN else [("requiredAttributeMissing", "1C")] if case in MISSING else []
    if case in FORBIDDEN or case in BYREF:
        codes = [("conditionalAttributeForbidden", "3" if case in BYREF else "1C")]
    elif case in TEXT_ERRORS:
        codes = [("attributeValueNotAllowed", "1C")]
    elif case in {"text-empty", "observation-required-empty", "template-empty"}:
        codes = [("requiredValueEmpty", "1C")]
    elif case in {"template-leading-zero", "template-prefixed"}:
        codes = [("attributeValueNotAllowed", "1")]
    elif case in {"template-missing-id", "template-missing-resource"}:
        codes = [("requiredAttributeMissing", "1")]
    if case == "template-missing-resource":
        codes.append(("valueUnavailable", "1"))
    if case in {"template-empty", "template-multiple"}:
        codes.append(("sequenceItemCountInvalid", "1C"))
    return [{"code": code, "requirement": requirement} for code, requirement in codes]


def witness(case, ds):
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.88.33" and ds.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1", "Wrong SOP class or syntax")
    require(ds.ValueType == "CONTAINER", "Wrong root type")
    require(len(ds.ContentSequence) == (2 if case in BYREF else 1), "Wrong content cardinality")
    facts = {"heading": "satisfied", "purpose": "satisfied", "observationDiffers": "unsatisfied", "templateRequired": "unsatisfied"}
    if case in BYREF:
        require(ds.ContentSequence[0].ValueType == "IMAGE" and ds.ContentSequence[1].ValueType == "TEXT", "Wrong relationship source/target")
        require(len(ds.ContentSequence[1].ContentSequence) == 1, "Wrong reference cardinality")
        child = ds.ContentSequence[1].ContentSequence[0]
        require(list(child.ReferencedContentItemIdentifier) == [1, 1] and child.RelationshipType == "INFERRED FROM", "Wrong by-reference edge")
        require(set(child.keys()) == {0x0040DB73, 0x0040A010, BYREF[case]}, "Wrong forbidden macro witness")
        if case == "byref-temporal":
            require(child.TemporalRangeType == "POINT", "Wrong temporal witness")
        elif case == "byref-spatial":
            require(child.ReferencedFrameOfReferenceUID == "2.25.23219001", "Wrong spatial witness")
        else:
            require(child[0x0040A801].VR == "SQ" and len(child[0x0040A801].value) == 1, "Wrong table witness")
        return facts
    child = ds.ContentSequence[0]
    require(child.RelationshipType == "CONTAINS", "Wrong relationship type")
    kind = "CONTAINER" if case.startswith(("heading-", "template-")) else "IMAGE" if case.startswith("purpose-") else \
           "DATE" if case.startswith("date-") else case.split("-")[0].upper() if case in {"time-valid", "datetime-valid", "pname-valid", "uidref-valid"} else "TEXT"
    require(child.ValueType == kind, "Wrong content type")
    if kind == "CONTAINER":
        require(child.ContinuityOfContent == "SEPARATE", "Wrong continuity")
    if kind == "IMAGE":
        require(len(child.ReferencedSOPSequence) == 1 and
                child.ReferencedSOPSequence[0].ReferencedSOPClassUID == "1.2.840.10008.5.1.4.1.1.2.1" and
                child.ReferencedSOPSequence[0].ReferencedSOPInstanceUID == "2.25.23212003", "Wrong image pair")
    concept_present = not (case.startswith(("heading-", "purpose-")) and
                          case.endswith(("missing", "absent", "unknown")))
    require(("ConceptNameCodeSequence" in child) == concept_present, "Wrong concept-name condition witness")
    if concept_present:
        require(len(child.ConceptNameCodeSequence) == 1 and child.ConceptNameCodeSequence[0].CodingSchemeDesignator == "DCM" and
                child.ConceptNameCodeSequence[0].CodeValue == "126000" and "CodingSchemeVersion" not in child.ConceptNameCodeSequence[0], "Wrong code/version witness")
    if case.startswith(("heading-", "purpose-")):
        fact = "undetermined" if case.endswith("unknown") else "unsatisfied" if "not-required" in case else "satisfied"
        facts.update(heading=fact, purpose=fact)
    expected_values = {}
    if kind == "TEXT" or case == "date-with-text":
        if case != "text-missing":
            expected_values[0x0040A160] = {"text-empty": None, "text-crlf": "LINE ONE\r\nLINE TWO", "text-tab": "A\tB",
                "text-formfeed": "A\fB", "text-lf": "A\nB", "text-cr": "A\rB"}.get(case, "SYNTHETIC")
    for value_type, tag, value in [("DATE", 0x0040A121, "20260908"), ("TIME", 0x0040A122, "140000"),
                                  ("DATETIME", 0x0040A120, "20260908140000"), ("PNAME", 0x0040A123, "SYNTHETIC^OBSERVER"),
                                  ("UIDREF", 0x0040A124, "2.25.23219001")]:
        if kind == value_type or (tag == 0x0040A121 and case == "text-with-date"):
            expected_values[tag] = value
    scalar_tags = {0x0040A160, 0x0040A120, 0x0040A121, 0x0040A122, 0x0040A123, 0x0040A124}
    require({tag for tag in scalar_tags if tag in child} == set(expected_values), "Wrong scalar presence")
    for tag, expected in expected_values.items():
        actual = child[tag].value
        require((not actual) if expected is None else str(actual) == expected, "Wrong scalar bytes")
    observed = {"observation-required-present": "20260908130000", "observation-optional-present": "20260908120000", "observation-required-empty": None}
    require((0x0040A032 in child) == (case in observed), "Wrong observation presence")
    if case in observed:
        require(child[0x0040A032].value in (None, "") if observed[case] is None else
                str(child[0x0040A032].value) == observed[case], "Wrong observation datetime")
    if case.startswith("observation-"):
        facts["observationDiffers"] = "undetermined" if case.endswith("unknown") else "unsatisfied" if "optional" in case else "satisfied"
    template_present = case.startswith("template-") and case not in {"template-required-missing", "template-unknown"}
    require((0x0040A504 in child) == template_present, "Wrong template presence")
    if case.startswith("template-"):
        facts["templateRequired"] = "undetermined" if case.endswith("unknown") else "unsatisfied" if "not-required" in case else "satisfied"
    if template_present:
        items = child.ContentTemplateSequence
        require(len(items) == (0 if case == "template-empty" else 2 if case == "template-multiple" else 1), "Wrong template cardinality")
        for item in items:
            require(("MappingResource" in item) == (case != "template-missing-resource") and
                    ("TemplateIdentifier" in item) == (case != "template-missing-id"), "Wrong template pair presence")
            if "MappingResource" in item:
                require(item[0x00080105].VR == "CS" and item.MappingResource == "DCMR", "Wrong mapping resource")
            if "TemplateIdentifier" in item:
                require(item[0x0040DB00].VR == "CS" and item.TemplateIdentifier ==
                        {"template-leading-zero": "01500", "template-prefixed": "TID 1500"}.get(case, "1500"), "Wrong template identifier")
    return facts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Wrong oracle/standard version")
    cases = POSITIVE | UNKNOWN | MISSING | FORBIDDEN | TEXT_ERRORS | BYREF.keys() | OTHER
    require(len(cases) == 43 and {p.name for p in args.corpus.iterdir() if p.is_file()} ==
            {case + suffix for case in cases for suffix in [".dcm", ".json"]}, "Unexpected corpus files")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    hashes = {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in data, "Wrong DocBook edition")
        hashes[name] = hashlib.sha256(data).hexdigest()
    validator = DicomFileValidator(DicomInfo(*(json.loads((args.standard_json / n).read_text()) for n in names)), log_level=logging.CRITICAL)
    results = []
    for case in sorted(cases):
        path = args.corpus / (case + ".dcm")
        facts = witness(case, dcmread(path))
        expected = "passed" if case in POSITIVE else "incomplete" if case in UNKNOWN else "failed"
        own = expected_diagnostics(case)
        require(json.loads(path.with_suffix(".json").read_text()) == {"attributes": expected, "conditions": facts,
                "schemeVersionRequired": {"DCM": False}, "structureAndVRVM": "passed", "diagnostics": own}, "Wrong producer result/condition witness: " + case)
        result = validator.validate(path)[str(path)]
        errors = [{"module": m, "tag": str(t), "code": e.code.name} for m, tags in (result.module_errors or {}).items() for t, e in tags.items()]
        expected_errors = []
        if case in AGREED_FAILURES:
            tag, code = AGREED_FAILURES[case]
            expected_errors = [{"module": "SR Document Content", "tag": "(0040,A730) / " + tag, "code": code}]
        if case in BYREF:
            expected_errors = [{"module": "SR Document Content", "tag": "(0040,A730) / (0040,A730) / " + tag, "code": code}
                for tag, code in [("(0040,A040)", "TagMissing"), ("(0040,A160)", "TagMissing"),
                                  (f"({BYREF[case] >> 16:04X},{BYREF[case] & 0xffff:04X})", "TagUnexpected")]]
        require(errors == expected_errors and result.errors == len(errors) and result.status.name == ("Failed" if errors else "Passed"),
                "Changed whole-IOD oracle diagnostics: " + case)
        gap = None
        if case in BYREF:
            gap = "Oracle rejects the extra tag but also wrongly applies by-value macros to the reference; not complete diagnostic agreement."
        elif case not in POSITIVE and case not in AGREED_FAILURES:
            gap = "Oracle does not resolve the explicit external condition or enforce this scalar/text/template restriction."
        results.append({"case": case, "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "conditionSHA256": hashlib.sha256(path.with_suffix(".json").read_bytes()).hexdigest(),
                        "ownAttributes": expected, "ownDiagnostics": own, "conditions": facts,
                        "wholeIODOutcome": result.status.name, "wholeIODDiagnostics": errors, "limitation": gap})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes,
              "scope": "Base SR item requirements, scalar text and template identification; full typed values, TIDs and IODs remain separate.",
              "independentWitnesses": len(results), "wholeIODAgreements": sum(r["limitation"] is None for r in results),
              "documentedWholeIODGaps": sum(r["limitation"] is not None for r in results), "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} item witnesses, {report['wholeIODAgreements']} whole-IOD agreements, {report['documentedWholeIODGaps']} documented gaps")


if __name__ == "__main__":
    main()
