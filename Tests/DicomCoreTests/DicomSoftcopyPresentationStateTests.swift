import Foundation
import XCTest
@testable import DicomCore

final class DicomSoftcopyPresentationStateTests: XCTestCase {
    func test_blendingBuilder_rejectsInvalidCardinalityWithoutRequiringConditionalColorModules() throws {
        let item = DicomPresentationBlendingItem(position: .underlying, studyInstanceUID: "2.25.1",
                                                referencedSeries: [])
        for count in [0, 1, 3] {
            XCTAssertThrowsError(try DicomGrayscalePresentationStateBuilder.dataSet(
                referencedSeries: [], graphicAnnotations: [],
                options: .init(kind: .blending, blendingItems: .init(repeating: item, count: count)))) {
                XCTAssertEqual($0 as? DicomGrayscalePresentationStateBuilder.BuildError, .invalidBlendingItemCount(count))
            }
        }
        let dataSet = try DicomGrayscalePresentationStateBuilder.dataSet(
            referencedSeries: [], graphicAnnotations: [],
            options: .init(kind: .blending, blendingItems: [item, .init(position: .superimposed,
                studyInstanceUID: "2.25.1", referencedSeries: [])], relativeOpacity: 0.5))
        XCTAssertEqual(dataSet.sequenceItems(for: .blendingSequence).count, 2)
        XCTAssertNil(dataSet.element(for: .iccProfile))
        XCTAssertNil(dataSet.element(for: .redPalette))
    }

    func test_blendingBuilder_rejectsDuplicatePositions() {
        for position in [DicomPresentationBlendingItem.Position.underlying, .superimposed] {
            let item = DicomPresentationBlendingItem(position: position, studyInstanceUID: "2.25.1",
                                                    referencedSeries: [])
            XCTAssertThrowsError(try DicomGrayscalePresentationStateBuilder.dataSet(
                referencedSeries: [], graphicAnnotations: [],
                options: .init(kind: .blending, blendingItems: [item, item], relativeOpacity: 0.5)
            )) {
                XCTAssertEqual($0 as? DicomGrayscalePresentationStateBuilder.BuildError, .invalidBlendingPositions)
            }
        }
    }

    func test_blendingBuilder_rejectsMissingNonfiniteAndOutOfRangeOpacity() {
        let items = [DicomPresentationBlendingItem.Position.underlying, .superimposed].map {
            DicomPresentationBlendingItem(position: $0, studyInstanceUID: "2.25.1", referencedSeries: [])
        }
        for opacity: Double? in [nil, .nan, .infinity, -.infinity, -0.1, 1.1] {
            XCTAssertThrowsError(try DicomGrayscalePresentationStateBuilder.dataSet(
                referencedSeries: [], graphicAnnotations: [],
                options: .init(kind: .blending, blendingItems: items, relativeOpacity: opacity)
            )) {
                XCTAssertEqual($0 as? DicomGrayscalePresentationStateBuilder.BuildError, .invalidRelativeOpacity)
            }
        }
    }

    func test_blendingBuilder_rejectsEmptyAndWhitespaceStudyUIDs() {
        let positions = [DicomPresentationBlendingItem.Position.underlying, .superimposed]
        for invalidPosition in positions {
            for uid in ["", " \t\n\0"] {
                let items = positions.map {
                    DicomPresentationBlendingItem(position: $0,
                        studyInstanceUID: $0 == invalidPosition ? uid : "2.25.1", referencedSeries: [])
                }
                XCTAssertThrowsError(try DicomGrayscalePresentationStateBuilder.dataSet(
                    referencedSeries: [], graphicAnnotations: [],
                    options: .init(kind: .blending, blendingItems: items, relativeOpacity: 0.5)
                )) {
                    XCTAssertEqual($0 as? DICOMError, .missingRequiredTag(tag: "0020,000D", description: "Study Instance UID"))
                }
            }
        }
    }

