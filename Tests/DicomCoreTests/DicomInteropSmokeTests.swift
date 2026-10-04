import Foundation
#if canImport(Network)
import Network
#endif
import XCTest
import DicomTestSupport
@testable import DicomCore

final class DicomInteropSmokeTests: XCTestCase {
    func testQA03Issue281SmokeConfigurationCoversRequiredInteropOperations() throws {
        let archives = try configuredArchives()
        let capabilities = Set(archives.flatMap(\.capabilities))

        XCTAssertTrue(capabilities.contains(.dicomweb), "At least one archive must cover DICOMweb.")
        XCTAssertTrue(capabilities.contains(.dimseEcho), "At least one archive must cover C-ECHO.")
        XCTAssertTrue(capabilities.contains(.dimseFind), "At least one archive must cover C-FIND.")
        XCTAssertTrue(capabilities.contains(.dimseStore), "At least one archive must cover C-STORE.")
        XCTAssertTrue(capabilities.contains(.dimseGet) || capabilities.contains(.dimseMove),
                      "At least one archive must cover C-GET or C-MOVE.")
        XCTAssertTrue(capabilities.contains(.storageSCP) || capabilities.contains(.dimseGet),
                      "Storage SCP coverage must be explicit, or C-GET must retrieve on the same association.")
    }

    func testQA03Issue281DICOMwebSmokeStoresQueriesAndRetrievesMetadata() async throws {
        let fixture = try fixture()
        let archives = try configuredArchives().filter { $0.capabilities.contains(.dicomweb) }
        guard !archives.isEmpty else {
            throw DicomTestRuntimePreflight.skip(
                .networkInteropSmoke,
                detail: "No configured archive declares DICOMweb support."
            )
        }

        for archive in archives {
            guard let baseURL = archive.dicomWebURL else {
                XCTFail("\(archive.id) declares DICOMweb but has no URL.")
                continue
            }

            let client = DicomWebClient(configuration: DicomWebClientConfiguration(
                baseURL: baseURL,
                headers: archive.dicomWebHeaders,
                timeout: archive.timeout
            ))

            let store = try await client.storeInstances(
                [DicomWebStoreInstance(data: fixture.part10Data)],
                studyInstanceUID: fixture.studyInstanceUID
            )
            XCTAssertEqual(store.storedInstanceCount, 1, archive.id)

            let studies = try await retrying("QIDO \(archive.id)") {
                try await client.searchStudies(DicomWebQuery(patientID: fixture.patientID))
            } until: { studies in
                studies.contains { $0.studyInstanceUID == fixture.studyInstanceUID }
            }
            XCTAssertTrue(studies.contains { $0.studyInstanceUID == fixture.studyInstanceUID }, archive.id)

            let metadata = try await retrying("WADO metadata \(archive.id)") {
                try await client.retrieveStudyMetadata(studyInstanceUID: fixture.studyInstanceUID)
            } until: { dataSets in
                dataSets.contains { $0.dataSet.string(for: .sopInstanceUID) == fixture.sopInstanceUID }
            }
            XCTAssertTrue(metadata.contains { $0.dataSet.string(for: .sopInstanceUID) == fixture.sopInstanceUID }, archive.id)
        }
    }

    func test_dimseSmokeEchoStoreFindRetrieveAndStorageSCP_runsConfiguredOperations() async throws {
        let fixture = try fixture()
        let archives = try configuredArchives().filter { $0.hasDIMSE }
        guard !archives.isEmpty else {
            throw DicomTestRuntimePreflight.skip(
                .networkInteropSmoke,
                detail: "No configured archive declares DIMSE support."
            )
        }

        for archive in archives {
            let service = DicomDIMSEServiceSCU(configuration: archive.dimseConfiguration)

            if archive.capabilities.contains(.dimseEcho) {
                let echo = try service.verify()
                XCTAssertEqual(echo.status, 0, archive.id)
            }

            if archive.capabilities.contains(.dimseStore) {
                let store = try service.store(
                    dataSet: fixture.dataSet,
                    sopClassUID: fixture.sopClassUID,
                    sopInstanceUID: fixture.sopInstanceUID
                )
                XCTAssertEqual(store.status, 0, archive.id)
            }

            if archive.capabilities.contains(.dimseFind) {
                let result = try retrying("C-FIND \(archive.id)", delay: 1) {
                    try service.find(identifier: studyQuery(patientID: fixture.patientID))
                } until: { result in
                    result.matches.contains { $0.string(for: .studyInstanceUID) == fixture.studyInstanceUID }
                }
                XCTAssertTrue(result.matches.contains { $0.string(for: .studyInstanceUID) == fixture.studyInstanceUID }, archive.id)
            }

            if archive.capabilities.contains(.dimseGet) {
                var retrievedInstances: [DicomRetrievedInstance] = []
                let result = try service.get(
                    identifier: retrieveQuery(studyInstanceUID: fixture.studyInstanceUID),
                    storageSOPClassUIDs: [fixture.sopClassUID],
                    onInstance: { retrievedInstances.append($0) }
                )
                XCTAssertEqual(result.status, 0, archive.id)
                XCTAssertTrue(retrievedInstances.contains { $0.sopInstanceUID == fixture.sopInstanceUID }, archive.id)
            }

            if archive.capabilities.contains(.dimseMove) {
                try await runMoveSmoke(archive: archive, fixture: fixture, service: service)
            }
        }
    }

    private struct InteropArchive {
        var id: String
        var dimseHost: String?
        var dimsePort: UInt16?
        var calledAETitle: String
        var callingAETitle: String
        var dicomWebURL: URL?
        var dicomWebHeaders: [String: String]
        var capabilities: Set<InteropCapability>
        var moveDestinationAETitle: String?
        var storageSCPPort: UInt16
        var timeout: TimeInterval

        var hasDIMSE: Bool {
            dimseHost != nil && dimsePort != nil && capabilities.contains { $0.isDIMSE }
        }

