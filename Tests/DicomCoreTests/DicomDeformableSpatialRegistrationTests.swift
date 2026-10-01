import Foundation
import XCTest
@testable import DicomCore

final class DicomDeformableSpatialRegistrationTests: XCTestCase {
    static func grid(nan: Bool = false) -> DicomDeformableRegistrationGrid {
        var values: [Float] = []
        for k in 0..<3 { for j in 0..<3 { for i in 0..<3 { values += [Float(i), Float(j * 2), Float(k * 3)] } } }
        if nan { values[0] = .nan; values[1] = .nan; values[2] = .nan }
        return .init(imageOrientationPatient: [0,1,0, -1,0,0], imagePositionPatient: SIMD3(10,20,30),
            dimensions: SIMD3(3,3,3), resolution: SIMD3(2,3,4), vectorGridData: values)
    }
    static let centre = SIMD3<Double>(7,22,34)
    static let half = SIMD3<Double>(8.5,21,32)
    static func document(prePost: Bool = false, nan: Bool = false, matrixItem: Bool = false) -> DicomDeformableSpatialRegistrationDocument {
        let matrices = DicomSpatialRegistrationBuilderTests.ordered
        let gridItem = DicomDeformableSpatialRegistrationItem(sourceFrameOfReferenceUID: "2.25.2347200",
            transformationComment: "Synthetic deformation", registrationTypeCode: .init(codeValue: "125025", codingSchemeDesignator: "DCM", codeMeaning: "Visual Alignment"),
            preMatrix: prePost ? matrices[0] : nil, postMatrix: prePost ? matrices[1] : nil, grid: grid(nan: nan))
        return .init(sopInstanceUID: "2.25.2347201", registeredFrameOfReferenceUID: "2.25.2347202",
            contentDate: "20260910", contentTime: "120000",
            registrations: matrixItem ? [.init(sourceFrameOfReferenceUID: "2.25.2347203", preMatrix: matrices[2]), gridItem] : [gridItem])
    }
    static func data(_ document: DicomDeformableSpatialRegistrationDocument) throws -> DicomDataSet {
        try DicomDeformableSpatialRegistrationBuilder.dataSet(from: document, studyInstanceUID: "2.25.1", seriesInstanceUID: "2.25.2")
    }

    func test_builder_roundTripsGridMatricesAndUndefinedVectors() throws {
        for model in [Self.document(), Self.document(prePost: true), Self.document(nan: true), Self.document(matrixItem: true)] {
            let bytes = try DicomGeometryCorpusTests.bytes(Self.data(model))
            let parsed = try DicomDeformableSpatialRegistrationParser.parse(part10Data: bytes)
            XCTAssertEqual(parsed.document, model)
            XCTAssertTrue(parsed.diagnostics.isEmpty)
        }
    }

    func test_mapping_registeredToSourceUsesOriginalGridPointAndMatrixOrder() throws {
        let item = Self.document(prePost: true).registrations[0]
        XCTAssertEqual(item.grid?.vector(i: 1, j: 1, k: 1), SIMD3(1,2,3))
        XCTAssertEqual(item.grid?.displacement(atRegisteredPoint: Self.centre), SIMD3(1,2,3))
        XCTAssertEqual(item.grid?.displacement(atRegisteredPoint: Self.half), SIMD3(0.5,1,1.5))
        XCTAssertEqual(item.sourcePoint(forRegisteredPoint: Self.centre), SIMD3(-26,11,38))
        XCTAssertEqual(item.sourcePoint(forRegisteredPoint: Self.half), SIMD3(-24,12,34.5))
        XCTAssertNil(item.sourcePoint(forRegisteredPoint: .zero))
        XCTAssertEqual(Self.grid(nan: true).undefinedVectorCount, 1)
        XCTAssertNil(Self.grid(nan: true).displacement(atRegisteredPoint: Self.half))
        XCTAssertNil(Self.grid().vector(i: -1, j: 0, k: 0))
        XCTAssertEqual(Self.grid().displacement(atRegisteredPoint: SIMD3(4,24,38)), SIMD3(2,4,6))
    }

    func test_undefinedNeighbourWithZeroWeight_doesNotInvalidateExactSample() {
        let grid = DicomDeformableRegistrationGrid(imageOrientationPatient: [1, 0, 0, 0, 1, 0], imagePositionPatient: .zero,
            dimensions: SIMD3(2, 1, 1), resolution: SIMD3(repeating: 1), vectorGridData: [1, 2, 3, .nan, .nan, .nan])
        XCTAssertEqual(grid.displacement(atRegisteredPoint: .zero), SIMD3(1, 2, 3))
        XCTAssertNil(grid.displacement(atRegisteredPoint: SIMD3(0.5, 0, 0)))
        XCTAssertNil(grid.displacement(atRegisteredPoint: SIMD3(1, 0, 0)))
    }

    func test_grid_rejectsInvalidShapeOrientationAndPartialNaN() {
        let base = Self.grid()
        for grid in [
            DicomDeformableRegistrationGrid(imageOrientationPatient: [1,0,0, 1,0,0], imagePositionPatient: .zero,
                dimensions: base.dimensions, resolution: base.resolution, vectorGridData: base.vectorGridData),
            .init(imageOrientationPatient: base.imageOrientationPatient, imagePositionPatient: .zero,
                dimensions: SIMD3(Int.max,2,2), resolution: base.resolution, vectorGridData: []),
            .init(imageOrientationPatient: base.imageOrientationPatient, imagePositionPatient: .zero,
                dimensions: SIMD3(1,1,1), resolution: base.resolution, vectorGridData: [.nan,0,0])
        ] { XCTAssertFalse(grid.isValid); XCTAssertNil(grid.displacement(atRegisteredPoint: .zero)) }
    }

    func test_slicedVectorBytes_preserveValidationAndParsedGrid() throws {
        let model = Self.document()
        let base = try Self.data(model)
        let item = try XCTUnwrap(base.sequenceItems(for: 0x00640002).first?.dataSet)
        let grid = try XCTUnwrap(item.sequenceItems(for: 0x00640005).first?.dataSet)
        let bytes = try XCTUnwrap(grid[0x00640009]?.bytesValue)
        var backing = Data(repeating: 0, count: 4)
        backing.append(bytes)
        let slice = backing.dropFirst(4)
        XCTAssertEqual(slice.startIndex, 4)
        let changedGrid = grid.setting(.init(tag: 0x00640009, vr: .OF, value: .bytes(slice)))
        let changedItem = item.setting(DicomRegistrationCoding.sequence(0x00640005, [changedGrid]))
        let changed = base.setting(DicomRegistrationCoding.sequence(0x00640002, [changedItem]))
        let expected = DicomEnhancedImageModules.validate(base, profile: .deformableSpatialRegistration)
        let actual = DicomEnhancedImageModules.validate(changed, profile: .deformableSpatialRegistration)
        XCTAssertEqual(actual.diagnostics, expected.diagnostics)
        XCTAssertEqual(DicomDeformableSpatialRegistrationParser.parse(dataSet: changed).document, model)
    }
}
