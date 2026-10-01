import Foundation
import XCTest
@testable import DicomCore

final class DicomRegistrationCorpusTests: XCTestCase {
    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied)

    func test_corpus_qualifiesRegistrationProfilesAndRejectsViolations() throws {
        let c = DicomRegistrationCoding.self
        let s = DicomSpatialRegistrationBuilderTests.self
        let d = DicomDeformableSpatialRegistrationTests.self
        let rigid = try s.data(s.document())
        let deformable = try d.data(d.document())
        let scale = DicomSpatialRegistrationMatrix(type: "RIGID_SCALE", rowMajorValues: [2,0,0,0, 0,3,0,0, 0,0,4,0, 0,0,0,1])
        let affine = DicomSpatialRegistrationMatrix(type: "AFFINE", rowMajorValues: [1,0.2,0,0, 0,1,0.3,0, 0,0,1,0, 0,0,0,1])
        func replace(_ root: DicomDataSet, _ path: [Int], _ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
            guard let tag = path.first else { return transform(root) }
            let items = root.sequenceItems(for: tag).map { replace($0.dataSet, Array(path.dropFirst()), transform) }
            return root.setting(c.sequence(tag, items))
        }
        let matrixPath = [0x00700308, 0x00700309, 0x0070030A]
        let cases: [(String, DicomDataSet, Bool)] = [
            ("reg-rigid-single", rigid, true),
            ("reg-rigid-two-items-common-frame", try s.data(s.document(twoItems: true)), true),
            ("reg-rigid-scale", try s.data(s.document(matrices: [scale])), true),
            ("reg-affine", try s.data(s.document(matrices: [affine])), true),
            ("reg-rigid-three-matrices-ordered", try s.data(s.document(matrices: s.ordered)), true),
            ("reg-with-used-fiducials-segments-rois", try s.data(s.document(usedReferences: true)), true),
            ("dreg-grid-only", deformable, true),
            ("dreg-pre-post-grid", try d.data(d.document(prePost: true)), true),
            ("dreg-nan-undefined", try d.data(d.document(nan: true)), true),
            ("dreg-matrix-item-plus-grid-item", try d.data(d.document(matrixItem: true)), true),
            ("reg-matrix-15-values", replace(rigid, matrixPath) { $0.setting(c.decimals(0x300600C6, Array(s.identity.rowMajorValues.prefix(15)))) }, false),
            ("reg-matrix-last-row", replace(rigid, matrixPath) { $0.setting(c.decimals(0x300600C6, Array(repeating: 0, count: 16))) }, false),
            ("reg-type-unknown", replace(rigid, matrixPath) { $0.setting(c.text(0x0070030C, .CS, "UNKNOWN")) }, false),
            ("reg-two-matrix-registration-items", replace(rigid, [0x00700308]) { data in
                let matrix = data.sequenceItems(for: 0x00700309)[0].dataSet
                return data.setting(c.sequence(0x00700309, [matrix, matrix]))
            }, false),
            ("reg-missing-frame-and-images", replace(rigid, [0x00700308]) { $0.removing(0x00200052).removing(0x00081140) }, false),
            ("reg-modality-wrong", rigid.setting(c.text(0x00080060, .CS, "CT")), false),
            ("dreg-vector-length-mismatch", replace(deformable, [0x00640002, 0x00640005]) {
                $0.setting(.init(tag: 0x00640009, vr: .OF, value: .bytes(Data(repeating: 0, count: 12))))
            }, false),
            ("dreg-no-grid-anywhere", replace(deformable, [0x00640002]) { $0.removing(0x00640005) }, false),
            ("dreg-resolution-zero", replace(deformable, [0x00640002, 0x00640005]) {
                $0.setting(.init(tag: 0x00640008, vr: .FD, value: .floats([1, 0, 1])))
            }, false),
            ("dreg-dimensions-two-values", replace(deformable, [0x00640002, 0x00640005]) {
                $0.setting(.init(tag: 0x00640007, vr: .UL, value: .unsignedIntegers([3, 3])))
            }, false)
        ]
        var targets: [String: DicomDataSet] = [:]
        for ref in s.references {
            targets[ref.sopInstanceUID] = .init(elements: [c.text(0x00080016, .UI, ref.sopClassUID),
                c.text(0x00080018, .UI, ref.sopInstanceUID), c.text(0x0020000D, .UI, "2.25.1"),
                c.text(0x0020000E, .UI, "2.25.2347115"), c.text(0x00280008, .IS, "2")])
        }
        let layers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
        let directory = ProcessInfo.processInfo.environment["DICOM_REGISTRATION_CORPUS_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        // The case list is fixed so stale or silently omitted cases cannot satisfy the oracle.
        XCTAssertEqual(cases.count, 20)
        for (name, data, valid) in cases {
            let bytes = try DicomGeometryCorpusTests.bytes(data)
            let report = try DicomInstanceValidator.validate(bytes, targets: targets, imageConditions: facts)
            let outcome = report.outcome(requiring: layers)
            XCTAssertEqual(outcome, valid ? .passed : .failed, "\(name): \(report.diagnostics)")
            var metadata: [String: Any] = ["outcome": outcome.rawValue, "sopClass": data.string(for: 0x00080016)!, "exit": valid ? 0 : 1]
            if name == "reg-rigid-three-matrices-ordered" {
                let model = try XCTUnwrap(DCMDecoder(data: bytes).spatialRegistration)
                let point = SIMD3<Double>(1,2,3)
                let mapped = try XCTUnwrap(model.registrations[0].registeredPoint(forSourcePoint: point))
                metadata["probePoint"] = [point.x, point.y, point.z]
                metadata["expectedMappedPoint"] = [mapped.x, mapped.y, mapped.z]
            }
            if name == "dreg-pre-post-grid" {
                let model = try XCTUnwrap(DicomDeformableSpatialRegistrationParser.parse(part10Data: bytes).document)
                let probes = [d.centre, d.half]
                metadata["probePoints"] = probes.map { [$0.x, $0.y, $0.z] }
                metadata["expectedMappedPoints"] = try probes.map { point -> [Double] in
                    let result = try XCTUnwrap(model.registrations[0].sourcePoint(forRegisteredPoint: point))
                    return [result.x, result.y, result.z]
                }
            }
            if name == "dreg-nan-undefined" {
                let model = try XCTUnwrap(DicomDeformableSpatialRegistrationParser.parse(part10Data: bytes).document)
                metadata["undefinedVectorCount"] = model.registrations[0].grid!.undefinedVectorCount
            }
            if let directory {
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }
}