        var dimseConfiguration: DicomDIMSEConnectionConfiguration {
            DicomDIMSEConnectionConfiguration(
                host: dimseHost ?? "127.0.0.1",
                port: dimsePort ?? 104,
                calledAETitle: calledAETitle,
                callingAETitle: callingAETitle,
                timeout: timeout
            )
        }
    }

    private enum InteropCapability: String {
        case dicomweb
        case dimseEcho = "dimse-echo"
        case dimseStore = "dimse-store"
        case dimseFind = "dimse-find"
        case dimseGet = "dimse-get"
        case dimseMove = "dimse-move"
        case storageSCP = "storage-scp"

        var isDIMSE: Bool {
            switch self {
            case .dimseEcho, .dimseStore, .dimseFind, .dimseGet, .dimseMove:
                return true
            case .dicomweb, .storageSCP:
                return false
            }
        }
    }

    private struct InteropFixture {
        var part10Data: Data
        var dataSet: DicomDataSet
        var patientID: String
        var studyInstanceUID: String
        var sopClassUID: String
        var sopInstanceUID: String
    }

    private func configuredArchives() throws -> [InteropArchive] {
        let env = ProcessInfo.processInfo.environment
        guard env["DICOM_INTEROP_SMOKE"] == "1" else {
            try DicomTestRuntimePreflight.require(.networkInteropSmoke, environment: env)
            return []
        }

        let requested = Set((env["DICOM_INTEROP_ARCHIVES"] ?? "orthanc,dcm4chee")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })

        let archives = [
            archive(id: "orthanc", prefix: "DICOM_INTEROP_ORTHANC", env: env),
            archive(id: "dcm4chee", prefix: "DICOM_INTEROP_DCM4CHEE", env: env)
        ].compactMap { $0 }
            .filter { requested.contains($0.id) }

        guard !archives.isEmpty else {
            throw XCTSkip(
                "DICOM interop smoke has no selected archive [capability="
                    + "\(DicomRuntimeCapability.networkInteropSmoke.manifestID), classification=missing-optional-runtime]. "
                    + "Set DICOM_INTEROP_ARCHIVES to orthanc, dcm4chee, or both."
            )
        }
        return archives
    }

    private func archive(id: String, prefix: String, env: [String: String]) -> InteropArchive? {
        let capabilities = Set((env["\(prefix)_CAPABILITIES"] ?? "")
            .split(separator: ",")
            .compactMap { InteropCapability(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        guard !capabilities.isEmpty else { return nil }

        return InteropArchive(
            id: id,
            dimseHost: env["\(prefix)_DIMSE_HOST"],
            dimsePort: env["\(prefix)_DIMSE_PORT"].flatMap(UInt16.init),
            calledAETitle: env["\(prefix)_CALLED_AE"] ?? "ARCHIVE",
            callingAETitle: env["\(prefix)_CALLING_AE"] ?? "MTKSMOKE",
            dicomWebURL: env["\(prefix)_DICOMWEB_URL"].flatMap(URL.init(string:)),
            dicomWebHeaders: bearerHeaders(token: env["\(prefix)_DICOMWEB_BEARER_TOKEN"]),
            capabilities: capabilities,
            moveDestinationAETitle: env["\(prefix)_MOVE_DESTINATION_AE"],
            storageSCPPort: env["DICOM_INTEROP_STORAGE_SCP_PORT"].flatMap(UInt16.init) ?? 11114,
            timeout: env["DICOM_INTEROP_TIMEOUT"].flatMap(TimeInterval.init) ?? 30
        )
    }

    private func fixture() throws -> InteropFixture {
        let patientID = "QA03-281"
        let studyInstanceUID = "2.25.2810001"
        let seriesInstanceUID = "2.25.2810002"
        let sopClassUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let sopInstanceUID = "2.25.2810003"
        let dataSet = DicomDataSet(elements: [
            element(DicomTag.sopClassUID.rawValue, .UI, sopClassUID),
            element(DicomTag.sopInstanceUID.rawValue, .UI, sopInstanceUID),
            element(DicomTag.patientName.rawValue, .PN, "QA03^Interop"),
            element(DicomTag.patientID.rawValue, .LO, patientID),
            element(DicomTag.studyInstanceUID.rawValue, .UI, studyInstanceUID),
            element(DicomTag.seriesInstanceUID.rawValue, .UI, seriesInstanceUID),
            element(DicomTag.modality.rawValue, .CS, "OT"),
            us(.samplesPerPixel, 1),
            element(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
            us(.rows, 1),
            us(.columns, 1),
            us(.bitsAllocated, 8),
            us(.bitsStored, 8),
            us(.highBit, 7),
            us(.pixelRepresentation, 0),
            bytes(.pixelData, vr: .OB, Data([0x7F]))
        ])
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: sopClassUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )

        XCTAssertFalse(patientID.isEmpty)
        XCTAssertFalse(studyInstanceUID.isEmpty)
        XCTAssertFalse(sopInstanceUID.isEmpty)
        return InteropFixture(
            part10Data: data,
            dataSet: dataSet,
            patientID: patientID,
            studyInstanceUID: studyInstanceUID,
            sopClassUID: sopClassUID,
            sopInstanceUID: sopInstanceUID
        )
    }

    private func runMoveSmoke(
        archive: InteropArchive,
        fixture: InteropFixture,
        service: DicomDIMSEServiceSCU
    ) async throws {
        guard archive.capabilities.contains(.storageSCP) else {
            throw DicomTestRuntimePreflight.skip(
                .networkInteropSmoke,
                detail: "\(archive.id) declares C-MOVE without storage-scp capability."
            )
        }
        guard let destination = archive.moveDestinationAETitle else {
            XCTFail("\(archive.id) declares C-MOVE but has no move destination AE title.")
            return
        }

        let storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicom-interop-scp-\(UUID().uuidString)", isDirectory: true)
        let storage = try DicomFileStorageCache(directoryURL: storageDirectory)
        let scpService = DicomStorageSCPService(
            configuration: DicomStorageSCPConfiguration(
                aeTitle: destination,
                port: archive.storageSCPPort,
                acceptAnyCalledAETitle: true
            ),
            storage: storage
        )
        #if canImport(Network)
        let server = try DicomStorageSCPServer(service: scpService)
        try server.start()
        defer { try? FileManager.default.removeItem(at: storageDirectory) }

        do {
            let result = try service.move(
                identifier: retrieveQuery(studyInstanceUID: fixture.studyInstanceUID),
                moveDestinationAETitle: destination
            )
            XCTAssertEqual(result.status, 0, archive.id)
            let storedURL = storageDirectory
                .appendingPathComponent(DicomFileStorageCache.fileName(for: fixture.sopInstanceUID))
            XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path), archive.id)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
        #else
        throw XCTSkip(DicomTestRuntimePreflight.skipMessage(for: DicomRuntimeStatus(
            capability: .networkInteropSmoke,
            kind: .unsupportedFeature,
            message: "Network framework is unavailable on this platform."
        )))
        #endif
    }

    private func studyQuery(patientID: String) -> DicomDataSet {
        DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.patientID.rawValue, .LO, patientID),
            element(DicomTag.patientName.rawValue, .PN, ""),
            element(DicomTag.studyInstanceUID.rawValue, .UI, "")
        ])
    }

    private func retrieveQuery(studyInstanceUID: String) -> DicomDataSet {
        DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.studyInstanceUID.rawValue, .UI, studyInstanceUID)
        ])
    }

    private func element(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }

    private func us(_ tag: DicomTag, _ value: UInt) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value]))
    }

    private func bytes(_ tag: DicomTag, vr: DicomVR, _ data: Data) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .bytes(data))
    }

    private func bearerHeaders(token: String?) -> [String: String] {
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return [:]
        }
        return ["Authorization": "Bearer \(token)"]
    }

    private func retrying<T>(
        _ label: String,
        attempts: Int = 12,
        delayNanoseconds: UInt64 = 1_000_000_000,
        operation: () async throws -> T,
        until predicate: (T) -> Bool
    ) async throws -> T {
        var lastValue: T?
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let value = try await operation()
                if predicate(value) || attempt == attempts {
                    return value
                }
                lastValue = value
            } catch {
                lastError = error
                if attempt == attempts {
                    throw error
                }
            }
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let lastValue {
            return lastValue
        }
        throw lastError ?? DicomNetworkError.networkTimeout(label)
    }

    private func retrying<T>(
        _ label: String,
        attempts: Int = 12,
        delay: TimeInterval = 1,
        operation: () throws -> T,
        until predicate: (T) -> Bool
    ) throws -> T {
        var lastValue: T?
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let value = try operation()
                if predicate(value) || attempt == attempts {
                    return value
                }
                lastValue = value
            } catch {
                lastError = error
                if attempt == attempts {
                    throw error
                }
            }
            Thread.sleep(forTimeInterval: delay)
        }
        if let lastValue {
            return lastValue
        }
        throw lastError ?? DicomNetworkError.networkTimeout(label)
    }
}

