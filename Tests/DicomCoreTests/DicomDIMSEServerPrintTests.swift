import Foundation
import XCTest
@testable import DicomCore

final class DicomDIMSEServerPrintTests: XCTestCase {
    func test_actionFitWarnings_sessionAndFilmB604B609B60A() async throws {
        let fixture = try Fixture()
        try await fixture.createSession()
        try await fixture.createFilm()
        let imageUID = await fixture.state.films[0].images[0]
        let filmUID = await fixture.state.films[0].film.sopInstanceUID
        let sessionUID = await fixture.state.sessionUID
        let image = try DicomImageBox(bitmap: .init(width: 32, height: 32, rgbData: Data(repeating: 128, count: 3072)))
        for (behavior, status) in [("", UInt16(0xB604)), ("CROP", 0xB609), ("DECIMATE", 0xB60A)] {
            var data = image.dataSet
            if !behavior.isEmpty { data.set(printSCPString(0x2020_0040, behavior)) }
            assertPrintStatus(try await fixture.request(.set, sop: fixture.imageSOP, uid: imageUID, data: data), status)
            assertPrintStatus(try await fixture.request(.action, sop: fixture.filmSOP, uid: filmUID), status)
            assertPrintStatus(try await fixture.request(.action, sop: fixture.sessionSOP, uid: sessionUID), status)
        }
    }

