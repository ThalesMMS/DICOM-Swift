# SPM Metal Resource Bundling Research

## Research Date
2026-02-05

## Summary
Swift Package Manager (SPM) has evolved its Metal shader support since Swift 5.3, but significant differences exist between regular build targets and test targets. The traditional `makeDefaultLibrary()` approach fails in SPM contexts, requiring runtime compilation from source instead.

## The Problem: makeDefaultLibrary() in SPM

### What Fails
```swift
// This pattern FAILS in SPM packages
let device = MTLCreateSystemDefaultDevice()
let library = device.makeDefaultLibrary()  // Returns nil in SPM!
```

### Why It Fails
- `makeDefaultLibrary()` expects a pre-compiled `.metallib` file embedded in the main app bundle
- SPM packages use `Bundle.module` instead of `Bundle.main`
- Metal shaders in SPM are resources, not pre-compiled libraries
- Test targets have additional bundling complexities

## The Solution: Runtime Compilation from Bundle.module

### Working Pattern (Proven in MetalBenchmark)
```swift
// This pattern WORKS in SPM packages
guard let device = MTLCreateSystemDefaultDevice() else {
    throw MetalProcessorError.metalNotAvailable
}

// Load shader source from Bundle.module and compile at runtime
guard let shaderURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal"),
      let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8),
      let library = try? device.makeLibrary(source: shaderSource, options: nil) else {
    throw MetalProcessorError.libraryCreationFailed
}

// Get kernel function from compiled library
guard let function = library.makeFunction(name: "applyWindowLevel") else {
    throw MetalProcessorError.functionNotFound("applyWindowLevel")
}

// Create compute pipeline state
let pipelineState = try device.makeComputePipelineState(function: function)
```

### Key Differences from Traditional Approach
| Aspect | Traditional (App Bundle) | SPM Package |
|--------|-------------------------|-------------|
| Library Loading | `makeDefaultLibrary()` | `makeLibrary(source:)` |
| Shader Format | Pre-compiled `.metallib` | Source `.metal` files |
| Bundle Access | `Bundle.main` | `Bundle.module` |
| Compilation | Build-time | Runtime (first use) |
| Cache | Pre-built | Metal driver caches compiled shaders |

## Package.swift Configuration

### Required Setup
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetalBenchmark",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "MetalBenchmark",
            path: "Sources",
            resources: [
                .process("Shaders.metal")  // Critical: use .process() not .copy()
            ]
        )
    ]
)
```

### Resource Declaration Options
- **`.process("Shaders.metal")`**: Recommended - SPM processes the file and makes it accessible via `Bundle.module`
- **`.copy("Shaders.metal")`**: Alternative - copies file as-is but may have different path handling
- **No resource declaration**: File won't be bundled - loading will fail

## Test Target Complications

### Known Issues
From Apple Developer Forums and community reports:
- `swift test` has different bundling behavior than Xcode Unit Tests
- `Bundle.module` access works in Xcode but may fail in command-line `swift test`
- Test targets require explicit resource declarations just like regular targets

### Workaround for Tests
```swift
// In test targets, may need to use Bundle(for:) instead
let bundle = Bundle(for: type(of: self))
let shaderURL = bundle.url(forResource: "Shaders", withExtension: "metal")
```

### Why This Task Used External Validation
The MetalBenchmark tool was created as a **standalone executable target** rather than fixing Metal in the library's test target because:
1. Executable targets have more reliable Bundle.module access
2. External validation bypasses test bundling complexities
3. Standalone CLI provides reproducible benchmarks outside test framework
4. Runtime compilation overhead is acceptable for validation (one-time cost)

## Performance Implications

### Runtime Compilation Overhead
- **First execution**: ~50-100ms shader compilation time (varies by GPU)
- **Subsequent executions**: Metal driver caches compiled shaders (minimal overhead)
- **Warmup iterations**: BenchmarkRunner uses 20 warmup iterations to eliminate this overhead from measurements

### Optimization: setBytes vs Buffers
```swift
// Optimized approach for small parameters (discovered during implementation)
computeEncoder.setBytes(&centerParam, length: MemoryLayout<Float>.stride, index: 2)
computeEncoder.setBytes(&widthParam, length: MemoryLayout<Float>.stride, index: 3)

