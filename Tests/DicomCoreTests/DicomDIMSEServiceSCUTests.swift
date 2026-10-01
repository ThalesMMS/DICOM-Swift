import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif
import DicomTestSupport
@testable import DicomCore
import XCTest

final class DicomDIMSEServiceSCUTests: XCTestCase {
    func test_defaultDIMSEConfigurations_doNotProposeExperimentalJPEGXL() {
        let scu = DicomDIMSEConnectionConfiguration(
            host: "127.0.0.1",
            port: 4007,
            calledAETitle: "HOROS",
            callingAETitle: "DICOMSWIFT"
        )
        let scp = DicomStorageSCPConfiguration(aeTitle: "DICOMSWIFT")
        let jpegXLSyntaxes: Set<DicomTransferSyntax> = [
            .jpegXLLossless,
            .jpegXLJPEGRecompression,
            .jpegXL
        ]

        XCTAssertTrue(jpegXLSyntaxes.isDisjoint(with: scu.transferSyntaxes))
        XCTAssertTrue(jpegXLSyntaxes.isDisjoint(with: scp.transferSyntaxes))
    }

    func test_retrievedInstanceEquality_ignoresParsedDataSetCache() {
        let cached = DicomRetrievedInstance(
            sopClassUID: "1.2.3",
            sopInstanceUID: "1.2.3.4",
            transferSyntax: .explicitVRLittleEndian,
            data: Data([0x01, 0x02]),
            dataSet: DicomDataSet()
        )
        let uncached = DicomRetrievedInstance(
            sopClassUID: "1.2.3",
            sopInstanceUID: "1.2.3.4",
            transferSyntax: .explicitVRLittleEndian,
            data: Data([0x01, 0x02]),
            dataSet: nil
        )

        XCTAssertEqual(cached, uncached)
    }

    func testRetrievedInstanceDataSetDecodesSpecificCharacterSet() throws {
        let dataSet = DicomDataSet(elements: [
            element(DicomTag.specificCharacterSet.rawValue, .CS, "ISO_IR 144"),
            element(DicomTag.patientName.rawValue, .PN, "Иванов^Иван")
        ])
        let data = try DicomDataSetWriter.dataSetData(from: dataSet)
        let instance = DicomRetrievedInstance(
            sopClassUID: "1.2.3",
            sopInstanceUID: "1.2.3.4",
            transferSyntax: .explicitVRLittleEndian,
            data: data,
            dataSet: nil
        )

        XCTAssertEqual(instance.dataSet?.string(for: .patientName), "Иванов^Иван")
    }

    func test_messageReader_withEmptyPData_readsUntilPDVIsAvailable() throws {
        let payload = Data([0x01, 0x02])
        let transport = RecordingTransport(responses: [
            try DicomPDUCodec.encode(.pData([])),
            try DicomPDUCodec.encode(.pData([
                DicomPDV(
                    presentationContextID: 1,
                    isCommand: true,
                    isLastFragment: true,
                    data: payload
                )
            ]))
        ])

        let result = try DicomDIMSEMessageReader().readNext(from: transport)

        guard case .message(let message) = result else {
            return XCTFail("Expected DIMSE message after empty P-DATA-TF")
        }
        XCTAssertEqual(message.presentationContextID, 1)
        XCTAssertEqual(message.data, payload)
    }

    #if canImport(Network)
    func test_exactLengthReader_requestsAllRemainingBytesAsMinimum() throws {
        let expected = Data(repeating: 0x5A, count: 64 * 1_024)
        var receiveRequests: [(minimum: Int, maximum: Int)] = []

        let result = try DicomTCPAssociationTransport.readExact(count: expected.count) { minimum, maximum in
            receiveRequests.append((minimum, maximum))
            return expected
        }

        XCTAssertEqual(result, expected)
        XCTAssertEqual(receiveRequests.map(\.minimum), [expected.count])
        XCTAssertEqual(receiveRequests.map(\.maximum), [expected.count])
        let expectedAddress = expected.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        let resultAddress = result.withUnsafeBytes { UInt(bitPattern: $0.baseAddress) }
        XCTAssertEqual(resultAddress, expectedAddress)
    }

