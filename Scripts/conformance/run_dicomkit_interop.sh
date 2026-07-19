#!/usr/bin/env bash
# Optional, pinned DICOMKit cross-read/write harness for issue #1435.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

MANIFEST="Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalCodecConformanceManifest.json"
RESULTS="${DICOM_CONFORMANCE_INTEROP_RESULTS:-.build/clinical-conformance/dicomkit-interop.jsonl}"
mkdir -p "$(dirname "$RESULTS")"
: > "$RESULTS"

PINNED_COMMIT="$(python3 - "$MANIFEST" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["dicomKit"]["commit"])
PY
)"
DICOMSWIFT_VERSION="$(git rev-parse HEAD)"
if ! git diff --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
  DICOMSWIFT_VERSION="$DICOMSWIFT_VERSION+workspace"
fi

emit_result() {
  local case_id="$1"
  local result="$2"
  local duration="$3"
  local metadata="$4"
  local failure_location="${5:-}"
  local encoder_version="${6:-$DICOMSWIFT_VERSION}"
  local decoder_version="${7:-$DICOMSWIFT_VERSION}"
  python3 - "$RESULTS" "$case_id" "$result" "$duration" "$metadata" \
    "$failure_location" "$encoder_version" "$decoder_version" <<'PY'
import json
import sys
path, case_id, result, duration, metadata, failure, encoder, decoder = sys.argv[1:]
record = {
    "caseID": case_id,
    "result": result,
    "durationSeconds": float(duration),
    "metadataValidation": metadata,
    "failureLocation": failure or None,
    "encoderVersion": encoder,
    "decoderVersion": decoder,
    "peakRSSBytes": None,
}
with open(path, "a") as stream:
    stream.write(json.dumps(record, sort_keys=True) + "\n")
PY
}

CURRENT_CASE=""
CURRENT_STARTED=0
CURRENT_ENCODER_VERSION="$DICOMSWIFT_VERSION"
CURRENT_DECODER_VERSION="$DICOMSWIFT_VERSION"
record_phase_failure() {
  local status="$?"
  local line="$1"
  trap - ERR
  if [ -n "$CURRENT_CASE" ]; then
    emit_result "$CURRENT_CASE" failed "$((SECONDS - CURRENT_STARTED))" \
      "Interop command failed" "run_dicomkit_interop.sh:$line" \
      "$CURRENT_ENCODER_VERSION" "$CURRENT_DECODER_VERSION"
  fi
  exit "$status"
}
trap 'record_phase_failure "$LINENO"' ERR

if [ -z "${DICOMKIT_CHECKOUT:-}" ]; then
  if [ "${DICOM_REQUIRE_DICOMKIT_INTEROP:-0}" = "1" ]; then
    echo "DICOMKIT_CHECKOUT is required when DICOM_REQUIRE_DICOMKIT_INTEROP=1." >&2
    exit 1
  fi
  emit_result dicomswift-object-export skipped 0 "DICOMKit checkout not provisioned" \
    "" "$DICOMSWIFT_VERSION" "$PINNED_COMMIT"
  emit_result dicomkit-synthetic-read skipped 0 "DICOMKit checkout not provisioned" \
    "" "$PINNED_COMMIT" "$DICOMSWIFT_VERSION"
  emit_result dicomkit-cross-write skipped 0 "DICOMKit checkout not provisioned" \
    "" "$PINNED_COMMIT" "$DICOMSWIFT_VERSION"
  echo "DICOMKit interop skipped: set DICOMKIT_CHECKOUT to the pinned checkout."
  exit 0
fi

if [ ! -d "$DICOMKIT_CHECKOUT/.git" ]; then
  echo "DICOMKIT_CHECKOUT is not a Git checkout: $DICOMKIT_CHECKOUT" >&2
  exit 1
fi
ACTUAL_COMMIT="$(git -C "$DICOMKIT_CHECKOUT" rev-parse HEAD)"
if [ "$ACTUAL_COMMIT" != "$PINNED_COMMIT" ]; then
  echo "DICOMKit commit mismatch: expected $PINNED_COMMIT, found $ACTUAL_COMMIT." >&2
  exit 1
fi

FIXTURE_ROOT="$DICOMKIT_CHECKOUT/$(python3 - "$MANIFEST" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1]))["dicomKit"]["fixtureRoot"])
PY
)"
if [ ! -f "$FIXTURE_ROOT/syn-ct.dcm" ]; then
  echo "Pinned DICOMKit synthetic fixture is missing: $FIXTURE_ROOT/syn-ct.dcm" >&2
  exit 1
