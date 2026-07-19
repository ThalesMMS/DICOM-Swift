# DICOM Decoder - Usage Examples

This document provides detailed examples of using the Swift DICOM Decoder in various scenarios.

## Table of Contents

- [Recommended API (Throwing Initializers)](#recommended-api-throwing-initializers)
- [Migration from Legacy API](#migration-from-legacy-api)
- [Type-Safe DicomTag Enum](#type-safe-dicomtag-enum)
- [Type-Safe Value Types (V2 APIs)](#type-safe-value-types-v2-apis)
- [Basic Usage](#basic-usage)
- [Async/Await Usage](#asyncawait-usage)
- [Validation and Error Handling](#validation-and-error-handling)
- [Window/Level Operations](#windowlevel-operations)
- [Medical Presets](#medical-presets)
- [Metadata Extraction](#metadata-extraction)
- [Image Quality Metrics](#image-quality-metrics)
- [Batch Processing](#batch-processing)
- [Protocol-Based Dependency Injection](#protocol-based-dependency-injection)
- [Advanced Features](#advanced-features)

## Recommended API (Throwing Initializers)

The library provides Swift-idiomatic throwing initializers for error handling. This is the **recommended approach** for new code.

### Loading with Throwing Initializer (Recommended)

```swift
import DicomCore

do {
    // Load DICOM file with throwing initializer (URL variant)
    let url = URL(fileURLWithPath: "/path/to/image.dcm")
    let decoder = try DCMDecoder(contentsOf: url)

    // Access image properties immediately - no need to check success boolean
    print("Image dimensions: \(decoder.width) x \(decoder.height)")
    print("Bit depth: \(decoder.bitDepth)")

    // Recommended: Use type-safe DicomTag enum
    print("Modality: \(decoder.info(for: .modality))")
    print("Patient: \(decoder.info(for: .patientName))")

    // Legacy (deprecated): Raw hex values (still supported for custom/private tags)
    // print("Modality: \(decoder.info(for: 0x00080060))")

    // Get pixels
    if let pixels16 = decoder.getPixels16() {
        print("Loaded \(pixels16.count) 16-bit pixels")
    }
} catch DICOMError.fileNotFound(let path) {
    print("File not found: \(path)")
} catch DICOMError.invalidDICOMFormat(let path, let reason) {
    print("Invalid DICOM file at \(path): \(reason)")
} catch {
    print("Unexpected error: \(error)")
}
```

### Loading with String Path

```swift
do {
    // Load DICOM file from String path
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")

    print("Image dimensions: \(decoder.width) x \(decoder.height)")
} catch DICOMError.fileNotFound(let path) {
    print("File not found: \(path)")
} catch DICOMError.invalidDICOMFormat(let path, let reason) {
    print("Invalid DICOM file: \(reason)")
} catch {
    print("Unexpected error: \(error)")
}
```

### Static Factory Methods

```swift
do {
    // Alternative: Use static factory method
    let url = URL(fileURLWithPath: "/path/to/image.dcm")
    let decoder = try DCMDecoder.load(from: url)

    // Or with String path
    let decoder2 = try DCMDecoder.load(fromFile: "/path/to/image.dcm")

    print("Successfully loaded: \(decoder.width) x \(decoder.height)")
} catch {
    print("Failed to load: \(error)")
}
```

### Async Throwing Initializers (Non-Blocking)

```swift
import DicomCore

func loadDICOMAsync() async {
    do {
        // Load asynchronously without blocking the main thread
        let url = URL(fileURLWithPath: "/path/to/image.dcm")
        let decoder = try await DCMDecoder(contentsOf: url)

        print("Loaded asynchronously: \(decoder.width) x \(decoder.height)")

        // Get pixels
        if let pixels = decoder.getPixels16() {
            print("Pixel count: \(pixels.count)")
        }
    } catch DICOMError.fileNotFound(let path) {
        print("File not found: \(path)")
    } catch DICOMError.invalidDICOMFormat(let path, let reason) {
        print("Invalid DICOM: \(reason)")
    } catch {
        print("Error: \(error)")
    }
}

// Usage in any asynchronous context
Task {
    await loadDICOMAsync()
}
```

### Async Static Factory Methods

```swift
do {
    // Async factory methods for non-blocking load
    let url = URL(fileURLWithPath: "/path/to/image.dcm")
    let decoder = try await DCMDecoder.load(from: url)

    // Or with String path
    let decoder2 = try await DCMDecoder.load(fromFile: "/path/to/image.dcm")

    print("Loaded in background: \(decoder.width) x \(decoder.height)")
} catch {
    print("Failed: \(error)")
}
```

## Migration from Legacy API

The legacy `setDicomFilename()` + `dicomFileReadSuccess` pattern is deprecated. Here's how to migrate:

### Old Pattern (Deprecated)

```swift
// Deprecated pattern
let decoder = DCMDecoder()
decoder.setDicomFilename("/path/to/image.dcm")

guard decoder.dicomFileReadSuccess else {
    print("Failed to load DICOM file")
    return
}

print("Dimensions: \(decoder.width) x \(decoder.height)")
```

### New Pattern (Recommended)

```swift
// Recommended pattern
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

### Migration Benefits

1. **Type-safe error handling**: Catch specific `DICOMError` cases instead of checking boolean flags
2. **Compiler-enforced error handling**: Swift requires `try` or `try?` - no forgotten error checks
3. **Immediate validity**: If initialization succeeds, the decoder is guaranteed to be valid
4. **Clearer intent**: Throwing initializers signal fallible operations at the API level
5. **Better async support**: Async throwing initializers integrate seamlessly with Swift Concurrency

## Type-Safe DicomTag Enum

The library provides a **type-safe `DicomTag` enum** for accessing DICOM metadata, replacing error-prone raw hex values with semantic, discoverable tag names.

### Why Use DicomTag Enum?

**Benefits:**
- **Type safety** - Compiler-checked tag names prevent typos
- **Discoverability** - Autocomplete shows all available standard tags
- **Readability** - Semantic names like `.patientName` instead of `0x00100010`
- **No magic numbers** - Self-documenting code
- **Backward compatible** - Raw hex values still work for custom/private tags

### Basic Tag Access

```swift
import DicomCore

do {
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")

    // Recommended: Type-safe DicomTag enum
    let patientName = decoder.info(for: .patientName)
    let modality = decoder.info(for: .modality)
    let studyUID = decoder.info(for: .studyInstanceUID)
    let seriesDesc = decoder.info(for: .seriesDescription)

    print("Patient: \(patientName)")
    print("Modality: \(modality)")
    print("Study: \(studyUID)")
    print("Series: \(seriesDesc)")

} catch {
    print("Error: \(error)")
}
```

### Typed Value Access

The DicomTag enum works with all metadata access methods:

```swift
// String values (default)
let patientName = decoder.info(for: .patientName)
let modality = decoder.info(for: .modality)

// Integer values
if let rows = decoder.intValue(for: .rows) {
    print("Height: \(rows) pixels")
}

if let columns = decoder.intValue(for: .columns) {
    print("Width: \(columns) pixels")
}

if let bitsAllocated = decoder.intValue(for: .bitsAllocated) {
    print("Bits per pixel: \(bitsAllocated)")
}

// Double values
if let windowCenter = decoder.doubleValue(for: .windowCenter) {
    print("Window center: \(windowCenter)")
}

if let windowWidth = decoder.doubleValue(for: .windowWidth) {
    print("Window width: \(windowWidth)")
}

if let sliceThickness = decoder.doubleValue(for: .sliceThickness) {
    print("Slice thickness: \(sliceThickness) mm")
}
```

### Common Tags by Category

**Patient Information:**
```swift
decoder.info(for: .patientName)          // (0010,0010) Patient Name
decoder.info(for: .patientID)            // (0010,0020) Patient ID
decoder.info(for: .patientBirthDate)     // (0010,0030) Birth Date
decoder.info(for: .patientSex)           // (0010,0040) Sex
decoder.info(for: .patientAge)           // (0010,1010) Age
```

**Study/Series:**
```swift
decoder.info(for: .studyInstanceUID)     // (0020,000D) Study UID
decoder.info(for: .seriesInstanceUID)    // (0020,000E) Series UID
decoder.info(for: .modality)             // (0008,0060) Modality
decoder.info(for: .studyDescription)     // (0008,1030) Study Description
decoder.info(for: .seriesDescription)    // (0008,103E) Series Description
decoder.info(for: .studyDate)            // (0008,0020) Study Date
decoder.info(for: .studyTime)            // (0008,0030) Study Time
```

**Image Geometry:**
```swift
decoder.intValue(for: .rows)             // (0028,0010) Height
decoder.intValue(for: .columns)          // (0028,0011) Width
decoder.info(for: .pixelSpacing)         // (0028,0030) Pixel Spacing
decoder.doubleValue(for: .sliceThickness)  // (0018,0050) Slice Thickness
decoder.info(for: .imagePositionPatient)   // (0020,0032) Position
decoder.info(for: .imageOrientationPatient) // (0020,0037) Orientation
```

**Window/Level:**
```swift
decoder.doubleValue(for: .windowCenter)    // (0028,1050) Window Center
decoder.doubleValue(for: .windowWidth)     // (0028,1051) Window Width
decoder.doubleValue(for: .rescaleSlope)    // (0028,1053) Rescale Slope
decoder.doubleValue(for: .rescaleIntercept) // (0028,1052) Rescale Intercept
```

**Pixel Data:**
```swift
decoder.intValue(for: .bitsAllocated)      // (0028,0100) Bits Allocated
decoder.intValue(for: .bitsStored)         // (0028,0101) Bits Stored
decoder.intValue(for: .highBit)            // (0028,0102) High Bit
decoder.intValue(for: .pixelRepresentation) // (0028,0103) Signed/Unsigned
decoder.intValue(for: .samplesPerPixel)    // (0028,0002) Samples Per Pixel
```

### Custom and Private Tags

For custom or private tags not in the standard enum, use raw hex values:

```swift
// Use raw hex for custom/private tags
let manufacturerTag = decoder.info(for: 0x00091001)  // Private tag
let customData = decoder.info(for: 0x00111234)       // Custom tag

// Standard tags should use the enum
let patientName = decoder.info(for: .patientName)  // Preferred
// Not: decoder.info(for: 0x00100010)               // Discouraged for standard tags
```

### Migration from Hex Values

Replace hex values with semantic enum cases:

```swift
// Deprecated: Magic hex numbers
let patient = decoder.info(for: 0x00100010)
let modality = decoder.info(for: 0x00080060)
let rows = decoder.intValue(for: 0x00280010)
let columns = decoder.intValue(for: 0x00280011)

// Recommended: Semantic, discoverable tag names
let patient = decoder.info(for: .patientName)
let modality = decoder.info(for: .modality)
let rows = decoder.intValue(for: .rows)
let columns = decoder.intValue(for: .columns)
```

### Autocomplete Support

The DicomTag enum provides full IDE autocomplete:

```swift
// Start typing "decoder.info(for: ." and get autocomplete suggestions:
decoder.info(for: .pa...)  // Shows: .patientName, .patientID, .patientAge, etc.
decoder.info(for: .study...)  // Shows: .studyInstanceUID, .studyDescription, etc.
decoder.info(for: .window...)  // Shows: .windowCenter, .windowWidth
```

### Complete Example

```swift
import DicomCore

do {
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

    // Patient demographics using type-safe tags
    print("=== Patient Information ===")
    print("Name: \(decoder.info(for: .patientName))")
    print("ID: \(decoder.info(for: .patientID))")
    print("Sex: \(decoder.info(for: .patientSex))")
    print("Age: \(decoder.info(for: .patientAge))")

    // Study information
    print("\n=== Study Information ===")
    print("Date: \(decoder.info(for: .studyDate))")
    print("Description: \(decoder.info(for: .studyDescription))")
    print("Modality: \(decoder.info(for: .modality))")

    // Image geometry with typed access
    print("\n=== Image Properties ===")
    if let rows = decoder.intValue(for: .rows),
       let cols = decoder.intValue(for: .columns) {
        print("Dimensions: \(cols) x \(rows)")
    }

    if let bits = decoder.intValue(for: .bitsAllocated) {
        print("Bit depth: \(bits)")
    }

    // Window/level settings
    print("\n=== Display Settings ===")
    if let center = decoder.doubleValue(for: .windowCenter),
       let width = decoder.doubleValue(for: .windowWidth) {
        print("Window: C=\(center) W=\(width)")
    }

    // Spatial information
    print("\n=== Spatial Information ===")
    print("Position: \(decoder.info(for: .imagePositionPatient))")
    print("Spacing: \(decoder.info(for: .pixelSpacing))")

    if let thickness = decoder.doubleValue(for: .sliceThickness) {
        print("Slice thickness: \(thickness) mm")
    }

} catch {
    print("Error loading DICOM: \(error)")
}
```

## Type-Safe Value Types (V2 APIs)

The library provides dedicated structs for common DICOM parameters, offering better type safety, Codable conformance, and discoverability compared to tuple-based APIs. All V2 APIs coexist with legacy tuple-based APIs for backward compatibility.

### Why Use V2 APIs?

**Benefits:**
- **Type safety** - Structs prevent parameter order mistakes (e.g., swapping center and width)
- **Codable support** - Serialize to JSON for persistence, networking, or logging
- **Sendable conformance** - Safe to pass across concurrency boundaries
- **Computed properties** - Built-in validation (`.isValid`, `.isIdentity`)
- **Methods** - Convenient transformations like `.apply(to:)` for rescale operations
- **Better autocomplete** - Named properties instead of tuple labels
- **Discoverability** - Struct types appear in API documentation and IDE suggestions

### WindowSettings Struct

Represents window center and width values for grayscale display adjustment:

```swift
import DicomCore

do {
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

    // Recommended: Use windowSettingsV2
    let settings = decoder.windowSettingsV2  // Returns WindowSettings struct

    if settings.isValid {
        print("Window center: \(settings.center)")
        print("Window width: \(settings.width)")

        // Serialize to JSON
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(settings)
        print("JSON: \(String(data: jsonData, encoding: .utf8)!)")
        // Output: {"center":50.0,"width":400.0}
    }

    // Legacy (deprecated): Tuple-based API (deprecated)
    let (center, width) = decoder.windowSettings  // Returns tuple

} catch {
    print("Error: \(error)")
}
```

### PixelSpacing Struct

Represents physical spacing between pixels in millimeters:

```swift
do {
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

    // Recommended: Use pixelSpacingV2
    let spacing = decoder.pixelSpacingV2  // Returns PixelSpacing struct

    if spacing.isValid {
        print("Pixel spacing:")
        print("  X (column): \(spacing.x) mm")
        print("  Y (row): \(spacing.y) mm")
        print("  Z (slice): \(spacing.z) mm")

        // Calculate physical dimensions
        let physicalWidth = Double(decoder.width) * spacing.x
        let physicalHeight = Double(decoder.height) * spacing.y
        print("Physical size: \(physicalWidth) × \(physicalHeight) mm")

        // Serialize to JSON
        let jsonData = try JSONEncoder().encode(spacing)
        // Output: {"x":0.5,"y":0.5,"z":1.0}
    }

    // Legacy (deprecated): Tuple-based API (deprecated)
    let (width, height, depth) = decoder.pixelSpacing  // Returns tuple

} catch {
    print("Error: \(error)")
}
```

### RescaleParameters Struct

Represents rescale slope and intercept for converting pixel values to modality units (e.g., Hounsfield Units in CT):

```swift
do {
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

    // Recommended: Use rescaleParametersV2
    let rescale = decoder.rescaleParametersV2  // Returns RescaleParameters struct

    if !rescale.isIdentity {
        print("Rescale parameters:")
        print("  Slope: \(rescale.slope)")
        print("  Intercept: \(rescale.intercept)")

        // Apply rescale transformation
        let storedValue: Double = 1024.0
        let hounsfieldValue = rescale.apply(to: storedValue)
        print("HU value: \(hounsfieldValue)")
        // For CT: output = slope * storedValue + intercept
        // Often slope=1.0, intercept=-1024.0

        // Transform array of pixel values
        if let pixels = decoder.getPixels16() {
            let hounsfieldValues = pixels.map { rescale.apply(to: Double($0)) }
            print("Converted \(hounsfieldValues.count) pixels to HU")
        }
    } else {
        print("No rescale needed (identity transformation)")
    }

    // Legacy (deprecated): Tuple-based API (deprecated)
    let (intercept, slope) = decoder.rescaleParameters  // Returns tuple

} catch {
    print("Error: \(error)")
}
```

### V2 Windowing Methods

All `DCMWindowingProcessor` methods now have V2 variants that return `WindowSettings` structs:

#### Calculate Optimal Window/Level

```swift
import DicomCore

do {
    let decoder = try DCMDecoder(contentsOfFile: "/path/to/ct_scan.dcm")

    guard let pixels = decoder.getPixels16() else {
        print("No pixel data")
        return
    }

    // Recommended: V2 method returns WindowSettings
    let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)

    if optimal.isValid {
        print("Optimal window: center=\(optimal.center), width=\(optimal.width)")

        // Apply windowing with the optimal settings
        let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels,
            center: optimal.center,
            width: optimal.width
        )
    }

    // Legacy (deprecated): Tuple-based method (deprecated)
    let (center, width) = DCMWindowingProcessor.calculateOptimalWindowLevel(pixels16: pixels)

} catch {
    print("Error: \(error)")
}
```

#### Get Medical Presets

```swift
// Recommended: V2 method with enum parameter
let lungSettings = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
print("Lung preset: center=\(lungSettings.center), width=\(lungSettings.width)")
// Output: center=-600.0, width=1500.0

// V2 method with string name
if let boneSettings = DCMWindowingProcessor.getPresetValuesV2(named: "Bone") {
    print("Bone preset: center=\(boneSettings.center), width=\(boneSettings.width)")
    // Output: center=400.0, width=1800.0
}

// Handle invalid preset name
if let invalidSettings = DCMWindowingProcessor.getPresetValuesV2(named: "InvalidName") {
    print("Found preset")
} else {
    print("Preset not found")  // This will be printed
}

// Legacy (deprecated): Tuple-based methods (deprecated)
let (center, width) = DCMWindowingProcessor.getPresetValues(preset: .lung)
let (c2, w2) = DCMWindowingProcessor.getPresetValues(named: "Bone") ?? (0, 0)
```

#### Batch Processing

```swift
// Load multiple images
let paths = ["/path/to/image1.dcm", "/path/to/image2.dcm", "/path/to/image3.dcm"]
var imagePixels: [[UInt16]] = []

for path in paths {
    do {
        let decoder = try DCMDecoder(contentsOfFile: path)
        if let pixels = decoder.getPixels16() {
            imagePixels.append(pixels)
        }
    } catch {
        print("Error loading \(path): \(error)")
    }
}

// Recommended: V2 batch method returns [WindowSettings]
let batchSettings = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
    imagePixels: imagePixels
)

for (index, settings) in batchSettings.enumerated() {
    print("Image \(index + 1): center=\(settings.center), width=\(settings.width)")
    if settings.isValid {
        // Apply windowing to each image
        let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
            pixels16: imagePixels[index],
            center: settings.center,
            width: settings.width
        )
    }
}

// Legacy (deprecated): Tuple-based method (deprecated)
let tupleResults = DCMWindowingProcessor.batchCalculateOptimalWindowLevel(imagePixels: imagePixels)
```

#### Preset Matching

```swift
// Recommended: V2 method accepts WindowSettings struct
let settings = WindowSettings(center: -600.0, width: 1500.0)

if let presetName = DCMWindowingProcessor.getPresetName(settings: settings, tolerance: 50.0) {
    print("Matches preset: \(presetName)")  // "Matches preset: Lung"
} else {
    print("No matching preset found")
}

// Custom tolerance for stricter matching
let strictSettings = WindowSettings(center: -595.0, width: 1510.0)
if let strictMatch = DCMWindowingProcessor.getPresetName(settings: strictSettings, tolerance: 10.0) {
    print("Strict match: \(strictMatch)")
} else {
    print("No match with strict tolerance")  // This will be printed
}

// Legacy (deprecated): Separate center and width parameters (deprecated)
let presetName = DCMWindowingProcessor.getPresetName(center: -600.0, width: 1500.0, tolerance: 50.0)
```

### Complete V2 API Example

```swift
import DicomCore

func processDICOMWithV2APIs(path: String) throws {
    // Load DICOM file
    let decoder = try DCMDecoder(contentsOfFile: path)

    print("=== DICOM Image Information ===")
    print("Dimensions: \(decoder.width) × \(decoder.height)")
    print("Modality: \(decoder.info(for: .modality))")

    // Use V2 APIs for type-safe value access

    // 1. Window Settings
    let windowSettings = decoder.windowSettingsV2
    print("\n=== Window Settings ===")
    if windowSettings.isValid {
        print("Embedded: center=\(windowSettings.center), width=\(windowSettings.width)")

        // Check if it matches a known preset
        if let presetName = DCMWindowingProcessor.getPresetName(settings: windowSettings) {
            print("Matches preset: \(presetName)")
        }
    }

    // 2. Pixel Spacing
    let spacing = decoder.pixelSpacingV2
    print("\n=== Pixel Spacing ===")
    if spacing.isValid {
        print("Physical spacing: \(spacing.x) × \(spacing.y) × \(spacing.z) mm")
        let physicalWidth = Double(decoder.width) * spacing.x
        let physicalHeight = Double(decoder.height) * spacing.y
        print("Physical dimensions: \(physicalWidth) × \(physicalHeight) mm")
    }

    // 3. Rescale Parameters
    let rescale = decoder.rescaleParametersV2
    print("\n=== Rescale Parameters ===")
    if rescale.isIdentity {
        print("No rescale needed (identity transformation)")
    } else {
        print("Slope: \(rescale.slope), Intercept: \(rescale.intercept)")
    }

    // 4. Calculate Optimal Window/Level
    guard let pixels = decoder.getPixels16() else {
        print("No pixel data available")
        return
    }

    let optimalSettings = DCMWindowingProcessor.calculateOptimalWindowLevelV2(pixels16: pixels)
    print("\n=== Optimal Window/Level ===")
    print("Calculated: center=\(optimalSettings.center), width=\(optimalSettings.width)")

    // 5. Compare with Medical Presets
    print("\n=== Medical Presets ===")
    let lungPreset = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)
    let bonePreset = DCMWindowingProcessor.getPresetValuesV2(preset: .bone)
    let softTissuePreset = DCMWindowingProcessor.getPresetValuesV2(preset: .softTissue)

    print("Lung: center=\(lungPreset.center), width=\(lungPreset.width)")
    print("Bone: center=\(bonePreset.center), width=\(bonePreset.width)")
    print("Soft Tissue: center=\(softTissuePreset.center), width=\(softTissuePreset.width)")

    // 6. Apply Windowing
    let pixels8bit = DCMWindowingProcessor.applyWindowLevel(
        pixels16: pixels,
        center: optimalSettings.center,
        width: optimalSettings.width
    )
    print("\n=== Processing Result ===")
    print("Converted \(pixels8bit.count) pixels to 8-bit display range")

    // 7. Serialize Settings to JSON
    print("\n=== Serialization ===")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .prettyPrinted

    if let windowJSON = try? encoder.encode(optimalSettings) {
        print("Window Settings JSON:")
        print(String(data: windowJSON, encoding: .utf8)!)
    }

    if let spacingJSON = try? encoder.encode(spacing) {
        print("\nPixel Spacing JSON:")
        print(String(data: spacingJSON, encoding: .utf8)!)
    }

    if let rescaleJSON = try? encoder.encode(rescale) {
        print("\nRescale Parameters JSON:")
        print(String(data: rescaleJSON, encoding: .utf8)!)
    }
}

// Usage
do {
    try processDICOMWithV2APIs(path: "/path/to/ct_scan.dcm")
} catch {
    print("Error: \(error)")
}
```

### Migration Guide: Tuple-based to V2 APIs

Replace tuple-based APIs with struct-based V2 variants:

```swift
// Deprecated: Tuple-based APIs (deprecated)
let (center, width) = decoder.windowSettings
let (x, y, z) = decoder.pixelSpacing
let (intercept, slope) = decoder.rescaleParameters
let (optC, optW) = decoder.calculateOptimalWindow() ?? (0, 0)
let (presetC, presetW) = DCMWindowingProcessor.getPresetValues(preset: .lung)
let batchTuples = DCMWindowingProcessor.batchCalculateOptimalWindowLevel(imagePixels: images)
let name = DCMWindowingProcessor.getPresetName(center: 50, width: 400)

// Recommended: Struct-based V2 APIs (recommended)
let settings = decoder.windowSettingsV2  // WindowSettings
let spacing = decoder.pixelSpacingV2     // PixelSpacing
let rescale = decoder.rescaleParametersV2  // RescaleParameters
let optimal = decoder.calculateOptimalWindowV2()  // WindowSettings?
let preset = DCMWindowingProcessor.getPresetValuesV2(preset: .lung)  // WindowSettings
let batchSettings = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(imagePixels: images)  // [WindowSettings]
let name = DCMWindowingProcessor.getPresetName(settings: settings)  // String?
```

### Benefits in Practice

**Type Safety:**
```swift
// Deprecated: Easy to swap parameters
func applyWindow(settings: (center: Double, width: Double)) {
    // What if we accidentally swap center and width?
    applyWindowLevel(center: settings.width, width: settings.center)  // Bug!
}

// Recommended: Type-safe property access
func applyWindow(settings: WindowSettings) {
    // Named properties prevent mistakes
    applyWindowLevel(center: settings.center, width: settings.width)  // Correct
}
```

**Codable Support:**
```swift
// Serialize to JSON for storage or networking
let settings = decoder.windowSettingsV2
let jsonData = try JSONEncoder().encode(settings)
UserDefaults.standard.set(jsonData, forKey: "lastWindowSettings")

// Load from JSON
if let savedData = UserDefaults.standard.data(forKey: "lastWindowSettings") {
    let restoredSettings = try JSONDecoder().decode(WindowSettings.self, from: savedData)
    print("Restored: center=\(restoredSettings.center), width=\(restoredSettings.width)")
}
```

**Validation:**
```swift
// Built-in validation
let settings = WindowSettings(center: 50.0, width: -100.0)
if !settings.isValid {
    print("Invalid window width (must be positive)")  // This will be printed
}

let rescale = RescaleParameters(intercept: 0.0, slope: 1.0)
if rescale.isIdentity {
    print("No transformation needed")  // This will be printed
}
```

**Sendable Conformance:**
```swift
// Safe to pass across concurrency boundaries
Task {
    let settings = decoder.windowSettingsV2  // WindowSettings is Sendable
    await processImage(with: settings)  // Safe to pass to async context
}

func processImage(with settings: WindowSettings) async {
    // Use settings safely in async context
}
```

## Basic Usage

### Loading a DICOM File (Legacy Pattern)

> **Note:** This pattern is deprecated. Use the [throwing initializers](#recommended-api-throwing-initializers) for new code.

```swift
import DicomCore

// Legacy pattern - still works but deprecated
let decoder = DCMDecoder()
decoder.setDicomFilename("/path/to/image.dcm")

guard decoder.dicomFileReadSuccess else {
    print("Failed to load DICOM file")
    return
}

// Access image properties
print("Image dimensions: \(decoder.width) x \(decoder.height)")
print("Bit depth: \(decoder.bitDepth)")

// Use type-safe DicomTag enum (recommended)
print("Modality: \(decoder.info(for: .modality))")
// Or legacy hex values: decoder.info(for: 0x00080060)
```

### Reading Pixel Data

```swift
// For 16-bit grayscale images (most common for CT, MR)
if let pixels16 = decoder.getPixels16() {
    print("Loaded \(pixels16.count) 16-bit pixels")

    // Apply window/level transformation
    let windowedData = DCMWindowingProcessor.applyWindowLevel(
        pixels16: pixels16,
        center: decoder.windowCenter,
        width: decoder.windowWidth
    )
}

// For 8-bit grayscale images
if let pixels8 = decoder.getPixels8() {
    print("Loaded \(pixels8.count) 8-bit pixels")
}

// For color/RGB images (ultrasound, etc.)
if let pixels24 = decoder.getPixels24() {
    print("Loaded \(pixels24.count / 3) RGB pixels")
}
```

## Async/Await Usage

### Loading Files Asynchronously with Throwing Initializers (Recommended)

```swift
import DicomCore

func loadDICOMAsync(path: String) async {
    do {
        // Recommended: Use async throwing initializer
        let decoder = try await DCMDecoder(contentsOfFile: path)

        print("Loaded \(decoder.width) x \(decoder.height)")

        // Get pixels asynchronously (if needed)
        if let pixels = await decoder.getPixels16Async() {
            print("Loaded \(pixels.count) pixels")
        }
    } catch DICOMError.fileNotFound(let filePath) {
        print("File not found: \(filePath)")
    } catch DICOMError.invalidDICOMFormat(let filePath, let reason) {
        print("Invalid DICOM at \(filePath): \(reason)")
    } catch {
        print("Error: \(error)")
    }
}

// Usage
Task {
    await loadDICOMAsync(path: "/path/to/image.dcm")
}
```

### Loading Files Asynchronously (Legacy Pattern)

> **Note:** This pattern is deprecated. Use the [async throwing initializers](#recommended-api-throwing-initializers) for new code.

```swift
import DicomCore

func loadDICOMAsyncLegacy(path: String) async {
    let decoder = DCMDecoder()

    // Legacy pattern (deprecated)
    let success = await decoder.loadDICOMFileAsync(path)

    guard success else {
        print("Failed to load DICOM file")
        return
    }

    // Get pixels asynchronously
    if let pixels = await decoder.getPixels16Async() {
        print("Loaded \(pixels.count) pixels")

        // Process pixels...
    }
}

// Usage
Task {
    await loadDICOMAsyncLegacy(path: "/path/to/image.dcm")
}
```

### Thumbnail Generation

```swift
// Get downsampled pixels for thumbnail (much faster than full resolution)
if let thumbnail = await decoder.getDownsampledPixels16Async(maxDimension: 150) {
    print("Thumbnail size: \(thumbnail.width) x \(thumbnail.height)")

    // Apply window/level to thumbnail
    let windowedThumb = DCMWindowingProcessor.applyWindowLevel(
        pixels16: thumbnail.pixels,
        center: decoder.windowCenter,
        width: decoder.windowWidth
    )
}
```

## Validation and Error Handling

### Validating DICOM Files

```swift
let decoder = DCMDecoder()

// Validate file structure before loading
let validation = decoder.validateDICOMFile("/path/to/image.dcm")

if !validation.isValid {
    print("Validation failed:")
    for issue in validation.issues {
        print("  - \(issue)")
    }
    return
}

// Load the validated file
let loadedDecoder = try DCMDecoder(contentsOfFile: "/path/to/image.dcm")

// Check detailed validation status
let status = loadedDecoder.getValidationStatus()
print("Valid: \(status.isValid)")
print("Dimensions: \(status.width) x \(status.height)")
print("Has pixels: \(status.hasPixels)")
print("Compressed: \(status.isCompressed)")
```

### Using Convenience Methods

```swift
// Check image type
if decoder.isGrayscale {
    print("Grayscale image")
} else if decoder.isColorImage {
    print("Color image")
}

if decoder.isMultiFrame {
    print("Multi-frame image with \(decoder.nImages) frames")
}

// Check validity
if decoder.isValid() {
    print("Decoder has valid DICOM data")
}
```

## Window/Level Operations

### Applying Window/Level

```swift
guard let pixels16 = decoder.getPixels16() else { return }

// Use default window/level from DICOM header
let defaultWindowed = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: decoder.windowCenter,
    width: decoder.windowWidth
)

// Use custom window/level
let customWindowed = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 40.0,  // Brain window center
    width: 80.0    // Brain window width
)
```

### Calculating Optimal Window/Level

```swift
guard let pixels16 = decoder.getPixels16() else { return }

// Calculate optimal window based on image statistics
let optimal = DCMWindowingProcessor.calculateOptimalWindowLevel(pixels16: pixels16)
print("Optimal window - Center: \(optimal.center), Width: \(optimal.width)")

// Or use decoder convenience method
if let optimal = decoder.calculateOptimalWindow() {
    let windowed = DCMWindowingProcessor.applyWindowLevel(
        pixels16: pixels16,
        center: optimal.center,
        width: optimal.width
    )
}
```

## Medical Presets

### Using CT Presets

```swift
// Get all available presets
let allPresets = DCMWindowingProcessor.allPresets
for preset in allPresets {
    let values = DCMWindowingProcessor.getPresetValues(preset: preset)
    print("\(preset.displayName): C:\(values.center) W:\(values.width)")
}

// Get CT-specific presets
let ctPresets = DCMWindowingProcessor.ctPresets
// Returns: [.lung, .bone, .softTissue, .brain, .liver, .mediastinum, etc.]

// Apply a specific preset
let brainPreset = DCMWindowingProcessor.getPresetValues(preset: .brain)
let brainWindowed = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: brainPreset.center,
    width: brainPreset.width
)
```

### Auto-Suggesting Presets

```swift
// Use type-safe DicomTag enum for metadata access
let modality = decoder.info(for: .modality)
let bodyPart = decoder.info(for: .bodyPartExamined)

let suggestions = DCMWindowingProcessor.suggestPresets(
    for: modality,
    bodyPart: bodyPart
)

print("Suggested presets:")
for preset in suggestions {
    print("  - \(preset.displayName)")
}
```

### Preset Lookup by Name

```swift
// Case-insensitive preset lookup
if let lungPreset = DCMWindowingProcessor.getPresetValues(named: "lung") {
    print("Lung preset: C:\(lungPreset.center) W:\(lungPreset.width)")
}

// Multi-word presets
if let tissuePreset = DCMWindowingProcessor.getPresetValues(named: "soft tissue") {
    print("Soft tissue preset: C:\(tissuePreset.center) W:\(tissuePreset.width)")
}
```

## Metadata Extraction

### Patient Information

```swift
let patientInfo = decoder.getPatientInfo()
print("Patient Name: \(patientInfo["Name"] ?? "Unknown")")
print("Patient ID: \(patientInfo["ID"] ?? "Unknown")")
print("Patient Sex: \(patientInfo["Sex"] ?? "Unknown")")
print("Patient Age: \(patientInfo["Age"] ?? "Unknown")")
```

### Study Information

```swift
let studyInfo = decoder.getStudyInfo()
print("Study UID: \(studyInfo["StudyInstanceUID"] ?? "")")
print("Study Date: \(studyInfo["StudyDate"] ?? "")")
print("Study Time: \(studyInfo["StudyTime"] ?? "")")
print("Description: \(studyInfo["StudyDescription"] ?? "")")
```

### Series Information

```swift
let seriesInfo = decoder.getSeriesInfo()
print("Series UID: \(seriesInfo["SeriesInstanceUID"] ?? "")")
print("Series Number: \(seriesInfo["SeriesNumber"] ?? "")")
print("Modality: \(seriesInfo["Modality"] ?? "")")
print("Description: \(seriesInfo["SeriesDescription"] ?? "")")
```

### Accessing Individual Tags

```swift
// Recommended: Use type-safe DicomTag enum

// String values
let patientName = decoder.info(for: .patientName)
let modality = decoder.info(for: .modality)

// Integer values
if let rows = decoder.intValue(for: .rows) {
    print("Rows: \(rows)")
}

if let columns = decoder.intValue(for: .columns) {
    print("Columns: \(columns)")
}

// Double values
if let sliceThickness = decoder.doubleValue(for: .sliceThickness) {
    print("Slice thickness: \(sliceThickness) mm")
}

if let windowCenter = decoder.doubleValue(for: .windowCenter) {
    print("Window center: \(windowCenter)")
}

// Legacy (deprecated): Raw hex values (use only for custom/private tags)
let privateTag = decoder.info(for: 0x00091001)  // Private manufacturer tag

// Get all tags
let allTags = decoder.getAllTags()
for (tag, value) in allTags {
    print("\(tag): \(value)")
}
```

### Using Convenience Properties

```swift
// Image dimensions
let dims = decoder.imageDimensions
print("Size: \(dims.width) x \(dims.height)")

// Pixel spacing
let spacing = decoder.pixelSpacing
print("Spacing: \(spacing.width) x \(spacing.height) x \(spacing.depth) mm")

// Window settings
let window = decoder.windowSettings
print("Window: C:\(window.center) W:\(window.width)")

// Rescale parameters (for Hounsfield Units in CT)
let rescale = decoder.rescaleParameters
print("Rescale: slope=\(rescale.slope) intercept=\(rescale.intercept)")
```

## Image Quality Metrics

### Calculating Quality Metrics

```swift
guard let pixels16 = decoder.getPixels16() else { return }

let metrics = DCMWindowingProcessor.calculateQualityMetrics(pixels16: pixels16)

print("Mean intensity: \(metrics["mean"] ?? 0)")
print("Standard deviation: \(metrics["std_deviation"] ?? 0)")
print("Min value: \(metrics["min_value"] ?? 0)")
print("Max value: \(metrics["max_value"] ?? 0)")
print("Contrast: \(metrics["contrast"] ?? 0)")
print("SNR: \(metrics["snr"] ?? 0)")
print("Dynamic range: \(metrics["dynamic_range"] ?? 0) dB")

// Or use decoder convenience method
if let metrics = decoder.getQualityMetrics() {
    print("Image quality metrics: \(metrics)")
}
```

## Batch Processing

The library provides powerful batch loading APIs that enable concurrent processing of multiple DICOM files using Swift's structured concurrency. These APIs are thread-safe, Sendable-compliant, and optimized for modern Swift concurrency patterns.

### Concurrent Batch Loading with DCMDecoder

The `DCMDecoder.loadBatch()` method loads multiple DICOM files concurrently using TaskGroup:

```swift
import DicomCore

// Concurrent batch loading (recommended)
let urls = [
    URL(fileURLWithPath: "/path/to/image1.dcm"),
    URL(fileURLWithPath: "/path/to/image2.dcm"),
    URL(fileURLWithPath: "/path/to/image3.dcm"),
    URL(fileURLWithPath: "/path/to/image4.dcm")
]

// Load files concurrently with maxConcurrency limit
let results = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 4)

// Process results - ordering matches input URLs
for result in results {
    if let decoder = result.decoder {
        print("✓ Loaded: \(decoder.width) x \(decoder.height)")

        // Access metadata
        let modality = decoder.info(for: .modality)
        let patientName = decoder.info(for: .patientName)
        print("  Patient: \(patientName), Modality: \(modality)")

        // Get pixels
        if let pixels = decoder.getPixels16() {
            print("  Pixels: \(pixels.count)")
        }
    } else if let error = result.error {
        print("✗ Failed to load \(result.url.lastPathComponent): \(error)")
    }
}

// Filter successful results
let successfulDecoders = results.compactMap { $0.decoder }
print("\nSuccessfully loaded \(successfulDecoders.count) of \(results.count) files")
```

### Batch Loading with Partial Failure Handling

The batch loading API handles partial failures gracefully:

```swift
// Load files from directory with error handling
func loadDicomDirectory(at url: URL) async {
    do {
        // Get all DICOM file URLs
        let fileManager = FileManager.default
        let urls = try fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "dcm" }

        print("Found \(urls.count) DICOM files")

        // Load with concurrency limit
        let results = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 4)

        // Separate successes and failures
        var successes: [(URL, DCMDecoder)] = []
        var failures: [(URL, Error)] = []

        for result in results {
            if let decoder = result.decoder {
                successes.append((result.url, decoder))
            } else if let error = result.error {
                failures.append((result.url, error))
            }
        }

        // Report results
        print("\n✓ Successfully loaded: \(successes.count) files")
        print("✗ Failed to load: \(failures.count) files")

        // Log failures
        for (url, error) in failures {
            print("  - \(url.lastPathComponent): \(error.localizedDescription)")
        }

        // Process successful files
        for (url, decoder) in successes {
            print("Processing: \(url.lastPathComponent)")
            // Process decoder...
        }
    } catch {
        print("Error reading directory: \(error)")
    }
}

// Usage
await loadDicomDirectory(at: URL(fileURLWithPath: "/path/to/dicom/files"))
```

### Batch Series Loading with Progress

Load multiple DICOM series concurrently with progress tracking:

```swift
import DicomCore

// Load multiple series with progress tracking
let seriesDirectories = [
    URL(fileURLWithPath: "/path/to/series1"),
    URL(fileURLWithPath: "/path/to/series2"),
    URL(fileURLWithPath: "/path/to/series3")
]

let loader = DicomSeriesLoader()

do {
    // Load series concurrently with progress callbacks
    let volumes = try await loader.batchLoadSeries(
        seriesDirectories: seriesDirectories,
        maxConcurrency: 2,
        progressHandler: { fractionComplete, seriesCompleted in
            let percentage = Int(fractionComplete * 100)
            print("Progress: \(percentage)% (\(seriesCompleted) series completed)")
        }
    )

    // Process loaded volumes
    for (index, volume) in volumes.enumerated() {
        print("\nSeries \(index + 1):")
        print("  Dimensions: \(volume.width) × \(volume.height) × \(volume.depth)")
        print("  Spacing: \(volume.spacing.x) × \(volume.spacing.y) × \(volume.spacing.z) mm")
        print("  Description: \(volume.seriesDescription)")
        print("  Voxel count: \(volume.voxels.count)")
    }

    print("\nSuccessfully loaded \(volumes.count) series")
} catch {
    print("Failed to load series: \(error)")
}
```

### Batch File Loading with DicomSeriesLoader

Load multiple individual files without assembling into volumes:

```swift
let loader = DicomSeriesLoader()

// Get file URLs
let fileManager = FileManager.default
let urls = try fileManager.contentsOfDirectory(
    at: URL(fileURLWithPath: "/path/to/dicom/files"),
    includingPropertiesForKeys: nil
).filter { $0.pathExtension.lowercased() == "dcm" }

// Load files concurrently
let results = await loader.batchLoadFiles(urls: urls, maxConcurrency: 4)

// Process results
let successfulDecoders = results.compactMap { result -> (any DicomDecoderProtocol)? in
    if result.success, let decoder = result.decoder {
        return decoder
    }

    if let error = result.error {
        print("Failed to load \(result.url.lastPathComponent): \(error)")
    }

    return nil
}

print("Loaded \(successfulDecoders.count) of \(results.count) files")

// Process decoders
for decoder in successfulDecoders {
    let studyUID = decoder.info(for: .studyInstanceUID)
    let seriesUID = decoder.info(for: .seriesInstanceUID)
    print("Study: \(studyUID), Series: \(seriesUID)")
}
```

### Actor-Isolated DICOM Processing

The library's Sendable conformance enables safe usage within actors:

```swift
import DicomCore

// Actor for managing DICOM files
actor DicomRepository {
    private var decoders: [String: DCMDecoder] = [:]

    // Load and store decoder
    func loadFile(at url: URL) async throws {
        let decoder = try await DCMDecoder(contentsOf: url)
        let studyUID = decoder.info(for: .studyInstanceUID)
        decoders[studyUID] = decoder
    }

    // Batch load multiple files
    func loadFiles(urls: [URL]) async {
        let results = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 4)

        for result in results {
            if let decoder = result.decoder {
                let studyUID = decoder.info(for: .studyInstanceUID)
                decoders[studyUID] = decoder
            }
        }
    }

    // Get decoder by study UID
    func decoder(forStudy studyUID: String) -> DCMDecoder? {
        return decoders[studyUID]
    }

    // Get all patient names
    func getAllPatientNames() -> [String] {
        return decoders.values.map { $0.info(for: .patientName) }
    }

    // Get image dimensions for study
    func getDimensions(forStudy studyUID: String) -> (width: Int, height: Int)? {
        guard let decoder = decoders[studyUID] else { return nil }
        return (decoder.width, decoder.height)
    }

    // Get pixel data for study
    func getPixels(forStudy studyUID: String) -> [UInt16]? {
        guard let decoder = decoders[studyUID] else { return nil }
        return decoder.getPixels16()
    }

    // Clear cache
    func clearCache() {
        decoders.removeAll()
    }
}

// Usage
let repository = DicomRepository()

// Load files into actor-isolated storage
let urls = [
    URL(fileURLWithPath: "/path/to/image1.dcm"),
    URL(fileURLWithPath: "/path/to/image2.dcm")
]

await repository.loadFiles(urls: urls)

// Access data safely through actor
let patientNames = await repository.getAllPatientNames()
print("Patients: \(patientNames)")

if let dimensions = await repository.getDimensions(forStudy: "1.2.3.4.5") {
    print("Image size: \(dimensions.width) × \(dimensions.height)")
}
```

### Concurrent Processing with Task Groups

Process DICOM files using structured concurrency patterns:

```swift
import DicomCore

// Process files with custom TaskGroup logic
func processDicomFilesWithCustomLogic(urls: [URL]) async {
    await withTaskGroup(of: (URL, Result<DCMDecoder, Error>).self) { group in
        // Add tasks for each file
        for url in urls {
            group.addTask {
                do {
                    let decoder = try await DCMDecoder(contentsOf: url)
                    return (url, .success(decoder))
                } catch {
                    return (url, .failure(error))
                }
            }
        }

        // Process results as they complete
        for await (url, result) in group {
            switch result {
            case .success(let decoder):
                print("✓ \(url.lastPathComponent): \(decoder.width)×\(decoder.height)")

                // Calculate optimal window/level
                if let pixels = decoder.getPixels16() {
                    let optimal = DCMWindowingProcessor.calculateOptimalWindowLevelV2(
                        pixels16: pixels
                    )
                    print("  Optimal window: C=\(optimal.center) W=\(optimal.width)")
                }

            case .failure(let error):
                print("✗ \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }
}

// Usage
let urls = [
    URL(fileURLWithPath: "/path/to/image1.dcm"),
    URL(fileURLWithPath: "/path/to/image2.dcm"),
    URL(fileURLWithPath: "/path/to/image3.dcm")
]

await processDicomFilesWithCustomLogic(urls: urls)
```

### Controlling Concurrency

Adjust concurrency levels based on your system resources:

```swift
// Low concurrency for memory-constrained environments
let results = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 2)

// Moderate concurrency (default)
let results = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 4)

// High concurrency for powerful systems
let results = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 8)

// Series loading with limited concurrency
let volumes = try await loader.batchLoadSeries(
    seriesDirectories: directories,
    maxConcurrency: 2  // Recommended: 2-3 for series loading
)
```

### Sequential vs Concurrent Processing Comparison

```swift
import DicomCore

// Sequential processing (slower, but predictable)
func loadSequentially(urls: [URL]) async -> [DCMDecoder] {
    var decoders: [DCMDecoder] = []

    for url in urls {
        do {
            let decoder = try await DCMDecoder(contentsOf: url)
            decoders.append(decoder)
        } catch {
            print("Failed: \(url.lastPathComponent)")
        }
    }

    return decoders
}

// Concurrent processing (faster, utilizing multiple cores)
func loadConcurrently(urls: [URL]) async -> [DCMDecoder] {
    let results = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 4)
    return results.compactMap { $0.decoder }
}

// Performance comparison
let urls = /* array of 20 DICOM files */

let startSequential = Date()
let sequentialResults = await loadSequentially(urls: urls)
let sequentialTime = Date().timeIntervalSince(startSequential)
print("Sequential: \(sequentialResults.count) files in \(sequentialTime)s")

let startConcurrent = Date()
let concurrentResults = await loadConcurrently(urls: urls)
let concurrentTime = Date().timeIntervalSince(startConcurrent)
print("Concurrent: \(concurrentResults.count) files in \(concurrentTime)s")

let speedup = sequentialTime / concurrentTime
print("Speedup: \(String(format: "%.2f", speedup))x")
```

### Batch Window/Level Application

Process multiple images with different window settings:

```swift
// Load multiple images
let urls = [
    URL(fileURLWithPath: "/path/to/ct1.dcm"),
    URL(fileURLWithPath: "/path/to/ct2.dcm"),
    URL(fileURLWithPath: "/path/to/ct3.dcm")
]

let results = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 4)
let decoders = results.compactMap { $0.decoder }

// Get pixel arrays
let imagePixels: [[UInt16]] = decoders.compactMap { $0.getPixels16() }

// Calculate optimal window/level for each image
let optimalSettings = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
    imagePixels: imagePixels
)

