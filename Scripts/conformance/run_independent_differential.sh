#!/usr/bin/env bash
# Issue #2366: hermetic XCTest plus an explicitly required independent reader.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ORACLE_PYTHON="${DICOM_DIFFERENTIAL_PYTHON:-python3}"
RUN_PARENT="${DICOM_DIFFERENTIAL_OUTPUT_ROOT:-.build/clinical-conformance}"
mkdir -p "$RUN_PARENT"
RUN_DIR="$(mktemp -d "$RUN_PARENT/differential.XXXXXX")"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
export DICOM_DIFFERENTIAL_REWRITE_DIR="$RUN_DIR/rewrites"
mkdir -p "$DICOM_DIFFERENTIAL_REWRITE_DIR"

"$ORACLE_PYTHON" - <<'PY' > "$RUN_DIR/preflight.json"
import json
import sys
if sys.version_info < (3, 12):
    sys.exit("Conformance oracles require Python 3.12 or newer; set DICOM_DIFFERENTIAL_PYTHON to a compatible interpreter.")
import numpy
import pydicom
print(json.dumps([{"id": "pydicom-differential", "kind": "oracle", "required": True,
                   "status": "available", "message": f"pydicom {pydicom.__version__}; NumPy {numpy.__version__}"}]))
PY

TEST_STATUS=0
swift test --filter 'ClinicalIndependentCorpusTests|ClinicalAdversarialCorpusTests|ClinicalMetadataRepresentationTests|DCMDecoderSecurityTests|DicomWebClientTests|ClinicalCodecConformanceManifestTests|ClinicalCodecConformanceReportTests' \
  2>&1 | tee "$RUN_DIR/test.log" || TEST_STATUS=$?
ORACLE_STATUS=0
INTEROP_ARGS=()
if [ "$TEST_STATUS" -eq 0 ]; then
  "$ORACLE_PYTHON" Scripts/conformance/independent_differential_corpus.py \
    --manifest Tests/DicomCoreTests/Fixtures/IndependentDifferential/manifest.json \
    --verify-swift-output "$DICOM_DIFFERENTIAL_REWRITE_DIR" \
    --report "$RUN_DIR/interop.jsonl" --self-test-mutations || ORACLE_STATUS=$?
  if [ -f "$RUN_DIR/interop.jsonl" ]; then
    INTEROP_ARGS=(--interop-results "$RUN_DIR/interop.jsonl")
  fi
fi
"$ORACLE_PYTHON" Scripts/clinical_conformance_report.py \
  --manifest Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalCodecConformanceManifest.json \
  --preflight "$RUN_DIR/preflight.json" --test-log "$RUN_DIR/test.log" \
  ${INTEROP_ARGS[@]+"${INTEROP_ARGS[@]}"} --output-dir "$RUN_DIR/report" \
  --gate differential --enforce-required
if [ "$TEST_STATUS" -ne 0 ] || [ "$ORACLE_STATUS" -ne 0 ]; then
  exit 1
fi
echo "Independent differential gate passed. Evidence: $RUN_DIR/report"