    func test_releaseMidJob_cancelsWithPartialResult_unlessKeepJobsConfigured() async throws {
        for keep in [false, true] {
            let output = GatedOutput()
            var configuration = DicomPrintSCPConfiguration()
            configuration.keepJobsOnRelease = keep
            let fixture = try Fixture(configuration, output: output)
            try await fixture.createSession()
            for _ in 0..<2 {
                try await fixture.createFilm()
                let uid = await fixture.state.films.last?.images.first
                let image = try DicomImageBox(bitmap: .init(width: 1, height: 1, rgbData: Data([1, 1, 1])))
                assertPrintStatus(try await fixture.request(.set, sop: fixture.imageSOP, uid: uid, data: image.dataSet), 0)
            }
            let uid = await fixture.state.sessionUID
            assertPrintStatus(try await fixture.request(.action, sop: fixture.sessionSOP, uid: uid), 0)
            for _ in 0..<100 where !(await output.started) { try await Task.sleep(for: .milliseconds(5)) }
            let job = await fixture.state.jobs.values.first
            XCTAssertNotNil(job)
            await fixture.state.release()
            XCTAssertEqual(job?.control.isCancelled, !keep)
            await output.confirm()
            for _ in 0..<100 where !(await fixture.state.jobs.isEmpty) { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(job?.control.completedFilmIndices, keep ? [0, 1] : [0])
        }
    }

    func test_printerWarning_isBroadcastToEveryUsingAssociation() async throws {
        let statusProvider = StatusProvider()
        let fixtures = try [Fixture(statusProvider: statusProvider), Fixture(statusProvider: statusProvider)]
        for fixture in fixtures {
            assertPrintStatus(try await fixture.request(.get, sop: DicomNetworkUID.printerSOPClass,
                uid: DicomNetworkUID.printerSOPInstance), 0)
        }
        for _ in 0..<100 where await statusProvider.subscribers < 2 { try await Task.sleep(for: .milliseconds(5)) }
        await statusProvider.warn()
        for fixture in fixtures {
            for _ in 0..<100 {
                if try fixture.transport.commands().contains(where: { $0.eventTypeID == 2 }) { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(try fixture.transport.commands().contains { $0.eventTypeID == 2
                && $0.affectedSOPInstanceUID == DicomNetworkUID.printerSOPInstance })
            await fixture.state.release()
        }
    }

    private actor StatusProvider: DicomPrinterStatusProviding {
        var streams: [AsyncStream<DicomPrinterStatusReport>.Continuation] = []
        var subscribers: Int { streams.count }
        func currentStatus() -> DicomPrinterStatusReport { .init(state: .normal, source: .nGet) }
        func statusChanges() -> AsyncStream<DicomPrinterStatusReport> {
            let pair = AsyncStream<DicomPrinterStatusReport>.makeStream()
            streams.append(pair.continuation)
            return pair.stream
        }
        func warn() { streams.forEach { $0.yield(.init(state: .warning, statusInfo: "LOW FILM", source: .nEventReport(eventTypeID: 2))) } }
    }

    // Combined Print Image is retired and is not a negotiated SOP class here.
    // These are response-injection checks, not evidence of overlay composition.
    func test_injectedCombinedPrintFailure_sessionFilmAndImageC613() async throws {
        var configuration = DicomPrintSCPConfiguration()
        configuration.failAction = 0xC613
        configuration.failSet = 0xC613
        let fixture = try Fixture(configuration)
        for sop in [fixture.sessionSOP, fixture.filmSOP] {
            assertPrintStatus(try await fixture.request(.action, sop: sop, uid: "2.25.1"), 0xC613)
        }
        assertPrintStatus(try await fixture.request(.set, sop: fixture.imageSOP, uid: "2.25.1", data: .init()), 0xC613)
    }

    func test_injectedLUTB605_stillCreatesInstance() async throws {
        var configuration = DicomPrintSCPConfiguration(capabilities: .init(acceptedSOPClassUIDs: [DicomNetworkUID.presentationLUTSOPClass]))
        configuration.failCreate = 0xB605
        let fixture = try Fixture(configuration)
        assertPrintStatus(try await fixture.request(.create, sop: DicomNetworkUID.presentationLUTSOPClass,
            data: DicomPresentationLUT(shape: .identity).dataSet), 0xB605)
        let luts = await fixture.state.luts
        XCTAssertEqual(luts.count, 1)
        XCTAssertEqual(try fixture.transport.commands().last?.affectedSOPInstanceUID, luts.keys.first)
    }

    func test_outputConfirmation_blocksDone_andDeletionRetainsJobSnapshot() async throws {
        let output = GatedOutput()
        let fixture = try Fixture(output: output)
        try await fixture.createSession()
        try await fixture.createFilm()
        let imageUID = await fixture.state.films[0].images[0]
        let image = try DicomImageBox(bitmap: .init(width: 1, height: 1, rgbData: Data([1, 1, 1])))
        assertPrintStatus(try await fixture.request(.set, sop: fixture.imageSOP, uid: imageUID, data: image.dataSet), 0)
        let sessionUID = await fixture.state.sessionUID
        assertPrintStatus(try await fixture.request(.action, sop: fixture.sessionSOP, uid: sessionUID), 0)
        for _ in 0..<100 where !(await output.started) { try await Task.sleep(for: .milliseconds(5)) }
        let started = await output.started
        XCTAssertTrue(started)
        let job = await fixture.state.jobs.values.first
        XCTAssertEqual(job?.status, .printing)
        assertPrintStatus(try await fixture.request(.delete, sop: fixture.sessionSOP, uid: sessionUID), 0)
        let retained = await fixture.state.jobs.values.first
        XCTAssertEqual(retained?.snapshot.count, 1)
        XCTAssertEqual(retained?.snapshot.first?.film.imageBoxes.count, 1)
        XCTAssertEqual(retained?.status, .printing)
        await output.confirm()
        for _ in 0..<100 where !(await fixture.state.jobs.isEmpty) { try await Task.sleep(for: .milliseconds(5)) }
        let empty = await fixture.state.jobs.isEmpty
        XCTAssertTrue(empty)
        XCTAssertEqual(job?.control.completedFilmIndices, [0])
    }

    private actor GatedOutput: DicomPrintOutputProviding {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func output(_ film: DicomComposedFilm, metadata: DicomPrintOutputMetadata,
                    control: DicomPrintJobControl) async -> DicomPrintOutputResult {
            if !started {
                started = true
                await withCheckedContinuation { continuation = $0 }
            }
            return .success
        }
        func confirm() { continuation?.resume(); continuation = nil }
    }
    func test_fullQueue_sessionC601_andFilmC602() async throws {
        var configuration = DicomPrintSCPConfiguration()
        configuration.maximumQueuedJobs = 0
        let fixture = try Fixture(configuration)
        try await fixture.createSession()
        try await fixture.createFilm()
        let session = await fixture.state.sessionUID
        let film = await fixture.state.films[0].film.sopInstanceUID
        assertPrintStatus(try await fixture.request(.action, sop: fixture.sessionSOP, uid: session), 0xC601)
        assertPrintStatus(try await fixture.request(.action, sop: fixture.filmSOP, uid: film), 0xC602)
    }

    func test_densityClamping_filmAndImageB605() async throws {
        let fixture = try Fixture()
        try await fixture.createSession()
        let session = await fixture.state.sessionUID
        var film = DicomFilmBox().dataSet(referencingFilmSessionUID: try XCTUnwrap(session))
        let density = DicomDataElement(tag: 0x2010_0130, vr: .US, value: .unsignedIntegers([500]))
        film.set(density)
        assertPrintStatus(try await fixture.request(.create, sop: fixture.filmSOP, data: film), 0xB605)
        let imageUID = await fixture.state.films[0].images[0]
        var image = try DicomImageBox(bitmap: .init(width: 1, height: 1, rgbData: Data([128, 128, 128]))).dataSet
        image.set(density)
        assertPrintStatus(try await fixture.request(.set, sop: fixture.imageSOP, uid: imageUID, data: image), 0xB605)
        let films = await fixture.state.films
        let bounded = films[0].imageDensityRanges[1]?.maximum
        XCTAssertEqual(bounded, 300)
    }

    func test_lutValidationAndReferencedDeletion_andUnsupportedOperation() async throws {
        var configuration = DicomPrintSCPConfiguration()
        configuration.capabilities = .init(acceptedSOPClassUIDs: [
            DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass, DicomNetworkUID.presentationLUTSOPClass,
            DicomNetworkUID.basicAnnotationBoxSOPClass])
        let fixture = try Fixture(configuration)
        let lutSOP = DicomNetworkUID.presentationLUTSOPClass
        let shape = DicomPresentationLUT(shape: .identity).dataSet
        assertPrintStatus(try await fixture.request(.create, sop: lutSOP, data: shape), 0)
        let lutUID = try XCTUnwrap(fixture.transport.commands().last?.affectedSOPInstanceUID)
        var invalid = shape
        invalid.set(printSCPSequence(0x2050_0010, [.init()]))
        assertPrintStatus(try await fixture.request(.create, sop: lutSOP, data: invalid), 0x0106)
        try await fixture.createSession()
        let session = await fixture.state.sessionUID
        var film = DicomFilmBox().dataSet(referencingFilmSessionUID: try XCTUnwrap(session))
        film.set(printSCPSequence(0x2050_0500, [printSCPReference(lutSOP, lutUID)]))
        assertPrintStatus(try await fixture.request(.create, sop: fixture.filmSOP, data: film), 0)
        assertPrintStatus(try await fixture.request(.delete, sop: lutSOP, uid: lutUID), 0x0110)
        assertPrintStatus(try await fixture.request(.delete, sop: DicomNetworkUID.basicAnnotationBoxSOPClass, uid: "2.25.1"), 0x0211)
        assertPrintStatus(try await fixture.request(.delete, sop: fixture.sessionSOP, uid: session), 0)
        assertPrintStatus(try await fixture.request(.delete, sop: lutSOP, uid: lutUID), 0)
        assertPrintStatus(try await fixture.request(.delete, sop: lutSOP, uid: lutUID), 0x0112)
    }

    func test_fragmentedImageHeader_admitsExactPixelBudget() throws {
        let image = try DicomImageBox(bitmap: .init(width: 2, height: 2, rgbData: Data(repeating: 1, count: 12)))
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .implicitVRLittleEndian] {
            let bytes = try DicomDataSetWriter.dataSetData(from: image.dataSet, transferSyntax: syntax)
            var admission = DicomPrintPixelAdmission(allowance: .init(raw: 4, resident: 12), explicitVR: syntax.isExplicitVR)
            for (index, byte) in bytes.enumerated() { admission.consume(Data([byte]), final: index == bytes.count - 1) }
            XCTAssertNil(admission.failure)
            XCTAssertEqual(admission.pixelBytesSeen, 4)
        }
    }

    func test_declaredPixelSize_andResidentLimit_stopBeforePixels() throws {
        let image = try DicomImageBox(bitmap: .init(width: 2, height: 2, rgbData: Data(repeating: 1, count: 12)))
        let bytes = try DicomDataSetWriter.dataSetData(from: image.dataSet)
        for (raw, resident, status) in [(3, 12, UInt16(0x0213)), (4, 11, 0xC605)] {
            var admission = DicomPrintPixelAdmission(allowance: .init(raw: raw, resident: resident), explicitVR: true)
            admission.consume(bytes, final: true)
            XCTAssertEqual(admission.failure, status)
            XCTAssertEqual(admission.pixelBytesSeen, 0)
        }
    }

    func test_rejectedPDV_doesNotReachMessageAccumulator() throws {
        let meta = DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
        let image = try DicomImageBox(bitmap: .init(width: 2, height: 2, rgbData: Data(repeating: 1, count: 12)))
        let command = DicomDIMSECommandSet(requestedSOPClassUID: DicomNetworkUID.basicGrayscaleImageBoxSOPClass,
            commandField: DicomDIMSECommandField.nSetRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, requestedSOPInstanceUID: "2.25.1")
        let transport = try A2Transport(uid: meta, commands: [(command, image.dataSet)])
        guard case .associationRequest(let request) = try DicomPDUCodec.decode(transport.readPDU()) else { return XCTFail() }
        let accept = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: [meta],
            preferredTransferSyntaxes: [.explicitVRLittleEndian], maximumPDULength: 1024)
        let budget = DicomPrintIngressBudget()
        budget.replace(["2.25.1": .init(raw: 3, resident: 12)])
        let guarded = DicomPrintAdmissionTransport(underlying: transport,
            association: .init(request: request, accept: accept), budget: budget)
        let reader = DicomDIMSEMessageReader()
        _ = try reader.readMessage(from: guarded)
        let dataset = try reader.readMessage(from: guarded)
        XCTAssertTrue(dataset.data.isEmpty)
        XCTAssertEqual(guarded.takeImageFailure(), 0x0213)
    }
    func test_printerConfiguration_isEncodable() async throws {
        let configuration = DicomPrintSCPConfiguration(capabilities: .init(acceptedSOPClassUIDs: [
            DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass, DicomNetworkUID.basicAnnotationBoxSOPClass,
            DicomNetworkUID.presentationLUTSOPClass, DicomNetworkUID.printJobSOPClass,
            DicomNetworkUID.printerConfigurationRetrievalSOPClass
        ]))
        let fixture = try Fixture(configuration)
        let status = try await fixture.request(.get, sop: DicomNetworkUID.printerConfigurationRetrievalSOPClass,
                                              uid: DicomNetworkUID.printerConfigurationRetrievalSOPInstance)
        XCTAssertEqual(status, 0)
    }
    func test_sessionStatuses_missingInvalidDuplicateMemoryAndUnsupportedClass() async throws {
        let fixture = try Fixture()
        assertPrintStatus(try await fixture.request(.create, sop: fixture.sessionSOP, data: nil), 0x0120)
        assertPrintStatus(try await fixture.request(.create, sop: fixture.sessionSOP,
            data: .init(elements: [printSCPString(0x2000_0010, "0", vr: .IS)])), 0x0106)
        assertPrintStatus(try await fixture.request(.create, sop: fixture.sessionSOP,
            data: .init(elements: [printSCPString(0x2000_0060, "100", vr: .IS)])), 0xB600)
        assertPrintStatus(try await fixture.request(.create, sop: fixture.sessionSOP, data: .init()), 0x0110)
        assertPrintStatus(try await fixture.request(.create, sop: DicomNetworkUID.presentationLUTSOPClass, data: .init()), 0x0118)
        assertPrintStatus(try await fixture.request(.get, sop: fixture.sessionSOP, uid: "2.25.9"), 0x0112)
    }

    func test_emptyHierarchyAndCollationStatuses() async throws {
        let fixture = try Fixture()
        try await fixture.createSession()
        let sessionUID = await fixture.state.sessionUID
        assertPrintStatus(try await fixture.request(.action, sop: fixture.sessionSOP, uid: sessionUID), 0xC600)
        try await fixture.createFilm()
        assertPrintStatus(try await fixture.request(.action, sop: fixture.sessionSOP, uid: sessionUID), 0xB602)
        let filmUID = await fixture.state.films.first?.film.sopInstanceUID
        assertPrintStatus(try await fixture.request(.action, sop: fixture.filmSOP, uid: filmUID), 0xB603)
        var configuration = DicomPrintSCPConfiguration()
        configuration.supportsCollation = false
        let noCollation = try Fixture(configuration)
        try await noCollation.createSession()
        let uncollatedUID = await noCollation.state.sessionUID
        assertPrintStatus(try await noCollation.request(.action, sop: noCollation.sessionSOP, uid: uncollatedUID), 0xB601)
        try await noCollation.createFilm()
        assertPrintStatus(try await noCollation.createFilmStatus(), 0xC616)
    }

    func test_imageFitStatuses_andLastFilmRestriction() async throws {
        let fixture = try Fixture()
        try await fixture.createSession()
        try await fixture.createFilm()
        let uid = await fixture.state.films[0].images[0]
        let bitmap = try DicomRenderedBitmap(width: 32, height: 32, rgbData: Data(repeating: 128, count: 32 * 32 * 3))
        let image = try DicomImageBox(bitmap: bitmap)
        var data = image.dataSet
        assertPrintStatus(try await fixture.request(.set, sop: fixture.imageSOP, uid: uid, data: data), 0xB604)
        for (behavior, expected) in [("CROP", UInt16(0xB609)), ("DECIMATE", 0xB60A), ("FAIL", 0xC603)] {
            data.set(printSCPString(0x2020_0040, behavior))
            assertPrintStatus(try await fixture.request(.set, sop: fixture.imageSOP, uid: uid, data: data), expected)
        }
        data = image.dataSet
        data.set(printSCPString(0x2020_9999, "UNKNOWN", vr: .LO))
        assertPrintStatus(try await fixture.request(.set, sop: fixture.imageSOP, uid: uid, data: data), 0x0107)
        try await fixture.createFilm()
        assertPrintStatus(try await fixture.request(.set, sop: fixture.imageSOP, uid: uid, data: image.dataSet), 0x0112)
    }

    func test_imageAndFilmResourceLimits_returnTypedStatuses() async throws {
        var configuration = DicomPrintSCPConfiguration()
        configuration.maximumResidentPixelBytes = 2
        let fixture = try Fixture(configuration)
        try await fixture.createSession()
        try await fixture.createFilm()
        let uid = await fixture.state.films[0].images[0]
        let image = try DicomImageBox(bitmap: .init(width: 1, height: 1, rgbData: Data([1, 1, 1])))
        assertPrintStatus(try await fixture.request(.set, sop: fixture.imageSOP, uid: uid, data: image.dataSet), 0xC605)
        configuration.limits.maximumFilmsPerJob = 0
        let limited = try Fixture(configuration)
        try await limited.createSession()
        assertPrintStatus(try await limited.createFilmStatus(), 0x0213)
    }

    private final class Fixture {
        enum Operation { case create, set, get, action, delete }
        let sessionSOP = DicomNetworkUID.basicFilmSessionSOPClass
        let filmSOP = DicomNetworkUID.basicFilmBoxSOPClass
        let imageSOP = DicomNetworkUID.basicGrayscaleImageBoxSOPClass
        let state: DicomPrintAssociationState
        let transport: A2Transport
        let connection: DicomDIMSEServerSession
        let context: DicomAcceptedPresentationContext

        init(_ configuration: DicomPrintSCPConfiguration = .init(),
             output: any DicomPrintOutputProviding = DicomRasterPrintOutputProvider(),
             statusProvider: (any DicomPrinterStatusProviding)? = nil) throws {
            var configuration = configuration
            configuration.outputWidth = 16
            let meta = DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
            transport = try A2Transport(uid: meta, commands: [])
            let request = DicomAssociationRequest(calledAETitle: "ISIS", callingAETitle: "SCU",
                presentationContexts: [.init(id: 1, abstractSyntaxUID: meta, transferSyntaxes: [.explicitVRLittleEndian])], maximumPDULength: 1024)
            let accept = DicomAssociationNegotiator.accept(request, supportedAbstractSyntaxUIDs: [meta],
                preferredTransferSyntaxes: [.explicitVRLittleEndian], maximumPDULength: 1024)
            let association = DicomAssociation(request: request, accept: accept)
            connection = DicomDIMSEServerSession(transport: transport, association: association, timeout: 1,
                governor: .init(configuration: .init(aeTitle: "ISIS")), maximumOutstanding: 1, auditLogger: nil)
            context = try connection.context(1)
            state = .init(configuration: configuration,
                provider: DicomPrintSCPProvider(outputProvider: output, printerStatusProvider: statusProvider))
        }

        func request(_ operation: Operation, sop: String, uid: String? = nil, data: DicomDataSet? = nil) async throws -> UInt16 {
            let field: UInt16
            switch operation {
            case .create: field = DicomDIMSECommandField.nCreateRQ
            case .set: field = DicomDIMSECommandField.nSetRQ
            case .get: field = DicomDIMSECommandField.nGetRQ
            case .action: field = DicomDIMSECommandField.nActionRQ
            case .delete: field = DicomDIMSECommandField.nDeleteRQ
            }
            let command = DicomDIMSECommandSet(affectedSOPClassUID: sop, commandField: field, messageID: 1,
                affectedSOPInstanceUID: uid, actionTypeID: 1)
            do { try await state.handle(command, context: context, data: data, connection: connection) }
            catch let error as DicomDIMSEProviderError { return error.status }
            return try XCTUnwrap(transport.commands().last?.status)
        }
        func createSession() async throws {
            let status = try await request(.create, sop: sessionSOP, data: .init())
            XCTAssertEqual(status, 0)
        }
        func createFilmStatus() async throws -> UInt16 {
            let currentUID = await state.sessionUID
            let uid = try XCTUnwrap(currentUID)
            return try await request(.create, sop: filmSOP, data: DicomFilmBox().dataSet(referencingFilmSessionUID: uid))
        }
        func createFilm() async throws {
            let status = try await createFilmStatus()
            XCTAssertEqual(status, 0)
        }
    }
}

private func assertPrintStatus(_ actual: UInt16, _ expected: UInt16, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual, expected, file: file, line: line)
}
