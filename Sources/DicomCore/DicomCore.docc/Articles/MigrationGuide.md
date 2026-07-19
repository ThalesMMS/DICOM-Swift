# Migration Guide

Upgrade your code to use the current DicomCore APIs with improved type safety, error handling, and Swift idioms.

## Overview

DicomCore has evolved to provide more Swift-idiomatic APIs. This guide helps you migrate from deprecated patterns to modern, recommended approaches.

**Recommended APIs:**
- **Throwing initializers** (v1.1.0+) - Swift-idiomatic error handling
- **Type-safe DicomTag enum** (v1.2.0+) - Semantic tag names replace hex values
- **Type-safe value types** (v1.2.0+) - Structs replace tuples for better type safety
- **V2 windowing methods** (v1.2.0+) - Return WindowSettings instead of tuples

> **Planned breaking changes in v2.0.0**
>
> Version 2.0.0 is expected to remove deprecated APIs that were marked for removal in v1.x releases. Migrate to the modern APIs documented in this guide before upgrading to v2.0.0.
>
> **Planned for removal in v2.0.0:**
> - Legacy file loading API (`setDicomFilename()`, `dicomFileReadSuccess`, `loadDICOMFileAsync()`)
> - Tuple-based properties (`windowSettings`, `pixelSpacing`, `rescaleParameters`)
> - Tuple-based windowing methods (`calculateOptimalWindowLevel()`, `getPresetValues()`, etc.)
> - DCMDictionary singleton pattern (`DCMDictionary.shared`)
> - Async pixel convenience methods (`getPixels16Async()`, `getPixels8Async()`, etc.)

---

## Migration Path 1: Throwing Initializers

**Status:** Recommended since v1.1.0
**Replaces:** `setDicomFilename()` + `dicomFileReadSuccess` pattern

### Old Pattern (Deprecated)

```swift
// Deprecated: Boolean success check pattern
let decoder = DCMDecoder()
decoder.setDicomFilename("/path/to/image.dcm")

guard decoder.dicomFileReadSuccess else {
    print("Failed to load DICOM file")
    return
}

print("Dimensions: \(decoder.width) x \(decoder.height)")
```

**Problems with old pattern:**
- No information about *why* the load failed
- Easy to forget the success check (no compiler enforcement)
- Decoder exists in invalid state if load fails
- Not idiomatic Swift error handling

### New Pattern (Recommended)

```swift
// Recommended: Throwing initializer with String path
do {
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")
    print("Dimensions: \(decoder.width) x \(decoder.height)")
} catch DICOMError.fileNotFound(let path) {
    print("File not found: \(path)")
} catch DICOMError.invalidDICOMFormat(let path, let reason) {
    print("Invalid DICOM: \(reason)")
} catch {
    print("Unexpected error: \(error)")
}
```

**Alternative: URL-based initializer**

```swift
// Alternative: Throwing initializer with URL
do {
    let url = URL(fileURLWithPath: "/path/to/image.dcm")
    let decoder = try DCMDecoder(contentsOf: url)
    print("Loaded: \(decoder.width) x \(decoder.height)")
} catch {
    print("Error: \(error)")
}
```

**Alternative: Static factory methods**

```swift
// Alternative: Static factory methods
do {
    let url = URL(fileURLWithPath: "/path/to/image.dcm")
    let decoder = try DCMDecoder.load(from: url)
    // Or: let decoder = try DCMDecoder.load(fromFile: "/path/to/image.dcm")

    print("Successfully loaded: \(decoder.width) x \(decoder.height)")
} catch {
    print("Failed to load: \(error)")
}
```

### Migration Benefits

1. **Type-safe error handling** - Catch specific `DICOMError` cases instead of boolean flags
2. **Compiler-enforced** - Swift requires `try` or `try?`, preventing forgotten error checks
3. **Immediate validity** - If initialization succeeds, decoder is guaranteed valid
4. **Clearer intent** - Throwing initializers signal fallible operations at the API level
5. **Better async support** - Seamless integration with Swift Concurrency