// MARK: - Issue #1223: cancellation, resilience, TLS, auth, bulk data, audit

extension DicomInteropSmokeTests {
    /// C-FIND results must expose stable patient/study/series attributes,
    /// not just a matching study UID.
    func testInteropCFindReturnsStablePatientStudyAndSeriesAttributes() throws {
        let fixture = try interopFixture()
        let archives = try interopArchivesForExtension().filter { $0.capabilities.contains("dimse-find") }
        try skipIfEmpty(archives, detail: "No configured archive declares C-FIND support.")

        for archive in archives {
            let service = DicomDIMSEServiceSCU(configuration: archive.configuration)

            let studyResult = try interopRetrying("C-FIND STUDY \(archive.id)") {
                try service.find(identifier: DicomDataSet(elements: [
                    interopElement(0x0008_0052, .CS, "STUDY"),
                    interopElement(DicomTag.patientID.rawValue, .LO, fixture.patientID),
                    interopElement(DicomTag.patientName.rawValue, .PN, ""),
                    interopElement(DicomTag.studyInstanceUID.rawValue, .UI, "")
                ]))
            } until: { result in
                result.matches.contains { $0.string(for: .studyInstanceUID) == fixture.studyInstanceUID }
            }
            let match = studyResult.matches.first {
                $0.string(for: .studyInstanceUID) == fixture.studyInstanceUID
            }
            XCTAssertNotNil(match, archive.id)
            XCTAssertEqual(match?.string(for: .patientID), fixture.patientID, archive.id)
            XCTAssertTrue(
                (match?.string(for: .patientName) ?? "").contains("QA03"),
                "\(archive.id): C-FIND study match must carry the patient name"
            )

            let seriesResult = try interopRetrying("C-FIND SERIES \(archive.id)") {
                try service.find(identifier: DicomDataSet(elements: [
                    interopElement(0x0008_0052, .CS, "SERIES"),
                    interopElement(DicomTag.studyInstanceUID.rawValue, .UI, fixture.studyInstanceUID),
                    interopElement(DicomTag.seriesInstanceUID.rawValue, .UI, ""),
                    interopElement(DicomTag.modality.rawValue, .CS, "")
                ]))
            } until: { result in
                result.matches.contains { $0.string(for: .seriesInstanceUID) == fixture.seriesInstanceUID }
            }
            let seriesMatch = seriesResult.matches.first {
                $0.string(for: .seriesInstanceUID) == fixture.seriesInstanceUID
            }
            XCTAssertNotNil(seriesMatch, archive.id)
            XCTAssertEqual(seriesMatch?.string(for: .modality), "OT", archive.id)
        }
    }

