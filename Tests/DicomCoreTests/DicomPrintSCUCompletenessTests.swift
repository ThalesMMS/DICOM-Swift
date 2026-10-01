import Foundation
import XCTest
@testable import DicomCore

final class DicomPrintSCUCompletenessTests: XCTestCase {
    func test_sparsePositions_usePeerUIDsAtConfiguredPositions() throws {
        let transport = PrintScriptedTransport()
        transport.imageUIDs = ["2.25.91", "2.25.92", "2.25.93"]
        transport.annotationUIDs = ["2.25.81", "2.25.82", "2.25.83"]
        var job = try printTestJob(layout: "STANDARD\\3,1", annotations: true)
        job.films[0].imageBoxes = [job.films[0].imageBoxes[2], job.films[0].imageBoxes[0]]
        job.films[0].annotations = [try .init(position: 3, text: "THIRD"), try .init(position: 1, text: "FIRST")]
        let result = try printTestSCU().sendPrintJob(job, using: transport)
        let usedImages = ["2.25.93", "2.25.91"]
        let usedAnnotations = ["2.25.83", "2.25.81"]
        XCTAssertEqual(result.filmResults[0].imageBoxSOPInstanceUIDs, usedImages)
        XCTAssertEqual(result.filmResults[0].annotationBoxSOPInstanceUIDs, usedAnnotations)
        XCTAssertEqual(result.imageBoxSOPInstanceUIDs, usedImages)
        XCTAssertEqual(transport.commands.filter { $0.commandField == DicomDIMSECommandField.nSetRQ }
            .compactMap(\.requestedSOPInstanceUID), usedImages + usedAnnotations)
    }

    func test_peerUIDs_lutLifecycleAndSessionScope() throws {
        let transport = PrintScriptedTransport()
        var job = try printTestJob(films: 2)
        job.printScope = .filmSession
        job.presentationLUT = .init(shape: .identity)
        let result = try printTestSCU().sendPrintJob(job, using: transport)
        XCTAssertEqual(result.filmSessionSOPInstanceUID, "2.25.1002")
        XCTAssertEqual(result.filmResults.count, 2)
        XCTAssertEqual(result.filmResults.map(\.state), [.accepted, .accepted])
        let creates = result.operations.filter { $0.kind == .create }
        XCTAssertEqual(creates.count, 4)
        let actions = result.operations.filter { $0.kind == .action }
        XCTAssertEqual(actions.map(\.sopInstanceUID), [result.filmSessionSOPInstanceUID])
        XCTAssertEqual(actions.map(\.sopClassUID), [DicomNetworkUID.basicFilmSessionSOPClass])
        let deletions = result.operations.filter { $0.kind == .delete }
        XCTAssertEqual(deletions.map(\.sopInstanceUID), result.filmResults.reversed().map(\.sopInstanceUID)
                       + [result.filmSessionSOPInstanceUID, result.presentationLUTSOPInstanceUID])
        for data in transport.datasets where data.string(for: DicomPrintTag.imageDisplayFormat) != nil {
            XCTAssertEqual(data.sequenceItems(for: DicomPrintTag.referencedFilmSessionSequence).first?.dataSet
                .string(for: .referencedSOPInstanceUID), result.filmSessionSOPInstanceUID)
            XCTAssertEqual(data.sequenceItems(for: 0x2050_0500).first?.dataSet.string(for: .referencedSOPInstanceUID),
                           result.presentationLUTSOPInstanceUID)
        }
    }

    func test_sopMismatch_refusesBeforeSet() throws {
        let transport = PrintScriptedTransport()
        transport.imageSOP = DicomNetworkUID.basicColorImageBoxSOPClass
        XCTAssertThrowsError(try printTestSCU().sendPrintJob(printTestJob(), using: transport)) {
            XCTAssertEqual($0 as? DicomPrintManagementError, .sopClassMismatch(
                expected: DicomNetworkUID.basicGrayscaleImageBoxSOPClass, received: DicomNetworkUID.basicColorImageBoxSOPClass))
        }
        XCTAssertFalse(transport.commands.contains { $0.commandField == DicomDIMSECommandField.nSetRQ })
    }

