# JPEG Lossless Algorithm Documentation

## Overview

JPEG Lossless is a lossless compression method defined in ITU-T T.81 (ISO/IEC 10918-1) that uses predictive coding and Huffman entropy coding. In DICOM, it appears as two transfer syntaxes:

- **1.2.840.10008.1.2.4.57**: JPEG Lossless, Non-Hierarchical (Process 14)
- **1.2.840.10008.1.2.4.70**: JPEG Lossless, Non-Hierarchical, First-Order Prediction (Process 14, Selection Value 1)

This document describes the decoding algorithm required to implement these transfer syntaxes.

## Key Concepts

### Predictive Coding

JPEG Lossless uses spatial prediction to exploit pixel correlation:

1. **Predictor**: A function that estimates the current pixel value based on previously decoded neighbors
2. **Prediction error**: The difference between predicted and actual values (encoded in bitstream)
3. **Reconstruction**: Add prediction error to predictor output to recover original pixel

### Selection Value

The **selection value** (Ss field in Start of Scan marker) determines which predictor to use:

| Selection | Predictor Formula | Description |
|-----------|-------------------|-------------|
| 0 | No prediction | Raw pixel values (rarely used) |
| 1 | Ra | Left neighbor |
| 2 | Rb | Top neighbor |
| 3 | Rc | Top-left neighbor |
| 4 | Ra + Rb - Rc | Planar predictor |
| 5 | Ra + ((Rb - Rc) >> 1) | Left + half vertical gradient |
| 6 | Rb + ((Ra - Rc) >> 1) | Top + half horizontal gradient |
| 7 | (Ra + Rb) / 2 | Average of left and top |

Where:
- **Ra**: Pixel to the left (x-1, y)
- **Rb**: Pixel above (x, y-1)
- **Rc**: Pixel at top-left diagonal (x-1, y-1)
- **X**: Current pixel being decoded

```
    Rc | Rb
    ---+---
    Ra | X
```

**DICOM Transfer Syntax 1.2.840.10008.1.2.4.70** mandates **Selection Value 1** (left neighbor predictor).

## JPEG Bitstream Structure

### Marker Overview

JPEG uses **markers** (2-byte codes starting with 0xFF) to structure the bitstream:

```
0xFFD8  Start of Image (SOI)
0xFFC4  Define Huffman Table (DHT)
0xFFC3  Start of Frame - Lossless (SOF3)
0xFFDA  Start of Scan (SOS)
        [Compressed image data]
0xFFD9  End of Image (EOI)
```

### Marker Parsing Strategy

1. **Read 2 bytes**: Check if it equals 0xFFxx
2. **Verify marker**: 0xFF followed by non-zero byte (0x00 is byte stuffing, not a marker)
3. **Read length**: Next 2 bytes (big-endian) include themselves in count
4. **Parse payload**: Length - 2 bytes of marker-specific data
5. **Repeat**: Continue until SOI (0xFFD8) found, then process markers sequentially

**Byte Stuffing Rule**: Any 0xFF byte in entropy-coded data is followed by 0x00. When reading compressed data:
- If you see 0xFF 0x00 → decode as single 0xFF byte
- If you see 0xFF 0xXX (XX != 0x00) → this is a marker, stop reading compressed data

## 1. JPEG Marker Parsing

### Start of Frame (SOF3 - 0xFFC3)

**Structure:**
```
Offset  Size  Field                 Description
------  ----  --------------------  -----------
0       2     Lf (Length)           Frame header length (big-endian)
2       1     P (Precision)         Sample precision in bits (8, 12, 16)
3       2     Y (Height)            Image height in pixels (big-endian)
5       2     X (Width)             Image width in pixels (big-endian)
7       1     Nf (# Components)     Number of image components (1 for grayscale)
8       3×Nf  Component specs       For each component:
                                      - 1 byte: Component ID
                                      - 1 byte: Sampling factors (H:V)
                                      - 1 byte: Quantization table selector
```