### Async Migration

The old async API also has a modern replacement:

```swift
// Deprecated: Async with completion handler
let decoder = DCMDecoder()
decoder.loadDICOMFileAsync(path: "/path/to/image.dcm") {
    guard decoder.dicomFileReadSuccess else {
        print("Failed to load")
        return
    }
    print("Loaded: \(decoder.width) x \(decoder.height)")
}

// Recommended: Async throwing initializer
Task {
    do {
        let decoder = try await DCMDecoder(contentsOfFile: "/path/to/image.dcm")
        print("Loaded: \(decoder.width) x \(decoder.height)")
    } catch {
        print("Error: \(error)")
    }
}

// Alternative: Async static factory methods
Task {
    do {
        let url = URL(fileURLWithPath: "/path/to/image.dcm")
        let decoder = try await DCMDecoder.load(from: url)
        // Or: let decoder = try await DCMDecoder.load(fromFile: "/path/to/image.dcm")

        print("Loaded in background: \(decoder.width) x \(decoder.height)")
    } catch {
        print("Failed: \(error)")
    }
}
```

---

## Migration Path 2: Type-Safe DicomTag Enum

**Status:** Recommended since v1.2.0
**Replaces:** Raw hex tag values (e.g., `0x00100010`)

### Old Pattern (Discouraged)

```swift
// Deprecated: Magic hex numbers
let patientName = decoder.info(for: 0x00100010)
let modality = decoder.info(for: 0x00080060)
let rows = decoder.intValue(for: 0x00280010)
let columns = decoder.intValue(for: 0x00280011)
let windowCenter = decoder.doubleValue(for: 0x00281050)
let windowWidth = decoder.doubleValue(for: 0x00281051)
```

**Problems with old pattern:**
- No IDE autocomplete or discoverability
- Easy to make typos in hex values
- Requires referencing DICOM standard for tag numbers
- Not self-documenting code
- No compiler validation

### New Pattern (Recommended)

```swift
// Recommended: Semantic, type-safe tag names
let patientName = decoder.info(for: .patientName)
let modality = decoder.info(for: .modality)
let rows = decoder.intValue(for: .rows)
let columns = decoder.intValue(for: .columns)
let windowCenter = decoder.doubleValue(for: .windowCenter)
let windowWidth = decoder.doubleValue(for: .windowWidth)
```

### Migration Benefits

1. **Type safety** - Compiler-checked tag names prevent typos
2. **Discoverability** - IDE autocomplete shows all available tags
3. **Readability** - Self-documenting code
4. **No magic numbers** - Semantic names are clearer than hex values
5. **Backward compatible** - Raw hex still works for custom/private tags

### Common Tag Migrations

**Patient Information:**
```swift
// Deprecated
decoder.info(for: 0x00100010)  // Patient Name
decoder.info(for: 0x00100020)  // Patient ID
decoder.info(for: 0x00100030)  // Birth Date
decoder.info(for: 0x00100040)  // Sex

// Recommended
decoder.info(for: .patientName)
decoder.info(for: .patientID)
decoder.info(for: .patientBirthDate)
decoder.info(for: .patientSex)
```

**Study/Series:**
```swift
// Deprecated
decoder.info(for: 0x0020000D)  // Study Instance UID
decoder.info(for: 0x0020000E)  // Series Instance UID
decoder.info(for: 0x00080060)  // Modality
decoder.info(for: 0x00081030)  // Study Description

// Recommended
decoder.info(for: .studyInstanceUID)
decoder.info(for: .seriesInstanceUID)
decoder.info(for: .modality)
decoder.info(for: .studyDescription)
```

**Image Geometry:**
```swift
// Deprecated
decoder.intValue(for: 0x00280010)      // Rows
decoder.intValue(for: 0x00280011)      // Columns
decoder.info(for: 0x00280030)          // Pixel Spacing
decoder.doubleValue(for: 0x00180050)   // Slice Thickness

// Recommended
decoder.intValue(for: .rows)
decoder.intValue(for: .columns)
decoder.info(for: .pixelSpacing)
decoder.doubleValue(for: .sliceThickness)
```

