import Foundation
import XCTest
@testable import DicomCore

final class DicomWholeSlideMicroscopyBuilderTests: XCTestCase {
    static let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied)
    static func options() -> DicomWholeSlideMicroscopyBuildOptions {
        var o = DicomWholeSlideMicroscopyBuildOptions()
        o.sopInstanceUID = "2.25.2348001"; o.studyInstanceUID = "2.25.2348"; o.seriesInstanceUID = "2.25.23481"
        o.frameOfReferenceUID = "2.25.23482"; o.pyramidUID = "2.25.23483"
        o.matrixColumns = 4; o.matrixRows = 4; o.tileColumns = 2; o.tileRows = 2
        o.origin = .init(xMillimeters: 10, yMillimeters: 20, zMicrometers: 30)
        o.orientation = [0, 1, 0, -1, 0, 0]
        o.pixelSpacingXMillimeters = 0.002; o.pixelSpacingYMillimeters = 0.003
        o.opticalPaths = [path("A")]
        o.specimen = .init(containerIdentifier: "SYNTHETIC", specimens: [.init(identifier: "SPECIMEN", uid: "2.25.23484")])
        o.contentDate = "20260910"; o.contentTime = "120000"; o.acquisitionDateTime = "20260910120000"
        o.frames = (0..<4).map { Data(repeating: UInt8($0 + 1), count: 12) }
        return o
    }
    static func path(_ id: String, monochrome: Bool = false) -> DicomWholeSlideOpticalPath {
        .init(identifier: id, illuminationTypeCodes: [.init(codeValue: monochrome ? "111743" : "111741",
            codingSchemeDesignator: "DCM", codeMeaning: monochrome ? "Epifluorescence illumination" : "Transmission illumination")],
            illuminationWavelengthNanometers: 500, iccProfile: monochrome ? nil : profile())
    }
    static func profile() -> Data {
        func be(_ value: UInt32) -> Data { Data([UInt8(value >> 24), UInt8(value >> 16 & 255), UInt8(value >> 8 & 255), UInt8(value & 255)]) }
        var header = Data(repeating: 0, count: 128)
        header.replaceSubrange(8..<12, with: [2, 0x10, 0, 0])
        for (offset, text) in [(12, "scnr"), (16, "RGB "), (20, "XYZ "), (36, "acsp")] {
            header.replaceSubrange(offset..<(offset + 4), with: Data(text.utf8))
        }
        let text = Data("sRGB IEC61966-2.1\0".utf8)
        var description = Data("desc".utf8) + Data(repeating: 0, count: 4) + be(UInt32(text.count)) + text
        while !description.count.isMultiple(of: 4) { description.append(0) }
        var bytes = header + be(1) + Data("desc".utf8) + be(144) + be(UInt32(description.count)) + description
        bytes.replaceSubrange(0..<4, with: be(UInt32(bytes.count)))
        return bytes
    }
    static func compressedOptions() -> DicomWholeSlideMicroscopyBuildOptions {
        var o = options(); o.transferSyntax = .rleLossless
        o.frames = (1...4).map { value in
            var bytes = Data(repeating: 0, count: 64)
            bytes[0] = 3; bytes[4] = 64; bytes[8] = 68; bytes[12] = 72
            bytes.append(contentsOf: [255, UInt8(value), 255, UInt8(value), 255, UInt8(value + 1), 255, UInt8(value + 1), 255, UInt8(value + 2), 255, UInt8(value + 2)])
            return bytes
        }
        return o
    }
    func test_nativeAndEncapsulated_roundTripModelsAndFrames() throws {
        for o in [Self.options(), Self.compressedOptions()] {
            let data = try DicomWholeSlideMicroscopyBuilder.dataSet(from: o)
            let bytes = try DicomWholeSlideMicroscopyBuilder.part10Data(from: o)
            let decoder = try DCMDecoder(data: bytes)
            let model = try XCTUnwrap(decoder.wholeSlideMicroscopyMetadata)
            XCTAssertEqual(model.opticalPaths, o.opticalPaths)
            XCTAssertEqual(model.specimen, o.specimen)
            XCTAssertEqual(model.totalPixelMatrixOrigin, o.origin)
            XCTAssertEqual(model.imageOrientationSlide, o.orientation)
            XCTAssertEqual(try DicomWholeSlideMicroscopyBuilder.frameBytes(decoder), o.frames)
            let second = try DicomDataSetWriter.part10Data(from: data, options: .init(transferSyntax: o.transferSyntax))
            XCTAssertEqual(try DCMDecoder(data: second).wholeSlideMicroscopyMetadata, model)
            let report = try DicomInstanceValidator.validate(bytes, imageConditions: Self.facts)
            XCTAssertEqual(report.outcome(requiring: Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })), .passed, "\(report.diagnostics)")
        }
    }
    func test_extendedOffsetTable_andRewrap_preserveCompressedFrames() throws {
        var o = Self.compressedOptions(); o.extendedOffsetTable = true
        let source = try DicomWholeSlideMicroscopyBuilder.part10Data(from: o)
        let output = try DicomWholeSlideMicroscopyBuilder.rewrappedContainer(from: source) {
            $0 = $0.setting(DicomRegistrationCoding.text(0x00080018, .UI, "2.25.2348991"))
        }
        XCTAssertEqual(try DicomWholeSlideMicroscopyBuilder.frameBytes(DCMDecoder(data: output)), o.frames)
        XCTAssertNotNil(try DCMDecoder(data: output).dataSet[0x7FE00001])
        XCTAssertThrowsError(try DicomWholeSlideMicroscopyBuilder.rewrappedContainer(from: source) {
            $0 = $0.setting(DicomRegistrationCoding.text(0x00280004, .CS, "MONOCHROME2"))
        })
    }
    func test_region_copiesTilesAndRotatesOrigin() throws {
        let o = Self.compressedOptions()
        let source = try DicomWholeSlideMicroscopyBuilder.part10Data(from: o)
        let output = try DicomWholeSlideMicroscopyBuilder.tileAlignedRegion(from: source, columns: 2..<4, rows: 1..<3,
            sopInstanceUID: "2.25.2348992", seriesInstanceUID: "2.25.2348993")
        let decoder = try DCMDecoder(data: output)
        let model = try XCTUnwrap(decoder.wholeSlideMicroscopyMetadata)
        XCTAssertEqual(model.matrixWidth, 2); XCTAssertEqual(model.matrixHeight, 4)
        XCTAssertNil(model.pyramidUID)
        XCTAssertEqual(model.totalPixelMatrixOrigin?.xMillimeters ?? 0, 10, accuracy: 1e-8)
        XCTAssertEqual(model.totalPixelMatrixOrigin?.yMillimeters ?? 0, 20.004, accuracy: 1e-8)
        XCTAssertEqual(try DicomWholeSlideMicroscopyBuilder.frameBytes(decoder), [o.frames[1], o.frames[3]])
        let sourceRef = decoder.dataSet.sequenceItems(for: 0x52009229)[0].dataSet.sequenceItems(for: 0x00089124)[0].dataSet
            .sequenceItems(for: 0x00082112)[0].dataSet
        XCTAssertEqual(sourceRef.ints(for: 0x00081160), [2, 4])
    }
    func test_regionWithoutSharedFunctionalGroups_refusesWithoutTrapping() throws {
        let data = try DicomWholeSlideMicroscopyBuilder.dataSet(from: Self.options())
            .removing(0x52009229)
            .setting(DicomRegistrationCoding.decimals(0x00280030, [0.003, 0.002]))
        let source = try DicomDataSetWriter.part10Data(from: data)
        XCTAssertNotNil(try DCMDecoder(data: source).wholeSlideMicroscopyMetadata?.slideCoordinateTransform)
        XCTAssertThrowsError(try DicomWholeSlideMicroscopyBuilder.tileAlignedRegion(from: source, columns: 2..<4, rows: 1..<3,
            sopInstanceUID: "2.25.2348992", seriesInstanceUID: "2.25.2348993")) {
            XCTAssertEqual($0 as? DicomWholeSlideMicroscopyBuilder.BuildError, .invalidSource)
        }
    }

    func test_inconsistentInput_isRejected() throws {
        var o = Self.options(); o.frames.removeLast()
        XCTAssertThrowsError(try DicomWholeSlideMicroscopyBuilder.part10Data(from: o))
        o = Self.options(); o.matrixColumns = Int.max
        XCTAssertThrowsError(try DicomWholeSlideMicroscopyBuilder.part10Data(from: o))
    }
}
