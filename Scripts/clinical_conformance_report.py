#!/usr/bin/env python3
"""Build auditable JSON, CSV, and Markdown clinical conformance reports."""

import argparse
import csv
import json
import platform
import re
import socket
import sys
from datetime import datetime, timezone
from pathlib import Path


RESULT_RANK = {"missing": 0, "passed": 1, "skipped": 2, "failed": 3, "mismatched": 3}


def parse_test_log(path):
    text = Path(path).read_text(errors="replace") if Path(path).exists() else ""
    results = []
    patterns = [
        re.compile(
            r"Test Case '-\[[^.]+\.(?P<class>[^ ]+) (?P<method>[^]]+)\]' "
            r"(?P<result>passed|failed|skipped) \((?P<duration>[0-9.]+) seconds\)"
        ),
        re.compile(
            r"Test Case '(?:[^.]+\.)?(?P<class>[A-Za-z0-9_]+)\."
            r"(?P<method>[A-Za-z0-9_]+)' (?P<result>passed|failed|skipped) "
            r"\((?P<duration>[0-9.]+) seconds\)"
        ),
    ]
    for line in text.splitlines():
        for pattern in patterns:
            match = pattern.search(line)
            if match:
                results.append(
                    {
                        "class": match.group("class"),
                        "method": match.group("method"),
                        "result": match.group("result"),
                        "durationSeconds": float(match.group("duration")),
                    }
                )
                break
    return results


def load_json(path, default):
    candidate = Path(path) if path else None
    if not candidate or not candidate.exists():
        return default
    return json.loads(candidate.read_text())


