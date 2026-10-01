import CryptoKit
import Foundation
import simd
import XCTest
@testable import DicomCore

final class DicomParityGoldenTests: XCTestCase {
    func testQA02Issue280UncompressedGoldenCoversDD06MetadataGeometryFrameCountAndPixelHash() throws {
        let feature = ClinicalGoldenPointer(featureID: "uncompressed", issue: "#220")
        XCTAssertEqual(feature.featureID, "uncompressed")
        XCTAssertEqual(feature.issue, "#220")

        let url = try getCTSyntheticFixtureURL()
        let decoder = try DCMDecoder(contentsOf: url)
        let descriptor = try XCTUnwrap(decoder.pixelDataDescriptor)
        let pixels = try XCTUnwrap(decoder.getPixels16())

        XCTAssertTrue(decoder.dicomFound)
        XCTAssertTrue(decoder.isValid())
        XCTAssertEqual(decoder.info(for: .modality), "CT")
        XCTAssertEqual(decoder.width, 64)
        XCTAssertEqual(decoder.height, 64)
        XCTAssertEqual(decoder.intValue(for: .rows), 64)
        XCTAssertEqual(decoder.intValue(for: .columns), 64)
        XCTAssertEqual(decoder.intValue(for: .bitsAllocated), 16)
        XCTAssertEqual(decoder.info(for: .photometricInterpretation), "MONOCHROME2")
        XCTAssertEqual(decoder.info(for: .pixelSpacing), "0.5\\0.5")
        XCTAssertEqual(decoder.info(for: .sliceThickness), "1")

        XCTAssertEqual(descriptor.rows, 64)
        XCTAssertEqual(descriptor.columns, 64)
        XCTAssertEqual(descriptor.numberOfFrames, 1)
        XCTAssertEqual(descriptor.bitsAllocated, 16)
        XCTAssertEqual(descriptor.samplesPerPixel, 1)
        XCTAssertEqual(decoder.nImages, 1)
        XCTAssertEqual(pixels.count, 64 * 64)
        XCTAssertEqual(Self.sha256Hex(Self.littleEndianData(pixels)), "49624f6c0d99aafde730b2990b31e4badbc7c05bbf92b389ca3fd8e307216892")
    }

    func testQA02Issue280SegmentationGoldenCoversDD20MTK03MetadataGeometryAndLabelmapHash() throws {
        let feature = ClinicalGoldenPointer(featureID: "seg", issue: "#234")
        XCTAssertEqual(feature.featureID, "seg")
        XCTAssertEqual(feature.issue, "#234")

        let sourceReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2.1",
            referencedSOPInstanceUID: "2.25.28001",
            referencedFrameNumbers: [4]
        )
        let segment = DicomSegment(
            number: 7,
            label: "QA-Lesion",
            description: "Issue 280 binary mask",
            algorithmType: "AUTOMATIC",
            algorithmName: "QA02Golden",
            propertyCategory: DicomCodedConcept(codeValue: "M-01000", codingSchemeDesignator: "SRT", codeMeaning: "Morphologically Altered Structure"),
            propertyType: DicomCodedConcept(codeValue: "M-03010", codingSchemeDesignator: "SRT", codeMeaning: "Nodule"),
            trackingID: "qa02-lesion",
            trackingUID: "2.25.28002",
            recommendedDisplayCIELabValue: [32000, 33000, 34000]
        )
        let segmentation = DicomSegmentation(
            sopInstanceUID: "2.25.28003",
            segmentationType: .binary,
            rows: 3,
            columns: 3,
            segments: [segment],
            frames: [
                DicomSegmentationFrame(
                    index: 0,
                    segmentNumber: 7,
                    geometry: segmentationGeometry(frameIndex: 0, z: 0, sourceReference: sourceReference),
                    sourceImageReferences: [sourceReference],
                    pixelData: .binary([1, 0, 1, 0, 1, 0, 1, 0, 1])
                ),
                DicomSegmentationFrame(
                    index: 1,
                    segmentNumber: 7,
                    geometry: segmentationGeometry(frameIndex: 1, z: 1.2, sourceReference: sourceReference),
                    sourceImageReferences: [sourceReference],
                    pixelData: .binary([0, 1, 0, 1, 0, 1, 0, 1, 0])
                )
            ]
        )