    func test_exactLengthReader_withPartialChunksRetainsSafetyLoop() throws {
        var chunks = [Data([0x01, 0x02]), Data([0x03, 0x04, 0x05]), Data([0x06])]
        var receiveRequests: [(minimum: Int, maximum: Int)] = []

        let result = try DicomTCPAssociationTransport.readExact(count: 6) { minimum, maximum in
            receiveRequests.append((minimum, maximum))
            return chunks.removeFirst()
        }

        XCTAssertEqual(result, Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))
        XCTAssertEqual(receiveRequests.map(\.minimum), [6, 4, 1])
        XCTAssertEqual(receiveRequests.map(\.maximum), [6, 4, 1])
    }

    func testPDUHeaderRejectsDeclaredLengthAboveIncomingLimit() {
        let header = Data([0x04, 0x00, 0x00, 0x01, 0x00, 0x01])

        XCTAssertThrowsError(
            try DicomTCPAssociationTransport.validatedPDUBodyLength(
                from: header,
                maximumIncomingPDUSize: 65_536
            )
        ) { error in
            XCTAssertEqual(
                error as? DicomNetworkError,
                .invalidPDULength(expected: 65_536, actual: 65_537)
            )
        }
    }

    func test_associationRequestAboveNegotiatedLimit_isReadUpToControlCeiling() throws {
        let length = try DicomTCPAssociationTransport.validatedPDUBodyLength(
            from: Data([0x01, 0x00, 0x00, 0x00, 0x42, 0x68]),
            maximumIncomingPDUSize: 16_384
        )
        XCTAssertEqual(length, 17_000)

        let ceiling = DicomTCPAssociationTransport.maximumControlPDUSize
        let oversized = UInt32(ceiling + 1)
        let header = Data([0x01, 0x00]) + withUnsafeBytes(of: oversized.bigEndian) { Data($0) }
        XCTAssertThrowsError(
            try DicomTCPAssociationTransport.validatedPDUBodyLength(from: header, maximumIncomingPDUSize: 16_384)
        ) { error in
            XCTAssertEqual(error as? DicomNetworkError, .invalidPDULength(expected: ceiling, actual: ceiling + 1))
        }
    }
    #endif

    func testVerificationSCUSendsCEchoAndReportsSuccess() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.verificationSOPClass
        ])
        let service = makeService()
        var progress: [DicomDIMSEProgress] = []

        let result = try service.verify(using: transport) { progress.append($0) }

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.cEchoRQ
        ])
        XCTAssertTrue(progress.contains(.associationAccepted(operation: .verification)))
        XCTAssertTrue(progress.contains(.completed(operation: .verification, status: 0)))
    }

    func testFindSCUReceivesPendingIdentifierMatches() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveFind
        ])
        let service = makeService()
        let query = DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.patientName.rawValue, .PN, "DOE^JANE")
        ])

        let result = try service.find(identifier: query, using: transport)

        XCTAssertEqual(result.operation.status, 0)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches[0].string(for: .patientName), "DOE^JANE")
        XCTAssertEqual(result.matches[0].string(for: .studyInstanceUID), "2.25.100")
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.cFindRQ
        ])
        XCTAssertEqual(transport.writtenCommands.first?.affectedSOPClassUID,
                       DicomNetworkUID.studyRootQueryRetrieveFind)
        XCTAssertNil(transport.writtenCommands.first?.requestedSOPClassUID)
        XCTAssertEqual(transport.writtenDataSets.first?.string(for: .patientName), "DOE^JANE")
    }

    func testFindSCUDecodesISO2022ResponseIdentifier() throws {
        let patientName = "Yamada^Taro=山田^太郎"
        let response = DicomDataSet(elements: [
            DicomDataElement(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS,
                             value: .strings(["", "ISO 2022 IR 87"])),
            element(DicomTag.patientName.rawValue, .PN, patientName),
            element(DicomTag.studyInstanceUID.rawValue, .UI, "2.25.100")
        ])
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.studyRootQueryRetrieveFind],
            findResponseDataSet: response
        )

        let result = try makeService().find(identifier: retrieveIdentifier(), using: transport)

        XCTAssertEqual(result.matches.first?.string(for: .patientName), patientName)
    }

    func testMoveSCUReportsPendingAndCompletedSuboperations() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveMove
        ])
        let service = makeService()
        var progress: [DicomDIMSEProgress] = []

        let result = try service.move(
            identifier: retrieveIdentifier(),
            moveDestinationAETitle: "VIEWER",
            using: transport
        ) { progress.append($0) }

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.completedSuboperations, 2)
        XCTAssertTrue(progress.contains(.pending(operation: .moveRetrieve,
                                                remaining: 1,
                                                completed: 1,
                                                failed: 0,
                                                warning: 0)))
        XCTAssertEqual(transport.writtenCommands.first?.affectedSOPClassUID,
                       DicomNetworkUID.studyRootQueryRetrieveMove)
        XCTAssertNil(transport.writtenCommands.first?.requestedSOPClassUID)
        XCTAssertEqual(transport.writtenCommands.first?.moveDestination, "VIEWER")
    }

    func testMoveSCUReturnsPartialSuccessWarning() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.studyRootQueryRetrieveMove],
            retrieveFinalStatus: 0xB000
        )
        let service = makeService()

        let result = try service.move(
            identifier: retrieveIdentifier(),
            moveDestinationAETitle: "VIEWER",
            using: transport
        )

        XCTAssertEqual(result.status, 0xB000)
        XCTAssertEqual(result.completedSuboperations, 2)
    }

    func testGetSCUReceivesStoreSuboperationAndAcknowledgesIt() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveGet,
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        ])
        let service = makeService()

        let result = try service.get(identifier: retrieveIdentifier(), using: transport)

        XCTAssertEqual(result.operation.status, 0)
        XCTAssertEqual(result.operation.completedSuboperations, 1)
        XCTAssertEqual(result.retrievedInstances.count, 1)
        XCTAssertEqual(result.retrievedInstances[0].sopInstanceUID, "2.25.instance")
        XCTAssertEqual(result.retrievedInstances[0].dataSet?.string(for: .patientName), "DOE^JANE")
        XCTAssertTrue(transport.writtenCommands.contains {
            $0.commandField == DicomDIMSECommandField.cStoreRSP && $0.status == 0
        })
        let cGetRequest = transport.writtenCommands.first { $0.commandField == DicomDIMSECommandField.cGetRQ }
        XCTAssertEqual(cGetRequest?.affectedSOPClassUID, DicomNetworkUID.studyRootQueryRetrieveGet)
        XCTAssertNil(cGetRequest?.requestedSOPClassUID)
    }

    // MARK: - C-GET SCP/SCU Role Selection (issue #1868)

    /// The association request carries one role-selection item per returned
    /// storage SOP Class, declaring this side SCP for the sub-operation
    /// C-STOREs while it stays SCU for the C-GET itself.
    func test_get_proposesSCPRoleForEveryReturnedStorageClass() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveGet,
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        ])
        let service = makeService()

        _ = try service.get(identifier: retrieveIdentifier(), using: transport)

        let request = try XCTUnwrap(transport.associationRequests.first)
        XCTAssertEqual(request.roleSelections, [
            DicomSCPSCURoleSelection(
                sopClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                scuRole: false,
                scpRole: true
            )
        ])
    }

    /// A peer that explicitly denies the SCP role on every storage class
    /// gets no C-GET request at all: the retrieved instances would have had
    /// nowhere to arrive.
    func test_get_whenThePeerDeniesEverySCPRole_refusesBeforeTheRequest() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.studyRootQueryRetrieveGet,
                DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
            ],
            roleSelectionPolicy: .denySCP
        )
        let service = makeService()

        XCTAssertThrowsError(try service.get(identifier: retrieveIdentifier(),
                                             using: transport)) { error in
            guard case DicomNetworkError.returnedStorageNotNegotiated? = error as? DicomNetworkError else {
                return XCTFail("expected returnedStorageNotNegotiated, got \(error)")
            }
        }
        XCTAssertFalse(transport.writtenCommands.contains {
            $0.commandField == DicomDIMSECommandField.cGetRQ
        }, "nothing was requested from a peer that will not send the instances back")
    }

    /// Without accepted Storage SCP roles, refuse before sending C-GET.
    func test_get_whenThePeerIgnoresRoleSelection_refusesBeforeSending() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.studyRootQueryRetrieveGet,
                DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
            ],
            roleSelectionPolicy: .ignore
        )
        let service = makeService()

        XCTAssertThrowsError(try service.get(identifier: retrieveIdentifier(), using: transport)) { error in
            guard case DicomNetworkError.returnedStorageNotNegotiated = error else {
                return XCTFail("Expected missing returned-storage role, got \(error)")
            }
        }
        XCTAssertFalse(transport.writtenCommands.contains { $0.commandField == DicomDIMSECommandField.cGetRQ })
    }

    /// A storage class whose presentation context the peer rejected is not
    /// usable — but one surviving class is enough for the retrieve to run.
    func test_get_withPartiallyAcceptedStorageClasses_proceedsOnTheSurvivors() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveGet,
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
            // "1.2.840.10008.5.1.4.1.1.2" (CT Image Storage) deliberately
            // unsupported: its context is rejected.
        ])
        let service = makeService()

        // The accepted class goes first so the scripted SCP's store
        // sub-operation arrives on the accepted context.
        let result = try service.get(
            identifier: retrieveIdentifier(),
            storageSOPClassUIDs: [
                DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                "1.2.840.10008.5.1.4.1.1.2"
            ],
            using: transport
        )
        let request = try XCTUnwrap(transport.associationRequests.first)
        let accept = try XCTUnwrap(transport.associationAccepts.first)
        let ctContext = try XCTUnwrap(request.presentationContexts.first {
            $0.abstractSyntaxUID == "1.2.840.10008.5.1.4.1.1.2"
        })

        XCTAssertEqual(
            accept.presentationContexts.first { $0.id == ctContext.id }?.result,
            .abstractSyntaxNotSupported
        )
        XCTAssertEqual(result.retrievedInstances.count, 1)
        XCTAssertEqual(result.operation.status, 0)
    }

    /// Issue #2793: with a receive directory, a returned object is handed over as the Part 10 file it was
    /// received into, holding the dataset as sent; the file is gone once the handler returns.
    func test_get_withReceivedFileDirectory_handsOverTheFileTheObjectArrivedIn() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("isis-2793-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveGet,
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        ])
        transport.storeSOPInstanceUID = "2.25.2793"
        var configuration = makeConfiguration()
        configuration.receivedFileDirectory = directory
        var delivered: [(url: URL?, file: Data?, data: Data)] = []

        _ = try DicomDIMSEServiceSCU(configuration: configuration).get(
            identifier: retrieveIdentifier(),
            storageSOPClassUIDs: [DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
            using: transport,
            onInstance: { instance in
                delivered.append((instance.part10FileURL, instance.part10FileURL.flatMap { try? Data(contentsOf: $0) },
                                  instance.data))
            }
        )

        let sent = try DicomDataSetWriter.dataSetData(from: storageDataSet(), transferSyntax: .explicitVRLittleEndian)
        let received = try XCTUnwrap(delivered.first)
        let url = try XCTUnwrap(received.url)
        let request = try DicomStoreRequest(part10Data: try XCTUnwrap(received.file))
        XCTAssertEqual(request.dataSetData, sent)
        XCTAssertEqual(request.sopInstanceUID, "2.25.2793")
        XCTAssertEqual(received.data, sent, "the instance's data is the file's dataset")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Query model fallback (issue #1867)

    /// Both models ride in the one association request; a peer that accepts
    /// both runs the query under Study Root, the preferred model.
    func test_find_prefersStudyRootWhenBothModelsAreAccepted() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveFind,
            DicomNetworkUID.patientRootQueryRetrieveFind
        ])
        let service = makeService()

        let result = try service.find(identifier: retrieveIdentifier(), using: transport)

        XCTAssertEqual(result.operation.status, 0)
        XCTAssertEqual(result.operation.negotiatedQueryModelUID,
                       DicomNetworkUID.studyRootQueryRetrieveFind)
        XCTAssertEqual(transport.writtenCommands.first?.affectedSOPClassUID,
                       DicomNetworkUID.studyRootQueryRetrieveFind)
        let request = try XCTUnwrap(transport.associationRequests.first)
        XCTAssertEqual(request.presentationContexts.map(\.abstractSyntaxUID), [
            DicomNetworkUID.studyRootQueryRetrieveFind,
            DicomNetworkUID.patientRootQueryRetrieveFind
        ], "both models are proposed, Study Root first")
    }

    /// A Patient-Root-only archive rejects the Study Root context; the same
    /// association falls through to Patient Root, and the Study-Root-shaped
    /// identifier gains the universal-match Patient ID key it was missing.
    func test_find_fallsBackToPatientRootWhenStudyRootIsRejected() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.patientRootQueryRetrieveFind
        ])
        let service = makeService()
        let query = DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.patientName.rawValue, .PN, "DOE^JANE")
        ])

        let result = try service.find(identifier: query, using: transport)

        XCTAssertEqual(result.operation.status, 0)
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.operation.negotiatedQueryModelUID,
                       DicomNetworkUID.patientRootQueryRetrieveFind)
        XCTAssertEqual(transport.writtenCommands.first?.affectedSOPClassUID,
                       DicomNetworkUID.patientRootQueryRetrieveFind)
        XCTAssertEqual(transport.associationRequests.count, 1,
                       "the fallback is a context choice, not a second association")
        let sentIdentifier = try XCTUnwrap(transport.writtenDataSets.first)
        XCTAssertTrue(sentIdentifier.contains(DicomTag.patientID))
        XCTAssertEqual(sentIdentifier.string(for: .patientID) ?? "", "",
                       "the added Patient ID key is universal-match, not a value")
    }

    /// An identifier that already names a patient keeps its Patient ID
    /// untouched under the fallback.
    func test_find_underPatientRoot_keepsAnExplicitPatientID() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.patientRootQueryRetrieveFind
        ])
        let service = makeService()
        let query = DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.patientID.rawValue, .LO, "PID-123")
        ])

        _ = try service.find(identifier: query, using: transport)

        XCTAssertEqual(transport.writtenDataSets.first?.string(for: .patientID), "PID-123")
    }

    /// A peer that accepts neither model fails at negotiation itself:
    /// nothing is queried, and there is no second association to retry on.
    func test_find_whenNoModelIsAccepted_refusesWithoutQuerying() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.verificationSOPClass
        ])
        let service = makeService()

        XCTAssertThrowsError(try service.find(identifier: retrieveIdentifier(),
                                              using: transport)) { error in
            guard case DicomNetworkError.missingAcceptedPresentationContext? = error as? DicomNetworkError else {
                return XCTFail("expected missingAcceptedPresentationContext, got \(error)")
            }
        }
        XCTAssertFalse(transport.writtenCommands.contains {
            $0.commandField == DicomDIMSECommandField.cFindRQ
        })
        XCTAssertEqual(transport.associationRequests.count, 1)
    }

    /// The retrieve services follow the same negotiation: a Patient-Root-only
    /// peer still delivers its instances over C-GET.
    func test_get_fallsBackToPatientRootWhenStudyRootIsRejected() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.patientRootQueryRetrieveGet,
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        ])
        let service = makeService()

        let result = try service.get(identifier: retrieveIdentifier(), using: transport)

        XCTAssertEqual(result.operation.status, 0)
        XCTAssertEqual(result.retrievedInstances.count, 1)
        XCTAssertEqual(result.operation.negotiatedQueryModelUID,
                       DicomNetworkUID.patientRootQueryRetrieveGet)
        let cGetRequest = transport.writtenCommands.first { $0.commandField == DicomDIMSECommandField.cGetRQ }
        XCTAssertEqual(cGetRequest?.affectedSOPClassUID, DicomNetworkUID.patientRootQueryRetrieveGet)
        XCTAssertTrue(transport.writtenDataSets.first?.contains(DicomTag.patientID) == true)
    }

    /// Preference order is per-operation: get also runs Study Root when the
    /// peer accepts both models.
    func test_get_prefersStudyRootWhenBothModelsAreAccepted() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveGet,
            DicomNetworkUID.patientRootQueryRetrieveGet,
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        ])
        let service = makeService()

        let result = try service.get(identifier: retrieveIdentifier(), using: transport)

        XCTAssertEqual(result.operation.negotiatedQueryModelUID,
                       DicomNetworkUID.studyRootQueryRetrieveGet)
        XCTAssertEqual(result.retrievedInstances.count, 1)
    }

    func test_move_fallsBackToPatientRootWhenStudyRootIsRejected() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.patientRootQueryRetrieveMove
        ])
        let service = makeService()

        let result = try service.move(identifier: retrieveIdentifier(),
                                      moveDestinationAETitle: "ISIS",
                                      using: transport)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.negotiatedQueryModelUID,
                       DicomNetworkUID.patientRootQueryRetrieveMove)
        let cMoveRequest = transport.writtenCommands.first { $0.commandField == DicomDIMSECommandField.cMoveRQ }
        XCTAssertEqual(cMoveRequest?.affectedSOPClassUID, DicomNetworkUID.patientRootQueryRetrieveMove)
    }

    func test_move_prefersStudyRootWhenBothModelsAreAccepted() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveMove,
            DicomNetworkUID.patientRootQueryRetrieveMove
        ])
        let service = makeService()

        let result = try service.move(identifier: retrieveIdentifier(),
                                      moveDestinationAETitle: "ISIS",
                                      using: transport)

        XCTAssertEqual(result.negotiatedQueryModelUID,
                       DicomNetworkUID.studyRootQueryRetrieveMove)
    }

    /// Live wire check against HOROS (127.0.0.1:4007): the dual-model
    /// association is accepted and the query runs under Study Root, the
    /// preferred model. Opt-in like the other live tests.
    func test_liveHorosFind_withDualModelProposal_prefersStudyRoot() throws {
        guard ProcessInfo.processInfo.environment["DICOM_SWIFT_LIVE_HOROS"] == "1" else {
            throw XCTSkip("Set DICOM_SWIFT_LIVE_HOROS=1 when HOROS is listening on 127.0.0.1:4007.")
        }
        let configuration = DicomDIMSEConnectionConfiguration(
            host: "127.0.0.1",
            port: 4007,
            calledAETitle: "HOROS",
            callingAETitle: "ISIS",
            timeout: 15
        )
        let service = DicomDIMSEServiceSCU(configuration: configuration)
        let studyQuery = DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.studyInstanceUID.rawValue, .UI, "")
        ])

        let result = try service.find(identifier: studyQuery)

        XCTAssertEqual(result.operation.negotiatedQueryModelUID,
                       DicomNetworkUID.studyRootQueryRetrieveFind)
        XCTAssertFalse(result.matches.isEmpty)
    }

    /// The wire form of the item (PS3.7 D.3.3.4): uid-length big-endian,
    /// uid, scu-role byte, scp-role byte — round-tripped through the codec
    /// in both the request and the accept.
    func test_roleSelectionItems_roundTripThroughThePDUCodec() throws {
        let roleSelection = DicomSCPSCURoleSelection(sopClassUID: "1.2.840.10008.5.1.4.1.1.7",
                                                     scuRole: false,
                                                     scpRole: true)
        let request = DicomAssociationRequest(
            calledAETitle: "CALLED",
            callingAETitle: "CALLING",
            presentationContexts: [
                DicomPresentationContextRequest(id: 1,
                                                abstractSyntaxUID: DicomNetworkUID.studyRootQueryRetrieveGet,
                                                transferSyntaxes: [.explicitVRLittleEndian])
            ],
            roleSelections: [roleSelection]
        )
        let encodedRequest = try DicomPDUCodec.encode(.associationRequest(request))
        guard case .associationRequest(let decodedRequest) = try DicomPDUCodec.decode(encodedRequest) else {
            return XCTFail("expected an association request")
        }
        XCTAssertEqual(decodedRequest.roleSelections, [roleSelection])

        // The raw sub-item: 0x54, reserved, length, then uid-length BE +
        // uid + scu + scp.
        let uid = Data(roleSelection.sopClassUID.utf8)
        var expectedItem = Data([0x54, 0x00])
        expectedItem.append(contentsOf: [UInt8((uid.count + 4) >> 8), UInt8((uid.count + 4) & 0xFF)])
        expectedItem.append(contentsOf: [UInt8(uid.count >> 8), UInt8(uid.count & 0xFF)])
        expectedItem.append(uid)
        expectedItem.append(contentsOf: [0x00, 0x01])
        XCTAssertNotNil(encodedRequest.range(of: expectedItem),
                        "the PDU carries the exact PS3.7 D.3.3.4 item bytes")

        let accept = DicomAssociationNegotiator.accept(
            request,
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.studyRootQueryRetrieveGet,
                                          "1.2.840.10008.5.1.4.1.1.7"],
            preferredTransferSyntaxes: [.explicitVRLittleEndian],
            supportedSCUAbstractSyntaxUIDs: ["1.2.840.10008.5.1.4.1.1.7"]
        )
        XCTAssertEqual(accept.roleSelections, [roleSelection], "the acceptor echoes supported proposals")
        let encodedAccept = try DicomPDUCodec.encode(.associationAccept(accept))
        guard case .associationAccept(let decodedAccept) = try DicomPDUCodec.decode(encodedAccept) else {
            return XCTFail("expected an association accept")
        }
        XCTAssertEqual(decodedAccept.roleSelections, [roleSelection])
    }

    func test_negotiator_omitsRoleAnswersForUnsupportedClasses() {
        let request = DicomAssociationRequest(
            calledAETitle: "CALLED",
            callingAETitle: "CALLING",
            presentationContexts: [
                DicomPresentationContextRequest(id: 1,
                                                abstractSyntaxUID: DicomNetworkUID.studyRootQueryRetrieveGet,
                                                transferSyntaxes: [.explicitVRLittleEndian])
            ],
            roleSelections: [
                DicomSCPSCURoleSelection(sopClassUID: "1.2.840.10008.5.1.4.1.1.128",
                                         scuRole: false,
                                         scpRole: true)
            ]
        )
        let accept = DicomAssociationNegotiator.accept(
            request,
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.studyRootQueryRetrieveGet],
            preferredTransferSyntaxes: [.explicitVRLittleEndian]
        )
        XCTAssertTrue(accept.roleSelections.isEmpty,
                      "an unsupported SOP class gets no role answer — absence, not invention")
    }

    /// Live wire check against HOROS (127.0.0.1:4007): the association with
    /// role-selection items must be accepted and the C-GET must still
    /// deliver instances. Opt-in like the other live tests.
    func test_liveHorosGetRetrieve_withRoleSelection_deliversInstances() throws {
        guard ProcessInfo.processInfo.environment["DICOM_SWIFT_LIVE_HOROS"] == "1" else {
            throw XCTSkip("Set DICOM_SWIFT_LIVE_HOROS=1 when HOROS is listening on 127.0.0.1:4007.")
        }
        let configuration = DicomDIMSEConnectionConfiguration(
            host: "127.0.0.1",
            port: 4007,
            calledAETitle: "HOROS",
            callingAETitle: "ISIS",
            timeout: 15
        )
        let service = DicomDIMSEServiceSCU(configuration: configuration)
        let studyQuery = DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.studyInstanceUID.rawValue, .UI, "")
        ])
        let studies = try service.find(identifier: studyQuery)
        guard let studyUID = studies.matches.first?.string(for: .studyInstanceUID) else {
            throw XCTSkip("HOROS returned no study to retrieve.")
        }
        let identifier = DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.studyInstanceUID.rawValue, .UI, studyUID)
        ])
        let result = try service.get(identifier: identifier,
                                     storageSOPClassUIDs: [
                                        "1.2.840.10008.5.1.4.1.1.2",
                                        "1.2.840.10008.5.1.4.1.1.4",
                                        "1.2.840.10008.5.1.4.1.1.7"
                                     ])
        XCTAssertFalse(result.retrievedInstances.isEmpty,
                       "HOROS accepted the role-negotiated association and returned instances")
    }

    func testGetSCUPreservesInstancesOnPartialSuccessWarning() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.studyRootQueryRetrieveGet,
                DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
            ],
            retrieveFinalStatus: 0xB000
        )
        let service = makeService()

        let result = try service.get(identifier: retrieveIdentifier(), using: transport)

        XCTAssertEqual(result.operation.status, 0xB000)
        XCTAssertEqual(result.retrievedInstances.map(\.sopInstanceUID), ["2.25.instance"])
    }

    func testGetSCUStreamsStoreSuboperationBeforeAcknowledgingIt() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveGet,
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        ])
        let service = makeService()
        var received: [DicomRetrievedInstance] = []

        let result = try service.get(
            identifier: retrieveIdentifier(),
            using: transport,
            onInstance: { instance in
                XCTAssertFalse(transport.writtenCommands.contains {
                    $0.commandField == DicomDIMSECommandField.cStoreRSP && $0.status == 0
                })
                XCTAssertEqual(instance.dataSet?.string(for: .patientName), "DOE^JANE")
                received.append(instance)
            }
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.completedSuboperations, 1)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received[0].sopInstanceUID, "2.25.instance")
    }

    func testGetSCURetry_redeliversInstanceFromFailedAttempt() throws {
        var attempt = 0
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(retryPolicy: DicomNetworkRetryPolicy(maxAttempts: 2)),
            transportFactory: {
                attempt += 1
                return DIMSEScriptedTransport(
                    supportedAbstractSyntaxUIDs: [
                        DicomNetworkUID.studyRootQueryRetrieveGet,
                        DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
                    ],
                    failBeforeRetrieveFinalResponse: attempt == 1
                )
            }
        )
        var receivedSOPInstanceUIDs: [String] = []

        let result = try service.get(
            identifier: retrieveIdentifier(),
            onInstance: { receivedSOPInstanceUIDs.append($0.sopInstanceUID ?? "") }
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(attempt, 2)
        XCTAssertEqual(receivedSOPInstanceUIDs, ["2.25.instance", "2.25.instance"])
    }

    func testModalityWorklistSCUMapsScheduledProcedureSteps() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.modalityWorklistInformationModelFind
        ])
        let service = makeService()
        let query = DicomModalityWorklistQuery(patientName: "DOE",
                                               modality: "CT",
                                               scheduledStationAETitle: "CTSCANNER")

        let result = try service.findModalityWorklist(query: query, using: transport)

        XCTAssertEqual(result.operation.status, 0)
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items[0].patientName, "DOE^JANE")
        XCTAssertEqual(result.items[0].modality, "CT")
        XCTAssertEqual(result.items[0].scheduledProcedureStepID, "SPS-1")
        XCTAssertEqual(transport.writtenCommands.first?.affectedSOPClassUID,
                       DicomNetworkUID.modalityWorklistInformationModelFind)
        XCTAssertNil(transport.writtenCommands.first?.requestedSOPClassUID)
        let scheduledQuery = transport.writtenDataSets.first?
            .element(for: DicomWorkflowTag.scheduledProcedureStepSequence)?
            .sequenceItems.first?.dataSet
        XCTAssertEqual(scheduledQuery?.string(for: DicomWorkflowTag.modality), "CT")
    }

    func testMPPSCreateAndUpdateSendStatusDatasets() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.modalityPerformedProcedureStepSOPClass
        ])
        let service = makeService()
        let item = DicomModalityWorklistItem(dataSet: worklistDataSet())
        let create = DicomMPPSCreateRequest(
            sopInstanceUID: "2.25.mpps",
            status: .inProgress,
            performedStationAETitle: "VIEWER",
            startDate: "20260529",
            startTime: "120000",
            worklistItem: item
        )

        let createResult = try service.createMPPS(create, using: transport)
        let updateResult = try service.updateMPPS(
            DicomMPPSUpdateRequest(sopInstanceUID: "2.25.mpps",
                                   status: .completed,
                                   endDate: "20260529",
                                   endTime: "121500"),
            using: transport
        )

        XCTAssertEqual(createResult.status, 0)
        XCTAssertEqual(updateResult.status, 0)
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nSetRQ
        ])
        XCTAssertEqual(transport.writtenCommands[0].affectedSOPInstanceUID, "2.25.mpps")
        XCTAssertEqual(transport.writtenCommands[1].requestedSOPInstanceUID, "2.25.mpps")
        XCTAssertEqual(transport.writtenDataSets[0].string(for: DicomWorkflowTag.performedProcedureStepStatus),
                       DicomMPPSStatus.inProgress.rawValue)
        XCTAssertEqual(transport.writtenDataSets[1].string(for: DicomWorkflowTag.performedProcedureStepStatus),
                       DicomMPPSStatus.completed.rawValue)
        XCTAssertNotNil(transport.writtenDataSets[0].element(for: DicomWorkflowTag.scheduledStepAttributesSequence))
    }

    func testStorageCommitmentReportNegotiatesReverseRoleAndSendsPartialResult() throws {
        let sopClassUID = DicomNetworkUID.storageCommitmentPushModelSOPClass
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [sopClassUID])
        let service = makeService()
        let report = DicomStorageCommitmentReport(
            transactionUID: "2.25.commitment",
            status: .partial,
            references: [
                DicomStorageCommitmentReference(
                    sopClassUID: DicomStorageSOPClassUIDs.ctImageStorage,
                    sopInstanceUID: "2.25.stored"
                ),
                DicomStorageCommitmentReference(
                    sopClassUID: DicomStorageSOPClassUIDs.ctImageStorage,
                    sopInstanceUID: "2.25.missing",
                    status: .failed,
                    failureReasonCode: 0x0112
                )
            ]
        )

        let result = try service.reportStorageCommitment(report, using: transport)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(transport.associationRequests.first?.roleSelections, [
            DicomSCPSCURoleSelection(sopClassUID: sopClassUID, scuRole: false, scpRole: true)
        ])
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.nEventReportRQ
        ])
        XCTAssertEqual(transport.writtenCommands.first?.eventTypeID, 2)
        let dataSet = try XCTUnwrap(transport.writtenDataSets.first)
        XCTAssertEqual(dataSet.string(for: 0x0008_1195), "2.25.commitment")
        XCTAssertEqual(dataSet.sequenceItems(for: 0x0008_1199).count, 1)
        let failed = try XCTUnwrap(dataSet.sequenceItems(for: 0x0008_1198).first?.dataSet)
        XCTAssertEqual(failed.string(for: .referencedSOPInstanceUID), "2.25.missing")
        XCTAssertEqual(failed.element(for: 0x0008_1197)?.intValue, 0x0112)
    }

    func testStorageCommitmentReportRefusesWhenReverseRoleIsNotNegotiated() throws {
        let sopClassUID = DicomNetworkUID.storageCommitmentPushModelSOPClass
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [sopClassUID],
            roleSelectionPolicy: .ignore
        )
        let service = makeService()
        let report = DicomStorageCommitmentReport(
            transactionUID: "2.25.commitment",
            status: .committed,
            references: [
                DicomStorageCommitmentReference(
                    sopClassUID: DicomStorageSOPClassUIDs.ctImageStorage,
                    sopInstanceUID: "2.25.stored"
                )
            ]
        )

        XCTAssertThrowsError(try service.reportStorageCommitment(report, using: transport)) { error in
            XCTAssertEqual(error as? DicomNetworkError, .storageCommitmentRoleNotNegotiated)
        }
        XCTAssertTrue(transport.writtenCommands.isEmpty)
    }

    func testPrintManagementCreatesFilmSessionImageBoxAndPrints() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
        ])
        let service = makeService()
        let bitmap = try DicomRenderedBitmap(width: 1,
                                             height: 1,
                                             rgbData: Data([0x10, 0x20, 0x30]))
        let job = try DicomPrintJob(renderedBitmap: bitmap,
                                    template: .singleImage(label: "PRINT-1"),
                                    id: "print-job")

        let result = try service.sendPrintJob(job, using: transport)

        XCTAssertEqual(result.operation.status, 0)
        XCTAssertEqual(result.imageBoxSOPInstanceUIDs, ["2.25.imagebox.1"])
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nSetRQ,
            DicomDIMSECommandField.nActionRQ,
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nDeleteRQ,
            DicomDIMSECommandField.nDeleteRQ
        ])
        XCTAssertEqual(transport.writtenDataSets[0].string(for: DicomPrintTag.filmSessionLabel), "PRINT-1")
        XCTAssertEqual(transport.writtenCommands[4].requestedSOPInstanceUID, job.filmBoxSOPInstanceUID)
        XCTAssertEqual(transport.writtenCommands[4].actionTypeID, 1)

        let imageDataSet = transport.writtenDataSets[2]
            .sequenceItems(for: DicomPrintTag.basicGrayscaleImageSequence)
            .first?.dataSet
        XCTAssertEqual(imageDataSet?.int(for: .rows), 1)
        XCTAssertEqual(imageDataSet?.int(for: .columns), 1)
        XCTAssertEqual(imageDataSet?.int(for: .bitsAllocated), 8)
    }

    func testPrintManagementColorModeNegotiatesColorAndSendsRGBImageBox() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.basicColorPrintManagementMetaSOPClass
            ],
            printImageBoxSOPClassUID: DicomNetworkUID.basicColorImageBoxSOPClass
        )
        let service = makeService()
        let bitmap = try DicomRenderedBitmap(
            width: 2,
            height: 1,
            rgbData: Data([10, 20, 30, 200, 150, 100])
        )
        let job = try DicomPrintJob(
            filmSession: DicomFilmSession(label: "COLOR"),
            filmBox: DicomFilmBox(),
            printMode: .color,
            imageBoxes: [try DicomImageBox(bitmap: bitmap)]
        )

        let result = try service.sendPrintJob(job, using: transport)

        XCTAssertEqual(result.operation.status, 0)
        let proposedSOPClasses = Set(
            try XCTUnwrap(transport.associationRequests.first).presentationContexts.map(\.abstractSyntaxUID)
        )
        XCTAssertTrue(proposedSOPClasses.contains(DicomNetworkUID.basicColorPrintManagementMetaSOPClass))
        XCTAssertTrue(proposedSOPClasses.contains(DicomNetworkUID.basicColorImageBoxSOPClass))
        XCTAssertFalse(proposedSOPClasses.contains(DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass))
        XCTAssertFalse(proposedSOPClasses.contains(DicomNetworkUID.basicGrayscaleImageBoxSOPClass))

        let setCommand = try XCTUnwrap(transport.writtenCommands.first {
            $0.commandField == DicomDIMSECommandField.nSetRQ
        })
        XCTAssertEqual(setCommand.requestedSOPClassUID, DicomNetworkUID.basicColorImageBoxSOPClass)
        let imageDataSet = try XCTUnwrap(
            transport.writtenDataSets[2]
                .sequenceItems(for: DicomPrintTag.basicColorImageSequence)
                .first?.dataSet
        )
        XCTAssertEqual(imageDataSet.int(for: .samplesPerPixel), 3)
        XCTAssertEqual(imageDataSet.string(for: .photometricInterpretation), "RGB")
        // PS3.3 C.13.5: Basic Color Image Sequence is color-by-plane only.
        XCTAssertEqual(imageDataSet.int(for: .planarConfiguration), 1)
        let interleaved = [UInt8](bitmap.rgbData)
        let pixelCount = interleaved.count / 3
        var planar = Data(capacity: interleaved.count)
        for channel in 0..<3 { for pixel in 0..<pixelCount { planar.append(interleaved[pixel * 3 + channel]) } }
        XCTAssertNotNil(transport.writtenDataSetPayloads[2].range(of: planar))
        XCTAssertNil(transport.writtenDataSetPayloads[2].range(of: bitmap.rgbData))
    }

    func testPrintManagementAutomaticModePrefersColorWhenBothModesAreAccepted() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.basicColorPrintManagementMetaSOPClass,
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
            ],
            printImageBoxSOPClassUID: DicomNetworkUID.basicColorImageBoxSOPClass
        )
        let bitmap = try DicomRenderedBitmap(width: 1, height: 1, rgbData: Data([1, 2, 3]))
        let job = try DicomPrintJob(
            filmSession: DicomFilmSession(),
            filmBox: DicomFilmBox(),
            printMode: .automatic,
            imageBoxes: [try DicomImageBox(bitmap: bitmap)]
        )

        _ = try makeService().sendPrintJob(job, using: transport)

        XCTAssertEqual(
            transport.writtenCommands.first(where: {
                $0.commandField == DicomDIMSECommandField.nSetRQ
            })?.requestedSOPClassUID,
            DicomNetworkUID.basicColorImageBoxSOPClass
        )
        XCTAssertFalse(
            transport.writtenDataSets[2]
                .sequenceItems(for: DicomPrintTag.basicColorImageSequence)
                .isEmpty
        )
    }

    func testPrintManagementAutomaticModeFallsBackToGrayscale() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
        ])
        let bitmap = try DicomRenderedBitmap(width: 1, height: 1, rgbData: Data([0x10, 0x20, 0x30]))
        let job = try DicomPrintJob(
            filmSession: DicomFilmSession(),
            filmBox: DicomFilmBox(),
            printMode: .automatic,
            imageBoxes: [try DicomImageBox(bitmap: bitmap)]
        )

        _ = try makeService().sendPrintJob(job, using: transport)

        let proposedSOPClasses = Set(
            try XCTUnwrap(transport.associationRequests.first).presentationContexts.map(\.abstractSyntaxUID)
        )
        XCTAssertTrue(proposedSOPClasses.contains(DicomNetworkUID.basicColorPrintManagementMetaSOPClass))
        XCTAssertTrue(proposedSOPClasses.contains(DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass))
        XCTAssertEqual(
            transport.writtenCommands.first(where: {
                $0.commandField == DicomDIMSECommandField.nSetRQ
            })?.requestedSOPClassUID,
            DicomNetworkUID.basicGrayscaleImageBoxSOPClass
        )
        let imageDataSet = try XCTUnwrap(
            transport.writtenDataSets[2]
                .sequenceItems(for: DicomPrintTag.basicGrayscaleImageSequence)
                .first?.dataSet
        )
        XCTAssertEqual(imageDataSet.int(for: .samplesPerPixel), 1)
        XCTAssertEqual(imageDataSet.string(for: .photometricInterpretation), "MONOCHROME2")
    }

    func testPrintManagementExplicitColorNeverFallsBackToGrayscale() throws {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
        ])
        let bitmap = try DicomRenderedBitmap(width: 1, height: 1, rgbData: Data([1, 2, 3]))
        let job = try DicomPrintJob(
            filmSession: DicomFilmSession(),
            filmBox: DicomFilmBox(),
            printMode: .color,
            imageBoxes: [try DicomImageBox(bitmap: bitmap)]
        )

        XCTAssertThrowsError(try makeService().sendPrintJob(job, using: transport)) { error in
            XCTAssertEqual(error as? DicomPrintManagementError, .printModeNotNegotiated(.color))
        }
        XCTAssertTrue(transport.writtenCommands.isEmpty)
    }

    func testPrintManagementQueriesPrinterStatusAndAcknowledgesEvents() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                DicomNetworkUID.printerSOPClass
            ],
            printerStatusDataSets: [
                printerStatusDataSet(state: "NORMAL", info: "NORMAL"),
                printerStatusDataSet(state: "FAILURE", info: "SUPPLY EMPTY")
            ],
            printerEventTypeID: 3,
            printerEventStatusInfo: "FILM JAM"
        )
        let service = makeService()
        let bitmap = try DicomRenderedBitmap(width: 1,
                                             height: 1,
                                             rgbData: Data([0x10, 0x20, 0x30]))
        let job = try DicomPrintJob(renderedBitmap: bitmap)

        let result = try service.sendPrintJob(job, using: transport)

        XCTAssertEqual(result.printerStatusReports, [
            DicomPrinterStatusReport(state: .normal,
                                     statusInfo: "NORMAL",
                                     printerName: "DRY IMAGER",
                                     source: .nGet),
            DicomPrinterStatusReport(state: .failure,
                                     statusInfo: "FILM JAM",
                                     source: .nEventReport(eventTypeID: 3)),
            DicomPrinterStatusReport(state: .failure,
                                     statusInfo: "SUPPLY EMPTY",
                                     printerName: "DRY IMAGER",
                                     source: .nGet)
        ])
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nSetRQ,
            DicomDIMSECommandField.nActionRQ,
            DicomDIMSECommandField.nEventReportRSP,
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nDeleteRQ,
            DicomDIMSECommandField.nDeleteRQ
        ])
        XCTAssertEqual(
            transport.writtenCommands.first(where: {
                $0.commandField == DicomDIMSECommandField.nEventReportRSP
            })?.messageIDBeingRespondedTo,
            0x7100
        )
    }

    func testPrintManagementContinuesWhenPrinterRefusesStatusQuery() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                DicomNetworkUID.printerSOPClass
            ],
            nGetResponseStatus: 0x0122
        )
        let service = makeService()
        let bitmap = try DicomRenderedBitmap(width: 1,
                                             height: 1,
                                             rgbData: Data([0x10, 0x20, 0x30]))
        let job = try DicomPrintJob(renderedBitmap: bitmap)

        let result = try service.sendPrintJob(job, using: transport)

        XCTAssertEqual(result.operation.status, 0)
        XCTAssertTrue(result.printerStatusReports.isEmpty)
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nSetRQ,
            DicomDIMSECommandField.nActionRQ,
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nDeleteRQ,
            DicomDIMSECommandField.nDeleteRQ
        ])
    }

    func test_printManagementWithImageBoxWarning_propagatesAcceptedWarning() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass],
            nSetResponseStatus: 0xB604
        )
        let service = makeService()
        let bitmap = try DicomRenderedBitmap(width: 1,
                                             height: 1,
                                             rgbData: Data([0x10, 0x20, 0x30]))
        let job = try DicomPrintJob(renderedBitmap: bitmap,
                                    template: .singleImage(label: "PRINT-WARNING"),
                                    id: "print-warning")

        let result = try service.sendPrintJob(job, using: transport)

        XCTAssertEqual(result.operation.status, 0xB604)
    }

    func test_printManagementWithActionWarning_acceptsWarning() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass],
            nActionResponseStatus: 0xB600
        )
        let service = makeService()
        let bitmap = try DicomRenderedBitmap(width: 1,
                                             height: 1,
                                             rgbData: Data([0x10, 0x20, 0x30]))
        let job = try DicomPrintJob(renderedBitmap: bitmap,
                                    template: .singleImage(label: "PRINT-WARNING"),
                                    id: "print-warning")

        let result = try service.sendPrintJob(job, using: transport)

        XCTAssertEqual(result.operation.status, 0xB600)
    }

    func test_printManagementWithCreateWarnings_propagatesAcceptedWarning() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass],
            nCreateResponseStatus: 0xB605
        )
        let service = makeService()
        let bitmap = try DicomRenderedBitmap(width: 1,
                                             height: 1,
                                             rgbData: Data([0x10, 0x20, 0x30]))
        let job = try DicomPrintJob(renderedBitmap: bitmap,
                                    template: .singleImage(label: "PRINT-WARNING"),
                                    id: "print-warning")

        let result = try service.sendPrintJob(job, using: transport)

        XCTAssertEqual(result.operation.status, 0xB605)
    }

    /// A printer answering a film box with fewer Referenced Image Box items than
    /// the job declared is conformant, not broken. The SCU used to invent one
    /// UID per missing box, so the N-SETs that followed addressed SOP instances
    /// the printer never created — silently. It must report both counts instead,
    /// and send nothing.
    func testPrintManagementReportsFewerImageBoxesThanRequestedWithoutSendingAnyImage() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass],
            grantedImageBoxCount: 1
        )
        let service = makeService()
        let bitmap = try DicomRenderedBitmap(width: 1,
                                             height: 1,
                                             rgbData: Data([0x10, 0x20, 0x30]))
        // The layout holds the images (issue #1907 refuses an over-capacity
        // job before any association) — the shortfall is the printer's:
        // it grants a single box for a film that declared three.
        let job = try DicomPrintJob(
            filmSession: DicomFilmSession(label: "PRINT-SHORTFALL"),
            filmBox: DicomFilmBox(imageDisplayFormat: "STANDARD\\2,2"),
            imageBoxes: [
                try DicomImageBox(position: 1, bitmap: bitmap),
                try DicomImageBox(position: 2, bitmap: bitmap),
                try DicomImageBox(position: 3, bitmap: bitmap)
            ]
        )

        XCTAssertThrowsError(try service.sendPrintJob(job, using: transport)) { error in
            XCTAssertEqual(error as? DicomPrintManagementError,
                           .insufficientImageBoxes(requested: 3, granted: 1))
        }

        // The film session and film box were created; no image was set and no
        // film was printed.
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nCreateRQ
        ])
        XCTAssertEqual(transport.releaseRequestCount, 1)
    }

    // MARK: - Basic Annotation Box (issue #1908)

    private func annotationBitmap() throws -> DicomRenderedBitmap {
        try DicomRenderedBitmap(width: 1, height: 1, rgbData: Data([0x10, 0x20, 0x30]))
    }

    private func annotatedJob(annotationTexts: [String] = ["DOE^JANE 2.25.9"],
                              formatID: String? = "LABEL") throws -> DicomPrintJob {
        try DicomPrintJob(
            filmSession: DicomFilmSession(label: "ANNOTATED"),
            filmBox: DicomFilmBox(imageDisplayFormat: "STANDARD\\1,1",
                                  annotationDisplayFormatID: formatID),
            imageBoxes: [try DicomImageBox(position: 1, bitmap: annotationBitmap())],
            annotations: try annotationTexts.enumerated().map {
                try DicomPrintAnnotation(position: $0.offset + 1, text: $0.element)
            }
        )
    }

    func test_annotatedPrint_negotiatesSetsAndPrints() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                DicomNetworkUID.basicAnnotationBoxSOPClass
            ],
            grantedAnnotationBoxCount: 2
        )
        let service = makeService()
        let job = try annotatedJob(annotationTexts: ["DOE^JANE", "STUDY 2.25.9"])

        let result = try service.sendPrintJob(job, using: transport)

        // The annotation context was proposed alongside the meta class.
        let proposedSyntaxes = Set(transport.associationRequests
            .flatMap(\.presentationContexts)
            .map(\.abstractSyntaxUID))
        XCTAssertTrue(proposedSyntaxes.contains(DicomNetworkUID.basicAnnotationBoxSOPClass))

        // Session create, film box create, image N-SET, two annotation
        // N-SETs, then the print action — in that order.
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nSetRQ,
            DicomDIMSECommandField.nSetRQ,
            DicomDIMSECommandField.nSetRQ,
            DicomDIMSECommandField.nActionRQ,
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nDeleteRQ,
            DicomDIMSECommandField.nDeleteRQ
        ])
        // The UIDs came from the printer's response, none invented.
        XCTAssertEqual(result.annotationBoxSOPInstanceUIDs,
                       ["2.25.annotationbox.1", "2.25.annotationbox.2"])
        let annotationSets = transport.writtenCommands.filter {
            $0.commandField == DicomDIMSECommandField.nSetRQ
                && $0.requestedSOPClassUID == DicomNetworkUID.basicAnnotationBoxSOPClass
        }
        XCTAssertEqual(annotationSets.map(\.requestedSOPInstanceUID),
                       ["2.25.annotationbox.1", "2.25.annotationbox.2"])
        // Each text went to its box with its position.
        let annotationDataSets = transport.writtenDataSets.filter {
            $0.string(for: DicomPrintTag.textString) != nil
        }
        XCTAssertEqual(annotationDataSets.count, 2)
        XCTAssertEqual(annotationDataSets[0].string(for: DicomPrintTag.textString), "DOE^JANE")
        XCTAssertEqual(annotationDataSets[1].string(for: DicomPrintTag.textString), "STUDY 2.25.9")
        XCTAssertEqual(result.operation.status, 0)
    }

    func test_annotatedPrint_filmBoxCarriesTheFormatIDOnlyWhenRequested() throws {
        let withFormat = DicomFilmBox(imageDisplayFormat: "STANDARD\\1,1",
                                      annotationDisplayFormatID: "LABEL")
        XCTAssertEqual(withFormat.dataSet(referencingFilmSessionUID: "2.25.1")
            .string(for: DicomPrintTag.annotationDisplayFormatID), "LABEL")

        let without = DicomFilmBox(imageDisplayFormat: "STANDARD\\1,1")
        XCTAssertNil(without.dataSet(referencingFilmSessionUID: "2.25.1")
            .string(for: DicomPrintTag.annotationDisplayFormatID))
    }

    /// No annotation context accepted → nothing is created, nothing printed.
    /// The film must never quietly come out without its identification.
    func test_annotatedPrint_withoutNegotiatedContext_refusesBeforeCreatingAnything() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
            ]
        )
        let service = makeService()
        let job = try annotatedJob()

        XCTAssertThrowsError(try service.sendPrintJob(job, using: transport)) { error in
            XCTAssertEqual(error as? DicomPrintManagementError, .annotationBoxNotNegotiated)
        }
        XCTAssertTrue(transport.writtenCommands.isEmpty,
                      "no film session or film box was created for a film that cannot be identified")
    }

    /// A refused Annotation Display Format surfaces as the film box create
    /// failure it is. The SCU does not recreate the film box without
    /// annotations — a generic create failure does not prove the format was
    /// the cause, and retrying blind is the reference implementation's bug.
    func test_annotatedPrint_refusedFilmBoxCreate_doesNotRecreateWithoutAnnotations() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                DicomNetworkUID.basicAnnotationBoxSOPClass
            ],
            grantedAnnotationBoxCount: 1,
            nCreateResponseStatus: 0x0106
        )
        let service = makeService()
        let job = try annotatedJob()

        XCTAssertThrowsError(try service.sendPrintJob(job, using: transport)) { error in
            guard case DicomNetworkError.dimseStatusFailure(let status)? = error as? DicomNetworkError else {
                return XCTFail("expected a DIMSE status failure, got \(error)")
            }
            XCTAssertEqual(status, 0x0106)
        }
        // One successful session create, one failed film box create — and no
        // second film box without annotations.
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nCreateRQ
        ])
    }

    /// The response carries no Referenced Basic Annotation Box Sequence at
    /// all: the boxes do not exist, no UID is invented, no N-SET goes out.
    func test_annotatedPrint_missingAnnotationSequence_refusesWithBothCounts() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                DicomNetworkUID.basicAnnotationBoxSOPClass
            ],
            grantedAnnotationBoxCount: nil
        )
        let service = makeService()
        let job = try annotatedJob()

        XCTAssertThrowsError(try service.sendPrintJob(job, using: transport)) { error in
            XCTAssertEqual(error as? DicomPrintManagementError,
                           .insufficientAnnotationBoxes(requested: 1, granted: 0))
        }
        XCTAssertFalse(transport.writtenCommands.contains {
            $0.commandField == DicomDIMSECommandField.nSetRQ
        }, "no N-SET was sent for boxes that do not exist")
    }

    func test_annotatedPrint_insufficientAnnotationBoxes_reportsBothCounts() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                DicomNetworkUID.basicAnnotationBoxSOPClass
            ],
            grantedAnnotationBoxCount: 1
        )
        let service = makeService()
        let job = try annotatedJob(annotationTexts: ["A", "B", "C"])

        XCTAssertThrowsError(try service.sendPrintJob(job, using: transport)) { error in
            XCTAssertEqual(error as? DicomPrintManagementError,
                           .insufficientAnnotationBoxes(requested: 3, granted: 1))
        }
    }

    /// A refused annotation N-SET stops the job before the print action:
    /// printing would produce a film missing the identification it was
    /// approved with.
    func test_annotatedPrint_refusedAnnotationSet_neverPrintsTheFilm() throws {
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass,
                DicomNetworkUID.basicAnnotationBoxSOPClass
            ],
            grantedAnnotationBoxCount: 1,
            annotationNSetResponseStatus: 0x0112
        )
        let service = makeService()
        let job = try annotatedJob()

        XCTAssertThrowsError(try service.sendPrintJob(job, using: transport)) { error in
            XCTAssertEqual(error as? DicomPrintManagementError,
                           .annotationSetFailed(position: 1, status: 0x0112))
        }
        XCTAssertFalse(transport.writtenCommands.contains {
            $0.commandField == DicomDIMSECommandField.nActionRQ
        }, "the film's N-ACTION was never sent")
    }

    func test_annotationModelRefusesMalformedInput() throws {
        XCTAssertThrowsError(try DicomPrintAnnotation(position: 0, text: "X"))
        XCTAssertThrowsError(try DicomPrintAnnotation(position: 1, text: "   "))
        XCTAssertThrowsError(try DicomPrintAnnotation(position: 1,
                                                      text: String(repeating: "x", count: 65)))
        // Annotations without a display format on the film box are refused
        // at the job, before any association.
        XCTAssertThrowsError(try annotatedJob(formatID: nil)) { error in
            guard case DicomPrintManagementError.invalidAnnotation? = error as? DicomPrintManagementError else {
                return XCTFail("expected invalidAnnotation, got \(error)")
            }
        }
        // Duplicate positions are one text stomping another.
        XCTAssertThrowsError(try DicomPrintJob(
            filmSession: DicomFilmSession(),
            filmBox: DicomFilmBox(imageDisplayFormat: "STANDARD\\1,1",
                                  annotationDisplayFormatID: "LABEL"),
            imageBoxes: [try DicomImageBox(position: 1, bitmap: annotationBitmap())],
            annotations: [
                try DicomPrintAnnotation(position: 1, text: "A"),
                try DicomPrintAnnotation(position: 1, text: "B")
            ]
        ))
    }

    func test_printManagementWithInsufficientImageBoxes_doesNotRetry() throws {
        var transports: [DIMSEScriptedTransport] = []
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(retryPolicy: DicomNetworkRetryPolicy(maxAttempts: 3)),
            transportFactory: {
                let transport = DIMSEScriptedTransport(
                    supportedAbstractSyntaxUIDs: [
                        DicomNetworkUID.basicGrayscalePrintManagementMetaSOPClass
                    ],
                    grantedImageBoxCount: 1
                )
                transports.append(transport)
                return transport
            }
        )
        let bitmap = try DicomRenderedBitmap(width: 1,
                                             height: 1,
                                             rgbData: Data([0x10, 0x20, 0x30]))
        // A valid two-image job on a two-slot film; the scripted printer
        // still grants only one box (issue #1907 keeps over-capacity jobs
        // from ever reaching the wire).
        let job = try DicomPrintJob(
            filmSession: DicomFilmSession(label: "PRINT-SHORTFALL"),
            filmBox: DicomFilmBox(imageDisplayFormat: "STANDARD\\1,2"),
            imageBoxes: [
                try DicomImageBox(position: 1, bitmap: bitmap),
                try DicomImageBox(position: 2, bitmap: bitmap)
            ]
        )

        XCTAssertThrowsError(try service.sendPrintJob(job)) { error in
            XCTAssertEqual(error as? DicomPrintManagementError,
                           .insufficientImageBoxes(requested: 2, granted: 1))
        }

        XCTAssertEqual(transports.count, 1)
        XCTAssertEqual(transports[0].writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.nGetRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nCreateRQ
        ])
    }

    func testStoreSCUSendsDataSetAndReportsSuccess() throws {
        let storageUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [storageUID])
        let service = makeService()
        let dataSet = storageDataSet()

        let result = try service.store(dataSet: dataSet, using: transport)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.cStoreRQ
        ])
        XCTAssertEqual(transport.writtenDataSets.first?.string(for: .sopInstanceUID), "2.25.instance")
        XCTAssertEqual(transport.writtenDataSets.first?.string(for: .patientName), "DOE^JANE")
    }

    func testStoreRequestFromPart10DataPreservesMetadataTransferSyntaxAndPayload() throws {
        let sopInstanceUID = "2.25.1001"
        let dataSet = writableStorageDataSet(sopInstanceUID: sopInstanceUID)
        let transferSyntax = DicomTransferSyntax.implicitVRLittleEndian
        let part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: transferSyntax,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )

        let request = try DicomStoreRequest(part10Data: part10Data)

        XCTAssertEqual(request.sopClassUID, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID)
        XCTAssertEqual(request.sopInstanceUID, sopInstanceUID)
        XCTAssertEqual(request.transferSyntax, transferSyntax)
        XCTAssertEqual(
            request.dataSetData,
            try DicomDataSetWriter.dataSetData(from: dataSet, transferSyntax: transferSyntax)
        )
    }

    func testStoreRequestFromSlicedPart10DataUsesLogicalByteOffsets() throws {
        let sopInstanceUID = "2.25.1002"
        let dataSet = writableStorageDataSet(sopInstanceUID: sopInstanceUID)
        let part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .implicitVRLittleEndian,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )
        var storage = Data(repeating: 0xA5, count: 150)
        storage.append(part10Data)
        let slicedPart10Data: Data = storage[150...]
        XCTAssertEqual(slicedPart10Data.startIndex, 150)

        let request = try DicomStoreRequest(part10Data: slicedPart10Data)

        XCTAssertEqual(request.sopInstanceUID, sopInstanceUID)
        XCTAssertEqual(request.transferSyntax, .implicitVRLittleEndian)
        XCTAssertEqual(
            request.dataSetData,
            try DicomDataSetWriter.dataSetData(from: dataSet, transferSyntax: .implicitVRLittleEndian)
        )
    }

    func testStoreRequestFromCompressedPart10DataPreservesEncapsulatedPayload() throws {
        let dataSet = compressedStorageDataSet()
        let part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .jpeg2000Lossless,
                mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                mediaStorageSOPInstanceUID: "2.25.2001"
            )
        )

        let request = try DicomStoreRequest(part10Data: part10Data)

        XCTAssertEqual(request.sopInstanceUID, "2.25.2001")
        XCTAssertEqual(request.transferSyntax, .jpeg2000Lossless)
        XCTAssertNotNil(request.dataSetData.range(of: encapsulatedPixelData()))
    }

    func testStoreSCUSendsRawStoreRequestAndReportsProgress() throws {
        let storageUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let sopInstanceUID = "2.25.1001"
        let dataSet = writableStorageDataSet(sopInstanceUID: sopInstanceUID)
        let part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: storageUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )
        let request = try DicomStoreRequest(part10Data: part10Data)
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [storageUID])
        let service = makeService()
        var progress: [DicomDIMSEProgress] = []

        let result = try service.store(request: request, using: transport) { progress.append($0) }

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.cStoreRQ
        ])
        XCTAssertEqual(transport.writtenCommands.first?.affectedSOPClassUID, storageUID)
        XCTAssertEqual(transport.writtenCommands.first?.affectedSOPInstanceUID, sopInstanceUID)
        XCTAssertEqual(transport.writtenDataSetPayloads.first, request.dataSetData)
        XCTAssertEqual(transport.writtenDataSets.first?.string(for: .sopInstanceUID), sopInstanceUID)
        XCTAssertTrue(progress.contains(.requestSent(operation: .store, messageID: 1)))
        XCTAssertTrue(progress.contains(.completed(operation: .store, status: 0)))
    }

    func testStoreSCUFragmentsDataSetWithinNegotiatedMaximumPDULength() throws {
        let storageUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let sopInstanceUID = "2.25.1002"
        let maximumPDULength: UInt32 = 256
        let dataSet = writableStorageDataSet(
            sopInstanceUID: sopInstanceUID,
            pixelData: Data(repeating: 0x7F, count: 2_048)
        )
        let part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .explicitVRLittleEndian,
                mediaStorageSOPClassUID: storageUID,
                mediaStorageSOPInstanceUID: sopInstanceUID
            )
        )
        let request = try DicomStoreRequest(part10Data: part10Data)
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [storageUID])
        transport.maximumPDULength = maximumPDULength
        let service = DicomDIMSEServiceSCU(configuration: makeConfiguration(
            maximumPDULength: maximumPDULength
        ))

        let result = try service.store(request: request, using: transport)

        let dataSetPDataFrames = transport.writtenPDataFrames.filter { frame in
            frame.pdvs.allSatisfy { !$0.isCommand }
        }
        let dataSetPDVs = dataSetPDataFrames.flatMap(\.pdvs)
        XCTAssertEqual(result.status, 0)
        XCTAssertGreaterThan(dataSetPDataFrames.count, 1)
        XCTAssertTrue(dataSetPDataFrames.allSatisfy {
            $0.byteCount <= Int(maximumPDULength) + 6
        })
        XCTAssertTrue(dataSetPDVs.dropLast().allSatisfy { !$0.isLastFragment })
        XCTAssertEqual(dataSetPDVs.last?.isLastFragment, true)
        XCTAssertEqual(dataSetPDVs.reduce(into: Data()) { $0.append($1.data) }, request.dataSetData)
        XCTAssertEqual(transport.writtenDataSets.first?.string(for: .sopInstanceUID), sopInstanceUID)
    }

    func testStoreSCUProposesOnlyRequestTransferSyntaxForRawPayload() throws {
        let storageUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let dataSet = writableStorageDataSet(sopInstanceUID: "2.25.1001")
        let part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .implicitVRLittleEndian,
                mediaStorageSOPClassUID: storageUID,
                mediaStorageSOPInstanceUID: "2.25.1001"
            )
        )
        let request = try DicomStoreRequest(part10Data: part10Data)
        let service = DicomDIMSEServiceSCU(configuration: makeConfiguration(
            transferSyntaxes: [.explicitVRLittleEndian, .implicitVRLittleEndian]
        ))
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [storageUID],
            preferredTransferSyntaxes: [.explicitVRLittleEndian, .implicitVRLittleEndian]
        )

        let result = try service.store(request: request, using: transport)

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(transport.associationRequests.first?.presentationContexts.first?.transferSyntaxUIDs, [
            DicomTransferSyntax.implicitVRLittleEndian.rawValue
        ])
        XCTAssertEqual(transport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.cStoreRQ
        ])
        XCTAssertEqual(transport.writtenDataSetPayloads.first, request.dataSetData)
    }

    func testStoreSCUWhenStoredSyntaxIsRejectedReportsAcceptedLosslessAlternativeWithoutSending() throws {
        let storageUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let dataSet = writableStorageDataSet(sopInstanceUID: "2.25.1002")
        let part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .implicitVRLittleEndian,
                mediaStorageSOPClassUID: storageUID,
                mediaStorageSOPInstanceUID: "2.25.1002"
            )
        )
        var request = try DicomStoreRequest(part10Data: part10Data)
        request.proposedTransferSyntaxes = [.implicitVRLittleEndian, .explicitVRLittleEndian]
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [storageUID],
            preferredTransferSyntaxes: [.explicitVRLittleEndian]
        )
        let service = makeService()

        XCTAssertThrowsError(try service.store(request: request, using: transport)) { error in
            XCTAssertEqual(
                error as? DicomNetworkError,
                .transferSyntaxMismatch(
                    expected: DicomTransferSyntax.implicitVRLittleEndian.rawValue,
                    actual: DicomTransferSyntax.explicitVRLittleEndian.rawValue
                )
            )
        }
        XCTAssertEqual(
            transport.associationRequests.first?.presentationContexts.map(\.transferSyntaxUIDs),
            [
                [DicomTransferSyntax.implicitVRLittleEndian.rawValue],
                [DicomTransferSyntax.explicitVRLittleEndian.rawValue]
            ]
        )
        XCTAssertTrue(transport.writtenCommands.isEmpty)
        XCTAssertTrue(transport.writtenDataSetPayloads.isEmpty)
    }

    func testStoreSCUWhenNoProposedSyntaxIsAcceptedReportsTypedPresentationContextRefusal() throws {
        let storageUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let dataSet = writableStorageDataSet(sopInstanceUID: "2.25.1003")
        let part10Data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .implicitVRLittleEndian,
                mediaStorageSOPClassUID: storageUID,
                mediaStorageSOPInstanceUID: "2.25.1003"
            )
        )
        var request = try DicomStoreRequest(part10Data: part10Data)
        request.proposedTransferSyntaxes = [.implicitVRLittleEndian, .explicitVRLittleEndian]
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [storageUID],
            preferredTransferSyntaxes: [.jpeg2000Lossless]
        )
        let service = makeService()

        XCTAssertThrowsError(try service.store(request: request, using: transport)) { error in
            XCTAssertEqual(
                error as? DicomNetworkError,
                .presentationContextRejected(
                    abstractSyntaxUID: storageUID,
                    result: .transferSyntaxNotSupported,
                    proposedTransferSyntaxUIDs: [
                        DicomTransferSyntax.implicitVRLittleEndian.rawValue,
                        DicomTransferSyntax.explicitVRLittleEndian.rawValue
                    ]
                )
            )
        }
        XCTAssertTrue(transport.writtenCommands.isEmpty)
    }

    func testAssociationTimeoutReachesCaller() throws {
        let service = makeService()
        let transport = TimeoutTransport()

        XCTAssertThrowsError(try service.verify(using: transport)) { error in
            XCTAssertEqual(error as? DicomNetworkError, .networkTimeout("association response"))
        }
    }

    func testAssociationUsesConfiguredUserIdentity() throws {
        let identity = DicomUserIdentity.usernameAndPasscode(
            "operator",
            passcode: "secret",
            positiveResponseRequested: true
        )
        let service = DicomDIMSEServiceSCU(configuration: makeConfiguration(
            tls: DicomTLSConfiguration(mode: .enabled, serverName: "archive.example"),
            userIdentity: identity
        ))
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.verificationSOPClass
        ])

        _ = try service.verify(using: transport)

        XCTAssertEqual(transport.associationRequests.first?.userIdentity, identity)
    }

    func testUserIdentityWithoutTLSIsRejectedBeforeAssociationRequest() throws {
        let identity = DicomUserIdentity.usernameAndPasscode("operator", passcode: "secret")
        let service = makeService(userIdentity: identity)
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.verificationSOPClass
        ])

        XCTAssertThrowsError(try service.verify(using: transport)) { error in
            XCTAssertEqual(error as? DicomNetworkError, .insecureUserIdentityTransport)
        }
        XCTAssertTrue(transport.associationRequests.isEmpty)
    }

    func testDefaultSCURejectsUserIdentityWithoutTLSBeforeOpeningTransport() throws {
        let identity = DicomUserIdentity.username("operator")
        var transportFactoryCalls = 0
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(userIdentity: identity),
            transportFactory: {
                transportFactoryCalls += 1
                return DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
                    DicomNetworkUID.verificationSOPClass
                ])
            }
        )

        XCTAssertThrowsError(try service.verify()) { error in
            XCTAssertEqual(error as? DicomNetworkError, .insecureUserIdentityTransport)
        }
        XCTAssertEqual(transportFactoryCalls, 0)
    }

    func testDefaultSCURetriesAndAuditsFailuresWithoutPayloadData() throws {
        let auditLog = DicomInMemoryNetworkAuditLog()
        var attempt = 0
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(retryPolicy: DicomNetworkRetryPolicy(maxAttempts: 2)),
            auditLogger: auditLog,
            transportFactory: {
                attempt += 1
                if attempt == 1 {
                    return FailingReadTransport(error: DicomNetworkError.malformedCommandSet("DOE^JANE"))
                }
                return DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
                    DicomNetworkUID.verificationSOPClass
                ])
            }
        )

        let result = try service.verify()

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(attempt, 2)
        XCTAssertEqual(auditLog.events.map(\.outcome), [
            .started,
            .retrying,
            .started,
            .succeeded
        ])
        XCTAssertFalse(auditLog.events.compactMap(\.errorDescription).contains { $0.contains("DOE") })
    }

    func testDefaultSCURetriesTimeoutAssociationRejectionAndDIMSEFailure() throws {
        let associationReject = DicomAssociationReject(
            result: .rejectedTransient,
            source: .serviceProviderACSE,
            reason: .noReason
        )
        let cases: [(String, Error)] = [
            ("transient", DicomNetworkError.networkUnavailable("transient transport failure")),
            ("timeout", DicomNetworkError.networkTimeout("association response")),
            ("association", DicomNetworkError.associationRejected(associationReject)),
            ("dimse", DicomNetworkError.dimseStatusFailure(0xA700))
        ]

        for testCase in cases {
            let auditLog = DicomInMemoryNetworkAuditLog()
            var attempt = 0
            let service = DicomDIMSEServiceSCU(
                configuration: makeConfiguration(retryPolicy: DicomNetworkRetryPolicy(maxAttempts: 2)),
                auditLogger: auditLog,
                transportFactory: {
                    attempt += 1
                    if attempt == 1 {
                        return FailingReadTransport(error: testCase.1)
                    }
                    return DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
                        DicomNetworkUID.verificationSOPClass
                    ])
                }
            )

            let result = try service.verify()

            XCTAssertEqual(result.status, 0, testCase.0)
            XCTAssertEqual(attempt, 2, testCase.0)
            XCTAssertEqual(auditLog.events.map(\.outcome), [
                .started,
                .retrying,
                .started,
                .succeeded
            ], testCase.0)
        }
    }

    func testCircuitBreakerBlocksAfterFailureThreshold() throws {
        let auditLog = DicomInMemoryNetworkAuditLog()
        let breaker = DicomNetworkCircuitBreaker(policy: DicomCircuitBreakerPolicy(
            failureThreshold: 1,
            resetInterval: 60
        ))
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(),
            auditLogger: auditLog,
            circuitBreaker: breaker,
            transportFactory: {
                FailingReadTransport(error: DicomNetworkError.networkTimeout("association response"))
            }
        )

        XCTAssertThrowsError(try service.verify()) { error in
            XCTAssertEqual(error as? DicomNetworkError, .networkTimeout("association response"))
        }
        XCTAssertThrowsError(try service.verify()) { error in
            XCTAssertEqual(error as? DicomNetworkError, .circuitBreakerOpen("C-ECHO"))
        }
        XCTAssertEqual(auditLog.events.map(\.outcome), [
            .started,
            .failed,
            .blocked
        ])
    }

    func testCircuitBreakerResetsAfterOpenIntervalAndRecordsSuccess() throws {
        let breaker = DicomNetworkCircuitBreaker(policy: DicomCircuitBreakerPolicy(
            failureThreshold: 1,
            resetInterval: 0
        ))
        var attempt = 0
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(),
            circuitBreaker: breaker,
            transportFactory: {
                attempt += 1
                if attempt == 1 {
                    return FailingReadTransport(error: DicomNetworkError.networkTimeout("association response"))
                }
                return DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
                    DicomNetworkUID.verificationSOPClass
                ])
            }
        )

        XCTAssertThrowsError(try service.verify()) { error in
            XCTAssertEqual(error as? DicomNetworkError, .networkTimeout("association response"))
        }
        if case .open = breaker.state {
        } else {
            XCTFail("Expected circuit breaker to open after first failure.")
        }
        let result = try service.verify()

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(breaker.state, .closed)
    }

    func testDefaultSCUDoesNotRetryCancellationOrTripCircuitBreaker() throws {
        let auditLog = DicomInMemoryNetworkAuditLog()
        let breaker = DicomNetworkCircuitBreaker(policy: DicomCircuitBreakerPolicy(
            failureThreshold: 1,
            resetInterval: 60
        ))
        var attempt = 0
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(retryPolicy: DicomNetworkRetryPolicy(maxAttempts: 3)),
            auditLogger: auditLog,
            circuitBreaker: breaker,
            transportFactory: {
                attempt += 1
                return FailingReadTransport(error: CancellationError())
            }
        )

        XCTAssertThrowsError(try service.verify()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(breaker.state, .closed)
        XCTAssertEqual(auditLog.events.map(\.outcome), [
            .started,
            .failed
        ])
    }

    func testBandwidthLimitedTransportForwardsReadsAndWrites() throws {
        let raw = RecordingTransport(responses: [Data([0x01, 0x02])])
        let limited = DicomBandwidthLimitedTransport(wrapping: raw, bytesPerSecond: Int.max)
        let payload = Data([0x03, 0x04, 0x05])

        try limited.writePDU(payload)
        let read = try limited.readPDU()

        XCTAssertEqual(raw.writtenPDUs, [payload])
        XCTAssertEqual(read, Data([0x01, 0x02]))
    }

    func testBandwidthLimitedTransportAccountsForSubsecondPDUsAcrossCalls() throws {
        let raw = RecordingTransport(responses: [])
        var currentTime: TimeInterval = 100
        var delays: [TimeInterval] = []
        let limited = DicomBandwidthLimitedTransport(
            wrapping: raw,
            bytesPerSecond: 100,
            currentTime: { currentTime },
            sleep: { delay in
                delays.append(delay)
                currentTime += delay
            }
        )

        try limited.writePDU(Data(repeating: 0x01, count: 80))
        try limited.writePDU(Data(repeating: 0x02, count: 80))

        XCTAssertEqual(delays.count, 1)
        XCTAssertEqual(delays[0], 0.6, accuracy: 0.000_1)
        XCTAssertEqual(raw.writtenPDUs.map(\.count), [80, 80])
    }

    func testTLSMaterialIsPreservedForSCUAndStorageSCPConfiguration() throws {
        let material = DicomTLSMaterial(
            certificatePath: "/tmp/client.pem",
            privateKeyPath: "/tmp/client.key",
            trustStorePath: "/tmp/trust.pem",
            trustedCertificatePaths: ["/tmp/root.pem"]
        )
        let tls = DicomTLSConfiguration(
            mode: .enabled,
            serverName: "archive.example",
            material: material,
            securityProfile: .bcp195RFC8996
        )
        let scu = DicomDIMSEServiceSCU(configuration: makeConfiguration(tls: tls))
        let scp = DicomStorageSCPConfiguration(aeTitle: "VIEWER", tls: tls)

        XCTAssertEqual(scu.configuration.tls, tls)
        XCTAssertEqual(scp.tls, tls)
    }

    func testTLSOptionsApplyIdentityTrustStoreServerNameAndProfile() throws {
        #if canImport(Network) && canImport(Security)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let tls = DicomTLSConfiguration(
            mode: .enabled,
            serverName: "localhost",
            material: DicomTLSMaterial(
                certificatePath: fixture.serverCertificatePath,
                privateKeyPath: fixture.serverPrivateKeyPath,
                trustStorePath: fixture.caCertificatePath
            ),
            securityProfile: .bcp195RFC8996
        )

        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .client)

        XCTAssertNotNil(prepared.tlsContext)
        XCTAssertEqual(prepared.tlsContext?.serverName, "localhost")
        XCTAssertEqual(prepared.tlsContext?.hasLocalIdentity, true)
        XCTAssertEqual(prepared.tlsContext?.trustedCertificateCount, 1)
        XCTAssertEqual(prepared.tlsContext?.securityProfile, .bcp195RFC8996)
        XCTAssertEqual(prepared.tlsContext?.minimumProtocolVersionName, "TLSv1.2")
        XCTAssertEqual(prepared.tlsContext?.peerAuthenticationRequired, true)
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS options are unavailable on this platform.")
        #endif
    }

    func testTLSOptionsApplyIdentityFromPrivateKeyData() throws {
        #if canImport(Network) && canImport(Security) && os(macOS)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let privateKeyData = try Data(contentsOf: URL(fileURLWithPath: fixture.serverPrivateKeyPath))
        let tls = DicomTLSConfiguration(
            mode: .enabled,
            material: DicomTLSMaterial(
                certificatePath: fixture.serverCertificatePath,
                privateKeyData: privateKeyData
            )
        )

        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .server)

        XCTAssertEqual(prepared.tlsContext?.hasLocalIdentity, true)
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS identity tests run only on macOS.")
        #endif
    }

    func testTLSMaterialCodableDoesNotPersistPrivateKeyData() throws {
        let privateKeyData = Data("private-key-secret".utf8)
        let material = DicomTLSMaterial(
            certificatePath: "/tmp/certificate.pem",
            privateKeyData: privateKeyData,
            trustStorePath: "/tmp/trust.pem"
        )

        let encoded = try JSONEncoder().encode(material)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let decoded = try JSONDecoder().decode(DicomTLSMaterial.self, from: encoded)

        XCTAssertFalse(encodedText.contains("privateKeyData"))
        XCTAssertFalse(encodedText.contains(privateKeyData.base64EncodedString()))
        XCTAssertNil(decoded.privateKeyData)
        XCTAssertEqual(decoded.certificatePath, material.certificatePath)
        XCTAssertEqual(decoded.trustStorePath, material.trustStorePath)
    }

    func testTLSOptionsRejectMissingCertificate() throws {
        #if canImport(Network) && canImport(Security)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let tls = DicomTLSConfiguration(
            mode: .enabled,
            material: DicomTLSMaterial(privateKeyPath: fixture.serverPrivateKeyPath)
        )

        XCTAssertThrowsError(try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .client)) { error in
            guard case .tlsConfigurationInvalid(let reason) = error as? DicomNetworkError else {
                return XCTFail("Expected TLS configuration error, got \(error)")
            }
            XCTAssertTrue(reason.contains("certificate"))
        }
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS options are unavailable on this platform.")
        #endif
    }

    func testTLSOptionsRejectMissingPrivateKey() throws {
        #if canImport(Network) && canImport(Security)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let tls = DicomTLSConfiguration(
            mode: .enabled,
            material: DicomTLSMaterial(certificatePath: fixture.serverCertificatePath)
        )

        XCTAssertThrowsError(try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .client)) { error in
            guard case .tlsConfigurationInvalid(let reason) = error as? DicomNetworkError else {
                return XCTFail("Expected TLS configuration error, got \(error)")
            }
            XCTAssertTrue(reason.contains("private key"))
        }
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS options are unavailable on this platform.")
        #endif
    }

    func testTLSOptionsRejectMissingTrustStore() throws {
        #if canImport(Network) && canImport(Security)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let missingTrustStore = fixture.directory.appendingPathComponent("missing_trust.pem").path
        let tls = DicomTLSConfiguration(
            mode: .enabled,
            material: DicomTLSMaterial(trustStorePath: missingTrustStore)
        )

        XCTAssertThrowsError(try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .client)) { error in
            guard case .tlsConfigurationInvalid(let reason) = error as? DicomNetworkError else {
                return XCTFail("Expected TLS configuration error, got \(error)")
            }
            XCTAssertTrue(reason.contains("trust store"))
        }
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS options are unavailable on this platform.")
        #endif
    }

    func testTLSOptionsKeepIdentityMaterialInMemory() throws {
        #if canImport(Network) && canImport(Security) && os(macOS)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let existingDirectories = try Set(FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("DicomDecoderTLS-") })
        let tls = DicomTLSConfiguration(
            mode: .enabled,
            material: DicomTLSMaterial(
                certificatePath: fixture.serverCertificatePath,
                privateKeyPath: fixture.serverPrivateKeyPath
            )
        )

        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .server)

        try withExtendedLifetime(prepared) {
            let currentDirectories = try Set(FileManager.default.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix("DicomDecoderTLS-") })
            XCTAssertEqual(currentDirectories, existingDirectories)
        }
        #else
        throw skipNetworkSecurityTLS("In-memory TLS identity tests run only on macOS Security.")
        #endif
    }

    func testTLSOptionsRejectMismatchedCertificateAndPrivateKey() throws {
        #if canImport(Network) && canImport(Security) && os(macOS)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let tls = DicomTLSConfiguration(
            mode: .enabled,
            material: DicomTLSMaterial(
                certificatePath: fixture.wrongCACertificatePath,
                privateKeyPath: fixture.serverPrivateKeyPath
            )
        )

        XCTAssertThrowsError(try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .server)) { error in
            guard case DicomNetworkError.tlsConfigurationInvalid(let reason) = error else {
                return XCTFail("Expected TLS configuration error, got \(error)")
            }
            XCTAssertTrue(reason.contains("does not match"))
        }
        #else
        throw skipNetworkSecurityTLS("TLS identity matching tests run only on macOS Security.")
        #endif
    }

    func testTLSHandshakeSucceedsWithTrustedPeer() throws {
        #if canImport(Network) && canImport(Security) && os(macOS)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let outcome = try performTLSHandshake(
            serverTLS: DicomTLSConfiguration(
                mode: .enabled,
                material: DicomTLSMaterial(
                    certificatePath: fixture.serverCertificatePath,
                    privateKeyPath: fixture.serverPrivateKeyPath
                ),
                securityProfile: .bcp195RFC8996
            ),
            clientTLS: DicomTLSConfiguration(
                mode: .enabled,
                serverName: "localhost",
                material: DicomTLSMaterial(trustStorePath: fixture.caCertificatePath),
                securityProfile: .bcp195RFC8996
            )
        )

        XCTAssertEqual(outcome, .ready)
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS handshake tests run only on macOS.")
        #endif
    }

    func testTLSHandshakeRejectsUntrustedPeer() throws {
        #if canImport(Network) && canImport(Security) && os(macOS)
        let fixture = try DicomTLSTestMaterial.write()
        defer { fixture.remove() }
        let outcome = try performTLSHandshake(
            serverTLS: DicomTLSConfiguration(
                mode: .enabled,
                material: DicomTLSMaterial(
                    certificatePath: fixture.serverCertificatePath,
                    privateKeyPath: fixture.serverPrivateKeyPath
                ),
                securityProfile: .bcp195RFC8996
            ),
            clientTLS: DicomTLSConfiguration(
                mode: .enabled,
                serverName: "localhost",
                material: DicomTLSMaterial(trustStorePath: fixture.wrongCACertificatePath),
                securityProfile: .bcp195RFC8996
            )
        )

        XCTAssertNotEqual(outcome, .ready)
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS handshake tests run only on macOS.")
        #endif
    }

    func testCancelledOperationHandleRejectsBeforeOpeningTransport() throws {
        let handle = DicomDIMSEOperationHandle()
        handle.cancel()
        var transportFactoryCalls = 0
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(),
            operationHandle: handle,
            transportFactory: {
                transportFactoryCalls += 1
                return DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
                    DicomNetworkUID.verificationSOPClass
                ])
            }
        )

        XCTAssertThrowsError(try service.verify()) { error in
            XCTAssertEqual(error as? DicomNetworkError, .operationCancelled("C-ECHO"))
        }
        XCTAssertEqual(transportFactoryCalls, 0)
    }

    func testFindSCUSendsCancelRequestWhenOperationHandleCancels() throws {
        let handle = DicomDIMSEOperationHandle()
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.studyRootQueryRetrieveFind],
            cancelBeforeReturningCommandFields: [DicomDIMSECommandField.cFindRSP]
        )
        transport.cancelHandler = { handle.cancel() }
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(),
            operationHandle: handle,
            transportFactory: { transport }
        )

        XCTAssertThrowsError(try service.find(identifier: retrieveIdentifier())) { error in
            XCTAssertEqual(error as? DicomNetworkError, .operationCancelled("C-FIND"))
        }

        let cancel = transport.writtenCommands.first { $0.commandField == DicomDIMSECommandField.cCancelRQ }
        XCTAssertEqual(cancel?.messageIDBeingRespondedTo, 1)
        XCTAssertGreaterThanOrEqual(transport.closeCount, 1)
    }

    func testGetSCUSendsCancelRequestWhenOperationHandleCancels() throws {
        let handle = DicomDIMSEOperationHandle()
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.studyRootQueryRetrieveGet,
                DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
            ],
            cancelBeforeReturningCommandFields: [DicomDIMSECommandField.cStoreRQ]
        )
        transport.cancelHandler = { handle.cancel() }
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(),
            operationHandle: handle,
            transportFactory: { transport }
        )

        XCTAssertThrowsError(try service.get(identifier: retrieveIdentifier())) { error in
            XCTAssertEqual(error as? DicomNetworkError, .operationCancelled("C-GET"))
        }

        let cancel = transport.writtenCommands.first { $0.commandField == DicomDIMSECommandField.cCancelRQ }
        XCTAssertEqual(cancel?.messageIDBeingRespondedTo, 1)
        XCTAssertGreaterThanOrEqual(transport.closeCount, 1)
    }

    func testMoveSCUSendsCancelRequestWhenOperationHandleCancels() throws {
        let handle = DicomDIMSEOperationHandle()
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [DicomNetworkUID.studyRootQueryRetrieveMove],
            cancelBeforeReturningCommandFields: [DicomDIMSECommandField.cMoveRSP]
        )
        transport.cancelHandler = { handle.cancel() }
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(),
            operationHandle: handle,
            transportFactory: { transport }
        )

        XCTAssertThrowsError(try service.move(identifier: retrieveIdentifier(), moveDestinationAETitle: "VIEWER")) { error in
            XCTAssertEqual(error as? DicomNetworkError, .operationCancelled("C-MOVE"))
        }

        let cancel = transport.writtenCommands.first { $0.commandField == DicomDIMSECommandField.cCancelRQ }
        XCTAssertEqual(cancel?.messageIDBeingRespondedTo, 1)
        XCTAssertGreaterThanOrEqual(transport.closeCount, 1)
    }

    func testStoreSCUClosesTransportWithoutCancelRequestWhenOperationHandleCancels() throws {
        let handle = DicomDIMSEOperationHandle()
        let storageUID = DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        let transport = DIMSEScriptedTransport(
            supportedAbstractSyntaxUIDs: [storageUID],
            cancelBeforeReturningCommandFields: [DicomDIMSECommandField.cStoreRSP]
        )
        transport.cancelHandler = { handle.cancel() }
        let service = DicomDIMSEServiceSCU(
            configuration: makeConfiguration(),
            operationHandle: handle,
            transportFactory: { transport }
        )

        XCTAssertThrowsError(try service.store(dataSet: storageDataSet())) { error in
            XCTAssertEqual(error as? DicomNetworkError, .operationCancelled("C-STORE"))
        }

        XCTAssertFalse(transport.writtenCommands.contains { $0.commandField == DicomDIMSECommandField.cCancelRQ })
        XCTAssertGreaterThanOrEqual(transport.closeCount, 1)
    }

    func testAssociationPoolReusesOpenAssociationAndHonorsCapacity() throws {
        let configuration = makeConfiguration()
        let poolLog = DicomInMemoryAssociationPoolLog()
        let factory = ScriptedTransportFactory(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.verificationSOPClass,
            DicomNetworkUID.studyRootQueryRetrieveFind
        ])
        let pool = DicomDIMSEAssociationPool(policy: DicomDIMSEAssociationPoolPolicy(
            maximumIdleServicesPerKey: 1,
            idleTimeout: 60
        ), logger: poolLog, transportFactory: factory.makeTransport)

        _ = try pool.service(for: configuration).verify()
        _ = try pool.service(for: configuration).verify()

        let verificationTransport = try XCTUnwrap(factory.transports.first)
        XCTAssertEqual(verificationTransport.associationRequests.count, 1)
        XCTAssertEqual(verificationTransport.writtenCommands.map(\.commandField), [
            DicomDIMSECommandField.cEchoRQ,
            DicomDIMSECommandField.cEchoRQ
        ])
        XCTAssertEqual(verificationTransport.releaseRequestCount, 0)

        let query = DicomDataSet(elements: [element(0x0008_0052, .CS, "STUDY")])
        _ = try pool.service(for: configuration).find(identifier: query)

        XCTAssertEqual(factory.transports.count, 2)
        XCTAssertEqual(pool.idleCount(for: configuration), 1)
        XCTAssertGreaterThanOrEqual(verificationTransport.closeCount, 1)
        XCTAssertEqual(verificationTransport.releaseRequestCount, 1)
        XCTAssertEqual(poolLog.events.map(\.kind), [
            .created,
            .recycled,
            .reused,
            .recycled,
            .created,
            .evicted,
            .recycled
        ])
    }

    func test_getRetrieve_whenQueuedTwice_opensFreshAssociation() throws {
        let configuration = makeConfiguration()
        let poolLog = DicomInMemoryAssociationPoolLog()
        let factory = ScriptedTransportFactory(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveGet,
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
        ])
        let pool = DicomDIMSEAssociationPool(policy: DicomDIMSEAssociationPoolPolicy(
            maximumIdleServicesPerKey: 2,
            idleTimeout: 60
        ), logger: poolLog, transportFactory: factory.makeTransport)

        _ = try pool.service(for: configuration).get(identifier: retrieveIdentifier())
        _ = try pool.service(for: configuration).get(identifier: retrieveIdentifier())

        XCTAssertEqual(factory.transports.count, 2)
        XCTAssertEqual(pool.idleCount(for: configuration), 0)
        XCTAssertFalse(poolLog.events.contains { $0.kind == .recycled })
        XCTAssertFalse(poolLog.events.contains { $0.kind == .reused })
        // Issue #2774: each finished retrieve ends with A-RELEASE, not a dropped connection.
        XCTAssertTrue(factory.transports.allSatisfy { $0.releaseRequestCount == 1 && $0.closeCount >= 1 })
        XCTAssertEqual(poolLog.events.filter { $0.reason == "operationComplete" }.count, 2)
    }

    func test_release_after64NonResponsePDUs_timesOutWithoutReadingFurther() throws {
        for pdu: DicomPDU in [.pData([]), .releaseRequest] {
            let transport = RecordingTransport(responses:
                try (Array(repeating: pdu, count: 64) + [.releaseResponse]).map(DicomPDUCodec.encode)
            )
            let service = DicomDIMSEServiceSCU(configuration: makeConfiguration())
            var released = false

            XCTAssertThrowsError(try service.release(operation: .verification, using: transport, progress: {
                if case .released = $0 { released = true }
            })) { error in
                XCTAssertEqual(error as? DicomNetworkError, .networkTimeout("releasing association"))
            }

            XCTAssertEqual(transport.readCount, 64)
            XCTAssertFalse(released)
            let expected: [DicomPDU] = [.releaseRequest]
                + Array(repeating: .releaseResponse, count: pdu == .releaseRequest ? 64 : 0)
            XCTAssertEqual(try transport.writtenPDUs.map(DicomPDUCodec.decode), expected)
        }
    }

    func test_release_when64thPDUIsResponse_completesAfterHandlingEarlierPDUs() throws {
        let pending: [DicomPDU] = (0..<63).map { $0.isMultiple(of: 2) ? .pData([]) : .releaseRequest }
        let transport = RecordingTransport(responses: try (pending + [.releaseResponse]).map(DicomPDUCodec.encode))
        let service = DicomDIMSEServiceSCU(configuration: makeConfiguration())
        var released = false

        try service.release(operation: .verification, using: transport, progress: {
            if case .released = $0 { released = true }
        })

        XCTAssertEqual(transport.readCount, 64)
        XCTAssertTrue(released)
        XCTAssertEqual(try transport.writtenPDUs.map(DicomPDUCodec.decode),
                       [.releaseRequest] + Array(repeating: .releaseResponse, count: 31))
    }

    func test_release_whenPeerAbortsOrSendsUnsupportedPDU_preservesTheError() throws {
        let abort = DicomAbort(source: .serviceUser, reason: .reasonNotSpecified)
        let rejection = DicomAssociationReject(result: .rejectedTransient, source: .serviceProviderACSE, reason: .noReason)
        let cases: [(DicomPDU, DicomNetworkError)] = [
            (.abort(abort), .associationAborted(abort)),
            (.associationReject(rejection), .unsupportedPDU(.associationReject))
        ]
        for (pdu, expected) in cases {
            let transport = RecordingTransport(responses: [try DicomPDUCodec.encode(pdu)])
            let service = DicomDIMSEServiceSCU(configuration: makeConfiguration())
            XCTAssertThrowsError(try service.release(operation: .verification, using: transport, progress: nil)) { error in
                XCTAssertEqual(error as? DicomNetworkError, expected)
            }
            XCTAssertEqual(transport.readCount, 1)
        }
    }

    func test_nonPooledRetrieve_releaseFailurePreservesTheFinalResultAndClosesTransport() throws {
        for useGet in [true, false] {
            let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.studyRootQueryRetrieveGet, DicomNetworkUID.studyRootQueryRetrieveMove,
                DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
            ])
            transport.acknowledgesRelease = false
            let service = DicomDIMSEServiceSCU(configuration: makeConfiguration())
            if useGet {
                let result = try service.get(identifier: retrieveIdentifier(), using: transport)
                XCTAssertEqual(result.operation.status, 0)
                XCTAssertEqual(result.retrievedInstances.count, 1)
            } else {
                let result = try service.move(identifier: retrieveIdentifier(), moveDestinationAETitle: "ISIS",
                                              using: transport)
                XCTAssertEqual(result.status, 0)
                XCTAssertEqual(result.completedSuboperations, 2)
            }
            XCTAssertEqual(transport.releaseRequestCount, 1, "deferred cleanup must not repeat the failed release")
            XCTAssertFalse(transport.isOpen)
        }
    }

    func test_retrieveRelease_deadlineInterruptsBothTricklingAndBlockedReads() throws {
        for trickles in [true, false] {
            var configuration = makeConfiguration()
            configuration.releaseTimeout = 0.08
            let transport = ReleaseStallingTransport(
                supportedAbstractSyntaxUIDs: [DicomNetworkUID.studyRootQueryRetrieveGet,
                                              DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
                readDelay: trickles ? 0.03 : 2, returnsPData: trickles
            )
            let pool = DicomDIMSEAssociationPool(transportFactory: { _ in transport })
            var completed = false
            let start = Date()
            let result = try pool.service(for: configuration).get(identifier: retrieveIdentifier(), progress: {
                if case .completed = $0 { completed = true }
            })
            XCTAssertLessThan(Date().timeIntervalSince(start), 0.7, "one deadline covers every release read")
            XCTAssertFalse(transport.isOpen)
            XCTAssertEqual(result.operation.status, 0)
            XCTAssertEqual(result.retrievedInstances.count, 1)
            XCTAssertTrue(completed)
            XCTAssertEqual(transport.releaseRequestCount, 1)
        }
    }

    func test_checkout_doesNotWaitForAnExpiredAssociationsRelease() throws {
        var configuration = makeConfiguration()
        configuration.releaseTimeout = 2
        let expired = ReleaseStallingTransport(supportedAbstractSyntaxUIDs: [DicomNetworkUID.verificationSOPClass],
                                               readDelay: 1, returnsPData: false)
        defer { expired.close() }
        let pool = DicomDIMSEAssociationPool(policy: .init(idleTimeout: 60), transportFactory: { _ in expired })
        _ = try pool.service(for: configuration).verify()
        let request = try XCTUnwrap(expired.associationRequests.first)
        let start = Date()
        let fresh = try pool.checkoutSession(for: configuration, request: request, transportFactory: {
            DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [DicomNetworkUID.verificationSOPClass])
        }, now: Date().addingTimeInterval(120))
        defer { pool.discardSession(fresh, error: nil) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertTrue(fresh.isOpen)
        XCTAssertEqual(expired.releaseStarted.wait(timeout: .now() + 1), .success)
    }

    func test_retrieveCompletion_waitsForReleaseResponseAfterUnreadPDUs() throws {
        for useGet in [true, false] {
            let configuration = makeConfiguration()
            let poolLog = DicomInMemoryAssociationPoolLog()
            let factory = ScriptedTransportFactory(supportedAbstractSyntaxUIDs: [
                DicomNetworkUID.studyRootQueryRetrieveGet, DicomNetworkUID.studyRootQueryRetrieveMove,
                DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
            ], trailingReleasePDUs: 3)
            let pool = DicomDIMSEAssociationPool(logger: poolLog, transportFactory: factory.makeTransport)
            var completed = false
            let progress: (DicomDIMSEProgress) -> Void = { event in
                guard case .completed = event else { return }
                completed = true
                XCTAssertEqual(factory.transports.first?.releaseResponseReadCount, 1)
                XCTAssertEqual(poolLog.events.last?.reason, "operationComplete")
            }
            if useGet {
                _ = try pool.service(for: configuration).get(identifier: retrieveIdentifier(), progress: progress)
            } else {
                _ = try pool.service(for: configuration).move(identifier: retrieveIdentifier(),
                                                              moveDestinationAETitle: "ISIS", progress: progress)
            }
            XCTAssertTrue(completed)
            XCTAssertEqual(factory.transports.first?.releaseRequestCount, 1)
            XCTAssertEqual(pool.idleCount(for: configuration), 0)
        }
    }

    func test_retrieveRelease_withoutAcknowledgementOrWithTooManyPDUs_preservesTheFinalResultWithoutRetry() throws {
        for useGet in [true, false] {
            for trailingPDUs in [0, 65] {
                let configuration = makeConfiguration(retryPolicy: .init(maxAttempts: 3))
                let poolLog = DicomInMemoryAssociationPoolLog()
                let factory = ScriptedTransportFactory(supportedAbstractSyntaxUIDs: [
                    DicomNetworkUID.studyRootQueryRetrieveGet, DicomNetworkUID.studyRootQueryRetrieveMove,
                    DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
                ], trailingReleasePDUs: trailingPDUs, acknowledgesRelease: false)
                let pool = DicomDIMSEAssociationPool(logger: poolLog, transportFactory: factory.makeTransport)
                var completed = false
                let progress: (DicomDIMSEProgress) -> Void = { event in
                    guard case .completed = event else { return }
                    completed = true
                    XCTAssertFalse(factory.transports.first?.isOpen ?? true, "cleanup precedes completion")
                }
                if useGet {
                    let result = try pool.service(for: configuration).get(identifier: retrieveIdentifier(), progress: progress)
                    XCTAssertEqual(result.operation.status, 0)
                    XCTAssertEqual(result.retrievedInstances.count, 1)
                } else {
                    let result = try pool.service(for: configuration).move(identifier: retrieveIdentifier(),
                                                                          moveDestinationAETitle: "ISIS", progress: progress)
                    XCTAssertEqual(result.status, 0)
                    XCTAssertEqual(result.completedSuboperations, 2)
                }
                XCTAssertTrue(completed)
                XCTAssertFalse(poolLog.events.contains { $0.reason == "operationComplete" })
                XCTAssertEqual(factory.transports.count, 1, "a completed retrieve must not request the images again")
                XCTAssertEqual(factory.transports.first?.releaseRequestCount, 1)
                XCTAssertGreaterThanOrEqual(factory.transports.first?.closeCount ?? 0, 1)
                XCTAssertEqual(pool.idleCount(for: configuration), 0)
            }
        }
    }

    func test_moveRetrieve_whenQueuedTwice_opensFreshAssociation() throws {
        let configuration = makeConfiguration()
        let poolLog = DicomInMemoryAssociationPoolLog()
        let factory = ScriptedTransportFactory(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.studyRootQueryRetrieveMove
        ])
        let pool = DicomDIMSEAssociationPool(policy: DicomDIMSEAssociationPoolPolicy(
            maximumIdleServicesPerKey: 2,
            idleTimeout: 60
        ), logger: poolLog, transportFactory: factory.makeTransport)

        _ = try pool.service(for: configuration).move(identifier: retrieveIdentifier(),
                                                      moveDestinationAETitle: "ISIS")
        _ = try pool.service(for: configuration).move(identifier: retrieveIdentifier(),
                                                      moveDestinationAETitle: "ISIS")

        XCTAssertEqual(factory.transports.count, 2)
        XCTAssertEqual(pool.idleCount(for: configuration), 0)
        XCTAssertFalse(poolLog.events.contains { $0.kind == .recycled })
        XCTAssertFalse(poolLog.events.contains { $0.kind == .reused })
        // Issue #2774: each finished retrieve ends with A-RELEASE, not a dropped connection.
        XCTAssertTrue(factory.transports.allSatisfy { $0.releaseRequestCount == 1 && $0.closeCount >= 1 })
        XCTAssertEqual(poolLog.events.filter { $0.reason == "operationComplete" }.count, 2)
    }

    /// Issue #2774: an idle association is released by the pool itself once `idleTimeout` passes, before a
    /// peer that drops inactive associations gets to it.
    func test_idleAssociation_isReleasedWhenItsIdleTimeoutPasses() throws {
        let configuration = makeConfiguration()
        let poolLog = DicomInMemoryAssociationPoolLog()
        let factory = ScriptedTransportFactory(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.verificationSOPClass
        ])
        let pool = DicomDIMSEAssociationPool(policy: DicomDIMSEAssociationPoolPolicy(
            maximumIdleServicesPerKey: 2,
            idleTimeout: 0.2
        ), logger: poolLog, transportFactory: factory.makeTransport)

        _ = try pool.service(for: configuration).verify()
        let transport = try XCTUnwrap(factory.transports.first)
        XCTAssertEqual(transport.releaseRequestCount, 0, "kept for reuse while it is fresh")

        let deadline = Date().addingTimeInterval(5)
        while transport.isOpen, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(poolLog.events.contains { $0.kind == .closedIdle })
        XCTAssertEqual(transport.releaseRequestCount, 1)
        XCTAssertFalse(transport.isOpen)

        _ = try pool.service(for: configuration).verify()
        XCTAssertEqual(factory.transports.count, 2, "a later operation opens a fresh association")
    }

    func testAssociationPoolKeySeparatesNodeTLSIdentityAndDIMSEConfiguration() throws {
        let tls = DicomTLSConfiguration(
            mode: .enabled,
            serverName: "archive.example.com",
            material: DicomTLSMaterial(
                certificatePath: "/tmp/client.pem",
                privateKeyPath: "/tmp/client.key",
                trustStorePath: "/tmp/trust.pem",
                trustedCertificatePaths: ["/tmp/root.pem"]
            ),
            securityProfile: .bcp195RFC8996
        )
        let identity = DicomUserIdentity.usernameAndPasscode("operator", passcode: "secret-passcode")
        let base = makeConfiguration(
            tls: tls,
            userIdentity: identity,
            retryPolicy: DicomNetworkRetryPolicy(maxAttempts: 2, retryDelay: 0.1),
            circuitBreakerPolicy: DicomCircuitBreakerPolicy(failureThreshold: 2, resetInterval: 4),
            bandwidthLimitBytesPerSecond: 1_024
        )
        let baseKey = DicomDIMSEAssociationPool.key(for: base)

        XCTAssertNotEqual(baseKey, DicomDIMSEAssociationPool.key(for: makeConfiguration(host: "192.0.2.10", tls: tls, userIdentity: identity)))
        XCTAssertNotEqual(baseKey, DicomDIMSEAssociationPool.key(for: makeConfiguration(calledAETitle: "PACS2", tls: tls, userIdentity: identity)))
        XCTAssertNotEqual(baseKey, DicomDIMSEAssociationPool.key(for: makeConfiguration(callingAETitle: "VIEWER2", tls: tls, userIdentity: identity)))
        XCTAssertNotEqual(baseKey, DicomDIMSEAssociationPool.key(for: makeConfiguration(timeout: 30, tls: tls, userIdentity: identity)))
        XCTAssertNotEqual(baseKey, DicomDIMSEAssociationPool.key(for: makeConfiguration(maximumPDULength: 32_768, tls: tls, userIdentity: identity)))
        XCTAssertNotEqual(baseKey, DicomDIMSEAssociationPool.key(for: makeConfiguration(tls: .disabled, userIdentity: identity)))
        XCTAssertNotEqual(baseKey, DicomDIMSEAssociationPool.key(for: makeConfiguration(tls: tls, userIdentity: .username("operator"))))
        XCTAssertNotEqual(baseKey, DicomDIMSEAssociationPool.key(for: makeConfiguration(tls: tls, userIdentity: identity, transferSyntaxes: [.implicitVRLittleEndian])))
        XCTAssertNotEqual(baseKey, DicomDIMSEAssociationPool.key(for: makeConfiguration(tls: tls, userIdentity: identity, bandwidthLimitBytesPerSecond: 2_048)))
        XCTAssertFalse(String(describing: baseKey).contains("secret-passcode"))
        XCTAssertEqual(baseKey.userIdentity?.secondaryFieldLength, "secret-passcode".utf8.count)
    }

    func testAssociationPoolClosesExpiredAndExplicitIdleServices() throws {
        let configuration = makeConfiguration()
        let poolLog = DicomInMemoryAssociationPoolLog()
        let factory = ScriptedTransportFactory(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.verificationSOPClass
        ])
        let pool = DicomDIMSEAssociationPool(policy: DicomDIMSEAssociationPoolPolicy(
            maximumIdleServicesPerKey: 2,
            idleTimeout: 1
        ), logger: poolLog, transportFactory: factory.makeTransport)
        let now = Date()

        _ = try pool.service(for: configuration).verify()
        XCTAssertEqual(pool.closeExpiredIdle(now: now.addingTimeInterval(2)), 1)
        XCTAssertEqual(pool.idleCount(for: configuration, now: now.addingTimeInterval(2)), 0)

        _ = try pool.service(for: configuration).verify()
        XCTAssertEqual(pool.closeAll(now: now.addingTimeInterval(4)), 1)
        XCTAssertEqual(poolLog.events.map(\.kind).filter { $0 == .closedIdle }.count, 1)
        XCTAssertEqual(poolLog.events.map(\.kind).filter { $0 == .closedExplicit }.count, 1)
        XCTAssertTrue(factory.transports.allSatisfy { $0.closeCount >= 1 })
        XCTAssertTrue(factory.transports.allSatisfy { $0.releaseRequestCount == 1 })
    }

    func testAssociationPoolDiscardLogsFailedAssociationEvictionWithoutPayloadData() throws {
        let configuration = makeConfiguration()
        let poolLog = DicomInMemoryAssociationPoolLog()
        let pool = DicomDIMSEAssociationPool(
            logger: poolLog,
            transportFactory: { _ in ClosedAssociationTransport() }
        )

        XCTAssertThrowsError(try pool.service(for: configuration).verify())

        let event = try XCTUnwrap(poolLog.events.last)
        XCTAssertEqual(event.kind, .failedAssociationEvicted)
        XCTAssertEqual(event.host, configuration.host)
        XCTAssertEqual(event.calledAETitle, configuration.calledAETitle)
        XCTAssertFalse(String(describing: event).contains("DOE"))
    }

    func testAssociationPoolDiscardsDeadSessionBeforeCheckout() throws {
        let configuration = makeConfiguration()
        let poolLog = DicomInMemoryAssociationPoolLog()
        let factory = ScriptedTransportFactory(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.verificationSOPClass
        ])
        let pool = DicomDIMSEAssociationPool(logger: poolLog, transportFactory: factory.makeTransport)

        _ = try pool.service(for: configuration).verify()
        let firstTransport = try XCTUnwrap(factory.transports.first)
        firstTransport.close()
        _ = try pool.service(for: configuration).verify()

        XCTAssertEqual(factory.transports.count, 2)
        XCTAssertEqual(factory.transports[1].associationRequests.count, 1)
        XCTAssertTrue(poolLog.events.contains {
            $0.kind == .failedAssociationEvicted && $0.reason == "livenessCheck"
        })
    }

    func testAssociationPoolHandlesConcurrentAccess() throws {
        let configuration = makeConfiguration()
        let factory = ScriptedTransportFactory(supportedAbstractSyntaxUIDs: [
            DicomNetworkUID.verificationSOPClass
        ])
        let pool = DicomDIMSEAssociationPool(policy: DicomDIMSEAssociationPoolPolicy(
            maximumIdleServicesPerKey: 4,
            idleTimeout: 60
        ), transportFactory: factory.makeTransport)
        let failures = LockedErrorStore()

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            do {
                _ = try pool.service(for: configuration).verify()
            } catch {
                failures.append(error)
            }
        }

        XCTAssertTrue(failures.errors.isEmpty)
        XCTAssertLessThanOrEqual(pool.idleCount(for: configuration), 4)
        XCTAssertTrue(factory.transports.allSatisfy { $0.associationRequests.count == 1 })
    }

    func testAssociationPoolReusesLiveHorosAssociationWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["DICOM_SWIFT_LIVE_HOROS"] == "1" else {
            throw XCTSkip("Set DICOM_SWIFT_LIVE_HOROS=1 when HOROS is listening on 127.0.0.1:4007.")
        }

        let poolLog = DicomInMemoryAssociationPoolLog()
        let pool = DicomDIMSEAssociationPool(logger: poolLog)
        defer { pool.closeAll() }
        let configuration = DicomDIMSEConnectionConfiguration(
            host: "127.0.0.1",
            port: 4007,
            calledAETitle: "HOROS",
            callingAETitle: "ISIS",
            timeout: 5
        )
        let query = DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.studyInstanceUID.rawValue, .UI, "")
        ])

        _ = try pool.service(for: configuration).find(identifier: query)
        _ = try pool.service(for: configuration).find(identifier: query)

        XCTAssertEqual(poolLog.events.filter { $0.kind == .created }.count, 1)
        XCTAssertEqual(poolLog.events.filter { $0.kind == .reused }.count, 1)
        XCTAssertEqual(pool.idleCount(for: configuration), 1)
    }

    /// Two retrieves queued back to back against one node, which is what the import queue does the
    /// instant a download finishes. Reusing the first retrieve's association leaves unread PDUs on
    /// the wire, and the second retrieve dies on `malformedCommandSet`.
    func test_liveHorosGetRetrieve_whenRunSequentially_doesNotReuseAssociation() throws {
        guard ProcessInfo.processInfo.environment["DICOM_SWIFT_LIVE_HOROS"] == "1" else {
            throw XCTSkip("Set DICOM_SWIFT_LIVE_HOROS=1 when HOROS is listening on 127.0.0.1:4007.")
        }

        let poolLog = DicomInMemoryAssociationPoolLog()
        let pool = DicomDIMSEAssociationPool(logger: poolLog)
        defer { pool.closeAll() }
        let configuration = DicomDIMSEConnectionConfiguration(
            host: "127.0.0.1",
            port: 4007,
            calledAETitle: "HOROS",
            callingAETitle: "ISIS",
            timeout: 15
        )

        let studyQuery = DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.studyInstanceUID.rawValue, .UI, "")
        ])
        let studies = try pool.service(for: configuration).find(identifier: studyQuery)
        let studyUID = try XCTUnwrap(studies.matches.first?.string(for: .studyInstanceUID),
                                     "HOROS has no studies to retrieve.")
        let imageQuery = DicomDataSet(elements: [
            element(0x0008_0052, .CS, "IMAGE"),
            element(DicomTag.studyInstanceUID.rawValue, .UI, studyUID),
            element(DicomTag.seriesInstanceUID.rawValue, .UI, ""),
            element(DicomTag.sopInstanceUID.rawValue, .UI, ""),
            element(DicomTag.sopClassUID.rawValue, .UI, "")
        ])
        let images = try pool.service(for: configuration).find(identifier: imageQuery)
        let storageSOPClassUIDs = Array(Set(images.matches.compactMap {
            $0.string(for: .sopClassUID)
        }.filter { !$0.isEmpty })).sorted()
        XCTAssertFalse(storageSOPClassUIDs.isEmpty, "HOROS returned no storage SOP Classes.")
        let retrieve = DicomDataSet(elements: [
            element(0x0008_0052, .CS, "STUDY"),
            element(DicomTag.studyInstanceUID.rawValue, .UI, studyUID)
        ])

        let first = try pool.service(for: configuration).get(
            identifier: retrieve, storageSOPClassUIDs: storageSOPClassUIDs
        )
        let second = try pool.service(for: configuration).get(
            identifier: retrieve, storageSOPClassUIDs: storageSOPClassUIDs
        )

        print("HOROS sequential GET: SOP Classes=\(storageSOPClassUIDs), "
              + "statuses=\(first.operation.status),\(second.operation.status), "
              + "instances=\(first.retrievedInstances.count),\(second.retrievedInstances.count)")
        print("HOROS pool events: \(poolLog.events.map(\.kind))")
        XCTAssertGreaterThan(first.retrievedInstances.count, 0)
        XCTAssertEqual(second.retrievedInstances.count, first.retrievedInstances.count)
        XCTAssertEqual(second.operation.status, first.operation.status)
        // One association shared by both C-FINDs plus one per retrieve:
        // the C-FIND's idle entry stays in the pool, the two retrieve associations do not.
        XCTAssertEqual(poolLog.events.filter { $0.kind == .created }.count, 3)
        XCTAssertEqual(poolLog.events.filter { $0.kind == .reused }.count, 1)
    }

    // MARK: - Retrieve associations are never recycled (#1602)

    /// Every assertion above about recycling needs HOROS on the wire, so none of it runs in a gate.
    /// The four tests below are the hermetic twins: they hold the same line with scripted transports.

    func test_recyclingPolicy_refusesRetrievesAndAllowsEveryOtherOperation() {
        XCTAssertFalse(DicomDIMSEOperation.getRetrieve.allowsAssociationRecycling)
        XCTAssertFalse(DicomDIMSEOperation.moveRetrieve.allowsAssociationRecycling)

        for operation in [DicomDIMSEOperation.verification,
                          .query,
                          .modalityWorklist,
                          .store,
                          .mppsCreate,
                          .mppsUpdate,
                          .printManagement] {
            XCTAssertTrue(operation.allowsAssociationRecycling,
                          "\(operation.rawValue) should keep pooling its association.")
        }
    }

    func test_pooledGetRetrieve_whenItSucceeds_isNotHandedBackToThePool() throws {
        let poolLog = DicomInMemoryAssociationPoolLog()
        let pool = DicomDIMSEAssociationPool(logger: poolLog)
        defer { pool.closeAll() }
        let configuration = makeConfiguration()
        var transports: [DIMSEScriptedTransport] = []
        let service = DicomDIMSEServiceSCU(
            configuration: configuration,
            transportFactory: {
                let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
                    DicomNetworkUID.studyRootQueryRetrieveGet,
                    DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
                ])
                transports.append(transport)
                return transport
            },
            associationPool: pool
        )

        let result = try service.get(identifier: retrieveIdentifier())

        XCTAssertEqual(result.operation.status, 0)
        XCTAssertEqual(pool.idleCount(for: configuration), 0)
        XCTAssertTrue(poolLog.events.allSatisfy { $0.kind != .recycled })
        XCTAssertEqual(transports.count, 1)
        XCTAssertGreaterThanOrEqual(transports[0].closeCount, 1)
    }

    /// The #1602 symptom itself: a download queued behind another starts the instant the first one
    /// finishes, well inside the pool's idle window. If the spent association came back out, the
    /// second retrieve would read the first one's leftover PDUs.
    func test_pooledGetRetrieve_whenQueuedBehindAnother_negotiatesItsOwnAssociation() throws {
        let poolLog = DicomInMemoryAssociationPoolLog()
        let pool = DicomDIMSEAssociationPool(logger: poolLog)
        defer { pool.closeAll() }
        let configuration = makeConfiguration()
        var transports: [DIMSEScriptedTransport] = []
        let makeService = {
            DicomDIMSEServiceSCU(
                configuration: configuration,
                transportFactory: {
                    let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
                        DicomNetworkUID.studyRootQueryRetrieveGet,
                        DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
                    ])
                    transports.append(transport)
                    return transport
                },
                associationPool: pool
            )
        }

        let first = try makeService().get(identifier: retrieveIdentifier())
        let second = try makeService().get(identifier: retrieveIdentifier())

        XCTAssertEqual(first.operation.status, 0)
        XCTAssertEqual(second.operation.status, 0)
        XCTAssertEqual(second.retrievedInstances.count, first.retrievedInstances.count)
        XCTAssertEqual(transports.count, 2, "The queued retrieve reused a spent association.")
        XCTAssertTrue(transports.allSatisfy { $0.associationRequests.count == 1 })
        XCTAssertEqual(poolLog.events.filter { $0.kind == .created }.count, 2)
        XCTAssertEqual(poolLog.events.filter { $0.kind == .reused }.count, 0)
    }

    func test_pooledMoveRetrieve_whenItSucceeds_isNotHandedBackToThePool() throws {
        let pool = DicomDIMSEAssociationPool()
        defer { pool.closeAll() }
        let configuration = makeConfiguration()
        let service = DicomDIMSEServiceSCU(
            configuration: configuration,
            transportFactory: {
                DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
                    DicomNetworkUID.studyRootQueryRetrieveMove
                ])
            },
            associationPool: pool
        )

        let result = try service.move(identifier: retrieveIdentifier(),
                                      moveDestinationAETitle: "VIEWER")

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(pool.idleCount(for: configuration), 0)
    }

    /// The other half of the fix: refusing to recycle retrieves must not quietly disable pooling for
    /// the operations where reuse is safe and worth having.
    func test_pooledQueryAndVerification_whenTheySucceed_keepReusingOneAssociation() throws {
        let poolLog = DicomInMemoryAssociationPoolLog()
        let pool = DicomDIMSEAssociationPool(logger: poolLog)
        defer { pool.closeAll() }
        let configuration = makeConfiguration()
        var transports: [DIMSEScriptedTransport] = []
        let makeService = {
            DicomDIMSEServiceSCU(
                configuration: configuration,
                transportFactory: {
                    let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: [
                        DicomNetworkUID.verificationSOPClass,
                        DicomNetworkUID.studyRootQueryRetrieveFind
                    ])
                    transports.append(transport)
                    return transport
                },
                associationPool: pool
            )
        }

        _ = try makeService().verify()
        XCTAssertEqual(pool.idleCount(for: configuration), 1)
        _ = try makeService().verify()

        XCTAssertEqual(transports.count, 1, "A second C-ECHO opened a needless association.")
        XCTAssertEqual(poolLog.events.filter { $0.kind == .created }.count, 1)
        XCTAssertEqual(poolLog.events.filter { $0.kind == .reused }.count, 1)
        XCTAssertEqual(poolLog.events.filter { $0.kind == .recycled }.count, 2)
        XCTAssertEqual(pool.idleCount(for: configuration), 1)
    }
}