**Window/Level:**
```swift
// Deprecated
decoder.doubleValue(for: 0x00281050)  // Window Center
decoder.doubleValue(for: 0x00281051)  // Window Width
decoder.doubleValue(for: 0x00281053)  // Rescale Slope
decoder.doubleValue(for: 0x00281052)  // Rescale Intercept

// Recommended
decoder.doubleValue(for: .windowCenter)
decoder.doubleValue(for: .windowWidth)
decoder.doubleValue(for: .rescaleSlope)
decoder.doubleValue(for: .rescaleIntercept)
```

### Custom and Private Tags

For custom or manufacturer-specific tags not in the standard, continue using hex values:

```swift
// Use hex for custom/private tags only
let manufacturerTag = decoder.info(for: 0x00091001)  // Private tag
let customData = decoder.info(for: 0x00111234)       // Custom tag

// Standard tags should use the enum
let patientName = decoder.info(for: .patientName)    // Preferred
// Not: decoder.info(for: 0x00100010)                // Discouraged
```

---

## Migration Path 3: DCMDictionary Singleton to Instance

**Status:** Recommended since v1.2.0, planned as required for v2.0.0
**Replaces:** `DCMDictionary.shared` singleton pattern

### Old Pattern (Deprecated)

```swift
// Deprecated: singleton pattern
let tagName = DCMDictionary.shared.description(forKey: 0x00100010)
let vrCode = DCMDictionary.shared.vrCode(forKey: 0x00100010)
```

**Problems with old pattern:**
- Global mutable state
- Difficult to test and mock
- No dependency injection support
- Tight coupling to singleton

### New Pattern (Required)

```swift
// Recommended: Instance-based pattern
let dictionary = DCMDictionary()
let tagName = dictionary.description(forKey: 0x00100010)
let vrCode = dictionary.vrCode(forKey: 0x00100010)
```

**For dependency injection:**

```swift
// Protocol-based dependency injection
protocol DicomDictionaryProtocol {
    func description(forKey: UInt32) -> String
    func vrCode(forKey: UInt32) -> String
}

class MyDicomService {
    private let dictionary: DicomDictionaryProtocol

    init(dictionary: DicomDictionaryProtocol = DCMDictionary()) {
        self.dictionary = dictionary
    }

    func getTagInfo(_ tag: UInt32) -> String {
        return dictionary.description(forKey: tag)
    }
}

// Production usage
let service = MyDicomService()  // Uses default DCMDictionary()

// Test usage
let mockDict = MockDicomDictionary()
let testService = MyDicomService(dictionary: mockDict)
```

### Migration Benefits

1. **Testability** - Easy to mock for unit tests
2. **Dependency injection** - Clear dependencies, no hidden global state
3. **Thread safety** - Each instance isolated, no shared mutable state
4. **Flexibility** - Can use custom dictionaries or decorators

---

## Migration Path 4: Type-Safe Value Types (V2 APIs)

**Status:** Recommended since v1.2.0
**Replaces:** Tuple-based APIs

### Overview

V2 APIs introduce dedicated structs (`WindowSettings`, `PixelSpacing`, `RescaleParameters`) that replace tuple return values, providing better type safety, Codable conformance, and validation.

### WindowSettings Migration

**Old Pattern:**
```swift
// Deprecated: Tuple-based API
let (center, width) = decoder.windowSettings

if center != 0.0 && width != 0.0 {
    print("Window: C=\(center) W=\(width)")
}

// Easy to accidentally swap parameters
applyWindow(width, center)  // Bug! Wrong order
```

**New Pattern:**
```swift
// Recommended: WindowSettings struct
let settings = decoder.windowSettingsV2

if settings.isValid {
    print("Window: C=\(settings.center) W=\(settings.width)")
}

// Impossible to swap parameters
applyWindow(settings)

// Serialize to JSON
let jsonData = try JSONEncoder().encode(settings)
// Output: {"center":50.0,"width":400.0}
```

