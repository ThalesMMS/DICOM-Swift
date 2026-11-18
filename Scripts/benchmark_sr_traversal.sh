#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOSITORY_DIR="$(cd "$PACKAGE_DIR/.." && pwd)"
source "$REPOSITORY_DIR/Tools/Scripts/xcode_common.sh"
ensure_xcodebuild

ITERATIONS="${DICOM_SR_TRAVERSAL_BENCHMARK_ITERATIONS:-7}"
SCRATCH_PATH="${DICOM_SR_TRAVERSAL_SCRATCH_PATH:-${TMPDIR:-/tmp}/dicom-sr-traversal-benchmark}"
LOG_DIR="$REPOSITORY_DIR/Tools/Logs"
LOG_FILE="$LOG_DIR/dicom-sr-traversal-benchmark-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"

echo "Scratch path: $SCRATCH_PATH"
echo "Writing log: $LOG_FILE"

set +e
DICOM_SR_TRAVERSAL_BENCHMARK=1 \
DICOM_SR_TRAVERSAL_BENCHMARK_ITERATIONS="$ITERATIONS" \
swift test --package-path "$PACKAGE_DIR" \
  --scratch-path "$SCRATCH_PATH" \
  -c release \
  --jobs 2 \
  --filter DicomStructuredReportBenchmarkTests \
  > "$LOG_FILE" 2>&1
command_exit=$?
set -e

echo
echo "Benchmark summary:"
grep 'DICOM_SR_TRAVERSAL_BENCHMARK' "$LOG_FILE" || true

if [[ "$command_exit" -eq 0 ]]; then
  metric_count="$(grep -c 'DICOM_SR_TRAVERSAL_BENCHMARK' "$LOG_FILE" || true)"
  if [[ "$metric_count" -ne 4 ]]; then
    echo "Expected four benchmark metrics, found $metric_count; inspect $LOG_FILE" >&2
    command_exit=1
  fi
fi

if [[ "$command_exit" -ne 0 ]]; then
  tail -n 100 "$LOG_FILE" >&2
fi

exit "$command_exit"
