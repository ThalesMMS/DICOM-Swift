import Foundation

enum DicomDecodedFrameDataNormalizer {
    static func makeBuffer(
        data: Data,
        width: Int,
        height: Int,
        bitsPerSample: Int,
        bitsStored: Int,
        highBit: Int,
        componentCount: Int,
        pixelRepresentation: Int,
        photometricInterpretation: String,
        sourceByteOrder: DicomDecodedFrameByteOrder,
        ownership: DicomDecodedFrameDataOwnership,
        packedBitOffset: Int = 0
    ) -> DicomDecodedFrameDataBuffer? {
        guard bitsPerSample > 0,
              bitsPerSample <= 16,
              bitsStored > 0,
              bitsStored <= bitsPerSample,
              highBit >= bitsStored - 1,
              highBit < bitsPerSample,
              componentCount > 0,
              packedBitOffset >= 0,
              packedBitOffset < 8,
              pixelRepresentation == 0 || pixelRepresentation == 1 else {
            return nil
        }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !pixels.overflow else { return nil }
        let pixelCount = pixels.partialValue
        let samples = pixelCount.multipliedReportingOverflow(by: componentCount)
        guard !samples.overflow else { return nil }
        let componentSampleCount = samples.partialValue
        let sampleShift = highBit - bitsStored + 1
        let storedValueRange = 1 << bitsStored
        let storedValueMask = storedValueRange - 1

        if componentCount == 3, bitsPerSample <= 8 {
            let rowBytes = width.multipliedReportingOverflow(by: 3)
            guard bitsStored == bitsPerSample,
                  sampleShift == 0,
                  packedBitOffset == 0,
                  !rowBytes.overflow,
                  data.count == componentSampleCount else { return nil }
            return DicomDecodedFrameDataBuffer(
                data: data,
                format: .rgb8Interleaved,
                byteOrder: .notApplicable,
                ownership: ownership,
                pixelCount: pixelCount,
                componentSampleCount: componentSampleCount,
                bytesPerRow: rowBytes.partialValue
            )
        }

        guard componentCount == 1 else { return nil }
        if bitsPerSample == 1 {
            let finalBitIndex = packedBitOffset.addingReportingOverflow(pixelCount)
            guard !finalBitIndex.overflow else { return nil }
            let packedByteCount = finalBitIndex.partialValue.addingReportingOverflow(7)
            guard !packedByteCount.overflow,
                  bitsStored == 1,
                  highBit == 0,
                  pixelRepresentation == 0,
                  data.count == packedByteCount.partialValue / 8 else {
                return nil
            }
            let needsInversion = photometricInterpretation == "MONOCHROME1"
            var outputData = Data(count: pixelCount)
            outputData.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for index in 0..<pixelCount {
                    let bitIndex = packedBitOffset + index
                    let bit = (data[bitIndex / 8] >> UInt8(bitIndex % 8)) & 0x01
                    output[index] = needsInversion ? 1 - bit : bit
                }
            }
            return DicomDecodedFrameDataBuffer(
                data: outputData,
                format: .gray8NormalizedUnsigned,
                byteOrder: .notApplicable,
                ownership: .ownedData,
                pixelCount: pixelCount,
                componentSampleCount: pixelCount,
                bytesPerRow: width
            )
        }
        if bitsPerSample <= 8 {
            guard packedBitOffset == 0, data.count == pixelCount else { return nil }
            let needsSignedNormalization = pixelRepresentation == 1
            let needsInversion = photometricInterpretation == "MONOCHROME1"
            let needsStoredBitNormalization = bitsStored != bitsPerSample || sampleShift != 0
            let normalized: Data
            let normalizedOwnership: DicomDecodedFrameDataOwnership
            if needsSignedNormalization || needsInversion || needsStoredBitNormalization {
                var outputData = Data(count: pixelCount)
                outputData.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                    for index in 0..<pixelCount {
                        let stored = (Int(data[index]) >> sampleShift) & storedValueMask
                        var value = stored
                        if needsSignedNormalization {
                            let signBit = 1 << (bitsStored - 1)
                            let signed = stored & signBit == 0 ? stored : stored - storedValueRange
                            value = signed + signBit
                        }
                        output[index] = UInt8(needsInversion ? storedValueMask - value : value)
                    }
                }
                normalized = outputData
                normalizedOwnership = .ownedData
            } else {
                normalized = data
                normalizedOwnership = ownership
            }
            return DicomDecodedFrameDataBuffer(
                data: normalized,
                format: .gray8NormalizedUnsigned,
                byteOrder: .notApplicable,
                ownership: normalizedOwnership,
                pixelCount: pixelCount,
                componentSampleCount: pixelCount,
                bytesPerRow: width
            )
        }

        guard bitsPerSample <= 16, packedBitOffset == 0 else { return nil }
        let expectedBytes = pixelCount.multipliedReportingOverflow(by: 2)
        let rowBytes = width.multipliedReportingOverflow(by: 2)
        guard !expectedBytes.overflow, !rowBytes.overflow, data.count == expectedBytes.partialValue else {
            return nil
        }
        let needsSignedNormalization = pixelRepresentation == 1
        let needsInversion = photometricInterpretation == "MONOCHROME1"
        let needsByteSwap = sourceByteOrder != .littleEndian
        let needsStoredBitNormalization = bitsStored != bitsPerSample || sampleShift != 0
        let normalized: Data
        let normalizedOwnership: DicomDecodedFrameDataOwnership
        if needsSignedNormalization || needsInversion || needsByteSwap || needsStoredBitNormalization {
            var outputData = Data(count: expectedBytes.partialValue)
            outputData.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for index in 0..<pixelCount {
                    let byteIndex = index * 2
                    let raw: UInt16
                    if sourceByteOrder == .littleEndian {
                        raw = UInt16(data[byteIndex]) | (UInt16(data[byteIndex + 1]) << 8)
                    } else {
                        raw = (UInt16(data[byteIndex]) << 8) | UInt16(data[byteIndex + 1])
                    }
                    let stored = (Int(raw) >> sampleShift) & storedValueMask
                    var value = stored
                    if needsSignedNormalization {
                        let signBit = 1 << (bitsStored - 1)
                        let signed = stored & signBit == 0 ? stored : stored - storedValueRange
                        value = signed + signBit
                    }
                    if needsInversion {
                        value = storedValueMask - value
                    }
                    output[byteIndex] = UInt8(truncatingIfNeeded: value)
                    output[byteIndex + 1] = UInt8(truncatingIfNeeded: value >> 8)
                }
            }
            normalized = outputData
            normalizedOwnership = .ownedData
        } else {
            normalized = data
            normalizedOwnership = ownership
        }
        return DicomDecodedFrameDataBuffer(
            data: normalized,
            format: .gray16NormalizedUnsigned,
            byteOrder: .littleEndian,
            ownership: normalizedOwnership,
            pixelCount: pixelCount,
            componentSampleCount: pixelCount,
            bytesPerRow: rowBytes.partialValue
        )
    }

    static func copyBuffer(
        from pixels: DicomDecodedFramePixelBuffer,
        width: Int,
        height: Int
    ) -> DicomDecodedFrameDataBuffer? {
        switch pixels {
        case .gray8(let values):
            return makeBuffer(
                data: Data(values), width: width, height: height, bitsPerSample: 8, bitsStored: 8, highBit: 7,
                componentCount: 1,
                pixelRepresentation: 0, photometricInterpretation: "MONOCHROME2", sourceByteOrder: .notApplicable,
                ownership: .ownedData
            )
        case .gray16(let values):
            var data = Data(count: values.count * 2)
            data.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) in
                for (index, value) in values.enumerated() {
                    output[index * 2] = UInt8(truncatingIfNeeded: value)
                    output[index * 2 + 1] = UInt8(truncatingIfNeeded: value >> 8)
                }
            }
            return makeBuffer(
                data: data, width: width, height: height, bitsPerSample: 16, bitsStored: 16, highBit: 15,
                componentCount: 1,
                pixelRepresentation: 0, photometricInterpretation: "MONOCHROME2", sourceByteOrder: .littleEndian,
                ownership: .ownedData
            )
        case .rgb8(let interleaved):
            return makeBuffer(
                data: Data(interleaved), width: width, height: height, bitsPerSample: 8, bitsStored: 8, highBit: 7,
                componentCount: 3,
                pixelRepresentation: 0, photometricInterpretation: "RGB", sourceByteOrder: .notApplicable,
                ownership: .ownedData
            )
        }
    }
}
