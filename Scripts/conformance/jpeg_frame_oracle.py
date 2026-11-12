#!/usr/bin/env python3
"""Compare the synthetic JPEG header corpus with pinned pydicom, without claiming entropy/IOD validation."""

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path

from pydicom import dcmread
from pydicom.encaps import generate_frames
from pydicom.pixels.utils import _get_jpg_parameters
from image_iod_oracle import require

CASES = {"baseline", "extended8", "extended12", "lossless8", "lossless12", "lossless16", "predictor7",
         "wrong-predictor", "wrong-sof0", "wrong-sof1", "wrong-precision", "wrong-rows", "wrong-components",
         "color", "truncated", "extra-frame"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-docbook", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    standard = args.standard_docbook.read_bytes()
    require(b"DICOM PS3.5 2026c" in standard and b'label="8.2.1"' in standard, "Wrong normative edition")
    require({p.name for p in args.corpus.iterdir() if p.is_file()} == {case + suffix for case in CASES for suffix in [".dcm", ".json"]}, "Wrong corpus files")
    results = []
    for name in sorted(CASES):
        path = args.corpus / (name + ".dcm")
        source = dcmread(path)
        syntax = "50" if name in {"baseline", "wrong-sof1"} else "51" if name in {"extended8", "extended12", "wrong-sof0"} else "57" if name == "predictor7" else "70"
        require(source.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.4." + syntax, "Wrong syntax witness")
        require(source[0x7FE00010].VR == "OB" and source[0x7FE00010].is_undefined_length, "Wrong encapsulation")
        frames = list(generate_frames(source.PixelData, number_of_frames=1))
        require(len(frames) == 1, "Wrong frame count")
        actual = _get_jpg_parameters(frames[0])
        precision = 16 if name == "lossless16" else 12 if name in {"extended12", "lossless12", "wrong-precision"} else 8
        count = 3 if name in {"color", "wrong-components"} else 1
        expected = {"width": 8, "height": 8, "precision": precision, "components": count, "component_ids": list(range(1, count + 1))}
        require(expected.keys() <= actual.keys() and {key: actual[key] for key in expected} == expected,
                "Changed independent header evidence: " + name)
        require(source.Rows == (9 if name == "wrong-rows" else 8) and source.Columns == 8 and
                source.BitsStored == (8 if name == "wrong-precision" else precision) and
                source.SamplesPerPixel == (3 if name == "color" else 1), "Wrong metadata witness: " + name)
        malformed = name in {"truncated", "extra-frame"}
        profile = name in {"wrong-predictor", "wrong-sof0", "wrong-sof1"}
        mismatch = name in {"wrong-precision", "wrong-rows", "wrong-components"}
        # Lossless, extended and (since #2326) baseline/progressive frames are decoded by own decoders; no payload stays unverified.
        unverified = False
        diagnostics = ["invalidCodestream", "valueUnavailable"] if malformed else \
            (["codestreamProfileMismatch"] if profile else []) + (["pixelMetadataContradiction"] if mismatch else []) + \
            (["codestreamColorProfileUnavailable"] if count == 3 else []) + (["codestreamPayloadUnverified"] if unverified else [])
        expected_report = {"attributes": "passed", "codestream": "failed" if malformed or profile else "incomplete" if unverified else "passed",
                           "pixels": "failed" if mismatch else "incomplete" if malformed or name == "color" else "passed",
                           "diagnostics": diagnostics}
        require(json.loads(path.with_suffix(".json").read_text()) == expected_report, "Changed scoped report: " + name)
        results.append({"case": name, "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(), "pydicomHeader": expected,
                        "own": expected_report, "boundaryOracleGap": malformed})
    report = {"standardEdition": "2026c", "standardSHA256": hashlib.sha256(standard).hexdigest(), "pydicomVersion": version,
              "headerAgreements": len(results), "boundaryOracleGaps": 2,
              "scope": "SOF precision, dimensions and components only. Pydicom header extraction does not check SOS prediction, transfer syntax, EOI, entropy or full IOD. The engine decodes lossless and extended frames natively (entropy verified); XCTest separately cross-decodes valid lossless frames with JLISwift 0.5.0.",
              "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} independent header witnesses; 2 boundary oracle gaps retained")


if __name__ == "__main__":
    main()
