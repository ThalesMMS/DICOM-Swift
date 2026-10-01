import simd
import XCTest
@testable import DicomCore

final class DicomSegmentationTests: XCTestCase {
    func test_mixedGeometry_doesNotInventPositionDimensionIndexes() throws {
        let segmentation = DicomSegmentation(sopInstanceUID: "2.25.9601", segmentationType: .binary,
            rows: 1, columns: 1, segments: [.init(number: 1, label: "Mask")], frames: [
                .init(index: 0, segmentNumber: 1,
                      geometry: .init(frameIndex: 0, imagePositionPatient: .init(0, 0, 2)), pixelData: .binary([1])),
                .init(index: 1, segmentNumber: 1, pixelData: .binary([0]))
            ])
        let dataSet = DicomSegmentationBuilder.dataSet(from: segmentation,
            studyInstanceUID: "2.25.9602", seriesInstanceUID: "2.25.9603")
        let indexes = dataSet.sequenceItems(for: .dimensionIndexSequence)
        XCTAssertEqual(indexes.count, 1)
        XCTAssertEqual(indexes.first?[.dimensionIndexPointer]?.intValue, DicomTag.referencedSegmentNumber.rawValue)
        for frame in dataSet.sequenceItems(for: .perFrameFunctionalGroupsSequence) {
            let values = try XCTUnwrap(frame[.frameContentSequence]?.sequenceItems.first?[.dimensionIndexValues])
            XCTAssertEqual(values.vm.count, 1)
            XCTAssertEqual(values.intValue, 1)
        }
    }

