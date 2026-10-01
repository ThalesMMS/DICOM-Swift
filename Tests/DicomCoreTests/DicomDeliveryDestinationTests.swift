import CryptoKit
import Foundation
import XCTest
@testable import DicomCore

func deliveryPart10(_ uid: String) throws -> URL {
    var set = DicomDataSet()
    set.set(.init(tag: 0x00080016, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])))
    set.set(.init(tag: 0x00080018, vr: .UI, value: .strings([uid])))
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try DicomDataSetWriter.part10Data(from: set).write(to: url)
    return url
}

struct DeliveryHTTPFake: DicomWebHTTPTransport {
    var response: DicomWebHTTPResponse
    func send(_ request: DicomWebHTTPRequest) async throws -> DicomWebHTTPResponse { response }
}

final class DicomDeliveryDestinationTests: XCTestCase {
    func test_stowConflictRequiresPerInstanceAcknowledgement() async throws {
        let file = try deliveryPart10("1.2.3")
        defer { try? FileManager.default.removeItem(at: file) }
        var item = deliveryItem("a")
        item.destinationKind = .stowRS
        item.payload = .objects([file])
        for code in [0xA700, 0x0111] {
            let json: [String: Any] = ["00081198": ["vr": "SQ", "Value": [[
                "00081150": ["vr": "UI", "Value": ["1.2.840.10008.5.1.4.1.1.7"]],
                "00081155": ["vr": "UI", "Value": ["1.2.3"]],
                "00081197": ["vr": "US", "Value": [code]]
            ]]]]
            let response = DicomWebHTTPResponse(statusCode: 409, headers: ["Content-Type": "application/dicom+json"],
                body: try JSONSerialization.data(withJSONObject: json))
            let destination = DicomSTOWDestination(id: "peer",
                configuration: .init(baseURL: URL(string: "https://example.test")!), transport: DeliveryHTTPFake(response: response))
            let result = await destination.deliver(item, isCancelled: { false })
            guard case .partial(let receipt) = result else { return XCTFail("Expected refused instance: \(result)") }
            XCTAssertEqual(receipt.perObject.first?.accepted, false)
            XCTAssertEqual(receipt.perObject.first?.errorClass, code == 0xA700 ? .transient : .rejectedByDestination)
        }
        let unknown = DicomSTOWDestination(id: "peer", configuration: .init(baseURL: URL(string: "https://example.test")!),
            transport: DeliveryHTTPFake(response: .init(statusCode: 409)))
        let result = await unknown.deliver(item, isCancelled: { false })
        guard case .uncertain = result else { return XCTFail("Missing acknowledgement must remain uncertain") }
    }

    func test_webhookOutcomeMappingIncludesSignatureHeader() async throws {
        let keys = DicomWebhookInMemoryKeyProvider(activeKeyID: "test",
            keys: ["test": SymmetricKey(data: Data("fixture".utf8))])
        var item = deliveryItem("a")
        item.payload = .event(try .init(eventID: "a", kind: "complete", occurredAt: Date(), subject: .init(), source: "test"))
        for (status, headers, expected) in [
            (401, ["X-Isis-Signature-Error": "invalid"], DicomDeliveryErrorClass.signatureRejected),
            (403, [:], .rejectedByDestination), (503, ["Retry-After": "12"], .transient),
            (307, ["Location": "https://example.test/other"], .rejectedByDestination)
        ] {
            let destination = DicomWebhookDestination(id: "peer", url: URL(string: "https://example.test/hook")!,
                transport: DeliveryHTTPFake(response: .init(statusCode: status, headers: headers)),
                policy: .init(resolve: { _ in ["8.8.8.8"] }), signer: .init(keys: keys))
            let result = await destination.deliver(item, isCancelled: { false })
            guard case .failed(let actual, _, let retry) = result else { return XCTFail("Expected failed outcome") }
            XCTAssertEqual(actual, expected)
            if status == 503 { XCTAssertEqual(retry, 12) }
        }
    }

    func test_dimseClassifications() {
        XCTAssertEqual(DicomDIMSEStoreDestination.classify(.networkTimeout("read")), .uncertain)
        XCTAssertEqual(DicomDIMSEStoreDestination.classify(.networkUnavailable("connect")), .transient)
        XCTAssertEqual(DicomDIMSEStoreDestination.classify(.dimseStatusFailure(0xA700)), .rejectedByDestination)
        XCTAssertEqual(DicomDIMSEStoreDestination.classify(.operationCancelled("store")), .cancelled)
        XCTAssertEqual(DicomDIMSEStoreDestination.classify(.missingAcceptedPresentationContext("1.2.3")),
                       .rejectedByDestination)
    }
}

