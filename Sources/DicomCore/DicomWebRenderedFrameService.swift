import Foundation

struct DicomWebRenderedFrameService {
    let maximumPixels: Int
    let maximumResponseBytes: Int

    func retrieve(
        instance: DicomWebStoredInstance,
        frames: DicomWebFrameList,
        accept: String?,
        requestURL: URL
    ) throws -> DicomWebHTTPResponse {
        let (decoder, descriptor) = try decode(instance)
        guard let last = frames.numbers.last, last <= descriptor.numberOfFrames else {
            throw DicomWebFrameRouteError.frameNotFound
        }

        let selection = try DicomWebMediaTypeNegotiator.renderedSelection(
            accept: accept,
            representationCount: frames.numbers.count
        )
        let parameters = try RenderParameters(url: requestURL, mediaType: selection.mediaType)
        let parts = try render(
            decoder: decoder,
            descriptor: descriptor,
            frameNumbers: frames.numbers,
            selection: selection,
            parameters: parameters
        ) { contentLocation(requestURL: requestURL, frameNumber: $0) }
        return try response(parts: parts, selection: selection)
    }

    /// Renders the first frame of each instance, in order, as a rendered study or series answers. Further frames of
    /// a multi-frame instance are left out.
    func retrieve(
        instances: [DicomWebStoredInstance],
        accept: String?,
        requestURL: URL
    ) throws -> DicomWebHTTPResponse {
        let decoded = try instances.map(decode)
        let selection = try DicomWebMediaTypeNegotiator.renderedSelection(
            accept: accept,
            representationCount: instances.count
        )
        let parameters = try RenderParameters(url: requestURL, mediaType: selection.mediaType)
        var parts: [DicomWebMultipartResponseBuilder.Part] = []
        for (instance, (decoder, descriptor)) in zip(instances, decoded) {
            parts += try render(
                decoder: decoder,
                descriptor: descriptor,
                frameNumbers: [1],
                selection: selection,
                parameters: parameters
            ) { _ in instanceLocation(requestURL: requestURL, instance: instance) }
        }
        return try response(parts: parts, selection: selection)
    }

    private func decode(_ instance: DicomWebStoredInstance) throws -> (DCMDecoder, DicomPixelDataDescriptor) {
        var data = instance.part10Data
        // Compressed Pixel Data is rendered from the Explicit VR Little Endian object that a retrieve would
        // send, decoded the same way. A syntax without a decoder stays not acceptable.
        let native = DicomTransferSyntax.explicitVRLittleEndian.rawValue
        if instance.transferSyntax.isEncapsulated {
            guard DicomWebServerNativeTranscoding().canTranscode(from: instance.transferSyntax.rawValue, to: native) else {
                throw DicomWebFrameRouteError.mediaTypeNotAcceptable
            }
            do {
                data = try DicomTranscoder().transcode(data, to: .explicitVRLittleEndian)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DicomWebFrameRouteError.mediaTypeNotAcceptable
            }
        }
        let decoder: DCMDecoder
        do {
            decoder = try DCMDecoder(data: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DicomWebFrameRouteError.malformedPixelData
        }
        guard let descriptor = decoder.pixelDataDescriptor else {
            throw DicomWebFrameRouteError.mediaTypeNotAcceptable
        }
        return (decoder, descriptor)
    }

    private func render(
        decoder: DCMDecoder,
        descriptor: DicomPixelDataDescriptor,
        frameNumbers: [Int],
        selection: DicomWebMediaTypeNegotiator.Selection,
        parameters: RenderParameters,
        location: (Int) -> URL
    ) throws -> [DicomWebMultipartResponseBuilder.Part] {
        let outputSize = try outputSize(parameters: parameters, descriptor: descriptor)
        return try frameNumbers.map { frameNumber -> DicomWebMultipartResponseBuilder.Part in
            let bitmap: DicomRenderedBitmap
            do {
                bitmap = try DicomImagePreprocessor().render(
                    decoder: decoder,
                    options: DicomImagePreprocessOptions(
                        frameIndex: frameNumber - 1,
                        displaySelection: parameters.displaySelection,
                        outputSize: outputSize
                    )
                )
            } catch {
                throw DicomWebFrameRouteError.renderingFailed
            }
            let data = try DicomWebRenderedFrameEncoder.encode(
                bitmap,
                mediaType: selection.mediaType,
                quality: parameters.quality,
                maximumBytes: maximumResponseBytes
            )
            return DicomWebMultipartResponseBuilder.Part(
                contentType: selection.mediaType,
                transferSyntaxUID: nil,
                contentLocation: location(frameNumber),
                body: data
            )
        }
    }

    private func response(
        parts: [DicomWebMultipartResponseBuilder.Part],
        selection: DicomWebMediaTypeNegotiator.Selection
    ) throws -> DicomWebHTTPResponse {
        if selection.isMultipart {
            let multipart = try DicomWebMultipartResponseBuilder.build(
                parts: parts,
                relatedType: selection.mediaType,
                maximumBytes: maximumResponseBytes
            )
            return response(contentType: multipart.contentType, body: multipart.body)
        }
        guard let part = parts.first else {
            throw DicomWebFrameRouteError.renderingFailed
        }
        return response(
            contentType: part.contentType,
            body: part.body,
            contentLocation: part.contentLocation
        )
    }

    private func outputSize(
        parameters: RenderParameters,
        descriptor: DicomPixelDataDescriptor
    ) throws -> DicomImageSize? {
        let width = parameters.viewport?.width ?? descriptor.columns
        let height = parameters.viewport?.height ?? descriptor.rows
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow, pixels.partialValue <= maximumPixels else {
            throw DicomWebFrameRouteError.responseTooLarge
        }
        return parameters.viewport
    }

    private func response(
        contentType: String,
        body: Data,
        contentLocation: URL? = nil
    ) -> DicomWebHTTPResponse {
        var headers = [
            "Cache-Control": "no-store",
            "Content-Length": String(body.count),
            "Content-Type": contentType
        ]
        if let contentLocation {
            headers["Content-Location"] = contentLocation.absoluteString
        }
        return DicomWebHTTPResponse(statusCode: 200, headers: headers, body: body)
    }

    private func contentLocation(requestURL: URL, frameNumber: Int) -> URL {
        guard var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            return requestURL
        }
        var pathComponents = components.percentEncodedPath.split(separator: "/").map(String.init)
        guard pathComponents.count >= 3 else { return requestURL }
        pathComponents[pathComponents.count - 2] = String(frameNumber)
        components.percentEncodedPath = "/" + pathComponents.joined(separator: "/")
        return components.url ?? requestURL
    }

