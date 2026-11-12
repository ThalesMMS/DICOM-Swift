#!/usr/bin/env python3
"""Build auditable JSON, CSV, and Markdown clinical conformance reports."""

import argparse
import csv
import hashlib
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
        if case_id in records:
            raise ValueError(f"{candidate}:{line_number}: duplicate caseID {case_id}")
        if record.get("result") not in RESULT_RANK:
            raise ValueError(f"{candidate}:{line_number}: invalid result for {case_id}")
        records[case_id] = record
    return records


def result_for_identifier(identifier, test_results):
    matches = []
    missing = []
    for required in identifier.split("|"):
        parts = required.rsplit(".", 1)
        class_name = parts[0]
        method_name = parts[1] if len(parts) == 2 else None
        selected = [
            item
            for item in test_results
            if item["class"] == class_name
            and (method_name is None or item["method"] == method_name)
        ]
        matches.extend(selected)
        if not selected:
            missing.append(required)
    if not matches:
        return {"result": "missing", "durationSeconds": 0.0, "missingTestIdentifiers": missing}
    worst = max(matches, key=lambda item: RESULT_RANK[item["result"]])["result"]
    if missing and worst == "passed":
        worst = "missing"
    return {
        "result": worst,
        "durationSeconds": round(sum(item["durationSeconds"] for item in matches), 6),
        "missingTestIdentifiers": missing,
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
            "viewer-core",
        ):
            return "workspace HEAD"
        return "not-declared"
    capability = preflight_by_id.get(oracle.get("preflightCapabilityID"))
    if capability and capability.get("status") == "available":
        return capability.get("message") or oracle["version"]
    return oracle["version"]


def fixture_record(fixture):
    record = {
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
    for key in ("rows", "columns", "components", "bitsAllocated", "highBit", "planarConfiguration",
                "geometry", "independentExpectedResults"):
        if key in fixture:
            record[key] = fixture[key]
    return record


def build_report(args):
    manifest = load_json(args.manifest, {})
    preflight = load_json(args.preflight, [])
    interop = load_jsonl(args.interop_results)
    test_results = parse_test_log(args.test_log)
    unknown = set(interop) - {item["id"] for item in manifest["cases"]}
    if unknown:
        raise ValueError(f"unknown caseID in interop evidence: {', '.join(sorted(unknown))}")
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
        "evidenceSHA256": {
            name: hashlib.sha256(Path(path).read_bytes()).hexdigest()
            for name, path in (
                ("manifest", args.manifest), ("preflight", args.preflight),
                ("testLog", args.test_log), ("interop", args.interop_results),
            ) if path and Path(path).is_file()
        },
    }
    cases = []
    for item in manifest["cases"]:
        local_outcome = result_for_identifier(item["testIdentifier"], test_results)
        external_outcome = interop.get(item["id"])
        if external_outcome and local_outcome["result"] in ("passed", "failed", "mismatched") and (
            external_outcome["result"] != local_outcome["result"]
        ):
            raise ValueError(f"conflicting evidence for caseID {item['id']}")
        outcome = external_outcome or local_outcome
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
                "executionTier": item.get("executionTier", "existing-conformance"),
                "metadataValidation": outcome.get(
                    "metadataValidation", "covered-by-test" if result == "passed" else "not-executed"
                ),
                "expectedResult": item["expectedResult"],
                "result": result,
                "failureLocation": outcome.get("failureLocation"),
                "firstDifference": outcome.get("firstDifference"),
                "metrics": outcome.get("metrics"),
                "missingTestIdentifiers": outcome.get("missingTestIdentifiers", []),
                "durationSeconds": outcome.get("durationSeconds", 0.0),
                "peakRSSBytes": outcome.get("peakRSSBytes"),
                "requiredGates": item["requiredGates"],
                "supportVerdict": verdict,
                "testIdentifier": item["testIdentifier"],
            }
        )

    case_by_id = {item["caseID"]: item for item in cases}
    backends = []
    for backend in manifest["backends"]:
        evidence = [case_by_id[case_id] for case_id in backend["caseIDs"]]
        verdict = backend["verdict"]
        if any(item["result"] in ("failed", "mismatched") for item in evidence):
            verdict = "unsupported"
        elif verdict == "qualified" and (
            not evidence or any(item["result"] != "passed" for item in evidence)
        ):
            verdict = "out-of-scope"
        backends.append({**backend, "declaredVerdict": backend["verdict"], "verdict": verdict})

    return {
        "schemaVersion": 1,
        "manifestVersion": manifest["version"],
        "issue": manifest["issue"],
        "environment": environment,
        "policy": manifest["policy"],
        "gaps": [entry for entry in manifest["coverage"] if entry["status"] == "gap"],
        "backends": backends,
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
        "executionTier",
        "metadataValidation",
        "expectedResult",
        "result",
        "failureLocation",
        "firstDifference",
        "metrics",
        "missingTestIdentifiers",
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
            for key in ("firstDifference", "metrics", "missingTestIdentifiers"):
                row[key] = json.dumps(item[key], sort_keys=True)
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
    for item in report["cases"]:
        if item["firstDifference"]:
            lines.extend(["", f"First difference for `{item['caseID']}`: "
                          f"`{json.dumps(item['firstDifference'], sort_keys=True)}`", ""])
        if item["metrics"]:
            lines.extend(["", f"Metrics for `{item['caseID']}`: "
                          f"`{json.dumps(item['metrics'], sort_keys=True)}`", ""])
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
    for capability in report["preflight"]:
        if capability.get("required") and capability.get("status") != "available":
            failures.append(f"required capability {capability['id']}: {capability.get('status', 'missing')}")
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