    /// A cancelled operation handle must surface the typed cancellation
    /// error at the protocol checkpoints of a query/retrieve path.
    func testInteropQueryCancellationSurfacesTypedCancellation() throws {
        let fixture = try interopFixture()
        let archives = try interopArchivesForExtension().filter { $0.capabilities.contains("dimse-find") }
        try skipIfEmpty(archives, detail: "No configured archive declares C-FIND support.")

        for archive in archives {
            let handle = DicomDIMSEOperationHandle()
            handle.cancel()
            let service = DicomDIMSEServiceSCU(
                configuration: archive.configuration,
                operationHandle: handle
            )

            do {
                _ = try service.find(identifier: DicomDataSet(elements: [
                    interopElement(0x0008_0052, .CS, "STUDY"),
                    interopElement(DicomTag.patientID.rawValue, .LO, fixture.patientID)
                ]))
                XCTFail("\(archive.id): cancelled find must throw")
            } catch let error as DicomNetworkError {
                guard case .operationCancelled = error else {
                    return XCTFail("\(archive.id): expected operationCancelled, got \(error)")
                }
                assertDiagnosticsCarryNoPHI(String(describing: error), fixture: fixture, context: archive.id)
            } catch {
                XCTFail("\(archive.id): expected DicomNetworkError, got \(error)")
            }
        }
    }

    /// Retry policy must not hide the underlying protocol/connection error:
    /// after exhausting attempts against a closed port the typed error
    /// surfaces to the caller.
    func testInteropRetryPolicySurfacesConnectionErrorsAfterRetries() throws {
        let fixture = try interopFixture()
        let archives = try interopArchivesForExtension()
        try skipIfEmpty(archives, detail: "No configured archive for the resilience check.")

        var configuration = archives[0].configuration
        configuration.port = 65499 // deliberately closed port
        configuration.timeout = 5
        configuration.retryPolicy = DicomNetworkRetryPolicy(maxAttempts: 2, retryDelay: 0.1)
        let audit = DicomInMemoryNetworkAuditLog()
        let service = DicomDIMSEServiceSCU(configuration: configuration, auditLogger: audit)

        do {
            _ = try service.verify()
            XCTFail("verify against a closed port must throw")
        } catch let error as DicomNetworkError {
            assertDiagnosticsCarryNoPHI(String(describing: error), fixture: fixture, context: "retry")
        } catch {
            #if canImport(Network)
            // The TCP transport keeps a refused connection's own POSIX error instead of wrapping it.
            guard let refusal = error as? NWError, case .posix(.ECONNREFUSED) = refusal else {
                return XCTFail("expected a DicomNetworkError or the connection refusal, got \(error)")
            }
            assertDiagnosticsCarryNoPHI(String(describing: error), fixture: fixture, context: "retry")
            #else
            XCTFail("expected a typed DicomNetworkError, got \(error)")
            #endif
        }
    }

    /// Enabling TLS against a plaintext DIMSE port must fail with a typed
    /// error instead of hanging or succeeding silently.
    func testInteropTLSAgainstPlaintextPortFailsWithTypedError() throws {
        let fixture = try interopFixture()
        let archives = try interopArchivesForExtension().filter { $0.capabilities.contains("dimse-echo") }
        try skipIfEmpty(archives, detail: "No configured archive declares C-ECHO support.")

        var configuration = archives[0].configuration
        configuration.tls = DicomTLSConfiguration(mode: .enabled, securityProfile: .bcp195RFC8996)
        configuration.timeout = 10
        let service = DicomDIMSEServiceSCU(configuration: configuration)

        do {
            _ = try service.verify()
            XCTFail("TLS handshake against a plaintext port must throw")
        } catch let error as DicomNetworkError {
            assertDiagnosticsCarryNoPHI(String(describing: error), fixture: fixture, context: "tls")
        } catch {
            XCTFail("expected a typed DicomNetworkError, got \(error)")
        }
    }

    /// Authenticated DICOMweb path: valid Basic credentials round-trip
    /// STOW + QIDO; invalid credentials surface the typed HTTP 401.
    func testInteropDICOMwebAuthenticatedPath() async throws {
        let fixture = try interopFixture()
        let env = ProcessInfo.processInfo.environment
        _ = try interopArchivesForExtension()
        guard let baseURL = env["DICOM_INTEROP_ORTHANC_AUTH_DICOMWEB_URL"].flatMap(URL.init(string:)),
              let user = env["DICOM_INTEROP_ORTHANC_AUTH_USER"],
              let password = env["DICOM_INTEROP_ORTHANC_AUTH_PASSWORD"] else {
            throw DicomTestRuntimePreflight.skip(
                .networkInteropSmoke,
                detail: "No authenticated DICOMweb endpoint is configured (DICOM_INTEROP_ORTHANC_AUTH_*)."
            )
        }

        let authenticated = DicomWebClient(configuration: DicomWebClientConfiguration(
            baseURL: baseURL,
            headers: ["Authorization": interopBasicAuthorization(user: user, password: password)],
            timeout: 30
        ))
        let store = try await authenticated.storeInstances(
            [DicomWebStoreInstance(data: fixture.part10Data)],
            studyInstanceUID: fixture.studyInstanceUID
        )
        XCTAssertEqual(store.storedInstanceCount, 1)

        let studies = try await interopRetryingAsync("authenticated QIDO") {
            try await authenticated.searchStudies(DicomWebQuery(patientID: fixture.patientID))
        } until: { studies in
            studies.contains { $0.studyInstanceUID == fixture.studyInstanceUID }
        }
        XCTAssertTrue(studies.contains { $0.studyInstanceUID == fixture.studyInstanceUID })

        let unauthenticated = DicomWebClient(configuration: DicomWebClientConfiguration(
            baseURL: baseURL,
            headers: ["Authorization": interopBasicAuthorization(user: user, password: "wrong-\(password)")],
            timeout: 30
        ))
        do {
            _ = try await unauthenticated.searchStudies(DicomWebQuery(patientID: fixture.patientID))
            XCTFail("QIDO with invalid credentials must fail")
        } catch let error as DicomWebError {
            XCTAssertEqual(error.statusCode, 401)
            assertDiagnosticsCarryNoPHI(error.bodyPreview ?? "", fixture: fixture, context: "auth")
        }
    }