    func test_cancelAfterCreate_cleansWithoutSetOrAction() throws {
        let transport = PrintScriptedTransport()
        let job = try printTestJob()
        transport.afterResponse = { command in
            if command.affectedSOPClassUID == DicomNetworkUID.basicFilmBoxSOPClass { job.cancellationToken.cancel() }
        }
        let result = try printTestSCU().sendPrintJob(job, using: transport)
        XCTAssertEqual(result.state, .cancelled)
        XCTAssertEqual(result.operations.filter { $0.kind == .delete }.count, 2)
        XCTAssertFalse(transport.commands.contains { [DicomDIMSECommandField.nSetRQ, DicomDIMSECommandField.nActionRQ].contains($0.commandField) })
    }

    func test_allWarningsRetained_deleteFailureDoesNotFailJob() throws {
        let transport = PrintScriptedTransport()
        transport.statuses = [DicomDIMSECommandField.nCreateRQ: 0xB605,
                              DicomDIMSECommandField.nSetRQ: 0xB604, DicomDIMSECommandField.nDeleteRQ: 0x0112]
        let result = try printTestSCU().sendPrintJob(printTestJob(), using: transport)
        XCTAssertEqual(result.state, .accepted)
        XCTAssertEqual(result.operation.status, 0xB605)
        XCTAssertEqual(result.operations.filter { $0.status == 0xB605 }.count, 2)
        XCTAssertEqual(result.operations.filter { $0.status == 0xB604 }.count, 1)
        XCTAssertEqual(result.operations.filter { $0.status == 0x0112 }.count, 2)
        XCTAssertGreaterThanOrEqual(result.warnings.count, 5)
    }

    func test_printerFailure_refusesBeforeCreate() throws {
        let transport = PrintScriptedTransport()
        transport.printerState = "FAILURE"
        XCTAssertThrowsError(try printTestSCU().sendPrintJob(printTestJob(), using: transport)) {
            XCTAssertEqual($0 as? DicomPrintManagementError, .printerFailure(statusInfo: "FILM JAM"))
        }
        XCTAssertEqual(transport.commands.map(\.commandField), [DicomDIMSECommandField.nGetRQ])
    }

    func test_optionalImageSize_unknownRequiresForce() throws {
        for force in [false, true] {
            let transport = PrintScriptedTransport()
            var job = try printTestJob()
            job.films[0].imageBoxes[0].requestedImageSize = 120
            job.films[0].imageBoxes[0].forceRequestedImageSize = force
            _ = try printTestSCU().sendPrintJob(job, using: transport)
            let image = try XCTUnwrap(transport.datasets.first { !$0.sequenceItems(for: DicomPrintTag.basicGrayscaleImageSequence).isEmpty })
            XCTAssertEqual(image.string(for: 0x2020_0030) != nil, force)
        }
    }

    func test_lutNegotiationRefusal_isNonRetryable() {
        XCTAssertTrue(DicomDIMSEServiceSCU.isNonRetryablePrintRefusal(.unsupportedService("Presentation LUT was not negotiated")))
    }