// Apply windowing to each image
for (index, settings) in optimalSettings.enumerated() {
    print("Image \(index + 1): center=\(settings.center), width=\(settings.width)")

    if settings.isValid, let pixels = imagePixels[safe: index] {
        let windowed = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels,
            center: settings.center,
            width: settings.width
        )

        if let windowedData = windowed {
            print("  Converted to 8-bit: \(windowedData.count) bytes")
            // Use windowedData for display...
        }
    }
}

// Safe array subscript extension (add to your code)
extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
```

### Complete Batch Processing Example

```swift
import DicomCore
import Foundation

// Complete batch processing workflow
func processDicomBatch(directoryPath: String) async {
    print("=== Batch DICOM Processing ===\n")

    // 1. Find all DICOM files
    let directoryURL = URL(fileURLWithPath: directoryPath)
    let fileManager = FileManager.default

    guard let urls = try? fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil
    ).filter({ $0.pathExtension.lowercased() == "dcm" }) else {
        print("Failed to read directory")
        return
    }

    print("Found \(urls.count) DICOM files\n")

    // 2. Load files concurrently
    print("Loading files concurrently...")
    let startTime = Date()
    let results = await DCMDecoder.loadBatch(urls: urls, maxConcurrency: 4)
    let loadTime = Date().timeIntervalSince(startTime)

    // 3. Analyze results
    let successfulDecoders = results.compactMap { $0.decoder }
    let failures = results.filter { $0.isFailure }

    print("Loaded in \(String(format: "%.2f", loadTime))s")
    print("✓ Success: \(successfulDecoders.count)")
    print("✗ Failures: \(failures.count)\n")

    // 4. Group by study
    var studyGroups: [String: [DCMDecoder]] = [:]
    for decoder in successfulDecoders {
        let studyUID = decoder.info(for: .studyInstanceUID)
        studyGroups[studyUID, default: []].append(decoder)
    }

    print("Found \(studyGroups.count) studies\n")

    // 5. Process each study
    for (studyUID, decoders) in studyGroups {
        guard let firstDecoder = decoders.first else { continue }

        print("Study: \(studyUID)")
        print("  Patient: \(firstDecoder.info(for: .patientName))")
        print("  Modality: \(firstDecoder.info(for: .modality))")
        print("  Images: \(decoders.count)")

        // Calculate optimal window/level for study
        let pixels = decoders.compactMap { $0.getPixels16() }
        if !pixels.isEmpty {
            let optimalSettings = DCMWindowingProcessor.batchCalculateOptimalWindowLevelV2(
                imagePixels: pixels
            )

            if let firstSettings = optimalSettings.first, firstSettings.isValid {
                print("  Optimal window: C=\(Int(firstSettings.center)) W=\(Int(firstSettings.width))")
            }
        }

        print()
    }

    // 6. Log failures
    if !failures.isEmpty {
        print("Failed files:")
        for result in failures {
            print("  - \(result.url.lastPathComponent)")
            if let error = result.error {
                print("    Error: \(error.localizedDescription)")
            }
        }
    }
}