// Instead of creating buffers for scalar values
// let centerBuffer = device.makeBuffer(bytes: &center, length: ...)
```

## File Organization Pattern

### Proven Structure
```
MetalBenchmark/
├── Package.swift                      # Declares .metal resource
├── Sources/
│   ├── Shaders.metal                 # Metal kernel source
│   ├── MetalWindowingProcessor.swift # Swift wrapper with runtime compilation
│   ├── main.swift                    # CLI entry point
│   └── ...
└── .build/
    └── arm64-apple-macosx/
        └── release/
            └── MetalBenchmark_MetalBenchmark.bundle/
                └── Shaders.metal     # SPM bundles source, not .metallib
```

### What SPM Creates
- SPM creates a `.bundle` directory containing resources
- Metal shaders remain as `.metal` source files (not compiled to `.metallib`)
- `Bundle.module` provides access to this bundle
- First `makeLibrary(source:)` call triggers Metal compiler

## Best Practices

### DO
1. Use `Bundle.module.url(forResource:withExtension:)` for SPM packages
2. Compile shaders at runtime with `makeLibrary(source:options:)`
3. Declare Metal files with `.process()` in Package.swift resources
4. Include warmup iterations to amortize compilation overhead
5. Cache `MTLComputePipelineState` instances for reuse
6. Use `setBytes()` for small constant parameters (<4KB)

### DON'T
1. Use `makeDefaultLibrary()` in SPM packages (returns nil)
2. Use `Bundle.main` in package code (use `Bundle.module`)
3. Expect pre-compiled `.metallib` files in SPM bundles
4. Skip warmup iterations in benchmarks (first run is slower)
5. Create buffers for scalar shader parameters (overhead)

## References

### Implementation Files
- `MetalBenchmark/Sources/MetalWindowingProcessor.swift` (lines 63-69) - Working runtime compilation pattern
- `MetalBenchmark/Package.swift` (lines 16-18) - Resource declaration
- `MetalBenchmark/Sources/BenchmarkRunner.swift` - Warmup iteration handling

### Apple Documentation
- [makeDefaultLibrary(bundle:)](https://developer.apple.com/documentation/metal/mtldevice/2177054-makedefaultlibrary) - Official API reference
- [makeLibrary(source:options:)](https://developer.apple.com/documentation/metal/mtldevice/1433431-makelibrary) - Runtime compilation API

### Community Resources
- [Swift Package with Metal - Apple Developer Forums](https://developer.apple.com/forums/thread/649579) - Official discussion of SPM Metal support
- [Swift Package Manager, Metal shaders - Swift Forums](https://forums.swift.org/t/swift-package-manager-metal-shaders-bridging-header/53321) - Community patterns
- [MetalCompilerPlugin](https://github.com/schwa/MetalCompilerPlugin) - Third-party SPM plugin for advanced Metal compilation
- [Build Swift Executable with Metal Library - MTLDoc](https://mtldoc.com/metal/2022/06/18/build-swift-executable-with-metal-library) - Tutorial on Metal in executables

### Issue Trackers
- [Metal files *not* silently compiled - Swift PM Issue #7716](https://github.com/swiftlang/swift-package-manager/issues/7716) - Known SPM limitation

## Conclusions

1. **SPM Metal support exists but differs from traditional app bundling**
   - Swift 5.3+ supports Metal resources via `.process()` declaration
   - Runtime compilation from source is required (not pre-compiled .metallib)

2. **makeDefaultLibrary() is incompatible with SPM**
   - Designed for app bundles with pre-compiled Metal libraries
   - SPM uses Bundle.module with source files instead

3. **Runtime compilation is the correct SPM pattern**
   - Load `.metal` source from `Bundle.module`
   - Compile with `makeLibrary(source:options:)`
   - Metal driver caches compiled shaders for subsequent runs

4. **Test targets have additional complexities**
   - `swift test` vs Xcode has different bundling behavior
   - External validation tools (standalone executables) bypass these issues

5. **Performance impact is negligible in practice**
   - 50-100ms compilation overhead on first execution
   - Warmup iterations eliminate this from benchmarks
   - Metal driver caching makes subsequent runs fast

## Implementation Notes

The MetalBenchmark CLI tool validates that Metal GPU processing can achieve **3.94x speedup** on 1024×1024 images compared to the vDSP baseline using the runtime compilation pattern documented above.

Applying the same SPM Metal pattern in the main library would involve:
1. Adding `.metal` shader source to main library's resources
2. Updating DCMWindowingProcessor to use runtime compilation pattern
3. Accepting ~50-100ms first-use overhead
4. Documenting that this is the correct SPM pattern (not a workaround)

External validation via MetalBenchmark is sufficient for benchmark reporting; adopting the same runtime compilation pattern in the main library should be treated as a separate implementation decision.