    /// WADO-RS metadata exposes the pixel data as a BulkDataURI; the client
    /// must resolve and retrieve it.
    func testInteropDICOMwebBulkDataURIRetrieval() async throws {
        let fixture = try interopFixture()
        let archives = try interopArchivesForExtension().filter { $0.dicomWebURL != nil }
        try skipIfEmpty(archives, detail: "No configured archive declares DICOMweb support.")

        for archive in archives {
            guard let baseURL = archive.dicomWebURL else { continue }
            let client = DicomWebClient(configuration: DicomWebClientConfiguration(
                baseURL: baseURL,
                headers: archive.dicomWebHeaders,
                timeout: archive.timeout
            ))
            _ = try await client.storeInstances(
                [DicomWebStoreInstance(data: fixture.part10Data)],
                studyInstanceUID: fixture.studyInstanceUID
            )
            let metadata = try await interopRetryingAsync("WADO metadata \(archive.id)") {
                try await client.retrieveStudyMetadata(studyInstanceUID: fixture.studyInstanceUID)
            } until: { dataSets in
                dataSets.contains { $0.dataSet.string(for: .sopInstanceUID) == fixture.sopInstanceUID }
            }
            guard let instance = metadata.first(where: {
                $0.dataSet.string(for: .sopInstanceUID) == fixture.sopInstanceUID
            }) else {
                XCTFail("\(archive.id): stored instance missing from metadata")
                continue
            }
            guard let pixelReference = instance.bulkData.first(where: { $0.tag == DicomTag.pixelData.rawValue }) else {
                throw DicomTestRuntimePreflight.skip(
                    .networkInteropSmoke,
                    detail: "\(archive.id) metadata does not reference pixel data through a BulkDataURI."
                )
            }
            let retrieved = try await client.retrieveBulkData(uri: pixelReference.uri)
            let payload = retrieved.firstPayload ?? Data()
            XCTAssertFalse(payload.isEmpty, archive.id)
            XCTAssertEqual(payload.first, 0x7F, "\(archive.id): bulk pixel payload must match the fixture")
        }
    }

    /// Audit events emitted during DIMSE operations must not carry PHI.
    func testInteropAuditEventsCarryNoPHI() throws {
        let fixture = try interopFixture()
        let archives = try interopArchivesForExtension().filter { $0.capabilities.contains("dimse-store") }
        try skipIfEmpty(archives, detail: "No configured archive declares C-STORE support.")

        for archive in archives {
            let audit = DicomInMemoryNetworkAuditLog()
            let service = DicomDIMSEServiceSCU(configuration: archive.configuration, auditLogger: audit)

            _ = try service.verify()
            _ = try service.store(
                dataSet: fixture.dataSet,
                sopClassUID: fixture.sopClassUID,
                sopInstanceUID: fixture.sopInstanceUID
            )

            let events = audit.events
            XCTAssertFalse(events.isEmpty, "\(archive.id): DIMSE operations must emit audit events")
            for event in events {
                assertDiagnosticsCarryNoPHI(String(describing: event), fixture: fixture, context: archive.id)
            }
        }
    }

    // MARK: Helpers (extension-scoped mirrors of the private fixture API)

    struct InteropExtensionArchive {
        var id: String
        var configuration: DicomDIMSEConnectionConfiguration
        var capabilities: Set<String>
        var dicomWebURL: URL?
        var dicomWebHeaders: [String: String]
        var timeout: TimeInterval
    }

    struct InteropExtensionFixture {
        var part10Data: Data
        var dataSet: DicomDataSet
        var patientID: String
        var patientName: String
        var studyInstanceUID: String
        var seriesInstanceUID: String
        var sopClassUID: String
        var sopInstanceUID: String
    }

    func interopArchivesForExtension() throws -> [InteropExtensionArchive] {
        let env = ProcessInfo.processInfo.environment
        guard env["DICOM_INTEROP_SMOKE"] == "1" else {
            try DicomTestRuntimePreflight.require(.networkInteropSmoke, environment: env)
            return []
        }
        let requested = Set((env["DICOM_INTEROP_ARCHIVES"] ?? "orthanc,dcm4chee")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })

        var archives: [InteropExtensionArchive] = []
        for (id, prefix) in [("orthanc", "DICOM_INTEROP_ORTHANC"), ("dcm4chee", "DICOM_INTEROP_DCM4CHEE")] {
            guard requested.contains(id),
                  let host = env["\(prefix)_DIMSE_HOST"],
                  let port = env["\(prefix)_DIMSE_PORT"].flatMap(UInt16.init) else { continue }
            let capabilities = Set((env["\(prefix)_CAPABILITIES"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            guard !capabilities.isEmpty else { continue }
            archives.append(InteropExtensionArchive(
                id: id,
                configuration: DicomDIMSEConnectionConfiguration(
                    host: host,
                    port: port,
                    calledAETitle: env["\(prefix)_CALLED_AE"] ?? "ARCHIVE",
                    callingAETitle: env["\(prefix)_CALLING_AE"] ?? "MTKSMOKE",
                    timeout: env["DICOM_INTEROP_TIMEOUT"].flatMap(TimeInterval.init) ?? 30
                ),
                capabilities: capabilities,
                dicomWebURL: env["\(prefix)_DICOMWEB_URL"].flatMap(URL.init(string:)),
                dicomWebHeaders: [:],
                timeout: env["DICOM_INTEROP_TIMEOUT"].flatMap(TimeInterval.init) ?? 30
            ))
        }
        return archives
    }

    func skipIfEmpty(_ archives: [InteropExtensionArchive], detail: String) throws {
        guard archives.isEmpty else { return }
        throw DicomTestRuntimePreflight.skip(.networkInteropSmoke, detail: detail)
    }

    func interopFixture() throws -> InteropExtensionFixture {
        let patientID = "QA03-281"
        let patientName = "QA03^Interop"
        let studyInstanceUID = "2.25.2810001"
        let seriesInstanceUID = "2.25.2810002"
        let sopClassUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let sopInstanceUID = "2.25.2810003"
        let dataSet = DicomDataSet(elements: [
            interopElement(DicomTag.sopClassUID.rawValue, .UI, sopClassUID),
            interopElement(DicomTag.sopInstanceUID.rawValue, .UI, sopInstanceUID),
            interopElement(DicomTag.patientName.rawValue, .PN, patientName),
            interopElement(DicomTag.patientID.rawValue, .LO, patientID),
            interopElement(DicomTag.studyInstanceUID.rawValue, .UI, studyInstanceUID),
            interopElement(DicomTag.seriesInstanceUID.rawValue, .UI, seriesInstanceUID),
            interopElement(DicomTag.modality.rawValue, .CS, "OT"),
            interopUS(.samplesPerPixel, 1),
            interopElement(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
            interopUS(.rows, 1),
            interopUS(.columns, 1),
            interopUS(.bitsAllocated, 8),
            interopUS(.bitsStored, 8),
            interopUS(.highBit, 7),
            interopUS(.pixelRepresentation, 0),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data([0x7F])))
        ])
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: sopClassUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )
        return InteropExtensionFixture(
            part10Data: data,
            dataSet: dataSet,
            patientID: patientID,
            patientName: patientName,
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            sopClassUID: sopClassUID,
            sopInstanceUID: sopInstanceUID
        )
    }