**Migration benefits:**
- No parameter order mistakes
- Built-in `.isValid` validation
- Codable support for JSON serialization
- Named properties instead of tuple indices

### PixelSpacing Migration

**Old Pattern:**
```swift
// Deprecated: Tuple-based API
let (width, height, depth) = decoder.pixelSpacing

if width != 0.0 && height != 0.0 {
    print("Spacing: \(width) × \(height) × \(depth) mm")
}
```

**New Pattern:**
```swift
// Recommended: PixelSpacing struct
let spacing = decoder.pixelSpacingV2

if spacing.isValid {
    print("Spacing: \(spacing.x) × \(spacing.y) × \(spacing.z) mm")

    // Calculate physical dimensions
    let physicalWidth = Double(decoder.width) * spacing.x
    let physicalHeight = Double(decoder.height) * spacing.y
    print("Physical size: \(physicalWidth) × \(physicalHeight) mm")
}
```

**Migration benefits:**
- Semantic names (`.x`, `.y`, `.z`) instead of generic tuple labels
- Built-in `.isValid` validation
- Codable for persistence

### RescaleParameters Migration

**Old Pattern:**
```swift
// Deprecated: Tuple-based API
let (intercept, slope) = decoder.rescaleParameters

if slope != 1.0 || intercept != 0.0 {
    let hounsfieldValue = slope * Double(pixelValue) + intercept
    print("HU: \(hounsfieldValue)")
}
```

**New Pattern:**
```swift
// Recommended: RescaleParameters struct
let rescale = decoder.rescaleParametersV2

if !rescale.isIdentity {
    // Use built-in apply() method
    let hounsfieldValue = rescale.apply(to: Double(pixelValue))
    print("HU: \(hounsfieldValue)")

    // Transform array of pixels
    if let pixels = decoder.getPixels16() {
        let huValues = pixels.map { rescale.apply(to: Double($0)) }
    }
}
```

**Migration benefits:**
- Built-in `.apply(to:)` method encapsulates transformation logic
- `.isIdentity` property for checking if transformation is needed
- Clearer semantics than raw slope/intercept values

---

## Migration Path 5: Windowing Processor V2 Methods

**Status:** Recommended since v1.2.0
**Replaces:** Tuple-based windowing methods

### Calculate Optimal Window/Level

**Old Pattern:**
```swift
// Deprecated: Returns tuple
let (center, width) = DCMWindowingProcessor.calculateOptimalWindowLevel(pixels16: pixels)

let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels,
    center: center,
    width: width
)
```

**New Pattern:**
```swift
// Recommended: Returns WindowSettings struct
let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)

if optimal.isValid {
    let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
        pixels16: pixels,
        center: optimal.center,
        width: optimal.width
    )

    // Serialize optimal settings
    let jsonData = try JSONEncoder().encode(optimal)
}
```

### Medical Presets

**Old Pattern:**
```swift
// Deprecated: Returns tuple
let (center, width) = DCMWindowingProcessor.getPresetValues(preset: .lung)

let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels,
    center: center,
    width: width
)
```

**New Pattern:**
```swift
// Recommended: Returns WindowSettings struct
let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)

let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels,
    center: lungSettings.center,
    width: lungSettings.width
)

// Detect which preset matches current settings
if let presetName = DCMWindowingProcessor.getPresetName(settings: lungSettings) {
    print("Using preset: \(presetName)")  // Output: "Lung"
}
```

### Batch Processing

**Old Pattern:**
```swift
// Deprecated: Returns array of tuples
let results = DCMWindowingProcessor.batchCalculateOptimalWindowLevel(
    imagePixels: [pixels1, pixels2, pixels3]
)

for (center, width) in results {
    print("Window: C=\(center) W=\(width)")
}
```

**New Pattern:**
```swift
// Recommended: Returns array of WindowSettings
let results = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
    imagePixels: [pixels1, pixels2, pixels3]
)

for settings in results {
    if settings.isValid {
        print("Window: C=\(settings.center) W=\(settings.width)")
    }
}

// Serialize all results to JSON
let jsonData = try JSONEncoder().encode(results)
```