**Parsing Logic:**
```swift
func parseSOF3(data: Data, offset: Int) -> SOF3Result {
    let length = UInt16(data[offset]) << 8 | UInt16(data[offset+1])
    let precision = data[offset+2]  // Bits per sample
    let height = UInt16(data[offset+3]) << 8 | UInt16(data[offset+4])
    let width = UInt16(data[offset+5]) << 8 | UInt16(data[offset+6])
    let numComponents = data[offset+7]

    var components: [ComponentSpec] = []
    var pos = offset + 8
    for _ in 0..<numComponents {
        let id = data[pos]
        let samplingFactors = data[pos+1]  // High nibble: H, Low nibble: V
        let quantTableSelector = data[pos+2]
        components.append(ComponentSpec(id: id, h: samplingFactors >> 4,
                                        v: samplingFactors & 0x0F,
                                        qtable: quantTableSelector))
        pos += 3
    }

    return SOF3Result(width: Int(width), height: Int(height),
                      precision: Int(precision), components: components)
}
```

### Define Huffman Table (DHT - 0xFFC4)

**Structure:**
```
Offset  Size  Field                 Description
------  ----  --------------------  -----------
0       2     Lh (Length)           Huffman table length (big-endian)
2       1     Th/Tc                 High nibble: table class (0=DC, 1=AC)
                                    Low nibble: table ID (0-3)
3       16    Li (Symbol counts)    # symbols of length 1-16 bits
19      Σ Li  Vi (Symbol values)    Huffman symbol values
```

**Critical Detail**: JPEG Lossless uses **DC Huffman tables** (table class 0) even though there's no DC/AC distinction in lossless mode. The Huffman codes encode the **bit length** of the prediction error, not the error itself.

### Start of Scan (SOS - 0xFFDA)

**Structure:**
```
Offset  Size  Field                 Description
------  ----  --------------------  -----------
0       2     Ls (Length)           Scan header length (big-endian)
2       1     Ns (# Components)     Number of components in scan
3       2×Ns  Component selectors   For each component:
                                      - 1 byte: Component selector
                                      - 1 byte: DC/AC entropy table selectors
3+2×Ns  1     Ss (Start spectral)   Selection value (predictor ID)
4+2×Ns  1     Se (End spectral)     Must be 0 for lossless
5+2×Ns  1     Ah/Al                 Successive approximation (must be 0)
```

**Parsing Logic:**
```swift
func parseSOS(data: Data, offset: Int) -> SOSResult {
    let length = UInt16(data[offset]) << 8 | UInt16(data[offset+1])
    let numComponents = data[offset+2]

    var pos = offset + 3
    var componentSelectors: [ComponentSelector] = []
    for _ in 0..<numComponents {
        let id = data[pos]
        let entropySelectors = data[pos+1]
        componentSelectors.append(ComponentSelector(
            id: id,
            dcTable: entropySelectors >> 4,
            acTable: entropySelectors & 0x0F
        ))
        pos += 2
    }

    let selectionValue = data[pos]      // Predictor ID
    let endSpectral = data[pos+1]       // Must be 0
    let successiveApprox = data[pos+2]  // Must be 0

    return SOSResult(components: componentSelectors,
                     selectionValue: Int(selectionValue))
}
```

## 2. Huffman Table Decoding

### Huffman Code Construction

The DHT marker provides **symbol counts per bit length** (Li) and **symbol values** (Vi). We need to construct a decoding table.

**Algorithm** (from JPEG spec F.2.2.3):

```swift
struct HuffmanTable {
    var minCode: [Int]      // Minimum code for each length [1...16]
    var maxCode: [Int]      // Maximum code for each length [1...16]
    var valPtr: [Int]       // Index into huffval for each length [1...16]
    var huffval: [UInt8]    // Ordered symbol values
}

func buildHuffmanTable(bits: [UInt8], huffval: [UInt8]) -> HuffmanTable {
    var minCode = [Int](repeating: -1, count: 17)
    var maxCode = [Int](repeating: -1, count: 17)
    var valPtr = [Int](repeating: 0, count: 17)

    // Generate code sizes
    var huffsize: [Int] = []
    for length in 1...16 {
        for _ in 0..<bits[length-1] {
            huffsize.append(length)
        }
    }

    // Generate codes
    var huffcode: [Int] = []
    var code = 0
    var size = huffsize[0]

    for currentSize in huffsize {
        if currentSize > size {
            code <<= (currentSize - size)
            size = currentSize
        }
        huffcode.append(code)
        code += 1
    }

    // Build decoding tables
    var j = 0
    for length in 1...16 {
        if bits[length-1] != 0 {
            valPtr[length] = j
            minCode[length] = huffcode[j]
            j += Int(bits[length-1])
            maxCode[length] = huffcode[j - 1]
        }
    }

    return HuffmanTable(minCode: minCode, maxCode: maxCode,
                        valPtr: valPtr, huffval: huffval)
}
```

