#!/usr/bin/env bash
# DICOM-Swift validation gates (issue #1220).
#
# Splits `swift test` into explicit cost/coverage levels so contributors and
# CI can pick the right gate without guessing:
#
#   quick    Deterministic unit gate for routine PR work. Skips performance,
#            stress, streaming, network/interop, conformance-fixture and CLI
#            process-spawning suites. No external services, no large fixtures.
#   fixture  Bundled and curated non-PHI fixture coverage. Stable inputs,
#            no network services.
#   runtime  Optional runtime/interop coverage. Consumes the preflight
#            capability report (issue #1219, `dicomtool preflight --json`)
#            and only runs the suites whose capability is active.
#   release  The authoritative expensive validation path before publishing
#            or consuming a DICOM-Swift update in Isis: the full suite.
#            Set DICOM_REQUIRE_* / DICOM_INTEROP_SMOKE per the manifest to
#            also force the optional legs.
#
# Usage: Scripts/test_gates.sh <quick|fixture|runtime|release>
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

GATE="${1:-}"
if [ -z "$GATE" ]; then
  echo "usage: Scripts/test_gates.sh <quick|fixture|runtime|release>" >&2
  exit 2
fi

banner() {
  echo "==============================================================="
  echo "DICOM-Swift validation gate: $1"
  echo "==============================================================="
}

# Runtime coverage artifacts (issue #1222): every gate runs the preflight
# first (required-missing capabilities fail BEFORE the long test body) and
# ends with a deterministic coverage summary written for CI logs/artifacts.
COVERAGE_DIR=".build/runtime-coverage/$GATE"
mkdir -p "$COVERAGE_DIR"
TEST_LOG="$COVERAGE_DIR/test.log"

run_preflight_or_fail_fast() {
  echo "==> Preflight (required capabilities fail fast before tests)"
  if ! swift run dicomtool preflight; then
    echo "[gate=$GATE] FAILED in preflight: required capabilities are missing." >&2
    exit 1
  fi
  swift run dicomtool preflight --json > "$COVERAGE_DIR/preflight.json"
}

emit_coverage_summary() {
  echo "==> Runtime coverage summary (artifacts in $COVERAGE_DIR)"
  python3 Scripts/runtime_coverage_report.py \
    --gate "$GATE" \
    --preflight "$COVERAGE_DIR/preflight.json" \
    --test-log "$TEST_LOG" \
    --output-dir "$COVERAGE_DIR"
}

emit_clinical_conformance_report() {
  echo "==> Clinical codec conformance report (JSON/CSV/Markdown)"
  local args=(
    --manifest Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalCodecConformanceManifest.json
    --preflight "$COVERAGE_DIR/preflight.json"
    --test-log "$TEST_LOG"
    --output-dir "$COVERAGE_DIR/clinical-conformance"
    --gate "$GATE"
    --enforce-required
  )
  if [ -f ".build/clinical-conformance/dicomkit-interop.jsonl" ]; then
    args+=(--interop-results ".build/clinical-conformance/dicomkit-interop.jsonl")
  fi
  python3 Scripts/clinical_conformance_report.py "${args[@]}"
}

# Heavy suites excluded from the quick gate. Keep this list in sync with the
# fixture/runtime gates below — everything skipped here must be owned by one
# of the other gates (or by the release gate's full run).
QUICK_SKIPS=(
  # Performance / stress / benchmark harnesses
  DCMDecoderPerformanceTests
  DCMPixelReaderPerformanceTests
  DCMWindowingProcessorPerformanceTests
  DicomSeriesLoaderPerformanceTests
  MemoryPoolPerformanceTests
  PerformanceBenchmarkSuite
  DCMDecoderStressTests
  # Streaming / memory-mapped IO
  DCMDecoderStreamingTests
  DCMDecoderMemoryMappedStreamingTests
  # Network / interop (preflight-gated)
  DicomDIMSENetworkTests
  DicomInteropSmokeTests
  DicomInteropScriptTests
  # Conformance fixtures (fixture gate)
  JPEGLosslessConformanceTests
  # CLI smoke tests spawn `swift run` subprocesses
  CLISmokeTests
)

