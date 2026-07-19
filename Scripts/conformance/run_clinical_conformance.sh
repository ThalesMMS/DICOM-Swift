#!/usr/bin/env bash
# Canonical entry point for the issue #1435 clinical conformance matrix.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

GATE="${1:-}"
case "$GATE" in
  fixture|runtime|release)
    Scripts/test_gates.sh "$GATE"
    ;;
  nightly)
    Scripts/test_gates.sh runtime
    DICOM_CONFORMANCE_INTEROP_RESULTS=.build/clinical-conformance/dicomkit-interop.jsonl \
      Scripts/conformance/run_dicomkit_interop.sh
    python3 Scripts/clinical_conformance_report.py \
      --manifest Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalCodecConformanceManifest.json \
      --preflight .build/runtime-coverage/runtime/preflight.json \
      --test-log .build/runtime-coverage/runtime/test.log \
      --interop-results .build/clinical-conformance/dicomkit-interop.jsonl \
      --output-dir .build/runtime-coverage/nightly/clinical-conformance \
      --gate nightly \
      --enforce-required
    ;;
  *)
    echo "usage: Scripts/conformance/run_clinical_conformance.sh <fixture|runtime|release|nightly>" >&2
    exit 2
    ;;
esac