---

## Migration Path 6: Async Pixel Methods

**Status:** Deprecated; planned for removal in v2.0.0
**Replaces:** Async convenience wrappers for pixel data access

### Overview

The async pixel methods (`getPixels16Async()`, `getPixels8Async()`, etc.) are simple async wrappers around synchronous pixel access methods. They are planned for removal in v2.0.0 because:

1. Pixel data access is already memory-mapped and non-blocking for large files
2. The synchronous methods are fast enough that async wrapping adds no benefit
3. If async behavior is truly needed, you can wrap calls yourself with more control

### Old Pattern (Deprecated)

```swift
// Deprecated: async pixel wrappers
let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")

// Prefer the synchronous pixel accessors shown below:
let pixels16 = await decoder.getPixels16Async()
let pixels8 = await decoder.getPixels8Async()
let pixels24 = await decoder.getPixels24Async()
```

### New Pattern (Required)

```swift
// Option 1: Use synchronous methods directly (recommended)
let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")
let pixels16 = decoder.getPixels16()  // Already fast with memory mapping
let pixels8 = decoder.getPixels8()
let pixels24 = decoder.getPixels24()

// Option 2: Wrap in Task if you need explicit async behavior
Task {
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")
    let pixels = decoder.getPixels16()  // Still fast
    await processPixels(pixels)
}

// Option 3: Use async/await context if needed
func loadPixelData() async throws -> [UInt16]? {
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")
    return decoder.getPixels16()  // Runs on current task
}
```

### Migration Benefits

1. **Simpler API surface** - Fewer methods to learn and maintain
2. **No performance difference** - Synchronous methods are already optimized
3. **More control** - You choose when/how to make operations async
4. **Less confusion** - Clear that pixel access is memory-mapped and fast

### Performance Note

The synchronous pixel methods use memory mapping for large files, making them non-blocking at the I/O level. The async wrappers added no performance benefit and are unnecessary in Swift's modern concurrency model.

---

## Complete Migration Example

Here's a comprehensive before/after example showing all migration paths:

### Before (All Deprecated APIs)

```swift
// Deprecated pattern - all deprecated APIs
let decoder = DCMDecoder()
decoder.setDicomFilename("/path/to/ct_scan.dcm")

guard decoder.dicomFileReadSuccess else {
    print("Failed to load")
    return
}

// Magic hex numbers
let patientName = decoder.info(for: 0x00100010)
let modality = decoder.info(for: 0x00080060)
let rows = decoder.intValue(for: 0x00280010) ?? 0
let cols = decoder.intValue(for: 0x00280011) ?? 0

print("Patient: \(patientName), \(cols)×\(rows) \(modality)")

// Tuple-based value access
let (center, width) = decoder.windowSettings
let (spacingX, spacingY, spacingZ) = decoder.pixelSpacing
let (intercept, slope) = decoder.rescaleParameters

// Tuple-based windowing
guard let pixels = decoder.getPixels16() else { return }
let (optimalCenter, optimalWidth) = DCMWindowingProcessor.calculateOptimalWindowLevel(
    pixels16: pixels
)

let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels,
    center: optimalCenter,
    width: optimalWidth
)
```

### After (All Recommended APIs)

