import DicomCore
import Foundation
import XCTest

/// Issue #3037: the loaders report the units, VOI and geometry provenance of a volume, and decoded frames carry the
/// rescale, Rescale Type, Modality LUT and spacing attributes that apply to them. Synthetic objects only.
final class DicomVolumeSemanticsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("volume-semantics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func test_classicSeries_reportsUnitsVOIAndMeasuredGeometryProvenance() throws {
        let lut: [UInt16] = [0, 500, 1_000]
        for slice in 0..<3 {
            try write(name: "slice-\(slice)", elements: [
                text(.modality, .CS, ["PT"]), text(.units, .CS, ["BQML"]), text(.instanceNumber, .IS, ["\(3 - slice)"]),
                decimals(.imagePositionPatient, [0, 0, 4 * Double(slice)]),
                decimals(.imageOrientationPatient, [1, 0, 0, 0, 1, 0]), decimals(.pixelSpacing, [2, 3]),
                decimals(.sliceThickness, [9]), lutSequence(.voiLUTSequence, lut)
            ])
        }
        let volume = try DicomSeriesLoader().loadSeries(in: directory)
        XCTAssertEqual(volume.units, "BQML")
        XCTAssertEqual(volume.geometryProvenance, DicomSeriesVolumeGeometryProvenance(
            sliceOrdering: .imagePositionPatient, sliceSpacingSource: .imagePositionPatient,
            isInPlaneSpacingCalibrated: true, hasDeclaredOrientation: true
        ))
        XCTAssertEqual(volume.spacing, SIMD3(3, 2, 4))
        XCTAssertEqual(volume.sliceVOIs.count, 3)
        XCTAssertEqual(volume.sliceVOIs.map { $0?.voiLUTs.first?.data }, [lut, lut, lut])
    }

    func test_classicSeriesWithoutGeometry_reportsGuessedOrderHeaderIntervalAndDefaultSpacing() throws {
        for slice in 0..<3 {
            try write(name: "slice-\(slice)", elements: [
                text(.instanceNumber, .IS, ["\(slice + 1)"]), decimals(.sliceThickness, [3]), decimals(.sliceSpacing, [3.5])
            ])
        }
        let volume = try DicomSeriesLoader().loadSeries(in: directory)
        XCTAssertNil(volume.units)
        XCTAssertEqual(volume.geometryProvenance, DicomSeriesVolumeGeometryProvenance(
            sliceOrdering: .instanceNumber, sliceSpacingSource: .spacingBetweenSlices,
            isInPlaneSpacingCalibrated: false, hasDeclaredOrientation: false
        ))
        XCTAssertEqual(volume.spacing.z, 3.5)
        XCTAssertEqual(volume.sliceVOIs, [nil, nil, nil])
    }

    func test_sopClassGeometry_reportsWhereItsSpacingCameFrom() throws {
        let scanned = try XCTUnwrap(DicomSOPClassGeometry(dataSet: DicomDataSet(elements: [
            DicomDataElement(tag: 0x0018_2010, vr: .DS, value: .strings(["0.25", "0.3"])),
            DicomDataElement(tag: 0x0018_0050, vr: .DS, value: .strings(["2"]))
        ]), sopClassUID: DicomSOPClassGeometry.secondaryCaptureSOPClassUID))
        XCTAssertTrue(scanned.isInPlaneSpacingCalibrated)
        XCTAssertEqual(scanned.frameStepSource, .sliceThickness)
        let bare = try XCTUnwrap(DicomSOPClassGeometry(dataSet: DicomDataSet(elements: []),
                                                       sopClassUID: DicomSOPClassGeometry.nuclearMedicineSOPClassUID))
        XCTAssertFalse(bare.isInPlaneSpacingCalibrated)
        XCTAssertEqual(bare.frameStepSource, .defaultValue)
    }

    func test_classicMultiframe_reportsStoredOrderAndItsFrameStep() throws {
        let url = try write(name: "nm", sopClassUID: DicomSOPClassGeometry.nuclearMedicineSOPClassUID, frames: 3, elements: [
            text(.modality, .CS, ["NM"]), text(.units, .CS, ["CNTS"]), decimals(.pixelSpacing, [4, 4]),
            decimals(.sliceSpacing, [4.5])
        ])
        let volume = try DicomSeriesLoader().loadClassicMultiframeVolume(at: url)
        XCTAssertEqual(volume.units, "CNTS")
        XCTAssertEqual(volume.geometryProvenance, DicomSeriesVolumeGeometryProvenance(
            sliceOrdering: .storedFrames, sliceSpacingSource: .spacingBetweenSlices,
            isInPlaneSpacingCalibrated: true, hasDeclaredOrientation: false
        ))
    }

    func test_enhancedFrames_resolveTheirOwnRescaleAndRescaleType_andTheVolumeReportsItsProvenance() throws {
        let url = try writeEnhanced()
        let volume = try DicomSeriesLoader().loadEnhancedMultiframeVolume(at: url)
        XCTAssertEqual(volume.units, "BQML")
        XCTAssertEqual(volume.geometryProvenance, DicomSeriesVolumeGeometryProvenance(
            sliceOrdering: .imagePositionPatient, sliceSpacingSource: .imagePositionPatient,
            isInPlaneSpacingCalibrated: true, hasDeclaredOrientation: true
        ))
        XCTAssertEqual(volume.sliceRescaleParameters.map(\.intercept), [-1000, -1024], "spatial order: the per-frame group's frame lies first")

        let reader = try DicomDecodedFrameReader(contentsOf: url)
        let first = try reader.frame(at: 0).metadata
        XCTAssertEqual(first.rescaleParameters, RescaleParameters(intercept: -1024, slope: 1), "shared group")
        XCTAssertEqual(first.rescaleType, "HU", "shared group")
        XCTAssertEqual(first.pixelSpacing, [0.5, 0.75], "Pixel Measures as row, column")
        let second = try reader.frame(at: 1).metadata
        XCTAssertEqual(second.rescaleParameters, RescaleParameters(intercept: -1000, slope: 2), "per-frame group")
        XCTAssertEqual(second.rescaleType, "HU", "the per-frame group declares no type: the shared one stands")
    }

    func test_classicFrame_carriesModalityLUTAndProjectionSpacingAttributes() throws {
        let lut: [UInt16] = [7, 8, 9, 10]
        let url = try write(name: "projection", sopClassUID: DicomSOPClassGeometry.secondaryCaptureSOPClassUID, elements: [
            lutSequence(.modalityLUTSequence, lut, type: "OD"),
            DicomDataElement(tag: 0x0018_1164, vr: .DS, value: .strings(["0.2", "0.3"])),
            DicomDataElement(tag: 0x0018_2010, vr: .DS, value: .strings(["0.4", "0.5"])),
            text(.rescaleType, .LO, ["US"]),
            DicomDataElement(tag: 0x0028_0A02, vr: .CS, value: .strings(["GEOMETRY"]))
        ])
        let metadata = try DicomDecodedFrameReader(contentsOf: url).frame(at: 0).metadata
        XCTAssertEqual(metadata.modalityLUTs.first?.data, lut)
        XCTAssertEqual(metadata.modalityLUTs.first?.lutType, "OD")
        XCTAssertEqual(metadata.pixelSpacing, [])
        XCTAssertEqual(metadata.imagerPixelSpacing, [0.2, 0.3])
        XCTAssertEqual(metadata.nominalScannedPixelSpacing, [0.4, 0.5])
        XCTAssertEqual(metadata.pixelSpacingCalibrationType, "GEOMETRY")
        XCTAssertEqual(metadata.rescaleType, "US")
    }

    /// Issue #3032: MONOCHROME1 voxels are the values written, as GDCM and the own stream deliver them; the inversion
    /// is a display step after the modality rescale and VOI. Native and RLE classic slices, and a classic multi-frame.
    func test_monochrome1Volumes_keepTheStoredSamples() throws {
        for bitsStored in [16, 12] {
            let series = directory.appendingPathComponent("mono1-\(bitsStored)")
            try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)
            for slice in 0..<2 {
                let url = try write(name: "mono1-\(bitsStored)/slice-\(slice)", photometric: "MONOCHROME1",
                                    bitsStored: bitsStored, elements: [
                    decimals(.imagePositionPatient, [0, 0, Double(slice)]), decimals(.imageOrientationPatient, [1, 0, 0, 0, 1, 0])
                ])
                if slice == 1 {
                    try DicomTranscoder().transcode(contentsOf: url, to: .rleLossless).write(to: url)
                }
            }
            let volume = try DicomSeriesLoader().loadSeries(in: series)
            XCTAssertEqual(Self.int16(volume.voxels), (0..<16).map { Int16($0 % 8) }, "\(bitsStored)-bit classic series")

            let multiframe = try write(name: "mono1-nm-\(bitsStored)", sopClassUID: DicomSOPClassGeometry.nuclearMedicineSOPClassUID,
                                       frames: 2, photometric: "MONOCHROME1", bitsStored: bitsStored, elements: [])
            let frames = try DicomSeriesLoader().loadClassicMultiframeVolume(at: multiframe)
            XCTAssertEqual(Self.int16(frames.voxels), (0..<16).map(Int16.init), "\(bitsStored)-bit classic multi-frame")
        }
    }

    // MARK: - Fixtures

    private static func int16(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// One 4 × 2 unsigned 16-bit object (CT unless named), `frames` frames.
    @discardableResult
    private func write(name: String, sopClassUID: String = "1.2.840.10008.5.1.4.1.1.2", frames: Int = 1,
                       photometric: String = "MONOCHROME2", bitsStored: Int = 16,
                       elements extra: [DicomDataElement]) throws -> URL {
        var pixels = Data()
        for value in 0..<(8 * frames) { pixels.append(UInt8(value)); pixels.append(0) }
        var elements = [
            text(.sopClassUID, .UI, [sopClassUID]), text(.sopInstanceUID, .UI, ["2.25.3037\(abs(name.hashValue) % 100_000)"]),
            text(.seriesInstanceUID, .UI, ["2.25.30371"]), text(.studyInstanceUID, .UI, ["2.25.30372"]),
            unsigned(.samplesPerPixel, 1), text(.photometricInterpretation, .CS, [photometric]),
            unsigned(.rows, 2), unsigned(.columns, 4), unsigned(.bitsAllocated, 16), unsigned(.bitsStored, UInt(bitsStored)),
            unsigned(.highBit, UInt(bitsStored - 1)), unsigned(.pixelRepresentation, 0),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixels))
        ] + extra
        if frames > 1 { elements.append(text(.numberOfFrames, .IS, ["\(frames)"])) }
        let url = directory.appendingPathComponent("\(name).dcm")
        try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements)).write(to: url)
        return url
    }

    /// Two frames 2 mm apart: the shared Pixel Value Transformation (-1024, HU) and a per-frame one on the second
    /// stored frame (slope 2, intercept -1000, no type), which lies first along the normal.
    private func writeEnhanced() throws -> URL {
        let shared = DicomDataSet(elements: [
            sequence(.pixelMeasuresSequence, [DicomDataSet(elements: [decimals(.pixelSpacing, [0.5, 0.75])])]),
            sequence(.planeOrientationSequence, [DicomDataSet(elements: [
                decimals(.imageOrientationPatient, [1, 0, 0, 0, 1, 0])
            ])]),
            sequence(.pixelValueTransformationSequence, [DicomDataSet(elements: [
                decimals(.rescaleIntercept, [-1024]), decimals(.rescaleSlope, [1]), text(.rescaleType, .LO, ["HU"])
            ])])
        ])
        let perFrame = [
            DicomDataSet(elements: [sequence(.planePositionSequence, [DicomDataSet(elements: [
                decimals(.imagePositionPatient, [0, 0, 2])
            ])])]),
            DicomDataSet(elements: [
                sequence(.planePositionSequence, [DicomDataSet(elements: [decimals(.imagePositionPatient, [0, 0, 0])])]),
                sequence(.pixelValueTransformationSequence, [DicomDataSet(elements: [
                    decimals(.rescaleIntercept, [-1000]), decimals(.rescaleSlope, [2])
                ])])
            ])
        ]
        return try write(name: "enhanced", sopClassUID: "1.2.840.10008.5.1.4.1.1.128.1", frames: 2, elements: [
            text(.units, .CS, ["BQML"]),
            sequence(.sharedFunctionalGroupsSequence, [shared]), sequence(.perFrameFunctionalGroupsSequence, perFrame)
        ])
    }

    private func lutSequence(_ tag: DicomTag, _ entries: [UInt16], type: String? = nil) -> DicomDataElement {
        var table = Data()
        for entry in entries { table.append(UInt8(entry & 0xFF)); table.append(UInt8(entry >> 8)) }
        var elements = [
            DicomDataElement(tag: DicomTag.lutDescriptor.rawValue, vr: .US,
                             value: .unsignedIntegers([UInt(entries.count), 0, 16])),
            DicomDataElement(tag: DicomTag.lutData.rawValue, vr: .OW, value: .bytes(table))
        ]
        if let type { elements.append(text(.modalityLUTType, .LO, [type])) }
        return sequence(tag, [DicomDataSet(elements: elements)])
    }

    private func text(_ tag: DicomTag, _ vr: DicomVR, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings(values))
    }

    private func decimals(_ tag: DicomTag, _ values: [Double]) -> DicomDataElement {
        text(tag, .DS, values.map { "\($0)" })
    }

    private func unsigned(_ tag: DicomTag, _ value: UInt) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value]))
    }

    private func sequence(_ tag: DicomTag, _ items: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .SQ, value: .sequence(items.map(DicomSequenceItem.init(dataSet:))))
    }
}
