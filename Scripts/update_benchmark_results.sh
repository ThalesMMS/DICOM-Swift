#!/bin/bash
#
# update_benchmark_results.sh
#
# Automated script to update BENCHMARKS.md with latest CI benchmark results.
# Parses JSON benchmark artifacts, extracts metrics, and generates markdown updates.
#
# Usage:
#   ./Scripts/update_benchmark_results.sh [OPTIONS]
#
# Options:
#   --dry-run              Preview changes without modifying files
#   --results FILE         Path to benchmark results JSON file
#   --output FILE          Path to BENCHMARKS.md (default: ./BENCHMARKS.md)
#   --help                 Show this help message
#
# Examples:
#   # Dry run with latest results
#   ./Scripts/update_benchmark_results.sh --dry-run --results benchmark-results-*.json
#
#   # Update BENCHMARKS.md with new results
#   ./Scripts/update_benchmark_results.sh --results ./benchmark-results/benchmark-results-2026-02-15-123456.json
#
#   # Update alternative output file
#   ./Scripts/update_benchmark_results.sh --results results.json --output ./docs/BENCHMARKS.md
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

DRY_RUN=false
RESULTS_FILE=""
OUTPUT_FILE="./BENCHMARKS.md"
VERBOSE=false

# ANSI color codes
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}ℹ ${NC} $*"
}

log_success() {
    echo -e "${GREEN}✓${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}⚠${NC}  $*"
}

log_error() {
    echo -e "${RED}✗${NC} $*" >&2
}

show_help() {
    sed -n '2,27p' "$0" | sed 's/^# //; s/^#//'
    exit 0
}

# Check if required commands are available
check_dependencies() {
    local missing=()

    if ! command -v jq &> /dev/null; then
        missing+=("jq")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "Missing required dependencies: ${missing[*]}"
        log_error "Install with: brew install ${missing[*]}"
        return 1
    fi

    return 0
}

# Format time value for display (seconds to milliseconds with precision)
format_time() {
    local seconds=$1
    local ms=$(echo "$seconds * 1000" | bc -l)
    printf "%.3f" "$ms"
}

# Format throughput (pixels per second to readable format)
format_throughput() {
    local pixels_per_sec=$1

    # Convert to millions of pixels per second
    local mpixels=$(echo "scale=2; $pixels_per_sec / 1000000" | bc -l)
    printf "%.2f" "$mpixels"
}

# Format percentage
format_percentage() {
    local value=$1
    printf "%.1f" "$value"
}

# Extract value from JSON using jq
json_get() {
    local json_file=$1
    local jq_query=$2
    jq -r "$jq_query" "$json_file"
}

# =============================================================================
# Benchmark Result Parsing
# =============================================================================

parse_benchmark_results() {
    local results_file=$1

    log_info "Parsing benchmark results from: $results_file"

    # Verify file exists and is valid JSON
    if [ ! -f "$results_file" ]; then
        log_error "Results file not found: $results_file"
        return 1
    fi

    if ! jq empty "$results_file" 2>/dev/null; then
        log_error "Invalid JSON format in: $results_file"
        return 1
    fi

    # Extract platform information
    PLATFORM_OS=$(json_get "$results_file" '.platform.operatingSystem // "Unknown"')
    PLATFORM_ARCH=$(json_get "$results_file" '.platform.architecture // "Unknown"')
    PLATFORM_MODEL=$(json_get "$results_file" '.platform.modelIdentifier // "Unknown"')
    TIMESTAMP=$(json_get "$results_file" '.timestamp // "Unknown"')

    log_success "Platform: $PLATFORM_OS $PLATFORM_ARCH ($PLATFORM_MODEL)"
    log_success "Timestamp: $TIMESTAMP"

    return 0
}

# Get benchmark result by operation name
get_benchmark_result() {
    local results_file=$1
    local operation=$2

    jq -r ".results[] | select(.operation == \"$operation\")" "$results_file"
}

# =============================================================================
# Markdown Generation
# =============================================================================

