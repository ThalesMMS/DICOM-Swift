# Performance Guide

Optimize DICOM processing with GPU acceleration, memory-efficient patterns, and async operations.

## Overview

DicomCore is designed for high-performance medical image processing on Apple platforms. This guide covers performance optimization strategies, from GPU-accelerated windowing to memory-efficient file handling.

## GPU Acceleration

The library includes optional Metal GPU acceleration for window/level operations, providing significant performance improvements for large medical images.

### Processing Modes

``DCMWindowingProcessor/applyWindowLevel(pixels16:center:width:processingMode:)`` supports three processing backends:

```swift
public enum ProcessingMode {
    case vdsp   // CPU-based processing (default)
    case metal  // GPU-based processing
    case auto   // Automatic selection based on image size
}
```

### Mode Selection Guide

| Mode | Use Case | Performance | Availability |
|------|----------|-------------|--------------|
| `.vdsp` | Small images (<800×800), guaranteed compatibility | ~1-2ms for 512×512 images | Always available |
| `.metal` | Large images (≥800×800), modern hardware | ~2.20ms for 1024×1024 (3.94× speedup) | Metal-capable supported devices |
| `.auto` | General purpose, adapts to image size | Optimal for all sizes | Graceful fallback to vDSP |

### Usage Examples

**Default behavior (backward compatible):**
```swift
// Uses vDSP (CPU) - no breaking changes
let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 50.0,
    width: 400.0
)
```

**Explicit Metal GPU acceleration:**
```swift
// Force GPU processing (falls back to vDSP if Metal unavailable)
let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 50.0,
    width: 400.0,
    processingMode: .metal
)
```

**Automatic selection (recommended):**
```swift
// Auto-selects Metal for images ≥800×800, vDSP for smaller images
let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 50.0,
    width: 400.0,
    processingMode: .auto
)
```

### Performance Characteristics

Measured on Apple M4 hardware:

| Image Size | vDSP (CPU) | Metal (GPU) | Speedup |
|------------|------------|-------------|---------|
| 256×256 | ~0.5ms | ~0.3ms | 1.67× |
| 512×512 | ~2ms | ~1.16ms | 1.84× |
| 1024×1024 | ~8.67ms | ~2.20ms | **3.94×** |
| 2048×2048 | ~35ms | ~8ms | 4.38× |

**Key Insights:**
- GPU acceleration provides **3-4× speedup** for large images (≥1024×1024)
- Small images (<512×512) benefit less from GPU overhead
- `.auto` mode provides optimal performance across all image sizes

### Auto-Selection Threshold

The `.auto` mode uses a **800×800 pixel threshold** (640,000 total pixels):
- Images with ≥640,000 pixels use Metal (if available)
- Smaller images use vDSP
- If Metal is unavailable, vDSP is used regardless of size
- No exceptions thrown - graceful fallback guaranteed

## Memory Optimization

### Memory Mapping for Large Files

Files >10MB are automatically memory-mapped to reduce memory footprint:

```swift
// Large files are memory-mapped automatically
let decoder = try DCMDecoder(contentsOf: largeFileURL)
// Only accessed portions loaded into RAM
```

**Benefits:**
- Reduces peak memory usage
- Faster loading times for large files
- Automatic cache management by OS

### Lazy Pixel Loading

Pixel data is loaded only when first accessed, not during file parsing:

```swift
// Parse metadata only (fast)
let decoder = try DCMDecoder(contentsOf: url)
let patientName = decoder.info(for: .patientName)

// Pixel data loaded here (slower, only if needed)
let pixels = decoder.getPixels16()
```

**Best Practice:**
- Load metadata first to validate files
- Defer pixel loading until display time
- Useful for thumbnail views or batch metadata extraction

### Tag Caching

Frequently accessed tags are cached after first lookup:

```swift
// First access: reads from file
let name = decoder.info(for: .patientName)

// Subsequent accesses: returns cached value
let nameAgain = decoder.info(for: .patientName)  // Fast
```

## Async/Await Patterns

Use async operations for non-blocking I/O:

### Async File Loading

```swift
// Non-blocking file load
Task {
    do {
        let decoder = try await DCMDecoder(contentsOf: url)
        await updateUI(with: decoder)
    } catch {
        print("Error: \(error)")
    }
}
```

### Async Series Loading

```swift
let loader = DicomSeriesLoader()
Task {
    do {
        let images = try await loader.loadSeriesAsync(
            from: directoryURL
        )
        await displaySeries(images)
    } catch {
        print("Error: \(error)")
    }
}
```

**Benefits:**
- UI remains responsive during loading
- Parallel processing of multiple files
- Cancellation support via Task

## Batch Processing Best Practices

### Process Multiple Images Efficiently

```swift
// Good: Reuse decoder instance for metadata
let decoders = urls.map { try? DCMDecoder(contentsOf: $0) }
let metadata = decoders.compactMap { $0?.info(for: .patientName) }

// Good: Batch window calculation
let pixelArrays = decoders.map { $0.getPixels16() }
let windowSettings = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
    imagePixels: pixelArrays
)

// Avoid: Creating new Metal processor per image
// The library reuses Metal processor internally - no need to manage it
```

