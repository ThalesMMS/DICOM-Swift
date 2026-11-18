#!/usr/bin/env python3
"""Compare native pixel allocation with pydicom and the original-byte CLI adapters.

This is a storage-length/selected-decoder comparison, not a complete IOD oracle.
"""

import argparse
import hashlib
import importlib.metadata
import json
import warnings
from pathlib import Path

import numpy as np
from pydicom import dcmread
from pydicom.pixels import pixel_array
from pydicom.pixels.utils import get_expected_length

from image_iod_oracle import require
from instance_validation_cli_oracle import run


CASES = {"gray8", "gray12", "gray24", "gray32", "gray64", "packed1", "packed1-frame-padding", "rgb0", "rgb1",
         "ybr422", "ybr422-expanded", "ybr422-odd-columns", "ybr422-odd-rows", "float32", "float64",
         "float-forbidden", "short", "excess", "wrong-ob", "wrong-high-bit", "wrong-allocation", "forbidden-photo"}
LENGTH_ERRORS = {"packed1-frame-padding", "ybr422-expanded", "short", "excess", "wrong-ob"}
PIXEL_ERRORS = LENGTH_ERRORS | {"ybr422-odd-columns", "wrong-allocation", "forbidden-photo"}
DECODE = {"gray8", "gray12", "gray32", "gray64", "packed1", "rgb0", "rgb1", "ybr422",
          "float32", "float64", "short", "excess"}


def decode(ds, case):
    if case not in DECODE:
        return {"status": "notQualified"}
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        try:
            array = pixel_array(ds, raw=True, allow_excess_frames=False)
        except ValueError as error:
            require(case == "short" and "(2 vs 4 bytes)" in str(error), "Unexpected independent decode failure")
            return {"status": "rejectedShortPayload"}
        require(case != "short", "Short payload unexpectedly decoded")
        flat = array.ravel()
        if case.startswith("float"):
            require(flat.size == 4 and np.isnan(flat[0]) and np.isposinf(flat[1]) and np.isneginf(flat[2]) and flat[3] == 1,
                    "IEEE floating samples changed")
        else:
            expected = 1 if case == "packed1" else 4095 if case == "gray12" else (1 << int(ds.BitsAllocated)) - 1
            require(np.all(flat == expected), "Unexpected independently decoded sample values")
        require(list(array.shape) == ([3, 1, 3] if case == "packed1" else [2, 2, 3] if case in {"rgb0", "rgb1", "ybr422"} else [2, 2]),
                "Unexpected decoded shape")
        messages = [str(item.message) for item in caught]
        require(messages == (["The pixel data is 6 bytes long, which indicates it contains 2 bytes of excess padding to be removed"]
                             if case == "excess" else []), "Changed independent decoder warnings")
        return {"status": "decoded", "shape": list(array.shape), "dtype": array.dtype.name, "warnings": messages}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    versions = {name: importlib.metadata.version(name) for name in ["pydicom", "numpy"]}
    require(versions == {"pydicom": "3.0.2", "numpy": "2.5.3"}, "Unexpected oracle versions")
    require({p.stem for p in args.corpus.glob("*.dcm")} == CASES, "Unexpected corpus cases")
    results = []
    for case in sorted(CASES):
        source = args.corpus / (case + ".dcm")
        ds = dcmread(source)
        require(ds.SOPClassUID == "1.2.840.10008.5.1.4.1.1.7" and ds.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.1",
                "Unexpected carrier or transfer syntax")
        tags = [tag for tag in [0x7FE00010, 0x7FE00008, 0x7FE00009] if tag in ds]
        require(len(tags) == 1, "Unexpected pixel alternatives")
        actual = len(ds[tags[0]].value)
        # pydicom's byte-count helper truncates invalid non-byte allocations, so do not use it to qualify BitsAllocated=12.
        expected = None if case == "wrong-allocation" else get_expected_length(ds)
        padded = None if expected is None else expected + expected % 2
        if padded is not None:
            require((actual != padded) == (case in LENGTH_ERRORS), "Independent length disagreement: " + case)
        scoped = json.loads(source.with_suffix(".json").read_text())
        pixels = "failed" if case in PIXEL_ERRORS else "incomplete" if case == "ybr422-odd-rows" else "passed"
        attributes = "failed" if case in {"wrong-high-bit", "float-forbidden"} else "passed"
        require(scoped["pixels"] == pixels and scoped["attributes"] == attributes, "Unexpected producer outcomes")
        exit_code, report = run(args.binary, ["validate", source, "--composed", "--format", "json"])
        require(report["outcomes"]["pixelsAndGeometry"] == pixels and
                report["outcomes"]["attributes"] == "failed", "CLI outcome mismatch")
        require(0x00100020 not in ds and any(d["code"] == "requiredAttributeMissing" and
                d["path"] == [{"tag": {"_0": 0x00100020}}] and d["requirement"] == "2"
                for d in report["diagnostics"]), "Partial SC carrier must fail the common Patient ID requirement")
        require(exit_code == (1 if "failed" in report["outcomes"].values() else 2), "Wrong composed exit")
        codec_exit, codec = run(args.binary, ["codec", "validate", source, "--format", "json"])
        require(codec["conformance"] == report and codec_exit == (0 if codec["success"] else 65), "Codec adapter mismatch")
        results.append({"case": case, "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
                        "actualValueBytes": actual, "pydicomExpectedBytesWithoutPadding": expected,
                        "outcomes": report["outcomes"], "independentDecode": decode(ds, case)})
    args.output.write_text(json.dumps({"versions": versions,
        "binarySHA256": hashlib.sha256(args.binary.read_bytes()).hexdigest(), "caseCount": len(results), "cases": results,
        "scope": "Native allocation/length, selected decoded samples and CLI parity; no complete SC IOD, geometry, palette or display qualification.",
        "gaps": ["pydicom length helper does not validate allocation, VR, HighBit, floating forbidden attributes or photometric constraints.",
                 "pydicom accepts excess bytes with a warning; sender conformance rejects the original length.",
                 "Odd YBR_FULL_422 rows remain incomplete because PS3.3's row example conflicts with horizontal-only subsampling.",
                 "24-bit and malformed metadata cases are length witnesses only; decoder support is not implied."]},
        indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} native allocation/CLI cases; {len(DECODE)} independent decoder cases", flush=True)


if __name__ == "__main__":
    main()
