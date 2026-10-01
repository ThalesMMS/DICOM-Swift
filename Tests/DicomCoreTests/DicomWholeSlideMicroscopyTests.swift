import XCTest
@testable import DicomCore

final class DicomWholeSlideMicroscopyTests: XCTestCase {
    func test_metadataModelsExplicitTilesPathsAndFocalPlanesWithoutDecodingPixels() throws {
        let decoder = try DCMDecoder(data: DicomDataSetWriter.part10Data(
            from: fixture(),
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DCMDecoder.wholeSlideMicroscopyImageStorageSOPClassUID
            )
        ))

        let metadata = try XCTUnwrap(decoder.wholeSlideMicroscopyMetadata)
        XCTAssertTrue(decoder.pixelsNotLoaded)
        XCTAssertEqual(metadata.matrixWidth, 1_024)
        XCTAssertEqual(metadata.matrixHeight, 1_024)
        XCTAssertEqual(metadata.tileWidth, 512)
        XCTAssertEqual(metadata.tileHeight, 512)
        XCTAssertEqual(metadata.opticalPaths.map(\.identifier), ["H&E", "IHC"])
        XCTAssertEqual(metadata.focalPlaneOffsetsMillimeters, [1.0, 1.002])
        XCTAssertEqual(metadata.pixelSpacingXMillimeters, 0.0005)
        XCTAssertEqual(metadata.pixelSpacingYMillimeters, 0.00075)
        XCTAssertEqual(metadata.tiles.count, 3)
        XCTAssertEqual(metadata.tiles[1].column, 512)
        XCTAssertEqual(metadata.tiles[2].row, 512)
        XCTAssertEqual(metadata.tiles[2].opticalPathIdentifier, "IHC")
        XCTAssertEqual(metadata.tiles[2].focalPlaneIndex, 1)
    }

    func test_nonMicroscopyObject_returnsNil() throws {
        let dataSet = DicomDataSet(elements: [
            string(DicomTag.sopClassUID.rawValue, .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            unsigned(DicomTag.rows.rawValue, .US, 1),
            unsigned(DicomTag.columns.rawValue, .US, 1),
            unsigned(DicomTag.bitsAllocated.rawValue, .US, 8),
            unsigned(DicomTag.bitsStored.rawValue, .US, 8),
            unsigned(DicomTag.highBit.rawValue, .US, 7),
            unsigned(DicomTag.pixelRepresentation.rawValue, .US, 0),
            unsigned(DicomTag.samplesPerPixel.rawValue, .US, 1),
            string(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data([0])))
        ])
        let decoder = try DCMDecoder(data: DicomDataSetWriter.part10Data(from: dataSet))

        XCTAssertNil(decoder.wholeSlideMicroscopyMetadata)
    }

    func test_absentOrganizationWithoutPositions_reportsUnpositionedFrames() throws {
        var elements = fixture().elements.filter { $0.tag != 0x5200_9230 }
        elements.removeAll { $0.tag == DicomTag.numberOfFrames.rawValue }
        elements.removeAll { $0.tag == 0x0048_0303 }
        elements.append(string(DicomTag.numberOfFrames.rawValue, .IS, "8"))
        elements.append(unsigned(0x0048_0303, .UL, 1))
        elements.append(sequence(0x5200_9230, Array(repeating: DicomDataSet(), count: 8)))
        let dataSet = DicomDataSet(elements: elements)
        let decoder = try DCMDecoder(data: DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DCMDecoder.wholeSlideMicroscopyImageStorageSOPClassUID
            )
        ))

        let metadata = try XCTUnwrap(decoder.wholeSlideMicroscopyMetadata)
        XCTAssertTrue(metadata.tiles.isEmpty)
        XCTAssertEqual(metadata.unpositionedFrameIndices, Array(0..<8))
        XCTAssertEqual(metadata.dimensionOrganizationType, .absent)
        XCTAssertTrue(decoder.pixelsNotLoaded)
    }

    func test_sparseMissingPerFrameItems_reportsOneMismatchWithoutEnumeratingDeclaredFrames() throws {
        for data in [fixture().removing(0x5200_9230), fixture()] {
            let malformed = replacing(data, [string(0x0028_0008, .IS, "10000")])
            let metadata = try decode(malformed)
            XCTAssertTrue(metadata.tiles.isEmpty)
            XCTAssertTrue(metadata.unpositionedFrameIndices.isEmpty)
            XCTAssertEqual(metadata.diagnostics.filter { $0.code == .frameCountMismatch }.count, 1)
        }
    }

    func test_opticalPathDiagnostic_identifiesActualSequenceItem() throws {
        let base = fixture()
        let original = try XCTUnwrap(base.sequenceItems(for: 0x5200_9230).first?.dataSet)
        let paths = sequence(0x0048_0207, [
            .init(elements: [string(0x0048_0106, .SH, "H&E")]),
            .init(elements: [string(0x0048_0106, .SH, "missing")])
        ])
        let changed = replacing(base, [sequence(0x5200_9230, [replacing(original, [paths])])])
        let report = DicomEnhancedImageModules.validate(changed, profile: .vlWholeSlideMicroscopy)
        XCTAssertTrue(report.diagnostics.contains {
            $0.code == .attributeValueContradiction && $0.path == [
                .tag(0x5200_9230), .item(0), .tag(0x0048_0207), .item(1), .tag(0x0048_0106)
            ]
        })
    }

    func test_tiledFull_fiveByThreeTwoPlanesTwoPaths_matchesNormativeMapping() throws {
        let metadata = try decode(fullFixture())
        XCTAssertEqual(metadata.tiles.count, 60)
        XCTAssertTrue(metadata.diagnostics.isEmpty)
        // Explicit spatial oracle; columns/rows here are zero-based tile origins.
        let spatial = [(0, 0), (512, 0), (1024, 0), (1536, 0), (2048, 0),
                       (0, 512), (512, 512), (1024, 512), (1536, 512), (2048, 512),
                       (0, 1024), (512, 1024), (1024, 1024), (1536, 1024), (2048, 1024)]
        // Normative block table: frames 1–15 H&E/Z0; 16–30 H&E/Z1; 31–45 IHC/Z0; 46–60 IHC/Z1.
        let blocks = [(0, "H&E", 0), (15, "H&E", 1), (30, "IHC", 0), (45, "IHC", 1)]
        for (start, path, plane) in blocks {
            for (ordinal, expected) in spatial.enumerated() {
                let tile = metadata.tiles[start + ordinal]
                XCTAssertEqual(tile.frameIndex, start + ordinal)
                XCTAssertEqual(tile.column, expected.0)
                XCTAssertEqual(tile.row, expected.1)
                XCTAssertEqual(tile.focalPlaneIndex, plane)
                XCTAssertEqual(tile.opticalPathIdentifier, path)
                XCTAssertEqual(tile.zOffsetMillimeters, plane == 0 ? 1 : 1.002)
                XCTAssertEqual(try XCTUnwrap(tile.xOffsetMillimeters), 10 + Double(expected.0) * 0.0005, accuracy: 1e-10)
                XCTAssertEqual(try XCTUnwrap(tile.yOffsetMillimeters), 20 + Double(expected.1) * 0.00075, accuracy: 1e-10)
            }
        }
        XCTAssertEqual(metadata.tiles[14].width, 2)
        XCTAssertEqual(metadata.tiles[14].height, 1)
    }

    func test_tiledFull_frameCountMismatch_hasNoImplicitPositions() throws {
        let metadata = try decode(replacing(fullFixture(), [string(0x0028_0008, .IS, "59")]))
        XCTAssertTrue(metadata.tiles.isEmpty)
        XCTAssertTrue(metadata.unpositionedFrameIndices.isEmpty)
        XCTAssertTrue(metadata.diagnostics.contains { $0.code == .frameCountMismatch })
    }

    func test_concatenation_usesGlobalFrameOffset() throws {
        let metadata = try decode(replacing(fullFixture(), [
            string(0x0028_0008, .IS, "15"), string(0x0020_9161, .UI, "2.25.123"),
            unsigned(0x0020_9162, .US, 3), unsigned(0x0020_9163, .US, 4), unsigned(0x0020_9228, .UL, 30)
        ]))
        XCTAssertEqual(metadata.tiles.count, 15)
        XCTAssertEqual(metadata.tiles.first?.opticalPathIdentifier, "IHC")
        XCTAssertEqual(metadata.tiles.first?.focalPlaneIndex, 0)
        XCTAssertEqual(metadata.concatenation?.frameOffsetNumber, 30)
        XCTAssertTrue(metadata.diagnostics.contains { $0.code == .concatenationCoverageUnverified })
    }

    func test_sparse_outOfOrderOverlapAndInvalidFrames_useOnlyAttributes() throws {
        let metadata = try decode(replacing(fixture(), [
            string(0x0020_9311, .CS, "TILED_SPARSE"), string(0x0028_0008, .IS, "6"),
            sequence(0x5200_9230, [
                frame(column: 513, row: 513, path: "IHC", z: 1.002),
                frame(column: 1, row: 1, path: "H&E", z: 1),
                frame(column: 257, row: 1, path: "H&E", z: 1),
                frame(column: 1025, row: 1, path: "H&E", z: 1),
                frame(column: 1, row: 1, path: "UNKNOWN", z: 1), DicomDataSet()
            ])
        ]))
        XCTAssertEqual(metadata.tiles.map(\.frameIndex), [0, 1, 2])
        XCTAssertEqual(metadata.tiles[0].column, 512)
        XCTAssertEqual(metadata.tiles[0].row, 512)
        XCTAssertEqual(metadata.tiles[0].focalPlaneIndex, 1)
        XCTAssertEqual(metadata.tiles[0].xOffsetMillimeters, 4)
        XCTAssertEqual(metadata.unpositionedFrameIndices, [3, 4, 5])
        XCTAssertTrue(metadata.tilesOverlapObserved)
        XCTAssertTrue(metadata.diagnostics.contains { $0.code == .positionOutsideMatrix })
        XCTAssertTrue(metadata.diagnostics.contains { $0.code == .opticalPathMismatch })
        XCTAssertTrue(metadata.diagnostics.contains { $0.code == .framePositionMissing && $0.frameIndex == 5 })
        XCTAssertTrue(metadata.diagnostics.contains { $0.code == .opticalPathIdentificationMissing && $0.frameIndex == 5 })
    }

    func test_opticalPathAndSpecimenHierarchy_roundTrip() throws {
        let code = DicomDataSet(elements: [string(0x0008_0100, .SH, "111741"),
            string(0x0008_0102, .SH, "DCM"), string(0x0008_0104, .LO, "Transmission illumination")])
        let issuer = DicomDataSet(elements: [string(0x0040_0031, .UT, "LAB"),
            string(0x0040_0032, .UT, "2.25.45"), string(0x0040_0033, .CS, "ISO")])
        let preparation = DicomDataSet(elements: [sequence(0x0040_0612, [
            DicomDataSet(elements: [string(0x0040_A040, .CS, "CODE"), sequence(0x0040_A043, [code]), sequence(0x0040_A168, [code])]),
            DicomDataSet(elements: [string(0x0040_A040, .CS, "TEXT"), sequence(0x0040_A043, [code]), string(0x0040_A160, .UT, "Synthetic preparation")])
        ])])
        let specimen = DicomDataSet(elements: [string(0x0040_0551, .LO, "SAMPLE"), string(0x0040_0554, .UI, "2.25.46"),
            sequence(0x0040_0562, [issuer]), string(0x0040_0600, .LO, "Short"), string(0x0040_0602, .UT, "Detailed"),
            sequence(0x0040_0610, [preparation])])
        let metadata = try decode(replacing(fixture(), [
            string(0x0040_0512, .LO, "CONTAINER"), sequence(0x0040_0513, [issuer]), sequence(0x0040_0518, [code]),
            sequence(0x0040_0560, [specimen, specimen]),
            sequence(0x0048_0105, [DicomDataSet(elements: [
                string(0x0048_0106, .SH, "H&E"), string(0x0048_0107, .ST, "Synthetic path"),
                sequence(0x0022_0016, [code, code]), sequence(0x0048_0108, [code]),
                strings(0x0022_0055, .FL, ["550"]), sequence(0x0022_0017, [code]), sequence(0x0022_0018, [code]),
                strings(0x0048_0112, .DS, ["40"]), strings(0x0048_0113, .DS, ["0.95"]),
                DicomDataElement(tag: 0x0028_2000, vr: .OB, value: .bytes(Data([1, 2, 3, 4]))),
                string(0x0028_2002, .CS, "SRGB"), sequence(0x0048_0120, [DicomDataSet()])
            ])])
        ]))
        let path = try XCTUnwrap(metadata.opticalPaths.first)
        XCTAssertEqual(path.iccProfile, Data([1, 2, 3, 4]))
        XCTAssertEqual(path.illuminationTypeCodes.count, 2)
        XCTAssertEqual(path.illuminationColorCode?.codeValue, "111741")
        XCTAssertEqual(path.illuminationWavelengthNanometers, 550)
        XCTAssertEqual(path.lightPathFilterTypeStackCodes.count, 1)
        XCTAssertEqual(path.imagePathFilterTypeStackCodes.count, 1)
        XCTAssertEqual(path.objectiveLensPower, 40)
        XCTAssertEqual(path.objectiveLensNumericalAperture, 0.95)
        XCTAssertEqual(path.colorSpace, "SRGB")
        XCTAssertTrue(path.palettePresent)
        XCTAssertEqual(metadata.specimen?.issuer?.localNamespaceEntityID, "LAB")
        XCTAssertEqual(metadata.specimen?.containerTypeCode?.codeValue, "111741")
        XCTAssertEqual(metadata.specimen?.specimens.count, 2)
        let description = try XCTUnwrap(metadata.specimen?.specimens.first)
        XCTAssertEqual(description.identifier, "SAMPLE")
        XCTAssertEqual(description.uid, "2.25.46")
        XCTAssertEqual(description.issuer?.universalEntityID, "2.25.45")
        XCTAssertEqual(description.shortDescription, "Short")
        XCTAssertEqual(description.detailedDescription, "Detailed")
        XCTAssertEqual(description.preparationSteps[0][0].codedValue?.codeValue, "111741")
        XCTAssertEqual(description.preparationSteps[0][1].textValue, "Synthetic preparation")
    }

    func test_completedMetadataFields_preserveValuesAndUnits() throws {
        let metadata = try decode(replacing(fullFixture(), [
            string(0x0008_0019, .UI, "2.25.19"), string(0x0020_000E, .UI, "2.25.20"),
            string(0x0020_0052, .UI, "2.25.52"),
            strings(0x0048_0001, .FL, ["1.025"]), strings(0x0048_0002, .FL, ["0.76875"]),
            strings(0x0048_0003, .FL, ["10"]), string(0x0048_0012, .CS, "YES"),
            unsigned(0x0048_0013, .US, 9), strings(0x0048_0014, .DS, ["5"]),
            string(0x0048_0011, .CS, "AUTO"), string(0x0048_0304, .CS, "NONE"),
            DicomDataElement(tag: 0x0048_0015, vr: .US, value: .unsignedIntegers([10, 20, 30])),
            string(0x0028_2110, .CS, "01"), strings(0x0028_2112, .DS, ["10", "20"]),
            strings(0x0028_2114, .CS, ["ISO_10918_1", "ISO_15444_1"]),
            string(0x0048_0010, .CS, "NO"), string(0x0028_0301, .CS, "NO"),
            string(0x0008_9206, .CS, "VOLUME"), string(0x2200_0005, .LT, "SYNTHETIC"),
            string(0x2200_0002, .LT, "Synthetic label"),
            sequence(0x5200_9229, [DicomDataSet(elements: [
                sequence(0x0040_0710, [DicomDataSet(elements: [strings(0x0008_9007, .CS, ["ORIGINAL", "PRIMARY", "VOLUME", "NONE"])])]),
                sequence(0x0028_9110, [DicomDataSet(elements: [strings(0x0028_0030, .DS, ["0.00075", "0.0005"]),
                    strings(0x0018_0088, .DS, ["0.002"]), strings(0x0018_0050, .DS, ["0.01"])])])
            ])])
        ]))
        XCTAssertEqual(metadata.pyramidUID, "2.25.19")
        XCTAssertEqual(metadata.seriesUID, "2.25.20")
        XCTAssertEqual(metadata.frameOfReferenceUID, "2.25.52")
        XCTAssertEqual(metadata.imageType.flavor, .volume)
        XCTAssertEqual(metadata.imageType.derivedPixels, DicomWholeSlideImageType.DerivedPixels.none)
        XCTAssertEqual(metadata.frameType, metadata.imageType)
        XCTAssertEqual(metadata.totalPixelMatrixOrigin?.zMicrometers, 1000)
        XCTAssertEqual(metadata.imagedVolume?.depthMicrometers, 10)
        XCTAssertEqual(metadata.totalPixelMatrixFocalPlanes, 2)
        XCTAssertEqual(metadata.focalPlaneOffsetsMillimeters, [1, 1.002])
        XCTAssertEqual(metadata.tiles.count, 60) // Nine acquisition planes do not create nine encoded planes.
        XCTAssertEqual(metadata.numberOfFocalPlanes, 9)
        XCTAssertEqual(metadata.distanceBetweenFocalPlanesMicrometers, 5)
        XCTAssertEqual(metadata.extendedDepthOfField, "YES")
        XCTAssertEqual(metadata.focusMethod, "AUTO")
        XCTAssertEqual(metadata.tilesOverlap, "NONE")
        XCTAssertEqual(metadata.recommendedAbsentPixelCIELab, [10, 20, 30])
        XCTAssertEqual(metadata.lossyImageCompression, "01")
        XCTAssertEqual(metadata.lossyImageCompressionRatios, [10, 20])
        XCTAssertEqual(metadata.lossyImageCompressionMethods, ["ISO_10918_1", "ISO_15444_1"])
        XCTAssertEqual(metadata.specimenLabelInImage, "NO")
        XCTAssertEqual(metadata.burnedInAnnotation, "NO")
        XCTAssertEqual(metadata.volumetricProperties, "VOLUME")
        XCTAssertEqual(metadata.photometricInterpretation, "RGB")
        XCTAssertEqual(metadata.samplesPerPixel, 3)
        XCTAssertEqual(metadata.bitsAllocated, 8)
        XCTAssertEqual(metadata.planarConfiguration, 0)
        XCTAssertEqual(metadata.sliceThickness, 0.01)
        XCTAssertEqual(metadata.slideLabel?.barcodeValue, "SYNTHETIC")
        XCTAssertEqual(metadata.slideLabel?.labelText, "Synthetic label")
    }

    func test_tiledFullAuxiliary_singleFrameDoesNotRequireFullMatrixCoverage() throws {
        let metadata = try decode(replacing(fullFixture(), [string(0x0028_0008, .IS, "1"),
            strings(0x0008_0008, .CS, ["ORIGINAL", "PRIMARY", "LABEL", "NONE"])]))
        XCTAssertEqual(metadata.tiles.count, 1)
        XCTAssertFalse(metadata.diagnostics.contains { $0.code == .frameCountMismatch })
    }

    func test_unknownDimensionAndImageType_retainRawValues() {
        XCTAssertEqual(DicomDimensionOrganizationType(rawValue: "CUSTOM"), .other("CUSTOM"))
        XCTAssertEqual(DicomDimensionOrganizationType(rawValue: "3D"), .threeDimensional)
        XCTAssertEqual(DicomDimensionOrganizationType(rawValue: "3D_TEMPORAL"), .threeDimensionalTemporal)
        let type = DicomWholeSlideImageType(rawValues: ["DERIVED", "PRIMARY", "CUSTOM", "CUSTOM"])
        XCTAssertNil(type.flavor)
        XCTAssertNil(type.derivedPixels)
        XCTAssertEqual(type.rawValues[2], "CUSTOM")
    }

    private func decode(_ dataSet: DicomDataSet) throws -> DicomWholeSlideMicroscopyMetadata {
        let decoder = try DCMDecoder(data: DicomDataSetWriter.part10Data(from: dataSet,
            options: .init(mediaStorageSOPClassUID: DCMDecoder.wholeSlideMicroscopyImageStorageSOPClassUID)))
        return try XCTUnwrap(decoder.wholeSlideMicroscopyMetadata)
    }

    private func replacing(_ dataSet: DicomDataSet, _ elements: [DicomDataElement]) -> DicomDataSet {
        DicomDataSet(elements: dataSet.elements.filter { old in !elements.contains { $0.tag == old.tag } } + elements)
    }

    private func fullFixture() -> DicomDataSet {
        let dataSet = replacing(fixture(), [
            unsigned(0x0048_0006, .UL, 2050), unsigned(0x0048_0007, .UL, 1025),
            string(0x0028_0008, .IS, "60"), string(0x0020_9311, .CS, "TILED_FULL"),
            strings(0x0008_0008, .CS, ["ORIGINAL", "PRIMARY", "VOLUME", "NONE"]),
            strings(0x0048_0102, .DS, ["1", "0", "0", "0", "1", "0"]),
            sequence(0x0048_0008, [DicomDataSet(elements: [strings(0x0040_072A, .DS, ["10"]),
                strings(0x0040_073A, .DS, ["20"]), strings(0x0040_074A, .DS, ["1000"])])]),
            sequence(0x5200_9229, [DicomDataSet(elements: [sequence(0x0028_9110, [DicomDataSet(elements: [
                strings(0x0028_0030, .DS, ["0.00075", "0.0005"]), strings(0x0018_0088, .DS, ["0.002"])
            ])])])])
        ])
        return DicomDataSet(elements: dataSet.elements.filter { $0.tag != 0x5200_9230 })
    }

    private func fixture() -> DicomDataSet {
        let paths = sequence(0x0048_0105, [
            DicomDataSet(elements: [string(0x0048_0106, .SH, "H&E"), string(0x0048_0107, .ST, "Brightfield")]),
            DicomDataSet(elements: [string(0x0048_0106, .SH, "IHC"), string(0x0048_0107, .ST, "Fluorescence")])
        ])
        let shared = sequence(0x5200_9229, [
            DicomDataSet(elements: [
                sequence(0x0028_9110, [DicomDataSet(elements: [strings(0x0028_0030, .DS, ["0.00075", "0.0005"])])])
            ])
        ])
        let origin = sequence(0x0048_0008, [
            DicomDataSet(elements: [strings(0x0040_074A, .DS, ["1000"])])
        ])
        let frames = sequence(0x5200_9230, [
            frame(column: 1, row: 1, path: "H&E", z: 1.0),
            frame(column: 513, row: 1, path: "H&E", z: 1.0),
            frame(column: 1, row: 513, path: "IHC", z: 1.002)
        ])
        return DicomDataSet(elements: [
            string(DicomTag.sopClassUID.rawValue, .UI, DCMDecoder.wholeSlideMicroscopyImageStorageSOPClassUID),
            string(DicomTag.sopInstanceUID.rawValue, .UI, "2.25.1943"),
            unsigned(0x0048_0006, .UL, 1_024),
            unsigned(0x0048_0007, .UL, 1_024),
            unsigned(DicomTag.rows.rawValue, .US, 512),
            unsigned(DicomTag.columns.rawValue, .US, 512),
            string(DicomTag.numberOfFrames.rawValue, .IS, "3"),
            unsigned(DicomTag.samplesPerPixel.rawValue, .US, 3),
            string(DicomTag.photometricInterpretation.rawValue, .CS, "RGB"),
            unsigned(DicomTag.planarConfiguration.rawValue, .US, 0),
            unsigned(DicomTag.bitsAllocated.rawValue, .US, 8),
            unsigned(DicomTag.bitsStored.rawValue, .US, 8),
            unsigned(DicomTag.highBit.rawValue, .US, 7),
            unsigned(DicomTag.pixelRepresentation.rawValue, .US, 0),
            unsigned(0x0048_0303, .UL, 2),
            strings(0x0048_0014, .DS, ["0.002"]),
            paths,
            shared,
            origin,
            frames,
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data(repeating: 0, count: 36)))
        ])
    }

    private func frame(column: UInt, row: UInt, path: String, z: Double) -> DicomDataSet {
        DicomDataSet(elements: [
            sequence(0x0048_021A, [DicomDataSet(elements: [
                unsigned(0x0048_021E, .UL, column),
                unsigned(0x0048_021F, .UL, row),
                strings(0x0040_072A, .DS, ["4"]),
                strings(0x0040_073A, .DS, ["8"]),
                strings(0x0040_074A, .DS, [String(z * 1000)])
            ])]),
            sequence(0x0048_0207, [DicomDataSet(elements: [string(0x0048_0106, .SH, path)])])
        ])
    }

    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: .SQ, value: .sequence(items.map(DicomSequenceItem.init(dataSet:))))
    }

    private func string(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        strings(tag, vr, [value])
    }

    private func strings(_ tag: Int, _ vr: DicomVR, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings(values))
    }

    private func unsigned(_ tag: Int, _ vr: DicomVR, _ value: UInt) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .unsignedIntegers([value]))
    }
}
