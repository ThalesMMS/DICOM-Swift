import XCTest
@testable import DicomCore

final class DicomRTDoseBuilderTests: XCTestCase {
    static let planReference = DicomRTDoseReferencedPlan(sopClassUID: DicomRTPlan.storageSOPClassUID,
        sopInstanceUID: "2.25.23279905")
    static let structureReference = DicomSOPReference(sopClassUID: DicomRTStructureSet.storageSOPClassUID,
        sopInstanceUID: "2.25.23279903")
    static let transverse = DicomPlaneOrientation(row: .init(1, 0, 0), column: .init(0, 1, 0))

    static func fullDVH() -> DicomRTDVH {
        .init(referencedROIs: [.init(number: 1, contributionType: "INCLUDED"), .init(number: 2, contributionType: "EXCLUDED")],
            type: "CUMULATIVE", doseUnits: "GY", doseType: "PHYSICAL", doseScaling: 0.5,
            volumeUnits: "CM3", bins: [(0, 10), (2, 5), (2, 0)], minimumDose: 0, maximumDose: 2, meanDose: 1)
    }

    static func dose(offsets: [Double] = [0, 2], bits: Int = 16, signed: Bool = false,
                     relative: Bool = false, dvhOnly: Bool = false, registered: Bool = false,
                     orientation: DicomPlaneOrientation = transverse) -> DicomRTDoseVolume {
        let signedValues: [Int32] = [-2, -1, 0, 1, 2, 3, 4, 5]
        let values: [UInt32] = signed ? signedValues.map {
            bits == 16 ? UInt32(UInt16(bitPattern: Int16($0))) : UInt32(bitPattern: $0)
        } : (0..<(offsets.count * 4)).map { UInt32($0) * (bits == 32 ? 100_000 : 1) }
        return DicomRTDoseVolume(sopInstanceUID: "2.25.234702", doseUnits: relative ? "RELATIVE" : "GY",
            doseType: signed ? "ERROR" : "PHYSICAL", doseSummationType: "PLAN", doseGridScaling: dvhOnly ? 1 : 0.01,
            frameOfReferenceUID: "2.25.23279998", rows: dvhOnly ? 0 : 2, columns: dvhOnly ? 0 : 2,
            frames: dvhOnly ? 0 : offsets.count, pixelSpacing: dvhOnly ? nil : .init(1, 2),
            imagePositionPatient: dvhOnly ? nil : .init(10, 20, offsets.first == 0 ? 30 : offsets[0]),
            imageOrientationPatient: dvhOnly ? nil : orientation,
            gridFrameOffsetVector: dvhOnly ? [] : offsets, sliceThickness: dvhOnly ? nil : 2,
            storedValues: dvhOnly ? [] : values, referencedPlans: [planReference],
            referencedStructureSet: dvhOnly ? structureReference : nil,
            spatialTransformOfDose: registered ? "RIGID" : nil,
            referencedSpatialRegistrations: registered ? [.init(sopClassUID: "1.2.840.10008.5.1.4.1.1.66.1", sopInstanceUID: "2.25.234703")] : [],
            normalizationPoint: relative ? .init(10, 20, 30) : nil, doseComment: "Synthetic dose", instanceNumber: 1,
            pixelRepresentation: dvhOnly ? nil : signed ? 1 : 0, bitsAllocated: dvhOnly ? nil : bits,
            signedStoredValues: signed ? signedValues : nil,
            recommendedIsodoseLevels: [.init(doseValue: 1, cielab: .init(30000, 40000, 50000))],
            dvhs: dvhOnly ? [fullDVH()] : [], dvhNormalizationPoint: dvhOnly ? .zero : nil,
            dvhNormalizationDoseValue: dvhOnly ? 2 : nil)
    }