### Parallel Processing

```swift
// Process multiple images in parallel
await withTaskGroup(of: [UInt8]?.self) { group in
    for decoder in decoders {
        group.addTask {
            let pixels16 = decoder.getPixels16()
            return DCMWindowingProcessor.applyWindowLevel(
                pixels16: pixels16,
                center: 50.0,
                width: 400.0,
                processingMode: .auto
            )
        }
    }

    for await result in group {
        // Process results
    }
}
```

## Large File Handling

### Files >1GB

**Limitations:**
- May consume significant memory during pixel loading
- Consider streaming approaches for extreme sizes

**Recommendations:**
```swift
// Check file size before loading
let attributes = try FileManager.default.attributesOfItem(atPath: path)
let fileSize = attributes[.size] as? UInt64 ?? 0

if fileSize > 1_000_000_000 {  // 1GB
    // Consider warning user or using memory-mapped access
    print("Warning: Large file (\(fileSize / 1_000_000)MB)")
}

let decoder = try DCMDecoder(contentsOf: url)
```

### Memory-Efficient Series Processing

```swift
// Process series one slice at a time
let loader = DicomSeriesLoader()
let seriesImages = try await loader.loadSeriesAsync(from: directory)

for dicomImage in seriesImages {
    // Process single slice
    let pixels = dicomImage.decoder.getPixels16()
    // ... process and discard
}
// Each slice freed after processing
```

## Compression Support Performance

### Native JPEG Lossless Decoder

**Fast path (native decoder):**
- JPEG Lossless Process 14, Selection Value 1
- Transfer Syntax UID 1.2.840.10008.1.2.4.57
- Transfer Syntax UID 1.2.840.10008.1.2.4.70
- Supports 8-bit, 12-bit, and 16-bit precision
- **Performance**: ~10-20ms for typical CT/MR slices

**Explicit compressed codec paths:**
- JPEG Baseline 8-bit through ImageIO
- JPEG 2000 up to 16-bit grayscale through OpenJPEG when available
- JPEG 2000 8-bit ImageIO fallback when OpenJPEG is unavailable
- JPEG 2000 Part 2 multi-component volume documents through OpenJPEG when available
- **Performance**: Varies by image size and compression
- **Limitation**: The single-frame `DCMPixelReader` path does not decode JPEG 2000 Part 2 volumes; use `DicomJP3DVolumeDocument`

### Best Practices

```swift
// Check transfer syntax for performance expectations
let transferSyntax = decoder.info(for: .transferSyntaxUID)
switch transferSyntax {
case "1.2.840.10008.1.2.4.57",  // JPEG Lossless
     "1.2.840.10008.1.2.4.70":  // JPEG Lossless (First-Order)
    // Fast native decoder path
    break
case "1.2.840.10008.1.2.4.90",  // JPEG 2000 Lossless
     "1.2.840.10008.1.2.4.91":  // JPEG 2000
    // OpenJPEG runtime path when available
    break
case "1.2.840.10008.1.2.4.92",  // JPEG 2000 Part 2 multi-component lossless
     "1.2.840.10008.1.2.4.93":  // JPEG 2000 Part 2 multi-component
    // DicomJP3DVolumeDocument OpenJPEG runtime path
    break
default:
    // Uncompressed - fastest
    break
}
```

## Performance Monitoring

### Quality Metrics

Track windowing quality:

```swift
let pixels16 = decoder.getPixels16()
let pixels8 = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 50.0,
    width: 400.0,
    processingMode: .auto
)

// Calculate quality metrics
let snr = DCMWindowingProcessor.calculateSNR(
    pixels16: pixels16,
    pixels8: pixels8
)
let contrast = DCMWindowingProcessor.calculateContrast(pixels8: pixels8)

print("SNR: \(snr) dB, Contrast: \(contrast)")
```

### Profiling Tips

**Use Instruments:**
- Time Profiler: Identify CPU bottlenecks
- Metal System Trace: Analyze GPU performance
- Allocations: Track memory usage

**Benchmarking Pattern:**
```swift
let start = CFAbsoluteTimeGetCurrent()
let pixels8 = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 50.0,
    width: 400.0,
    processingMode: .auto
)
let elapsed = CFAbsoluteTimeGetCurrent() - start
print("Processing time: \(elapsed * 1000) ms")
```

## Summary

**Key Performance Features:**
1. **GPU Acceleration**: 3-4× speedup for large images via Metal
2. **Auto-Selection**: Optimal backend choice based on image size
3. **Memory Mapping**: Automatic for files >10MB
4. **Lazy Loading**: Pixel data loaded on demand
5. **Async/Await**: Non-blocking I/O for responsive UIs
6. **Tag Caching**: Fast repeated metadata access

**Recommended Defaults:**
- Use `.auto` processing mode for windowing
- Use async APIs for file loading
- Process series slices incrementally for memory efficiency
- Monitor performance with Instruments on target hardware