    /// The rendered-instance URL of `instance` under the same service root and query as `requestURL`.
    private func instanceLocation(requestURL: URL, instance: DicomWebStoredInstance) -> URL {
        guard var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false) else {
            return requestURL
        }
        let pathComponents = components.percentEncodedPath.split(separator: "/").map(String.init)
        guard let studies = pathComponents.lastIndex(of: "studies") else { return requestURL }
        let resource = [instance.studyInstanceUID, "series", instance.seriesInstanceUID,
                        "instances", instance.sopInstanceUID, "rendered"]
        components.percentEncodedPath = "/" + (pathComponents[...studies] + resource).joined(separator: "/")
        return components.url ?? requestURL
    }

    private struct RenderParameters {
        let quality: Double
        let viewport: DicomImageSize?
        let displaySelection: DicomDisplaySelection?

        init(url: URL, mediaType: String) throws {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var values: [String: String] = [:]
            for item in items {
                let name = item.name.lowercased()
                guard values[name] == nil else {
                    throw DicomWebFrameRouteError.invalidRenderParameter
                }
                values[name] = item.value ?? ""
            }
            guard Set(values.keys).isSubset(of: ["quality", "viewport", "window"]) else {
                throw DicomWebFrameRouteError.invalidRenderParameter
            }

            if let rawQuality = values["quality"] {
                guard mediaType == "image/jpeg",
                      let quality = Int(rawQuality),
                      (1...100).contains(quality) else {
                    throw DicomWebFrameRouteError.invalidRenderParameter
                }
                self.quality = Double(quality) / 100
            } else {
                self.quality = 0.9
            }

            if let rawViewport = values["viewport"] {
                let fields = rawViewport.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count == 2,
                      let width = Int(fields[0]), width > 0,
                      let height = Int(fields[1]), height > 0 else {
                    throw DicomWebFrameRouteError.invalidRenderParameter
                }
                self.viewport = DicomImageSize(width: width, height: height)
            } else {
                self.viewport = nil
            }

            if let rawWindow = values["window"] {
                // The third field names the VOI LUT function; only `linear` is rendered.
                let fields = rawWindow.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count == 2 || (fields.count == 3 && fields[2] == "linear"),
                      let center = Double(fields[0]), center.isFinite,
                      let width = Double(fields[1]), width.isFinite, width > 0 else {
                    throw DicomWebFrameRouteError.invalidRenderParameter
                }
                self.displaySelection = .customWindow(WindowSettings(center: center, width: width))
            } else {
                self.displaySelection = nil
            }
        }
    }
}
