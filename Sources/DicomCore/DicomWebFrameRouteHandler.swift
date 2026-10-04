import Foundation

struct DicomWebFrameRouteHandler {
    let configuration: DicomWebServerConfiguration
    let instance: DicomWebStoredInstance

    func retrieveRaw(
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String,
        frameList: String,
        request: DicomWebHTTPRequest
    ) -> DicomWebHTTPResponse {
        retrieve(
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            sopInstanceUID: sopInstanceUID,
            frameList: frameList
        ) { instance, frames in
            try DicomWebFrameRetrievalService(
                maximumResponseBytes: configuration.maximumFrameResponseBytes
            ).retrieve(
                instance: instance,
                frames: frames,
                accept: request.headers.dicomWebHeaderValue("Accept"),
                requestURL: request.url
            )
        }
    }

    func retrieveRendered(
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String,
        frameList: String,
        request: DicomWebHTTPRequest
    ) -> DicomWebHTTPResponse {
        retrieve(
            studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            sopInstanceUID: sopInstanceUID,
            frameList: frameList
        ) { instance, frames in
            try DicomWebRenderedFrameService(
                maximumPixels: configuration.maximumRenderedPixels,
                maximumResponseBytes: configuration.maximumRenderedResponseBytes
            ).retrieve(
                instance: instance,
                frames: frames,
                accept: request.headers.dicomWebHeaderValue("Accept"),
                requestURL: request.url
            )
        }
    }

    /// Renders the first frame of each of `instances`, as a rendered study or series answers.
    func retrieveRendered(instances: [DicomWebStoredInstance], request: DicomWebHTTPRequest) -> DicomWebHTTPResponse {
        do {
            return try DicomWebRenderedFrameService(
                maximumPixels: configuration.maximumRenderedPixels,
                maximumResponseBytes: configuration.maximumRenderedResponseBytes
            ).retrieve(
                instances: instances,
                accept: request.headers.dicomWebHeaderValue("Accept"),
                requestURL: request.url
            )
        } catch {
            return errorResponse(error)
        }
    }

    private func retrieve(
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String,
        frameList: String,
        operation: (DicomWebStoredInstance, DicomWebFrameList) throws -> DicomWebHTTPResponse
    ) -> DicomWebHTTPResponse {
        guard instance.studyInstanceUID == studyInstanceUID,
              instance.seriesInstanceUID == seriesInstanceUID,
              instance.sopInstanceUID == sopInstanceUID else {
            return stableError(statusCode: 404,
                               code: .frameNotFound,
                               text: "Requested DICOM instance was not found.")
        }
        do {
            let frames = try DicomWebFrameList(
                pathComponent: frameList,
                maximumLength: configuration.maximumFrameListLength,
                maximumCount: configuration.maximumFramesPerRequest
            )
            return try operation(instance, frames)
        } catch {
            return errorResponse(error)
        }
    }

    private func errorResponse(_ error: Error) -> DicomWebHTTPResponse {
        if error is DicomWebFrameList.ValidationError
            || error as? DicomWebFrameRouteError == .invalidFrameList {
            return stableError(statusCode: 400,
                               code: .invalidFrameList,
                               text: "Frame list must contain strictly increasing positive frame numbers.")
        }
        guard let error = error as? DicomWebFrameRouteError else {
            return stableError(statusCode: 500,
                               code: .renderingFailed,
                               text: "The frame request could not be completed.")
        }
        switch error {
        case .invalidFrameList:
            return stableError(statusCode: 400,
                               code: .invalidFrameList,
                               text: "Frame list must contain strictly increasing positive frame numbers.")
        case .frameNotFound:
            return stableError(statusCode: 404,
                               code: .frameNotFound,
                               text: "One or more requested frames were not found.")
        case .mediaTypeNotAcceptable:
            return stableError(statusCode: 406,
                               code: .mediaTypeNotAcceptable,
                               text: "No acceptable representation is available for the requested frames.")
        case .responseTooLarge:
            return stableError(statusCode: 413,
                               code: .frameResponseTooLarge,
                               text: "The requested frame response exceeds the configured size limit.")
        case .invalidRenderParameter:
            return stableError(statusCode: 400,
                               code: .invalidRenderParameter,
                               text: "One or more rendered-frame parameters are invalid or unsupported.")
        case .malformedPixelData:
            return stableError(statusCode: 422,
                               code: .malformedPixelData,
                               text: "The stored Pixel Data cannot produce a frame representation.")
        case .renderingFailed:
            return stableError(statusCode: 422,
                               code: .renderingFailed,
                               text: "The requested frame could not be rendered.")
        }
    }

    private func stableError(
        statusCode: Int,
        code: DicomWebServerErrorCode,
        text: String
    ) -> DicomWebHTTPResponse {
        DicomWebHTTPResponse(
            statusCode: statusCode,
            headers: [
                "Content-Type": "text/plain",
                "X-DICOMweb-Error-Code": code.rawValue
            ],
            body: Data(text.utf8)
        )
    }
}
