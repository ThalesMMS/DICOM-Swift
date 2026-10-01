import Foundation
import XCTest
@testable import DicomCore

final class DicomPrintLoopbackTests: XCTestCase {
    func test_refusedColorAndAnnotation_doNotProduceFilm() async throws {
        let output = DicomRasterPrintOutputProvider()
        let server = DicomDIMSEServer(configuration: .init(aeTitle: "PRINT", port: 0), print: .init(),
            printProvider: DicomPrintSCPProvider(outputProvider: output))
        try server.start()
        do {
            let port = try XCTUnwrap(server.listeningPort)
            let bitmap = try DicomRenderedBitmap(width: 1, height: 1, rgbData: Data([1, 2, 3]))
            let film = DicomFilm(filmBox: .init(), imageBoxes: [try .init(bitmap: bitmap)])
            let color = try DicomPrintJob(films: [film], printMode: .color)
            var annotated = film
            annotated.filmBox.annotationDisplayFormatID = "LABEL"
            annotated.annotations = [try .init(position: 1, text: "SYNTHETIC")]
            let annotation = try DicomPrintJob(films: [annotated])
            for (job, expected) in [(color, DicomPrintManagementError.printModeNotNegotiated(.color)),
                                    (annotation, .annotationBoxNotNegotiated)] {
                let scu = DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: port,
                    calledAETitle: "PRINT", callingAETitle: "SCU", timeout: 5))
                do {
                    _ = try await Task.detached { try scu.sendPrintJob(job) }.value
                    XCTFail("Refused capability produced a successful job")
                } catch { XCTAssertEqual(error as? DicomPrintManagementError, expected) }
            }
            let records = await output.records
            XCTAssertTrue(records.isEmpty)
        } catch { await server.stop(); throw error }
        await server.stop()
    }

    func test_scuToSCP_matchesPreviewAcrossLayoutsAndModes() async throws {
        for color in [false, true] {
            for layout in [DicomImageDisplayFormat.standard(columns: 2, rows: 1),
                           .row(imagesPerRow: [1, 2]), .col(imagesPerColumn: [1, 2])] {
                let output = DicomRasterPrintOutputProvider()
                let meta = color ? DicomNetworkUID.basicColorPrintManagementMetaSOPClass
                    : DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
                var printConfiguration = DicomPrintSCPConfiguration(capabilities: .init(acceptedSOPClassUIDs: [
                    meta, DicomNetworkUID.printJobSOPClass, DicomNetworkUID.basicAnnotationBoxSOPClass,
                    DicomNetworkUID.presentationLUTSOPClass
                ]))
                printConfiguration.outputWidth = 128
                printConfiguration.identify = true
                printConfiguration.annotationFormats = ["LABEL": 1]
                let server = DicomDIMSEServer(configuration: .init(aeTitle: "PRINT", port: 0),
                    print: printConfiguration, printProvider: DicomPrintSCPProvider(outputProvider: output))
                try server.start()
                do {
                    let port = try XCTUnwrap(server.listeningPort)
                    let bitmap = try DicomRenderedBitmap(width: 2, height: 2,
                        rgbData: Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]))
                    var first = try DicomImageBox(bitmap: bitmap)
                    first.originalImage = .init(elements: [printSCPString(0x0010_0010, "SAME", vr: .PN),
                        printSCPString(0x0020_000D, "2.25.1", vr: .UI)])
                    var second = first
                    second.position = 2
                    second.originalImage?.set(printSCPString(0x0020_000D, "2.25.2", vr: .UI))
                    let annotations = [try DicomPrintAnnotation(position: 1, text: "SYNTHETIC")]
                    let box = DicomFilmBox(displayFormat: layout, annotationDisplayFormatID: "LABEL")
                    let mixed = DicomFilm(filmBox: box, imageBoxes: [first, second], annotations: annotations)
                    second.originalImage = first.originalImage
                    let singleStudy = DicomFilm(filmBox: box, imageBoxes: [first, second], annotations: annotations)
                    let job = try DicomPrintJob(films: [mixed, singleStudy], printMode: color ? .color : .grayscale,
                        monitor: .untilDone(timeout: 10), presentationLUT: color ? nil : .init(shape: .linearOpticalDensity))
                    let preview = try DicomPrintPreview.compose(job: job, outputWidth: 128,
                        annotationFormats: ["LABEL": 1], identify: true)
                    let scu = DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: port,
                        calledAETitle: "PRINT", callingAETitle: "SCU", timeout: 10))
                    let result = try await Task.detached { try scu.sendPrintJob(job) }.value
                    XCTAssertEqual(result.state, .done)
                    let records = await output.records
                    XCTAssertEqual(records.count, 2)
                    XCTAssertEqual(records.map(\.film.fingerprint), preview.map(\.fingerprint))
                    XCTAssertEqual(records.map(\.film.pixelData), preview.map(\.pixelData))
                    XCTAssertEqual(records.first?.film.info.identificationByPosition.count, 2)
                    XCTAssertNil(records.first?.film.info.filmIdentification)
                    XCTAssertNotNil(records.last?.film.info.filmIdentification)
                    XCTAssertEqual(result.operations.filter { $0.kind == .eventReport }.compactMap(\.executionStatus),
                                   [.pending, .printing, .done, .pending, .printing, .done])
                } catch {
                    await server.stop()
                    throw error
                }
                await server.stop()
            }
        }
    }
}