    func test_identificationRefusals_neverProceed() throws {
        let capabilities = DicomPrintPeerCapabilities(acceptedSOPClassUIDs: [DicomNetworkUID.basicAnnotationBoxSOPClass])
        let failures: [DicomPrintManagementError] = [.annotationBoxNotNegotiated,
            .insufficientAnnotationBoxes(requested: 2, granted: 1), .annotationSetFailed(position: 1, status: 0xC000),
            .annotationIgnored(position: 1, status: 0x0107)]
        for failure in failures {
            for burnIn in [false, true] {
                let decision = DicomPrintIdentificationGate.decide(requested: .init(requiresAnnotation: true, allowsBurnIn: burnIn),
                                                                  negotiated: capabilities, failure: failure)
                if burnIn {
                    guard case .recomposeWithBurnIn(_, requiresOperatorConfirmation: true) = decision else { return XCTFail("\(decision)") }
                } else {
                    guard case .blocked = decision else { return XCTFail("\(decision)") }
                }
            }
        }
        XCTAssertEqual(DicomPrintIdentificationGate.decide(requested: .init(requiresAnnotation: true), negotiated: capabilities), .proceed)
    }
}

func printTestSCU(port: UInt16 = 104) -> DicomDIMSEServiceSCU {
    DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: port,
                                             calledAETitle: "PYNETDICOM", callingAETitle: "ISIS", timeout: 5))
}
func printTestJob(films: Int = 1, layout: String = "STANDARD\\1,1", color: Bool = false,
                  annotations: Bool = false) throws -> DicomPrintJob {
    let count = try DicomImageDisplayFormat(wireValue: layout).imageBoxCapacity ?? 1
    return try DicomPrintJob(films: (0..<films).map { film in
        DicomFilm(id: "film-\(film)", filmBox: .init(imageDisplayFormat: layout,
                                                  annotationDisplayFormatID: annotations ? "LABEL" : nil),
            imageBoxes: try (1...count).map { position in
                try DicomImageBox(position: position, bitmap: DicomRenderedBitmap(width: 2, height: 2,
                    rgbData: Data((0..<12).map { UInt8(film * 20 + position * 10 + $0) })))
            }, annotations: annotations ? [try DicomPrintAnnotation(position: 1, text: "SAME^NAME STUDY 2.25.\(film + 1)")] : [])
    }, printMode: color ? .color : .grayscale)
}