### Huffman Symbol Decoding

**Algorithm** (from JPEG spec F.2.2.4):

```swift
func decodeHuffmanSymbol(bitstream: inout BitInputStream,
                          table: HuffmanTable) throws -> UInt8 {
    var code = 0

    for length in 1...16 {
        code = (code << 1) | bitstream.readBit()

        if code <= table.maxCode[length] && table.maxCode[length] != -1 {
            let index = table.valPtr[length] + (code - table.minCode[length])
            return table.huffval[index]
        }
    }

    throw JPEGError.invalidHuffmanCode
}
```

**What the symbol means**: In JPEG Lossless, the decoded symbol represents the **bit length** of the prediction error difference that follows. If symbol is N:
- Read N additional bits from bitstream
- These N bits encode the signed prediction error
- Use special encoding for negative values (see next section)

## 3. Prediction and Reconstruction

### First-Order Predictor (Selection Value 1)

**Formula**: `Predictor = Ra` (left neighbor)

**Special Cases**:
- **First pixel of each row**: Predictor = 2^(P-1) where P is precision (e.g., 2^15 = 32768 for 16-bit)
- **First row, first column**: Predictor = 2^(P-1)

**Row-by-row processing**:
```
Row 0:  [32768 + Δ₀] [pixel₀ + Δ₁] [pixel₁ + Δ₂] ...
Row 1:  [32768 + Δₙ] [pixel₀ + Δₙ₊₁] ...
Row N:  [32768 + Δₘ] ...
```

### Prediction Error Decoding

After decoding Huffman symbol (gives bit length N):

1. **Read N bits** from bitstream
2. **Interpret as signed value** using JPEG's magnitude encoding:
3. For the lossless-only category `SSSS == 16`, read no extra bits and use the most-negative 16-bit difference value `-32768`.

```swift
func decodeDifference(ssss: Int, bitstream: inout BitInputStream) throws -> Int {
    if ssss == 0 {
        return 0  // No difference
    }

    if ssss == 16 {
        return -32768  // Lossless sentinel difference, no extra bits
    }

    // Read ssss bits
    var bits = 0
    for _ in 0..<ssss {
        bits = (bits << 1) | bitstream.readBit()
    }

    // Check sign bit (MSB)
    let halfRange = 1 << (ssss - 1)
    if bits < halfRange {
        // Negative value: compute using JPEG's magnitude encoding
        // Formula: value = bits - (2^ssss - 1)
        return bits - ((1 << ssss) - 1)
    } else {
        // Positive value
        return bits
    }
}
```

**Example** (ssss=4):
- Bits `1001` (9) → halfRange=8, 9≥8 → Positive: +9
- Bits `0110` (6) → halfRange=8, 6<8 → Negative: 6 - 15 = -9

### Reconstruction Formula

```swift
func reconstructPixel(predictor: Int, difference: Int,
                      precision: Int) -> UInt16 {
    let modulo = 1 << precision  // 2^P (e.g., 65536 for 16-bit)
    var pixel = predictor + difference

    // Handle modulo wraparound (JPEG spec requirement)
    if pixel < 0 {
        pixel += modulo
    } else if pixel >= modulo {
        pixel -= modulo
    }

    return UInt16(pixel)
}
```

## 4. Bit Unpacking Strategy

### BitInputStream Design

We need an efficient bit-level reader that handles:
1. **Byte stuffing removal** (0xFF 0x00 → 0xFF)
2. **Marker detection** (0xFF 0xXX where XX != 0x00 signals end)
3. **Bit-level access** (Huffman codes cross byte boundaries)