private func skipNetworkSecurityTLS(_ message: String) -> XCTSkip {
    XCTSkip(DicomTestRuntimePreflight.skipMessage(for: DicomRuntimeStatus(
        capability: .networkSecurityTLS,
        kind: .unsupportedFeature,
        message: message
    )))
}

private func makeService(userIdentity: DicomUserIdentity? = nil) -> DicomDIMSEServiceSCU {
    DicomDIMSEServiceSCU(configuration: makeConfiguration(userIdentity: userIdentity))
}

private func makeConfiguration(host: String = "127.0.0.1",
                               port: UInt16 = 104,
                               calledAETitle: String = "ARCHIVE",
                               callingAETitle: String = "VIEWER",
                               timeout: TimeInterval = 10,
                               maximumPDULength: UInt32 = 16_384,
                               tls: DicomTLSConfiguration = .disabled,
                               userIdentity: DicomUserIdentity? = nil,
                               retryPolicy: DicomNetworkRetryPolicy = .disabled,
                               circuitBreakerPolicy: DicomCircuitBreakerPolicy? = nil,
                               transferSyntaxes: [DicomTransferSyntax] = [.explicitVRLittleEndian],
                               bandwidthLimitBytesPerSecond: Int? = nil) -> DicomDIMSEConnectionConfiguration {
    DicomDIMSEConnectionConfiguration(
        host: host,
        port: port,
        calledAETitle: calledAETitle,
        callingAETitle: callingAETitle,
        timeout: timeout,
        maximumPDULength: maximumPDULength,
        transferSyntaxes: transferSyntaxes,
        tls: tls,
        userIdentity: userIdentity,
        retryPolicy: retryPolicy,
        circuitBreakerPolicy: circuitBreakerPolicy,
        bandwidthLimitBytesPerSecond: bandwidthLimitBytesPerSecond
    )
}