final class PrintScriptedTransport: DicomAssociationTransport {
    var commands: [DicomDIMSECommandSet] = []
    var datasets: [DicomDataSet] = []
    var statuses: [UInt16: UInt16] = [:]
    var imageSOP = DicomNetworkUID.basicGrayscaleImageBoxSOPClass
    var imageUIDs = ["2.25.99"]
    var annotationUIDs: [String] = []
    var printerState = "NORMAL"
    var jobEvents: [UInt16] = []
    var afterResponse: ((DicomDIMSECommandSet) -> Void)?
    private var queue: [Data] = []
    private var pending: DicomDIMSECommandSet?
    private var bytes = Data()
    private var contexts: [UInt8: DicomTransferSyntax] = [:]
    func writePDU(_ data: Data) throws {
        switch try DicomPDUCodec.decode(data) {
        case .associationRequest(let request):
            var supported: Set<String> = [DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                DicomNetworkUID.basicAnnotationBoxSOPClass, DicomNetworkUID.presentationLUTSOPClass]
            if !jobEvents.isEmpty { supported.insert(DicomNetworkUID.printJobSOPClass) }
            let accept = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: supported,
                                                           preferredTransferSyntaxes: [.explicitVRLittleEndian])
            for context in accept.presentationContexts { contexts[context.id] = .explicitVRLittleEndian }
            queue.append(try DicomPDUCodec.encode(.associationAccept(accept)))
        case .pData(let pdvs):
            for pdv in pdvs {
                if pdv.isCommand {
                    let command = try DicomDIMSECommandSet.decode(pdv.data)
                    commands.append(command); pending = command
                    if command.commandField & 0x8000 == 0 && command.commandDataSetType == DicomDIMSECommandDataSetType.noDataSet {
                        try respond(command, context: pdv.presentationContextID)
                    }
                } else {
                    bytes.append(pdv.data)
                    if pdv.isLastFragment {
                        datasets.append(try DicomDataSetParser.dataSet(from: bytes, transferSyntax: .explicitVRLittleEndian))
                        bytes = Data()
                        try respond(XCTUnwrap(pending), context: pdv.presentationContextID)
                    }
                }
            }
        case .releaseRequest: queue.append(try DicomPDUCodec.encode(.releaseResponse))
        default: break
        }
    }
    func readPDU() throws -> Data {
        guard !queue.isEmpty else { throw DicomNetworkError.networkUnavailable("No scripted response") }
        return queue.removeFirst()
    }
    private func respond(_ command: DicomDIMSECommandSet, context: UInt8) throws {
        var data: DicomDataSet?
        if command.commandField == DicomDIMSECommandField.nGetRQ {
            data = .init(elements: [printTestString(DicomPrintTag.printerStatus, printerState),
                                    printTestString(DicomPrintTag.printerStatusInfo, "FILM JAM")])
        }
        if command.affectedSOPClassUID == DicomNetworkUID.basicFilmBoxSOPClass {
            func references(_ uids: [String], sopClass: String) -> [DicomSequenceItem] {
                uids.map { uid in
                    .init(dataSet: .init(elements: [
                        printTestString(DicomTag.referencedSOPClassUID.rawValue, sopClass, .UI),
                        printTestString(DicomTag.referencedSOPInstanceUID.rawValue, uid, .UI)
                    ]))
                }
            }
            data = .init(elements: [
                .init(tag: DicomPrintTag.referencedImageBoxSequence, vr: .SQ,
                      value: .sequence(references(imageUIDs, sopClass: imageSOP))),
                .init(tag: DicomPrintTag.referencedBasicAnnotationBoxSequence, vr: .SQ,
                      value: .sequence(references(annotationUIDs, sopClass: DicomNetworkUID.basicAnnotationBoxSOPClass)))
            ])
        }
        if command.commandField == DicomDIMSECommandField.nActionRQ && !jobEvents.isEmpty {
            data = .init(elements: [DicomDataElement(tag: DicomPrintTag.referencedPrintJobSequence, vr: .SQ,
                value: .sequence([DicomSequenceItem(dataSet: .init(elements: [
                    printTestString(DicomTag.referencedSOPClassUID.rawValue, DicomNetworkUID.printJobSOPClass, .UI),
                    printTestString(DicomTag.referencedSOPInstanceUID.rawValue, "2.25.8000", .UI)
                ]))]))])
        }
        let response = DicomDIMSECommandSet(affectedSOPClassUID: command.affectedSOPClassUID,
            commandField: command.commandField | 0x8000, messageIDBeingRespondedTo: command.messageID,
            commandDataSetType: data == nil ? DicomDIMSECommandDataSetType.noDataSet : DicomDIMSECommandDataSetType.hasDataSet,
            status: statuses[command.commandField] ?? 0,
            affectedSOPInstanceUID: command.commandField == DicomDIMSECommandField.nCreateRQ ? "2.25.\(1000 + commands.count)" : nil)
        queue.append(try DicomPDUCodec.encode(.pData([DicomPDV(presentationContextID: context, isCommand: true,
                                                             isLastFragment: true, data: response.encoded())])))
        if let data {
            let payload = try DicomDataSetWriter.dataSetData(from: data, transferSyntax: .explicitVRLittleEndian)
            queue.append(try DicomPDUCodec.encode(.pData([DicomPDV(presentationContextID: context, isCommand: false,
                                                                 isLastFragment: true, data: payload)])))
        }
        if command.commandField == DicomDIMSECommandField.nActionRQ {
            for event in jobEvents {
                let eventCommand = DicomDIMSECommandSet(affectedSOPClassUID: DicomNetworkUID.printJobSOPClass,
                    commandField: DicomDIMSECommandField.nEventReportRQ, messageID: 0x7100 + event,
                    commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
                    affectedSOPInstanceUID: "2.25.8000", eventTypeID: event)
                queue.append(try DicomPDUCodec.encode(.pData([DicomPDV(presentationContextID: context,
                    isCommand: true, isLastFragment: true, data: eventCommand.encoded())])))
                let info = DicomDataSet(elements: [printTestString(DicomPrintTag.executionStatusInfo,
                    event == 4 ? "FILM JAM" : event == 1 ? "QUEUED" : "NORMAL")])
                queue.append(try DicomPDUCodec.encode(.pData([DicomPDV(presentationContextID: context,
                    isCommand: false, isLastFragment: true,
                    data: DicomDataSetWriter.dataSetData(from: info, transferSyntax: .explicitVRLittleEndian))])))
            }
        }
        afterResponse?(command)
    }
}
func printTestString(_ tag: Int, _ value: String, _ vr: DicomVR = .CS) -> DicomDataElement {
    .init(tag: tag, vr: vr, value: .strings([value]))
}

