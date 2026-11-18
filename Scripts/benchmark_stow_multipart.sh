#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPOSITORY_DIR="$(cd "$PACKAGE_DIR/.." && pwd)"
source "$REPOSITORY_DIR/Tools/Scripts/xcode_common.sh"
ensure_xcodebuild

ITERATIONS="${DICOMWEB_STOW_MULTIPART_BENCHMARK_ITERATIONS:-5}"
INSTANCES="${DICOMWEB_STOW_MULTIPART_BENCHMARK_INSTANCES:-64}"
PAYLOAD_BYTES="${DICOMWEB_STOW_MULTIPART_BENCHMARK_PAYLOAD_BYTES:-1048576}"
SCRATCH_PATH="${DICOMWEB_STOW_MULTIPART_SCRATCH_PATH:-${TMPDIR:-/tmp}/dicomweb-stow-multipart-benchmark}"
LOG_DIR="$REPOSITORY_DIR/Tools/Logs"
LOG_FILE="$LOG_DIR/dicomweb-stow-multipart-benchmark-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"

echo "Scratch path: $SCRATCH_PATH"
echo "Writing log: $LOG_FILE"

command_exit=0
for mode in legacy preallocated; do
  echo "Running mode: $mode" | tee -a "$LOG_FILE"
  set +e
  DICOMWEB_STOW_MULTIPART_BENCHMARK=1 \
  DICOMWEB_STOW_MULTIPART_BENCHMARK_MODE="$mode" \
  DICOMWEB_STOW_MULTIPART_BENCHMARK_ITERATIONS="$ITERATIONS" \
  DICOMWEB_STOW_MULTIPART_BENCHMARK_INSTANCES="$INSTANCES" \
  DICOMWEB_STOW_MULTIPART_BENCHMARK_PAYLOAD_BYTES="$PAYLOAD_BYTES" \
  swift test --package-path "$PACKAGE_DIR" \
    --scratch-path "$SCRATCH_PATH" \
    -c release \
    --jobs 2 \
    --filter DicomWebSTOWMultipartBenchmarkTests/test_releaseMultiInstanceBody \
    >> "$LOG_FILE" 2>&1
  mode_exit=$?
  set -e
  if [[ "$mode_exit" -ne 0 ]]; then
    command_exit="$mode_exit"
    break
  fi
done

echo
echo "Benchmark summary:"
grep 'DICOMWEB_STOW_MULTIPART_BENCHMARK mode=' "$LOG_FILE" || true

if [[ "$command_exit" -eq 0 ]]; then
  metric_count="$(grep -c 'DICOMWEB_STOW_MULTIPART_BENCHMARK mode=' "$LOG_FILE" || true)"
  if [[ "$metric_count" -ne 2 ]]; then
    echo "Expected two benchmark metrics, found $metric_count; inspect $LOG_FILE" >&2
    command_exit=1
  fi
fi

if [[ "$command_exit" -eq 0 ]]; then
  legacy_hash="$(grep 'DICOMWEB_STOW_MULTIPART_BENCHMARK mode=legacy ' "$LOG_FILE" | sed -E 's/.* body_hash=([0-9]+).*/\1/')"
  preallocated_hash="$(grep 'DICOMWEB_STOW_MULTIPART_BENCHMARK mode=preallocated ' "$LOG_FILE" | sed -E 's/.* body_hash=([0-9]+).*/\1/')"
  if [[ "$legacy_hash" != "$preallocated_hash" ]]; then
    echo "Legacy and preallocated wire-body hashes differ; inspect $LOG_FILE" >&2
    command_exit=1
  fi
fi

if [[ "$command_exit" -ne 0 ]]; then
  tail -n 100 "$LOG_FILE" >&2
fi

exit "$command_exit"
