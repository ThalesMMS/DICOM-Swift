# DICOM Glossary

A reference guide to DICOM terms and concepts to clarify medical and technical terminology.

## Contents

- [General Terms](#general-terms)
- [Data Structure](#data-structure)
- [Images and Pixels](#images-and-pixels)
- [Modalities](#modalities)
- [Window/Level](#windowlevel)
- [Clinical Terms](#clinical-terms)
- [Technical Terms](#technical-terms)

---

## General Terms

### DICOM
**Digital Imaging and Communications in Medicine**

International standard for storing and transmitting medical images. Defines both the file format and communication protocols.

### SOP (Service-Object Pair)
Combination of a DICOM service (store, print, etc.) with an object (such as a CT image). It defines which service operates on which object.

### UID (Unique Identifier)
Unique number identifying each study, series, or image. Format: `1.2.840.10008.xxx.xxx`

Example:
```swift
let studyUID = decoder.info(for: .studyInstanceUID)
// "1.2.840.113619.2.55.3.2831868264.123.1234567890.1"
```

Types of UID:
- **Study Instance UID** - identifies an exam
- **Series Instance UID** - identifies a related group of images
- **SOP Instance UID** - identifies a specific image

---

## Data Structure

### DICOM Tag
Numeric identifier for each metadata field.

Format: `(GGGG,EEEE)` where:
- `GGGG` = Group
- `EEEE` = Element

Example:
```
(0010,0010) = Patient Name
(0008,0060) = Modality
```

In code:
```swift
// Recommended: Type-safe DicomTag enum
let name = decoder.info(for: .patientName)

// Legacy: raw hex (for custom/private tags)
let name = decoder.info(for: 0x00100010)
```

### VR (Value Representation)
Defines the data type of a DICOM element.

| VR | Name             | Description               | Example    |
|----|------------------|---------------------------|------------|
| PN | Person Name      | Person name               | "Doe^John" |
| DA | Date             | Date (YYYYMMDD)           | "20240101" |
| TM | Time             | Time (HHMMSS)             | "143025"   |
| UI | UID              | Unique identifier         | "1.2.840..." |
| US | Unsigned Short   | 16-bit integer            | 512        |
| DS | Decimal String   | Decimal number            | "1.5"      |
| CS | Code String      | Short code                | "CT"       |
| LO | Long String      | Longer text               | "Head CT"  |

### Transfer Syntax
Defines how DICOM data is encoded (endianness, compression).

Supported by the decoder:
- Little Endian Implicit VR (default)
- Little Endian Explicit VR
- Big Endian Explicit VR
- JPEG Lossless (Process 14, Selection Value 1) - native decoder
- JPEG Baseline (ImageIO)
- JPEG 2000 (ImageIO)

Not supported:
- JPEG Lossless processes other than Process 14, Selection Value 1
- RLE

To detect in code:
```swift
if decoder.compressedImage {
    print("Compressed image detected")
}
```

---

## Images and Pixels

### Pixel Data
Tag `(7FE0,0010)` - contains the raw pixel values of the image.

Formats:
- 8-bit grayscale (0-255)
- 16-bit grayscale (0-65535)
- 24-bit RGB (color)

```swift
if decoder.bitDepth == 16 {
    let pixels = decoder.getPixels16()
} else if decoder.bitDepth == 8 {
    let pixels = decoder.getPixels8()
}

if decoder.samplesPerPixel == 3 {
    let pixels = decoder.getPixels24()
}
```

### Bits Allocated vs Bits Stored
- **Bits Allocated**: Space reserved per pixel (often 8 or 16).
- **Bits Stored**: Bits actually used (may be fewer).

Example:
```
Bits Allocated: 16
Bits Stored: 12
High Bit: 11
```
Meaning: pixels occupy 16 bits, but only 12 bits carry data.

### Photometric Interpretation
Describes how to interpret pixel values.

| Value        | Meaning                           |
|--------------|-----------------------------------|
| MONOCHROME1  | 0 = white, max = black (X-ray)    |
| MONOCHROME2  | 0 = black, max = white (default)  |
| RGB          | RGB color                         |
| PALETTE COLOR| Color lookup table                |

```swift
let photoInterp = decoder.photometricInterpretation

if photoInterp == "MONOCHROME1" {
    // Invert values if you read raw pixels
}
```

### Pixel Spacing
Physical distance between pixels in millimeters.

```swift
let spacing = decoder.pixelSpacingV2
print("Pixel: \(spacing.x) x \(spacing.y) mm")
print("Slice thickness: \(spacing.z) mm")

let widthMM = Double(decoder.width) * spacing.x
print("Physical width: \(widthMM) mm")
```

---

## Window/Level

### Window Center (Level)
Tag `(0028,1050)` - central value of the display window. Controls brightness.

### Window Width
Tag `(0028,1051)` - width of the display window. Controls contrast.

```
Narrow window (high contrast) vs. wide window (low contrast)
```

### Preset Windows
Common window/level settings for different tissues.

Examples for CT:

```swift
let lung = DCMWindowingProcessor.getPresetValues(preset: .lung)
// Center: -600 HU, Width: 1500 HU

let bone = DCMWindowingProcessor.getPresetValues(preset: .bone)
// Center: 400 HU, Width: 1800 HU

let brain = DCMWindowingProcessor.getPresetValues(preset: .brain)
// Center: 40 HU, Width: 80 HU
```

### Hounsfield Unit (HU)
Density scale used in CT. Water = 0 HU.

| Tissue/Material | HU Range        |
|-----------------|-----------------|
| Air             | -1000           |
| Lung            | -500 to -700    |
| Fat             | -100 to -50     |
| Water           | 0               |
| Blood           | +30 to +45      |
| Muscle          | +10 to +40      |
| Liver           | +40 to +60      |
| Trabecular bone | +300 to +400    |
| Dense bone      | +700 to +3000   |
| Metals          | > +3000         |

Pixel to HU conversion:
```swift
let hu = decoder.applyRescale(to: pixelValue)
// HU = slope x pixel + intercept
```

---

## Modalities

### CT (Computed Tomography)
Rotational X-ray creating cross-sectional images.

Characteristics:
- 16-bit grayscale
- Values in HU
- Multiple series (contrast phases)

Useful presets: lung, bone, brain, liver, abdomen.

### MR (Magnetic Resonance)
Magnetic fields for soft-tissue imaging.

Characteristics:
- Strong soft-tissue contrast
- Multiple sequences (T1, T2, FLAIR, etc.)
- No ionizing radiation
- Does not use Hounsfield Units

### CR/DX (Computed/Digital Radiography)
Digital X-ray.

Characteristics:
- Often MONOCHROME1
- 2D
- High resolution

### US (Ultrasound)
Sound-based imaging.

Characteristics:
- Often color (RGB)
- Frequently multi-frame
- Doppler for blood flow

### MG (Mammography)
Specialized X-ray for breast tissue. High resolution; often MONOCHROME1.

---

## Clinical Terms

### Patient Demographics
Identifying patient information.

```swift
let info = decoder.getPatientInfo()
// ["Name": "Doe^John", "ID": "12345", "Sex": "M", "Age": "045Y"]
```

Key tags:
- `(0010,0010)` - Patient Name
- `(0010,0020)` - Patient ID
- `(0010,0030)` - Birth Date
- `(0010,0040)` - Sex (M/F/O)

### Study
A full medical exam that can contain multiple series.

Example: "CT Chest with Contrast"
- Series 1: Non-contrast
- Series 2: Arterial phase
- Series 3: Venous phase
- Series 4: Reconstructions

```swift
let study = decoder.getStudyInfo()
```

### Series
Related images within a study.

Example: "Axial T1 Series"

```swift
let series = decoder.getSeriesInfo()
print(series["SeriesNumber"] ?? "")
```

### Instance
A single DICOM image.

Hierarchy:
```
Study
  `-- Series 1
      |-- Instance 1
      |-- Instance 2
      `-- Instance 3
  `-- Series 2
      |-- Instance 1
      `-- Instance 2
```

---

## Technical Terms

### Endianness
Byte order in multi-byte values.

- Little Endian: least significant byte first
- Big Endian: most significant byte first

The decoder handles both.

### Implicit vs Explicit VR
- Explicit VR: VR is specified for each tag.
- Implicit VR: VR is inferred from the tag dictionary.

The decoder detects both automatically.

### Multi-frame Image
A DICOM file with multiple frames (similar to a short video).

```swift
if decoder.isMultiFrame {
    print("Frames: \(decoder.nImages)")
}
```

Common in ultrasound, angiography, and some dynamic CT studies.

### Rescale Slope/Intercept
Formula for converting pixel values to clinical units.

```
Real Value = (Pixel x Slope) + Intercept
```

For CT (HU):
```swift
let params = decoder.rescaleParametersV2
let hu = params.apply(to: pixelValue)
```

### Overlay
Graphics drawn over the image (annotations, measurements). Not processed by this decoder.

### PACS (Picture Archiving and Communication System)
Hospital system for storing and distributing DICOM images.

### WADO (Web Access to DICOM Objects)
Protocol for accessing DICOM images over HTTP.

---

## Quick Tag Reference

Common tags (DicomTag enum and hex):

```swift
// Patient
.patientName       // 0x00100010 - Name
.patientID         // 0x00100020 - ID
.patientBirthDate  // 0x00100030 - Birth Date
.patientSex        // 0x00100040 - Sex

// Study
.studyInstanceUID  // 0x0020000D - Study Instance UID
.studyDate         // 0x00080020 - Study Date
.studyTime         // 0x00080030 - Study Time
.studyDescription  // 0x00081030 - Study Description

// Series
.seriesInstanceUID // 0x0020000E - Series Instance UID
.seriesNumber      // 0x00200011 - Series Number
.seriesDescription // 0x0008103E - Series Description
.modality          // 0x00080060 - Modality

// Image
.rows              // 0x00280010 - Rows
.columns           // 0x00280011 - Columns
.bitsAllocated     // 0x00280100 - Bits Allocated
.pixelRepresentation // 0x00280103 - Pixel Representation
.windowCenter      // 0x00281050 - Window Center
.windowWidth       // 0x00281051 - Window Width
.pixelData         // 0x7FE00010 - Pixel Data
```

---

## Additional Resources

- **[Innolitics DICOM Browser](https://dicom.innolitics.com/)** - browse DICOM tags
- **[DICOM Standard](https://www.dicomstandard.org/)** - official specification
- **[RadioGraphics](https://pubs.rsna.org/radiographics)** - articles on medical imaging

---

Previous: [Getting Started](GETTING_STARTED.md) | Next: [Usage Examples](USAGE_EXAMPLES.md)
