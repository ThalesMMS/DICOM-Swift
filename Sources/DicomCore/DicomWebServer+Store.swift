import Foundation

extension DicomWebServer {
    func stow(_ request: DicomWebHTTPRequest, body: AsyncThrowingStream<Data, Error>, study: String?) async throws -> DicomWebHTTPResponse {
        guard let type = request.headers.dicomWebHeaderValue("Content-Type"),
              let media = try? DicomWebMediaType(type), media.type == "multipart/related",
              media.parameters["type"] == "application/dicom", configuration.supportedMediaTypes.contains("application/dicom") else {
            throw DicomWebServerFailure(415, "STOW requires multipart/related with type application/dicom.")
        }
        // Negotiate before accepting any instance.
        _ = try encode([], request: request)
        var parser: DicomWebMultipartStreamParser
        do { parser = try .init(contentType: type, limits: configuration.multipartLimits) }
        catch { throw DicomWebServerFailure(415, "Invalid MIME Content-Type.") }
        var payload = Data()
        var headers: [String: String] = [:]
        var results: [DicomWebStorageResult] = []
        var otherFailures: [Int] = []
        var locations: [String: String] = [:]
        var total = 0
        var count = 0
        func consume(_ events: [DicomWebMultipartEvent]) async throws {
            for event in events {
                switch event {
                case .partHeaders(let value, _):
                    headers = value
                    guard let partType = value.dicomWebHeaderValue("Content-Type"),
                          let parsed = try? DicomWebMediaType(partType), parsed.type == "application/dicom" else {
                        throw DicomWebServerFailure(415, "Unsupported MIME part media type.")
                    }
                case .payload(let bytes): payload.append(bytes)
                case .partEnd:
                    count += 1
                    defer { payload = Data() }
                    let meta = try? DicomPart10FileMetaParser.parse(payload)
                    guard let meta, let sopClass = meta.mediaStorageSOPClassUID, let sop = meta.mediaStorageSOPInstanceUID else {
                        otherFailures.append(0xC000); continue
                    }
                    var failure: Int?
                    var stored: DicomWebStoredInstance?
                    if let syntaxUID = meta.transferSyntaxUID, let syntax = DicomTransferSyntax(rawValue: syntaxUID) {
                        do {
                            let part = try DicomWebMediaType(headers.dicomWebHeaderValue("Content-Type")!)
                            if let declared = part.parameters["transfer-syntax"], declared != syntaxUID { failure = 0xC122 }
                            var set = try DicomDataSetParser.read(from: Data(payload.dropFirst(meta.dataSetOffset)), transferSyntax: syntax).dataSet
                            guard let studyUID = set.string(for: .studyInstanceUID), let seriesUID = set.string(for: .seriesInstanceUID),
                                  set.string(for: .sopClassUID) == sopClass, set.string(for: .sopInstanceUID) == sop,
                                  [studyUID, seriesUID, sopClass, sop].allSatisfy(Self.validUID) else {
                                throw DicomWebServerFailure(409, "Part 10 identity mismatch.")
                            }
                            if let study, study != studyUID { failure = 0xA900 }
                            // The dataset parser deliberately omits Pixel Data. Preserve native bytes for metadata bulk references.
                            if let decoder = try? DCMDecoder(data: payload), let descriptor = decoder.pixelDataDescriptor {
                                let start = descriptor.pixelDataOffset
                                let end = start + descriptor.totalPixelBytes
                                if start >= 0, end <= payload.count {
                                    set.set(.init(tag: 0x7FE00010, vr: descriptor.bitsAllocated > 8 ? .OW : .OB,
                                                  value: .bytes(Data(payload[start..<end]))))
                                }
                            }
                            stored = .init(dataSet: set, part10Data: payload, studyInstanceUID: studyUID,
                                seriesInstanceUID: seriesUID, sopInstanceUID: sop, sopClassUID: sopClass, transferSyntax: syntax)
                        } catch { failure = failure ?? 0xC000 }
                    } else { failure = 0xC122 }
                    if let failure { results.append(.init(sopClassUID: sopClass, sopInstanceUID: sop, failureReason: failure)) }
                    else if let stored {
                        _ = try await DicomRequestAuthorization.current?.check(.store,
                                .instance(study: stored.studyInstanceUID, series: stored.seriesInstanceUID,
                                          instance: stored.sopInstanceUID))
                        do {
                            let response = try await storage.store(instances: [stored])
                            guard response.count == 1, response[0].sopInstanceUID == sop else {
                                throw DicomWebServerFailure(500, "Storage provider returned invalid results.")
                            }
                            results += response
                        } catch is CancellationError { throw CancellationError() }
                        catch { results.append(.init(sopClassUID: sopClass, sopInstanceUID: sop, failureReason: 0x0110)) }
                        locations[sop] = baseURL(request).appendingPathComponent("studies/\(stored.studyInstanceUID)/series/\(stored.seriesInstanceUID)/instances/\(sop)").absoluteString
                    }
                case .epilogue: break
                }
            }
        }
        do {
            for try await chunk in body {
                try Task.checkCancellation()
                guard chunk.count <= configuration.maximumRequestBodyBytes - total else {
                    throw DicomWebServerFailure(413, "Request body limit exceeded.")
                }
                total += chunk.count
                // Even a buffered in-process caller feeds the parser in bounded pieces.
                for start in stride(from: 0, to: chunk.count, by: 64 * 1024) {
                    try await consume(parser.feed(Data(chunk.dropFirst(start).prefix(64 * 1024))))
                }
            }
            try await consume(parser.finish())
        } catch let error as DicomWebMultipartStreamError {
            if case .limitExceeded = error { throw DicomWebServerFailure(413, "Multipart limit exceeded.") }
            throw DicomWebServerFailure(400, "Malformed multipart message.")
        }
        guard count > 0 else { throw DicomWebServerFailure(400, "No instances supplied.") }
        var set = DicomDataSet(elements: [.init(tag: 0x00081190, vr: .UR,
                                               value: study.map { .strings([baseURL(request).appendingPathComponent("studies/\($0)").absoluteString]) } ?? .empty)])
        for failed in [false, true] {
            let items = results.filter { ($0.failureReason != nil) == failed }.map { result in
                var entry = DicomDataSet(elements: [
                    .init(tag: 0x00081150, vr: .UI, value: .strings([result.sopClassUID])),
                    .init(tag: 0x00081155, vr: .UI, value: .strings([result.sopInstanceUID]))
                ])
                if let reason = result.failureReason { entry.set(Self.reason(0x00081197, reason)) }
                else {
                    entry.set(.init(tag: 0x00081190, vr: .UR, value: locations[result.sopInstanceUID].map { .strings([$0]) } ?? .empty))
                    if let reason = result.effectiveWarningReason { entry.set(Self.reason(0x00081196, reason)) }
                }
                return DicomSequenceItem(dataSet: entry)
            }
            if !items.isEmpty { set.set(.init(tag: failed ? 0x00081198 : 0x00081199, vr: .SQ, value: .sequence(items))) }
        }
        if !otherFailures.isEmpty {
            set.set(.init(tag: 0x0008119A, vr: .SQ, value: .sequence(otherFailures.map {
                DicomSequenceItem(dataSet: .init(elements: [Self.reason(0x00081197, $0)]))
            })))
        }
        var response = try encode([set], request: request)
        if response.headers["Content-Type"] == "application/dicom+json",
           let array = try JSONSerialization.jsonObject(with: response.body) as? [[String: Any]], let object = array.first {
            response.body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let accepted = results.filter { $0.failureReason == nil }.count
        response.statusCode = accepted == 0 ? 409 : accepted < count || results.contains { $0.effectiveWarningReason != nil } ? 202 : 200
        return response
    }
    static func validUID(_ uid: String) -> Bool {
        !uid.isEmpty && uid.utf8.count <= 64 && uid.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && ($0.count == 1 || $0.first != "0") && $0.utf8.allSatisfy { (48...57).contains($0) }
        }
    }
    private static func reason(_ tag: Int, _ value: Int) -> DicomDataElement {
        .init(tag: tag, vr: .US, value: .unsignedIntegers([UInt(value)]))
    }
}