// Usage
await processDicomBatch(directoryPath: "/path/to/dicom/files")
```

## Protocol-Based Dependency Injection

The library uses protocol-based dependency injection to enable testability, flexibility, and clean architecture. All core services implement protocols that can be mocked or replaced with custom implementations.

### Why Use Dependency Injection?

- **Testability**: Replace real implementations with mocks for unit testing
- **Flexibility**: Swap implementations without changing client code
- **Maintainability**: Clear separation of concerns and dependencies
- **Isolation**: Test components independently without file I/O

### Available Protocols

All core components have protocol abstractions:

- `DicomDecoderProtocol` - Abstracts DICOM file parsing (implemented by `DCMDecoder`, `MockDicomDecoder`)
- `StudyDataServiceProtocol` - Abstracts study/series processing (implemented by `StudyDataService`)
- `DicomSeriesLoaderProtocol` - Abstracts series volume loading (implemented by `DicomSeriesLoader`)
- `DicomDictionaryProtocol` - Abstracts DICOM tag lookups (implemented by `DCMDictionary`)
- `FileImportServiceProtocol` - Abstracts file import operations (implemented by `FileImportService`)

### Basic Dependency Injection

Services accept decoder factories instead of creating decoders directly:

```swift
import DicomCore

// Production: Inject real decoder factory
let studyService = StudyDataService(
    decoderFactory: { DCMDecoder() }
)

