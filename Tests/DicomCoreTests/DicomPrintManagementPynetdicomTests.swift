import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

#if os(macOS)
final class DicomPrintManagementPynetdicomTests: XCTestCase {
    private func peer(_ config: [String: Any] = [:]) throws -> PynetdicomPeer {
        guard PynetdicomPeer.pythonPath != nil else {
            if ProcessInfo.processInfo.environment["DICOM_REQUIRE_PYNETDICOM"] == "1" {
                XCTFail("Required pynetdicom 3.0.4 is unavailable")
                throw NSError(domain: "PrintPeer", code: 1)
            }
            throw XCTSkip("pynetdicom unavailable")
        }
        return try PynetdicomPeer(configuration: ["print": config])
    }
    private func finish(_ peer: PynetdicomPeer, name: String = #function) throws -> [String: Any] {
        let json = try peer.stop()
        let directory = URL(fileURLWithPath: "/tmp/isis-2353-print-evidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name)-\(peer.port).json")
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        return json
    }
    private func verifyPixels(_ json: [String: Any], job: DicomPrintJob, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(json["pynetdicom"] as? String, "3.0.4", file: file, line: line)
        let films = try XCTUnwrap(json["films"] as? [[String: Any]], file: file, line: line)
        XCTAssertEqual(films.count, job.effectiveFilms.count, file: file, line: line)
        for (film, expected) in zip(films, job.effectiveFilms) {
            let images = try XCTUnwrap(film["images"] as? [[String: Any]])
            XCTAssertEqual(images.count, expected.imageBoxes.count, file: file, line: line)
            for (image, box) in zip(images, expected.imageBoxes) {
                let color = job.printMode == .color
                let data = box.dataSet(for: color ? .color : .grayscale)
                    .sequenceItems(for: color ? DicomPrintTag.basicColorImageSequence : DicomPrintTag.basicGrayscaleImageSequence)[0].dataSet
                let pixels = try XCTUnwrap(data.element(for: DicomTag.pixelData.rawValue))
                guard case .bytes(let bytes) = pixels.value else { return XCTFail("Missing pixels") }
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(image["sha256"] as? String, digest, file: file, line: line)
                XCTAssertEqual(image["position"] as? Int, box.position, file: file, line: line)
                XCTAssertEqual(image["rows"] as? Int, box.bitmap.height, file: file, line: line)
                XCTAssertEqual(image["columns"] as? Int, box.bitmap.width, file: file, line: line)
                XCTAssertEqual(image["photometric"] as? String, color ? "RGB" : "MONOCHROME2", file: file, line: line)
                if color {
                    XCTAssertEqual(image["planar_configuration"] as? Int, 1, file: file, line: line)
                }
            }
            let annotations = try XCTUnwrap(film["annotations"] as? [[String: Any]])
            XCTAssertEqual(annotations.compactMap { $0["text"] as? String }, expected.annotations.map(\.text), file: file, line: line)
        }
    }
    func test_grayscaleColorStandardRowCol_pixelIdentity() throws {
        for color in [false, true] {
            for layout in ["STANDARD\\2,1", "ROW\\1,2", "COL\\2,1"] {
                let peer = try peer()
                defer { _ = try? finish(peer) }
                let job = try printTestJob(films: 2, layout: layout, color: color)
                let result = try printTestSCU(port: peer.port).sendPrintJob(job)
                XCTAssertEqual(result.state, .accepted)
                XCTAssertNotEqual(result.filmSessionSOPInstanceUID, job.filmSessionSOPInstanceUID)
                let json = try finish(peer)
                try verifyPixels(json, job: job)
                let films = try XCTUnwrap(json["films"] as? [[String: Any]])
                XCTAssertEqual(films.compactMap { $0["uid"] as? String }, result.filmResults.compactMap(\.sopInstanceUID))
                XCTAssertTrue(films.allSatisfy { $0["deleted"] as? Bool == true })
            }
        }
    }
    func test_sameNameDifferentStudyUID_annotationsAndSessionCollation() throws {
        let peer = try peer(["annotation_formats": ["LABEL": 1]])
        defer { _ = try? finish(peer) }
        var job = try printTestJob(films: 2, annotations: true)
        job.printScope = .filmSession
        job.filmSession.numberOfCopies = 2
        let result = try printTestSCU(port: peer.port).sendPrintJob(job)
        XCTAssertEqual(result.state, .accepted)
        let json = try finish(peer)
        try verifyPixels(json, job: job)
        let actions = try XCTUnwrap(json["print_operations"] as? [[String: Any]]).filter { $0["operation"] as? String == "action" }
        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?["sop_class"] as? String, DicomNetworkUID.basicFilmSessionSOPClass)
        XCTAssertEqual((json["print_sessions"] as? [[String: Any]])?.first?["copies"] as? Int, 2)
        let filmUIDs = result.filmResults.compactMap(\.sopInstanceUID)
        XCTAssertEqual(json["print_order"] as? [String], filmUIDs + filmUIDs)
    }
    func test_presentationLUTAndConfiguration() throws {
        let configuration: [[String: Any]] = [[
            "SOPClassesSupported": [DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass, DicomNetworkUID.presentationLUTSOPClass],
            "MaximumCollatedFilms": 4, "DefaultPrinterResolutionID": "STANDARD", "DecimateCropResult": "DEF FAIL",
            "SupportedImageDisplayFormatsSequence": [["ImageDisplayFormat": "STANDARD\\1,1", "FilmOrientation": "PORTRAIT",
                "FilmSizeID": "8INX10IN", "PrinterResolutionID": "STANDARD", "RequestedImageSizeFlag": "YES"]]
        ]]
        let peer = try peer(["configuration": configuration])
        defer { _ = try? finish(peer) }
        var job = try printTestJob()
        job.presentationLUT = .init(shape: .linearOpticalDensity)
        job.films[0].filmBox.illumination = 2000
        job.films[0].imageBoxes[0].requestedImageSize = 100
        let result = try printTestSCU(port: peer.port).sendPrintJob(job)
        XCTAssertNotNil(result.presentationLUTSOPInstanceUID)
        XCTAssertEqual(result.capabilities?.printerConfiguration?.printers.count, 1)
        XCTAssertEqual(result.operations.filter { $0.sopClassUID == DicomNetworkUID.presentationLUTSOPClass }.map(\.kind), [.create, .delete])
        let json = try finish(peer)
        try verifyPixels(json, job: job)
    }
    func test_printJobEvents_pendingPrintingDone() throws {
        let peer = try peer(["jobs": true])
        defer { _ = try? finish(peer) }
        var job = try printTestJob()
        job.monitor = .untilDone(timeout: 4)
        let result = try printTestSCU(port: peer.port).sendPrintJob(job)
        XCTAssertEqual(result.state, .done, "\(result)")
        XCTAssertEqual(result.executionStatus, .done)
        let json = try finish(peer)
        XCTAssertEqual((json["job_events"] as? [[String: Any]])?.compactMap { $0["type"] as? Int }, [1, 2, 3], "\(json)")
        try verifyPixels(json, job: job)
    }
    func test_monitorTimeout_doesNotClaimCompletion() throws {
        let peer = try peer(["jobs": true, "job_stall": true])
        defer { _ = try? finish(peer) }
        var job = try printTestJob()
        job.monitor = .untilDone(timeout: 0.2)
        let started = Date()
        XCTAssertThrowsError(try printTestSCU(port: peer.port).sendPrintJob(job)) {
            XCTAssertEqual($0 as? DicomPrintManagementError, .monitoringTimedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
    func test_printJobFailure_neverSuccess() throws {
        let peer = try peer(["jobs": true, "job_failure": true])
        defer { _ = try? finish(peer) }
        var job = try printTestJob()
        job.monitor = .untilDone(timeout: 4)
        XCTAssertThrowsError(try printTestSCU(port: peer.port).sendPrintJob(job)) {
            XCTAssertEqual($0 as? DicomPrintManagementError, .printJobFailure(statusInfo: .filmJam))
        }
        let json = try finish(peer)
        XCTAssertEqual((json["job_events"] as? [[String: Any]])?.last?["type"] as? Int, 4)
    }
    func test_colorAndAnnotationContextRefusals_noFilm() throws {
        for annotation in [false, true] {
            let peer = try peer(annotation ? ["refuse_annotation_context": true] : ["refuse_color_contexts": true])
            defer { _ = try? finish(peer) }
            let job = try printTestJob(color: !annotation, annotations: annotation)
            XCTAssertThrowsError(try printTestSCU(port: peer.port).sendPrintJob(job)) {
                XCTAssertEqual($0 as? DicomPrintManagementError, annotation ? .annotationBoxNotNegotiated : .printModeNotNegotiated(.color))
            }
            XCTAssertEqual((try finish(peer)["films"] as? [Any])?.count, 0)
        }
    }
    func test_failingCreateSetActionAndInsufficientBoxes_noAcceptance() throws {
        for config: [String: Any] in [["fail_create": 0xC600], ["fail_set": 0xC605], ["fail_action": 0xC602], ["insufficient_boxes": 1]] {
            let peer = try peer(config)
            defer { _ = try? finish(peer) }
            let job = try printTestJob()
            XCTAssertThrowsError(try printTestSCU(port: peer.port).sendPrintJob(job))
            let json = try finish(peer)
            if config["fail_set"] != nil || config["fail_action"] != nil { try verifyPixels(json, job: job) }
            let films = try XCTUnwrap(json["films"] as? [[String: Any]])
            XCTAssertFalse(films.contains { $0["accepted"] as? Bool == true })
            if config["insufficient_boxes"] != nil {
                XCTAssertEqual((films.first?["images"] as? [Any])?.count, 0)
            }
        }
    }

    func test_peerImageBoxLimit_rejectsBeforeCreatingFilmState() throws {
        let cases: [([String: Any], String)] = [
            ([:], "STANDARD\\13,5"),
            (["max_image_boxes": 4], "STANDARD\\3,2"),
            (["max_image_boxes": 4], "ROW\\3,2"),
            (["max_image_boxes": 4], "COL\\3,2")
        ]
        for (configuration, layout) in cases {
            let peer = try peer(configuration)
            defer { _ = try? finish(peer) }
            var job = try printTestJob()
            job.films[0].filmBox.imageDisplayFormat = layout
            XCTAssertThrowsError(try printTestSCU(port: peer.port).sendPrintJob(job))
            let json = try finish(peer)
            XCTAssertEqual((json["films"] as? [Any])?.count, 0)
            let sessions = try XCTUnwrap(json["print_sessions"] as? [[String: Any]])
            XCTAssertTrue(sessions.allSatisfy { ($0["films"] as? [String])?.isEmpty == true })
            let operations = try XCTUnwrap(json["print_operations"] as? [[String: Any]])
            let create = operations.first {
                $0["operation"] as? String == "create" && $0["sop_class"] as? String == DicomNetworkUID.basicFilmBoxSOPClass
            }
            XCTAssertEqual(create?["status"] as? Int, 0x0106)
        }
    }

    func test_peerImageBoxLimit_acceptsBoundaryAndConfiguredOverride() throws {
        let cases: [([String: Any], String)] = [
            ([:], "STANDARD\\8,8"),
            (["max_image_boxes": 4], "STANDARD\\2,2"),
            (["max_image_boxes": 6], "STANDARD\\3,2")
        ]
        for (configuration, layout) in cases {
            let peer = try peer(configuration)
            defer { _ = try? finish(peer) }
            var job = try printTestJob()
            job.films[0].filmBox.imageDisplayFormat = layout
            let result = try printTestSCU(port: peer.port).sendPrintJob(job)
            XCTAssertEqual(result.state, .accepted)
            XCTAssertEqual(result.filmResults.first?.imageBoxSOPInstanceUIDs.count, 1)
        }
    }

    func test_batchFailure_preservesPerFilmOperationStatus() throws {
        let peer = try peer(["fail_action": 0xC602])
        defer { _ = try? finish(peer) }
        let batch = try DicomPrintBatch(jobs: [printTestJob(), printTestJob()])
        let result = try printTestSCU(port: peer.port).sendPrintBatch(batch)
        XCTAssertEqual(result.results.count, 2)
        XCTAssertEqual(result.films.map(\.state), [.failed, .failed])
        for film in result.films {
            XCTAssertEqual(film.operations.first { $0.kind == .action }?.status, 0xC602)
        }
    }
    func test_unknownAttributeWarning_retained() throws {
        let peer = try peer(["unknown_attribute_warning": true])
        defer { _ = try? finish(peer) }
        let job = try printTestJob()
        let result = try printTestSCU(port: peer.port).sendPrintJob(job)
        XCTAssertTrue(result.warnings.contains { $0.status == 0x0107 })
        try verifyPixels(finish(peer), job: job)
    }
    func test_cancelAfterFirstFilm_partialIdentityPreserved() throws {
        let peer = try peer()
        defer { _ = try? finish(peer) }
        let job = try printTestJob(films: 2)
        var requests = 0
        let result = try printTestSCU(port: peer.port).sendPrintJob(job) { progress in
            if case .requestSent = progress {
                requests += 1
                // Printer, configuration, session, film, image, action.
                if requests == 6 { job.cancellationToken.cancel() }
            }
        }
        XCTAssertEqual(result.state, .cancelled)
        XCTAssertEqual(result.filmResults.map(\.state), [.accepted, .cancelled])
        let json = try finish(peer)
        let films = try XCTUnwrap(json["films"] as? [[String: Any]])
        XCTAssertEqual(films.count, 1)
        XCTAssertEqual(films.first?["accepted"] as? Bool, true)
        XCTAssertEqual(films.first?["deleted"] as? Bool, true)
        var acceptedJob = job
        acceptedJob.films = Array(job.films.prefix(1))
        try verifyPixels(json, job: acceptedJob)
    }
    func test_mixedStudies_preformattedBurnInVersusAnnotation() throws {
        for burnIn in [false, true] {
            let peer = try peer(["annotation_formats": ["LABEL": 1]])
            defer { _ = try? finish(peer) }
            var job = try printTestJob(films: 2, layout: "ROW\\1,1", annotations: !burnIn)
            for filmIndex in job.films.indices {
                for imageIndex in job.films[filmIndex].imageBoxes.indices {
                    let study = "2.25.\(filmIndex + 1).\(imageIndex + 1)"
                    if burnIn {
                        job.films[filmIndex].imageBoxes[imageIndex].bitmap = try identificationBitmap("SAME^NAME STUDY " + study)
                    }
                    job.films[filmIndex].imageBoxes[imageIndex].originalImage = .init(elements: [
                        printTestString(DicomTag.studyInstanceUID.rawValue, study, .UI),
                        printTestString(DicomTag.seriesInstanceUID.rawValue, study + ".1", .UI),
                        printTestString(DicomTag.patientID.rawValue, "SYNTHETIC", .LO),
                        printTestString(DicomTag.referencedSOPClassUID.rawValue, DicomStorageSOPClassUIDs.secondaryCaptureImageStorage, .UI),
                        printTestString(DicomTag.referencedSOPInstanceUID.rawValue, study + ".1.1", .UI)
                    ])
                }
                if !burnIn {
                    job.films[filmIndex].annotations = [try DicomPrintAnnotation(position: 1,
                        text: "SAME^NAME STUDIES 2.25.\(filmIndex + 1).1 / 2.25.\(filmIndex + 1).2")]
                }
            }
            _ = try printTestSCU(port: peer.port).sendPrintJob(job)
            let json = try finish(peer)
            try verifyPixels(json, job: job)
            let films = try XCTUnwrap(json["films"] as? [[String: Any]])
            for (index, film) in films.enumerated() {
                let images = try XCTUnwrap(film["images"] as? [[String: Any]])
                for (position, image) in images.enumerated() {
                    let original = try XCTUnwrap((image["original_image"] as? [[String: Any]])?.first)
                    let study = try XCTUnwrap(original["0020000D"] as? [String: Any])
                    XCTAssertEqual(study["Value"] as? [String], ["2.25.\(index + 1).\(position + 1)"])
                }
            }
        }
    }

    private func identificationBitmap(_ text: String) throws -> DicomRenderedBitmap {
        let width = 320, height = 32
        var gray = [UInt8](repeating: 0, count: width * height)
        try gray.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0))
            context.setFillColor(gray: 1, alpha: 1)
            context.textPosition = CGPoint(x: 2, y: 10)
            let attributes = [kCTFontAttributeName: CTFontCreateWithName("Helvetica" as CFString, 12, nil),
                              kCTForegroundColorFromContextAttributeName: true] as [CFString: Any]
            let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        XCTAssertTrue(gray.contains { $0 != 0 })
        return try DicomRenderedBitmap(width: width, height: height, rgbData: Data(gray.flatMap { [$0, $0, $0] }))
    }

    func test_printerFailureEventBeforeAction_refusedAndAcknowledged() throws {
        let peer = try peer(["printer_event": 3, "printer_status_info": "FILM JAM"])
        defer { _ = try? finish(peer) }
        XCTAssertThrowsError(try printTestSCU(port: peer.port).sendPrintJob(printTestJob())) {
            XCTAssertEqual($0 as? DicomPrintManagementError, .printerFailure(statusInfo: "FILM JAM"))
        }
        let json = try finish(peer)
        XCTAssertEqual((json["films"] as? [Any])?.count, 0)
        XCTAssertTrue((json["commands"] as? [[String: Any]])?.contains {
            $0["field"] as? Int == Int(DicomDIMSECommandField.nEventReportRSP)
        } == true)
    }
    func test_annotationSetRefusalOrIgnoredText_neverPrints() throws {
        for warning in [false, true] {
            let config: [String: Any] = ["annotation_formats": ["LABEL": 1],
                "fail_set": [DicomNetworkUID.basicAnnotationBoxSOPClass: warning ? 0x0107 : 0xC000]]
            let peer = try peer(config)
            defer { _ = try? finish(peer) }
            let job = try printTestJob(annotations: true)
            XCTAssertThrowsError(try printTestSCU(port: peer.port).sendPrintJob(job)) {
                XCTAssertEqual($0 as? DicomPrintManagementError, warning ? .annotationIgnored(position: 1, status: 0x0107)
                    : .annotationSetFailed(position: 1, status: 0xC000))
            }
            let json = try finish(peer)
            XCTAssertFalse((json["films"] as? [[String: Any]])?.contains { $0["accepted"] as? Bool == true } == true)
            var expected = job
            expected.films[0].annotations = []
            try verifyPixels(json, job: expected)
        }
    }
    func test_lutTable_roundTripsThroughIndependentSCP() throws {
        let peer = try peer()
        defer { _ = try? finish(peer) }
        var job = try printTestJob()
        job.presentationLUT = try .init(descriptor: [256, 0, 10], values: (0..<256).map { UInt16($0 * 4) })
        let result = try printTestSCU(port: peer.port).sendPrintJob(job)
        XCTAssertNotNil(result.presentationLUTSOPInstanceUID)
        try verifyPixels(finish(peer), job: job)
    }
    func test_printerFailureBeforeAction_refused() throws {
        let peer = try peer(["printer_status": "FAILURE", "printer_status_info": "FILM JAM"])
        defer { _ = try? finish(peer) }
        XCTAssertThrowsError(try printTestSCU(port: peer.port).sendPrintJob(printTestJob())) {
            XCTAssertEqual($0 as? DicomPrintManagementError, .printerFailure(statusInfo: "FILM JAM"))
        }
        XCTAssertEqual((try finish(peer)["films"] as? [Any])?.count, 0)
    }
}
#endif