**Implementation**:
```swift
class BitInputStream {
    private let data: Data
    private var byteIndex: Int
    private var bitBuffer: UInt32 = 0
    private var bitsAvailable: Int = 0
    private let endIndex: Int

    init(data: Data, startIndex: Int, endIndex: Int) {
        self.data = data
        self.byteIndex = startIndex
        self.endIndex = endIndex
    }

    /// Fills the bit buffer with up to 24 bits
    private func fillBuffer() throws {
        while bitsAvailable <= 24 && byteIndex < endIndex {
            let byte = data[byteIndex]
            byteIndex += 1

            // Handle byte stuffing
            if byte == 0xFF {
                if byteIndex < endIndex {
                    let nextByte = data[byteIndex]
                    if nextByte == 0x00 {
                        // Stuffed byte: skip 0x00, keep 0xFF
                        byteIndex += 1
                        bitBuffer = (bitBuffer << 8) | UInt32(byte)
                        bitsAvailable += 8
                    } else {
                        // Marker detected: stop reading
                        byteIndex -= 1  // Back up to marker
                        return
                    }
                } else {
                    throw JPEGError.truncatedData
                }
            } else {
                bitBuffer = (bitBuffer << 8) | UInt32(byte)
                bitsAvailable += 8
            }
        }
    }

    /// Reads a single bit (MSB first)
    func readBit() throws -> Int {
        if bitsAvailable == 0 {
            try fillBuffer()
        }
        guard bitsAvailable > 0 else {
            throw JPEGError.truncatedData
        }

        bitsAvailable -= 1
        let bit = Int((bitBuffer >> bitsAvailable) & 1)
        return bit
    }

    /// Reads N bits as an integer (MSB first)
    func readBits(_ count: Int) throws -> Int {
        guard count <= 16 else {
            throw JPEGError.invalidBitCount
        }

        var result = 0
        for _ in 0..<count {
            result = (result << 1) | try readBit()
        }
        return result
    }
}
```

### Byte Stuffing Details

**Why it exists**: JPEG markers start with 0xFF. To prevent false marker detection in compressed data, any 0xFF byte in entropy-coded data is followed by 0x00.

**Decoding rule**:
```
Input:  ... 0x12 0xFF 0x00 0x34 ...
Output: ... 0x12 0xFF 0x34 ...

Input:  ... 0x12 0xFF 0xD9 ...
Output: ... 0x12 [STOP - EOI marker detected]
```

**Implementation consideration**: Use a state machine or lookahead to handle this efficiently during bit extraction.

## 5. Complete Decoding Algorithm

### High-Level Flow

```swift
func decodeJPEGLossless(data: Data) throws -> [UInt16] {
    // 1. Parse markers
    let markers = try parseMarkers(data)
    let sof3 = markers.sof3
    let huffmanTables = markers.huffmanTables
    let sos = markers.sos
    let compressedDataStart = markers.compressedDataStart

    // 2. Initialize
    let width = sof3.width
    let height = sof3.height
    let precision = sof3.precision
    let predictor = 1 << (precision - 1)  // 2^(P-1)
    var pixels = [UInt16](repeating: 0, count: width * height)

    // 3. Create bitstream
    var bitstream = BitInputStream(data: data,
                                   startIndex: compressedDataStart,
                                   endIndex: data.count)

    // 4. Decode pixels row by row
    let huffTable = huffmanTables[sos.components[0].dcTable]
    var index = 0

    for y in 0..<height {
        for x in 0..<width {
            // Determine predictor
            let pred: Int
            if x == 0 {
                pred = predictor  // First column: use default predictor
            } else {
                pred = Int(pixels[index - 1])  // Use left neighbor (Ra)
            }

            // Decode difference
            let ssss = try decodeHuffmanSymbol(bitstream: &bitstream,
                                               table: huffTable)
            let diff = try decodeDifference(ssss: Int(ssss),
                                           bitstream: &bitstream)

            // Reconstruct pixel
            pixels[index] = reconstructPixel(predictor: pred,
                                            difference: diff,
                                            precision: precision)
            index += 1
        }
    }

    return pixels
}
```

## 6. Edge Cases and Error Handling

### Required Validations

