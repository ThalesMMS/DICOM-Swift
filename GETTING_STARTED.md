# Quick Start Guide - DICOM-Swift

Welcome to DICOM-Swift. This guide helps you start working with DICOM files in Swift.

## Contents

1. [What is DICOM?](#what-is-dicom)
2. [Prerequisites](#prerequisites)
3. [Installation](#installation)
4. [Your First Program](#your-first-program)
5. [Fundamental Concepts](#fundamental-concepts)
6. [Next Steps](#next-steps)

---

## What is DICOM?

**DICOM** (Digital Imaging and Communications in Medicine) is the international standard for storing and transmitting medical images. Common sources include:

- CT scanners
- MRI
- Digital X-ray
- Ultrasound
- Mammography

A DICOM file (`.dcm`) contains:
- Pixel data (the image itself)
- Metadata (patient name, exam date, scanner settings, and more)

---

## Prerequisites

Before you start, ensure you have:

- Xcode 26.0+
- Swift 6.2+ toolchain. DICOM-Swift targets compile in Swift 6 language mode, which enables complete
  strict-concurrency checking; consuming targets retain their own language-mode setting.
- macOS 26+ or iOS 26+
- Basic Swift knowledge
- At least one DICOM file to test (`.dcm`)

### Where to Get Sample DICOM Files

- Public datasets such as [TCIA](https://www.cancerimagingarchive.net/)
- [DICOM Sample Images](https://www.dicomlibrary.com/)

---

## Installation

### Step 1: Add the Package to Your Project

#### Using Xcode

1. Open your project in Xcode.
2. Go to **File -> Add Packages...**
3. Enter the repository URL:
   ```
   https://github.com/ThalesMMS/DICOM-Swift.git
   ```
4. Select version `1.0.0` or later.
5. Click **Add Package**.

#### Using Package.swift

Add to `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ThalesMMS/DICOM-Swift.git", exact: "2.0.0-rc.2")
]
```

And in your target:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "DicomCore", package: "DICOM-Swift")
    ]
)
```

### Step 2: Import the Module

In any Swift file where you want to use the decoder:

```swift
import DicomCore
```

---

## Your First Program

Create a simple program that reads a DICOM file and prints basic information.

### Example 1: Basic Reading (Synchronous)

```swift
import DicomCore

func readDICOMFile() {
    do {
        let decoder = try DCMDecoder(contentsOfFile: "/path/to/your/file.dcm")

        print("DICOM file loaded")
        print("Dimensions: \(decoder.width) x \(decoder.height) pixels")
        print("Bit depth: \(decoder.bitDepth) bits")
        print("Modality: \(decoder.info(for: .modality))")
        print("Patient Name: \(decoder.info(for: .patientName))")
    } catch {
        print("Error loading DICOM file: \(error)")
    }
}

readDICOMFile()
```

Expected output:
```
DICOM file loaded
Dimensions: 512 x 512 pixels
Bit depth: 16 bits
Modality: CT
Patient Name: John Doe
```

### Example 2: Async Reading

Use the asynchronous API to keep file loading off the caller's thread:

```swift
import DicomCore

func readDICOMAsync() async {
    do {
        let decoder = try await DCMDecoder(contentsOfFile: "/path/to/your/file.dcm")

        print("File loaded")
        print("Dimensions: \(decoder.width) x \(decoder.height)")
    } catch {
        print("Error loading file: \(error)")
    }
}

Task {
    await readDICOMAsync()
}
```

### Example 3: Validate Before Loading

Validate the file before loading it fully.

```swift
import DicomCore

func validateAndLoad(path: String) {
    let decoder = DCMDecoder()

    let validation = decoder.validateDICOMFile(path)

    if !validation.isValid {
        print("Invalid file:")
        for issue in validation.issues {
            print("  - \(issue)")
        }
        return
    }

    print("Valid file. Loading...")
    do {
        let decoder = try DCMDecoder(contentsOfFile: path)

        let status = decoder.getValidationStatus()
        print("Status:")
        print("  - Valid: \(status.isValid)")
        print("  - Dimensions: \(status.width) x \(status.height)")
        print("  - Contains pixels: \(status.hasPixels)")
        print("  - Compressed: \(status.isCompressed)")
    } catch {
        print("Error loading file: \(error)")
    }
}
```

---

## Fundamental Concepts

### 1. DICOM File Structure

```
+-----------------------------+
|  Preamble (128 bytes)       |
+-----------------------------+
|  "DICM" (4 bytes)           | <- DICOM signature
+-----------------------------+
|  Meta Information           | <- File information
+-----------------------------+
|  Dataset (Tags)             | <- Medical metadata
|  - Patient Info             |
|  - Study Info               |
|  - Series Info              |
|  - Image Info               |
+-----------------------------+
|  Pixel Data                 | <- Image pixels
+-----------------------------+
```

### 2. DICOM Tags

Tags are numeric identifiers for each metadata field. Format: `(GGGG,EEEE)`

Common examples:

| Tag        | DicomTag Enum    | Description            |
|------------|------------------|------------------------|
| (0010,0010)| `.patientName`   | Patient Name           |
| (0010,0020)| `.patientID`     | Patient ID             |
| (0008,0060)| `.modality`      | Modality (CT, MR, ...) |
| (0020,000D)| `.studyInstanceUID` | Study Instance UID  |
| (0028,0010)| `.rows`          | Rows (height)          |
| (0028,0011)| `.columns`       | Columns (width)        |

Using tags in code:

```swift
// Recommended: Type-safe DicomTag enum
let name = decoder.info(for: .patientName)
let patient = decoder.getPatientInfo()
print(patient["Name"] ?? "Unknown")

if let height = decoder.intValue(for: .rows) {
    print("Height: \(height) pixels")
}
```

### 3. Window/Level

Window/Level controls brightness and contrast of DICOM images.

- Level (Center): controls brightness
- Width: controls contrast

```
Pixels below window      Pixels inside window       Pixels above window
    (black)                    (grayscale)              (white)
       v                            v                       v
   ===========================================================
              ^                                        ^
       Level - Width/2                          Level + Width/2
```

Practical example:

```swift
guard let pixels16 = decoder.getPixels16() else {
    print("No pixel data")
    return
}

let lung = DCMWindowingProcessor.getPresetValues(preset: .lung)
let lungImage = DCMWindowingProcessor.applyWindowLevel(
    pixels16: pixels16,
    center: lung.center,
    width: lung.width
)

if let optimal = decoder.calculateOptimalWindow() {
    let optimizedImage = DCMWindowingProcessor.applyWindowLevel(
        pixels16: pixels16,
        center: optimal.center,
        width: optimal.width
    )
}
```

### 4. Medical Modalities

Supported modalities and notes:

| Code | Name                  | Description                       |
|------|-----------------------|-----------------------------------|
| CT   | Computed Tomography   | Cross-sectional images            |
| MR   | Magnetic Resonance    | Soft tissue imaging               |
| CR   | Computed Radiography  | Digital X-ray                     |
| DX   | Digital X-Ray         | Digital X-ray                     |
| US   | Ultrasound            | Often color and multi-frame       |
| MG   | Mammography           | High-resolution breast imaging    |
| PT   | PET Scan              | Positron emission tomography      |

Example:

```swift
let modality = decoder.info(for: .modality)

switch modality {
case "CT":
    print("Computed Tomography")
case "MR":
    print("Magnetic Resonance")
case "CR", "DX":
    print("Digital X-ray")
case "US":
    print("Ultrasound")
default:
    print("Modality: \(modality)")
}
```

### 5. Hounsfield Units (for CT)

In CT, pixel values represent density in Hounsfield Units (HU):

| Material         | Typical HU    |
|------------------|---------------|
| Air              | -1000         |
| Lung             | -500 to -700  |
| Fat              | -100 to -50   |
| Water            | 0             |
| Blood            | +30 to +45    |
| Muscle           | +10 to +40    |
| Soft Tissue      | +100 to +300  |
| Bone             | +700 to +3000 |

Convert pixels to HU:

```swift
let pixelValue: Double = 1024.0
let hu = decoder.applyRescale(to: pixelValue)
print("Pixel \(pixelValue) = \(hu) HU")

if hu < -500 {
    print("Likely air or lung")
} else if hu > 700 {
    print("Likely bone")
}
```

---

## Next Steps

Explore additional materials:

### Tutorials and Samples

1. **[Complete Usage Examples](USAGE_EXAMPLES.md)**
   - Batch processing
   - Thumbnail generation
   - Image quality analysis
3. **[DICOM Glossary](DICOM_GLOSSARY.md)**
   - Definitions of technical terms

### Helpful References

- **[Troubleshooting](TROUBLESHOOTING.md)** - fixes for common issues
- **API Reference** - generate DocC locally with `swift package generate-documentation --target DicomCore`
- **[Project Architecture](README.md#architecture)** - code organization

### External Resources

- [DICOM Standard](https://www.dicomstandard.org/) - official specification
- [Innolitics DICOM Browser](https://dicom.innolitics.com/) - browse tags