// Testing: Inject mock decoder factory
let mockStudyService = StudyDataService(
    decoderFactory: { MockDicomDecoder() }
)

// Use the service (same API regardless of implementation)
let studies = studyService.loadStudiesFromDirectory("/path/to/dicom/files")
```

### Testing with MockDicomDecoder

The `MockDicomDecoder` provides a fully configurable implementation for testing:

```swift
import XCTest
@testable import DicomCore

class MyDicomTests: XCTestCase {
    func testStudyLoading() {
        // Create and configure mock decoder
        let mock = MockDicomDecoder()
        mock.width = 512
        mock.height = 512
        mock.bitDepth = 16
        mock.dicomFileReadSuccess = true

        // Configure metadata tags (using raw values for mocking)
        // Note: Use DicomTag enum values in production code
        mock.setTag(0x00100010, value: "Test^Patient")       // .patientName
        mock.setTag(0x0020000D, value: "1.2.3.4.5.6.7.8.9")  // .studyInstanceUID
        mock.setTag(0x0020000E, value: "1.2.3.4.5.6.7.8.10") // .seriesInstanceUID
        mock.setTag(0x00080060, value: "CT")                 // .modality

        // Configure pixel data
        let testPixels = [UInt16](repeating: 1000, count: 512 * 512)
        mock.setPixels16(testPixels)

        // Inject mock into service
        let service = StudyDataService(
            decoderFactory: { mock }
        )

        // Test the service with mock data
        let studies = service.loadStudiesFromDirectory("/test/path")

        // Verify results
        XCTAssertEqual(studies.count, 1)
        XCTAssertEqual(studies[0].studyInstanceUID, "1.2.3.4.5.6.7.8.9")
    }
}
```

### Factory Pattern for Multiple Files

Services use factories instead of single instances to ensure clean state per file:

```swift
// Wrong: Single decoder instance (state leakage)
let decoder = DCMDecoder()
let service = StudyDataService(decoder: decoder)  // Not the actual API!