    /// Diagnostics, audit events and error bodies must never carry the
    /// fixture's PHI-like identifiers.
    func assertDiagnosticsCarryNoPHI(_ text: String, fixture: InteropExtensionFixture, context: String) {
        XCTAssertFalse(text.contains(fixture.patientName), "\(context): diagnostics must not contain the patient name")
        XCTAssertFalse(text.contains(fixture.patientID), "\(context): diagnostics must not contain the patient ID")
    }

    func interopBasicAuthorization(user: String, password: String) -> String {
        "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
    }

    func interopElement(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }

    func interopUS(_ tag: DicomTag, _ value: UInt) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value]))
    }

    func interopRetrying<T>(
        _ label: String,
        attempts: Int = 12,
        delay: TimeInterval = 1,
        operation: () throws -> T,
        until predicate: (T) -> Bool
    ) throws -> T {
        var lastValue: T?
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let value = try operation()
                if predicate(value) || attempt == attempts {
                    return value
                }
                lastValue = value
            } catch {
                lastError = error
                if attempt == attempts { throw error }
            }
            Thread.sleep(forTimeInterval: delay)
        }
        if let lastValue { return lastValue }
        throw lastError ?? DicomNetworkError.networkTimeout(label)
    }

    func interopRetryingAsync<T>(
        _ label: String,
        attempts: Int = 12,
        delayNanoseconds: UInt64 = 1_000_000_000,
        operation: () async throws -> T,
        until predicate: (T) -> Bool
    ) async throws -> T {
        var lastValue: T?
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let value = try await operation()
                if predicate(value) || attempt == attempts {
                    return value
                }
                lastValue = value
            } catch {
                lastError = error
                if attempt == attempts { throw error }
            }
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let lastValue { return lastValue }
        throw lastError ?? DicomNetworkError.networkTimeout(label)
    }
}

// MARK: - Batched STOW, paging, retrieve levels, frames, Accept fallback, palette LUT

extension DicomInteropSmokeTests {
    struct InteropSeriesInstance {
        var sopInstanceUID: String
        var part10Data: Data
    }

    /// A series of the fixture study: one 8-bit grayscale instance, one palette color instance whose LUTs are large
    /// enough to be sent as BulkDataURI references, and one instance of another study that a STOW-RS request to the
    /// fixture study must refuse.
    struct InteropSeriesFixture {
        var studyInstanceUID: String
        var seriesInstanceUID: String
        var grayscale: InteropSeriesInstance
        var palette: InteropSeriesInstance
        var paletteLUTs: [Data]
        var otherStudy: InteropSeriesInstance

        var storedSOPInstanceUIDs: Set<String> { [grayscale.sopInstanceUID, palette.sopInstanceUID] }
    }

    /// Stores the series in batches with one refused instance, pages it, retrieves it at the three WADO-RS levels
    /// and as frames, falls back after a refused Accept, and resolves the palette LUT BulkDataURI references.
    func testInteropDICOMwebBatchesPagingRetrieveFramesFallbackAndPaletteLUT() async throws {
        let fixture = try interopSeriesFixture()
        let archives = try interopArchivesForExtension().filter { $0.dicomWebURL != nil }
        try skipIfEmpty(archives, detail: "No configured archive declares DICOMweb support.")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dicom-interop-stow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The refused instance shares the first batch with an accepted one, so that batch gets a partial answer.
        let files = try [fixture.grayscale, fixture.otherStudy, fixture.palette].map { instance in
            let url = directory.appendingPathComponent("\(instance.sopInstanceUID).dcm")
            try instance.part10Data.write(to: url)
            return url
        }

        for archive in archives {
            guard let baseURL = archive.dicomWebURL else { continue }
            let client = DicomWebClient(configuration: DicomWebClientConfiguration(
                baseURL: baseURL,
                headers: archive.dicomWebHeaders,
                timeout: archive.timeout
            ))
            try await assertBatchedStore(client, files: files, fixture: fixture, archive: archive.id)
            try await assertPagedInstanceSearch(client, fixture: fixture, archive: archive.id)
            try await assertRetrieveLevels(client, fixture: fixture, archive: archive.id)
            try await assertFrames(client, fixture: fixture, archive: archive.id)
            try await assertAcceptFallback(client, fixture: fixture, archive: archive.id)
            try await assertPaletteLUTBulkData(client, fixture: fixture, archive: archive.id)
        }
    }