        let decoder = try open(segmentation)
        let parsed = try XCTUnwrap(decoder.segmentation)
        let labelmap = try XCTUnwrap(parsed.labelmapsBySegment[7])

        XCTAssertEqual(parsed.sopInstanceUID, "2.25.28003")
        XCTAssertEqual(parsed.segmentationType, .binary)
        XCTAssertEqual(parsed.rows, 3)
        XCTAssertEqual(parsed.columns, 3)
        XCTAssertEqual(parsed.frames.count, 2)
        XCTAssertEqual(parsed.segments, [segment])
        XCTAssertEqual(parsed.frames.map(\.segmentNumber), [7, 7])
        XCTAssertEqual(parsed.frames[0].geometry?.imagePositionPatient, SIMD3<Double>(1, 2, 0))
        XCTAssertEqual(parsed.frames[1].geometry?.imagePositionPatient, SIMD3<Double>(1, 2, 1.2))
        XCTAssertEqual(parsed.frames[0].geometry?.pixelMeasures?.pixelSpacing, SIMD2<Double>(0.6, 0.7))
        // Since #2346 the parser also keeps the derivation/purpose codes the builder writes; compare identities.
        XCTAssertEqual(parsed.frames[0].geometry?.sourceImageReferences.map { DicomSourceImageReferenceIdentity($0) },
                       [DicomSourceImageReferenceIdentity(sourceReference)])
        XCTAssertEqual(labelmap.frameIndexes, [0, 1])
        XCTAssertEqual(labelmap.voxels, [7, 0, 7, 0, 7, 0, 7, 0, 7, 0, 7, 0, 7, 0, 7, 0, 7, 0])
        XCTAssertEqual(Self.sha256Hex(Self.littleEndianData(labelmap.voxels)), "b0d9fe9eb6f1465ff49a07bb3dda5771933bbea82255182360ae0a28eeb973cb")
    }

    func testQA02Issue280StructuredReportGoldenCoversDD23MTK12TreeMeasurementsAndSourceRefs() throws {
        let feature = ClinicalGoldenPointer(featureID: "sr-tid1500", issue: "#237")
        XCTAssertEqual(feature.featureID, "sr-tid1500")
        XCTAssertEqual(feature.issue, "#237")

        let source = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.28010",
            referencedFrameNumbers: [2]
        )
        let keyReference = DicomKeyObjectReference(
            studyInstanceUID: "2.25.28011",
            seriesInstanceUID: "2.25.28012",
            referencedSOPClassUID: source.referencedSOPClassUID,
            referencedSOPInstanceUID: source.referencedSOPInstanceUID,
            referencedFrameNumbers: source.referencedFrameNumbers
        )
        let longAxis = DicomCodedConcept(codeValue: "G-A185", codingSchemeDesignator: "SRT", codeMeaning: "Long Axis")
        let millimeter = DicomCodedConcept(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter")
        let reportTitle = DicomCodedConcept(codeValue: "126000", codingSchemeDesignator: "DCM", codeMeaning: "Imaging Measurement Report")
        let keyImage = DicomCodedConcept(codeValue: "113000", codingSchemeDesignator: "DCM", codeMeaning: "Key Object")
        let roi = DicomSRContentItem(
            relationshipType: "INFERRED FROM",
            valueType: "SCOORD",
            conceptName: DicomCodedConcept(codeValue: "111030", codingSchemeDesignator: "DCM", codeMeaning: "Image Region"),
            graphicType: "POLYLINE",
            graphicData: [10, 20, 30, 40],
            children: [
                DicomSRContentItem(
                    relationshipType: "SELECTED FROM",
                    valueType: "IMAGE",
                    conceptName: keyImage,
                    referencedSOPs: [source]
                )
            ]
        )
        let measurement = DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "NUM",
            conceptName: longAxis,
            numericValue: 18.75,
            measurementUnits: millimeter,
            trackingID: "qa02-long-axis",
            trackingUID: "2.25.28013",
            children: [roi]
        )
        let document = DicomSRDocument(
            sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            sopInstanceUID: "2.25.28014",
            completionFlag: "COMPLETE",
            verificationFlag: "UNVERIFIED",
            templateIdentifier: "1500",
            root: DicomSRContentItem(
                valueType: "CONTAINER",
                conceptName: reportTitle,
                continuityOfContent: "SEPARATE",
                children: [measurement]
            ),
            evidenceReferences: [keyReference]
        )

        let decoder = try open(document: document)
        let parsed = try XCTUnwrap(decoder.structuredReport)

        XCTAssertEqual(parsed.sopInstanceUID, "2.25.28014")
        XCTAssertEqual(parsed.templateIdentifier, "1500")
        XCTAssertEqual(parsed.flattenedContentItems.count, 4)
        XCTAssertEqual(parsed.measurements.count, 1)
        XCTAssertEqual(parsed.measurements.first?.name, longAxis)
        XCTAssertEqual(parsed.measurements.first?.value, 18.75)
        XCTAssertEqual(parsed.measurements.first?.units, millimeter)
        XCTAssertEqual(parsed.measurements.first?.roi?.graphicType, "POLYLINE")
        XCTAssertEqual(parsed.measurements.first?.roi?.graphicData, [10, 20, 30, 40])
        XCTAssertEqual(parsed.measurements.first?.sourceImageReferences, [source])
        XCTAssertEqual(parsed.keyObjectReferences, [keyReference])
        XCTAssertEqual(Self.sha256Hex(Self.utf8Data(canonicalSRTree(parsed.flattenedContentItems))), "eb9b04e21b8ec94c37d43a9c7f26e409584e4b073d18064d470d1e39e917a6ee")
    }

    func testQA02Issue280ParametricMapGoldenCoversDD22RWVFrameGeometryAndScalarHash() throws {
        let feature = ClinicalGoldenPointer(featureID: "pmap", issue: "#236")
        XCTAssertEqual(feature.featureID, "pmap")
        XCTAssertEqual(feature.issue, "#236")

        let sourceReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.4",
            referencedSOPInstanceUID: "2.25.28020",
            referencedFrameNumbers: [1]
        )
        let storedValues: [UInt16] = [50, 100, 150, 200, 250, 300, 350, 400]
        let units = DicomCodedConcept(codeValue: "mm2/s", codingSchemeDesignator: "UCUM", codeMeaning: "square millimeter per second")
        let quantityName = DicomCodedConcept(codeValue: "246205007", codingSchemeDesignator: "SCT", codeMeaning: "Quantity")
        let quantityCode = DicomCodedConcept(codeValue: "113041", codingSchemeDesignator: "DCM", codeMeaning: "Apparent Diffusion Coefficient")
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomParametricMap.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.28021"),
            string(.modality, vr: .CS, "PM"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            string(.numberOfFrames, vr: .IS, "2"),
            us(.rows, 2),
            us(.columns, 2),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 0),
            sequence(.sharedFunctionalGroupsSequence, [
                DicomDataSet(elements: [
                    sequence(.pixelMeasuresSequence, [
                        DicomDataSet(elements: [
                            ds(.pixelSpacing, ["0.9", "1.1"]),
                            ds(.sliceThickness, ["2.0"]),
                            ds(.sliceSpacing, ["2.0"])
                        ])
                    ]),
                    sequence(.planeOrientationSequence, [
                        DicomDataSet(elements: [
                            ds(.imageOrientationPatient, ["1", "0", "0", "0", "1", "0"])
                        ])
                    ]),
                    sequence(.realWorldValueMappingSequence, [
                        realWorldValueMap(
                            label: "ADC",
                            first: 0,
                            last: 1000,
                            intercept: 0,
                            slope: 0.002,
                            units: units,
                            quantityName: quantityName,
                            quantityCode: quantityCode
                        )
                    ])
                ])
            ]),
            sequence(.perFrameFunctionalGroupsSequence, [
                parametricMapFrameFunctionalGroup(index: 0, z: 0, sourceReference: sourceReference),
                parametricMapFrameFunctionalGroup(index: 1, z: 2.0, sourceReference: sourceReference)
            ]),
            bytes(.pixelData, vr: .OW, Self.littleEndianData(storedValues))
        ])

        let decoder = try openParametricMap(dataSet: dataSet)
        let map = try XCTUnwrap(decoder.parametricMap)

        XCTAssertEqual(map.sopInstanceUID, "2.25.28021")
        XCTAssertEqual(map.rows, 2)
        XCTAssertEqual(map.columns, 2)
        XCTAssertEqual(map.frameCount, 2)
        XCTAssertEqual(map.scalarVolume.scalarValues, storedValues.map(Double.init))
        assertEqual(map.scalarVolume.physicalValues ?? [], [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8], accuracy: 1e-12)
        XCTAssertEqual(map.scalarVolume.units, units)
        XCTAssertEqual(map.scalarVolume.quantityDefinitions.first?.conceptName, quantityName)
        XCTAssertEqual(map.scalarVolume.quantityDefinitions.first?.conceptCode, quantityCode)
        XCTAssertEqual(map.frames[0].sourceImageReferences, [sourceReference])
        XCTAssertEqual(map.frames[1].geometry?.imagePositionPatient, SIMD3<Double>(0, 0, 2.0))
        XCTAssertEqual(map.frames[0].geometry?.imageOrientationPatient?.normal, SIMD3<Double>(0, 0, 1))
        XCTAssertEqual(map.frames[0].geometry?.pixelMeasures?.pixelSpacing, SIMD2<Double>(0.9, 1.1))
        XCTAssertEqual(map.frames[0].realWorldValueMap?.label, "ADC")
        XCTAssertEqual(Self.sha256Hex(Self.littleEndianData(storedValues)), "48bfd6bd0b13ea658a3c3a8c8a90857785f243969419adb70a23b31fd17c1bf7")
    }

    private struct ClinicalGoldenPointer {
        var featureID: String
        var issue: String
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func littleEndianData(_ values: [UInt16]) -> Data {
        values.reduce(into: Data()) { data, value in
            data.append(UInt8(value.littleEndian & 0x00FF))
            data.append(UInt8((value.littleEndian >> 8) & 0x00FF))
        }
    }

    private static func utf8Data(_ value: String) -> Data {
        Data(value.utf8)
    }

    private func open(
        _ segmentation: DicomSegmentation,
        transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian
    ) throws -> DCMDecoder {
        let dataSet = DicomSegmentationBuilder.dataSet(
            from: segmentation,
            studyInstanceUID: "2.25.28030",
            seriesInstanceUID: "2.25.28031"
        )
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: DicomSegmentationBuilder.segmentationStorageSOPClassUID,
                mediaStorageSOPInstanceUID: segmentation.sopInstanceUID
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity_segmentation_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func open(document: DicomSRDocument) throws -> DCMDecoder {
        let dataSet = DicomStructuredReportBuilder.dataSet(
            from: document,
            studyInstanceUID: "2.25.28011",
            seriesInstanceUID: "2.25.28040",
            sopInstanceUID: document.sopInstanceUID
        )
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: document.sopClassUID ?? DicomSRDocument.enhancedSRStorageSOPClassUID,
                mediaStorageSOPInstanceUID: document.sopInstanceUID
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity_structured_report_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func openParametricMap(dataSet: DicomDataSet) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomParametricMap.storageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parity_parametric_map_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func segmentationGeometry(
        frameIndex: Int,
        z: Double,
        sourceReference: DicomSourceImageReference
    ) -> DicomFrameGeometry {
        DicomFrameGeometry(
            frameIndex: frameIndex,
            functionalGroups: DicomFrameFunctionalGroups(
                frameContent: DicomFrameContent(
                    dimensionIndexValues: [frameIndex + 1],
                    stackID: "QA02",
                    inStackPositionNumber: frameIndex + 1,
                    temporalPositionIndex: nil,
                    frameAcquisitionNumber: nil
                ),
                pixelMeasures: DicomPixelMeasures(
                    pixelSpacing: SIMD2<Double>(0.6, 0.7),
                    sliceThickness: 1.2,
                    spacingBetweenSlices: 1.2
                ),
                planePosition: DicomPlanePosition(imagePositionPatient: SIMD3<Double>(1, 2, z)),
                planeOrientation: DicomPlaneOrientation(
                    row: SIMD3<Double>(1, 0, 0),
                    column: SIMD3<Double>(0, 1, 0)
                ),
                derivationImage: DicomDerivationImage(sourceImages: [sourceReference])
            )
        )!
    }

    private func parametricMapFrameFunctionalGroup(
        index: Int,
        z: Double,
        sourceReference: DicomSourceImageReference
    ) -> DicomDataSet {
        DicomDataSet(elements: [
            sequence(.frameContentSequence, [
                DicomDataSet(elements: [
                    ul(.dimensionIndexValues, [index + 1]),
                    string(.stackID, vr: .SH, "PM"),
                    ul(.inStackPositionNumber, [index + 1])
                ])
            ]),
            sequence(.planePositionSequence, [
                DicomDataSet(elements: [
                    ds(.imagePositionPatient, ["0", "0", String(z)])
                ])
            ]),
            sequence(.derivationImageSequence, [
                DicomDataSet(elements: [
                    sequence(.sourceImageSequence, [sourceImageDataSet(sourceReference)])
                ])
            ])
        ])
    }

    private func realWorldValueMap(
        label: String,
        first: Int,
        last: Int,
        intercept: Double,
        slope: Double,
        units: DicomCodedConcept,
        quantityName: DicomCodedConcept,
        quantityCode: DicomCodedConcept
    ) -> DicomDataSet {
        DicomDataSet(elements: [
            string(.realWorldValueLUTLabel, vr: .SH, label),
            us(.realWorldValueFirstValueMapped, first),
            us(.realWorldValueLastValueMapped, last),
            fd(.realWorldValueIntercept, [intercept]),
            fd(.realWorldValueSlope, [slope]),
            sequence(.measurementUnitsCodeSequence, [codedConceptDataSet(units)]),
            sequence(.quantityDefinitionSequence, [
                DicomDataSet(elements: [
                    string(.valueType, vr: .CS, "CODE"),
                    sequence(.conceptNameCodeSequence, [codedConceptDataSet(quantityName)]),
                    sequence(.conceptCodeSequence, [codedConceptDataSet(quantityCode)])
                ])
            ])
        ])
    }

    private func sourceImageDataSet(_ reference: DicomSourceImageReference) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        if let sopClassUID = reference.referencedSOPClassUID {
            elements.append(string(.referencedSOPClassUID, vr: .UI, sopClassUID))
        }
        if let sopInstanceUID = reference.referencedSOPInstanceUID {
            elements.append(string(.referencedSOPInstanceUID, vr: .UI, sopInstanceUID))
        }
        if !reference.referencedFrameNumbers.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.referencedFrameNumber.rawValue,
                vr: .IS,
                value: .strings(reference.referencedFrameNumbers.map(String.init))
            ))
        }
        return DicomDataSet(elements: elements)
    }

    private func codedConceptDataSet(_ concept: DicomCodedConcept) -> DicomDataSet {
        var elements = [
            string(.codeValue, vr: .SH, concept.codeValue),
            string(.codingSchemeDesignator, vr: .SH, concept.codingSchemeDesignator)
        ]
        if let meaning = concept.codeMeaning {
            elements.append(string(.codeMeaning, vr: .LO, meaning))
        }
        return DicomDataSet(elements: elements)
    }

    private func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)]))
    }

    private func ul(_ tag: DicomTag, _ values: [Int]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .UL, value: .unsignedIntegers(values.map { UInt($0) }))
    }

    private func ds(_ tag: DicomTag, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values))
    }

    private func fd(_ tag: DicomTag, _ values: [Double]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .FD, value: .floats(values))
    }

    private func bytes(_ tag: DicomTag, vr: DicomVR, _ data: Data) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .bytes(data))
    }

    private func canonicalSRTree(_ items: [DicomSRContentItem]) -> String {
        items.map { item in
            [
                item.relationshipType ?? "",
                item.valueType,
                item.conceptName.map(canonicalConcept) ?? "",
                item.numericValue.map { String(format: "%.3f", $0) } ?? "",
                item.measurementUnits.map(canonicalConcept) ?? "",
                item.graphicType ?? "",
                item.graphicData.map { String(format: "%.3f", $0) }.joined(separator: ","),
                item.referencedSOPs.map(canonicalSourceReference).joined(separator: ",")
            ].joined(separator: "^")
        }.joined(separator: "|")
    }

    private func canonicalConcept(_ concept: DicomCodedConcept) -> String {
        [
            concept.codeValue,
            concept.codingSchemeDesignator,
            concept.codeMeaning ?? ""
        ].joined(separator: ":")
    }

    private func canonicalSourceReference(_ reference: DicomSourceImageReference) -> String {
        [
            reference.referencedSOPClassUID ?? "",
            reference.referencedSOPInstanceUID ?? "",
            reference.referencedFrameNumbers.map(String.init).joined(separator: ",")
        ].joined(separator: ":")
    }

    private func assertEqual(
        _ actual: [Double],
        _ expected: [Double],
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(actualValue, expectedValue, accuracy: accuracy, file: file, line: line)
        }
    }
}