fi

echo "==> Building pinned DICOMKit CLI oracles"
swift build --package-path "$DICOMKIT_CHECKOUT" -c release --product dicom-validate
swift build --package-path "$DICOMKIT_CHECKOUT" -c release --product dicom-compress
DICOMKIT_BIN="$(swift build --package-path "$DICOMKIT_CHECKOUT" -c release --show-bin-path)"

echo "==> Building DICOM-Swift validation CLI"
swift build -c release --product dicomtool
DICOMSWIFT_BIN="$(swift build -c release --show-bin-path)/dicomtool"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dicomkit-interop.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
EXPORTS="$WORK/dicomswift-objects"
TRANSCODES="$WORK/dicomkit-transcodes"
mkdir -p "$EXPORTS" "$TRANSCODES"

CURRENT_CASE="dicomswift-object-export"
CURRENT_STARTED=$SECONDS
CURRENT_ENCODER_VERSION="$DICOMSWIFT_VERSION"
CURRENT_DECODER_VERSION="$PINNED_COMMIT"
echo "==> DICOM-Swift write -> DICOMKit read"
DICOM_INTEROP_OUTPUT_DIR="$EXPORTS" swift test \
  --filter ClinicalInteropFixtureExportTests.test_exportClinicalInteropFixturesWhenRequested
for fixture in "$EXPORTS"/*.dcm; do
  "$DICOMKIT_BIN/dicom-validate" "$fixture" --level 1 --format json >/dev/null
done
emit_result dicomswift-object-export passed "$((SECONDS - CURRENT_STARTED))" \
  "DICOMKit level 1 validation passed for SEG, RTSTRUCT, RTDOSE, GSPS, SR TID 1500, and KOS" \
  "" "$DICOMSWIFT_VERSION" "$PINNED_COMMIT"
CURRENT_CASE=""

CURRENT_CASE="dicomkit-synthetic-read"
CURRENT_STARTED=$SECONDS
CURRENT_ENCODER_VERSION="$PINNED_COMMIT"
CURRENT_DECODER_VERSION="$DICOMSWIFT_VERSION"
echo "==> DICOMKit write -> DICOM-Swift read"
for fixture in "$FIXTURE_ROOT"/*.dcm; do
  "$DICOMSWIFT_BIN" validate "$fixture" --format json >/dev/null
done
DICOMKIT_SYNTHETIC_FIXTURE_ROOT="$FIXTURE_ROOT" swift test \
  --filter ClinicalDICOMKitInteropTests.test_readDICOMKitSyntheticCTPreservesMetadataAndStoredPixels
emit_result dicomkit-synthetic-read passed "$((SECONDS - CURRENT_STARTED))" \
  "DICOM-Swift validated DICOMKit synthetic Part 10 objects and exact CT stored pixels" \
  "" "$PINNED_COMMIT" "$DICOMSWIFT_VERSION"
CURRENT_CASE=""

CURRENT_CASE="dicomkit-cross-write"
CURRENT_STARTED=$SECONDS
CURRENT_ENCODER_VERSION="$PINNED_COMMIT"
CURRENT_DECODER_VERSION="$DICOMSWIFT_VERSION"
echo "==> DICOMKit transcode -> DICOM-Swift lossless decode"
"$DICOMKIT_BIN/dicom-compress" compress "$FIXTURE_ROOT/syn-ct.dcm" \
  --output "$TRANSCODES/syn-ct-rle.dcm" --codec rle
"$DICOMKIT_BIN/dicom-compress" compress "$FIXTURE_ROOT/syn-ct.dcm" \
  --output "$TRANSCODES/syn-ct-jpeg-lossless.dcm" --codec jpeg-lossless
for fixture in "$TRANSCODES"/*.dcm; do
  "$DICOMSWIFT_BIN" validate "$fixture" --format json >/dev/null
done
DICOMKIT_SYNTHETIC_FIXTURE_ROOT="$FIXTURE_ROOT" \
DICOMKIT_TRANSCODE_OUTPUT_DIR="$TRANSCODES" swift test \
  --filter ClinicalDICOMKitInteropTests.test_readDICOMKitTranscodesPreservesMetadataAndLosslessPixels
emit_result dicomkit-cross-write passed "$((SECONDS - CURRENT_STARTED))" \
  "RLE and JPEG Lossless encapsulation, metadata, dimensions, and stored pixels match exactly" \
  "" "$PINNED_COMMIT" "$DICOMSWIFT_VERSION"
CURRENT_CASE=""

echo "DICOMKit interoperability results: $RESULTS"