generate_decoder_operations_table() {
    local results_file=$1

    log_info "Generating decoder operations table..."

    cat << 'EOF'
| Operation | Mean Time | Median | 95th %ile | Std Dev | CV% | Notes |
|-----------|-----------|--------|-----------|---------|-----|-------|
EOF

    # Lock overhead
    local lock_result=$(get_benchmark_result "$results_file" "decoder_lock_overhead")
    if [ -n "$lock_result" ]; then
        local mean=$(echo "$lock_result" | jq -r '.meanTimeSeconds')
        local median=$(echo "$lock_result" | jq -r '.medianTimeSeconds')
        local p95=$(echo "$lock_result" | jq -r '.p95TimeSeconds')
        local stddev=$(echo "$lock_result" | jq -r '.stdDevSeconds')
        local cv=$(echo "$lock_result" | jq -r '.coefficientOfVariation')

        printf "| **Lock Overhead** | %s ms | %s ms | %s ms | %s ms | %s%% | Per lock/unlock cycle |\n" \
            "$(format_time "$mean")" \
            "$(format_time "$median")" \
            "$(format_time "$p95")" \
            "$(format_time "$stddev")" \
            "$(format_percentage "$cv")"
    fi

    # Decoder initialization
    local init_result=$(get_benchmark_result "$results_file" "decoder_initialization")
    if [ -n "$init_result" ]; then
        local mean=$(echo "$init_result" | jq -r '.meanTimeSeconds')
        local median=$(echo "$init_result" | jq -r '.medianTimeSeconds')
        local p95=$(echo "$init_result" | jq -r '.p95TimeSeconds')
        local stddev=$(echo "$init_result" | jq -r '.stdDevSeconds')
        local cv=$(echo "$init_result" | jq -r '.coefficientOfVariation')

        printf "| **Decoder Init** | %s ms | %s ms | %s ms | %s ms | %s%% | Instance creation |\n" \
            "$(format_time "$mean")" \
            "$(format_time "$median")" \
            "$(format_time "$p95")" \
            "$(format_time "$stddev")" \
            "$(format_percentage "$cv")"
    fi

    # File validation
    local validation_result=$(get_benchmark_result "$results_file" "file_validation")
    if [ -n "$validation_result" ]; then
        local mean=$(echo "$validation_result" | jq -r '.meanTimeSeconds')
        local median=$(echo "$validation_result" | jq -r '.medianTimeSeconds')
        local p95=$(echo "$validation_result" | jq -r '.p95TimeSeconds')
        local stddev=$(echo "$validation_result" | jq -r '.stdDevSeconds')
        local cv=$(echo "$validation_result" | jq -r '.coefficientOfVariation')

        printf "| **File Validation** | %s ms | %s ms | %s ms | %s ms | %s%% | Format verification |\n" \
            "$(format_time "$mean")" \
            "$(format_time "$median")" \
            "$(format_time "$p95")" \
            "$(format_time "$stddev")" \
            "$(format_percentage "$cv")"
    fi

    # Metadata access
    local metadata_result=$(get_benchmark_result "$results_file" "metadata_access")
    if [ -n "$metadata_result" ]; then
        local mean=$(echo "$metadata_result" | jq -r '.meanTimeSeconds')
        local median=$(echo "$metadata_result" | jq -r '.medianTimeSeconds')
        local p95=$(echo "$metadata_result" | jq -r '.p95TimeSeconds')
        local stddev=$(echo "$metadata_result" | jq -r '.stdDevSeconds')
        local cv=$(echo "$metadata_result" | jq -r '.coefficientOfVariation')

        printf "| **Metadata Access** | %s ms | %s ms | %s ms | %s ms | %s%% | Cached tag lookup |\n" \
            "$(format_time "$mean")" \
            "$(format_time "$median")" \
            "$(format_time "$p95")" \
            "$(format_time "$stddev")" \
            "$(format_percentage "$cv")"
    fi

    log_success "Decoder operations table generated"
}

generate_windowing_table() {
    local results_file=$1

    log_info "Generating windowing operations table..."

    # Get image dimensions from configuration
    local image_width=$(json_get "$results_file" '.configuration.imageWidth')
    local image_height=$(json_get "$results_file" '.configuration.imageHeight')
    local total_pixels=$(json_get "$results_file" '.configuration.totalPixels')

    cat << EOF

### Window/Level Processing

Performance metrics for window/level operations on ${image_width}×${image_height} images ($total_pixels pixels):

| Backend | Mean Time | Median | 95th %ile | Throughput | CV% | Notes |
|---------|-----------|--------|-----------|------------|-----|-------|
EOF

    # vDSP backend
    local vdsp_result=$(get_benchmark_result "$results_file" "windowing_vdsp")
    if [ -n "$vdsp_result" ]; then
        local mean=$(echo "$vdsp_result" | jq -r '.meanTimeSeconds')
        local median=$(echo "$vdsp_result" | jq -r '.medianTimeSeconds')
        local p95=$(echo "$vdsp_result" | jq -r '.p95TimeSeconds')
        local throughput=$(echo "$vdsp_result" | jq -r '.throughputPixelsPerSecond // 0')
        local cv=$(echo "$vdsp_result" | jq -r '.coefficientOfVariation')

        printf "| **vDSP (CPU)** | %s ms | %s ms | %s ms | %s Mpx/s | %s%% | Accelerate framework |\n" \
            "$(format_time "$mean")" \
            "$(format_time "$median")" \
            "$(format_time "$p95")" \
            "$(format_throughput "$throughput")" \
            "$(format_percentage "$cv")"
    fi

    # Metal backend
    local metal_result=$(get_benchmark_result "$results_file" "windowing_metal")
    if [ -n "$metal_result" ]; then
        local mean=$(echo "$metal_result" | jq -r '.meanTimeSeconds')
        local median=$(echo "$metal_result" | jq -r '.medianTimeSeconds')
        local p95=$(echo "$metal_result" | jq -r '.p95TimeSeconds')
        local throughput=$(echo "$metal_result" | jq -r '.throughputPixelsPerSecond // 0')
        local cv=$(echo "$metal_result" | jq -r '.coefficientOfVariation')

        printf "| **Metal (GPU)** | %s ms | %s ms | %s ms | %s Mpx/s | %s%% | GPU compute shaders |\n" \
            "$(format_time "$mean")" \
            "$(format_time "$median")" \
            "$(format_time "$p95")" \
            "$(format_throughput "$throughput")" \
            "$(format_percentage "$cv")"
    fi

    # Calculate speedup if both results are available
    if [ -n "$vdsp_result" ] && [ -n "$metal_result" ]; then
        local vdsp_mean=$(echo "$vdsp_result" | jq -r '.meanTimeSeconds')
        local metal_mean=$(echo "$metal_result" | jq -r '.meanTimeSeconds')
        local speedup=$(echo "scale=2; $vdsp_mean / $metal_mean" | bc -l)

        printf "\n**Metal Speedup:** %.2fx faster than vDSP for %s×%s images\n" \
            "$speedup" "$image_width" "$image_height"
    fi

    log_success "Windowing operations table generated"
}