extension DicomPrintSCUCompletenessTests {
    func test_queueCancellationAndPartialResults() throws {
        let queue = DicomPrintJobQueue()
        let job = try printTestJob()
        queue.enqueue(job)
        queue.cancel(id: job.id)
        XCTAssertTrue(job.cancellationToken.isCancelled)
        XCTAssertEqual(queue.entries.first?.status, .cancelled)
        let result = try printTestSCU().sendPrintJob(job, using: PrintScriptedTransport())
        queue.recordResult(id: job.id, result: result)
        XCTAssertEqual(queue.result(id: job.id)?.state, .cancelled)
        XCTAssertTrue(result.operations.isEmpty)
    }
    func test_negotiatedConfigurationNo_cannotBeForced() throws {
        let format = DicomDataSet(elements: [
            printTestString(DicomPrintTag.imageDisplayFormat, "STANDARD\\1,1", .ST),
            printTestString(DicomPrintTag.filmOrientation, "PORTRAIT"),
            printTestString(DicomPrintTag.filmSizeID, "8INX10IN"),
            printTestString(DicomPrintTag.requestedImageSizeFlag, "NO")
        ])
        let printer = DicomDataSet(elements: [
            printTestString(DicomPrintTag.sopClassesSupported, DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass, .UI),
            DicomDataElement(tag: DicomPrintTag.supportedImageDisplayFormatsSequence, vr: .SQ,
                             value: .sequence([DicomSequenceItem(dataSet: format)]))
        ])
        let config = DicomPrinterConfiguration(dataSet: .init(elements: [
            DicomDataElement(tag: DicomPrintTag.printerConfigurationSequence, vr: .SQ,
                             value: .sequence([DicomSequenceItem(dataSet: printer)]))
        ]))
        XCTAssertEqual(config.requestedImageSizeAllowed(filmBox: .init(),
            metaSOPClassUID: DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass), false)
    }
}


extension DicomPrintSCUCompletenessTests {
    func test_scriptedJobEvents_doneAndFailureAreTerminal() throws {
        for failed in [false, true] {
            let transport = PrintScriptedTransport()
            transport.jobEvents = [1, 2, failed ? 4 : 3]
            var job = try printTestJob()
            job.monitor = .untilDone(timeout: 1)
            if failed {
                XCTAssertThrowsError(try printTestSCU().sendPrintJob(job, using: transport)) {
                    XCTAssertEqual($0 as? DicomPrintManagementError, .printJobFailure(statusInfo: .filmJam))
                }
            } else {
                let result = try printTestSCU().sendPrintJob(job, using: transport)
                XCTAssertEqual(result.state, .done)
                XCTAssertEqual(result.executionStatus, .done)
                XCTAssertEqual(result.operations.filter { $0.kind == .eventReport }.map(\.executionStatus), [.pending, .printing, .done])
            }
            XCTAssertEqual(transport.commands.filter { $0.commandField == DicomDIMSECommandField.nEventReportRSP }.count, 3)
        }
    }
}