    private func assertBatchedStore(_ client: DicomWebClient, files: [URL], fixture: InteropSeriesFixture,
                                    archive: String) async throws {
        let results = await client.storeFiles(files, studyInstanceUID: fixture.studyInstanceUID,
                                              options: DicomWebStoreBatchOptions(maximumFilesPerBatch: 2))
        XCTAssertEqual(results.count, 3, archive)
        for result in results {
            let uid = result.sopInstanceUID ?? ""
            if uid == fixture.otherStudy.sopInstanceUID {
                XCTAssertEqual(result.state, .failed, "\(archive): an instance of another study must be refused")
                XCTAssertNotNil(result.dicomStatus, "\(archive): the refusal must carry its Failure Reason")
            } else {
                // A repeated run stores the same instances again, which an archive may answer with a warning.
                XCTAssertTrue([.stored, .warning].contains(result.state),
                              "\(archive): \(uid) ended \(result.state.rawValue) (\(result.reason ?? "no reason"))")
            }
        }
    }

    private func assertPagedInstanceSearch(_ client: DicomWebClient, fixture: InteropSeriesFixture,
                                           archive: String) async throws {
        let found = try await interopRetryingAsync("paged QIDO \(archive)") {
            var uids: [String] = []
            var pages = 0
            var stopReason: DicomWebSearchStopReason?
            let parameters = DicomWebSearchParameters(level: .instance, studyInstanceUID: fixture.studyInstanceUID,
                                                      seriesInstanceUID: fixture.seriesInstanceUID, limit: 1)
            for try await page in client.searchPages(parameters: parameters, continuesOnFullPage: true,
                                                     limits: DicomWebSearchPagingLimits(maximumPages: 10)) {
                pages += 1
                uids += page.dataSets.compactMap { $0.string(for: .sopInstanceUID) }
                stopReason = page.stopReason ?? stopReason
            }
            return (uids: uids, pages: pages, stopReason: stopReason)
        } until: { Set($0.uids) == fixture.storedSOPInstanceUIDs }
        XCTAssertEqual(Set(found.uids), fixture.storedSOPInstanceUIDs, archive)
        XCTAssertEqual(found.uids.count, Set(found.uids).count, "\(archive): each instance must be returned once")
        XCTAssertGreaterThanOrEqual(found.pages, 2, "\(archive): limit=1 must take more than one page")
        XCTAssertNil(found.stopReason, "\(archive): the pager must end on the server's last page")
    }

    private func assertRetrieveLevels(_ client: DicomWebClient, fixture: InteropSeriesFixture,
                                      archive: String) async throws {
        let study = DicomWebMemoryRetrieveSink()
        try await client.retrieveStudy(studyInstanceUID: fixture.studyInstanceUID, sink: study)
        let studyUIDs = Set(await study.result().compactMap(interopSOPInstanceUID))
        XCTAssertTrue(fixture.storedSOPInstanceUIDs.isSubset(of: studyUIDs), "\(archive): study retrieve")

        let series = DicomWebMemoryRetrieveSink()
        try await client.retrieveSeries(studyInstanceUID: fixture.studyInstanceUID,
                                        seriesInstanceUID: fixture.seriesInstanceUID, sink: series)
        let seriesUIDs = await series.result().compactMap(interopSOPInstanceUID)
        XCTAssertEqual(Set(seriesUIDs), fixture.storedSOPInstanceUIDs, "\(archive): series retrieve")
        XCTAssertEqual(seriesUIDs.count, 2, "\(archive): series retrieve")

        let instance = DicomWebMemoryRetrieveSink()
        try await client.retrieveInstance(studyInstanceUID: fixture.studyInstanceUID,
                                          seriesInstanceUID: fixture.seriesInstanceUID,
                                          sopInstanceUID: fixture.grayscale.sopInstanceUID, sink: instance)
        let instanceUIDs = await instance.result().compactMap(interopSOPInstanceUID)
        XCTAssertEqual(instanceUIDs, [fixture.grayscale.sopInstanceUID], "\(archive): instance retrieve")
    }

    private func assertFrames(_ client: DicomWebClient, fixture: InteropSeriesFixture, archive: String) async throws {
        for accept in [
            DicomWebMediaTypeNegotiator.acceptHeader(for: .frames),
            "multipart/related; type=\"application/octet-stream\""
        ] {
            let frames = try await client.retrieveFrames(studyInstanceUID: fixture.studyInstanceUID,
                                                         seriesInstanceUID: fixture.seriesInstanceUID,
                                                         sopInstanceUID: fixture.grayscale.sopInstanceUID,
                                                         frames: DicomWebFrameList([1]), accept: accept)
            XCTAssertEqual(frames.statusCode, 200, "\(archive): \(accept)")
            XCTAssertEqual(frames.parts.count, 1, "\(archive): \(accept)")
            XCTAssertEqual(frames.firstPayload?.first, 0x7F, "\(archive): frame 1 must hold the fixture pixel (\(accept))")
            XCTAssertTrue(frames.parts.first?.contentType?.lowercased().contains("application/octet-stream") == true,
                          "\(archive): native frames are octet-stream (\(accept))")
        }
    }

    /// The first range asks for a transfer syntax no archive can produce. Archives refuse it with 406, or with 400
    /// (Orthanc), so both are fallback statuses; the retrieve then asks again for the instance as stored.
    private func assertAcceptFallback(_ client: DicomWebClient, fixture: InteropSeriesFixture,
                                      archive: String) async throws {
        let unknownSyntax = "2.25.2810999"
        let fallbackStatuses: Set<Int> = [400, 406]
        do {
            try await client.retrieveInstance(
                studyInstanceUID: fixture.studyInstanceUID, seriesInstanceUID: fixture.seriesInstanceUID,
                sopInstanceUID: fixture.grayscale.sopInstanceUID,
                accept: DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUIDs: [unknownSyntax],
                                                                   fallbackStatuses: fallbackStatuses),
                sink: DicomWebMemoryRetrieveSink())
            XCTFail("\(archive): an unknown transfer syntax alone must be refused")
        } catch let error as DicomWebError {
            XCTAssertTrue(fallbackStatuses.contains(error.statusCode), "\(archive): refused with \(error)")
            XCTAssertEqual(error.attemptedAccepts?.count, 1, archive)
        }

