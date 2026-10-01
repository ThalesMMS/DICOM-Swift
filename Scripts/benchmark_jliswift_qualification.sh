#!/usr/bin/env bash

# Runs issue #2094's opt-in benchmark twice in isolated Release XCTest processes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$PACKAGE_ROOT/.." && pwd)"
SIZE="${DICOM_JLISWIFT_BENCHMARK_SIZE:-512}"
ITERATIONS="${DICOM_JLISWIFT_BENCHMARK_ITERATIONS:-20}"
WARMUPS="${DICOM_JLISWIFT_BENCHMARK_WARMUPS:-3}"
OUTPUT_ROOT="${CLINICAL_PERFORMANCE_OUTPUT_DIR:-$PACKAGE_ROOT/.build/jliswift-qualification}"
JLISWIFT_CHECKOUT="${JLISWIFT_CHECKOUT:-$WORKSPACE_ROOT/../JLISwift}"

if ! grep -q 'JLISwift' "$PACKAGE_ROOT/Package.swift"; then
    echo "JLISwift is not declared in DICOM-Swift/Package.swift; qualification cannot run." >&2
    echo "This script intentionally does not alter the dependency graph." >&2
    exit 2
fi

if [[ ! -d "$JLISWIFT_CHECKOUT/.git" ]]; then
    echo "JLISwift checkout not found at $JLISWIFT_CHECKOUT; set JLISWIFT_CHECKOUT." >&2
    exit 2
fi

DICOM_SWIFT_REVISION="$(git -C "$WORKSPACE_ROOT" rev-parse HEAD):$(git -C "$WORKSPACE_ROOT" rev-parse HEAD:DICOM-Swift)"
JLISWIFT_REVISION="$(git -C "$JLISWIFT_CHECKOUT" rev-parse HEAD)"
TEST_FILTER='DicomJLISwiftQualificationBenchmarkTests/test_releaseGray16SV1_reportsFirstCallWarmTimingCopiesAndMemory'

for RUN in 1 2; do
    RUN_OUTPUT="$OUTPUT_ROOT/run-$RUN"
    mkdir -p "$RUN_OUTPUT"
    echo "==> JLISwift qualification isolated run $RUN (Release, ${SIZE}x${SIZE})"
    env \
        DICOM_JLISWIFT_BENCHMARK=1 \
        DICOM_JLISWIFT_ISOLATED_RUN="$RUN" \
        DICOM_JLISWIFT_BENCHMARK_SIZE="$SIZE" \
        DICOM_JLISWIFT_BENCHMARK_ITERATIONS="$ITERATIONS" \
        DICOM_JLISWIFT_BENCHMARK_WARMUPS="$WARMUPS" \
        DICOM_SWIFT_REVISION="$DICOM_SWIFT_REVISION" \
        JLISWIFT_REVISION="$JLISWIFT_REVISION" \
        CLINICAL_PERFORMANCE_TIER=release \
        CLINICAL_PERFORMANCE_OUTPUT_DIR="$RUN_OUTPUT" \
        swift test --package-path "$PACKAGE_ROOT" -c release --filter "$TEST_FILTER"

    for STEM in dicom-jliswift-qualification-first dicom-jliswift-qualification-warm; do
        for FORMAT in json csv md; do
            ARTIFACT="$RUN_OUTPUT/$STEM.$FORMAT"
            if [[ ! -s "$ARTIFACT" ]]; then
                echo "Missing qualification artifact: $ARTIFACT" >&2
                exit 1
            fi
        done
    done
done

echo "JLISwift qualification completed in two isolated processes."
echo "Artifacts: $OUTPUT_ROOT/run-1 and $OUTPUT_ROOT/run-2"
echo "Native/GDCM encode comparator: N/A (not implemented/exposed)."