    func test_blendingBuilder_normalizesPaddedStudyUIDs() throws {
        let items = [DicomPresentationBlendingItem.Position.underlying, .superimposed].map {
            DicomPresentationBlendingItem(position: $0, studyInstanceUID: " \t2.25.1\n\0", referencedSeries: [])
        }
        let dataSet = try DicomGrayscalePresentationStateBuilder.dataSet(
            referencedSeries: [], graphicAnnotations: [],
            options: .init(kind: .blending, blendingItems: items, relativeOpacity: 0.5))
        XCTAssertEqual(dataSet.sequenceItems(for: .blendingSequence).map {
            $0.dataSet.string(for: .studyInstanceUID)
        }, ["2.25.1", "2.25.1"])
    }

    func test_blendingParser_discardsBlankStudyUIDsAndNormalizesPaddedValues() throws {
        let items = [DicomPresentationBlendingItem.Position.underlying, .superimposed].map {
            DicomPresentationBlendingItem(position: $0,
                studyInstanceUID: $0 == .underlying ? "2.25.123" : "2.25.1", referencedSeries: [])
        }
        let original = try DicomGrayscalePresentationStateBuilder.part10Data(
            referencedSeries: [], graphicAnnotations: [],
            options: .init(kind: .blending, blendingItems: items, relativeOpacity: 0.5))
        let encodedUID = Data([0x20, 0, 0x0D, 0, 0x55, 0x49, 8, 0]) + Data("2.25.123".utf8)
        let element = try XCTUnwrap(original.range(of: encodedUID))
        let valueRange = (element.upperBound - 8)..<element.upperBound
        for uid in ["\0\0\0\0\0\0\0\0", " \t\n\0 \r  ", " 2.25.2 "] {
            var bytes = original
            XCTAssertEqual(uid.utf8.count, valueRange.count)
            bytes.replaceSubrange(valueRange, with: uid.utf8)
            let state = try XCTUnwrap(try DCMDecoder(data: bytes).grayscalePresentationState)
            XCTAssertEqual(state.blendingItems.map(\.studyInstanceUID),
                           uid.contains("2.25.2") ? ["2.25.2", "2.25.1"] : ["2.25.1"])
            XCTAssertEqual(state.blendingItems.last?.position, .superimposed)
        }
    }

    func test_blendingBuilder_acceptsEitherOrderAndOpacityEndpoints() throws {
        let items = [DicomPresentationBlendingItem.Position.underlying, .superimposed].map {
            DicomPresentationBlendingItem(position: $0, studyInstanceUID: "2.25.1", referencedSeries: [])
        }
        for orderedItems in [items, Array(items.reversed())] {
            for opacity in [0.0, 0.5, 1.0] {
                let dataSet = try DicomGrayscalePresentationStateBuilder.dataSet(
                    referencedSeries: [], graphicAnnotations: [],
                    options: .init(kind: .blending, blendingItems: orderedItems, relativeOpacity: opacity)
                )
                XCTAssertEqual(dataSet.sequenceItems(for: .blendingSequence).map {
                    $0.dataSet.string(for: .blendingPosition)
                }, orderedItems.map { $0.position.rawValue })
                XCTAssertEqual(dataSet.element(for: .relativeOpacity)?.floatValue, opacity)
            }
        }
    }

