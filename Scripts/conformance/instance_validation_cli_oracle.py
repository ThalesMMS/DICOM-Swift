#!/usr/bin/env python3
"""Verify real CLI adapters against previously qualified synthetic RLE/JPEG frame corpora."""

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

from image_iod_oracle import require


def run(binary, arguments):
    result = subprocess.run([str(binary), *map(str, arguments)], capture_output=True, text=True, timeout=30)
    require(result.returncode in {0, 1, 2, 65}, "Unexpected CLI failure")
    require("PRIVATE_TEST_MARKER" not in result.stdout and "PRIVATE_TEST_MARKER" not in result.stderr,
            "Synthetic private value leaked")
    return result.returncode, json.loads(result.stdout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--rle-corpus", type=Path, required=True)
    parser.add_argument("--jpeg-corpus", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    results = []
    for family, directory, count in [("rle", args.rle_corpus, 20), ("jpeg", args.jpeg_corpus, 16)]:
        files = sorted(directory.glob("*.dcm"))
        require(len(files) == count, "Wrong qualified corpus count")
        for source in files:
            scoped = json.loads(source.with_suffix(".json").read_text())
            exit_code, report = run(args.binary, ["validate", source, "--composed", "--format", "json"])
            outcomes = report["outcomes"]
            expected = {"codestream": scoped["codestream"], "pixelsAndGeometry": scoped["pixels"],
                        "attributes": "failed",  # These pixel-only SC carriers omit mandatory common attributes.
                        # Images without declared references have nothing to resolve in the references layer; every
                        # encapsulated fragment is read and framed, so the wire pass's pixel-value omission is withdrawn.
                        "structure": "passed", "vrAndVM": "passed", "references": "passed", "operation": "notEvaluated"}
            require(outcomes == expected, "Changed composed outcomes: " + family + "/" + source.stem)
            require(any(d["code"] == "requiredAttributeMissing" and d["path"] == [{"tag": {"_0": 0x00100020}}]
                        and d["requirement"] == "2" for d in report["diagnostics"]), "Missing common SC carrier failure")
            require(exit_code == (1 if "failed" in expected.values() else 2), "Wrong tri-state exit")
            codec_exit, codec = run(args.binary, ["codec", "validate", source, "--format", "json"])
            require(codec["conformance"] == report, "Codec adapter diverged from instance API")
            require(codec_exit == (0 if codec["success"] else 65), "Wrong legacy operation exit")
            results.append({"case": family + "/" + source.stem, "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
                            "outcomes": outcomes, "composedExit": exit_code, "codecExit": codec_exit})
        print(f"PASS: {family} {len(files)} composed/codec CLI comparisons", flush=True)
    with tempfile.TemporaryDirectory(prefix="isis-composed-transcode-") as folder:
        output = Path(folder) / "output.dcm"
        exit_code, transcoded = run(args.binary, ["codec", "transcode", args.rle_corpus / "gray8.dcm", "--output", output,
                                                "--transfer-syntax", "1.2.840.10008.1.2.5", "--format", "json"])
        require(exit_code == 0 and output.is_file(), "Transcode did not save its artifact")
        checked_exit, checked = run(args.binary, ["validate", output, "--composed", "--format", "json"])
        require(checked_exit == 1 and transcoded["conformance"] == checked, "Transcode artifact evidence diverged")
        require(transcoded["artifact"]["comparisonPassed"] is True, "Decoded pixel comparison did not pass")
    args.output.write_text(json.dumps({"binarySHA256": hashlib.sha256(args.binary.read_bytes()).hexdigest(),
        "scope": "Adapter parity with scoped frame corpora, not a new independent normative validator or full IOD qualification.",
        "caseCount": len(results), "transcodedArtifactRevalidated": True, "cases": results}, indent=2, sort_keys=True) + "\n")
    print("PASS: saved transcode artifact matches the common engine and decoded pixels", flush=True)


if __name__ == "__main__":
    main()
