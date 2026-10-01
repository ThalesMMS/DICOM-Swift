import Foundation

struct DicomWebFrameRetrievalService {
    let maximumResponseBytes: Int

    func retrieve(
        instance: DicomWebStoredInstance,
        frames: DicomWebFrameList,
        accept: String?,
        requestURL: URL
    ) throws -> DicomWebHTTPResponse {
        let decoder: DCMDecoder
        do {
            decoder = try DCMDecoder(data: instance.part10Data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DicomWebFrameRouteError.malformedPixelData
        }
        let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) ?? instance.transferSyntax
        let isEncapsulated = decoder.pixelDataDescriptor == nil && syntax.isCompressed
        let selection = try DicomWebMediaTypeNegotiator.rawFrameSelection(
            accept: accept,
            transferSyntax: syntax,
            isCompressed: isEncapsulated
        )
        let representations = try isEncapsulated
            ? compressedRepresentations(decoder: decoder, frames: frames, selection: selection)
            : nativeRepresentations(decoder: decoder, frames: frames, selection: selection)
        let parts = representations.map { representation in
            DicomWebMultipartResponseBuilder.Part(
                contentType: representation.mediaType,
                transferSyntaxUID: representation.transferSyntaxUID,
                contentLocation: contentLocation(
                    requestURL: requestURL,
                    frameNumbers: representation.frameNumbers
                ),
                body: representation.data
            )
        }
        let multipart = try DicomWebMultipartResponseBuilder.build(
            parts: parts,
            relatedType: selection.mediaType,
            relatedTransferSyntaxUID: selection.transferSyntaxUID,
            maximumBytes: maximumResponseBytes
        )
        return DicomWebHTTPResponse(
            statusCode: 200,
            headers: [
                "Cache-Control": "no-store",
                "Content-Length": String(multipart.body.count),
                "Content-Type": multipart.contentType
            ],
            body: multipart.body
        )
    }

    private func nativeRepresentations(
        decoder: DCMDecoder,
        frames: DicomWebFrameList,
        selection: DicomWebMediaTypeNegotiator.Selection
    ) throws -> [DicomWebFrameRepresentation] {
        guard let descriptor = decoder.pixelDataDescriptor else {
            throw DicomWebFrameRouteError.malformedPixelData
        }
        guard descriptor.bitsAllocated.isMultiple(of: 8) else {
            throw DicomWebFrameRouteError.mediaTypeNotAcceptable
        }
        try validate(frames: frames, frameCount: descriptor.numberOfFrames)

        var payload = Data()
        for number in frames.numbers {
            guard let frame = decoder.getFrame(number - 1) else {
                throw DicomWebFrameRouteError.malformedPixelData
            }
            try append(frame.data, to: &payload)
        }
        return [DicomWebFrameRepresentation(
            frameNumbers: frames.numbers,
            mediaType: selection.mediaType,
            transferSyntaxUID: selection.transferSyntaxUID,
            data: payload
        )]
    }

    private func compressedRepresentations(
        decoder: DCMDecoder,
        frames: DicomWebFrameList,
        selection: DicomWebMediaTypeNegotiator.Selection
    ) throws -> [DicomWebFrameRepresentation] {
        let reader: DicomEncapsulatedPixelFrameReader
        do {
            reader = try decoder.makeEncapsulatedPixelFrameReader()
            try reader.validateDeclaredFrameCount()
        } catch {
            throw DicomWebFrameRouteError.malformedPixelData
        }
        try validate(frames: frames, frameCount: reader.frameCount)
        return try frames.numbers.map { number in
            let data: Data
            do {
                data = try reader.frameData(at: number - 1)
            } catch {
                throw DicomWebFrameRouteError.malformedPixelData
            }
            guard data.count <= maximumResponseBytes else {
                throw DicomWebFrameRouteError.responseTooLarge
            }
            return DicomWebFrameRepresentation(
                frameNumbers: [number],
                mediaType: selection.mediaType,
                transferSyntaxUID: selection.transferSyntaxUID,
                data: data
            )
        }
    }

    private func validate(frames: DicomWebFrameList, frameCount: Int) throws {
        guard let last = frames.numbers.last, last <= frameCount else {
            throw DicomWebFrameRouteError.frameNotFound
        }
    }

    private func append(_ data: Data, to destination: inout Data) throws {
        let total = destination.count.addingReportingOverflow(data.count)
        guard !total.overflow, total.partialValue <= maximumResponseBytes else {
            throw DicomWebFrameRouteError.responseTooLarge
        }
        destination.append(data)
    }

    private func contentLocation(requestURL: URL, frameNumbers: [Int]) -> URL {
        guard frameNumbers.count == 1,
              var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            return requestURL
        }
        var pathComponents = components.percentEncodedPath.split(separator: "/").map(String.init)
        guard pathComponents.count >= 2 else { return requestURL }
        pathComponents[pathComponents.count - 1] = String(frameNumbers[0])
        components.percentEncodedPath = "/" + pathComponents.joined(separator: "/")
        return components.url ?? requestURL
    }
}