private func retrieveIdentifier() -> DicomDataSet {
    DicomDataSet(elements: [
        element(0x0008_0052, .CS, "SERIES"),
        element(DicomTag.studyInstanceUID.rawValue, .UI, "2.25.100"),
        element(DicomTag.seriesInstanceUID.rawValue, .UI, "2.25.200")
    ])
}

private func storageDataSet() -> DicomDataSet {
    DicomDataSet(elements: [
        element(DicomTag.sopClassUID.rawValue, .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
        element(DicomTag.sopInstanceUID.rawValue, .UI, "2.25.instance"),
        element(DicomTag.patientName.rawValue, .PN, "DOE^JANE"),
        element(DicomTag.studyInstanceUID.rawValue, .UI, "2.25.100"),
        element(DicomTag.seriesInstanceUID.rawValue, .UI, "2.25.200"),
        DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
        element(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
        DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])),
        DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([1])),
        DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
        DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
        DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
        DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
        DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data([0x7F])))
    ])
}

private func writableStorageDataSet(
    sopInstanceUID: String,
    pixelData: Data = Data([0x7F])
) -> DicomDataSet {
    DicomDataSet(elements: [
        element(DicomTag.sopClassUID.rawValue, .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
        element(DicomTag.sopInstanceUID.rawValue, .UI, sopInstanceUID),
        element(DicomTag.patientName.rawValue, .PN, "DOE^JANE"),
        element(DicomTag.studyInstanceUID.rawValue, .UI, "2.25.100"),
        element(DicomTag.seriesInstanceUID.rawValue, .UI, "2.25.200"),
        DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
        element(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
        DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])),
        DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([1])),
        DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
        DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
        DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
        DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
        DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(pixelData))
    ])
}