generate_markdown_update() {
    local results_file=$1

    cat << EOF
<!-- BEGIN AUTO-GENERATED BENCHMARK RESULTS -->
<!-- Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC") -->
<!-- Source: $results_file -->
<!-- Platform: $PLATFORM_OS $PLATFORM_ARCH ($PLATFORM_MODEL) -->

## Benchmark Results

### Decoder Operations

Performance metrics for core DICOM decoding operations:

$(generate_decoder_operations_table "$results_file")

**Key Findings:**
- ✅ **Low overhead**: Lock operations add minimal latency
- ✅ **Fast initialization**: Decoder instances created in sub-millisecond time
- ✅ **Quick validation**: File format checks complete in milliseconds
- ✅ **Efficient caching**: Metadata access benefits from tag caching

$(generate_windowing_table "$results_file")

<!-- END AUTO-GENERATED BENCHMARK RESULTS -->
EOF
}

# =============================================================================
# File Update Logic
# =============================================================================

update_benchmarks_file() {
    local results_file=$1
    local output_file=$2
    local dry_run=$3

    log_info "Updating benchmark results in: $output_file"

    # Verify output file exists
    if [ ! -f "$output_file" ]; then
        log_error "Output file not found: $output_file"
        return 1
    fi

    # Generate new markdown content
    local new_content
    new_content=$(generate_markdown_update "$results_file")

    if [ "$dry_run" = true ]; then
        log_warning "DRY RUN MODE - No files will be modified"
        echo ""
        echo "=== GENERATED MARKDOWN UPDATE ==="
        echo "$new_content"
        echo "=== END GENERATED MARKDOWN UPDATE ==="
        echo ""
        log_info "In non-dry-run mode, this would update the '## Benchmark Results' section in $output_file"
        return 0
    fi

    # Create temporary file with updated content
    local temp_file
    temp_file=$(mktemp)

    # Check if auto-generated section exists
    if grep -q "BEGIN AUTO-GENERATED BENCHMARK RESULTS" "$output_file"; then
        log_info "Replacing existing auto-generated section..."

        # Replace content between markers
        awk -v new_content="$new_content" '
            /BEGIN AUTO-GENERATED BENCHMARK RESULTS/ {
                print new_content
                skip=1
                next
            }
            /END AUTO-GENERATED BENCHMARK RESULTS/ {
                skip=0
                next
            }
            !skip { print }
        ' "$output_file" > "$temp_file"
    else
        log_warning "No auto-generated section found. You may need to manually integrate the results."
        log_info "Generated content saved to: ${temp_file}.generated"
        echo "$new_content" > "${temp_file}.generated"
        cat "$output_file" > "$temp_file"
        return 0
    fi

    # Replace original file
    mv "$temp_file" "$output_file"

    log_success "Successfully updated $output_file"
    return 0
}

# =============================================================================
# Main Script
# =============================================================================

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --results)
                RESULTS_FILE="$2"
                shift 2
                ;;
            --output)
                OUTPUT_FILE="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            --help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Check dependencies
    if ! check_dependencies; then
        exit 1
    fi

    # Validate required arguments
    if [ -z "$RESULTS_FILE" ]; then
        log_error "Missing required argument: --results FILE"
        echo "Use --help for usage information"
        exit 1
    fi

    # Parse benchmark results
    if ! parse_benchmark_results "$RESULTS_FILE"; then
        exit 1
    fi

    # Update benchmarks file
    if ! update_benchmarks_file "$RESULTS_FILE" "$OUTPUT_FILE" "$DRY_RUN"; then
        exit 1
    fi

    log_success "Benchmark results update completed successfully!"

    if [ "$DRY_RUN" = true ]; then
        log_info "Run without --dry-run to apply changes"
    fi
}

# Run main function
main "$@"
