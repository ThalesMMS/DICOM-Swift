import CryptoKit
import Foundation
import XCTest
@testable import DicomCore

final class DicomWholeSlideCorpusTests: XCTestCase {
    func test_corpus_qualifiesWholeSlideProfileAndRejectsViolations() throws {
        let b = DicomWholeSlideMicroscopyBuilder.self
        let c = DicomRegistrationCoding.self
        let fixture = DicomWholeSlideMicroscopyBuilderTests.self
        let baseOptions = fixture.options()
        let base = try b.dataSet(from: baseOptions)
        var cases: [(String, Data, Bool)] = []
        func add(_ name: String, _ o: DicomWholeSlideMicroscopyBuildOptions) throws {
            cases.append((name, try b.part10Data(from: o), true))
        }
        func invalid(_ name: String, _ data: DicomDataSet) throws {
            cases.append((name, try DicomDataSetWriter.part10Data(from: data), false))
        }
        try add("wsi-tiled-full-pyramid-base", baseOptions)
        var o = baseOptions
        o.sopInstanceUID = "2.25.2348002"; o.seriesInstanceUID = "2.25.234811"
        o.matrixColumns = 2; o.matrixRows = 2; o.frames = [o.frames[0]]
        o.pixelSpacingXMillimeters *= 2; o.pixelSpacingYMillimeters *= 2
        o.derivation = .init(sourceSOPInstanceUID: baseOptions.sopInstanceUID, sourceStudyInstanceUID: baseOptions.studyInstanceUID,
            sourceSeriesInstanceUID: baseOptions.seriesInstanceUID, sourceFrames: [1, 2, 3, 4],
            code: .init(codeValue: "113085", codingSchemeDesignator: "DCM", codeMeaning: "Spatial resampling"), resampled: true)
        try add("wsi-tiled-full-level2", o)
        o = baseOptions; o.opticalPaths.append(fixture.path("B")); o.focalPlanes = 2
        o.frames = (0..<16).map { Data(repeating: UInt8($0 + 1), count: 12) }
        try add("wsi-tiled-full-two-paths-two-planes", o)
        o = baseOptions; o.organization = .tiledSparse
        o.positions = [.init(column: 3, row: 3, opticalPathIdentifier: "A"), .init(column: 1, row: 1, opticalPathIdentifier: "A"),
                       .init(column: 3, row: 1, opticalPathIdentifier: "A"), .init(column: 1, row: 3, opticalPathIdentifier: "A")]
        let sparse = try b.dataSet(from: o)
        try add("wsi-tiled-sparse-out-of-order", o)
        o.positions?.removeLast(); o.frames.removeLast()
        try add("wsi-tiled-sparse-missing-tile", o)
        o = baseOptions; o.matrixColumns = 3; o.matrixRows = 3
        try add("wsi-partial-edge-tiles", o)
        for flavor in [DicomWholeSlideImageType.Flavor.label, .overview, .thumbnail] {
            o = baseOptions; o.flavor = flavor; o.frames = [o.frames[0]]
            if flavor != .thumbnail { o.pyramidUID = nil; o.frameOfReferenceUID = nil }
            if flavor == .label { o.label = .init(barcodeValue: "SYNTHETIC", labelText: "Synthetic specimen") }
            try add("wsi-" + flavor.rawValue.lowercased(), o)
        }
        o = baseOptions; o.photometricInterpretation = "MONOCHROME2"; o.opticalPaths = [fixture.path("A", monochrome: true)]
        o.frames = (0..<4).map { Data(repeating: UInt8($0), count: 4) }
        try add("wsi-monochrome-fluorescence", o)
        let compressed = fixture.compressedOptions()
        let compressedSource = try b.part10Data(from: compressed)
        let passthrough = try b.rewrappedContainer(from: compressedSource) { $0 = $0.setting(c.text(0x00080018, .UI, "2.25.2348010")) }
        cases.append(("wsi-encapsulated-passthrough", passthrough, true))
        cases.append(("wsi-region-derived", try b.tileAlignedRegion(from: cases[0].1, columns: 2..<4, rows: 1..<3,
            sopInstanceUID: "2.25.2348011", seriesInstanceUID: "2.25.234812"), true))
        cases.append(("wsi-rewrapped-container", try b.rewrappedContainer(from: cases[0].1) {
            $0 = $0.setting(c.text(0x00080018, .UI, "2.25.2348012")).setting(c.text(0x0008103E, .LO, "Rewrapped WSI"))
        }, true))
        // Keep native frame lengths coherent so this negative measures the tiling rule specifically.
        try invalid("wsi-tiled-full-frame-count", base.setting(.init(tag: 0x00480006, vr: .UL, value: .unsignedIntegers([6]))))
        try invalid("wsi-sparse-without-positions", sparse.removing(0x52009230))
        func replaceFirstPosition(_ tag: Int, _ element: DicomDataElement) -> DicomDataSet {
            var items = sparse.sequenceItems(for: 0x52009230).map(\.dataSet)
            let first = items[0].sequenceItems(for: tag)[0].dataSet.setting(element)
            items[0] = items[0].setting(c.sequence(tag, [first]))
            return sparse.setting(c.sequence(0x52009230, items))
        }
        try invalid("wsi-position-outside-matrix", replaceFirstPosition(0x0048021A, .init(tag: 0x0048021E, vr: .SL, value: .signedIntegers([99]))))
        try invalid("wsi-unknown-optical-path", replaceFirstPosition(0x00480207, c.text(0x00480106, .SH, "MISSING")))
        try invalid("wsi-missing-icc", base.setting(c.sequence(0x00480105, base.sequenceItems(for: 0x00480105).map { $0.dataSet.removing(0x00282000) })))
        var label = base.setting(.init(tag: 0x00080008, vr: .CS, value: .strings(["ORIGINAL", "PRIMARY", "LABEL", "NONE"])))
            .setting(c.text(0x00480010, .CS, "YES")).setting(c.text(0x22000005, .LT, "")).setting(c.text(0x22000002, .UT, "")).removing(0x00080019)
        var shared = label.sequenceItems(for: 0x52009229)[0].dataSet
        shared = shared.setting(c.sequence(0x00400710, [.init(elements: [.init(tag: 0x00089007, vr: .CS, value: .strings(["ORIGINAL", "PRIMARY", "LABEL", "NONE"]))])]))
        label = label.setting(c.sequence(0x52009229, [shared]))
        try invalid("wsi-label-multiframe", label)
        try invalid("wsi-volume-depth-zero", base.setting(.init(tag: 0x00480003, vr: .FL, value: .floats([0]))))
        try invalid("wsi-bits-mismatch", base.setting(.init(tag: 0x00280101, vr: .US, value: .unsignedIntegers([7])))
            .setting(.init(tag: 0x00280102, vr: .US, value: .unsignedIntegers([6]))))
        try invalid("wsi-flavor-unknown", base.setting(.init(tag: 0x00080008, vr: .CS, value: .strings(["ORIGINAL", "PRIMARY", "UNKNOWN", "NONE"]))))
        XCTAssertEqual(cases.count, 22)
        let directory = ProcessInfo.processInfo.environment["DICOM_WSI_CORPUS_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let layers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
        for (name, bytes, valid) in cases {
            let decoder = try DCMDecoder(data: bytes)
            let report = try DicomInstanceValidator.validate(bytes, targets: [baseOptions.sopInstanceUID: base], imageConditions: fixture.facts)
            let outcome = report.outcome(requiring: layers)
            XCTAssertEqual(outcome, valid ? .passed : .failed, "\(name): \(report.diagnostics)")
            let hasReferences = decoder.dataSet.contains(0x00081115)
            var metadata: [String: Any] = ["outcome": outcome.rawValue, "sopClass": b.sopClassUID, "exit": valid ? (hasReferences ? 2 : 0) : 1]
            if valid, let model = decoder.wholeSlideMicroscopyMetadata {
                metadata["tiles"] = model.tiles.map { tile in [tile.frameIndex, tile.column, tile.row, tile.focalPlaneIndex,
                    model.opticalPaths.firstIndex(where: { $0.identifier == tile.opticalPathIdentifier }) ?? -1] }
            }
            if name == "wsi-encapsulated-passthrough" {
                metadata["sourceFrameSHA256"] = try b.frameBytes(DCMDecoder(data: compressedSource)).map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            }
            if name == "wsi-region-derived" {
                let model = try XCTUnwrap(decoder.wholeSlideMicroscopyMetadata)
                let point = try XCTUnwrap(DCMDecoder(data: cases[0].1).wholeSlideMicroscopyMetadata?.slideCoordinateTransform)
                    .slidePoint(forMatrixColumn: 3, row: 1)
                metadata["firstSourceTile"] = [3, 1]
                metadata["sourceOrigin"] = [baseOptions.origin.xMillimeters, baseOptions.origin.yMillimeters, baseOptions.origin.zMicrometers]
                metadata["expectedOrigin"] = [point.xMillimeters, point.yMillimeters, point.zMicrometers]
                XCTAssertEqual(model.totalPixelMatrixOrigin, point)
            }
            if let directory {
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }
}