private func compressedStorageDataSet() -> DicomDataSet {
    DicomDataSet(elements: [
        element(DicomTag.sopClassUID.rawValue, .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
        element(DicomTag.sopInstanceUID.rawValue, .UI, "2.25.2001"),
        element(DicomTag.patientName.rawValue, .PN, "DOE^JPEG2000"),
        element(DicomTag.studyInstanceUID.rawValue, .UI, "2.25.100"),
        element(DicomTag.seriesInstanceUID.rawValue, .UI, "2.25.200"),
        DicomDataElement(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
        element(DicomTag.photometricInterpretation.rawValue, .CS, "MONOCHROME2"),
        DicomDataElement(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([1])),
        DicomDataElement(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([1])),
        DicomDataElement(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
        DicomDataElement(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
        DicomDataElement(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
        DicomDataElement(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
        DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(encapsulatedPixelData()))
    ])
}

private func encapsulatedPixelData() -> Data {
    var data = Data()
    appendEncapsulatedItem(Data(), to: &data)
    appendEncapsulatedItem(Data([0xFF, 0x4F, 0xFF, 0x51]), to: &data)
    data.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0x00, 0x00, 0x00, 0x00])
    return data
}

private func appendEncapsulatedItem(_ itemData: Data, to data: inout Data) {
    data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0])
    let length = UInt32(itemData.count)
    data.append(UInt8(length & 0xFF))
    data.append(UInt8((length >> 8) & 0xFF))
    data.append(UInt8((length >> 16) & 0xFF))
    data.append(UInt8((length >> 24) & 0xFF))
    data.append(itemData)
}

private func worklistDataSet() -> DicomDataSet {
    DicomDataSet(elements: [
        element(DicomTag.patientName.rawValue, .PN, "DOE^JANE"),
        element(DicomTag.patientID.rawValue, .LO, "P-1"),
        element(DicomWorkflowTag.accessionNumber, .SH, "ACC-1"),
        element(DicomWorkflowTag.requestedProcedureID, .SH, "RP-1"),
        element(DicomWorkflowTag.requestedProcedureDescription, .LO, "CT CHEST"),
        DicomDataElement(tag: DicomWorkflowTag.scheduledProcedureStepSequence,
                         vr: .SQ,
                         value: .sequence([
                            DicomSequenceItem(dataSet: DicomDataSet(elements: [
                                element(DicomWorkflowTag.scheduledStationAETitle, .AE, "CTSCANNER"),
                                element(DicomWorkflowTag.modality, .CS, "CT"),
                                element(DicomWorkflowTag.scheduledProcedureStepStartDate, .DA, "20260529"),
                                element(DicomWorkflowTag.scheduledProcedureStepStartTime, .TM, "120000"),
                                element(DicomWorkflowTag.scheduledProcedureStepDescription, .LO, "CHEST ROUTINE"),
                                element(DicomWorkflowTag.scheduledProcedureStepID, .SH, "SPS-1")
                            ]))
                         ]))
    ])
}

/// The film box N-CREATE response, carrying one Referenced Image Box item per
/// image box the printer actually created. `grantedImageBoxCount` is how a
/// printer says "your film box asked for more than this layout holds".
private func printFilmBoxResponseDataSet(imageBoxSOPClassUID: String,
                                         grantedImageBoxCount: Int = 1,
                                         grantedAnnotationBoxCount: Int? = nil) -> DicomDataSet {
    var elements = [
        DicomDataElement(tag: DicomPrintTag.referencedImageBoxSequence,
                         vr: .SQ,
                         value: .sequence((0..<max(0, grantedImageBoxCount)).map { index in
                            DicomSequenceItem(dataSet: DicomDataSet(elements: [
                                element(DicomTag.referencedSOPClassUID.rawValue,
                                        .UI,
                                        imageBoxSOPClassUID),
                                element(DicomTag.referencedSOPInstanceUID.rawValue,
                                        .UI,
                                        "2.25.imagebox.\(index + 1)")
                            ]))
                         }))
    ]
    if let grantedAnnotationBoxCount {
        elements.append(DicomDataElement(
            tag: DicomPrintTag.referencedBasicAnnotationBoxSequence,
            vr: .SQ,
            value: .sequence((0..<max(0, grantedAnnotationBoxCount)).map { index in
                DicomSequenceItem(dataSet: DicomDataSet(elements: [
                    element(DicomTag.referencedSOPClassUID.rawValue,
                            .UI,
                            DicomNetworkUID.basicAnnotationBoxSOPClass),
                    element(DicomTag.referencedSOPInstanceUID.rawValue,
                            .UI,
                            "2.25.annotationbox.\(index + 1)")
                ]))
            })
        ))
    }
    return DicomDataSet(elements: elements)
}

private func printerStatusDataSet(state: String, info: String, name: String = "DRY IMAGER") -> DicomDataSet {
    DicomDataSet(elements: [
        element(DicomPrintTag.printerStatus, .CS, state),
        element(DicomPrintTag.printerStatusInfo, .CS, info),
        element(DicomPrintTag.printerName, .LO, name)
    ])
}

private func element(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
    DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
}

#if canImport(Network) && canImport(Security) && os(macOS)
private enum TLSHandshakeOutcome: Equatable {
    case ready
    case failed
    case timedOut
}

private func performTLSHandshake(
    serverTLS: DicomTLSConfiguration,
    clientTLS: DicomTLSConfiguration
) throws -> TLSHandshakeOutcome {
    let queue = DispatchQueue(label: "DicomDIMSEServiceSCUTests.TLS")
    let serverPrepared = try DicomTLSOptionsFactory.preparedParameters(for: serverTLS, role: .server)
    let clientPrepared = try DicomTLSOptionsFactory.preparedParameters(for: clientTLS, role: .client)
    let listener = try NWListener(using: serverPrepared.parameters, on: .any)
    let listenerSemaphore = DispatchSemaphore(value: 0)
    let connectionSemaphore = DispatchSemaphore(value: 0)
    let listenerError = DicomTestLockedValue<(any Error)?>(nil)
    let outcome = DicomTestLockedValue(TLSHandshakeOutcome.timedOut)
    let acceptedConnections = DicomTestLockedValue<[NWConnection]>([])

    listener.newConnectionHandler = { connection in
        acceptedConnections.withValue { $0.append(connection) }
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                outcome.replace(with: .failed)
                connectionSemaphore.signal()
            }
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in }
    }
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            listenerSemaphore.signal()
        case .failed(let error):
            listenerError.replace(with: error)
            listenerSemaphore.signal()
        default:
            break
        }
    }
    listener.start(queue: queue)

    guard listenerSemaphore.wait(timeout: .now() + 5) == .success else {
        listener.cancel()
        return .timedOut
    }
    if let listenerError = listenerError.value {
        listener.cancel()
        throw listenerError
    }
    guard let port = listener.port else {
        listener.cancel()
        throw DicomNetworkError.networkUnavailable("TLS listener did not publish a port.")
    }

    let connection = NWConnection(host: "localhost", port: port, using: clientPrepared.parameters)
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            outcome.replace(with: .ready)
            connectionSemaphore.signal()
        case .failed:
            outcome.replace(with: .failed)
            connectionSemaphore.signal()
        default:
            break
        }
    }
    connection.start(queue: queue)
    connection.send(content: Data([0x01]), completion: .contentProcessed { error in
        outcome.replace(with: error == nil ? .ready : .failed)
        connectionSemaphore.signal()
    })

    if connectionSemaphore.wait(timeout: .now() + 5) != .success {
        outcome.replace(with: .timedOut)
    }
    connection.cancel()
    acceptedConnections.value.forEach { $0.cancel() }
    listener.cancel()
    _ = serverPrepared.tlsContext
    _ = clientPrepared.tlsContext
    return outcome.value
}
#endif