// Correct: Factory creates fresh decoder per file
let service = StudyDataService(
    decoderFactory: { DCMDecoder() }
)

// Each file gets its own decoder instance
// Thread-safe for concurrent file processing
// No state leakage between files
```

### Custom Protocol Implementations

You can create custom implementations for specialized use cases:

```swift
// Custom decoder that adds logging
class LoggingDicomDecoder: DicomDecoderProtocol {
    private let underlying: DicomDecoderProtocol
    private let logger: Logger

    init(underlying: DicomDecoderProtocol = DCMDecoder(), logger: Logger) {
        self.underlying = underlying
        self.logger = logger
    }

    func setDicomFilename(_ filename: String) {
        logger.info("Loading DICOM file: \(filename)")
        underlying.setDicomFilename(filename)

        if underlying.dicomFileReadSuccess {
            logger.info("Successfully loaded \(width)x\(height) image")
        } else {
            logger.error("Failed to load DICOM file")
        }
    }

    // Forward all other protocol methods to underlying
    var width: Int { underlying.width }
    var height: Int { underlying.height }
    // ... implement remaining protocol requirements ...
}

// Use custom implementation
let service = StudyDataService(
    decoderFactory: { LoggingDicomDecoder(logger: myLogger) }
)
```

### Injecting Dependencies in DicomSeriesLoader

Load 3D volumes with custom decoders:

```swift
// Production usage with real decoder
let seriesLoader = DicomSeriesLoader(
    decoderFactory: { DCMDecoder() }
)

