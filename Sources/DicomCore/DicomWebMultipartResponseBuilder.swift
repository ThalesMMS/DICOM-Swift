import Foundation

enum DicomWebMultipartResponseBuilder {
    struct Part: Sendable {
        let contentType: String
        let transferSyntaxUID: String?
        let contentLocation: URL
        let body: Data
    }

    struct Result: Sendable {
        let contentType: String
        let body: Data
    }

    static func build(
        parts: [Part],
        relatedType: String,
        relatedTransferSyntaxUID: String? = nil,
        maximumBytes: Int
    ) throws -> Result {
        guard !parts.isEmpty, maximumBytes > 0 else {
            throw DicomWebFrameRouteError.responseTooLarge
        }
        let boundary = "dicomweb-\(UUID().uuidString)"
        var body = Data()
        var writer = try DicomWebMultipartStreamWriter(boundary: boundary, maximumBytes: .max)

        for part in parts {
            guard headerValueIsSafe(part.contentType),
                  part.transferSyntaxUID.map(headerValueIsSafe) ?? true,
                  headerValueIsSafe(part.contentLocation.absoluteString) else {
                throw DicomWebFrameRouteError.malformedPixelData
            }
            var contentType = part.contentType
            if let transferSyntaxUID = part.transferSyntaxUID {
                contentType += "; transfer-syntax=\(transferSyntaxUID)"
            }
            try writer.beginPart(headers: [
                ("Content-Type", contentType), ("Content-Location", part.contentLocation.absoluteString)
            ], contentLength: part.body.count) { try append($0, to: &body, maximumBytes: maximumBytes) }
            try writer.payload(part.body) { try append($0, to: &body, maximumBytes: maximumBytes) }
            try writer.endPart { try append($0, to: &body, maximumBytes: maximumBytes) }
        }
        try writer.finish { try append($0, to: &body, maximumBytes: maximumBytes) }

        let syntaxParameter = relatedTransferSyntaxUID.map { "; transfer-syntax=\($0)" } ?? ""
        return Result(
            contentType: "multipart/related; type=\"\(relatedType)\"\(syntaxParameter); boundary=\(boundary)",
            body: body
        )
    }

    private static func append(_ data: Data, to destination: inout Data, maximumBytes: Int) throws {
        let total = destination.count.addingReportingOverflow(data.count)
        guard !total.overflow, total.partialValue <= maximumBytes else {
            throw DicomWebFrameRouteError.responseTooLarge
        }
        destination.append(data)
    }

    private static func headerValueIsSafe(_ value: String) -> Bool {
        !value.contains("\r") && !value.contains("\n")
    }
}