/// The base transport is accessed only under the lock; close may interrupt a release read from another queue.
private final class ReleaseStallingTransport: DicomCancellableAssociationTransport {
    private let lock = NSLock()
    private let base: DIMSEScriptedTransport
    private let readDelay: TimeInterval
    private let returnsPData: Bool
    private var releasing = false
    private let closed = DispatchSemaphore(value: 0)
    let releaseStarted = DispatchSemaphore(value: 0)

    init(supportedAbstractSyntaxUIDs: Set<String>, readDelay: TimeInterval, returnsPData: Bool) {
        base = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: supportedAbstractSyntaxUIDs)
        self.readDelay = readDelay
        self.returnsPData = returnsPData
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return base.isOpen
    }

    var releaseRequestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return base.releaseRequestCount
    }

    var associationRequests: [DicomAssociationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return base.associationRequests
    }

    func writePDU(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        try base.writePDU(data)
        if case .releaseRequest = try DicomPDUCodec.decode(data) {
            releasing = true
            releaseStarted.signal()
        }
    }

    func readPDU() throws -> Data {
        lock.lock()
        if !releasing {
            defer { lock.unlock() }
            return try base.readPDU()
        }
        lock.unlock()
        _ = closed.wait(timeout: .now() + readDelay)
        guard isOpen else { throw DicomNetworkError.networkUnavailable("Transport closed.") }
        guard returnsPData else { throw DicomNetworkError.networkTimeout("test release read") }
        return try DicomPDUCodec.encode(.pData([]))
    }

    func close() {
        lock.lock()
        base.close()
        lock.unlock()
        closed.signal()
    }
}