def load_jsonl(path):
    candidate = Path(path) if path else None
    if not candidate or not candidate.exists():
        return {}
    records = {}
    for line_number, line in enumerate(candidate.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        record = json.loads(line)
        case_id = record.get("caseID")
        if not case_id:
            raise ValueError(f"{candidate}:{line_number}: missing caseID")
        records[case_id] = record
    return records


def result_for_identifier(identifier, test_results):
    matches = []
    for alternative in identifier.split("|"):
        parts = alternative.rsplit(".", 1)
        class_name = parts[0]
        method_name = parts[1] if len(parts) == 2 else None
        matches.extend(
            item
            for item in test_results
            if item["class"] == class_name
            and (method_name is None or item["method"] == method_name)
        )
    if not matches:
        return {"result": "missing", "durationSeconds": 0.0}
    worst = max(matches, key=lambda item: RESULT_RANK[item["result"]])["result"]
    return {
        "result": worst,
        "durationSeconds": round(sum(item["durationSeconds"] for item in matches), 6),
    }


def oracle_version(oracle_id, oracle_by_id, preflight_by_id):
    oracle = oracle_by_id.get(oracle_id)
    if not oracle:
        parts = oracle_id.split("-and-")
        if len(parts) > 1 and all(part in oracle_by_id for part in parts):
            return "; ".join(
                f"{oracle_by_id[part]['implementation']}: "
                f"{oracle_version(part, oracle_by_id, preflight_by_id)}"
                for part in parts
            )
        if oracle_id in (
            "repository-builders",
            "malformed-generators",
            "metadata-parser",
        ):
            return "workspace HEAD"
        return "not-declared"
    capability = preflight_by_id.get(oracle.get("preflightCapabilityID"))
    if capability and capability.get("status") == "available":
        return capability.get("message") or oracle["version"]
    return oracle["version"]


def fixture_record(fixture):
    return {
        key: fixture[key]
        for key in (
            "id",
            "path",
            "provenance",
            "license",
            "deidentification",
            "sha256",
            "modality",
            "objectFamily",
            "transferSyntaxUID",
            "photometricInterpretation",
            "bitsStored",
            "signed",
            "frames",
        )
    }


def build_report(args):
    manifest = load_json(args.manifest, {})
    preflight = load_json(args.preflight, [])
    interop = load_jsonl(args.interop_results)
    test_results = parse_test_log(args.test_log)
    fixture_by_id = {fixture["id"]: fixture for fixture in manifest["fixtures"]}
    oracle_by_id = {oracle["id"]: oracle for oracle in manifest["oracles"]}
    preflight_by_id = {entry["id"]: entry for entry in preflight}

    environment = {
        "gate": args.gate,
        "timestampUTC": datetime.now(timezone.utc).isoformat(),
        "host": socket.gethostname(),
        "platform": platform.platform(),
        "architecture": platform.machine(),
        "pythonVersion": platform.python_version(),
    }
    cases = []
    for item in manifest["cases"]:
        outcome = interop.get(item["id"]) or result_for_identifier(
            item["testIdentifier"], test_results
        )
        result = outcome.get("result", "missing")
        verdict = item["supportVerdict"]
        if result not in (item["expectedResult"], "passed"):
            verdict = "unsupported" if result in ("failed", "mismatched") else "out-of-scope"
        cases.append(
            {
                "caseID": item["id"],
                "fixtureIDs": item["fixtureIDs"],
                "fixtures": [fixture_record(fixture_by_id[id_]) for id_ in item["fixtureIDs"]],
                "encoderID": item["encoderID"],
                "encoderVersion": outcome.get("encoderVersion")
                or oracle_version(item["encoderID"], oracle_by_id, preflight_by_id),
                "decoderID": item["decoderID"],
                "decoderVersion": outcome.get("decoderVersion")
                or oracle_version(item["decoderID"], oracle_by_id, preflight_by_id),
                "backendID": item["backendID"],
                "comparison": item["comparison"],
                "metadataValidation": outcome.get("metadataValidation", "covered-by-test"),
                "expectedResult": item["expectedResult"],
                "result": result,
                "failureLocation": outcome.get("failureLocation"),
                "durationSeconds": outcome.get("durationSeconds", 0.0),
                "peakRSSBytes": outcome.get("peakRSSBytes"),
                "requiredGates": item["requiredGates"],
                "supportVerdict": verdict,
                "testIdentifier": item["testIdentifier"],
            }
        )

    return {
        "schemaVersion": 1,
        "manifestVersion": manifest["version"],
        "issue": manifest["issue"],
        "environment": environment,
        "policy": manifest["policy"],
        "gaps": [entry for entry in manifest["coverage"] if entry["status"] == "gap"],
        "backends": manifest["backends"],
        "preflight": preflight,
        "cases": cases,
    }


def write_json(report, output_dir):
    (output_dir / "report.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n"
    )


def write_csv(report, output_dir):
    fieldnames = [
        "caseID",
        "fixtureIDs",
        "fixtureChecksums",
        "encoderID",
        "encoderVersion",
        "decoderID",
        "decoderVersion",
        "backendID",
        "comparison",
        "metadataValidation",
        "expectedResult",
        "result",
        "failureLocation",
        "durationSeconds",
        "peakRSSBytes",
        "requiredGates",
        "supportVerdict",
    ]
    with (output_dir / "report.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        for item in report["cases"]:
            row = {key: item.get(key) for key in fieldnames}
            row["fixtureIDs"] = ";".join(item["fixtureIDs"])
            row["fixtureChecksums"] = ";".join(
                fixture["sha256"] for fixture in item["fixtures"]
            )
            row["requiredGates"] = ";".join(item["requiredGates"])
            writer.writerow(row)


def write_markdown(report, output_dir):
    lines = [
        "# DICOM-Swift clinical codec conformance",
        "",
        f"Gate: `{report['environment']['gate']}`  ",
        f"Host: `{report['environment']['host']}`  ",
        f"Platform: `{report['environment']['platform']}`  ",
        f"Generated: `{report['environment']['timestampUTC']}`",
        "",
        "## Cases",
        "",
        "| Case | Backend | Comparison | Result | Verdict | Duration (s) |",
        "| --- | --- | --- | --- | --- | ---: |",
    ]
    for item in report["cases"]:
        lines.append(
            f"| {item['caseID']} | {item['backendID']} | {item['comparison']} | "
            f"{item['result']} | {item['supportVerdict']} | {item['durationSeconds']} |"
        )
    lines.extend(["", "## Capability gaps", ""])
    if not report["gaps"]:
        lines.append("No declared gaps.")
    else:
        for gap in report["gaps"]:
            lines.append(f"- `{gap['id']}` — {gap['gap']} Owner: {gap['owner']}.")
    lines.extend(
        [
            "",
            "## Backend verdicts",
            "",
            "| Capability | Verdict | Independent oracles |",
            "| --- | --- | --- |",
        ]
    )
    for backend in report["backends"]:
        lines.append(
            f"| {backend['capabilityID']} | {backend['verdict']} | "
            f"{', '.join(backend['independentOracleIDs']) or 'none'} |"
        )
    (output_dir / "report.md").write_text("\n".join(lines) + "\n")


def enforce_required(report):
    failures = []
    for item in report["cases"]:
        if report["environment"]["gate"] not in item["requiredGates"]:
            continue
        if item["result"] != item["expectedResult"]:
            failures.append(
                f"{item['caseID']}: expected {item['expectedResult']}, got {item['result']}"
            )
    if failures:
        print("Clinical conformance gate failed:", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--preflight", required=True)
    parser.add_argument("--test-log", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--gate", required=True)
    parser.add_argument("--interop-results")
    parser.add_argument("--enforce-required", action="store_true")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    report = build_report(args)
    write_json(report, output_dir)
    write_csv(report, output_dir)
    write_markdown(report, output_dir)
    if args.enforce_required:
        sys.exit(enforce_required(report))


if __name__ == "__main__":
    main()
