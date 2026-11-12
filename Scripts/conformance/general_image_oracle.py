#!/usr/bin/env python3
"""Compare General Image rules in synthetic SC carriers, preserving oracle gaps."""

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


PASSED = {"baseline", "image-type-valid", "qc-both", "lut-identity", "icon-129"}
ERRORS = {
    "missing-instance-number": [("General Image", "(0020,0013)", "TagMissing")],
    "burned-invalid": [("General Image", "(0028,0301)", "EnumValueNotAllowed")],
    "lossy-invalid": [("General Image", "(0028,2110)", "EnumValueNotAllowed")],
    "qc-invalid": [("General Image", "(0028,0300)", "EnumValueNotAllowed")],
}
GAPS = {
    "missing-orientation": "Oracle does not enforce SC Patient Orientation when Image Plane is absent.",
    "orientation-invalid": "Oracle does not parse the directional abbreviations.",
    "image-type-reversed": "Oracle does not constrain the first two Image Type positions.",
    "lut-contradiction": "Oracle does not compare LUT Shape with Photometric Interpretation.",
    "ratio-count": "Oracle does not compare compression ratio and method counts.",
    "icon-empty": "Oracle accepts an empty optional Icon Image Sequence.",
    "icon-two": "Oracle does not enforce the single icon item constraint.",
}
CASES = PASSED | set(ERRORS) | set(GAPS)


def witness(name, ds):
    require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.7", "Wrong carrier IOD")
    require(ds.pixel_array.tolist() == [[1, 2], [3, 4]], "Changed independently decoded samples")
    if name == "missing-orientation":
        require(all(tag not in ds for tag in [0x00200020, 0x00200032, 0x00200037]), "Missing orientation witness")
    elif name == "orientation-invalid":
        require(list(ds.PatientOrientation) == ["LEFT", "POSTERIOR"], "Missing lexical orientation witness")
    elif name == "image-type-reversed":
        require(list(ds.ImageType) == ["PRIMARY", "ORIGINAL"], "Missing positional enum witness")
    elif name == "image-type-valid":
        require(list(ds.ImageType) == ["DERIVED", "SECONDARY", "", "PRIVATE"], "Changed trailing Image Type values")
    elif name == "lut-contradiction":
        require(ds.PresentationLUTShape == "INVERSE" and ds.PhotometricInterpretation == "MONOCHROME2",
                "Missing photometric LUT contradiction")
    elif name == "ratio-count":
        require(list(ds.LossyImageCompressionRatio) == [3, 5] and ds.LossyImageCompressionMethod == "ISO_10918_1",
                "Missing ratio/method count contradiction")
    elif name.startswith("icon-"):
        icons = ds.IconImageSequence
        require(len(icons) == {"icon-129": 1, "icon-empty": 0, "icon-two": 2}[name], "Wrong icon cardinality")
        for icon in icons:
            icon.file_meta = ds.file_meta
            pixels = icon.pixel_array
            require(pixels.shape == (129, 129) and bool((pixels == 1).all()), "Changed independently decoded icon")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in VERSIONS}
    require(versions == VERSIONS and args.standard_json.parent.name == "2026c", "Unexpected oracle/standard versions")
    require({p.stem for p in args.corpus.glob("*.dcm")} == CASES, "Missing or unexpected cases")
    filenames = ["dict_info.json", "iod_info.json", "module_info.json"]
    info = DicomInfo(*(json.loads((args.standard_json / name).read_text()) for name in filenames))
    validator = DicomFileValidator(info, log_level=logging.CRITICAL)
    results = []
    for name in sorted(CASES):
        path = args.corpus / (name + ".dcm")
        own = json.loads(path.with_suffix(".json").read_text())
        expected = "passed" if name in PASSED else "failed"
        require(own == {"attributes": expected, "instanceAttributes": "incomplete" if expected == "passed" else "failed",
                        "temporallyRelatedSeries": "unsatisfied"}, "Changed component/instance outcome: " + name)
        witness(name, dcmread(path))
        result = validator.validate(path)[str(path)]
        errors = sorted((module, str(tag), error.code.name) for module, tags in (result.module_errors or {}).items()
                        for tag, error in tags.items())
        require(errors == sorted(ERRORS.get(name, [])) and result.errors == len(errors), "Changed independent diagnostics: " + name)
        require(result.status.name == ("Failed" if errors else "Passed"), "Changed independent outcome")
        results.append({"case": name, "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), **own,
                        "independentOutcome": result.status.name, "errors": errors, "gap": GAPS.get(name)})
    args.output.write_text(json.dumps({"versions": {**versions, "numpy": importlib.metadata.version("numpy")},
        "standardSHA256": {name: hashlib.sha256((args.standard_json / name).read_bytes()).hexdigest() for name in filenames},
        "scope": "General Image attributes and native icon samples in SC carriers; not a complete IOD qualification.",
        "cases": results}, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} General Image cases, exact independent diagnostics, 16 image and 3 icon decodes")


if __name__ == "__main__":
    main()