private final class ScriptedTransportFactory: @unchecked Sendable {
    private let supportedAbstractSyntaxUIDs: Set<String>
    private let lock = NSLock()
    private var storage: [DIMSEScriptedTransport] = []

    private let trailingReleasePDUs: Int
    private let acknowledgesRelease: Bool

    init(supportedAbstractSyntaxUIDs: Set<String>, trailingReleasePDUs: Int = 0, acknowledgesRelease: Bool = true) {
        self.supportedAbstractSyntaxUIDs = supportedAbstractSyntaxUIDs
        self.trailingReleasePDUs = trailingReleasePDUs
        self.acknowledgesRelease = acknowledgesRelease
    }

    var transports: [DIMSEScriptedTransport] {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }

    func makeTransport(configuration _: DicomDIMSEConnectionConfiguration) -> DicomAssociationTransport {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: supportedAbstractSyntaxUIDs)
        transport.trailingReleasePDUs = trailingReleasePDUs
        transport.acknowledgesRelease = acknowledgesRelease
        lock.lock()
        storage.append(transport)
        lock.unlock()
        return transport
    }
}

private final class ClosedAssociationTransport: DicomCancellableAssociationTransport {
    var isOpen: Bool { false }

    func writePDU(_: Data) throws {
        throw DicomNetworkError.networkUnavailable("Transport is closed.")
    }

    func readPDU() throws -> Data {
        throw DicomNetworkError.networkUnavailable("Transport is closed.")
    }

    func close() {}
}

private final class LockedErrorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var errors: [Error] {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }

    func append(_ error: Error) {
        lock.lock()
        storage.append(error)
        lock.unlock()
    }
}

private final class DIMSEScriptedTransport: DicomCancellableAssociationTransport {
    private let supportedAbstractSyntaxUIDs: Set<String>
    private let preferredTransferSyntaxes: [DicomTransferSyntax]
    private let roleSelectionPolicy: DicomAssociationNegotiator.RoleSelectionResponsePolicy
    private let cancelBeforeReturningCommandFields: Set<UInt16>
    private let retrieveFinalStatus: UInt16
    private let failBeforeRetrieveFinalResponse: Bool
    private let findResponseDataSet: DicomDataSet?
    private let grantedImageBoxCount: Int
    private let grantedAnnotationBoxCount: Int?
    private let printImageBoxSOPClassUID: String
    private let nCreateResponseStatus: UInt16
    private let nSetResponseStatus: UInt16
    private let annotationNSetResponseStatus: UInt16
    private let nActionResponseStatus: UInt16
    private let nGetResponseStatus: UInt16
    private let printerStatusDataSets: [DicomDataSet]
    private let printerEventTypeID: UInt16?
    private let printerEventStatusInfo: String?
    var maximumPDULength: UInt32 = 16_384
    /// The Affected SOP Instance UID of the C-GET's store sub-operation.
    var storeSOPInstanceUID = "2.25.instance"
    var trailingReleasePDUs = 0
    var acknowledgesRelease = true
    private(set) var releaseResponseReadCount = 0
    private var responses: [Data] = []
    private var acceptedContextsByID: [UInt8: DicomAcceptedPresentationContext] = [:]
    private var lastRequestCommand: DicomDIMSECommandSet?
    private var pendingDataSetPayload = Data()
    private var pendingDataSetPresentationContextID: UInt8?
    private var didTriggerCancellation = false
    private var printerStatusDataSetIndex = 0
    private var isClosed = false

    private(set) var associationRequests: [DicomAssociationRequest] = []
    private(set) var associationAccepts: [DicomAssociationAccept] = []
    private(set) var writtenCommands: [DicomDIMSECommandSet] = []
    private(set) var writtenDataSets: [DicomDataSet] = []
    private(set) var writtenDataSetPayloads: [Data] = []
    private(set) var writtenPDataFrames: [(byteCount: Int, pdvs: [DicomPDV])] = []
    private(set) var closeCount = 0
    private(set) var releaseRequestCount = 0
    var cancelHandler: (() -> Void)?
    var isOpen: Bool { !isClosed }

    init(
        supportedAbstractSyntaxUIDs: Set<String>,
        preferredTransferSyntaxes: [DicomTransferSyntax] = [.explicitVRLittleEndian],
        roleSelectionPolicy: DicomAssociationNegotiator.RoleSelectionResponsePolicy = .acceptProposed,
        cancelBeforeReturningCommandFields: Set<UInt16> = [],
        retrieveFinalStatus: UInt16 = 0,
        failBeforeRetrieveFinalResponse: Bool = false,
        findResponseDataSet: DicomDataSet? = nil,
        grantedImageBoxCount: Int = 1,
        grantedAnnotationBoxCount: Int? = nil,
        printImageBoxSOPClassUID: String = DicomNetworkUID.basicGrayscaleImageBoxSOPClass,
        nCreateResponseStatus: UInt16 = 0,
        nSetResponseStatus: UInt16 = 0,
        annotationNSetResponseStatus: UInt16 = 0,
        nActionResponseStatus: UInt16 = 0,
        nGetResponseStatus: UInt16 = 0,
        printerStatusDataSets: [DicomDataSet] = [],
        printerEventTypeID: UInt16? = nil,
        printerEventStatusInfo: String? = nil
    ) {
        self.supportedAbstractSyntaxUIDs = supportedAbstractSyntaxUIDs
        self.preferredTransferSyntaxes = preferredTransferSyntaxes
        self.roleSelectionPolicy = roleSelectionPolicy
        self.cancelBeforeReturningCommandFields = cancelBeforeReturningCommandFields
        self.retrieveFinalStatus = retrieveFinalStatus
        self.failBeforeRetrieveFinalResponse = failBeforeRetrieveFinalResponse
        self.findResponseDataSet = findResponseDataSet
        self.grantedImageBoxCount = grantedImageBoxCount
        self.grantedAnnotationBoxCount = grantedAnnotationBoxCount
        self.printImageBoxSOPClassUID = printImageBoxSOPClassUID
        self.nCreateResponseStatus = nCreateResponseStatus
        self.nSetResponseStatus = nSetResponseStatus
        self.annotationNSetResponseStatus = annotationNSetResponseStatus
        self.nActionResponseStatus = nActionResponseStatus
        self.nGetResponseStatus = nGetResponseStatus
        self.printerStatusDataSets = printerStatusDataSets
        self.printerEventTypeID = printerEventTypeID
        self.printerEventStatusInfo = printerEventStatusInfo
    }

    func writePDU(_ data: Data) throws {
        guard !isClosed else {
            throw DicomNetworkError.networkUnavailable("Transport closed.")
        }
        switch try DicomPDUCodec.decode(data) {
        case .associationRequest(let request):
            associationRequests.append(request)
            let accept = DicomAssociationNegotiator.accept(
                request,
                supportedAbstractSyntaxUIDs: supportedAbstractSyntaxUIDs,
                preferredTransferSyntaxes: preferredTransferSyntaxes,
                roleSelectionPolicy: roleSelectionPolicy,
                maximumPDULength: maximumPDULength,
                supportedSCUAbstractSyntaxUIDs: supportedAbstractSyntaxUIDs
            )
            associationAccepts.append(accept)
            acceptedContextsByID = accept.presentationContexts.reduce(into: [:]) { partial, accepted in
                guard accepted.result == .acceptance,
                      let requested = request.presentationContexts.first(where: { $0.id == accepted.id }),
                      let transferSyntaxUID = accepted.transferSyntaxUID else {
                    return
                }
                partial[accepted.id] = DicomAcceptedPresentationContext(
                    id: accepted.id,
                    abstractSyntaxUID: requested.abstractSyntaxUID,
                    transferSyntaxUID: transferSyntaxUID
                )
            }
            responses.append(try DicomPDUCodec.encode(.associationAccept(accept)))
        case .pData(let pdvs):
            writtenPDataFrames.append((byteCount: data.count, pdvs: pdvs))
            try handlePData(pdvs)
        case .releaseRequest:
            releaseRequestCount += 1
            for _ in 0..<trailingReleasePDUs {
                responses.append(try DicomPDUCodec.encode(.pData([])))
            }
            if acknowledgesRelease { responses.append(try DicomPDUCodec.encode(.releaseResponse)) }
        default:
            break
        }
    }

    func readPDU() throws -> Data {
        if isClosed {
            throw DicomNetworkError.networkUnavailable("Transport closed.")
        }
        guard !responses.isEmpty else {
            throw DicomNetworkError.invalidPDULength(expected: 1, actual: 0)
        }
        let response = responses.removeFirst()
        if failBeforeRetrieveFinalResponse,
           case .pData(let pdvs) = try DicomPDUCodec.decode(response),
           pdvs.contains(where: { pdv in
               guard pdv.isCommand,
                     let command = try? DicomDIMSECommandSet.decode(pdv.data) else { return false }
               return command.commandField == DicomDIMSECommandField.cGetRSP &&
                   command.status.map { $0 != 0xFF00 && $0 != 0xFF01 } == true
           }) {
            throw DicomNetworkError.networkUnavailable("Failed before final C-GET response.")
        }
        if case .releaseResponse = try DicomPDUCodec.decode(response) { releaseResponseReadCount += 1 }
        triggerCancellationIfNeeded(for: response)
        return response
    }

    func close() {
        closeCount += 1
        isClosed = true
    }

    private func handlePData(_ pdvs: [DicomPDV]) throws {
        for pdv in pdvs {
            if pdv.isCommand {
                let command = try DicomDIMSECommandSet.decode(pdv.data)
                writtenCommands.append(command)
                lastRequestCommand = command
                try handleCommand(command, presentationContextID: pdv.presentationContextID)
            } else {
                if let pendingContextID = pendingDataSetPresentationContextID,
                   pendingContextID != pdv.presentationContextID {
                    throw DicomNetworkError.invalidPresentationContextID(pdv.presentationContextID)
                }
                pendingDataSetPresentationContextID = pdv.presentationContextID
                pendingDataSetPayload.append(pdv.data)
                guard pdv.isLastFragment else { continue }

                let payload = pendingDataSetPayload
                pendingDataSetPayload.removeAll(keepingCapacity: true)
                pendingDataSetPresentationContextID = nil
                writtenDataSetPayloads.append(payload)
                let transferSyntax = acceptedContextsByID[pdv.presentationContextID]?.transferSyntax ?? .explicitVRLittleEndian
                let dataSet = try DicomDataSetParser.dataSet(from: payload, transferSyntax: transferSyntax)
                writtenDataSets.append(dataSet)
                try handleDataSetAfterCommand(presentationContextID: pdv.presentationContextID)
            }
        }
    }

