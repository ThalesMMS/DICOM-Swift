#!/usr/bin/env python3
"""Deterministic runtime-coverage summary for DICOM-Swift gates (issue #1222).

Combines the preflight capability report (issue #1219) with the test-run log
of a validation gate (issue #1220) and emits a human-readable and a
machine-readable summary answering: what was tested, what was skipped, what
was missing, and what was required.

Usage:
  runtime_coverage_report.py --gate <name> --preflight <preflight.json> \
      --test-log <test.log> --output-dir <dir>
"""

import argparse
import json
import re
import sys
from pathlib import Path


def classify(entry):
    """Map a preflight entry to a coverage classification."""
    status = entry["status"]
    kind = entry["kind"]
    if entry["required"] and status != "available":
        return "required-missing"
    if status == "available":
        return "deterministic-bundled" if kind == "fixture" else "active-optional"
    if status == "unsupported-feature":
        return "unsupported-platform"
    if "fixture" in kind:
        return "absent-fixture"
    if "service" in kind or entry["id"] == "network-interop-smoke":
        return "absent-service"
    return "absent-runtime"


def parse_test_log(path):
    text = Path(path).read_text(errors="replace") if Path(path).exists() else ""
    executed = skipped = failures = 0
    for match in re.finditer(
        r"Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?",
        text,
    ):
        executed = max(executed, int(match.group(1)))
        skipped = max(skipped, int(match.group(2) or 0))
        failures = max(failures, int(match.group(3)))

    # Attribute skips to manifest capabilities via the preflight skip-message
    # format: "... [capability=<id>, classification=..., requireEnv=...]".
    skip_capabilities = sorted(set(re.findall(r"capability=([a-z0-9-]+)", text)))
    return {
        "executedTests": executed,
        "skippedTests": skipped,
        "failures": failures,
        "skippedCapabilities": skip_capabilities,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--gate", required=True)
    parser.add_argument("--preflight", required=True)
    parser.add_argument("--test-log", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    entries = json.loads(Path(args.preflight).read_text())
    test_run = parse_test_log(args.test_log)

    buckets = {}
    for entry in entries:
        buckets.setdefault(classify(entry), []).append(entry)

    summary = {
        "gate": args.gate,
        "testRun": test_run,
        "capabilities": [
            {
                "id": entry["id"],
                "classification": classify(entry),
                "status": entry["status"],
                "required": entry["required"],
                "requireEnvironmentVariable": entry.get("requireEnvironmentVariable"),
                "message": entry["message"],
            }
            for entry in entries
        ],
        "counts": {name: len(items) for name, items in sorted(buckets.items())},
    }

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")

    order = [
        ("deterministic-bundled", "Deterministic bundled coverage"),
        ("active-optional", "Optional capabilities exercised"),
        ("absent-runtime", "Absent optional runtimes (coverage NOT exercised)"),
        ("absent-fixture", "Absent optional fixtures (coverage NOT exercised)"),
        ("absent-service", "Absent external services (coverage NOT exercised)"),
        ("unsupported-platform", "Unsupported on this platform"),
        ("required-missing", "REQUIRED CAPABILITIES MISSING"),
    ]
    lines = [
        f"DICOM-Swift runtime coverage summary — gate={args.gate}",
        f"Tests: executed={test_run['executedTests']} skipped={test_run['skippedTests']} "
        f"failures={test_run['failures']}",
    ]
    if test_run["skippedCapabilities"]:
        lines.append(
            "Skips attributed to capabilities: " + ", ".join(test_run["skippedCapabilities"])
        )
    for key, title in order:
        items = buckets.get(key)
        if not items:
            continue
        lines.append(f"{title}:")
        for entry in items:
            require_env = entry.get("requireEnvironmentVariable")
            hint = f" (promote with {require_env}=1)" if require_env and not entry["required"] else ""
            lines.append(f"  - {entry['id']}: {entry['message']}{hint}")
    absent = sum(len(buckets.get(k, [])) for k in ("absent-runtime", "absent-fixture", "absent-service"))
    if absent:
        lines.append(
            f"NOTE: {absent} optional capabilit{'y was' if absent == 1 else 'ies were'} not exercised — "
            "this run is NOT full coverage."
        )
    else:
        lines.append("All manifest capabilities were active for this run.")

    text = "\n".join(lines) + "\n"
    (output_dir / "summary.txt").write_text(text)
    print(text, end="")

    if buckets.get("required-missing"):
        sys.exit(1)


if __name__ == "__main__":
    main()