// Test usage with mock decoder
let mockLoader = DicomSeriesLoader(
    decoderFactory: {
        let mock = MockDicomDecoder()
        mock.width = 512
        mock.height = 512
        mock.setPixels16([/* test data */])
        mock.setTag(0x00200032, value: "0\\0\\0")  // .imagePositionPatient
        return mock
    }
)

// Load series (same API)
let result = try await seriesLoader.loadSeries(
    from: seriesMetadata,
    progressHandler: { progress in
        print("Loading: \(Int(progress * 100))%")
    }
)
```

### Testing FileImportService

Inject decoders into file import operations:

```swift
func testZipExtraction() {
    // Create mock decoder
    let mock = MockDicomDecoder()
    mock.dicomFileReadSuccess = true
    mock.setTag(0x0020000D, value: "1.2.3.4.5")  // .studyInstanceUID

    // Inject into FileImportService
    let importService = FileImportService(
        decoderFactory: { mock }
    )

    // Test import
    let result = importService.importFile(at: URL(fileURLWithPath: "/test.zip"))

    XCTAssertEqual(result.success, true)
}
```

### Integration Testing with Mixed Implementations

Combine real and mock implementations:

```swift
func testIntegration() {
    // Use real dictionary for tag lookups
    let realDictionary = DCMDictionary()

    // Use mock decoder for file I/O
    let mockDecoder = MockDicomDecoder()
    mockDecoder.setTag(0x00100010, value: "Test^Patient")  // .patientName

    // Combine in service
    let service = StudyDataService(
        decoderFactory: { mockDecoder }
    )

    // Dictionary works with real tag database
    let tagName = realDictionary.description(forKey: "00100010")
    XCTAssertEqual(tagName, "Patient's Name")

    // Service uses mock for testing
    let studies = service.loadStudiesFromDirectory("/test")
    XCTAssertEqual(studies[0].patientName, "Test^Patient")
}
```

### Backward Compatibility

The library maintains backward compatibility with default initializers:

```swift
// Modern DI approach (recommended)
let service = StudyDataService(
    decoderFactory: { DCMDecoder() }
)

