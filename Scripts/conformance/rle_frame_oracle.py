#!/usr/bin/env python3
"""Verify synthetic Annex G frames with exact byte witnesses and the independent pydicom RLE decoder."""

import argparse
import hashlib
import importlib.metadata
import json
import struct
import warnings
from pathlib import Path

from pydicom import dcmread
from pydicom.encaps import generate_frames
from pydicom.pixels.decoders.rle import _rle_decode_frame
from image_iod_oracle import require

CASES = {"gray8", "gray16", "gray12-signed", "mono1", "binary", "palette8", "palette16", "rgb8-planar0", "rgb8-planar1",
         "rgb16", "ybr8", "ybr16", "segment-count", "row-cross", "literal-triple", "odd-segment16", "trailing", "unused-offset", "nonbinary", "bits-stored"}
GAPS = {"binary", "nonbinary", "row-cross", "literal-triple", "odd-segment16", "trailing", "unused-offset", "bits-stored"}


def witness(case, source, frame):
    require(source.file_meta.TransferSyntaxUID == "1.2.840.10008.1.2.5" and source[0x7FE00010].VR == "OB" and
            source[0x7FE00010].is_undefined_length, "Wrong syntax/encapsulation")
    color = case.startswith(("rgb", "ybr")) or case == "segment-count"
    binary = case in {"binary", "nonbinary"}
    bits = 1 if binary else 16 if "16" in case or case == "gray12-signed" else 8
    stored = 12 if case == "gray12-signed" else 17 if case == "bits-stored" else bits
    photo = "RGB" if case.startswith("rgb") or case == "segment-count" else "YBR_FULL" if case.startswith("ybr") else \
            "PALETTE COLOR" if case.startswith("palette") else "MONOCHROME1" if case == "mono1" else "MONOCHROME2"
    require(source.Rows == (1 if case == "literal-triple" else 2) and source.Columns == (3 if case == "literal-triple" else 2) and
            source.SamplesPerPixel == (3 if color else 1) and source.BitsAllocated == bits and source.BitsStored == stored and
            source.HighBit == stored - 1 and source.PixelRepresentation == (1 if case == "gray12-signed" else 0) and
            source.PhotometricInterpretation == photo and source.get("PlanarConfiguration") == (1 if case == "rgb8-planar1" else 0 if color else None),
            "Wrong metadata witness: " + case)
    count = 1 if case == "segment-count" else (3 if color else 1) * ((bits + 7) // 8)
    segment = bytes([3, 1, 2, 3, 4, 0]) if case == "row-cross" else bytes([2, 7, 7, 7]) if case == "literal-triple" else \
              bytes([1, 1, 2, 0, 3, 0, 4]) if case == "odd-segment16" else bytes([1, 0, 2 if case == "nonbinary" else 1, 1, 1, 0]) if binary else bytes([1, 1, 2, 1, 3, 4])
    header = [count] + [64 + index * len(segment) for index in range(count)] + [0] * (15 - count)
    if case == "unused-offset": header[2] = 66
    expected = struct.pack("<16I", *header) + segment * count + (bytes([0, 9]) if case == "trailing" else b"")
    require(frame == expected, "Wrong encoded header/packet/plane witness: " + case)
    diagnostics = {
        "segment-count": ["pixelMetadataContradiction"], "row-cross": ["codestreamRowBoundaryViolation"],
        "literal-triple": ["codestreamReplicateRunRequired"], "odd-segment16": ["codestreamSegmentPaddingMissing"],
        "trailing": ["invalidCodestream", "valueUnavailable"],
        "unused-offset": ["invalidCodestream", "valueUnavailable"], "nonbinary": ["pixelMetadataContradiction"],
        "bits-stored": ["attributeValueNotAllowed", "attributeValueContradiction"],
    }.get(case, [])
    own = {"structure": "passed", "metadataVRVM": "passed", "wireVRVM": "incomplete", "diagnostics": diagnostics,
           "attributes": "failed" if case == "bits-stored" else "passed",
           "codestream": "failed" if case in {"row-cross", "literal-triple", "odd-segment16", "trailing", "unused-offset"} else "passed",
           "pixels": "failed" if case in {"segment-count", "nonbinary"} else "incomplete" if case in {"trailing", "unused-offset"} else "passed"}
    with warnings.catch_warnings(record=True) as caught:
        try:
            decoded = _rle_decode_frame(frame, int(source.Rows), int(source.Columns), int(source.SamplesPerPixel), bits)
            outcome = {"status": "decoded", "bytes": list(decoded), "warnings": [str(item.message) for item in caught]}
        except (ValueError, NotImplementedError) as error:
            outcome = {"status": type(error).__name__, "message": str(error)}
    if binary:
        require(outcome == {"status": "NotImplementedError", "message": "Unable to decode RLE encoded pixel data with 1 bits allocated"}, "Changed binary oracle limitation")
    elif case == "segment-count":
        require(outcome == {"status": "ValueError", "message": "The number of RLE segments in the pixel data doesn't match the expected amount (1 vs. 3 segments)"}, "Changed segment-count failure")
    else:
        expected_pixels = [7, 7, 7] if case == "literal-triple" else [value for value in [1, 2, 3, 4] for _ in range(bits // 8)] * (3 if color else 1)
        expected_warnings = ["The decoded RLE segment contains non-conformant padding - 5 vs. 4 bytes expected"] if case == "trailing" else []
        require(outcome == {"status": "decoded", "bytes": expected_pixels, "warnings": expected_warnings}, "Changed independent decode: " + case)
    return own, outcome


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--standard-docbook", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    version = importlib.metadata.version("pydicom")
    require(version == "3.0.2", "Wrong pydicom version")
    standard = args.standard_docbook.read_bytes()
    require(b"DICOM PS3.5 2026c" in standard and b'label="G.5"' in standard, "Wrong normative edition")
    require({p.name for p in args.corpus.iterdir() if p.is_file()} == {case + suffix for case in CASES for suffix in [".dcm", ".json"]}, "Wrong corpus files")
    results = []
    for case in sorted(CASES):
        path = args.corpus/(case + ".dcm")
        source = dcmread(path)
        frames = list(generate_frames(source.PixelData, number_of_frames=1))
        require(len(frames) == 1, "Wrong frame count")
        own, outcome = witness(case, source, frames[0])
        require(json.loads(path.with_suffix(".json").read_text()) == own, "Wrong scoped report: " + case)
        gap = None
        if case in {"binary", "nonbinary"}: gap = "Independent decoder does not support DICOM one-bit RLE; exact padded-byte witnesses remain available."
        elif case in GAPS: gap = "Decoder acceptance does not establish encoder conformance, complete metadata coherence or absence of discarded source data."
        results.append({"case": case, "sourceSHA256": hashlib.sha256(path.read_bytes()).hexdigest(), "own": own,
                        "pydicom": outcome, "limitation": gap})
    report = {"standardEdition": "2026c", "standardSHA256": hashlib.sha256(standard).hexdigest(), "pydicomVersion": version,
              "scope": "Single assembled RLE frame header, packet and metadata rules. No full IOD, palette/color display, native packing or frame-map qualification.",
              "wireVRVMLimitation": "Metadata parser omits Pixel Data; its limitation is retained separately from actual frame inspection.",
              "independentByteWitnesses": len(results), "decoderAgreements": len(CASES - GAPS), "documentedDecoderGaps": len(GAPS), "cases": results}
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"PASS: {len(results)} byte witnesses, {len(CASES-GAPS)} decoder agreements, {len(GAPS)} documented gaps")


if __name__ == "__main__":
    main()
