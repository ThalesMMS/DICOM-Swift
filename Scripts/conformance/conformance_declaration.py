#!/usr/bin/env python3
"""Generate the DICOM validation conformance declaration from evidence, never from prose.

Inputs are the qualified-profile catalog printed by the Release `dicomtool profiles --format json`,
the pinned oracle outputs of every profile corpus (Scripts/conformance/*_oracle.py), the codestream and
CLI oracle outputs, the capability-matrix run of the `composed-*` checks (Tools/Scripts/
raster_capability_matrix.py run) and the build identity (git HEAD, working-tree fingerprint recorded by
the matrix run, binary digest, Swift toolchain). The generator refuses to declare a profile without a
passing corpus oracle or a passing matrix check, and writes Markdown plus JSON that state the composed
scope only: no general or full conformance is asserted.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess

COMPOSED_CHECKS = {
    "ultrasound": ["composed-ultrasound", "composed-ultrasound-consumers"],
    "sc_profile": ["composed-sc-profile"], "sc_multiframe": ["composed-sc-multiframe"], "classic_image": ["composed-classic-image"],
    "sr_profile": ["composed-sr-profile"], "enhanced_image": ["composed-enhanced-image"],
    "seg_pm": ["composed-segmentation-parametric-map"], "presentation_state": ["composed-presentation-state"],
    "rt": ["composed-rt"], "registration": ["composed-registration"], "wsi": ["composed-wsi"], "video": ["composed-video", "composed-video-consumers"], "waveform_document": ["composed-waveform-document"],
}
SHARED_CHECKS = ["composed-attribute-contract", "composed-instance-consumers", "composed-codestream"]
SYNTAX_SCOPE = ("Native transfer syntaxes (Implicit/Explicit VR Little Endian, Explicit VR Big Endian, Deflated Explicit VR "
                "Little Endian within the inflation budget). Encapsulated syntaxes compose main-header coherence per "
                "Docs/QA/CodestreamConformanceCoverage.md: RLE, JPEG lossless and extended pass the codestream layer; JPEG "
                "baseline, JPEG-LS, JPEG 2000 and HTJ2K stay incomplete on that layer (payload unverified).")


def require(condition, message):
    if not condition:
        raise SystemExit("error: " + message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root, *arguments):
    return subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, text=True, check=True).stdout.strip()


def swift_version():
    result = subprocess.run(["swift", "--version"], capture_output=True, text=True, check=True)
    lines = result.stdout.strip().splitlines()
    require(lines, "Swift version command returned no version")
    return lines[0]


def oracle_summary(path):
    record = json.loads(path.read_text())
    cases = record["cases"]
    require(cases, f"Empty oracle evidence: {path}")
    gaps = sum(1 for case in cases if case.get("gap"))
    false_positives = sum(len(value) if isinstance(value, list) else int(value or 0)
                          for value in (case.get("falsePositives", 0) for case in cases))
    versions = record.get("versions") or {"pydicom": record.get("pydicomVersion")}
    return {"file": path.name, "sha256": digest(path), "cases": len(cases), "independentAgreements": len(cases) - gaps,
            "documentedGaps": gaps, "oracleFalsePositives": false_positives, "versions": versions,
            "standardSHA256": record.get("standardSHA256"), "facts": record.get("facts")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--binary", type=Path, required=True, help="Release dicomtool")
    parser.add_argument("--oracle-directory", type=Path, required=True, help="Directory holding isis-2321-<oracle>-oracle.json outputs")
    parser.add_argument("--matrix-results", type=Path, required=True, help="results.json of raster_capability_matrix.py run")
    parser.add_argument("--output", type=Path, required=True, help="Markdown declaration path; the JSON twin is written next to it")
    args = parser.parse_args()
    root = args.repo_root.resolve()
    listing = subprocess.run([str(args.binary), "profiles", "--format", "json"], capture_output=True, text=True, check=True)
    profiles = json.loads(listing.stdout)
    require(profiles and len({p["sopClassUID"] for p in profiles}) == len(profiles), "The binary lists no unique profiles")
    matrix = json.loads(args.matrix_results.read_text())
    checks = matrix["checks"]
    for key in SHARED_CHECKS + [check for keys in COMPOSED_CHECKS.values() for check in keys]:
        require(checks.get(key, {}).get("state") == "passed", f"Matrix check {key} is not passed in {args.matrix_results}")
    oracles = {}
    for name in sorted({p["oracle"] for p in profiles}):
        require(name in COMPOSED_CHECKS, f"No matrix check is registered for oracle {name}")
        path = args.oracle_directory / f"isis-2321-{name.replace('_', '-')}-oracle.json"
        require(path.is_file(), f"Missing oracle output {path}")
        oracles[name] = oracle_summary(path)
    for extra in ["codestream", "instance-cli", "jpeg-frame"]:
        path = args.oracle_directory / f"isis-2321-{extra}-oracle.json"
        require(path.is_file(), f"Missing oracle output {path}")
        record = json.loads(path.read_text())
        require(record["cases"], f"Empty oracle evidence: {path}")
        oracles[extra] = {"file": path.name, "sha256": digest(path), "cases": len(record["cases"]),
                          "independentAgreements": sum(1 for case in record["cases"] if not case.get("gap") and not case.get("boundaryOracleGap")),
                          "documentedGaps": sum(1 for case in record["cases"] if case.get("gap") or case.get("boundaryOracleGap")),
                          "versions": record.get("versions") or {"pydicom": record.get("pydicomVersion")}}
    binary_digest = digest(args.binary)
    cli = json.loads((args.oracle_directory / "isis-2321-instance-cli-oracle.json").read_text())
    require(cli["binarySHA256"] == binary_digest, "The CLI oracle was not run against the declared binary")
    build = {"commit": git(root, "rev-parse", "HEAD"), "branch": git(root, "rev-parse", "--abbrev-ref", "HEAD"),
             "workingTreeDirty": bool(git(root, "status", "--porcelain")), "matrixInputSHA256": matrix["inputSHA256"],
             "matrixRecordedAtUTC": matrix["recordedAtUTC"], "host": matrix["host"], "binarySHA256": binary_digest,
             "swift": swift_version(),
             "generatedAtUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}
    families = {}
    for profile in profiles:
        families.setdefault(profile["family"], []).append(profile)
    declaration = {"schemaVersion": 1, "issue": 2321, "scope": SYNTAX_SCOPE, "build": build, "profiles": profiles,
                   "oracles": oracles, "matrixChecks": {key: checks[key]["state"] for key in sorted(checks)},
                   "statement": ("Each listed SOP Class has every module of its PS3.3 2026c IOD tables composed by DicomInstanceValidator "
                                 "on native transfer syntaxes, a positive/negative profile corpus and an independent comparison with "
                                 "documented gaps. Declared optional content may still yield explicit limitations (Defined context "
                                 "groups, private coding scheme versions, signatures, unsupplied reference targets, template content, "
                                 "Defined Terms). No SOP Class outside this list, no encapsulated payload, no operation policy and no "
                                 "hosted CI run is declared. This is not a general DICOM conformance statement.")}
    json_path = args.output.with_suffix(".json")
    json_path.write_text(json.dumps(declaration, indent=2, sort_keys=True) + "\n")
    lines = ["# DICOM validation conformance declaration (generated)", "",
             "Generated by `DICOM-Swift/Scripts/conformance/conformance_declaration.py` from the Release `dicomtool profiles`",
             "listing, the pinned profile oracles, the capability-matrix run and the build identity. Do not edit by hand;",
             f"the JSON twin is `{json_path.name}`.", "", "## Build identity", "",
             f"- Commit `{build['commit']}` on `{build['branch']}`" + (" (working tree dirty at generation time)" if build["workingTreeDirty"] else ""),
             f"- Matrix input fingerprint `{build['matrixInputSHA256']}`, recorded {build['matrixRecordedAtUTC']} on {build['host']}",
             f"- Release `dicomtool` SHA-256 `{build['binarySHA256']}`; {build['swift']}",
             f"- Generated {build['generatedAtUTC']}", "", "## Scope", "", SYNTAX_SCOPE, "", declaration["statement"], "",
             "## Qualified profiles", "", "| SOP Class UID | Name | Family | Lot | Coverage map | Corpus oracle |", "| --- | --- | --- | --- | --- | --- |"]
    for profile in profiles:
        oracle = oracles[profile["oracle"]]
        lines.append(f"| `{profile['sopClassUID']}` | {profile['name']} | {profile['family']} | {profile['lot']} | "
                     f"[{Path(profile['coverageDocument']).name}]({Path(profile['coverageDocument']).name}) | "
                     f"`{profile['oracle']}_oracle.py`: {oracle['cases']} cases, {oracle['independentAgreements']} agreements, {oracle['documentedGaps']} gaps |")
    lines += ["", "## Evidence", "", "| Oracle output | Cases | Independent agreements | Documented gaps | Oracle false positives | Versions | SHA-256 |",
              "| --- | --- | --- | --- | --- | --- | --- |"]
    for name, oracle in sorted(oracles.items()):
        versions = ", ".join(f"{k} {v}" for k, v in sorted((oracle.get("versions") or {}).items()) if v)
        lines.append(f"| `{oracle['file']}` | {oracle['cases']} | {oracle['independentAgreements']} | {oracle['documentedGaps']} | "
                     f"{oracle.get('oracleFalsePositives', 0)} | {versions} | `{oracle['sha256'][:16]}…` |")
    lines += ["", "Matrix checks: " + ", ".join(f"`{key}` {state}" for key, state in sorted(declaration["matrixChecks"].items())) + ".", ""]
    args.output.write_text("\n".join(lines) + "\n")
    print(f"PASS: declared {len(profiles)} profiles in {len(families)} families from {len(oracles)} oracle outputs and "
          f"{len(checks)} matrix checks; no general conformance asserted")


if __name__ == "__main__":
    main()