    private func handleCommand(_ command: DicomDIMSECommandSet,
                               presentationContextID: UInt8) throws {
        switch command.commandField {
        case DicomDIMSECommandField.cEchoRQ:
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: DicomNetworkUID.verificationSOPClass,
                commandField: DicomDIMSECommandField.cEchoRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: 0
            ), contextID: presentationContextID)
        case DicomDIMSECommandField.cStoreRQ:
            break
        case DicomDIMSECommandField.nDeleteRQ:
            try enqueueCommand(DicomDIMSECommandSet(
                commandField: DicomDIMSECommandField.nDeleteRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: 0
            ), contextID: presentationContextID)
        case DicomDIMSECommandField.nActionRQ:
            if let eventTypeID = printerEventTypeID,
               let printerContextID = acceptedContextsByID.first(where: {
                   $0.value.abstractSyntaxUID == DicomNetworkUID.printerSOPClass
               })?.key {
                let hasDataSet = printerEventStatusInfo != nil
                try enqueueCommand(DicomDIMSECommandSet(
                    affectedSOPClassUID: DicomNetworkUID.printerSOPClass,
                    commandField: DicomDIMSECommandField.nEventReportRQ,
                    messageID: 0x7100,
                    commandDataSetType: hasDataSet
                        ? DicomDIMSECommandDataSetType.hasDataSet
                        : DicomDIMSECommandDataSetType.noDataSet,
                    affectedSOPInstanceUID: DicomNetworkUID.printerSOPInstance,
                    eventTypeID: eventTypeID
                ), contextID: printerContextID)
                if let printerEventStatusInfo {
                    try enqueueDataSet(DicomDataSet(elements: [
                        element(DicomPrintTag.printerStatusInfo, .CS, printerEventStatusInfo)
                    ]), contextID: printerContextID)
                }
            }
            try enqueueCommand(DicomDIMSECommandSet(
                requestedSOPClassUID: command.requestedSOPClassUID,
                commandField: DicomDIMSECommandField.nActionRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: nActionResponseStatus,
                requestedSOPInstanceUID: command.requestedSOPInstanceUID,
                actionTypeID: command.actionTypeID
            ), contextID: presentationContextID)
        case DicomDIMSECommandField.nGetRQ:
            try enqueueCommand(DicomDIMSECommandSet(
                requestedSOPClassUID: command.requestedSOPClassUID,
                commandField: DicomDIMSECommandField.nGetRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: nGetResponseStatus == 0
                    ? DicomDIMSECommandDataSetType.hasDataSet
                    : DicomDIMSECommandDataSetType.noDataSet,
                status: nGetResponseStatus,
                requestedSOPInstanceUID: command.requestedSOPInstanceUID
            ), contextID: presentationContextID)
            if nGetResponseStatus == 0 {
                let dataSet: DicomDataSet
                if printerStatusDataSetIndex < printerStatusDataSets.count {
                    dataSet = printerStatusDataSets[printerStatusDataSetIndex]
                } else {
                    dataSet = printerStatusDataSet(state: "NORMAL", info: "NORMAL")
                }
                printerStatusDataSetIndex += 1
                try enqueueDataSet(dataSet, contextID: presentationContextID)
            }
        default:
            break
        }
    }

    private func handleDataSetAfterCommand(presentationContextID: UInt8) throws {
        guard let command = lastRequestCommand else { return }
        switch command.commandField {
        case DicomDIMSECommandField.cFindRQ:
            let affectedSOPClassUID = command.affectedSOPClassUID ?? DicomNetworkUID.studyRootQueryRetrieveFind
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: affectedSOPClassUID,
                commandField: DicomDIMSECommandField.cFindRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
                status: 0xFF00
            ), contextID: presentationContextID)
            if affectedSOPClassUID == DicomNetworkUID.modalityWorklistInformationModelFind {
                try enqueueDataSet(worklistDataSet(), contextID: presentationContextID)
            } else {
                try enqueueDataSet(findResponseDataSet ?? DicomDataSet(elements: [
                    element(DicomTag.patientName.rawValue, .PN, "DOE^JANE"),
                    element(DicomTag.studyInstanceUID.rawValue, .UI, "2.25.100")
                ]), contextID: presentationContextID)
            }
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: affectedSOPClassUID,
                commandField: DicomDIMSECommandField.cFindRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: 0
            ), contextID: presentationContextID)
        case DicomDIMSECommandField.cMoveRQ:
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: command.affectedSOPClassUID,
                commandField: DicomDIMSECommandField.cMoveRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: 0xFF00,
                remainingSuboperations: 1,
                completedSuboperations: 1,
                failedSuboperations: 0,
                warningSuboperations: 0
            ), contextID: presentationContextID)
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: command.affectedSOPClassUID,
                commandField: DicomDIMSECommandField.cMoveRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: retrieveFinalStatus,
                remainingSuboperations: 0,
                completedSuboperations: 2,
                failedSuboperations: 0,
                warningSuboperations: 0
            ), contextID: presentationContextID)
        case DicomDIMSECommandField.cGetRQ:
            // The store sub-operation rides whichever accepted context carries
            // the storage class — its id shifts as the SCU proposes more
            // query models ahead of the storage classes (issue #1867).
            guard let storeContextID = acceptedContextsByID.first(where: {
                $0.value.abstractSyntaxUID == DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID
            })?.key else {
                throw DicomNetworkError.invalidPresentationContextID(presentationContextID)
            }
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                commandField: DicomDIMSECommandField.cStoreRQ,
                messageID: 33,
                commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
                affectedSOPInstanceUID: storeSOPInstanceUID
            ), contextID: storeContextID)
            try enqueueDataSet(storageDataSet(), contextID: storeContextID)
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: command.affectedSOPClassUID,
                commandField: DicomDIMSECommandField.cGetRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: retrieveFinalStatus,
                remainingSuboperations: 0,
                completedSuboperations: 1,
                failedSuboperations: 0,
                warningSuboperations: 0
            ), contextID: presentationContextID)
        case DicomDIMSECommandField.cStoreRQ:
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: command.affectedSOPClassUID,
                commandField: DicomDIMSECommandField.cStoreRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: 0,
                affectedSOPInstanceUID: command.affectedSOPInstanceUID
            ), contextID: presentationContextID)
        case DicomDIMSECommandField.nCreateRQ:
            let hasFilmBoxDataSet = command.affectedSOPClassUID == DicomNetworkUID.basicFilmBoxSOPClass
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: command.affectedSOPClassUID,
                commandField: DicomDIMSECommandField.nCreateRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: hasFilmBoxDataSet
                    ? DicomDIMSECommandDataSetType.hasDataSet
                    : DicomDIMSECommandDataSetType.noDataSet,
                status: hasFilmBoxDataSet ? nCreateResponseStatus : 0,
                affectedSOPInstanceUID: command.affectedSOPInstanceUID
            ), contextID: presentationContextID)
            if hasFilmBoxDataSet {
                try enqueueDataSet(
                    printFilmBoxResponseDataSet(imageBoxSOPClassUID: printImageBoxSOPClassUID,
                                                grantedImageBoxCount: grantedImageBoxCount,
                                                grantedAnnotationBoxCount: grantedAnnotationBoxCount),
                    contextID: presentationContextID
                )
            }
        case DicomDIMSECommandField.nSetRQ:
            let isAnnotation = command.requestedSOPClassUID == DicomNetworkUID.basicAnnotationBoxSOPClass
            try enqueueCommand(DicomDIMSECommandSet(
                requestedSOPClassUID: command.requestedSOPClassUID,
                commandField: DicomDIMSECommandField.nSetRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: isAnnotation ? annotationNSetResponseStatus : nSetResponseStatus,
                requestedSOPInstanceUID: command.requestedSOPInstanceUID
            ), contextID: presentationContextID)
        case DicomDIMSECommandField.nEventReportRQ:
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: command.affectedSOPClassUID,
                commandField: DicomDIMSECommandField.nEventReportRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: 0,
                affectedSOPInstanceUID: command.affectedSOPInstanceUID,
                eventTypeID: command.eventTypeID
            ), contextID: presentationContextID)
        default:
            break
        }
    }

    private func enqueueCommand(_ command: DicomDIMSECommandSet, contextID: UInt8) throws {
        responses.append(try DicomPDUCodec.encode(.pData([
            DicomPDV(presentationContextID: contextID,
                    isCommand: true,
                    isLastFragment: true,
                    data: try command.encoded())
        ])))
    }

    private func enqueueDataSet(_ dataSet: DicomDataSet, contextID: UInt8) throws {
        responses.append(try DicomPDUCodec.encode(.pData([
            DicomPDV(presentationContextID: contextID,
                    isCommand: false,
                    isLastFragment: true,
                    data: try DicomDataSetWriter.dataSetData(from: dataSet,
                                                             transferSyntax: .explicitVRLittleEndian))
        ])))
    }

    private func triggerCancellationIfNeeded(for response: Data) {
        guard !didTriggerCancellation,
              !cancelBeforeReturningCommandFields.isEmpty,
              case .pData(let pdvs) = try? DicomPDUCodec.decode(response) else {
            return
        }
        for pdv in pdvs where pdv.isCommand {
            guard let command = try? DicomDIMSECommandSet.decode(pdv.data),
                  cancelBeforeReturningCommandFields.contains(command.commandField) else {
                continue
            }
            didTriggerCancellation = true
            cancelHandler?()
            return
        }
    }
}

private final class TimeoutTransport: DicomAssociationTransport {
    func writePDU(_ data: Data) throws {}

    func readPDU() throws -> Data {
        throw DicomNetworkError.networkTimeout("association response")
    }
}

private final class FailingReadTransport: DicomAssociationTransport {
    private let error: Error

    init(error: Error) {
        self.error = error
    }

    func writePDU(_ data: Data) throws {}

    func readPDU() throws -> Data {
        throw error
    }
}

private final class RecordingTransport: DicomAssociationTransport {
    private var responses: [Data]
    private(set) var writtenPDUs: [Data] = []
    private(set) var readCount = 0

    init(responses: [Data]) {
        self.responses = responses
    }

    func writePDU(_ data: Data) throws {
        writtenPDUs.append(data)
    }

    func readPDU() throws -> Data {
        guard !responses.isEmpty else {
            throw DicomNetworkError.invalidPDULength(expected: 1, actual: 0)
        }
        readCount += 1
        return responses.removeFirst()
    }
}

extension DicomDIMSEServiceSCUTests {
    func test_storeBatch_windowFourDispatchesWholeMessagesBeforeReading() throws {
        let peer = DIMSEWindowTransport()
        let service = DicomDIMSEServiceSCU(configuration: .init(host: "fake", port: 1,
            calledAETitle: "SCP", callingAETitle: "SCU", asynchronousOperationsWindow: .init(maximumInvoked: 4)))
        let requests = try (1...4).map { index in
            try DicomStoreRequest(sopClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                sopInstanceUID: "2.25.\(index)", transferSyntax: .explicitVRLittleEndian,
                dataSetData: Data(repeating: UInt8(index), count: 4096))
        }
        let results = try service.store(requests: requests, using: peer)
        XCTAssertEqual(results.count, 4)
        for result in results { XCTAssertEqual(try result.get().status, 0) }
        XCTAssertEqual(peer.maximumOutstanding, 4)
        XCTAssertEqual(peer.completedMessageIDs, [1, 2, 3, 4])
        XCTAssertEqual(peer.responseIDs, [4, 3, 2, 1])
        XCTAssertTrue(peer.pduBodyLengths.allSatisfy { $0 <= 1024 })
    }

    func test_findAndEcho_windowFourDispatchesBeforeReading() throws {
        let peer = DIMSEWindowTransport()
        let service = DicomDIMSEServiceSCU(configuration: .init(host: "fake", port: 1,
            calledAETitle: "SCP", callingAETitle: "SCU", asynchronousOperationsWindow: .init(maximumInvoked: 4)))
        let results = try service.find(identifiers: [DicomDataSet(elements: [])], verifyOnAssociation: true, using: peer)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(peer.maximumOutstanding, 2)
        XCTAssertEqual(peer.fields, [DicomDIMSECommandField.cFindRQ, DicomDIMSECommandField.cEchoRQ])
        XCTAssertEqual(peer.responseIDs, [2, 1])
    }

    func test_commandAndDataset_fragmentWithinPeerMaximum() throws {
        let peer = DIMSEWindowTransport()
        let service = DicomDIMSEServiceSCU(configuration: .init(host: "fake", port: 1,
            calledAETitle: "SCP", callingAETitle: "SCU"))
        let association = try service.openAssociation(for: .store,
            abstractSyntaxUIDs: [DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID],
            using: peer, progress: nil)
        let command = DicomDIMSECommandSet(commandField: DicomDIMSECommandField.cStoreRQ, messageID: 1,
            commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet, errorComment: String(repeating: "A", count: 2048))
        try service.sendCommand(command, presentationContextID: 1, association: association, transport: peer)
        try service.sendDataSetData(Data(repeating: 7, count: 5000), presentationContextID: 1,
                                    association: association, transport: peer)
        XCTAssertGreaterThan(peer.commandFragments, 1)
        XCTAssertGreaterThan(peer.datasetFragments, 1)
        XCTAssertTrue(peer.pduBodyLengths.allSatisfy { $0 <= 1024 })
        XCTAssertEqual(peer.completedMessageIDs, [1])
    }
}

/// Defers responses until read, then deliberately returns them in reverse order.
private final class DIMSEWindowTransport: DicomAssociationTransport {
    var failResponse = false
    var maximumOutstanding = 0
    var completedMessageIDs: [UInt16] = []
    var responseIDs: [UInt16] = []
    var fields: [UInt16] = []
    var pduBodyLengths: [Int] = []
    var commandFragments = 0
    var datasetFragments = 0
    private var responses: [Data] = []
    private var pending: [(UInt8, DicomDIMSECommandSet)] = []
    private var commandBytes = Data()
    private var active: (UInt8, DicomDIMSECommandSet)?

    func writePDU(_ data: Data) throws {
        switch try DicomPDUCodec.decode(data) {
        case .associationRequest(let request):
            let accept = DicomAssociationNegotiator.accept(request,
                supportedAbstractSyntaxUIDs: Set(request.presentationContexts.map(\.abstractSyntaxUID)),
                preferredTransferSyntaxes: [.explicitVRLittleEndian], maximumPDULength: 1024,
                supportedAsynchronousOperationsWindow: .init(maximumInvoked: 4))
            responses.append(try DicomPDUCodec.encode(.associationAccept(accept)))
        case .pData(let pdvs):
            pduBodyLengths.append(data.count - 6)
            for pdv in pdvs {
                if pdv.isCommand {
                    guard active == nil else { throw DicomNetworkError.malformedCommandSet("Interleaved messages") }
                    commandFragments += 1
                    commandBytes.append(pdv.data)
                    if pdv.isLastFragment {
                        let command = try DicomDIMSECommandSet.decode(commandBytes)
                        commandBytes.removeAll()
                        fields.append(command.commandField)
                        active = (pdv.presentationContextID, command)
                        if command.commandDataSetType == DicomDIMSECommandDataSetType.noDataSet { finishMessage() }
                    }
                } else {
                    guard let active, active.0 == pdv.presentationContextID, commandBytes.isEmpty else {
                        throw DicomNetworkError.malformedCommandSet("Dataset without complete matching command")
                    }
                    datasetFragments += 1
                    if pdv.isLastFragment { finishMessage() }
                }
            }
        case .releaseRequest:
            responses.append(try DicomPDUCodec.encode(.releaseResponse))
        default: break
        }
    }

    private func finishMessage() {
        guard let active else { return }
        completedMessageIDs.append(active.1.messageID!)
        pending.append(active)
        maximumOutstanding = max(maximumOutstanding, pending.count)
        self.active = nil
    }

    func readPDU() throws -> Data {
        if !responses.isEmpty { return responses.removeFirst() }
        if failResponse { throw DicomNetworkError.networkTimeout("awaiting response") }
        guard let (context, request) = pending.popLast() else {
            throw DicomNetworkError.networkUnavailable("No scripted response")
        }
        responseIDs.append(request.messageID!)
        let response = DicomDIMSECommandSet(commandField: request.commandField | 0x8000,
                                            messageIDBeingRespondedTo: request.messageID, status: 0)
        return try DicomPDUCodec.encode(.pData([.init(presentationContextID: context, isCommand: true,
                                                    isLastFragment: true, data: response.encoded())]))
    }
}


extension DicomDIMSEServiceSCUTests {
    func test_UPSWrite_sentWithoutResponseIsNotReplayed() throws {
        var attempts = 0
        let service = DicomDIMSEServiceSCU(configuration: .init(host: "fake", port: 1,
            calledAETitle: "SCP", callingAETitle: "SCU", retryPolicy: .init(maxAttempts: 3)),
            transportFactory: {
                attempts += 1
                let transport = DIMSEWindowTransport()
                transport.failResponse = true
                return transport
            })
        XCTAssertThrowsError(try service.createUnifiedProcedureStep(sopInstanceUID: "2.25.2352", attributes: .init())) { error in
            XCTAssertEqual(error as? DicomNetworkError, .outcomeUncertain("Workflow write"))
        }
        XCTAssertEqual(attempts, 1)
    }

    func test_UPSWrite_notSentCanRetry() throws {
        var attempts = 0
        let service = DicomDIMSEServiceSCU(configuration: .init(host: "fake", port: 1,
            calledAETitle: "SCP", callingAETitle: "SCU", retryPolicy: .init(maxAttempts: 2)),
            transportFactory: {
                attempts += 1
                if attempts == 1 { throw DicomNetworkError.networkUnavailable("before connect") }
                return DIMSEWindowTransport()
            })
        XCTAssertEqual(try service.createUnifiedProcedureStep(sopInstanceUID: "2.25.2352", attributes: .init()).status, 0)
        XCTAssertEqual(attempts, 2)
    }

    func test_UPSRead_sentWithoutResponseCanRetry() throws {
        var attempts = 0
        let service = DicomDIMSEServiceSCU(configuration: .init(host: "fake", port: 1,
            calledAETitle: "SCP", callingAETitle: "SCU", retryPolicy: .init(maxAttempts: 2)),
            transportFactory: {
                attempts += 1
                let transport = DIMSEWindowTransport()
                transport.failResponse = attempts == 1
                return transport
            })
        XCTAssertEqual(try service.getUnifiedProcedureStep(sopInstanceUID: "2.25.2352").status, 0)
        XCTAssertEqual(attempts, 2)
    }

    func test_normalizedRequest_sentWithoutResponseIsNotReplayed() throws {
        var attempts = 0
        let service = DicomDIMSEServiceSCU(configuration: .init(host: "fake", port: 1,
            calledAETitle: "SCP", callingAETitle: "SCU", retryPolicy: .init(maxAttempts: 3)),
            transportFactory: {
                attempts += 1
                let transport = DIMSEWindowTransport()
                transport.failResponse = true
                return transport
            })
        XCTAssertThrowsError(try service.createMPPS(.init(sopInstanceUID: "2.25.2350"))) { error in
            XCTAssertEqual(error as? DicomNetworkError, .outcomeUncertain("MPPS N-CREATE"))
        }
        XCTAssertEqual(attempts, 1)
    }

    func test_normalizedRequest_notSentCanRetry() throws {
        var attempts = 0
        let service = DicomDIMSEServiceSCU(configuration: .init(host: "fake", port: 1,
            calledAETitle: "SCP", callingAETitle: "SCU", retryPolicy: .init(maxAttempts: 2)),
            transportFactory: {
                attempts += 1
                if attempts == 1 { throw DicomNetworkError.networkUnavailable("before connect") }
                return DIMSEWindowTransport()
            })
        XCTAssertEqual(try service.createMPPS(.init(sopInstanceUID: "2.25.2350")).status, 0)
        XCTAssertEqual(attempts, 2)
    }

    func test_timeoutDefaultsAndOverrides_areSeparate() {
        let configuration = DicomDIMSEConnectionConfiguration(host: "fake", port: 1, calledAETitle: "SCP",
            callingAETitle: "SCU", timeout: 9, associationTimeout: 2, cancelTimeout: 3)
        XCTAssertEqual(configuration.connectTimeout, 9)
        XCTAssertEqual(configuration.associationTimeout, 2)
        XCTAssertEqual(configuration.dimseResponseTimeout, 9)
        XCTAssertEqual(configuration.releaseTimeout, 9)
        XCTAssertEqual(configuration.cancelTimeout, 3)
    }
}