        let sink = DicomWebMemoryRetrieveSink()
        try await client.retrieveInstance(
            studyInstanceUID: fixture.studyInstanceUID, seriesInstanceUID: fixture.seriesInstanceUID,
            sopInstanceUID: fixture.grayscale.sopInstanceUID,
            accept: DicomWebMediaTypeNegotiator.instanceAccept(transferSyntaxUIDs: [unknownSyntax, "*"],
                                                               fallbackStatuses: fallbackStatuses),
            sink: sink)
        let uids = await sink.result().compactMap(interopSOPInstanceUID)
        XCTAssertEqual(uids, [fixture.grayscale.sopInstanceUID], "\(archive): the fallback must retrieve the instance")
    }

    private func assertPaletteLUTBulkData(_ client: DicomWebClient, fixture: InteropSeriesFixture,
                                          archive: String) async throws {
        let metadata = try await client.retrieveInstanceMetadata(studyInstanceUID: fixture.studyInstanceUID,
                                                                 seriesInstanceUID: fixture.seriesInstanceUID,
                                                                 sopInstanceUID: fixture.palette.sopInstanceUID)
        let decoded = try XCTUnwrap(metadata.first, archive)
        for index in fixture.paletteLUTs.indices {
            XCTAssertTrue(decoded.bulkData.contains { $0.tag == 0x0028_1201 + index },
                          "\(archive): palette LUT \(index) must be a BulkDataURI reference")
        }
        let resolved = try await client.resolveBulkData(in: decoded)
        for (index, lut) in fixture.paletteLUTs.enumerated() {
            let element = try XCTUnwrap(resolved.dataSet[0x0028_1201 + index], archive)
            XCTAssertEqual(try DicomDataSetRepresentation.binaryValueBytes(of: element), lut,
                           "\(archive): palette LUT \(index) bytes")
        }
    }

    func interopSOPInstanceUID(_ part: DicomWebMultipartPart) -> String? {
        (try? DicomPart10FileMetaParser.parse(part.body))?.mediaStorageSOPInstanceUID?
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    func interopSeriesFixture() throws -> InteropSeriesFixture {
        let base = try interopFixture()
        let seriesInstanceUID = "2.25.2810010"
        // 12-bit palette color: three 4096-entry, 16-bit LUTs of 8 KiB each.
        let luts = (0..<3).map { channel in
            Data((0..<4096).flatMap { entry -> [UInt8] in
                let value = UInt16((entry * (channel + 1) * 16) & 0xFFFF)
                return [UInt8(value & 0xFF), UInt8(value >> 8)]
            })
        }
        func instance(sopInstanceUID: String, studyInstanceUID: String, seriesInstanceUID: String,
                      pixel: [DicomDataElement]) throws -> InteropSeriesInstance {
            let dataSet = DicomDataSet(elements: [
                interopElement(DicomTag.sopClassUID.rawValue, .UI, base.sopClassUID),
                interopElement(DicomTag.sopInstanceUID.rawValue, .UI, sopInstanceUID),
                interopElement(DicomTag.patientName.rawValue, .PN, base.patientName),
                interopElement(DicomTag.patientID.rawValue, .LO, base.patientID),
                interopElement(DicomTag.studyInstanceUID.rawValue, .UI, studyInstanceUID),
                interopElement(DicomTag.seriesInstanceUID.rawValue, .UI, seriesInstanceUID),
                interopElement(DicomTag.modality.rawValue, .CS, "OT"),
                interopUS(.samplesPerPixel, 1),
                interopUS(.rows, 1),
                interopUS(.columns, 1),
                interopUS(.pixelRepresentation, 0)
            ] + pixel)
            let data = try DicomDataSetWriter.part10Data(
                from: dataSet,
                options: DicomPart10WriterOptions(mediaStorageSOPClassUID: base.sopClassUID,
                                                  mediaStorageSOPInstanceUID: sopInstanceUID)
            )
            return InteropSeriesInstance(sopInstanceUID: sopInstanceUID, part10Data: data)
        }
        let grayscalePixel = [
            interopElement(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
            interopUS(.bitsAllocated, 8),
            interopUS(.bitsStored, 8),
            interopUS(.highBit, 7),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data([0x7F])))
        ]
        var palettePixel = [
            interopElement(DicomTag.photometricInterpretation.rawValue, .CS, "PALETTE COLOR"),
            interopUS(.bitsAllocated, 16),
            interopUS(.bitsStored, 12),
            interopUS(.highBit, 11),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Data([0x23, 0x01])))
        ]
        for (index, lut) in luts.enumerated() {
            palettePixel.append(DicomDataElement(tag: 0x0028_1101 + index, vr: .US,
                                                 value: .unsignedIntegers([4096, 0, 16])))
            palettePixel.append(DicomDataElement(tag: 0x0028_1201 + index, vr: .OW, value: .bytes(lut)))
        }
        return InteropSeriesFixture(
            studyInstanceUID: base.studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            grayscale: try instance(sopInstanceUID: "2.25.2810011", studyInstanceUID: base.studyInstanceUID,
                                    seriesInstanceUID: seriesInstanceUID, pixel: grayscalePixel),
            palette: try instance(sopInstanceUID: "2.25.2810012", studyInstanceUID: base.studyInstanceUID,
                                  seriesInstanceUID: seriesInstanceUID, pixel: palettePixel),
            paletteLUTs: luts,
            otherStudy: try instance(sopInstanceUID: "2.25.2810019", studyInstanceUID: "2.25.2810901",
                                     seriesInstanceUID: "2.25.2810902", pixel: grayscalePixel)
        )
    }
}
