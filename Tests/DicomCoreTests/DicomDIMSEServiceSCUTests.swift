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
            element(DicomTag.specificCharacterSet.rawValue, .CS, "ISO 2022 IR 87"),
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

    func testGetSCUStreamsStoreSuboperationAfterAcknowledgingIt() throws {
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
                XCTAssertTrue(transport.writtenCommands.contains {
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
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nCreateRQ,
            DicomDIMSECommandField.nSetRQ,
            DicomDIMSECommandField.nActionRQ
        ])
        XCTAssertEqual(transport.writtenDataSets[0].string(for: DicomPrintTag.filmSessionLabel), "PRINT-1")
        XCTAssertEqual(transport.writtenCommands[3].requestedSOPInstanceUID, job.filmBoxSOPInstanceUID)
        XCTAssertEqual(transport.writtenCommands[3].actionTypeID, 1)

        let imageDataSet = transport.writtenDataSets[2]
            .sequenceItems(for: DicomPrintTag.basicGrayscaleImageSequence)
            .first?.dataSet
        XCTAssertEqual(imageDataSet?.int(for: .rows), 1)
        XCTAssertEqual(imageDataSet?.int(for: .columns), 1)
        XCTAssertEqual(imageDataSet?.int(for: .bitsAllocated), 8)
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
            securityProfile: .bcp195
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
            securityProfile: .bcp195
        )

        let prepared = try DicomTLSOptionsFactory.preparedParameters(for: tls, role: .client)

        XCTAssertNotNil(prepared.tlsContext)
        XCTAssertEqual(prepared.tlsContext?.serverName, "localhost")
        XCTAssertEqual(prepared.tlsContext?.hasLocalIdentity, true)
        XCTAssertEqual(prepared.tlsContext?.trustedCertificateCount, 1)
        XCTAssertEqual(prepared.tlsContext?.securityProfile, .bcp195)
        XCTAssertEqual(prepared.tlsContext?.minimumProtocolVersionName, "TLSv1.2")
        XCTAssertEqual(prepared.tlsContext?.peerAuthenticationRequired, true)
        #else
        throw skipNetworkSecurityTLS("Network/Security TLS options are unavailable on this platform.")
        #endif
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

    func testTemporaryKeychainCleansUpDirectoryWhenUnlockFails() throws {
        #if canImport(Security) && os(macOS)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DicomTemporaryKeychainTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertThrowsError(try DicomTemporaryKeychain(
            fileManager: .default,
            directory: directory,
            unlockKeychain: { _, _, _, _ in errSecAuthFailed }
        )) { error in
            guard case DicomNetworkError.tlsConfigurationInvalid(let reason) = error else {
                return XCTFail("Expected TLS configuration error, got \(error)")
            }
            XCTAssertTrue(reason.contains("unlock"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        #else
        throw skipNetworkSecurityTLS("Temporary keychain cleanup runs only on macOS Security.")
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
                securityProfile: .bcp195
            ),
            clientTLS: DicomTLSConfiguration(
                mode: .enabled,
                serverName: "localhost",
                material: DicomTLSMaterial(trustStorePath: fixture.caCertificatePath),
                securityProfile: .bcp195
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
                securityProfile: .bcp195
            ),
            clientTLS: DicomTLSConfiguration(
                mode: .enabled,
                serverName: "localhost",
                material: DicomTLSMaterial(trustStorePath: fixture.wrongCACertificatePath),
                securityProfile: .bcp195
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
            securityProfile: .bcp195
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

private func printFilmBoxResponseDataSet() -> DicomDataSet {
    DicomDataSet(elements: [
        DicomDataElement(tag: DicomPrintTag.referencedImageBoxSequence,
                         vr: .SQ,
                         value: .sequence([
                            DicomSequenceItem(dataSet: DicomDataSet(elements: [
                                element(DicomTag.referencedSOPClassUID.rawValue,
                                        .UI,
                                        DicomNetworkUID.basicGrayscaleImageBoxSOPClass),
                                element(DicomTag.referencedSOPInstanceUID.rawValue,
                                        .UI,
                                        "2.25.imagebox.1")
                            ]))
                         ]))
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
    var listenerError: Error?
    var outcome = TLSHandshakeOutcome.timedOut
    var acceptedConnections: [NWConnection] = []
    let acceptedConnectionsLock = NSLock()

    listener.newConnectionHandler = { connection in
        acceptedConnectionsLock.lock()
        acceptedConnections.append(connection)
        acceptedConnectionsLock.unlock()
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                outcome = .failed
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
            listenerError = error
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
    if let listenerError {
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
            outcome = .ready
            connectionSemaphore.signal()
        case .failed:
            outcome = .failed
            connectionSemaphore.signal()
        default:
            break
        }
    }
    connection.start(queue: queue)
    connection.send(content: Data([0x01]), completion: .contentProcessed { error in
        outcome = error == nil ? .ready : .failed
        connectionSemaphore.signal()
    })

    if connectionSemaphore.wait(timeout: .now() + 5) != .success {
        outcome = .timedOut
    }
    connection.cancel()
    acceptedConnectionsLock.lock()
    acceptedConnections.forEach { $0.cancel() }
    acceptedConnectionsLock.unlock()
    listener.cancel()
    _ = serverPrepared.tlsContext
    _ = clientPrepared.tlsContext
    return outcome
}
#endif

private final class ScriptedTransportFactory: @unchecked Sendable {
    private let supportedAbstractSyntaxUIDs: Set<String>
    private let lock = NSLock()
    private var storage: [DIMSEScriptedTransport] = []

    init(supportedAbstractSyntaxUIDs: Set<String>) {
        self.supportedAbstractSyntaxUIDs = supportedAbstractSyntaxUIDs
    }

    var transports: [DIMSEScriptedTransport] {
        lock.lock()
        let value = storage
        lock.unlock()
        return value
    }

    func makeTransport(configuration _: DicomDIMSEConnectionConfiguration) -> DicomAssociationTransport {
        let transport = DIMSEScriptedTransport(supportedAbstractSyntaxUIDs: supportedAbstractSyntaxUIDs)
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
    private let cancelBeforeReturningCommandFields: Set<UInt16>
    private let retrieveFinalStatus: UInt16
    private let failBeforeRetrieveFinalResponse: Bool
    private let findResponseDataSet: DicomDataSet?
    private var responses: [Data] = []
    private var acceptedContextsByID: [UInt8: DicomAcceptedPresentationContext] = [:]
    private var lastRequestCommand: DicomDIMSECommandSet?
    private var pendingDataSetPayload = Data()
    private var pendingDataSetPresentationContextID: UInt8?
    private var didTriggerCancellation = false
    private var isClosed = false

    private(set) var associationRequests: [DicomAssociationRequest] = []
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
        cancelBeforeReturningCommandFields: Set<UInt16> = [],
        retrieveFinalStatus: UInt16 = 0,
        failBeforeRetrieveFinalResponse: Bool = false,
        findResponseDataSet: DicomDataSet? = nil
    ) {
        self.supportedAbstractSyntaxUIDs = supportedAbstractSyntaxUIDs
        self.preferredTransferSyntaxes = preferredTransferSyntaxes
        self.cancelBeforeReturningCommandFields = cancelBeforeReturningCommandFields
        self.retrieveFinalStatus = retrieveFinalStatus
        self.failBeforeRetrieveFinalResponse = failBeforeRetrieveFinalResponse
        self.findResponseDataSet = findResponseDataSet
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
                preferredTransferSyntaxes: preferredTransferSyntaxes
            )
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
            responses.append(try DicomPDUCodec.encode(.releaseResponse))
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
        case DicomDIMSECommandField.nActionRQ:
            try enqueueCommand(DicomDIMSECommandSet(
                requestedSOPClassUID: command.requestedSOPClassUID,
                commandField: DicomDIMSECommandField.nActionRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: 0,
                requestedSOPInstanceUID: command.requestedSOPInstanceUID,
                actionTypeID: command.actionTypeID
            ), contextID: presentationContextID)
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
            try enqueueCommand(DicomDIMSECommandSet(
                affectedSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
                commandField: DicomDIMSECommandField.cStoreRQ,
                messageID: 33,
                commandDataSetType: DicomDIMSECommandDataSetType.hasDataSet,
                affectedSOPInstanceUID: "2.25.instance"
            ), contextID: 3)
            try enqueueDataSet(storageDataSet(), contextID: 3)
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
                status: 0,
                affectedSOPInstanceUID: command.affectedSOPInstanceUID
            ), contextID: presentationContextID)
            if hasFilmBoxDataSet {
                try enqueueDataSet(printFilmBoxResponseDataSet(), contextID: presentationContextID)
            }
        case DicomDIMSECommandField.nSetRQ:
            try enqueueCommand(DicomDIMSECommandSet(
                requestedSOPClassUID: command.requestedSOPClassUID,
                commandField: DicomDIMSECommandField.nSetRSP,
                messageIDBeingRespondedTo: command.messageID,
                commandDataSetType: DicomDIMSECommandDataSetType.noDataSet,
                status: 0,
                requestedSOPInstanceUID: command.requestedSOPInstanceUID
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
        return responses.removeFirst()
    }
}
