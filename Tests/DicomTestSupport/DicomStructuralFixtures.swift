import DicomCore
import Foundation

/// Synthetic classic CT/MR slices and multi-frame Secondary Capture objects for split/merge tests (#2323).
public enum DicomStructuralFixtures {
    public static func string(_ tag: DicomTag, _ vr: DicomVR, _ values: [String]) -> DicomDataElement { DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([String](values))) }
    public static func number(_ tag: DicomTag, _ value: UInt) -> DicomDataElement { DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value])) }

    /// A classic 16-bit CT slice; `extra` adds per-instance attributes.
    public static func ctSlice(index: Int, position: [Double] = [0, 0, 0], orientation: [Double] = [1, 0, 0, 0, 1, 0], spacing: [Double] = [0.5, 0.5],
                 sopClass: String = "1.2.840.10008.5.1.4.1.1.2", series: String = "2.25.23269903", frameOfReference: String = "2.25.23269904",
                 pixels: Data? = nil, window: [String] = ["40", "400"], extra: [DicomDataElement] = []) throws -> Data {
        let bytes = pixels ?? Data((0..<32).map { UInt8(($0 + index * 7) & 0xFF) })
        var dataSet = DicomDataSet(elements: [
            string(.sopClassUID, .UI, [sopClass]), string(.sopInstanceUID, .UI, ["2.25.2326990\(index)"]),
            string(.studyInstanceUID, .UI, ["2.25.23269902"]), string(.seriesInstanceUID, .UI, [series]), string(.frameOfReferenceUID, .UI, [frameOfReference]),
            string(.patientName, .PN, ["Merge^Case"]), string(.patientID, .LO, ["M-1"]), string(.modality, .CS, [sopClass.hasSuffix(".4") ? "MR" : "CT"]),
            string(.imageType, .CS, ["ORIGINAL", "PRIMARY", "AXIAL"]), string(.instanceNumber, .IS, [String(index)]),
            string(.seriesNumber, .IS, ["3"]), string(.imagePositionPatient, .DS, position.map { String($0) }),
            string(.imageOrientationPatient, .DS, orientation.map { String($0) }), string(.pixelSpacing, .DS, spacing.map { String($0) }),
            string(.sliceThickness, .DS, ["2"]), string(.rescaleIntercept, .DS, ["-1024"]), string(.rescaleSlope, .DS, ["1"]), string(.rescaleType, .LO, ["HU"]),
            string(.windowCenter, .DS, [window[0]]), string(.windowWidth, .DS, [window[1]]), DicomDataElement(tag: 0x0018_0060, vr: .DS, value: .strings(["120"])),
            number(.rows, 4), number(.columns, 4), number(.bitsAllocated, 16), number(.bitsStored, 12), number(.highBit, 11), number(.pixelRepresentation, 0),
            number(.samplesPerPixel, 1), string(.photometricInterpretation, .CS, ["MONOCHROME2"]),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(bytes))
        ])
        for element in extra { dataSet.set(element) }
        return try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .explicitVRLittleEndian))
    }

    public static func multiframeSecondaryCapture(frames: Int, bitsAllocated: Int = 8, samples: Int = 1, sopClass: String = "1.2.840.10008.5.1.4.1.1.7.2") throws -> Data {
        let pixelByteCount = (3 * 2 * samples * bitsAllocated * frames + 7) / 8
        var elements = [
            string(.sopClassUID, .UI, [sopClass]), string(.sopInstanceUID, .UI, ["2.25.23269950"]), string(.studyInstanceUID, .UI, ["2.25.23269902"]),
            string(.seriesInstanceUID, .UI, ["2.25.23269951"]), string(.patientName, .PN, ["Split^Case"]), string(.patientID, .LO, ["S-1"]), string(.modality, .CS, ["OT"]),
            string(.conversionType, .CS, ["WSD"]), string(.instanceNumber, .IS, ["1"]), string(.numberOfFrames, .IS, [String(frames)]),
            DicomDataElement(tag: DicomTag.frameIncrementPointer.rawValue, vr: .AT, value: .unsignedIntegers([0x0018_2005])),
            DicomDataElement(tag: 0x0018_2005, vr: .DS, value: .strings((0..<frames).map { String($0 * 2) })),
            number(.rows, 3), number(.columns, 2), number(.bitsAllocated, UInt(bitsAllocated)), number(.bitsStored, UInt(bitsAllocated)), number(.highBit, UInt(bitsAllocated - 1)),
            number(.pixelRepresentation, 0), number(.samplesPerPixel, UInt(samples)), string(.photometricInterpretation, .CS, [samples == 3 ? "RGB" : "MONOCHROME2"]),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: bitsAllocated > 8 ? .OW : .OB, value: .bytes(Data((0..<pixelByteCount).map { UInt8($0 & 0xFF) })))
        ]
        if samples == 3 { elements.append(number(.planarConfiguration, 0)) }
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements), options: .init(transferSyntax: .explicitVRLittleEndian))
    }

}
