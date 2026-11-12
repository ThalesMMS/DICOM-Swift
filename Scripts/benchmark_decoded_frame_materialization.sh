#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "${script_dir}/.." && pwd)"
output_dir="${CLINICAL_PERFORMANCE_OUTPUT_DIR:-${package_dir}/.build/clinical-performance/decoded-frame-materialization}"

scenarios=(
    native-gray8
    native-gray16-signed
    native-rgb8
    rle-gray8
    jpeg-lossless-gray16
    jpeg-ls-gray16-signed
    jpeg2000-gray16
    jpeg2000-rgb8
    native-gray8-multiframe
)

mkdir -p "${output_dir}"

for run in 1 2; do
    for scenario in "${scenarios[@]}"; do
        scenario_output="${output_dir}/run-${run}/${scenario}"
        mkdir -p "${scenario_output}"
        DICOM_DECODED_FRAME_MATERIALIZATION_BENCHMARK=1 \
        DICOM_DECODED_FRAME_SCENARIO="${scenario}" \
        DICOM_DECODED_FRAME_RUN="${run}" \
        DICOM_J2KSWIFT_MODE=forced-for-tests \
        DICOM_JLSWIFT_MODE=forced-for-tests \
        CLINICAL_PERFORMANCE_TIER=release \
        CLINICAL_PERFORMANCE_OUTPUT_DIR="${scenario_output}" \
            swift test --package-path "${package_dir}" -c release --jobs 2 \
                --filter DicomDecodedFrameMaterializationBenchmarkTests/test_releaseDecodedFrameMaterialization_reportsColdWarmDecodeAndMaterializationStages
    done
done

echo "Decoded-frame materialization reports: ${output_dir}"