// Legacy approach (still works, uses default factory internally)
let legacyService = StudyDataService()

// Both work identically for production code
```

### Best Practices

1. **Always use factories in services**: Each file should get a fresh decoder
2. **Configure mocks completely**: Set all required properties and tags
3. **Test with protocols**: Write tests against protocol types, not concrete classes
4. **Use default factories for production**: Only inject custom factories for testing
5. **Thread safety**: Services using factories are thread-safe for concurrent operations

### Complete Testing Example

```swift
import XCTest
@testable import DicomCore

class CompleteDIExample: XCTestCase {
    func testCompleteWorkflow() async throws {
        // 1. Setup mock decoder with complete data
        let mock = MockDicomDecoder()

        // Configure image properties
        mock.width = 512
        mock.height = 512
        mock.bitDepth = 16
        mock.dicomFileReadSuccess = true

        // Configure spatial properties
        mock.pixelWidth = 0.5
        mock.pixelHeight = 0.5
        mock.pixelDepth = 1.0

        // Configure display properties
        mock.windowCenter = 40.0
        mock.windowWidth = 80.0

        // Configure metadata (using raw hex for mocking)
        // In production code, access these with DicomTag enum (e.g., .patientName)
        mock.setTag(0x00100010, value: "Doe^John")            // .patientName
        mock.setTag(0x00100020, value: "12345")               // .patientID
        mock.setTag(0x0020000D, value: "1.2.840.113619.2.1.1") // .studyInstanceUID
        mock.setTag(0x0020000E, value: "1.2.840.113619.2.1.2") // .seriesInstanceUID
        mock.setTag(0x00080060, value: "CT")                  // .modality
        mock.setTag(0x00200032, value: "0\\0\\0")             // .imagePositionPatient
        mock.setTag(0x00200037, value: "1\\0\\0\\0\\1\\0")    // .imageOrientationPatient

        // Configure pixel data
        let pixels = [UInt16](repeating: 1000, count: 512 * 512)
        mock.setPixels16(pixels)

        // 2. Inject into services
        let studyService = StudyDataService(
            decoderFactory: { mock }
        )

        let seriesLoader = DicomSeriesLoader(
            decoderFactory: { mock }
        )

        // 3. Test complete workflow
        let studies = studyService.loadStudiesFromDirectory("/test")

        XCTAssertEqual(studies.count, 1)
        XCTAssertEqual(studies[0].patientName, "Doe^John")
        XCTAssertEqual(studies[0].series.count, 1)

        let series = studies[0].series[0]
        XCTAssertEqual(series.modality, "CT")

        // 4. Test series loading
        let result = try await seriesLoader.loadSeries(from: series.images)

        XCTAssertEqual(result.width, 512)
        XCTAssertEqual(result.height, 512)
        XCTAssertEqual(result.slices.count, 1)

        // 5. Verify pixel data
        XCTAssertEqual(result.slices[0].count, 512 * 512)
        XCTAssertEqual(result.slices[0][0], 1000)
    }
}
```

## Advanced Features

### Hounsfield Unit Conversion (CT Images)

```swift
let rescale = decoder.rescaleParameters

