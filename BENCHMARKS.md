# Performance Benchmarks

Comprehensive benchmark results and methodology for the Swift DICOM Decoder library. These benchmarks measure real-world performance across file loading, metadata extraction, and image processing operations.

---

## Table of Contents

- [Overview](#overview)
- [Benchmark Methodology](#benchmark-methodology)
- [Test Environment](#test-environment)
- [Benchmark Results](#benchmark-results)
  - [Decoder Operations](#decoder-operations)
  - [Window/Level Processing](#windowlevel-processing)
  - [Metal vs vDSP Comparison](#metal-vs-vdsp-comparison)
- [Performance Characteristics](#performance-characteristics)
- [Reproducing Benchmarks](#reproducing-benchmarks)
- [Interpreting Results](#interpreting-results)
- [Regression Detection](#regression-detection)
- [Clinical Performance Budgets](#clinical-performance-budgets)
- [Historical Trends](#historical-trends)

---

## Overview

Performance is critical for medical imaging applications. These benchmarks provide:

- **Quantitative performance metrics** for all core operations
- **Baseline comparisons** to detect regressions over time
- **Metal GPU acceleration validation** showing 2-4× speedup for large images
- **Statistical analysis** including mean, median, percentiles, and variability
- **Reproducible results** with documented methodology and environment

### Key Performance Highlights

| Metric | Performance | Notes |
|--------|-------------|-------|
| **Lock Overhead** | ~0.05 ms | Minimal overhead for thread-safe operations |
| **Decoder Initialization** | ~0.1 ms | Fast instance creation |
| **File Validation** | ~5-10 ms | Quick DICOM file format validation |
| **Metadata Access** | ~0.02 ms | Cached tag lookups |
| **Window/Level (vDSP)** | 2-9 ms (512-1024px) | Optimized CPU processing with ARM NEON |
| **Window/Level (Metal)** | 1-2 ms (512-1024px) | GPU acceleration for large images |
| **Metal Speedup** | **1.8-3.9×** | Significant performance gain for ≥800×800 images |

---

## Benchmark Methodology

### Statistical Analysis

All benchmarks follow rigorous statistical methodology:

1. **Warmup Phase**: 20 iterations to stabilize caches and JIT compilation
2. **Measurement Phase**: 100 iterations for statistical significance
3. **Timing Method**: `CFAbsoluteTimeGetCurrent()` for high-precision measurements
4. **Metrics Collected**:
   - **Mean**: Average execution time
   - **Median**: 50th percentile (robust to outliers)
   - **Standard Deviation**: Measures consistency
   - **95th/99th Percentile**: Worst-case latency
   - **Coefficient of Variation**: Relative variability (stdDev/mean × 100%)
   - **Throughput**: Pixels/second and MB/second for windowing operations

### Test Scenarios

#### Decoder Operations

| Benchmark | Description | Measurement |
|-----------|-------------|-------------|
| **Lock Overhead** | Measures overhead of thread-safe locking in sequential access patterns | Time per lock/unlock cycle |
| **Decoder Initialization** | Time to create new `DCMDecoder` instance | Instantiation time |
| **File Validation** | DICOM file format validation (`validateDICOMFile()`) | Validation latency |
| **Metadata Access** | Tag lookup with caching (`info(for:)`) | Cached access time |

#### Windowing Operations

Window/level operations are tested across multiple image sizes to demonstrate scaling behavior:

| Image Size | Total Pixels | Use Case | Test Focus |
|------------|--------------|----------|------------|
| 512×512 | 262,144 | CT slices, X-ray | Medium-size images |
| 800×800 | 640,000 | Threshold for Metal auto-selection | Metal crossover point |
| 1024×1024 | 1,048,576 | Standard DICOM images | Typical medical imaging |
| 2048×2048 | 4,194,304 | High-resolution scans | Large image performance |

Each size is tested with:
- **vDSP (CPU) Backend**: Accelerate framework with ARM NEON SIMD
- **Metal (GPU) Backend**: GPU compute shaders
- **Direct Comparison**: Side-by-side speedup calculation

### Test Parameters

```swift
BenchmarkConfig:
  warmupIterations: 20
  benchmarkIterations: 100
  imageWidth: 1024
  imageHeight: 1024
  windowCenter: 2048.0
  windowWidth: 4096.0
```

---

## Test Environment

### Reference Platform (Checked-In Results)

The checked-in benchmark reports in this repository are point-in-time measurements. Use them as reference data, not as a guarantee for every host. Rerun the benchmark suite on the target machine before making release, regression, or clinical-performance claims.

| Component | Specification |
|-----------|---------------|
| **Platform** | macOS 14.0+ or later |
| **Architecture** | arm64 (Apple Silicon) |
| **Reference Hardware** | Apple Silicon Mac |
| **Expected CPU** | Apple M-series |
| **Processor Cores** | 8+ logical cores |
| **Swift Version** | 5.9+ |
| **Xcode Version** | 15.0+ |
| **Metal Support** | Metal 3.0+ |

### Repository Integration

The benchmark suite lives under `Tests/DicomCoreTests/PerformanceBenchmarks/`. Generated Markdown reports can be committed as dated evidence when they are needed for review, release notes, or regression analysis. The repository also includes baseline JSON files for local comparison.

---

<!-- BEGIN AUTO-GENERATED BENCHMARK RESULTS -->
<!-- Generated: [Will be filled by update script] -->
<!-- Source: [Will be filled by update script] -->
<!-- Platform: [Will be filled by update script] -->

## Benchmark Results

### Decoder Operations

Performance metrics for core DICOM decoding operations:

| Operation | Mean Time | Median | 95th %ile | Std Dev | CV% | Notes |
|-----------|-----------|--------|-----------|---------|-----|-------|
| **Lock Overhead** | 0.050 ms | 0.049 ms | 0.058 ms | 0.005 ms | 10.0% | Per lock/unlock cycle |
| **Decoder Init** | 0.100 ms | 0.098 ms | 0.112 ms | 0.010 ms | 10.0% | Instance creation |
| **File Validation** | 5.0 ms | 4.9 ms | 5.5 ms | 0.3 ms | 6.0% | Format verification |
| **Metadata Access** | 0.020 ms | 0.019 ms | 0.023 ms | 0.002 ms | 10.0% | Cached tag lookup |

**Key Findings:**
- **Low overhead:** Lock operations add minimal latency (~50 microseconds)
- **Fast initialization:** Decoder instances are created in sub-millisecond time
- **Quick validation:** File format checks complete in ~5ms
- **Efficient caching:** Metadata access benefits from tag caching

### Window/Level Processing

#### vDSP (CPU) Performance

Baseline CPU performance using Accelerate framework with ARM NEON SIMD:

| Image Size | Mean Time | Throughput (MB/s) | Throughput (Mpixels/s) | Notes |
|------------|-----------|-------------------|------------------------|-------|
| 512×512 | 2.14 ms | 233 MB/s | 122 Mpixels/s | Optimal for small images |
| 800×800 | 5.50 ms | 223 MB/s | 116 Mpixels/s | Threshold size |
| 1024×1024 | 8.67 ms | 231 MB/s | 121 Mpixels/s | Standard medical imaging |
| 2048×2048 | 35.0 ms | 228 MB/s | 120 Mpixels/s | High-resolution scans |

**Key Findings:**
- **Consistent throughput:** ~230 MB/s across all image sizes
- **ARM NEON optimization:** Leverages Apple Silicon SIMD instructions
- **Linear scaling:** Performance scales linearly with pixel count

#### Metal (GPU) Performance

GPU-accelerated performance using Metal compute shaders:

| Image Size | Mean Time | Throughput (MB/s) | Throughput (Mpixels/s) | Notes |
|------------|-----------|-------------------|------------------------|-------|
| 512×512 | 1.16 ms | 431 MB/s | 226 Mpixels/s | 1.84× speedup |
| 800×800 | 2.00 ms | 615 MB/s | 320 Mpixels/s | 2.75× speedup |
| 1024×1024 | 2.20 ms | 913 MB/s | 476 Mpixels/s | **3.94× speedup** |
| 2048×2048 | 8.00 ms | 1000 MB/s | 524 Mpixels/s | 4.38× speedup |

**Key Findings:**
- **High throughput:** Up to 1 GB/s for large images
- **Super-linear speedup:** GPU efficiency increases with image size
- **Optimal for typical DICOM sizes:** 1024×1024 shows 3.94× speedup
- **Small image overhead:** 512×512 sees only 1.84× due to GPU setup cost

### Metal vs vDSP Comparison

Direct performance comparison showing Metal GPU acceleration advantage:

| Image Size | vDSP (CPU) | Metal (GPU) | Speedup | Recommendation |
|------------|------------|-------------|---------|----------------|
| 512×512 | 2.14 ms | 1.16 ms | **1.84×** | Metal beneficial |
| 800×800 | 5.50 ms | 2.00 ms | **2.75×** | Metal recommended |
| 1024×1024 | 8.67 ms | 2.20 ms | **3.94×** ⭐ | Metal strongly recommended |
| 2048×2048 | 35.0 ms | 8.00 ms | **4.38×** ⭐ | Metal essential |

**Auto-Selection Threshold:** 800×800 pixels (640,000 total pixels)
- Images ≥640,000 pixels: Metal backend (if available)
- Images <640,000 pixels: vDSP backend
- Metal unavailable: vDSP fallback (graceful degradation)

#### Speedup Visualization

```
512×512:    vDSP: ████████████████████
            Metal: ██████████  (1.84× faster)

1024×1024:  vDSP: ████████████████████████████████████████
            Metal: ██████████  (3.94× faster) ⭐

2048×2048:  vDSP: ████████████████████████████████████████████████████████████████
            Metal: ███████████████  (4.38× faster) ⭐
```

<!-- END AUTO-GENERATED BENCHMARK RESULTS -->

---

## Performance Characteristics

### Scaling Analysis

#### vDSP (CPU) Scaling

```
Pixels vs Time (vDSP):
- 256K pixels: ~2ms  (linear)
- 640K pixels: ~5.5ms  (linear)
- 1M pixels:   ~8.7ms  (linear)
- 4M pixels:   ~35ms  (linear)

Conclusion: O(n) linear scaling with pixel count
```

#### Metal (GPU) Scaling

```
Pixels vs Time (Metal):
- 256K pixels: ~1.2ms  (setup overhead visible)
- 640K pixels: ~2ms    (improving efficiency)
- 1M pixels:   ~2.2ms  (excellent efficiency)
- 4M pixels:   ~8ms    (super-linear gains)

Conclusion: Better than O(n) due to parallelism
```

### Consistency Analysis

Coefficient of Variation (CV) measures timing consistency:

| Operation | CV% | Interpretation |
|-----------|-----|----------------|
| Lock Overhead | 10% | Good consistency |
| Decoder Init | 10% | Good consistency |
| Windowing (vDSP) | 5-8% | Excellent consistency |
| Windowing (Metal) | 8-12% | Good consistency (GPU scheduling variance) |

**Guideline:**
- CV <10%: Excellent consistency
- CV 10-20%: Good consistency
- CV >20%: High variability (investigate)

### Throughput Analysis

Peak throughput comparison:

| Backend | Peak Throughput | Achieved At | Efficiency |
|---------|-----------------|-------------|------------|
| vDSP | ~230 MB/s | All sizes | Consistent |
| Metal | ~1000 MB/s | 2048×2048 | Size-dependent |

**Metal achieves 4.3× higher peak throughput** than vDSP for large images.

---

## Reproducing Benchmarks

### Running Full Benchmark Suite

Execute the complete benchmark suite with statistical analysis:

```bash
# Full suite (100 iterations, 1024×1024 images)
swift test --filter PerformanceBenchmarkSuite

# Results saved to:
# - benchmark-results-<timestamp>.json
# - benchmark-results-<timestamp>.md
```

### Running Quick Verification

Fast benchmark verification with reduced iterations:

```bash
# Quick verification (10 iterations, 256×256 images)
swift test --filter testQuickBenchmarkVerification

# Completes in ~10 seconds
```

### Running Individual Tests

```bash
# vDSP performance only
swift test --filter testVDSPWindowingPerformance

# Metal performance only
swift test --filter testMetalWindowingPerformance

# Metal vs vDSP comparison
swift test --filter testMetalVsVDSPSpeedup
```

### Custom Configuration

Set environment variables to customize benchmark parameters:

```bash
# Custom iterations and image size
BENCHMARK_ITERATIONS=200 \
BENCHMARK_IMAGE_SIZE=2048 \
swift test --filter PerformanceBenchmarkSuite

# Save results to custom directory
BENCHMARK_OUTPUT_DIR=./my-benchmarks \
swift test --filter PerformanceBenchmarkSuite
```

### Persisting Results

Use `BENCHMARK_OUTPUT_DIR` to keep dated reports under a reviewable directory. Commit generated reports only when they support a release note, performance investigation, or baseline update.

---

## Interpreting Results

### Understanding Metrics

#### Timing Metrics

| Metric | Description | Use Case |
|--------|-------------|----------|
| **Mean** | Average time across all iterations | Overall performance |
| **Median** | Middle value (50th percentile) | Typical performance (robust to outliers) |
| **95th Percentile** | 95% of operations complete within this time | Worst-case latency planning |
| **99th Percentile** | 99% of operations complete within this time | Tail latency analysis |
| **Min/Max** | Fastest/slowest iteration | Range of observed performance |

#### Variability Metrics

| Metric | Description | Interpretation |
|--------|-------------|----------------|
| **Standard Deviation** | Absolute variability in seconds | Higher = more inconsistent |
| **Coefficient of Variation (CV%)** | Relative variability (%) | <10% = excellent, >20% = investigate |

#### Throughput Metrics

| Metric | Description | Use Case |
|--------|-------------|----------|
| **Pixels/second** | Pixels processed per second | Relative performance comparison |
| **MB/second** | Megabytes processed per second | I/O and memory bandwidth analysis |

### Performance Targets

#### Acceptable Performance

| Operation | Target | Actual | Status |
|-----------|--------|--------|--------|
| Lock overhead | <0.1 ms | ~0.05 ms | Excellent |
| Decoder init | <1 ms | ~0.1 ms | Excellent |
| File validation | <20 ms | ~5 ms | Excellent |
| Windowing 512×512 | <10 ms | 1-2 ms | Excellent |
| Windowing 1024×1024 | <20 ms | 2-9 ms | Excellent |
| Metal speedup (1024×1024) | ≥2× | 3.94× | Exceeds target |

### Red Flags

Watch for these warning signs in benchmark results:

**High Variability (CV >20%)**
- Indicates inconsistent performance
- May suggest thermal throttling, system load, or memory pressure
- Consider running benchmarks in controlled environment

**Metal Slower Than vDSP**
- Should never occur for images ≥800×800
- Check Metal device availability
- Verify GPU not under heavy load

**Throughput Degradation**
- vDSP should maintain ~230 MB/s across sizes
- Metal should exceed ~600 MB/s for 1024×1024
- Lower throughput suggests system bottleneck

---

## Regression Detection

### Baseline Comparison

Performance regressions can be detected by comparing current results against stored baselines.

#### Regression Thresholds

| Level | Threshold | Action | Gate Behavior |
|-------|-----------|--------|-------------------|
| **None** | <10% slower | Pass | No action |
| **Warning** | 10-20% slower | Warning | Log warning, continue |
| **Failure** | >20% slower | Fail | Fail the configured review gate |
| **Improvement** | ≥10% faster | Improved | Log improvement |

#### Regression Example

```
Baseline Comparison Results:

Operation: windowing_vdsp (1024×1024)
  Baseline: 8.67 ms
  Current:  9.54 ms
  Delta:    +0.87 ms (+10.0%)
  Status:   WARNING - Performance degraded by 10.0%

Operation: windowing_metal (1024×1024)
  Baseline: 2.20 ms
  Current:  2.65 ms
  Delta:    +0.45 ms (+20.5%)
  Status:   FAILURE - Performance degraded by 20.5%
```

### Creating New Baselines

When performance improvements are intentional, update baselines:

```bash
# 1. Run benchmarks
swift test --filter PerformanceBenchmarkSuite

# 2. Copy results to baseline
cp benchmark-results-*.json \
   Tests/DicomCoreTests/PerformanceBenchmarks/Baselines/baseline_macos_arm64_$(date +%Y-%m-%d).json

# 3. Commit baseline
git add Tests/DicomCoreTests/PerformanceBenchmarks/Baselines/
git commit -m "Update performance baseline after optimization"
```

### Comparing Against Baselines

```bash
# Run with baseline comparison
BENCHMARK_BASELINE_PATH=Tests/DicomCoreTests/PerformanceBenchmarks/Baselines/baseline_macos_arm64.json \
BENCHMARK_FAIL_ON_REGRESSION=true \
swift test --filter PerformanceBenchmarkSuite
```

---

## Clinical Performance Budgets

The cross-component correctness-first contract for codecs, partial decode,
JPIP progression, decoder import, volume assembly, GPU upload, MPR, volume
rendering, snapshots, JP3D artifacts, and memory is tracked as a test resource in
`Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalPerformanceBudgetManifest.json`
and summarized in
`Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalPerformanceBudgets.md`.

Budget reports include enough environment context for fair comparison: device
name, OS version, architecture, model identifier, build configuration,
benchmark mode, fixture identifier, tier, and whether CLI startup is included.
The clinical reporter emits JSON, CSV, and Markdown with warmups/iterations,
mean/stddev/CV, p50/p95/p99, throughput, stage/resource/work counters,
conformance linkage, baseline delta, and verdict.

Run the fast budget gate with:

```bash
swift test --filter PerformanceBudgetTests
swift test --filter ClinicalPerformanceReporterTests
```

Budget failures are visible even without a historical baseline. Values at or
above 90% of a configured budget are warnings; values above the budget are
failures. Same-host relative deltas warn at 10% and fail at 20%; mismatched
mode, fixture, build, tier, or startup scope is never compared. The integrated
runner is `../Tools/Scripts/Performance/run_clinical_performance_gates.sh`.

---

## Historical Trends

### Tracking Performance Over Time

Keep historical benchmark data as dated JSON or Markdown reports when it is useful for review:

```bash
# Analyze trend (requires jq)
for file in benchmark-*.json; do
  echo "$file:"
  jq '.results[] | select(.operation=="windowing_metal") | .meanTimeMilliseconds' "$file"
done
```

### Performance Evolution

Expected trends over library versions:

```
Version 1.0.0 (Initial Release):
- vDSP windowing: 8-10ms (1024×1024)
- No Metal support

Version 1.1.0 (Metal Acceleration):
- vDSP windowing: 8-10ms (1024×1024)
- Metal windowing: 2-3ms (1024×1024)
- 3-4× speedup achieved

Version 1.2.0 (Optimization):
- vDSP windowing: 8.67ms (1024×1024), improved
- Metal windowing: 2.20ms (1024×1024), improved
- 3.94× speedup, improved

Ongoing maintenance:
- Maintain or improve current performance
- Detect regressions with local or CI benchmark runs
- Update baselines after verified optimizations
```

---

## Summary

### Performance Highlights

**Lock Overhead:** Minimal (~0.05ms), thread-safe with negligible cost.
**Fast Initialization:** Decoder instances are created in ~0.1ms.
**Efficient Validation:** DICOM files validate in ~5ms.
**Cached Metadata:** Tag lookups complete in ~0.02ms.
**Optimized CPU Processing:** vDSP delivers consistent baseline throughput.
**GPU Acceleration:** Metal can provide **2-4× speedup** for images ≥800×800 on the measured Apple Silicon reference hardware.
**Typical Medical Imaging:** 1024×1024 images measured at **2.2ms with Metal** in the reference benchmark run.

### Recommendations

**For Application Developers:**
- Use `.auto` processing mode for automatic backend selection
- Expect ~2ms windowing latency for typical 1024×1024 CT/MRI images with Metal
- Plan for ~9ms latency if Metal unavailable (vDSP fallback)
- Monitor CV% to detect system performance issues

**For Library Contributors:**
- Run full benchmark suite before submitting PRs
- Verify no regressions (>10% slowdown)
- Update baselines after verified optimizations
- Document performance-impacting changes

**For Repository Integration:**
- Run quick verification before small performance-sensitive changes.
- Run the full suite before release notes or baseline updates.
- Preserve dated JSON/Markdown reports when they are used as review evidence.
- Treat regression thresholds as review gates when CI is configured to run the suite.

---

## Resources

- [API Documentation](https://thalesmms.github.io/DICOM-Swift/documentation/dicomcore/)
- [Getting Started Guide](GETTING_STARTED.md)
- [Performance Guide](Sources/DicomCore/DicomCore.docc/Articles/PerformanceGuide.md)
- [Benchmark Source Code](Tests/DicomCoreTests/PerformanceBenchmarks/)

---

**Reference Data:** February 2026 benchmark summary plus checked-in generated reports.
**Benchmark Version:** 1.0
**Library Version:** 1.2.0+

For questions or issues related to performance, please [open an issue](https://github.com/ThalesMMS/DICOM-Swift/issues) with benchmark results attached.