```swift
// Recommended pattern - all recommended APIs
do {
    // Throwing initializer
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

    // Type-safe DicomTag enum
    let patientName = decoder.info(for: .patientName)
    let modality = decoder.info(for: .modality)
    let rows = decoder.intValue(for: .rows) ?? 0
    let cols = decoder.intValue(for: .columns) ?? 0

    print("Patient: \(patientName), \(cols)×\(rows) \(modality)")

    // Type-safe value structs
    let windowSettings = decoder.windowSettingsV2
    let spacing = decoder.pixelSpacingV2
    let rescale = decoder.rescaleParametersV2

    if windowSettings.isValid {
        print("Window: C=\(windowSettings.center) W=\(windowSettings.width)")
    }

    if spacing.isValid {
        print("Spacing: \(spacing.x)×\(spacing.y)×\(spacing.z) mm")
    }

    // V2 windowing methods
    guard let pixels = decoder.getPixels16() else { return }
    let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)

    if optimal.isValid {
        let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels,
            center: optimal.center,
            width: optimal.width
        )

        // Serialize settings to JSON
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let jsonData = try encoder.encode(optimal)
        print("Optimal settings: \(String(data: jsonData, encoding: .utf8)!)")
    }

} catch DICOMError.fileNotFound(let path) {
    print("File not found: \(path)")
} catch DICOMError.invalidDICOMFormat(let path, let reason) {
    print("Invalid DICOM at \(path): \(reason)")
} catch {
    print("Unexpected error: \(error)")
}
```

---

## Quick Reference

### API Replacement Table

| Deprecated API | Replacement API | Migration Path |
|----------------|-----------------|----------------|
| `DCMDecoder()` + `setDicomFilename()` | `try DCMDecoder(contentsOfFile:)` | Path 1 |
| `DCMDecoder()` + `setDicomFilename()` | `try DCMDecoder(contentsOf:)` | Path 1 |
| `loadDICOMFileAsync()` | `try await DCMDecoder(contentsOfFile:)` | Path 1 |
| `dicomFileReadSuccess` | Use `do-catch` with throwing initializers | Path 1 |
| `info(for: 0x00100010)` | `info(for: .patientName)` | Path 2 |
| `intValue(for: 0x00280010)` | `intValue(for: .rows)` | Path 2 |
| `DCMDictionary.shared` | `DCMDictionary()` instance | Path 3 |
| `windowSettings` (tuple) | `windowSettingsV2` (struct) | Path 4 |
| `pixelSpacing` (tuple) | `pixelSpacingV2` (struct) | Path 4 |
| `rescaleParameters` (tuple) | `rescaleParametersV2` (struct) | Path 4 |
| `calculateOptimalWindow()` (tuple) | `calculateOptimalWindowV2()` (struct) | Path 4 |
| `calculateOptimalWindowLevel()` | `calculateOptimalWindowLevelV2()` | Path 5 |
| `getPresetValues(preset:)` | `getPresetValuesV2(preset:)` | Path 5 |
| `getPresetValues(named:)` | `getPresetValuesV2(named:)` | Path 5 |
| `batchCalculateOptimalWindowLevel()` | `batchCalculateOptimalWindowLevelV2()` | Path 5 |
| `getPresetName(center:width:)` | `getPresetName(settings:)` | Path 5 |
| `getPixels16Async()` | `getPixels16()` (synchronous) | Path 6 |
| `getPixels8Async()` | `getPixels8()` (synchronous) | Path 6 |
| `getPixels24Async()` | `getPixels24()` (synchronous) | Path 6 |
| `getDownsampledPixels16Async()` | `getDownsampledPixels16()` (synchronous) | Path 6 |
| `getDownsampledPixels8Async()` | `getDownsampledPixels8()` (synchronous) | Path 6 |

### Migration Status Before v2.0.0

This table records the migration actions consumers should complete before
upgrading to the planned v2.0.0 API break. It is intentionally not an open
project checklist; current package documentation reconciliation and decoder
parity are guarded by package-local tests.

