#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "${script_dir}/.." && pwd)"

modes=(indexed-frames stream-only)

for run in 1 2; do
    for mode in "${modes[@]}"; do
        echo "Video parsing benchmark: run=${run} mode=${mode}"
        DICOM_VIDEO_PARSING_BENCHMARK=1 \
        DICOM_VIDEO_PARSING_MODE="${mode}" \
            swift test --package-path "${package_dir}" -c release --jobs 2 \
                --filter DicomVideoParsingBenchmarkTests/test_videoPayloadMode_reportsIsolatedParsingMetrics
    done
done