private final class DeliveryDIMSETransport: DicomAssociationTransport {
    let status: UInt16
    let timeout: Bool
    private var responses: [Data] = []
    private var command = Data()
    private var request: DicomDIMSECommandSet?
    private var context: UInt8 = 1
    init(status: UInt16 = 0, timeout: Bool = false) { self.status = status; self.timeout = timeout }
    func writePDU(_ data: Data) throws {
        switch try DicomPDUCodec.decode(data) {
        case .associationRequest(let request):
            let accept = DicomAssociationNegotiator.accept(request,
                supportedAbstractSyntaxUIDs: Set(request.presentationContexts.map(\.abstractSyntaxUID)),
                preferredTransferSyntaxes: [.explicitVRLittleEndian])
            responses.append(try DicomPDUCodec.encode(.associationAccept(accept)))
        case .pData(let fragments):
            for fragment in fragments {
                context = fragment.presentationContextID
                if fragment.isCommand {
                    command.append(fragment.data)
                    if fragment.isLastFragment {
                        request = try DicomDIMSECommandSet.decode(command)
                        command.removeAll()
                    }
                } else if fragment.isLastFragment, let request, !timeout {
                    let reply = DicomDIMSECommandSet(commandField: DicomDIMSECommandField.cStoreRSP,
                        messageIDBeingRespondedTo: request.messageID, status: status)
                    responses.append(try DicomPDUCodec.encode(.pData([.init(presentationContextID: context,
                        isCommand: true, isLastFragment: true, data: reply.encoded())])))
                }
            }
        case .releaseRequest: responses.append(try DicomPDUCodec.encode(.releaseResponse))
        default: break
        }
    }
    func readPDU() throws -> Data {
        guard !responses.isEmpty else { throw DicomNetworkError.networkTimeout("after complete dataset") }
        return responses.removeFirst()
    }
}

private final class DeliveryFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

extension DicomDeliveryDestinationTests {
    func test_dimseBatchScriptedSuccessRefusalAndSentTimeoutWithoutNestedRetry() async throws {
        let file = try deliveryPart10("1.2.3")
        defer { try? FileManager.default.removeItem(at: file) }
        var item = deliveryItem("a")
        item.destinationKind = .dimseStore
        item.payload = .objects([file])
        for (status, timeout) in [(UInt16(0), false), (UInt16(0xA700), false), (UInt16(0), true)] {
            let counter = DeliveryFactoryCounter()
            let destination = DicomDIMSEStoreDestination(id: "peer") {
                DicomDIMSEServiceSCU(configuration: .init(host: "scripted", port: 1, calledAETitle: "SCP",
                    callingAETitle: "SCU", retryPolicy: .init(maxAttempts: 8)), transportFactory: {
                        counter.increment()
                        return DeliveryDIMSETransport(status: status, timeout: timeout)
                    })
            }
            let result = await destination.deliver(item, isCancelled: { false })
            if timeout {
                guard case .uncertain = result else { return XCTFail("Expected uncertain timeout: \(result)") }
            } else if status != 0 {
                guard case .failed(.rejectedByDestination, _, _) = result else {
                    return XCTFail("Expected classified refusal: \(result)")
                }
            } else {
                guard case .delivered = result else { return XCTFail("Expected delivery: \(result)") }
            }
            XCTAssertEqual(counter.value, 1)
        }
    }
}

extension DicomDeliveryDestinationTests {
    func test_stowTransientPreservesRetryAfter() async throws {
        let file = try deliveryPart10("1.2.3")
        defer { try? FileManager.default.removeItem(at: file) }
        let destination = DicomSTOWDestination(id: "peer",
            configuration: .init(baseURL: URL(string: "https://example.test")!),
            transport: DeliveryHTTPFake(response: .init(statusCode: 503, headers: ["Retry-After": "123"])))
        var item = deliveryItem("a")
        item.destinationKind = .stowRS
        item.payload = .objects([file])
        let result = await destination.deliver(item, isCancelled: { false })
        guard case .failed(.transient, _, let delay) = result else { return XCTFail("Expected transient: \(result)") }
        XCTAssertEqual(delay, 123)
    }
}
