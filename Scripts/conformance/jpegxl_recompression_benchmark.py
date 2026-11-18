#!/usr/bin/env python3
"""Qualify #2379: eight single-thread Release cases <= 5x cjxl/djxl, with unchanged bytes.

One warmup, three measured runs. Own operations run in memory; cjxl/djxl include process and file IO.
Both reconstruct the own-produced JXL. Run without concurrent builds/tests. The pinned 28-source
corpus contains 25 accepted cases and three reference refusals (covered by the XCTest corpus).
"""
import argparse
import hashlib
import json
import platform
import statistics
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

HISTORICAL_TIMING_CASES = {
    "pil_rgb_q75_420", "pil_rgb_q95_444", "pil_gray_q90", "pil_rgb_progressive",
    "cjpeg_restart2", "cjpeg_odd_1x1", "cjpeg_big_2048", "cjpeg_noninterleaved",
}


def run(args):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=600)
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text())
    manifest = json.loads((args.corpus / "manifest.json").read_text())
    expected = {r["name"]: r for r in baseline["corpus"]}
    if len(expected) != 28 or {r["name"] for r in manifest} != set(expected):
        raise RuntimeError("The complete pinned 28-source corpus is required")
    for row in manifest:
        name = row["name"]
        digest = hashlib.sha256((args.corpus / f"{name}.jpg").read_bytes()).hexdigest()
        if digest != expected[name]["inputSHA256"] or row["cjxlAccepts"] != expected[name]["accepted"]:
            raise RuntimeError(f"Input/acceptance drift: {name}")
    timed = {r["name"] for r in baseline["timings"]}
    accepted = {r["name"] for r in baseline["corpus"] if r["accepted"]}
    if len(baseline["timings"]) != 8 or timed != HISTORICAL_TIMING_CASES or not timed <= accepted:
        raise RuntimeError("The eight historical timing cases are required")
    package = Path(__file__).resolve().parents[2]
    run(["xcrun", "swift", "build", "--package-path", package, "-c", "release", "--target", "DicomJPEGXL", "--jobs", "2"])
    build = Path(run(["xcrun", "swift", "build", "--package-path", package, "-c", "release", "--show-bin-path"]).strip())
    with tempfile.TemporaryDirectory(prefix="isis-jxl-recompression-benchmark-") as temporary:
        work = Path(temporary)
        probe = work / "probe"
        sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        run(["xcrun", "swiftc", "-O", "-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0",
             "-I", build / "Modules", Path(__file__).with_name("JPEGXLRecompressionBenchmark.swift"),
             *sorted((build / "DicomJPEGXL.build").glob("*.o")), "-o", probe])
        versions = {tool: subprocess.check_output([tool, "--version"], stderr=subprocess.STDOUT, text=True).strip().splitlines()[0]
                    for tool in ["cjxl", "djxl"]}
        report = {"complete": False, "passed": False, "generatedAt": datetime.now(timezone.utc).isoformat(),
                  "baselineRevision": baseline["revision"], "protocol": baseline["protocol"],
                  "probeSHA256": hashlib.sha256(probe.read_bytes()).hexdigest(),
                  "hardware": run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
                  "swift": run(["xcrun", "swift", "--version"]).strip(), **versions, "timings": [], "corpus": []}
        for old in baseline["corpus"]:
            name = old["name"]
            if not old["accepted"]:
                report["corpus"].append({"name": name, "inputSHA256": old["inputSHA256"], "accepted": False})
                continue
            source = args.corpus / f"{name}.jpg"
            encoded = work / "own.jxl"
            own = json.loads(run([probe, source, "3" if name in timed else "0", "both", encoded]))
            refencode, refdecode = [], []
            if name in timed:
                for index in range(4):
                    started = time.perf_counter()
                    run(["cjxl", source, work / "reference.jxl", "--quiet", "--lossless_jpeg=1", "--num_threads=1", "-e", "7"])
                    et = (time.perf_counter() - started) * 1000
                    started = time.perf_counter()
                    run(["djxl", encoded, work / "reference.jpg", "--quiet", "--num_threads=1"])
                    dt = (time.perf_counter() - started) * 1000
                    if index:
                        refencode.append(et)
                        refdecode.append(dt)
                a, b = statistics.median(own["encodeMilliseconds"]), statistics.median(own["decodeMilliseconds"])
                c, d = statistics.median(refencode), statistics.median(refdecode)
                report["timings"].append({"name": name, "encodeMilliseconds": own["encodeMilliseconds"],
                    "decodeMilliseconds": own["decodeMilliseconds"], "referenceEncodeMilliseconds": refencode,
                    "referenceDecodeMilliseconds": refdecode, "encodeMedian": a, "decodeMedian": b,
                    "referenceEncodeMedian": c, "referenceDecodeMedian": d, "encodeRatio": a / c,
                    "decodeRatio": b / d, "passed": a / c <= 5 and b / d <= 5})
                print(f"{name}: encode {a:.2f}/{c:.2f} = {a/c:.3f}; decode {b:.2f}/{d:.2f} = {b/d:.3f}", flush=True)
            else:
                run(["djxl", encoded, work / "reference.jpg", "--quiet", "--num_threads=1"])
            exact = own["reconstructedSHA256"] == [old["inputSHA256"]]
            unchanged = own["encodedSHA256"] == old["encodedSHA256"]
            reference_exact = (work / "reference.jpg").read_bytes() == source.read_bytes()
            report["corpus"].append({"name": name, "inputSHA256": old["inputSHA256"], "accepted": True,
                "encodedSHA256": own["encodedSHA256"], "reconstructedSHA256": own["reconstructedSHA256"],
                "inputBytes": own["inputBytes"], "encodedBytes": own["encodedBytes"], "encodedUnchanged": unchanged,
                "ownReconstructionExact": exact, "referenceReconstructionExact": reference_exact,
                "passed": unchanged and exact and reference_exact})
        report["complete"] = True
        report["passed"] = all(r["passed"] for r in report["timings"]) and all(r["passed"] for r in report["corpus"] if r["accepted"])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        if not report["passed"]:
            raise RuntimeError("Timing or byte-identity acceptance failed; inspect the report")
        print("PASS: all eight encode/decode budgets, 25 unchanged JXL outputs and exact JPEG reconstruction")


if __name__ == "__main__":
    main()
