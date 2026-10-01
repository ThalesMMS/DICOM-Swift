import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

#if os(macOS)
/// Issue #2794: DCMTK as an independent DIMSE peer, both ways. Its storescu
/// proposes the 128-context Default profile (issue #2791); its findscu,
/// movescu and getscu query this SCP; and this SCU queries, moves, gets from
/// and cancels on dcmqrscp. Loopback only, synthetic data only.
final class DicomDCMTKPeerTests: XCTestCase {
    private var dcmtk: DCMTKToolchain!
    private var directory: URL!

    private static let ctFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CT/ct_synthetic.dcm")

    override func setUpWithError() throws {
        try super.setUpWithError()
        dcmtk = try DCMTKToolchain.required()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("isis-dcmtk-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func test_storescuDefaultProfile_128Contexts_storesIntoThisSCP() async throws {
        let stored = try folder("stored")
        let server = try startServer(storage: DicomFileStorageCache(directoryURL: stored))
        let port = try XCTUnwrap(server.listeningPort)
        do {
            try dcmtk.run("storescu", ["-aet", "DCMTK", "-aec", "ISIS",
                                       "-xf", dcmtk.data("storescu.cfg").path, "Default",
                                       "127.0.0.1", "\(port)", Self.ctFixture.path])
        } catch { await server.stop(); throw error }
        await server.stop()
        let files = try regularFiles(in: stored)
        XCTAssertEqual(files.count, 1)
        let received = try DicomPart10FileMetaParser.parse(Data(contentsOf: XCTUnwrap(files.first)))
        let sent = try DicomPart10FileMetaParser.parse(Data(contentsOf: Self.ctFixture))
        XCTAssertEqual(received.mediaStorageSOPInstanceUID, sent.mediaStorageSOPInstanceUID)
    }

    func test_findscuMovescuGetscu_queryAndRetrieveFromThisSCP() async throws {
        let moved = try folder("moved")
        let destinationPort = try DCMTKToolchain.freePort()
        let destination = try dcmtk.start("storescp", ["-aet", "DEST", "-od", moved.path, "\(destinationPort)"])
        XCTAssertTrue(DCMTKToolchain.waitUntilListening(port: destinationPort), destination.output)
        let resolver = A2DestinationResolver()
        await resolver.set("DEST", port: destinationPort)
        let server = try startServer(query: A2QueryProvider(), retrieve: A2RetrieveProvider(count: 3),
                                     moveDestinations: resolver)
        let port = try XCTUnwrap(server.listeningPort)
        let peer = ["-aet", "DCMTK", "-aec", "ISIS", "-S"]
        let found = try folder("found")
        let got = try folder("got")
        do {
            try dcmtk.run("findscu", peer + ["-k", "QueryRetrieveLevel=STUDY", "-k", "PatientName=SYN*",
                                             "-k", "StudyInstanceUID", "-X", "-od", found.path,
                                             "127.0.0.1", "\(port)"])
            try dcmtk.run("movescu", peer + ["-aem", "DEST", "-k", "QueryRetrieveLevel=STUDY",
                                             "-k", "StudyInstanceUID=2.25.23500", "127.0.0.1", "\(port)"])
            try dcmtk.run("getscu", peer + ["-k", "QueryRetrieveLevel=STUDY", "-k", "StudyInstanceUID=2.25.23500",
                                            "-od", got.path, "127.0.0.1", "\(port)"])
        } catch { await server.stop(); throw error }
        await server.stop()
        destination.stop()
        XCTAssertEqual(try regularFiles(in: found).count, 3, "each C-FIND match is a response")
        XCTAssertEqual(try regularFiles(in: moved).count, 3, "C-MOVE stored every instance at DEST")
        XCTAssertEqual(try regularFiles(in: got).count, 3, "C-GET returned every instance")
    }

    func test_findMoveGetAndCancel_againstDcmqrscp() async throws {
        let archive = try folder("archive")
        let count = 40
        let files = try (0 ..< count).map { index -> String in
            let file = archive.appendingPathComponent("ct\(index).dcm")
            try FileManager.default.copyItem(at: Self.ctFixture, to: file)
            try dcmtk.run("dcmodify", ["-nb", "-m", "(0008,0018)=2.25.2794\(index)", "-m", "(0020,0013)=\(index + 1)",
                                       file.path])
            return file.path
        }
        try dcmtk.run("dcmqridx", [archive.path] + files)

        let moved = try folder("moved")
        let destination = try startServer(storage: DicomFileStorageCache(directoryURL: moved))
        let archivePort = try DCMTKToolchain.freePort()
        let configuration = directory.appendingPathComponent("dcmqrscp.cfg")
        try """
        NetworkTCPPort = \(archivePort)
        MaxPDUSize = 16384
        MaxAssociations = 16
        HostTable BEGIN
        isis = (ISIS, 127.0.0.1, \(try XCTUnwrap(destination.listeningPort)))
        HostTable END
        VendorTable BEGIN
        VendorTable END
        AETable BEGIN
        DCMQR \(archive.path) RW (200, 1024mb) ANY
        AETable END
        """.write(to: configuration, atomically: true, encoding: .utf8)
        let archiveProcess = try dcmtk.start("dcmqrscp", ["-s", "-c", configuration.path])
        XCTAssertTrue(DCMTKToolchain.waitUntilListening(port: archivePort), archiveProcess.output)

        let header = try await DCMDecoder(contentsOf: Self.ctFixture)
        let study = try XCTUnwrap(header.dataSet.string(for: .studyInstanceUID))
        let series = try XCTUnwrap(header.dataSet.string(for: .seriesInstanceUID))
        let sopClass = try XCTUnwrap(header.dataSet.string(for: .sopClassUID))
        let images = DicomDataSet(elements: [
            a2String(0x00080052, .CS, "IMAGE"), a2String(0x0020000D, .UI, study),
            a2String(0x0020000E, .UI, series), DicomDataElement(tag: 0x00080018, vr: .UI, value: .strings([]))
        ])
        func scu(_ handle: DicomDIMSEOperationHandle? = nil) -> DicomDIMSEServiceSCU {
            DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: archivePort, calledAETitle: "DCMQR",
                                                      callingAETitle: "ISIS", timeout: 10, cancelTimeout: 2),
                                 operationHandle: handle)
        }
        do {
            let found = try scu().find(identifier: images)
            XCTAssertEqual(found.operation.status, 0)
            XCTAssertEqual(Set(found.matches.compactMap { $0.string(for: .sopInstanceUID) }).count, count)

            let move = try scu().move(identifier: images, moveDestinationAETitle: "ISIS")
            XCTAssertEqual(move.status, 0)
            XCTAssertEqual(move.completedSuboperations, UInt16(count))

            let got: DicomCGetResult = try scu().get(identifier: images, storageSOPClassUIDs: [sopClass])
            XCTAssertEqual(got.operation.status, 0)
            XCTAssertEqual(Set(got.retrievedInstances.compactMap { $0.sopInstanceUID }).count, count)

            let handle = DicomDIMSEOperationHandle()
            XCTAssertThrowsError(try scu(handle).find(identifier: images, progress: { event in
                if case .pending = event { handle.cancel() }
            })) { error in
                XCTAssertEqual(error as? DicomNetworkError, .operationCancelled("C-FIND"))
            }
        } catch {
            archiveProcess.stop()
            await destination.stop()
            throw error
        }
        archiveProcess.stop()
        await destination.stop()
        XCTAssertEqual(try regularFiles(in: moved).count, count, "every moved instance reached this SCP")
    }

    private func startServer(
        storage: DicomFileStorageCache? = nil,
        query: (any DicomQueryProviding)? = nil,
        retrieve: (any DicomRetrieveProviding)? = nil,
        moveDestinations: (any DicomMoveDestinationResolving)? = nil
    ) throws -> DicomDIMSEServer {
        var configuration = DicomDIMSEServerConfiguration(aeTitle: "ISIS", port: 0)
        configuration.bindAddress = "127.0.0.1"
        let server = DicomDIMSEServer(
            configuration: configuration,
            storage: storage.map { DicomStorageSCPService(configuration: configuration.storage, storage: $0) },
            query: query, retrieve: retrieve, moveDestinations: moveDestinations,
            exposure: .defaults(for: .localOnly)
        )
        try server.start()
        return server
    }

    /// Issue #2906: closed date ranges and time windows on the Scheduled Procedure Step start, matched by DCMTK's
    /// worklist SCP over three synthetic procedures.
    func test_worklistDateRangeAndTimeWindow_againstWlmscpfs() throws {
        let worklists = try folder("worklists")
        let aeFolder = worklists.appendingPathComponent("WLTEST")
        try FileManager.default.createDirectory(at: aeFolder, withIntermediateDirectories: true)
        // wlmscpfs answers 0xA700 unless each AE folder holds a lock file.
        try Data().write(to: aeFolder.appendingPathComponent("lockfile"))
        for (index, (date, time)) in [("20260824", "090000"), ("20260826", "143000"), ("20260901", "083000")]
            .enumerated() {
            let step = DicomDataSet(elements: [
                a2String(DicomWorkflowTag.scheduledStationAETitle, .AE, "ISIS"),
                a2String(DicomWorkflowTag.scheduledProcedureStepStartDate, .DA, date),
                a2String(DicomWorkflowTag.scheduledProcedureStepStartTime, .TM, time),
                a2String(DicomWorkflowTag.modality, .CS, "CT"),
                DicomDataElement(tag: 0x00400006, vr: .PN, value: .strings([])),
                a2String(DicomWorkflowTag.scheduledProcedureStepDescription, .LO, "Synthetic step"),
                a2String(DicomWorkflowTag.scheduledProcedureStepID, .SH, "SPS\(index)")
            ])
            let item = DicomDataSet(elements: [
                a2String(0x00100010, .PN, "WORKLIST^\(index)"), a2String(0x00100020, .LO, "WL\(index)"),
                a2String(DicomWorkflowTag.accessionNumber, .SH, "ACC\(index)"),
                a2String(0x0020000D, .UI, "2.25.29060\(index)"),
                // wlmscpfs ignores items without the requested-procedure attributes.
                a2String(DicomWorkflowTag.requestedProcedureID, .SH, "RP\(index)"),
                a2String(DicomWorkflowTag.requestedProcedureDescription, .LO, "Synthetic"),
                DicomDataElement(tag: DicomWorkflowTag.scheduledProcedureStepSequence, vr: .SQ,
                                 value: .sequence([.init(dataSet: step)]))
            ])
            try DicomDataSetWriter.part10Data(from: item)
                .write(to: aeFolder.appendingPathComponent("item\(index).wl"))
        }
        let port = try DCMTKToolchain.freePort()
        let server = try dcmtk.start("wlmscpfs", ["-dfp", worklists.path, "\(port)"])
        defer { server.stop() }
        XCTAssertTrue(DCMTKToolchain.waitUntilListening(port: port), server.output)
        let scu = DicomDIMSEServiceSCU(configuration: .init(host: "127.0.0.1", port: port, calledAETitle: "WLTEST",
                                                            callingAETitle: "ISIS", timeout: 5))
        func steps(date: String?, time: String? = nil) throws -> [String] {
            try scu.findModalityWorklist(query: .init(scheduledProcedureStepStartDate: date,
                                                      scheduledProcedureStepStartTime: time))
                .items.compactMap(\.scheduledProcedureStepID).sorted()
        }
        XCTAssertEqual(try steps(date: nil), ["SPS0", "SPS1", "SPS2"])
        XCTAssertEqual(try steps(date: "20260826"), ["SPS1"])
        XCTAssertEqual(try steps(date: "20260824-20260830"), ["SPS0", "SPS1"])
        XCTAssertEqual(try steps(date: nil, time: "080000-100000"), ["SPS0", "SPS2"])
        // With both ranges, DCMTK matches the combined date-time span (24th 08:00 to 30th 10:00), which takes SPS1
        // on the 26th at 14:30; PS3.4 C.2.2.2.5 matches them independently unless negotiated, so the Isis worklist
        // screen filters the returned start times again.
        XCTAssertEqual(try steps(date: "20260824-20260830", time: "080000-100000"), ["SPS0", "SPS1"])
    }

    private func folder(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func regularFiles(in folder: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles
        ).filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
    }
}
#endif
