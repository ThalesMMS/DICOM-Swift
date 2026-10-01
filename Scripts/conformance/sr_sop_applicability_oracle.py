#!/usr/bin/env python3
"""Audit SR reference roles against the pinned IOD catalogue and independent wire witnesses.

The target files contain synthetic identity metadata only: they are not complete
storage IOD fixtures or evidence of payload/decoder support for these 171 classes.
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
from image_iod_oracle import VERSIONS, require

PREFIX = "1.2.840.10008.5.1.4.1.1."
UNKNOWN = [PREFIX + "2.999", "2.25.23219999"]
KINDS = ["IMAGE", "WAVEFORM", "COMPOSITE"]


def traits(iod):
    modules = iod["modules"]
    image = any(name in modules for name in ["Image Pixel", "Floating Point Image Pixel", "Double Floating Point Image Pixel"])
    waveform = "Waveform" in modules
    require(not (image and waveform), "Ambiguous IOD reference kind")
    title = iod["title"]
    multiframe = [modules[name] for name in ["Multi-frame", "Multi-frame Functional Groups", "Sparse Multi-frame Functional Groups"] if name in modules]
    return {"kind": "IMAGE" if image else "WAVEFORM" if waveform else "COMPOSITE",
            "softcopy": "Softcopy Presentation State" in title or title == "Advanced Blending Presentation State IOD",
            "realWorldMap": title == "Real World Value Mapping IOD",
            "multiframe": "satisfied" if image and any(m["use"].startswith("M") for m in multiframe) else
                          "undetermined" if image and multiframe else "unsatisfied",
            "segmentation": any(name in modules for name in ["Segmentation Image", "Height Map Segmentation Image"])}


def content_facts(known):
    if known is None:
        return {}
    return {"multiframe": known["multiframe"], "segmentation": "satisfied" if known["segmentation"] else "unsatisfied",
            "multipleChannels": "undetermined" if known["kind"] == "WAVEFORM" else "unsatisfied",
            "allFrames": "undetermined", "allSegments": "undetermined", "allChannels": "undetermined"}


def witness(path, kind, uid, auxiliary):
    source = dcmread(path)
    require(source.SOPClassUID == PREFIX + "88.33", "Unexpected source class")
    require(source.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1", "Unexpected transfer syntax")
    require(len(source.ContentSequence) == 1 and source.ContentSequence[0].ValueType == kind, "Wrong content role")
    require(len(source.ContentSequence[0].ReferencedSOPSequence) == 1, "Wrong primary cardinality")
    primary = source.ContentSequence[0].ReferencedSOPSequence[0]
    require(primary.ReferencedSOPClassUID == (PREFIX + "2.1" if auxiliary else uid) and
            primary.ReferencedSOPInstanceUID == "2.25.23212003", "Wrong primary identity")
    require({tag for tag in [0x00081199, 0x0008114B] if tag in primary} ==
            ({auxiliary} if auxiliary else set()), "Wrong companion placement")
    pairs = [primary]
    if auxiliary:
        require(primary[auxiliary].VR == "SQ" and len(primary[auxiliary].value) == 1, "Wrong companion shape")
        companion = primary[auxiliary].value[0]
        require(companion.ReferencedSOPClassUID == uid and companion.ReferencedSOPInstanceUID == "2.25.23217007",
                "Wrong companion identity")
        pairs.append(companion)
    studies = source.CurrentRequestedProcedureEvidenceSequence
    require(len(studies) == 1 and studies[0].StudyInstanceUID == "2.25.23212001", "Wrong evidence study")
    series = studies[0].ReferencedSeriesSequence
    require(len(series) == 1 and series[0].SeriesInstanceUID == "2.25.23212002", "Wrong evidence series")
    evidence = series[0].ReferencedSOPSequence
    require(len(evidence) == len(pairs), "Wrong evidence cardinality")
    for index, pair in enumerate(pairs):
        require(evidence[index].ReferencedSOPClassUID == pair.ReferencedSOPClassUID and
                evidence[index].ReferencedSOPInstanceUID == pair.ReferencedSOPInstanceUID, "Contradictory evidence identity")
        suffix = ".target.dcm" if index == 0 else ".companion.dcm"
        target = dcmread(path.with_suffix(suffix))
        require(target.SOPClassUID == pair.ReferencedSOPClassUID and target.SOPInstanceUID == pair.ReferencedSOPInstanceUID and
                target.StudyInstanceUID == studies[0].StudyInstanceUID and target.SeriesInstanceUID == series[0].SeriesInstanceUID,
                "Target identity does not match reference/evidence")
        require(set(target.keys()) == {0x00080016, 0x00080018, 0x0020000D, 0x0020000E}, "Target must be an identity-only witness")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS, "Unexpected oracle dependency versions")
    require(args.standard_json.parent.name == "2026c", "DICOM 2026c cache required")
    names = ["dict_info.json", "iod_info.json", "module_info.json"]
    standard = {name: json.loads((args.standard_json / name).read_text()) for name in names}
    hashes = {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in names}
    for name in ["part03.xml", "part04.xml", "part06.xml"]:
        data = (args.standard_json.parent / "docbook" / name).read_bytes()
        require(b"2026c" in data, "Unexpected DocBook edition")
        hashes[name] = hashlib.sha256(data).hexdigest()
    expected_traits = {uid: traits(iod) for uid, iod in standard["iod_info.json"].items()}
    require(len(expected_traits) == 171, "Changed audited catalogue")
    require(sum(t["softcopy"] for t in expected_traits.values()) == 7 and
            sum(t["realWorldMap"] for t in expected_traits.values()) == 1, "Changed accompanying class catalogue")
    require(json.loads((args.corpus / "catalogue.json").read_text()) == expected_traits, "Swift catalogue disagrees with normative IOD tables")
    cases = [(kind, uid, None) for uid in sorted(expected_traits) + UNKNOWN for kind in KINDS]
    cases += [("IMAGE", PREFIX + suffix, 0x00081199) for suffix in ["11.1", "11.2", "11.3", "11.4", "11.5", "11.8", "11.12",
              "2", "67", "11.6", "11.7", "11.9", "11.10", "11.11", "9.100.1", "9.100.2"]]
    cases += [("IMAGE", PREFIX + "67", 0x0008114B), ("IMAGE", PREFIX + "11.1", 0x0008114B),
              ("IMAGE", UNKNOWN[0], 0x00081199), ("IMAGE", UNKNOWN[1], 0x0008114B)]
    files = {"catalogue.json"}
    for index, (_, _, auxiliary) in enumerate(cases):
        files.update(f"sop-{index}" + suffix for suffix in [".dcm", ".json", ".target.dcm"])
        if auxiliary:
            files.add(f"sop-{index}.companion.dcm")
    require({p.name for p in args.corpus.iterdir() if p.is_file()} == files, "Missing or unexpected corpus files")
    validator = DicomFileValidator(DicomInfo(*(standard[name] for name in names)), log_level=logging.CRITICAL)
    results = []
    for index, (kind, uid, auxiliary) in enumerate(cases):
        path = args.corpus / f"sop-{index}.dcm"
        witness(path, kind, uid, auxiliary)
        known = expected_traits.get(uid)
        allowed = known and (known["softcopy" if auxiliary == 0x00081199 else "realWorldMap"] if auxiliary else known["kind"] == kind)
        expected = "incomplete" if known is None else "passed" if allowed else "failed"
        code = [] if expected == "passed" else ["referenceRuleUnavailable" if known is None else "referenceSOPClassNotAllowed"]
        require(json.loads(path.with_suffix(".json").read_text()) ==
                {"references": expected, "diagnostics": code, "structureAndVRVM": "passed",
                 "contentFacts": content_facts(expected_traits[PREFIX + "2.1"] if auxiliary else known if allowed else None)}, "Wrong runtime result for " + str(index))
        result = validator.validate(path)[str(path)]
        errors = [{"module": module, "tag": str(tag), "code": error.code.name}
                  for module, tags in (result.module_errors or {}).items() for tag, error in tags.items()]
        expected_errors = [] if auxiliary is None else [{"module": "SR Document Content", "code": "TagUnexpected",
            "tag": f"(0040,A730) / (0008,1199) / ({auxiliary >> 16:04X},{auxiliary & 0xffff:04X})"}]
        require(errors == expected_errors and result.errors == len(expected_errors) and
                result.status.name == ("Failed" if auxiliary else "Passed"), "Changed whole-IOD oracle result for " + str(index))
        gap = ("Oracle loses accompanying macro nesting; the unexpected-tag error does not check SOP class applicability." if auxiliary else
               "Whole-IOD oracle does not check the referenced SOP class against the content role." if expected != "passed" else None)
        results.append({"case": index, "role": kind, "auxiliaryTag": auxiliary, "sopClass": uid,
                        "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(), "ownReferences": expected,
                        "independentIODOutcome": result.status.name, "independentErrors": errors, "limitation": gap})
    report = {"standardEdition": "2026c", "versions": versions, "sourceHashes": hashes,
              "scope": "Reference class applicability only; targets witness identity, not full IOD/payload conformance.",
              "cataloguedClasses": len(expected_traits), "classCounts": {k: sum(t["kind"] == k for t in expected_traits.values()) for k in KINDS},
              "independentRoleWitnesses": len(results), "wholeIODAgreements": sum(r["limitation"] is None for r in results),
              "documentedWholeIODGaps": sum(r["limitation"] is not None for r in results), "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(expected_traits)} audited classes, {len(results)} role witnesses, "
          f"{report['wholeIODAgreements']} whole-IOD agreements, {report['documentedWholeIODGaps']} documented gaps")


if __name__ == "__main__":
    main()