    func test_incompleteExplicitReferences_areOmitted() throws {
        let valid = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                                             referencedSOPInstanceUID: "2.25.9701", referencedFrameNumbers: [])
        let segmentation = DicomSegmentation(sopInstanceUID: "2.25.9601", segmentationType: .binary,
            rows: 1, columns: 1, referencedSeriesInstanceUIDs: ["2.25.9700"],
            segments: [.init(number: 1, label: "Mask")],
            frames: [.init(index: 0, segmentNumber: 1, pixelData: .binary([1]))])
        let dataSet = DicomSegmentationBuilder.dataSet(from: segmentation,
            studyInstanceUID: "2.25.9602", seriesInstanceUID: "2.25.9603", options: .init(
                referencedInstancesBySeries: ["2.25.9700": [
                    .init(referencedSOPClassUID: nil, referencedSOPInstanceUID: "2.25.9702", referencedFrameNumbers: []),
                    .init(referencedSOPClassUID: valid.referencedSOPClassUID, referencedSOPInstanceUID: nil, referencedFrameNumbers: []), valid
                ]]))
        let references = try XCTUnwrap(dataSet[.referencedSeriesSequence]?.sequenceItems.first?[0x0008114A]?.sequenceItems)
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references[0][.referencedSOPClassUID]?.stringValue, valid.referencedSOPClassUID)
        XCTAssertEqual(references[0][.referencedSOPInstanceUID]?.stringValue, valid.referencedSOPInstanceUID)
    }

    func test_reusedDimensionIndexes_matchTheEmittedDimensionCount() throws {
        for hasPosition in [false, true] {
            let expected = hasPosition ? ["1", "1"] : ["1"]
            for indexes in [[1], [1, 1], [1, 1, 9]] {
                let geometry = DicomFrameGeometry(frameIndex: 0,
                    imagePositionPatient: hasPosition ? .init(0, 0, 2) : nil,
                    frameContent: .init(dimensionIndexValues: indexes, stackID: "SOURCE",
                        inStackPositionNumber: nil, temporalPositionIndex: nil, frameAcquisitionNumber: nil))
                let segmentation = DicomSegmentation(sopInstanceUID: "2.25.9801", segmentationType: .binary,
                    rows: 1, columns: 1, segments: [.init(number: 1, label: "Mask")],
                    frames: [.init(index: 0, segmentNumber: 1, geometry: geometry, pixelData: .binary([1]))])
                let dataSet = DicomSegmentationBuilder.dataSet(from: segmentation,
                    studyInstanceUID: "2.25.9802", seriesInstanceUID: "2.25.9803")
                XCTAssertEqual(dataSet.sequenceItems(for: .dimensionIndexSequence).count, expected.count)
                let frame = try XCTUnwrap(dataSet[.perFrameFunctionalGroupsSequence]?.sequenceItems.first)
                let content = try XCTUnwrap(frame[.frameContentSequence]?.sequenceItems.first)
                XCTAssertEqual(content[.dimensionIndexValues]?.stringValues, expected)
                XCTAssertEqual(content[.stackID]?.stringValue, "SOURCE")
            }
        }
    }

    func test_labelmapReusedDimensionIndexes_keepOnlyThePositionDimension() throws {
        for indexes in [[1], [1, 1], [1, 1, 9]] {
            let geometry = DicomFrameGeometry(frameIndex: 0, imagePositionPatient: .init(0, 0, 2),
                frameContent: .init(dimensionIndexValues: indexes, stackID: "SOURCE",
                    inStackPositionNumber: nil, temporalPositionIndex: nil, frameAcquisitionNumber: nil))
            let segmentation = DicomSegmentation(segmentationType: .labelmap, rows: 1, columns: 1,
                segments: [.init(number: 300, label: "Mask")],
                frames: [.init(index: 0, segmentNumber: 0, geometry: geometry, pixelData: .labelmap([300]))])
            let dataSet = build(segmentation)
            let dimensions = dataSet.sequenceItems(for: .dimensionIndexSequence)
            XCTAssertEqual(dimensions.count, 1)
            XCTAssertEqual(dimensions.first?[.dimensionIndexPointer]?.intValue, DicomTag.imagePositionPatient.rawValue)
            let frame = try XCTUnwrap(dataSet[.perFrameFunctionalGroupsSequence]?.sequenceItems.first)
            let content = try XCTUnwrap(frame[.frameContentSequence]?.sequenceItems.first)
            XCTAssertEqual(content[.dimensionIndexValues]?.stringValues, ["1"])
            XCTAssertEqual(content[.stackID]?.stringValue, "SOURCE")
        }
    }

    func test_referencedSeriesWithoutValidInstances_areOmitted() throws {
        let segmentation = DicomSegmentation(sopInstanceUID: "2.25.9901", segmentationType: .binary,
            rows: 1, columns: 1, referencedSeriesInstanceUIDs: ["2.25.9910", "2.25.9920"],
            segments: [.init(number: 1, label: "Mask")],
            frames: [.init(index: 0, segmentNumber: 1, pixelData: .binary([1]))])
        let valid = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9911", referencedFrameNumbers: [])
        for references in [[], [valid]] {
            let dataSet = DicomSegmentationBuilder.dataSet(from: segmentation,
                studyInstanceUID: "2.25.9902", seriesInstanceUID: "2.25.9903",
                options: .init(referencedInstancesBySeries: ["2.25.9910": references]))
            XCTAssertEqual(dataSet.contains(.referencedSeriesSequence), !references.isEmpty)
            let series = dataSet.sequenceItems(for: .referencedSeriesSequence)
            XCTAssertEqual(series.count, references.isEmpty ? 0 : 1)
            if !references.isEmpty {
                XCTAssertEqual(series.first?[.seriesInstanceUID]?.stringValue, "2.25.9910")
                XCTAssertEqual(series.first?[0x0008114A]?.sequenceItems.first?[.referencedSOPInstanceUID]?.stringValue, "2.25.9911")
            }
        }
    }

    func testBinarySegmentationRoundTripsSegmentMetadataLabelmapsAndGeometry() throws {
        let sourceReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2.1",
            referencedSOPInstanceUID: "2.25.9001",
            referencedFrameNumbers: [7],
            derivationCode: DicomSegmentationBuilder.derivationCode,
            purposeOfReferenceCode: DicomSegmentationBuilder.sourcePurposeCode
        )
        let segment = DicomSegment(
            number: 1,
            label: "Liver",
            description: "Binary liver mask",
            algorithmType: "AUTOMATIC",
            algorithmName: "UnitTestSegmenter",
            propertyCategory: DicomCodedConcept(codeValue: "T-D0050", codingSchemeDesignator: "SRT", codeMeaning: "Tissue"),
            propertyType: DicomCodedConcept(codeValue: "T-62000", codingSchemeDesignator: "SRT", codeMeaning: "Liver"),
            trackingID: "liver-mask",
            trackingUID: "2.25.9101",
            recommendedDisplayCIELabValue: [32896, 32896, 32896]
        )
        let segmentation = DicomSegmentation(
            sopInstanceUID: "2.25.9201",
            segmentationType: .binary,
            rows: 2,
            columns: 2,
            referencedSeriesInstanceUIDs: ["2.25.9000"],
            segments: [segment],
            frames: [
                DicomSegmentationFrame(
                    index: 0,
                    segmentNumber: 1,
                    geometry: geometry(frameIndex: 0, z: 0, sourceReference: sourceReference),
                    sourceImageReferences: [sourceReference],
                    pixelData: .binary([1, 0, 0, 1])
                ),
                DicomSegmentationFrame(
                    index: 1,
                    segmentNumber: 1,
                    geometry: geometry(frameIndex: 1, z: 1.5, sourceReference: sourceReference),
                    sourceImageReferences: [sourceReference],
                    pixelData: .binary([0, 1, 1, 0])
                )
            ]
        )

        let decoder = try open(segmentation)
        let parsed = try XCTUnwrap(decoder.segmentation)

        XCTAssertEqual(parsed.sopInstanceUID, "2.25.9201")
        XCTAssertEqual(parsed.segmentationType, .binary)
        XCTAssertNil(parsed.fractionalType)
        XCTAssertEqual(parsed.rows, 2)
        XCTAssertEqual(parsed.columns, 2)
        XCTAssertEqual(parsed.referencedSeriesInstanceUIDs, ["2.25.9000"])
        XCTAssertEqual(parsed.segments, [segment])
        XCTAssertEqual(parsed.frames.map(\.segmentNumber), [1, 1])
        XCTAssertEqual(parsed.frames[0].pixelData, .binary([1, 0, 0, 1]))
        XCTAssertEqual(parsed.frames[1].pixelData, .binary([0, 1, 1, 0]))

        let firstGeometry = try XCTUnwrap(parsed.frames[0].geometry)
        XCTAssertEqual(firstGeometry.imagePositionPatient, SIMD3<Double>(0, 0, 0))
        XCTAssertEqual(firstGeometry.imageOrientationPatient?.row, SIMD3<Double>(1, 0, 0))
        XCTAssertEqual(firstGeometry.imageOrientationPatient?.column, SIMD3<Double>(0, 1, 0))
        XCTAssertEqual(firstGeometry.pixelMeasures?.pixelSpacing, SIMD2<Double>(0.7, 0.8))
        XCTAssertEqual(firstGeometry.pixelMeasures?.sliceThickness, 1.5)
        XCTAssertEqual(firstGeometry.sourceImageReferences, [sourceReference])
        XCTAssertEqual(parsed.frames[1].geometry?.imagePositionPatient, SIMD3<Double>(0, 0, 1.5))

        let labelmap = try XCTUnwrap(parsed.labelmapsBySegment[1])
        XCTAssertEqual(labelmap.frameIndexes, [0, 1])
        XCTAssertEqual(labelmap.voxels, [1, 0, 0, 1, 0, 1, 1, 0])
        XCTAssertNil(labelmap.fractionalVoxels)
        XCTAssertEqual(labelmap.sourceImageReferences[0], [sourceReference])
    }

    func testFractionalSegmentationRoundTripsValuesAndLabelmap() throws {
        let segment = DicomSegment(
            number: 2,
            label: "Probability",
            algorithmType: "SEMIAUTOMATIC",
            algorithmName: "UnitTestFractional",
            trackingUID: "2.25.9301"
        )
        let segmentation = DicomSegmentation(
            sopInstanceUID: "2.25.9302",
            segmentationType: .fractional,
            fractionalType: .probability,
            maximumFractionalValue: 255,
            rows: 2,
            columns: 2,
            segments: [segment],
            frames: [
                DicomSegmentationFrame(
                    index: 0,
                    segmentNumber: 2,
                    geometry: geometry(frameIndex: 0, z: 3, sourceReference: nil),
                    pixelData: .fractional(values: [0, 64, 128, 255], maximumFractionalValue: 255)
                )
            ]
        )

        let decoder = try open(segmentation)
        let parsed = try XCTUnwrap(decoder.segmentation)

        XCTAssertEqual(parsed.segmentationType, .fractional)
        XCTAssertEqual(parsed.fractionalType, .probability)
        XCTAssertEqual(parsed.maximumFractionalValue, 255)
        XCTAssertEqual(parsed.segments, [segment])
        XCTAssertEqual(parsed.frames.first?.pixelData, .fractional(values: [0, 64, 128, 255], maximumFractionalValue: 255))
        XCTAssertEqual(parsed.frames.first?.geometry?.imagePositionPatient, SIMD3<Double>(0, 0, 3))

        let labelmap = try XCTUnwrap(parsed.labelmapsBySegment[2])
        XCTAssertEqual(labelmap.binarized(threshold: 1), [0, 2, 2, 2])
        XCTAssertEqual(labelmap.fractionalVoxels, [0, 64, 128, 255])
    }

    func testSegmentationParsesImplicitVRLittleEndian() throws {
        let segment = DicomSegment(number: 3, label: "Implicit")
        let segmentation = DicomSegmentation(
            sopInstanceUID: "2.25.9501",
            segmentationType: .binary,
            rows: 2,
            columns: 2,
            segments: [segment],
            frames: [
                DicomSegmentationFrame(
                    index: 0,
                    segmentNumber: 3,
                    pixelData: .binary([1, 0, 1, 0])
                )
            ]
        )

        let decoder = try open(segmentation, transferSyntax: .implicitVRLittleEndian)
        let parsed = try XCTUnwrap(decoder.segmentation)

        XCTAssertEqual(parsed.segments, [segment])
        XCTAssertEqual(parsed.frames.first?.pixelData, .binary([1, 0, 1, 0]))
        XCTAssertEqual(parsed.labelmapsBySegment[3]?.voxels, [3, 0, 3, 0])
    }

    func test_labelmap8And16Bit_roundTripsStoredLabelsAndSparseFrames() throws {
        for labels: [UInt16] in [[1, 2], [1, 2, 300]] {
            let planes = [labels, labels.reversed().map { $0 }, labels]
            let model = DicomSegmentation(segmentationType: .labelmap, rows: 1, columns: labels.count,
                segments: labels.map { DicomSegment(number: Int($0), label: "Label") },
                frames: planes.enumerated().map { index, values in
                    DicomSegmentationFrame(index: index, segmentNumber: 0,
                        geometry: geometry(frameIndex: index, z: Double(index * 2 + 1), sourceReference: nil),
                        pixelData: .labelmap(.uint16(values)))
                }, pixelPaddingValue: 1)
            let dataSet = build(model)
            XCTAssertEqual(dataSet[0x00080016]?.stringValue, DicomSegmentationBuilder.labelMapSegmentationStorageSOPClassUID)
            XCTAssertEqual(dataSet[0x00280100]?.intValue, labels.contains(300) ? 16 : 8)
            XCTAssertEqual(dataSet[0x00620013]?.stringValue, "NO")
            XCTAssertNil(dataSet[0x0062000E])
            XCTAssertNil(dataSet[0x00620010])
            XCTAssertTrue(dataSet[0x52009230]!.sequenceItems.allSatisfy { !$0.dataSet.contains(0x0062000A) })
            let parsed = try XCTUnwrap(open(model).segmentation)
            XCTAssertEqual(parsed.labelmapVoxelsByFrame, planes)
            XCTAssertEqual(parsed.frames.map { $0.geometry?.imagePositionPatient?.z }, [1, 3, 5])
            XCTAssertEqual(parsed.frames.map(\.segmentAttribution), Array(repeating: .unattributed, count: 3))
            XCTAssertEqual(parsed.pixelPaddingValue, 1)
            XCTAssertTrue(parsed.diagnostics.isEmpty)
        }
    }

    func test_labelmapZeroValue_requiresDeclaredSegmentEvenWhenUsedAsPadding() throws {
        for padding: UInt16? in [nil, 0] {
            for declaresZero in [false, true] {
                let segments = (declaresZero ? [0, 1] : [1]).map { DicomSegment(number: $0, label: "Label \($0)") }
                let model = DicomSegmentation(segmentationType: .labelmap, rows: 1, columns: 2,
                    segments: segments,
                    frames: [.init(index: 0, segmentNumber: 0,
                        geometry: geometry(frameIndex: 0, z: 1, sourceReference: nil), pixelData: .labelmap([0, 1]))],
                    pixelPaddingValue: padding)
                let parsed = try parse(build(model))
                XCTAssertEqual(parsed.segments.map(\.number), segments.map(\.number))
                XCTAssertEqual(parsed.labelmapVoxelsByFrame, [[0, 1]])
                XCTAssertEqual(parsed.pixelPaddingValue, padding)
                XCTAssertEqual(parsed.diagnostics.contains { $0.code == .labelmapValueWithoutSegment }, !declaresZero)
            }
        }
    }

    /// Isis issue #2504: Series Description and Specific Character Set are written when set, text is encoded
    /// with that set, and the Referenced Series Sequence is read from the header without decoding a frame.
    func test_seriesDescriptionAndCharacterSet_areWrittenAndReferencedSeriesReadFromTheHeader() throws {
        let source = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.2504.2", referencedFrameNumbers: [])
        let model = DicomSegmentation(segmentationType: .labelmap, rows: 1, columns: 2,
            referencedSeriesInstanceUIDs: ["2.25.2504.1"],
            segments: [0, 1].map { DicomSegment(number: $0, label: "Label \($0)") },
            frames: [.init(index: 0, segmentNumber: 0, geometry: geometry(frameIndex: 0, z: 1, sourceReference: source),
                           sourceImageReferences: [source], pixelData: .labelmap([0, 1]))],
            pixelPaddingValue: 0)
        var options = DicomSegmentationBuildOptions()
        options.seriesDescription = "Órgãos"
        options.specificCharacterSet = "ISO_IR 192"
        let dataSet = DicomSegmentationBuilder.dataSet(from: model, studyInstanceUID: "2.25.100",
                                                       seriesInstanceUID: "2.25.101", options: options)
        XCTAssertEqual(dataSet[0x0008103E]?.stringValue, "Órgãos")
        XCTAssertEqual(dataSet[0x00080005]?.stringValue, "ISO_IR 192")
        XCTAssertNil(build(model)[0x0008103E])
        XCTAssertNil(build(model)[0x00080005])
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
        XCTAssertNotNil(bytes.range(of: Data("Órgãos".utf8)), "UTF-8 under ISO_IR 192")
        let decoder = try DCMDecoder(data: bytes)
        XCTAssertEqual(decoder.segmentationReferencedSeriesInstanceUIDs, ["2.25.2504.1"])
        XCTAssertEqual(try DCMDecoder(data: DicomDataSetWriter.part10Data(from: build(DicomSegmentation(
            segmentationType: .binary, rows: 1, columns: 1, segments: [.init(number: 1, label: "Mask")],
            frames: [.init(index: 0, segmentNumber: 1, pixelData: .binary([1]))])))).segmentationReferencedSeriesInstanceUIDs, [])
    }

    func test_paletteColorLabelmap_roundTripsPaletteAndOmitsCIELab() throws {
        var palette: [DicomDataElement] = []
        for tag in [0x00281101, 0x00281102, 0x00281103] {
            palette.append(.init(tag: tag, vr: .US, value: .unsignedIntegers([2, 1, 8])))
        }
        for tag in [0x00281201, 0x00281202, 0x00281203] {
            palette.append(.init(tag: tag, vr: .OW, value: .bytes(Data([0, 255]))))
        }
        let model = DicomSegmentation(segmentationType: .labelmap, rows: 1, columns: 2,
            segments: [.init(number: 1, label: "One", recommendedDisplayCIELabValue: [1, 2, 3]),
                       .init(number: 2, label: "Two")],
            frames: [.init(index: 0, segmentNumber: 0, pixelData: .labelmap([1, 2]))],
            photometricInterpretation: "PALETTE COLOR", paletteColorElements: palette)
        let decoder = try open(model)
        let parsed = try XCTUnwrap(decoder.segmentation)
        XCTAssertEqual(parsed.photometricInterpretation, "PALETTE COLOR")
        XCTAssertEqual(parsed.labelmapVoxelsByFrame, [[1, 2]])
        XCTAssertEqual(parsed.paletteColorElements.sorted { $0.tag < $1.tag }, palette.sorted { $0.tag < $1.tag })
        XCTAssertEqual(decoder.reds, [0, 255])
        XCTAssertEqual(decoder.redPaletteDescriptor?.firstMappedValue, 1)
        XCTAssertTrue(parsed.segments.allSatisfy { $0.recommendedDisplayCIELabValue.isEmpty })
        XCTAssertEqual(try parse(build(parsed)).paletteColorElements, parsed.paletteColorElements)
    }

    func test_sharedGroupsWithDifferentFrames_writePerFrameAndPreserveSparsePositions() throws {
        let model = DicomSegmentation(segmentationType: .binary, rows: 1, columns: 1,
            segments: [.init(number: 1, label: "One"), .init(number: 2, label: "Two")],
            frames: (0..<3).map { index in
                .init(index: index, segmentNumber: index == 1 ? 2 : 1,
                    geometry: geometry(frameIndex: index, z: Double(index * 2 + 1), sourceReference: nil),
                    pixelData: .binary([1]))
            }, sharedFunctionalGroups: [.segmentIdentification])
        let parsed = try parse(build(model))
        XCTAssertTrue(parsed.sharedFunctionalGroups.isEmpty)
        XCTAssertEqual(parsed.frames.map(\.segmentNumber), [1, 2, 1])
        XCTAssertEqual(parsed.frames.map { $0.geometry?.imagePositionPatient?.z }, [1, 3, 5])
        XCTAssertTrue(build(parsed)[0x52009230]!.sequenceItems.allSatisfy { $0.dataSet.contains(0x0062000A) })
        // Missing identification in a single-segment object is explicitly inferred.
        let single = DicomSegmentation(segmentationType: .binary, rows: 1, columns: 1,
            segments: [.init(number: 1, label: "One")],
            frames: [.init(index: 0, segmentNumber: 0, pixelData: .binary([1]), segmentAttribution: .unattributed)])
        XCTAssertEqual(try parse(build(single)).frames[0].segmentAttribution, .inferredSingleSegment)
    }

    func test_fractionalThreshold_requiresExplicitInclusiveComparison() throws {
        let pixels = DicomSegmentationPixelData.fractional(values: [0, 1, 127, 128, 255], maximumFractionalValue: 255)
        XCTAssertEqual(pixels.binarized(threshold: 128, comparison: .greaterThanOrEqual), [0, 0, 0, 1, 1])
        XCTAssertEqual(pixels.binarized(threshold: 0), [1, 1, 1, 1, 1])
        let model = DicomSegmentation(segmentationType: .fractional, rows: 1, columns: 5,
            segments: [.init(number: 2, label: "Mask")],
            frames: [.init(index: 0, segmentNumber: 2, pixelData: pixels)])
        let mask = try XCTUnwrap(model.labelmapsBySegment[2])
        XCTAssertEqual(mask.fractionalVoxels, [0, 1, 127, 128, 255])
        XCTAssertEqual(mask.binarized(threshold: 128), [0, 0, 0, 2, 2])
    }

    func test_oddDimensions_packContiguouslyAcrossThreeFramesInBothDirections() throws {
        for (rows, columns) in [(3, 5), (7, 1)] {
            let count = rows * columns
            let values: [UInt8] = (0..<(3 * count)).map { $0 % 3 == 0 || $0 % 5 == 0 ? 1 : 0 }
            var expected = Data(repeating: 0, count: (values.count + 7) / 8)
            for (index, value) in values.enumerated() where value == 1 { expected[index / 8] |= 1 << (index % 8) }
            let model = DicomSegmentation(segmentationType: .binary, rows: rows, columns: columns,
                segments: [.init(number: 1, label: "Mask")], frames: (0..<3).map {
                    .init(index: $0, segmentNumber: 1, pixelData: .binary(Array(values[($0 * count)..<(($0 + 1) * count)])))
                })
            XCTAssertEqual(build(model)[0x7FE00010]?.value, .bytes(expected))
            let parsed = try XCTUnwrap(open(model).segmentation)
            XCTAssertEqual(parsed.frames.flatMap(\.pixelData.storedValues), values)
            // Decode independently supplied packed bytes, including non-byte-aligned frame starts.
            let dataSet = build(model).setting(.init(tag: 0x7FE00010, vr: .OB, value: .bytes(expected)))
            XCTAssertEqual(try parse(dataSet).frames.flatMap(\.pixelData.storedValues), values)
        }
    }

    func test_metadataAndSharedPlacement_roundTripWithoutSynthesizingReferences() throws {
        let code = DicomCodedConcept(codeValue: "123", codingSchemeDesignator: "99TEST", codeMeaning: "Synthetic")
        let reference = DicomSourceImageReference(referencedSOPClassUID: "1.2.3", referencedSOPInstanceUID: "2.25.1",
            referencedFrameNumbers: [3], derivationCode: code, purposeOfReferenceCode: code)
        let segment = DicomSegment(number: 1, label: "Mask", algorithmType: "AUTOMATIC", algorithmName: "Example",
            propertyType: code, algorithmIdentification: .init(name: "Example", version: "2", family: code, parameters: "a=1"),
            anatomicRegion: code, anatomicRegionModifiers: [code], propertyTypeModifiers: [code],
            recommendedDisplayGrayscaleValue: 45000)
        let groups = Set(DicomSegmentationFunctionalGroup.allCases)
        let model = DicomSegmentation(frameOfReferenceUID: "2.25.5", segmentationType: .binary, rows: 1, columns: 1,
            segments: [segment], frames: (0..<3).map {
                .init(index: $0, segmentNumber: 1, geometry: geometry(frameIndex: $0, z: Double($0 * 2 + 1), sourceReference: reference),
                      sourceImageReferences: [reference], pixelData: .binary([1]))
            }, segmentsOverlap: .no, contentLabel: "CUSTOM", contentDescription: "Description", contentCreatorName: "Creator",
            referencedInstancesBySeries: ["2.25.10": [.init(referencedSOPClassUID: "1.2.3",
                referencedSOPInstanceUID: "2.25.1", referencedFrameNumbers: [3])], "2.25.20": [
                .init(referencedSOPClassUID: "1.2.3", referencedSOPInstanceUID: "2.25.2")]], sharedFunctionalGroups: groups)
        let parsed = try parse(build(model))
        XCTAssertEqual(parsed.segments.first?.algorithmIdentification, segment.algorithmIdentification)
        XCTAssertEqual(parsed.segments.first?.anatomicRegion, code)
        XCTAssertEqual(parsed.segments.first?.anatomicRegionModifiers, [code])
        XCTAssertEqual(parsed.segments.first?.propertyTypeModifiers, [code])
        XCTAssertEqual(parsed.segments.first?.recommendedDisplayGrayscaleValue, 45000)
        XCTAssertEqual(parsed.contentLabel, "CUSTOM")
        XCTAssertEqual(parsed.contentDescription, "Description")
        XCTAssertEqual(parsed.contentCreatorName, "Creator")
        XCTAssertEqual(parsed.frameOfReferenceUID, "2.25.5")
        XCTAssertEqual(parsed.segmentsOverlap, .no)
        XCTAssertEqual(parsed.referencedInstancesBySeries["2.25.10"]?.first?.referencedSOPInstanceUID, "2.25.1")
        XCTAssertEqual(parsed.referencedInstancesBySeries["2.25.20"]?.first?.referencedSOPInstanceUID, "2.25.2")
        XCTAssertEqual(parsed.referencedInstancesBySeries, model.referencedInstancesBySeries)
        XCTAssertEqual(parsed.frames.first?.sourceImageReferences, [reference])
        XCTAssertEqual(parsed.sharedFunctionalGroups, groups)
        XCTAssertEqual(build(parsed)[0x52009229], build(model)[0x52009229])
        XCTAssertEqual(build(parsed)[0x52009230], build(model)[0x52009230])
        XCTAssertTrue(parsed.diagnostics.isEmpty)
    }

    func test_parserDiagnostics_keepUnattributedFramesAndReportEveryViolation() throws {
        let segments = [DicomSegment(number: 1, label: "One"), .init(number: 2, label: "Two"), .init(number: 3, label: "Unused")]
        let reference = DicomSourceImageReference(referencedSOPClassUID: "1.2.3", referencedSOPInstanceUID: "2.25.99")
        let model = DicomSegmentation(segmentationType: .fractional, maximumFractionalValue: 10, rows: 1, columns: 1,
            segments: segments, frames: [
                .init(index: 0, segmentNumber: 1, geometry: geometry(frameIndex: 0, z: 1, sourceReference: reference),
                      sourceImageReferences: [reference], pixelData: .fractional(values: [11], maximumFractionalValue: 10)),
                .init(index: 1, segmentNumber: 2, geometry: geometry(frameIndex: 1, z: 1, sourceReference: nil),
                      pixelData: .fractional(values: [1], maximumFractionalValue: 10)),
                .init(index: 2, segmentNumber: 0, pixelData: .fractional(values: [0], maximumFractionalValue: 10),
                      segmentAttribution: .unattributed)
            ], segmentsOverlap: .no, referencedInstancesBySeries: ["2.25.10": [
                .init(referencedSOPClassUID: "1.2.3", referencedSOPInstanceUID: "2.25.1")]])
        let parsed = try parse(build(model))
        XCTAssertEqual(parsed.frames.count, 3)
        XCTAssertEqual(parsed.frames[2].segmentAttribution, .unattributed)
        for code: DicomSegmentationDiagnostic.Code in [.frameWithoutSegment, .segmentWithoutFrames,
            .fractionalValueAboveMaximum, .referencedInstanceNotInReferencedSeries,
            .segmentsOverlapDeclaredNoButOverlapping, .frameGeometryMissing] {
            XCTAssertTrue(parsed.diagnostics.contains { $0.code == code }, code.rawValue)
        }
        XCTAssertTrue(parsed.diagnostics.allSatisfy { !$0.message.contains("2.25") })
        let labelmap = DicomSegmentation(segmentationType: .labelmap, rows: 1, columns: 1, segments: [segments[0]],
            frames: [.init(index: 0, segmentNumber: 0, pixelData: .labelmap([2]))])
        XCTAssertTrue(try parse(build(labelmap)).diagnostics.contains { $0.code == .labelmapValueWithoutSegment })
        let unknown = build(model).setting(.init(tag: 0x00620001, vr: .CS, value: .strings(["INVALID"])))
        let unrecognized = try parse(unknown)
        XCTAssertEqual(unrecognized.segmentationType, .unknown)
        XCTAssertTrue(unrecognized.diagnostics.contains { $0.code == .unknownSegmentationType })
    }

    func test_binaryOverlapDiagnostic_requiresNoDeclarationAndCoincidentSetPixels() throws {
        for overlap: DicomSegmentsOverlap? in [.no, .yes, .undefined, nil] {
            for coincident in [true, false] {
                let model = DicomSegmentation(segmentationType: .binary, rows: 1, columns: 1,
                    segments: [.init(number: 1, label: "One"), .init(number: 2, label: "Two")], frames: [
                        .init(index: 0, segmentNumber: 1, geometry: geometry(frameIndex: 0, z: 1, sourceReference: nil),
                              pixelData: .binary([1])),
                        .init(index: 1, segmentNumber: 2,
                              geometry: geometry(frameIndex: 1, z: coincident ? 1 : 3, sourceReference: nil),
                              pixelData: .binary([1]))
                    ], segmentsOverlap: overlap)
                XCTAssertEqual(try parse(build(model)).diagnostics.contains {
                    $0.code == .segmentsOverlapDeclaredNoButOverlapping
                }, overlap == .no && coincident)
            }
        }
    }

    private func build(_ model: DicomSegmentation) -> DicomDataSet {
        DicomSegmentationBuilder.dataSet(from: model, studyInstanceUID: "2.25.100", seriesInstanceUID: "2.25.101")
    }

    private func parse(_ dataSet: DicomDataSet) throws -> DicomSegmentation {
        let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
        return try XCTUnwrap(DCMDecoder(data: bytes).segmentation)
    }

    private func open(
        _ segmentation: DicomSegmentation,
        transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian
    ) throws -> DCMDecoder {
        let dataSet = DicomSegmentationBuilder.dataSet(
            from: segmentation,
            studyInstanceUID: "2.25.9401",
            seriesInstanceUID: "2.25.9402"
        )
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: dataSet[0x00080016]?.stringValue,
                mediaStorageSOPInstanceUID: segmentation.sopInstanceUID
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("segmentation_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func geometry(
        frameIndex: Int,
        z: Double,
        sourceReference: DicomSourceImageReference?
    ) -> DicomFrameGeometry {
        let derivationImage = sourceReference.map { DicomDerivationImage(sourceImages: [$0]) }
        return DicomFrameGeometry(
            frameIndex: frameIndex,
            functionalGroups: DicomFrameFunctionalGroups(
                frameContent: DicomFrameContent(
                    dimensionIndexValues: [frameIndex + 1],
                    stackID: "SEG",
                    inStackPositionNumber: frameIndex + 1,
                    temporalPositionIndex: nil,
                    frameAcquisitionNumber: nil
                ),
                pixelMeasures: DicomPixelMeasures(
                    pixelSpacing: SIMD2<Double>(0.7, 0.8),
                    sliceThickness: 1.5,
                    spacingBetweenSlices: 1.5
                ),
                planePosition: DicomPlanePosition(imagePositionPatient: SIMD3<Double>(0, 0, z)),
                planeOrientation: DicomPlaneOrientation(
                    row: SIMD3<Double>(1, 0, 0),
                    column: SIMD3<Double>(0, 1, 0)
                ),
                derivationImage: derivationImage
            )
        )!
    }
}