| Area | Consumer Action | Current Package Status |
| --- | --- | --- |
| File Loading (Path 1) | Replace `setDicomFilename()`, `dicomFileReadSuccess`, and `loadDICOMFileAsync()` with throwing initializers, async throwing initializers, and `do-catch` handling for specific `DICOMError` cases. | Recommended APIs are available and documented. |
| Type-Safe Tags (Path 2) | Replace standard hex tag values with `DicomTag` enum cases; keep raw hex only for private or custom tags. | `DicomTag` remains the preferred public API for standard tags. |
| Dictionary (Path 3) | Replace `DCMDictionary.shared` and static calls with `DCMDictionary()` instances and dependency injection where appropriate. | Instance-based dictionary APIs are available and documented. |
| Value Types (Path 4) | Replace tuple properties such as `windowSettings`, `pixelSpacing`, `rescaleParameters`, and `calculateOptimalWindow()` with their V2 value-type APIs. | V2 value-type APIs are available and documented. |
| Windowing Methods (Path 5) | Replace tuple-returning windowing helpers with V2 variants such as `calculateOptimalWindowLevelV2()`, `getPresetValuesV2(...)`, `batchCalculateOptimalWindowLevelV2()`, and `getPresetName(settings:)`. | V2 windowing methods are available and documented. |
| Async Pixels (Path 6) | Replace async pixel convenience methods with synchronous pixel/downsample accessors and move threading decisions to the caller. | Synchronous pixel APIs are available and documented. |
| Final Verification | Build without v1.x deprecation warnings, run tests, and confirm readiness for the v2.0.0 compatibility break. | Verification remains a consumer integration responsibility. |

### Need Help?

- See <doc:GettingStarted> for basic usage examples
- See <doc:Architecture> for protocol-based dependency injection
- See <doc:PerformanceGuide> for optimization tips
- Check the API documentation for detailed method signatures

---

## Preparing for Version 2.0.0 Breaking Changes

**Important:** Version 2.0.0 is planned as a major breaking release that removes deprecated APIs.

### What Is Planned for Removal

1. **Legacy file loading API**
   - `setDicomFilename(_:)` → Use `init(contentsOfFile:) throws`
   - `dicomFileReadSuccess` → Use throwing initializers with do-catch
   - `loadDICOMFileAsync(_:)` → Use `init(contentsOfFile:) async throws`

2. **Tuple-based properties**
   - `windowSettings` → Use `windowSettingsV2`
   - `pixelSpacing` → Use `pixelSpacingV2`
   - `rescaleParameters` → Use `rescaleParametersV2`
   - `calculateOptimalWindow()` → Use `calculateOptimalWindowV2()`

3. **Tuple-based windowing methods**
   - `calculateOptimalWindowLevel(pixels16:)` → Use `calculateOptimalWindowLevelV2(pixels16:)`
   - `getPresetValues(preset:)` → Use `getPresetValuesV2(preset:)`
   - `getPresetValues(named:)` → Use `getPresetValuesV2(named:)`
   - `batchCalculateOptimalWindowLevel(imagePixels:)` → Use `batchCalculateOptimalWindowLevelV2(imagePixels:)`
   - `getPresetName(center:width:tolerance:)` → Use `getPresetName(settings:tolerance:)`

4. **DCMDictionary singleton**
   - `DCMDictionary.shared` → Use `DCMDictionary()` instance
   - Static methods → Use instance methods

5. **Async pixel convenience methods**
   - `getPixels16Async()` → Use synchronous `getPixels16()` directly
   - `getPixels8Async()` → Use synchronous `getPixels8()` directly
   - `getPixels24Async()` → Use synchronous `getPixels24()` directly
   - `getDownsampledPixels16Async()` → Use synchronous method directly
   - `getDownsampledPixels8Async()` → Use synchronous method directly

### Migration Timeline

- **v1.1.0** (2024) - Throwing initializers added, legacy loading deprecated
- **v1.2.0** (2024) - Type-safe DicomTag enum and V2 methods added, tuples deprecated
- **v2.0.0** (planned) - Deprecated APIs removed

### Before Upgrading to v2.0.0

1. Ensure your code compiles without deprecation warnings on v1.x
2. Follow all migration paths in this guide
3. Update all deprecated API usage to modern equivalents
4. Test thoroughly on v1.x before upgrading

### Backward Compatibility (v1.x only)

In version 1.x releases, deprecated APIs remain functional:

1. **No breaking changes** - Existing code continues to work
2. **Gradual migration** - You can update one component at a time
3. **Incremental adoption** - You can mix old and new APIs during transition
4. **Clear deprecation warnings** - The compiler guides you to modern APIs

**Version 2.0.0 is expected to end this compatibility period.** Plan to remove all deprecated API usage before upgrading.