    func test_gridAndDVHVariants_roundTripEqualModels() throws {
        for model in [Self.dose(), Self.dose(offsets: [30, 32]), Self.dose(offsets: [0, 2, 5]),
                      Self.dose(bits: 32), Self.dose(signed: true), Self.dose(bits: 32, signed: true),
                      Self.dose(relative: true), Self.dose(dvhOnly: true), Self.dose(registered: true)] {
            let data = try DicomRTDoseBuilder.dataSet(from: model, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
            let parsed = try XCTUnwrap(DCMDecoder(data: DicomGeometryCorpusTests.bytes(data)).rtDose)
            XCTAssertEqual(parsed, model)
            XCTAssertTrue(parsed.diagnostics.isEmpty)
            if model.signedStoredValues != nil { XCTAssertEqual(parsed.doseValues[0], -0.02) }
            let rebuilt = try DicomRTDoseBuilder.dataSet(from: parsed, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
            XCTAssertEqual(try DCMDecoder(data: DicomGeometryCorpusTests.bytes(rebuilt)).rtDose, parsed)
        }
    }

    func test_referenceHierarchyDerivationAndPurpose_roundTrip() throws {
        let code = DicomCodedConcept(codeValue: "113085", codingSchemeDesignator: "DCM", codeMeaning: "Spatial resampling")
        let source = DicomSourceImageReference(referencedSOPClassUID: DicomRTPlan.storageSOPClassUID,
            referencedSOPInstanceUID: "2.25.23279905",
            purposeOfReferenceCode: .init(codeValue: "121322", codingSchemeDesignator: "DCM", codeMeaning: "Source image for image processing operation"))
        let plans = [DicomRTDoseReferencedPlan(sopClassUID: DicomRTPlan.storageSOPClassUID,
            sopInstanceUID: "2.25.23279905", referencedPlanOverviewIndex: 1, fractionGroups: [
                .init(number: 1, beams: [.init(number: 1, controlPointRanges: [.init(startIndex: 0, stopIndex: 1)])],
                    brachyApplicationSetups: [.init(number: 2)])])]
        let records = [DicomRTDoseReferencedTreatmentRecord(sopClassUID: "1.2.840.10008.5.1.4.1.1.481.4",
            sopInstanceUID: "2.25.234790", beams: [.init(number: 3)])]
        let model = DicomRTDoseVolume(sopInstanceUID: "2.25.234791", doseUnits: "GY", doseType: "PHYSICAL",
            doseSummationType: "RECORD", doseGridScaling: 1, frameOfReferenceUID: "2.25.23279998",
            rows: 0, columns: 0, frames: 0, storedValues: [], referencedPlans: plans,
            referencedStructureSet: Self.structureReference, referencedTreatmentRecords: records,
            derivationCodes: [code], referencedInstances: [source], dvhs: [Self.fullDVH()])
        let data = try DicomRTDoseBuilder.dataSet(from: model, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        XCTAssertEqual(try DCMDecoder(data: DicomGeometryCorpusTests.bytes(data)).rtDose, model)
    }

    func test_nilGrid_decodesDVHWithoutPixelData() throws {
        let data = try DicomRTDoseBuilder.dataSet(grid: nil, dvhs: [Self.fullDVH()],
            referencedStructureSet: Self.structureReference, referencedPlans: [Self.planReference],
            frameOfReferenceUID: "2.25.23279998", studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2",
            sopInstanceUID: "2.25.234792")
        XCTAssertFalse(data.contains(0x7FE00010))
        let dose = try XCTUnwrap(DCMDecoder(data: DicomGeometryCorpusTests.bytes(data)).rtDose)
        XCTAssertEqual(dose.dvhs, [Self.fullDVH()])
        XCTAssertTrue(dose.storedValues.isEmpty)
        XCTAssertNil(dose.imagePositionPatient)
        XCTAssertNil(dose.pixelRepresentation)
    }

    func test_pixelGridWithoutPixelData_isRejectedEvenWhenDVHIsPresent() throws {
        let grid = try DicomRTDoseBuilder.dataSet(from: Self.dose(), studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        let missing = grid.removing(0x7FE00010)
            .setting(DicomRTValueCoding.sequence(0x30040050, [Self.fullDVH().dataSet]))
        XCTAssertThrowsError(try DCMDecoder(data: DicomGeometryCorpusTests.bytes(missing)))
        let bytes = try DicomGeometryCorpusTests.bytes(grid)
        let decoder = try DCMDecoder(data: bytes)
        // Truncate the Pixel Data element header after retaining Rows and Columns.
        XCTAssertThrowsError(try DCMDecoder(data: Data(bytes.prefix(decoder.offset - 8))))
        XCTAssertThrowsError(try DCMDecoder(data: Data(bytes.dropLast(2))))
    }

    func test_offsets_resolveObliqueAbsoluteDescendingAndNonuniformPlanes() {
        let oblique = DicomPlaneOrientation(row: .init(0.8, 0, -0.6), column: .init(0, 1, 0))
        let relative = DicomRTDoseGridFrameOffsets.relative([0, 2, 5])
        XCTAssertEqual(relative.planePositions(imagePosition: .init(10, 20, 30), orientation: oblique),
            [.init(10, 20, 30), .init(11.2, 20, 31.6), .init(13, 20, 34)])
        XCTAssertEqual(relative.spacings, [2, 3])
        XCTAssertTrue(relative.isMonotonic)
        XCTAssertFalse(relative.isUniform(tolerance: 0.01))
        let descending = DicomRTDoseGridFrameOffsets.absoluteZ([30, 28, 26])
        XCTAssertEqual(descending.planePositions(imagePosition: .init(10, 20, 30), orientation: Self.transverse),
            [.init(10, 20, 30), .init(10, 20, 28), .init(10, 20, 26)])
        XCTAssertTrue(descending.isUniform(tolerance: 0))
        XCTAssertNil(descending.planePositions(imagePosition: .zero, orientation: oblique))
        XCTAssertFalse(DicomRTDoseGridFrameOffsets.relative([0, 2, 1]).isMonotonic)
        XCTAssertEqual(DicomRTDoseGridFrameOffsets.none.planePositions(imagePosition: .zero, orientation: oblique), [.zero])
    }

    func test_paddedSignedErrorDose_doesNotReportSignedPhysicalDose() throws {
        let data = try DicomRTDoseBuilder.dataSet(from: Self.dose(signed: true), studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
            .setting(DicomRTValueCoding.text(0x30040004, .CS, "ERROR "))
        let dose = try XCTUnwrap(DCMDecoder(data: DicomGeometryCorpusTests.bytes(data)).rtDose)
        XCTAssertTrue(dose.diagnostics.isEmpty)
        XCTAssertEqual(dose.doseValues[0], -0.02)
    }

    func test_incompleteDVH_isRejectedWithDiagnostic() {
        let valid = Self.fullDVH().dataSet
        let invalidROIs = [valid.removing(0x30040060),
            valid.setting(DicomRTValueCoding.sequence(0x30040060, [])),
            valid.setting(DicomRTValueCoding.sequence(0x30040060,
                [Self.fullDVH().referencedROIs[0].dataSet, .init(elements: [])]))]
        for data in invalidROIs {
            var diagnostics: [DicomRTDoseDiagnostic] = []
            XCTAssertNil(DicomRTDVH.parse(data, index: 2, diagnostics: &diagnostics))
            XCTAssertEqual(diagnostics, [.init(code: .dvhReferencedROIInvalid, dvhIndex: 2)])
        }
        let empty = valid.setting(DicomRTValueCoding.text(0x30040056, .IS, "0"))
            .setting(DicomRTValueCoding.decimals(0x30040058, []))
        var diagnostics: [DicomRTDoseDiagnostic] = []
        XCTAssertNil(DicomRTDVH.parse(empty, index: 0, diagnostics: &diagnostics))
        XCTAssertEqual(diagnostics, [.init(code: .dvhDataCountMismatch, dvhIndex: 0)])
    }

    func test_malformedDose_recordsTypedDiagnosticsWithoutForwardRepair() throws {
        let base = try DicomRTDoseBuilder.dataSet(from: Self.dose(), studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        let badOffsets = base.setting(DicomRTValueCoding.decimals(0x3004000C, [0, 2, 1]))
        let parsed = try XCTUnwrap(DCMDecoder(data: DicomGeometryCorpusTests.bytes(badOffsets)).rtDose)
        XCTAssertEqual(parsed.diagnostics.map(\.code), [.offsetsCountMismatch, .nonMonotonicOffsets])
        let signedPhysical = base.setting(.init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([1])))
        XCTAssertEqual(try DCMDecoder(data: DicomGeometryCorpusTests.bytes(signedPhysical)).rtDose?.diagnostics.map(\.code), [.signedNonErrorDose])
        let absoluteOblique = base.setting(DicomRTValueCoding.decimals(0x3004000C, [30, 32]))
            .setting(DicomRTValueCoding.decimals(0x00200037, [0.8, 0, -0.6, 0, 1, 0]))
        XCTAssertEqual(try DCMDecoder(data: DicomGeometryCorpusTests.bytes(absoluteOblique)).rtDose?.diagnostics.map(\.code), [.absoluteZNonTransverseOrientation])
        let dvh = try DicomRTDoseBuilder.dataSet(from: Self.dose(dvhOnly: true), studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
        for values in [[0.0, 1, 2], [0, 1, 2, 3]] {
            let badDVH = dvh.setting(DicomRTValueCoding.sequence(0x30040050,
                [Self.fullDVH().dataSet.setting(DicomRTValueCoding.decimals(0x30040058, values))]))
            let result = try XCTUnwrap(DCMDecoder(data: DicomGeometryCorpusTests.bytes(badDVH)).rtDose)
            XCTAssertTrue(result.dvhs.isEmpty)
            XCTAssertEqual(result.diagnostics, [.init(code: .dvhDataCountMismatch, dvhIndex: 0)])
        }
    }
}
