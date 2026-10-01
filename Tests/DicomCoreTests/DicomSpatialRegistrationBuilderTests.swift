import Foundation
import XCTest
@testable import DicomCore

final class DicomSpatialRegistrationBuilderTests: XCTestCase {
    static let identity = DicomSpatialRegistrationMatrix(type: "RIGID", rowMajorValues: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1])
    static let ordered = [
        DicomSpatialRegistrationMatrix(type: "RIGID", rowMajorValues: [1,0,0,3, 0,1,0,2, 0,0,1,1, 0,0,0,1]),
        DicomSpatialRegistrationMatrix(type: "RIGID", rowMajorValues: [0,-1,0,0, 1,0,0,0, 0,0,1,0, 0,0,0,1]),
        DicomSpatialRegistrationMatrix(type: "RIGID", rowMajorValues: [1,0,0,-2, 0,1,0,5, 0,0,1,4, 0,0,0,1])]

    static func document(matrices: [DicomSpatialRegistrationMatrix] = [identity], twoItems: Bool = false,
                         usedReferences: Bool = false) -> DicomSpatialRegistrationDocument {
        let image = DicomSourceImageReference(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2.1",
            referencedSOPInstanceUID: "2.25.2347101", referencedFrameNumbers: [1, 2])
        let item = DicomSpatialRegistrationItem(sourceFrameOfReferenceUID: "2.25.2347100",
            referencedSOPInstanceUIDs: usedReferences ? ["2.25.2347101"] : [], matrices: matrices,
            referencedImages: usedReferences ? [image] : [], transformationComment: "Synthetic registration",
            registrationTypeCode: .init(codeValue: "125025", codingSchemeDesignator: "DCM", codeMeaning: "Visual Alignment"),
            usedFiducials: usedReferences ? [.init(reference: references[1], fiducialUID: "2.25.2347111")] : [],
            usedSegments: usedReferences ? [.init(reference: references[2], segmentNumber: 1), .init(reference: references[2], segmentNumber: 2)] : [],
            usedROIs: usedReferences ? [.init(reference: references[3], roiNumber: 1), .init(reference: references[3], roiNumber: 2)] : [])
        return .init(sopInstanceUID: "2.25.2347102", registeredFrameOfReferenceUID: "2.25.2347103",
            registrations: twoItems ? [item, .init(sourceFrameOfReferenceUID: "2.25.2347104", referencedSOPInstanceUIDs: [], matrices: [identity])] : [item],
            contentDate: "20260910", contentTime: "120000", instanceNumber: 7, contentLabel: "TESTREG",
            contentDescription: "Synthetic registration", contentCreatorName: "TEST")
    }
    static let references: [DicomSOPReference] = [
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.2.1", sopInstanceUID: "2.25.2347101"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.66.2", sopInstanceUID: "2.25.2347112"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.66.4", sopInstanceUID: "2.25.2347113"),
        .init(sopClassUID: "1.2.840.10008.5.1.4.1.1.481.3", sopInstanceUID: "2.25.2347114")]
    static var options: DicomRegistrationBuildOptions {
        var result = DicomRegistrationBuildOptions()
        result.referencedStudies = ["2.25.1": ["2.25.2347115": references]]
        return result
    }
    static func data(_ document: DicomSpatialRegistrationDocument) throws -> DicomDataSet {
        try DicomSpatialRegistrationBuilder.dataSet(from: document, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2",
            options: document.registrations.contains { !$0.referencedImages.isEmpty } ? options : .init())
    }

    func test_builder_roundTripsAllTypedAttributesAndOrderedMatrices() throws {
        let model = Self.document(matrices: Self.ordered, twoItems: true, usedReferences: true)
        let bytes = try DicomGeometryCorpusTests.bytes(Self.data(model))
        let decoder = try DCMDecoder(data: bytes)
        XCTAssertEqual(decoder.spatialRegistration, model)
        XCTAssertTrue(decoder.spatialRegistrationDiagnostics.isEmpty)
        XCTAssertEqual(model.registrations[0].registeredPoint(forSourcePoint: SIMD3(1, 2, 3)), SIMD3(-6, 9, 8))
        XCTAssertEqual(Self.identity.matrixType, .rigid)
        XCTAssertEqual(DicomFrameOfReferenceTransformationMatrixType(rawValue: "CUSTOM"), .other("CUSTOM"))
    }

    func test_builder_missingHierarchyIsRejected() {
        XCTAssertThrowsError(try DicomSpatialRegistrationBuilder.dataSet(from: Self.document(usedReferences: true),
            studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2"))
    }

    func test_parser_matrixDiagnosticsArePHIFreeAndLegacyUnknownTypeIsRetained() throws {
        let c = DicomRegistrationCoding.self
        let root = try Self.data(Self.document())
        var matrix = c.matrix(Self.identity).setting(c.text(0x0070030C, .CS, "UNKNOWN"))
        func replacing(_ matrix: DicomDataSet) -> DicomDataSet {
            root.setting(c.sequence(0x00700308, [.init(elements: [c.text(0x00200052, .UI, "2.25.3"),
                c.sequence(0x00700309, [.init(elements: [c.sequence(0x0070030A, [matrix])])])])]))
        }
        XCTAssertNotNil(DicomSpatialRegistrationParser.parse(dataSet: replacing(matrix)))
        XCTAssertEqual(DicomSpatialRegistrationParser.diagnostics(dataSet: replacing(matrix)).map(\.code), [.unknownMatrixType])
        matrix = c.matrix(Self.identity).setting(c.decimals(0x300600C6, Array(repeating: 0, count: 15)))
        XCTAssertEqual(DicomSpatialRegistrationParser.diagnostics(dataSet: replacing(matrix)).map(\.code), [.matrixValueCount])
        matrix = c.matrix(Self.identity).setting(c.decimals(0x300600C6, Array(repeating: 0, count: 16)))
        XCTAssertEqual(DicomSpatialRegistrationParser.diagnostics(dataSet: replacing(matrix)).map(\.code), [.invalidLastRow])
        var values = Self.identity.rowMajorValues
        values[0] = .infinity
        matrix = c.matrix(Self.identity).setting(.init(tag: 0x300600C6, vr: .DS, value: .strings(values.map(String.init(describing:)))))
        XCTAssertTrue(DicomSpatialRegistrationParser.diagnostics(dataSet: replacing(matrix)).contains { $0.code == .nonFiniteMatrix })
    }
}