1. **SOF3 validation**:
   - Precision must be 8, 12, or 16 bits
   - Width and height must be > 0
   - Number of components must be 1 (grayscale) for DICOM

2. **SOS validation**:
   - Selection value must be 1 for Transfer Syntax 1.2.840.10008.1.2.4.70
   - Se (end spectral) must be 0
   - Ah/Al must be 0 (no successive approximation)

3. **Huffman validation**:
   - Sum of symbol counts must not exceed 256
   - All referenced Huffman tables must be defined

4. **Bitstream validation**:
   - Handle truncated data gracefully
   - Detect invalid Huffman codes
   - Stop at EOI marker (0xFFD9)

### Common Failure Modes

| Error | Cause | Mitigation |
|-------|-------|------------|
| Invalid Huffman code | Corrupted bitstream | Check code against maxCode at each length |
| Truncated data | Incomplete file | Check byteIndex < endIndex before reads |
| Missing markers | Malformed JPEG | Validate presence of SOI, SOF3, DHT, SOS, EOI |
| Wrong predictor | Incorrect selection value | Verify Ss field in SOS marker |

## 7. Performance Optimizations

### Critical Performance Paths

1. **Bit reading**: Most frequent operation (2-4 calls per pixel)
   - Use 32-bit buffer to minimize refills
   - Inline bit extraction logic
   - Pre-compute byte stuffing removal where possible

2. **Huffman decoding**: Second most frequent (1 call per pixel)
   - Use lookup tables for short codes (≤8 bits)
   - Cache recently used symbols

3. **Prediction**: Third most frequent (1 call per pixel)
   - Inline predictor formula
   - Avoid conditional branches where possible

### Memory Access Patterns

- **Sequential pixel writing**: Good cache locality
- **Left neighbor reads**: Single load, excellent cache hit rate
- **Bitstream reads**: Minimize byte-at-a-time access via buffering

## 8. Testing Strategy

### Unit Tests

1. **Marker parsing**: Verify SOF3, DHT, SOS extraction
2. **Huffman table construction**: Test with known symbol distributions
3. **Huffman decoding**: Decode known bit sequences
4. **Difference decoding**: Test positive/negative values with all ssss values (0-16)
5. **Predictor calculation**: Test first pixel, first column, interior pixels
6. **Reconstruction**: Test modulo wraparound cases

### Integration Tests

1. **Synthetic images**: Generate known pixel patterns, compress with reference encoder, decode
2. **Bit-perfect validation**: Compare output with dicom-swift or GDCM pixel-by-pixel
3. **Edge cases**: 1×1 image, maximum precision (16-bit), all predictor values

### Conformance Tests

Use DICOM conformance images from:
- **dcm4che test suite**: github.com/dcm4che/dcm4che
- **NEMA DICOM samples**: medical.nema.org/medical/dicom/DataSets/

## 9. References

### Specifications

- **ITU-T T.81** (09/1992): Digital compression and coding of continuous-tone still images
- **ISO/IEC 10918-1**: Information technology — Digital compression and coding of continuous-tone still images: Requirements and guidelines
- **DICOM PS3.5 Section 8.2.4**: Transfer Syntax Specifications (JPEG Lossless)

### Key Sections

- **T.81 Annex F**: Huffman table specification and decoding procedures
- **T.81 Annex H**: Lossless mode of operation
- **T.81 Figure A.2**: Predictor definitions (Selection values 0-7)

### Implementation References

- **libjpeg**: Reference implementation (C)
- **GDCM**: Open-source DICOM library with JPEG Lossless support
- **dicom-swift**: OFFIS DICOM Toolkit with lossless decoder

---

## Summary Checklist

Implementation should cover:
- [x] JPEG marker parsing (SOI, SOF3, DHT, SOS, EOI)
- [x] Huffman table construction from DHT segments
- [x] Huffman symbol decoding with bit-level precision
- [x] First-order prediction (Selection Value 1)
- [x] Prediction error decoding (magnitude encoding)
- [x] Pixel reconstruction with modulo arithmetic
- [x] Bit unpacking with byte stuffing removal
- [x] Marker detection during entropy-coded data
- [x] Edge case handling (first pixel, first column)
- [x] Error detection and validation
