# Troubleshooting Guide

Solutions for common issues when using the DICOM Decoder.

## Contents

- [Installation Issues](#installation-issues)
- [File Loading Issues](#file-loading-issues)
- [Image Issues](#image-issues)
- [Performance Issues](#performance-issues)
- [Metadata Issues](#metadata-issues)
- [Common Errors](#common-errors)

---

## Installation Issues

### Error: "No such module 'DicomCore'"

Cause: The package was not added correctly to the project.

Solution:

1. Confirm the package is added in **File -> Add Packages**.
2. Ensure `DicomCore` appears in **Target Dependencies**.
3. Clean the build folder (**Product -> Clean Build Folder**, Shift+Command+K).
4. Reopen the project.

```swift
import DicomCore  // Correct
import DICOM-Swift  // Incorrect
```

### Error: Swift tools version mismatch

Symptom: SwiftPM reports that the package manifest requires Swift tools 6.2 or later.

Solution:

1. Update Xcode to version 26.0 or later.
2. Check Swift version:
   ```bash
   swift --version
   ```
3. Confirm the toolchain supports Swift tools 6.2. The package manifest compiles DICOM-Swift targets in Swift 6
   language mode; it does not change the consuming target's language mode.

---

## File Loading Issues

### Error: "Failed to load DICOM file"

Diagnostics:

```swift
do {
    let decoder = try DCMDecoder(contentsOfFile: path)
    // File loaded successfully
} catch {
    print("Error: \(error)")

    let tempDecoder = DCMDecoder()
    let validation = tempDecoder.validateDICOMFile(path)
    print("Valid: \(validation.isValid)")
    print("Issues:")
    for issue in validation.issues {
        print("  - \(issue)")
    }
}
```

#### Problem 1: "File does not exist"

Cause: Invalid path or missing file.

Solutions:

```swift
// Use absolute paths
let decoder = try DCMDecoder(contentsOfFile: "/Users/name/Documents/file.dcm")

// Build from a bundle
if let path = Bundle.main.path(forResource: "example", ofType: "dcm") {
    let decoder = try DCMDecoder(contentsOfFile: path)
}

// Using URL
let url = URL(fileURLWithPath: "/path/file.dcm")
let decoder = try DCMDecoder(contentsOf: url)
```

#### Problem 2: "Missing DICOM header signature"

Cause: The file is not valid DICOM or is corrupted.

Solutions:

1. Check the file with a DICOM tool (e.g., `dcmdump file.dcm` if dicom-swift is installed).
2. Open the file in a DICOM viewer to confirm it is valid.
3. Verify the extension (`.dcm`, `.dicom`, `.ima`).
4. Some DICOM files omit the standard prefix; consider a more permissive parser if needed.

#### Problem 3: "File too small to be valid DICOM"

Cause: File is under 132 bytes.

Solutions:

- Verify the file was fully downloaded or copied.
- Re-download if corruption is suspected.
- Check read permissions.

### Error: Compressed file not supported

Message: No image loads and `compressedImage = true`.

Cause: The file uses a compressed transfer syntax (JPEG, JPEG2000, RLE).

Diagnostics:

```swift
let decoder = try DCMDecoder(contentsOfFile: path)

if decoder.compressedImage {
    print("Compressed transfer syntax detected")
    print("UID: \(decoder.info(for: .transferSyntaxUID))")
}
```

Solutions:

**Option 1:** Convert to an uncompressed format

```bash
# Using dicom-swift
dcmconv --write-xfer-little compressed.dcm uncompressed.dcm
```

**Option 2:** Use built-in JPEG decoding (ImageIO)

```swift
let decoder = try DCMDecoder(contentsOfFile: path)
if let pixels = decoder.getPixels8() ?? decoder.getPixels16() {
    print("JPEG decoding succeeded")
}
```

Supported transfer syntaxes:
- Little Endian Implicit VR
- Little Endian Explicit VR
- Big Endian Explicit VR
- JPEG Lossless (Process 14, Selection Value 1) - native decoder
- JPEG Baseline (via ImageIO)
- JPEG 2000 (via ImageIO)

Not supported:
- JPEG Lossless processes other than Process 14, Selection Value 1
- RLE

---

## Image Issues

### Pixels return `nil`

Diagnostics:

```swift
let status = decoder.getValidationStatus()
print("Has pixels: \(status.hasPixels)")
print("Width: \(status.width), Height: \(status.height)")
print("Samples/Pixel: \(decoder.samplesPerPixel)")
print("Bit Depth: \(decoder.bitDepth)")
```

Problem 1: Wrong pixel type requested

Cause: Requesting 16-bit pixels when the image is 8-bit or RGB.

Solution:

```swift
if decoder.samplesPerPixel == 1 {
    if decoder.bitDepth == 8 {
        let pixels = decoder.getPixels8()
    } else if decoder.bitDepth == 16 {
        let pixels = decoder.getPixels16()
    }
} else if decoder.samplesPerPixel == 3 {
    let pixels = decoder.getPixels24()
}

if decoder.isGrayscale {
    let pixels = decoder.bitDepth == 16
        ? decoder.getPixels16()
        : decoder.getPixels8()
}
```

Problem 2: File has no pixel data

Cause: DICOMDIR or metadata-only file.

Solution:

```swift
if decoder.info(for: 0x00041220).isEmpty == false {
    print("This is a DICOMDIR (index), it does not contain pixels")
}
```

### Image appears all black or white

Cause: Incorrect window/level.

Diagnostics:

```swift
let window = decoder.windowSettings
print("Center: \(window.center), Width: \(window.width)")

if window.center == 0 && window.width == 0 {
    print("No default window defined")
}
```

Solutions:

- Calculate an optimal window automatically:

```swift
if let optimal = decoder.calculateOptimalWindow(),
   let image = DCMWindowingProcessor.applyWindowLevel(
        pixels16: pixels16!,
        center: optimal.center,
        width: optimal.width
   ) {
    // Use image
}
```

- Use an appropriate preset:

```swift
let preset = DCMWindowingProcessor.getPresetValues(preset: .lung)
let image = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16!,
    center: preset.center,
    width: preset.width
)
```

- Suggest presets automatically:

```swift
let modality = decoder.info(for: .modality)
let bodyPart = decoder.info(for: .bodyPartExamined)

let suggestions = DCMWindowingProcessor.suggestPresets(
    for: modality,
    bodyPart: bodyPart
)

if let first = suggestions.first {
    let preset = DCMWindowingProcessor.getPresetValues(preset: first)
    // Apply preset...
}
```

### Image inverted (black/white swapped)

Cause: `MONOCHROME1` where 0 = white.

Solution: The decoder inverts this automatically. If reading raw pixels, invert manually:

```swift
let photoInterp = decoder.photometricInterpretation

if photoInterp == "MONOCHROME1" {
    pixels = pixels.map { 65535 - $0 }  // For 16-bit
}
```

---

## Performance Issues

### Slow loading of large files

Cause: Files larger than 100MB can be slow.

Solutions:

- Use async/await to avoid blocking the UI:

```swift
Task {
    let decoder = try await DCMDecoder(contentsOfFile: path)
}
```

- Use thumbnails first:

```swift
if let thumb = decoder.getDownsampledPixels16(maxDimension: 150) {
    showThumbnail(thumb.pixels, thumb.width, thumb.height)
}

Task {
    if let pixels = await decoder.getPixels16Async() {
        showFullImage(pixels)
    }
}
```

- Monitor performance:

```swift
let start = Date()
let decoder = try DCMDecoder(contentsOfFile: path)
let elapsed = Date().timeIntervalSince(start)
print("Load time: \(elapsed)s")
```

### Slow window/level

Cause: Processing large pixel arrays.

Solution: Use automatic backend selection:

```swift
let windowed = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: 40.0,
    width: 80.0,
    processingMode: .auto
)
```

---

## Metadata Issues

### Tag returns an empty string

Diagnostics:

```swift
let value = decoder.info(for: .patientName)
if value.isEmpty {
    let allTags = decoder.getAllTags()
    print("Available tags: \(allTags.count)")

    for (tag, value) in allTags where tag.hasPrefix("0010") {
        print("\(tag): \(value)")
    }
}
```

Solutions:

1. Check if the tag exists:
```swift
let all = decoder.getAllTags()
let tagHex = String(format: "%08X", 0x00100010)
if let value = all[tagHex] {
    print("Tag exists: \(value)")
} else {
    print("Tag not found in the file")
}
```

2. Use convenience methods with defaults:
```swift
let info = decoder.getPatientInfo()
let name = info["Name"] ?? "Unknown"
```

### Date/Time values look unusual

Cause: DICOM uses specific formats (YYYYMMDD, HHMMSS).

Solution: Parse correctly.

```swift
let dateString = decoder.info(for: .studyDate)  // "20240115"

let formatter = DateFormatter()
formatter.dateFormat = "yyyyMMdd"
let date = formatter.date(from: dateString)

let timeString = decoder.info(for: .studyTime)  // "143025.123456"
formatter.dateFormat = "HHmmss.SSSSSS"
let time = formatter.date(from: timeString)
```

---

## Common Errors

### Thread Sanitizer warnings

Cause: Shared mutable decoder state, custom decoder implementations, or legacy code paths that bypass the public synchronized API.

Solution: Use the public `DCMDecoder` API, which synchronizes instance state internally. For batch work, prefer factory-based services that create a decoder per file.

```swift
// Preferred: use isolated decoder instances in concurrent work
await withTaskGroup(of: Void.self) { group in
    for file in files {
        group.addTask {
            let decoder = try await DCMDecoder(contentsOfFile: file)
            process(decoder)
        }
    }
}
```

### Memory warnings when loading many files

Cause: Many decoders loaded simultaneously.

Solution:

```swift
// Wrong: holding all decoders in memory
var decoders: [DCMDecoder] = []
for file in files {
    let decoder = try DCMDecoder(contentsOfFile: file)
    decoders.append(decoder)  // Holds everything in memory
}

// Correct: process and release each decoder
for file in files {
    autoreleasepool {
        let decoder = try DCMDecoder(contentsOfFile: file)
        process(decoder)
    }
}

// Or extract only metadata
for file in files {
    let decoder = try DCMDecoder(contentsOfFile: file)
    let metadata = decoder.getStudyInfo()
    saveMetadata(metadata)
}
```

### Crash when accessing pixels before loading

Cause: Trying to access pixels without loading a file first.

Solution: Use throwing initializers, which guarantee the file is loaded on success.

```swift
do {
    let decoder = try DCMDecoder(contentsOfFile: path)

    guard let pixels = decoder.getPixels16() else {
        print("No pixel data")
        return
    }

    process(pixels)
} catch {
    print("Load error: \(error)")
}
```

---

## Still Need Help?

1. Enable detailed logs:
```swift
// The decoder prints performance and error logs.
// Look for lines with [DCMDecoder] or [PERF].
```

2. Create a minimal example:
```swift
do {
    let decoder = try DCMDecoder(contentsOfFile: "your_file.dcm")
    print("Width: \(decoder.width), Height: \(decoder.height)")
    print("Modality: \(decoder.info(for: .modality))")
} catch {
    print("Error: \(error)")
}
```

3. Inspect the file with external tools:
```bash
dcmdump file.dcm

pip install pydicom
python -c "import pydicom; print(pydicom.dcmread('file.dcm'))"
```

4. Open a GitHub Issue:
   - Include the decoder version.
   - Provide a minimal code sample.
   - Include `dcmdump` output (without sensitive data).
   - Describe expected vs. current behavior.

---

Previous: [DICOM Glossary](DICOM_GLOSSARY.md) | Next: [README Documentation Section](README.md#documentation)