// Convert pixel value to Hounsfield Units
let pixelValue = 1024.0
let hu = decoder.applyRescale(to: pixelValue)
print("Pixel \(pixelValue) = \(hu) HU")

// Or use static method
let hu2 = DCMWindowingProcessor.pixelValueToHU(
    pixelValue: pixelValue,
    rescaleSlope: rescale.slope,
    rescaleIntercept: rescale.intercept
)

// Convert HU to pixel value
let pixelVal = DCMWindowingProcessor.huToPixelValue(
    hu: 0.0,  // Water
    rescaleSlope: rescale.slope,
    rescaleIntercept: rescale.intercept
)
```

### Image Enhancement

```swift
guard let pixels16 = decoder.getPixels16() else { return }

// Apply window/level first
let windowed = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 40.0,
    width: 80.0
)

guard let windowedData = windowed else { return }

// Apply global histogram equalization
let enhanced = DCMWindowingProcessor.applyHistogramEqualization(
    imageData: windowedData,
    width: decoder.width,
    height: decoder.height
)

// Apply noise reduction
let denoised = DCMWindowingProcessor.applyNoiseReduction(
    imageData: windowedData,
    width: decoder.width,
    height: decoder.height,
    strength: 0.5
)
```

### Performance Optimization

```swift
guard let pixels16 = decoder.getPixels16() else { return }

// Use automatic backend selection for large datasets
let windowed = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 40.0,
    width: 80.0,
    processingMode: .auto
)

// Use downsampled pixels for preview/thumbnail
if let thumbnail = decoder.getDownsampledPixels16(maxDimension: 150) {
    // Much faster than processing full resolution
    let windowedThumb = DCMWindowingProcessor.applyWindowLevel(
        pixels16: thumbnail.pixels,
        center: 40.0,
        width: 80.0
    )
}
```

### Error Handling with DICOMError

```swift
import DicomCore

func loadDICOM(path: String) throws -> DCMDecoder {
    // Throwing initializer handles validation and loading
    let decoder = try DCMDecoder(contentsOfFile: path)

    // Check for compressed images
    if decoder.compressedImage {
        throw DICOMError.unsupportedTransferSyntax(
            syntax: "Compressed transfer syntax not supported"
        )
    }

    // Verify required metadata using type-safe DicomTag enum
    let studyUID = decoder.info(for: .studyInstanceUID)
    if studyUID.isEmpty {
        throw DICOMError.missingRequiredTag(
            tag: "StudyInstanceUID",
            description: "Study Instance UID"
        )
    }

    return decoder
}

// Usage with error handling
do {
    try loadDICOM(path: "/path/to/image.dcm")
    print("DICOM loaded successfully")
} catch let error as DICOMError {
    print("Error: \(error.localizedDescription)")
    print("Suggestion: \(error.recoverySuggestion ?? "None")")
    print("Category: \(error.category)")
    print("Severity: \(error.severity)")
} catch {
    print("Unknown error: \(error)")
}
```

## Complete Example: DICOM Image Processing Pipeline

```swift
import DicomCore
import Foundation

class DICOMImageProcessor {

    func loadAndProcess(path: String) async throws -> ProcessedImage {
        // Load file asynchronously with throwing initializer
        let decoder = try await DCMDecoder(contentsOfFile: path)

        // Get metadata
        let patientInfo = decoder.getPatientInfo()
        let studyInfo = decoder.getStudyInfo()
        let seriesInfo = decoder.getSeriesInfo()

        // Get suggested presets using type-safe DicomTag enum
        let modality = decoder.info(for: .modality)
        let bodyPart = decoder.info(for: .bodyPartExamined)
        let suggestedPresets = DCMWindowingProcessor.suggestPresets(
            for: modality,
            bodyPart: bodyPart
        )

        // Get pixels
        guard let pixels16 = await decoder.getPixels16Async() else {
            throw DICOMError.invalidPixelData(reason: "No pixel data available")
        }

        // Calculate optimal window
        let optimal = DCMWindowingProcessor.calculateOptimalWindowLevel(
            pixels16: pixels16
        )

        // Apply window/level
        guard let windowedData = DCMWindowingProcessor.applyWindowLevel(
            pixels16: pixels16,
            center: optimal.center,
            width: optimal.width
        ) else {
            throw DICOMError.imageProcessingFailed(
                operation: "Window/Level",
                reason: "Failed to apply window/level transformation"
            )
        }

        // Get quality metrics
        let metrics = DCMWindowingProcessor.calculateQualityMetrics(
            pixels16: pixels16
        )

        return ProcessedImage(
            imageData: windowedData,
            width: decoder.width,
            height: decoder.height,
            patientInfo: patientInfo,
            studyInfo: studyInfo,
            seriesInfo: seriesInfo,
            suggestedPresets: suggestedPresets,
            currentWindow: optimal,
            qualityMetrics: metrics
        )
    }
}

struct ProcessedImage {
    let imageData: Data
    let width: Int
    let height: Int
    let patientInfo: [String: String]
    let studyInfo: [String: String]
    let seriesInfo: [String: String]
    let suggestedPresets: [MedicalPreset]
    let currentWindow: (center: Double, width: Double)
    let qualityMetrics: [String: Double]
}
```

---

For more information, see the main [README.md](README.md) and inline code documentation.