    func test_blendingBuilder_roundTripsIndependentModalityAndVOITransforms() throws {
        let references = try [DicomPresentationReferencedSeries(seriesInstanceUID: "2.25.2", images: [
            DicomPresentationReferencedImage(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                                             referencedSOPInstanceUID: "2.25.3")
        ])]
        let descriptor = try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: 3, firstMappedValue: 0, bitsPerEntry: 16))
        let modality = DicomLookupTable(descriptor: descriptor, explanation: "Modality", lutType: "HU", data: [1, 2, 3])
        let voi = DicomLookupTable(descriptor: descriptor, explanation: "VOI", lutType: nil, data: [0, 32000, 65535])
        let profiles = [
            DicomDisplayTransformProfile(rescaleParameters: .init(intercept: -1024, slope: 2), rescaleType: "HU",
                windows: [.init(settings: .init(center: 40, width: 400), explanation: "Soft tissue", source: .dicom(index: 0))]),
            DicomDisplayTransformProfile(modalityLUTs: [modality], voiLUTs: [voi])
        ]
        var items = zip([DicomPresentationBlendingItem.Position.underlying, .superimposed], profiles).map {
            DicomPresentationBlendingItem(position: $0, studyInstanceUID: "2.25.1", referencedSeries: references,
                displayTransformProfile: $1, voiSelections: [.init(referencedImages: references[0].images,
                                                                    displayTransformProfile: $1)])
        }
        for _ in 0..<2 {
            let data = try DicomGrayscalePresentationStateBuilder.part10Data(
                referencedSeries: references, graphicAnnotations: [],
                options: .init(kind: .blending, blendingItems: items, relativeOpacity: 0.5))
            let state = try XCTUnwrap(try DCMDecoder(data: data).grayscalePresentationState)
            XCTAssertEqual(state.blendingItems, items)
            items = state.blendingItems
        }
    }

    func test_presentationLUT_roundTripsPackedEightBitAndReadsLegacyWords() throws {
        for count in [3, 4] {
            let entries = Array([UInt16(0), 64, 128, 255].prefix(count))
            let descriptor = try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: count, firstMappedValue: 0, bitsPerEntry: 8))
            let lut = DicomLookupTable(descriptor: descriptor, explanation: nil, lutType: nil, data: entries)
            let dataSet = try DicomGrayscalePresentationStateBuilder.dataSet(
                referencedSeries: [], graphicAnnotations: [], options: .init(displayTransformProfile: .init(presentationLUT: lut)))
            let packed = try XCTUnwrap(dataSet.sequenceItems(for: .presentationLUTSequence).first?.dataSet)
            XCTAssertEqual(packed.element(for: .lutData)?.bytesValue?.count, count + count % 2)
            for legacy in [false, true] {
                var source = dataSet
                if legacy {
                    var item = packed
                    let bytes = entries.map(\.littleEndian).withUnsafeBytes { Data($0) }
                    item.set(DicomDataElement(tag: DicomTag.lutData.rawValue, vr: .OW, value: .bytes(bytes)))
                    source.set(DicomDataElement(tag: DicomTag.presentationLUTSequence.rawValue, vr: .SQ,
                        value: .sequence([DicomSequenceItem(dataSet: item)])))
                }
                let data = try DicomDataSetWriter.part10Data(from: source)
                let profile = try DCMDecoder(data: data).displayTransformProfile
                XCTAssertEqual(profile.presentationLUT, lut)
            }
        }
    }

    func test_colorAndBlendingBuilder_roundTripReferencesAndICC() throws {
        let references = try [DicomPresentationReferencedSeries(seriesInstanceUID: "2.25.234401", images: [
            DicomPresentationReferencedImage(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                                             referencedSOPInstanceUID: "2.25.234402")
        ])]
        // Issue #2396: each item carries its own Modality LUT macro (a table on one, a rescale pair on the other).
        let itemLUT = DicomLookupTable(
            descriptor: try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: 4, firstMappedValue: 0, bitsPerEntry: 8)),
            explanation: "UNDERLYING MLUT", lutType: "HU", data: [0, 10, 20, 30]
        )
        let blending = [DicomPresentationBlendingItem(position: .underlying, studyInstanceUID: "2.25.234400",
                                                       referencedSeries: references, modalityLUT: itemLUT),
                        DicomPresentationBlendingItem(position: .superimposed, studyInstanceUID: "2.25.234400",
                                                       referencedSeries: references, rescaleIntercept: -1024, rescaleSlope: 2,
                                                       rescaleType: "HU")]
        let descriptor = try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: 3, firstMappedValue: 0, bitsPerEntry: 8))
        let palette = DicomPaletteColorLookupTable(redDescriptor: descriptor, greenDescriptor: descriptor,
            blueDescriptor: descriptor, red: [0, 128, 255], green: [255, 64, 0], blue: [10, 20, 30])
        for kind in [DicomSoftcopyPresentationStateKind.color, .blending] {
            let options = DicomPresentationStateBuildOptions(iccProfile: lotAICCProfile(), kind: kind,
                paletteColorLookupTable: kind == .blending ? palette : nil,
                blendingItems: kind == .blending ? blending : [], relativeOpacity: kind == .blending ? 0.25 : nil)
            let dataSet = try DicomGrayscalePresentationStateBuilder.dataSet(
                referencedSeries: references, graphicAnnotations: [], options: options)
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let parsed = try XCTUnwrap(try DCMDecoder(data: bytes).grayscalePresentationState)
            XCTAssertEqual(parsed.kind, kind)
            XCTAssertEqual(parsed.paletteColorLookupTable, options.paletteColorLookupTable)
            XCTAssertEqual(parsed.referencedSeries, references)
            XCTAssertEqual(parsed.blendingItems, options.blendingItems)
            XCTAssertEqual(parsed.relativeOpacity, options.relativeOpacity)
            XCTAssertEqual(parsed.iccProfile, options.iccProfile)
            XCTAssertNil(parsed.displayTransformProfile.presentationLUTShape)
            XCTAssertNil(parsed.displayTransformProfile.presentationLUT)
            XCTAssertTrue(parsed.voiSelections.isEmpty)
            XCTAssertTrue(parsed.shutters.isEmpty)
            XCTAssertEqual(parsed.displayedAreas.count, 1)
            let report = try DicomInstanceValidator.validate(bytes)
            XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, "\(kind): \(report.diagnostics)")
        }
    }

    func test_pseudoColorBuilder_roundTripsPackedPaletteAndPadding() throws {
        let references = try [DicomPresentationReferencedSeries(seriesInstanceUID: "2.25.234401", images: [
            DicomPresentationReferencedImage(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                                             referencedSOPInstanceUID: "2.25.234402")
        ])]
        let descriptor = try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: 3, firstMappedValue: 0, bitsPerEntry: 8))
        let palette = DicomPaletteColorLookupTable(redDescriptor: descriptor, greenDescriptor: descriptor,
            blueDescriptor: descriptor, red: [0, 128, 255], green: [255, 64, 0], blue: [10, 20, 30])
        var options = DicomPresentationStateBuildOptions(iccProfile: lotAICCProfile(), kind: .pseudoColor,
                                                        paletteColorLookupTable: palette)
        for _ in 0..<2 {
            let dataSet = try DicomGrayscalePresentationStateBuilder.dataSet(
                referencedSeries: references, graphicAnnotations: [], options: options)
            XCTAssertEqual(dataSet.element(for: .redPalette)?.vr, .OW)
            XCTAssertEqual(dataSet.element(for: .redPalette)?.value, .bytes(Data([0, 128, 255, 0])))
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let parsed = try XCTUnwrap(try DCMDecoder(data: bytes).grayscalePresentationState)
            XCTAssertEqual(parsed.kind, .pseudoColor)
            XCTAssertEqual(parsed.paletteColorLookupTable, palette)
            XCTAssertEqual(parsed.referencedSeries, references)
            XCTAssertEqual(parsed.iccProfile, options.iccProfile)
            let report = try DicomInstanceValidator.validate(bytes)
            XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, "\(report.diagnostics)")
            options.paletteColorLookupTable = parsed.paletteColorLookupTable
        }
    }

    private func lotAICCProfile() -> Data {
        func be(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]) }
        var description = Data("desc".utf8) + Data(repeating: 0, count: 4)
        let label = Data("sRGB IEC61966-2.1".utf8) + Data([0])
        description += be(UInt32(label.count)) + label
        while !description.count.isMultiple(of: 4) { description.append(0) }
        var header = Data(repeating: 0, count: 128)
        header.replaceSubrange(8..<12, with: [2, 0x10, 0, 0])
        header.replaceSubrange(12..<16, with: Data("scnr".utf8))
        header.replaceSubrange(16..<20, with: Data("RGB ".utf8))
        header.replaceSubrange(20..<24, with: Data("XYZ ".utf8))
        header.replaceSubrange(36..<40, with: Data("acsp".utf8))
        var bytes = header + be(1) + Data("desc".utf8) + be(144) + be(UInt32(description.count)) + description
        bytes.replaceSubrange(0..<4, with: be(UInt32(bytes.count)))
        if !bytes.count.isMultiple(of: 2) { bytes.append(0) }
        return bytes
    }

    func test_grayscaleBuilder_roundTripsModalityAndPresentationTablesAndRescale() throws {
        let references = try [DicomPresentationReferencedSeries(seriesInstanceUID: "2.25.234401", images: [
            DicomPresentationReferencedImage(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                                             referencedSOPInstanceUID: "2.25.234402")
        ])]
        let descriptor = try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: 4, firstMappedValue: 0, bitsPerEntry: 16))
        let modality = DicomLookupTable(descriptor: descriptor, explanation: "Modality", lutType: "US",
                                       data: [0, 1, 2, 3])
        let presentation = DicomLookupTable(descriptor: descriptor, explanation: "Presentation", lutType: nil,
                                           data: [0, 10000, 40000, 65535])
        let windows = [DicomDisplayWindow(settings: WindowSettings(center: 2, width: 4),
                                           explanation: "Window", source: .dicom(index: 0))]
        for useModalityTable in [false, true] {
            let profile = DicomDisplayTransformProfile(
                rescaleParameters: useModalityTable ? .init(intercept: 0, slope: 1) : .init(intercept: -10, slope: 2),
                rescaleType: useModalityTable ? nil : "HU",
                modalityLUTs: useModalityTable ? [modality] : [], windows: windows,
                presentationLUTShape: .inverse, presentationLUT: useModalityTable ? presentation : nil)
            let dataSet = try DicomGrayscalePresentationStateBuilder.dataSet(
                referencedSeries: references, graphicAnnotations: [],
                options: .init(displayTransformProfile: profile))
            let bytes = try DicomDataSetWriter.part10Data(from: dataSet)
            let parsed = try XCTUnwrap(try DCMDecoder(data: bytes).grayscalePresentationState)
            XCTAssertEqual(parsed.kind, .grayscale)
            XCTAssertEqual(parsed.referencedSeries, references)
            XCTAssertEqual(parsed.displayTransformProfile.modalityLUTs, profile.modalityLUTs)
            XCTAssertEqual(parsed.displayTransformProfile.rescaleParameters, profile.rescaleParameters)
            XCTAssertEqual(parsed.displayTransformProfile.rescaleType, profile.rescaleType)
            XCTAssertEqual(parsed.displayTransformProfile.windows, windows)
            XCTAssertEqual(parsed.displayTransformProfile.presentationLUT, profile.presentationLUT)
            XCTAssertEqual(parsed.displayTransformProfile.presentationLUTShape, useModalityTable ? nil : .inverse)
            let report = try DicomInstanceValidator.validate(bytes)
            XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, "\(report.diagnostics)")
        }
    }

    func test_referencedSeries_rejectsEmptyUIDAndPreservesValidUID() throws {
        for uid in ["", " \n\0"] {
            XCTAssertThrowsError(try DicomPresentationReferencedSeries(seriesInstanceUID: uid, images: [])) { error in
                XCTAssertEqual(error as? DICOMError, .missingRequiredTag(
                    tag: "0020,000E", description: "Referenced Series Instance UID"
                ))
            }
        }
        let reference = try DicomPresentationReferencedSeries(seriesInstanceUID: " 1.2.826.1.1 ", images: [])
        XCTAssertEqual(reference.seriesInstanceUID, "1.2.826.1.1")
    }

    func test_referencedSeriesParsing_skipsMissingAndEmptyUIDs() throws {
        let valid = try DicomPresentationReferencedSeries(seriesInstanceUID: "1.2.826.1.1", images: [])
        var dataSet = try DicomGrayscalePresentationStateBuilder.dataSet(
            referencedSeries: [valid], graphicAnnotations: []
        )
        let validItems = dataSet.sequenceItems(for: .referencedSeriesSequence)
        let emptyUID = DicomDataSet(elements: [DicomDataElement(
            tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings([""])
        )])
        dataSet.set(DicomDataElement(
            tag: DicomTag.referencedSeriesSequence.rawValue, vr: .SQ,
            value: .sequence([DicomSequenceItem(dataSet: DicomDataSet(elements: [])),
                              DicomSequenceItem(dataSet: emptyUID)] + validItems)
        ))
        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        let state = try XCTUnwrap(try DCMDecoder(data: data).grayscalePresentationState)
        XCTAssertEqual(state.referencedSeries, [valid])
    }

    func test_colorSoftcopyPresentationState_decodesCommonTransformsAndReferences() throws {
        let data = try presentationStateData(
            sopClassUID: DicomGrayscalePresentationState.colorStorageSOPClassUID,
            includesPalette: false
        )

        let state = try XCTUnwrap(try DCMDecoder(data: data).grayscalePresentationState)

        XCTAssertEqual(state.kind, .color)
        XCTAssertEqual(state.referencedSeries.map(\.seriesInstanceUID), ["1.2.826.1.1"])
        XCTAssertEqual(state.spatialTransform.rotationDegrees, 90)
        XCTAssertTrue(state.spatialTransform.isHorizontallyFlipped)
        XCTAssertNil(state.paletteColorLookupTable)
    }

    func test_pseudoColorSoftcopyPresentationState_decodesPaletteLookupTable() throws {
        let data = try presentationStateData(
            sopClassUID: DicomGrayscalePresentationState.pseudoColorStorageSOPClassUID,
            includesPalette: true
        )

        let state = try XCTUnwrap(try DCMDecoder(data: data).grayscalePresentationState)
        let palette = try XCTUnwrap(state.paletteColorLookupTable)

        XCTAssertEqual(state.kind, .pseudoColor)
        XCTAssertEqual(palette.redDescriptor.entryCount, 4)
        XCTAssertEqual(palette.red, [0, 85, 170, 255])
        XCTAssertEqual(palette.green, [255, 170, 85, 0])
        XCTAssertEqual(palette.blue, [0, 255, 255, 0])
        XCTAssertFalse(state.diagnostics.contains { $0.code == "invalid-pseudo-color-palette" })
    }

    func test_pseudoColorSoftcopyPresentationState_missingPaletteReportsDiagnostic() throws {
        let data = try presentationStateData(
            sopClassUID: DicomGrayscalePresentationState.pseudoColorStorageSOPClassUID,
            includesPalette: false
        )

        let state = try XCTUnwrap(try DCMDecoder(data: data).grayscalePresentationState)

        XCTAssertNil(state.paletteColorLookupTable)
        XCTAssertTrue(state.diagnostics.contains { $0.code == "invalid-pseudo-color-palette" })
    }

    func test_storageSCPAdvertisesEverySupportedSoftcopyPresentationState() {
        XCTAssertTrue(
            DicomGrayscalePresentationState.supportedStorageSOPClassUIDs.isSubset(
                of: DicomStorageSOPClassUIDs.commonClinicalStorage
            )
        )
    }

    func test_compoundGraphic_decodesStylesTicksAndLinkedFallback() throws {
        let compound = DicomPresentationCompoundGraphic(
            instanceID: 17,
            units: "DISPLAY",
            graphicType: "AXIS",
            graphicData: [0.1, 0.5, 0.9, 0.5],
            tickAlignment: "TOP",
            tickLabelAlignment: "BOTTOM",
            showsTickLabels: true,
            majorTicks: [
                DicomPresentationCompoundGraphicMajorTick(position: 0, label: "0"),
                DicomPresentationCompoundGraphicMajorTick(position: 1, label: "100")
            ],
            lineStyle: DicomPresentationCompoundGraphicLineStyle(
                patternOnColorCIELabValue: [45_000, 50_000, 20_000],
                patternOnOpacity: 0.75,
                lineThickness: 0.01,
                lineDashingStyle: "DASHED",
                linePattern: 0x00FF_00FF,
                shadowStyle: "NORMAL",
                shadowOffsetX: 0.01,
                shadowOffsetY: 0.02,
                shadowColorCIELabValue: [10_000, 32_768, 32_768],
                shadowOpacity: 0.5
            ),
            textStyle: DicomPresentationCompoundGraphicTextStyle(
                fontName: "Helvetica",
                fontNameType: "ISO_32000",
                cssFontName: "sans-serif",
                textColorCIELabValue: [50_000, 32_768, 32_768],
                shadowStyle: "OFF",
                isBold: true
            ),
            graphicGroupID: 4
        )

        let state = try XCTUnwrap(try DCMDecoder(data: try compoundPresentationStateData(
            compound: compound
        )).grayscalePresentationState)
        let annotation = try XCTUnwrap(state.graphicAnnotations.first)
        let decoded = try XCTUnwrap(annotation.compoundGraphics.first)

        XCTAssertEqual(decoded.instanceID, compound.instanceID)
        XCTAssertEqual(decoded.units, compound.units)
        XCTAssertEqual(decoded.graphicType, compound.graphicType)
        XCTAssertEqual(decoded.graphicData.count, compound.graphicData.count)
        for (actual, expected) in zip(decoded.graphicData, compound.graphicData) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_001)
        }
        XCTAssertEqual(decoded.tickAlignment, compound.tickAlignment)
        XCTAssertEqual(decoded.tickLabelAlignment, compound.tickLabelAlignment)
        XCTAssertEqual(decoded.showsTickLabels, compound.showsTickLabels)
        XCTAssertEqual(decoded.majorTicks, compound.majorTicks)
        XCTAssertEqual(
            decoded.lineStyle?.patternOnColorCIELabValue,
            compound.lineStyle?.patternOnColorCIELabValue
        )
        XCTAssertEqual(decoded.lineStyle?.patternOnOpacity ?? 0, 0.75, accuracy: 0.000_001)
        XCTAssertEqual(decoded.lineStyle?.lineThickness ?? 0, 0.01, accuracy: 0.000_001)
        XCTAssertEqual(decoded.lineStyle?.lineDashingStyle, compound.lineStyle?.lineDashingStyle)
        XCTAssertEqual(decoded.lineStyle?.linePattern, compound.lineStyle?.linePattern)
        XCTAssertEqual(decoded.lineStyle?.shadowStyle, compound.lineStyle?.shadowStyle)
        XCTAssertEqual(decoded.lineStyle?.shadowOffsetX ?? 0, 0.01, accuracy: 0.000_001)
        XCTAssertEqual(decoded.lineStyle?.shadowOffsetY ?? 0, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(decoded.lineStyle?.shadowColorCIELabValue, compound.lineStyle?.shadowColorCIELabValue)
        XCTAssertEqual(decoded.lineStyle?.shadowOpacity ?? 0, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(decoded.textStyle, compound.textStyle)
        XCTAssertEqual(decoded.graphicGroupID, compound.graphicGroupID)
        XCTAssertEqual(annotation.graphicObjects.first?.compoundGraphicInstanceID, 17)
        XCTAssertTrue(decoded.isStructurallyRenderable)
        XCTAssertFalse(state.diagnostics.contains { $0.code == "invalid-compound-graphic" })
        XCTAssertFalse(state.diagnostics.contains { $0.code == "missing-compound-graphic-fallback" })
    }

    func test_invalidCompoundGraphic_preservesLinkedSimpleFallbackWithoutCrash() throws {
        // A filled rectangle without a fill style is not renderable; the builder writes it as given.
        let invalid = DicomPresentationCompoundGraphic(
            instanceID: 23,
            units: "PIXEL",
            graphicType: "RECTANGLE",
            graphicData: [1, 1, 8, 8],
            graphicFilled: true
        )

        let state = try XCTUnwrap(try DCMDecoder(data: try compoundPresentationStateData(
            compound: invalid
        )).grayscalePresentationState)

        XCTAssertEqual(state.graphicAnnotations.first?.compoundGraphics, [invalid])
        XCTAssertEqual(state.graphicAnnotations.first?.graphicObjects.count, 1)
        XCTAssertFalse(invalid.isStructurallyRenderable)
        XCTAssertTrue(state.diagnostics.contains { $0.code == "invalid-compound-graphic" })
    }

    private func presentationStateData(
        sopClassUID: String,
        includesPalette: Bool
    ) throws -> Data {
        var dataSet = try DicomGrayscalePresentationStateBuilder.dataSet(
            referencedSeries: [
                DicomPresentationReferencedSeries(
                    seriesInstanceUID: "1.2.826.1.1",
                    images: [DicomPresentationReferencedImage(
                        referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                        referencedSOPInstanceUID: "1.2.826.1.1.1"
                    )]
                )
            ],
            graphicAnnotations: [],
            options: DicomPresentationStateBuildOptions(
                sopInstanceUID: "1.2.826.1.99.1",
                studyInstanceUID: "1.2.826.1",
                seriesInstanceUID: "1.2.826.1.99",
                spatialTransform: DicomPresentationSpatialTransform(
                    isHorizontallyFlipped: true,
                    rotationDegrees: 90
                )
            )
        )
        dataSet.set(DicomDataElement(
            tag: DicomTag.sopClassUID.rawValue,
            vr: .UI,
            value: .strings([sopClassUID])
        ))
        if includesPalette {
            let descriptor: [UInt] = [4, 0, 16]
            for tag in [
                DicomTag.redPaletteDescriptor,
                .greenPaletteDescriptor,
                .bluePaletteDescriptor
            ] {
                dataSet.set(DicomDataElement(
                    tag: tag.rawValue,
                    vr: .US,
                    value: .unsignedIntegers(descriptor)
                ))
            }
            setPalette([0, 21_845, 43_690, 65_535], tag: .redPalette, in: &dataSet)
            setPalette([65_535, 43_690, 21_845, 0], tag: .greenPalette, in: &dataSet)
            setPalette([0, 65_535, 65_535, 0], tag: .bluePalette, in: &dataSet)
        }
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: sopClassUID,
                mediaStorageSOPInstanceUID: "1.2.826.1.99.1"
            )
        )
    }

    private func compoundPresentationStateData(
        compound: DicomPresentationCompoundGraphic
    ) throws -> Data {
        try DicomGrayscalePresentationStateBuilder.part10Data(
            referencedSeries: [DicomPresentationReferencedSeries(
                seriesInstanceUID: "1.2.826.1.1",
                images: [DicomPresentationReferencedImage(
                    referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                    referencedSOPInstanceUID: "1.2.826.1.1.1"
                )]
            )],
            graphicAnnotations: [DicomPresentationGraphicAnnotation(
                graphicLayer: "MEASUREMENTS",
                graphicObjects: [DicomPresentationGraphicObject(
                    graphicType: "POLYLINE",
                    graphicData: [1, 1, 8, 8],
                    compoundGraphicInstanceID: compound.instanceID
                )],
                compoundGraphics: [compound]
            )],
            graphicLayers: [DicomPresentationGraphicLayer(name: "MEASUREMENTS", order: 1)],
            options: DicomPresentationStateBuildOptions(
                sopInstanceUID: "1.2.826.1.99.2",
                studyInstanceUID: "1.2.826.1",
                seriesInstanceUID: "1.2.826.1.99"
            )
        )
    }

    private func setPalette(
        _ values: [UInt16],
        tag: DicomTag,
        in dataSet: inout DicomDataSet
    ) {
        let bytes = values.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        dataSet.set(DicomDataElement(
            tag: tag.rawValue,
            vr: .OW,
            value: .bytes(Data(bytes))
        ))
    }
}