# Fixture-focused suites: bundled synthetic fixtures plus curated non-PHI
# conformance/parity material. Deterministic, network-free.
FIXTURE_FILTERS=(
  ClinicalCodecConformanceManifestTests
  ClinicalCodecConformanceReportTests
  ClinicalInteropFixtureExportTests.test_committedClinicalObjectFixturesMatchDeterministicBuildersAndParse
  ClinicalParityFixtureManifestTests
  DCMDecoderIntegrationTests
  DCMPixelReaderInternalTests
  JPEGLosslessConformanceTests
  JPEGExtendedDecoderTests
  DicomCompressedPixelCodecMatrixTests
  DicomColorPixelDataTests
  DicomEncapsulatedPixelFrameReaderTests
  DicomEnhancedMultiframeVolumeTests
  DicomJLSwiftBackendTests
  DicomJXLSwiftBackendTests
  DicomSegmentationTests
  DicomRTObjectsTests
  DicomAIInferenceTests
  DicomQuantitativeValuesTests
  DicomEncapsulatedDocumentTests
  DicomWaveformTests
  DicomVideoTests
  TestFixturesIntegrationTests
)

case "$GATE" in
  quick)
    banner "quick (deterministic unit gate)"
    run_preflight_or_fail_fast
    SKIP_ARGS=()
    for suite in "${QUICK_SKIPS[@]}"; do
      SKIP_ARGS+=(--skip "$suite")
    done
    swift test "${SKIP_ARGS[@]}" 2>&1 | tee "$TEST_LOG"
    emit_coverage_summary
    echo "[gate=quick] PASSED"
    ;;

  fixture)
    banner "fixture (bundled + curated non-PHI fixtures)"
    run_preflight_or_fail_fast
    FILTER_ARGS=()
    for suite in "${FIXTURE_FILTERS[@]}"; do
      FILTER_ARGS+=(--filter "$suite")
    done
    swift test "${FILTER_ARGS[@]}" 2>&1 | tee "$TEST_LOG"
    emit_coverage_summary
    emit_clinical_conformance_report
    echo "[gate=fixture] PASSED"
    ;;

  runtime)
    banner "runtime/interop (preflight-gated optional coverage)"
    run_preflight_or_fail_fast
    PREFLIGHT_JSON="$(cat "$COVERAGE_DIR/preflight.json")"
    echo "$PREFLIGHT_JSON"

    capability_active() {
      python3 - "$1" <<'PY' "$PREFLIGHT_JSON"
import json
import sys
capability = sys.argv[1]
entries = json.loads(sys.argv[2])
status = next((e["status"] for e in entries if e["id"] == capability), None)
sys.exit(0 if status == "available" else 1)
PY
    }

    FILTER_ARGS=()
    add_if_active() { # <capability-id> <suite...>
      local capability="$1"; shift
      if capability_active "$capability"; then
        for suite in "$@"; do
          FILTER_ARGS+=(--filter "$suite")
        done
        echo "[gate=runtime] $capability active -> running: $*"
      else
        echo "[gate=runtime] $capability inactive -> skipping: $*"
      fi
    }

    add_if_active charls-runtime DicomLosslessCodecTests
    add_if_active j2kswift-backend DicomJ2KSwiftBackendTests DicomJ2KSwiftEncoderTests
    add_if_active jlswift-backend DicomJLSwiftBackendTests
    add_if_active jxlswift-backend DicomJXLSwiftBackendTests
    add_if_active openjpeg-runtime DicomLossyCodecBackendTests DicomJP3DVolumeDocumentTests
    add_if_active metal-device MetalWindowingTests
    add_if_active network-interop-smoke DicomInteropSmokeTests DicomDIMSENetworkTests
    # The codec preflight contract itself always runs in this gate.
    FILTER_ARGS+=(--filter DicomCodecRuntimePreflightTests --filter DicomTestRuntimePreflightTests)

    swift test "${FILTER_ARGS[@]}" 2>&1 | tee "$TEST_LOG"
    emit_coverage_summary
    emit_clinical_conformance_report
    echo "[gate=runtime] PASSED"
    ;;

  release)
    banner "release (full authoritative validation)"
    # Release determinism (issue #1230): a release candidate is only
    # acceptable when the JPEG-LS (CharLS) and JPEG 2000 (OpenJPEG) codec
    # backends are active — the preflight below fails fast otherwise.
    export DICOM_REQUIRE_CHARLS=1
    export DICOM_REQUIRE_OPENJPEG=1
    export DICOM_REQUIRE_OPJ_COMPRESS=1
    export DICOM_REQUIRE_LIBJXL_TOOLS=1
    run_preflight_or_fail_fast
    swift build -c release
    swift test 2>&1 | tee "$TEST_LOG"
    emit_coverage_summary
    emit_clinical_conformance_report
    echo "[gate=release] PASSED"
    ;;

  *)
    echo "unknown gate '$GATE' (expected quick|fixture|runtime|release)" >&2
    exit 2
    ;;
esac
