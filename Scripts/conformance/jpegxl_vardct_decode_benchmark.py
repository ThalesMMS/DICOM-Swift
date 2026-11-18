#!/usr/bin/env python3
"""Qualify #2377: single-thread Release decode <= 3x djxl, with unchanged output on all 68 streams.

Builds the package target and links the small in-memory probe. Both decoders get one warmup and
three measured runs for the eight historical cases. djxl includes process startup and PNM file IO,
matching the original issue's comparison; own timing excludes input IO and output hashing.
Run without concurrent builds/tests. The baseline pins input and decoded-byte hashes.
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


def run(args):
    completed = subprocess.run([str(a) for a in args], capture_output=True, text=True, timeout=600)
    if completed.returncode:
        raise RuntimeError(completed.stdout + completed.stderr)
    return completed.stdout


def validated_timings(baseline, expected):
    timings = baseline.get("timings")
    if not isinstance(timings, list) or len(timings) != 8:
        raise ValueError("The baseline must contain exactly eight timing cases")
    names = [row.get("name") if isinstance(row, dict) else None for row in timings]
    if any(not isinstance(name, str) or name not in expected for name in names) or len(set(names)) != 8:
        raise ValueError("Timing cases must be distinct members of the pinned corpus")
    return timings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[2]
    baseline = json.loads(args.baseline.read_text())
    expected = {r["name"]: r for r in baseline["decodedCorpus"]}
    manifest = {r["name"]: r for r in json.loads((args.corpus / "manifest.json").read_text())}
    if set(manifest) != set(expected) or len(expected) != 68:
        raise RuntimeError("The complete pinned 68-stream corpus is required")
    timings = validated_timings(baseline, expected)
    for name, row in expected.items():
        if hashlib.sha256((args.corpus / f"{name}.jxl").read_bytes()).hexdigest() != row["inputSHA256"]:
            raise RuntimeError(f"Input hash changed: {name}")
    run(["xcrun", "swift", "build", "--package-path", package, "-c", "release", "--target", "DicomJPEGXL", "--jobs", "2"])
    build = Path(run(["xcrun", "swift", "build", "--package-path", package, "-c", "release", "--show-bin-path"]).strip())
    with tempfile.TemporaryDirectory(prefix="isis-jxl-decode-benchmark-") as temporary:
        work = Path(temporary)
        probe = work / "probe"
        sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        run(["xcrun", "swiftc", "-O", "-sdk", sdk, "-target", f"{platform.machine()}-apple-macosx26.0",
             "-I", build / "Modules", Path(__file__).with_name("JPEGXLDecodeBenchmark.swift"),
             *sorted((build / "DicomJPEGXL.build").glob("*.o")), "-o", probe])
        report = {"complete": False, "passed": False, "generatedAt": datetime.now(timezone.utc).isoformat(),
                  "baselineRevision": baseline["revision"], "protocol": baseline["protocol"],
                  "probeSHA256": hashlib.sha256(probe.read_bytes()).hexdigest(),
                  "hardware": run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
                  "swift": run(["xcrun", "swift", "--version"]).strip(),
                  "djxl": subprocess.check_output(["djxl", "--version"], stderr=subprocess.STDOUT, text=True).strip().splitlines()[0],
                  "timings": [], "decodedCorpus": []}
        measured = {}
        for old in timings:
            name = old["name"]
            source = args.corpus / f"{name}.jxl"
            own = json.loads(run([probe, source, "3"]))
            measured[name] = own["outputSHA256"]
            reference = []
            for index in range(4):
                started = time.perf_counter()
                run(["djxl", source, work / "reference.pnm", "--quiet", "--num_threads=1",
                     f"--bits_per_sample={manifest[name]['bits']}"])
                elapsed = (time.perf_counter() - started) * 1000
                if index:
                    reference.append(elapsed)
            own_median, reference_median = statistics.median(own["milliseconds"]), statistics.median(reference)
            ratio = own_median / reference_median
            report["timings"].append({"name": name, "ownMilliseconds": own["milliseconds"],
                                      "referenceMilliseconds": reference, "ownMedian": own_median,
                                      "referenceMedian": reference_median, "ratio": ratio, "passed": ratio <= 3})
            print(f"{name}: own {own_median:.2f} ms, djxl {reference_median:.2f} ms, ratio {ratio:.3f}", flush=True)
        for name, old in expected.items():
            hashes = measured.get(name)
            if hashes is None:
                hashes = json.loads(run([probe, args.corpus / f"{name}.jxl", "0"]))["outputSHA256"]
            report["decodedCorpus"].append({"name": name, "inputSHA256": old["inputSHA256"],
                                            "outputSHA256": hashes, "unchanged": hashes == [old["sha256"]]})
        report["complete"] = True
        report["passed"] = all(r["passed"] for r in report["timings"]) and all(r["unchanged"] for r in report["decodedCorpus"])
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
        if not report["passed"]:
            raise RuntimeError("Performance or byte-identity acceptance failed; inspect the report")
        print("PASS: all eight time budgets and all 68 output hashes")


if __name__ == "__main__":
    main()
