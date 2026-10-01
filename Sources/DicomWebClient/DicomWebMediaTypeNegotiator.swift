import Foundation
import DicomData

public enum DicomWebMediaTypeNegotiator {}

public protocol DicomWebTranscoding: Sendable {
    func canTranscode(from storedSyntaxUID: String, to requestedSyntaxUID: String) -> Bool
}

extension DicomWebMediaTypeNegotiator {
    public enum ResourceKind: Sendable { case instance, metadata, frames, rendered, thumbnail, bulkdata }
    public struct Representation: Equatable, Sendable {
        public let mediaType: String
        public let transferSyntaxUID: String?
        public let multipart: Bool
        public init(_ mediaType: String, transferSyntaxUID: String? = nil, multipart: Bool = false) {
            self.mediaType = mediaType
            self.transferSyntaxUID = transferSyntaxUID
            self.multipart = multipart
        }
        /// Multipart callers append their generated boundary to this value.
        public var contentType: String {
            let type = multipart ? "multipart/related; type=\"\(mediaType)\"" : mediaType
            return type + (transferSyntaxUID.map { "; transfer-syntax=\($0)" } ?? "")
        }
    }

    /// Only caller-supplied available representations are negotiated; no codec availability is invented.
    public static func select(accept: String?, resource: ResourceKind, available: [Representation],
                              storedSyntaxUID: String? = nil,
                              storedSyntaxUIDs: Set<String> = [],
                              transcoding: (any DicomWebTranscoding)? = nil) throws -> Representation {
        let ranges = DicomWebMediaType.split(accept ?? "*/*", separator: ",").compactMap { try? DicomWebMediaType($0) }
        var selected: (Representation, Double, Int, Int)?
        for candidate in available {
            guard allowed(candidate, resource: resource) else { continue }
            if resource == .instance {
                guard let storedSyntaxUID, let target = candidate.transferSyntaxUID,
                      target == storedSyntaxUID || storedSyntaxUIDs.contains(target)
                        || transcoding?.canTranscode(from: storedSyntaxUID, to: target) == true else { continue }
                // PS3.18 8.6.2.1 excludes implicit VR; Big Endian is not a web transfer syntax.
                guard target != "1.2.840.10008.1.2", target != "1.2.840.10008.1.2.2" else { continue }
            }
            var preference: (Double, Int, Int)?
            for (order, range) in ranges.enumerated() {
                let q = range.parameters["q"].flatMap(Double.init) ?? (range.parameters["q"] == nil ? 1 : -1)
                guard q >= 0, q <= 1 else { continue }
                let responseType = candidate.multipart ? "multipart/related" : candidate.mediaType
                let specificity: Int
                if range.type == responseType { specificity = 2 }
                else if range.type == "*/*" { specificity = 0 }
                else if range.type == responseType.components(separatedBy: "/")[0] + "/*" { specificity = 1 }
                else { continue }
                var parameterCount = 0
                var matches = true
                for (key, value) in range.parameters where key != "q" {
                    switch key {
                    case "type":
                        matches = matches && candidate.multipart && (value.lowercased() == candidate.mediaType || value == "*/*")
                    case "transfer-syntax":
                        matches = matches && candidate.transferSyntaxUID != nil && (value == "*" || value == candidate.transferSyntaxUID)
                    default: matches = false
                    }
                    parameterCount += 1
                }
                guard matches else { continue }
                // An omitted syntax parameter for DICOM instances means Explicit VR Little Endian.
                if resource == .instance, range.parameters["transfer-syntax"] == nil,
                   candidate.transferSyntaxUID != DicomTransferSyntax.explicitVRLittleEndian.rawValue { continue }
                let rank = specificity * 100 + parameterCount
                if preference == nil || rank > preference!.1 { preference = (q, rank, order) }
            }
            guard let preference, preference.0 > 0 else { continue }
            if selected == nil || preference.0 > selected!.1
                || (preference.0 == selected!.1 && preference.1 > selected!.2)
                || (preference.0 == selected!.1 && preference.1 == selected!.2 && preference.2 < selected!.3) {
                selected = (candidate, preference.0, preference.1, preference.2)
            }
        }
        guard let selected else { throw DicomWebError(kind: .notAcceptable) }
        return selected.0
    }

    public static var storeResponseAcceptHeader: String {
        "application/dicom+json, multipart/related; type=\"application/dicom+xml\""
    }

    public static func renderedFrameAcceptHeader(representationCount: Int) -> String {
        representationCount == 1 ? "image/png, image/jpeg" : "multipart/related; type=\"image/png\""
    }

    public static func acceptHeader(for resource: ResourceKind) -> String {
        switch resource {
        case .instance: return "multipart/related; type=\"application/dicom\"; transfer-syntax=*"
        case .metadata: return "application/dicom+json"
        case .frames: return "multipart/related; type=\"application/octet-stream\"; transfer-syntax=*"
        case .rendered, .thumbnail: return "image/jpeg, image/png, image/gif"
        case .bulkdata: return "application/octet-stream, multipart/related; type=\"application/octet-stream\""
        }
    }

    /// The Accept of a WADO-RS study, series or instance retrieve (PS3.18 8.7.3.5.2): `nil`, empty or `*` asks for
    /// the objects as stored, a UID asks for that transfer syntax. A value that is not a UID (PS3.5 9.1) is refused.
    public static func instanceAccept(transferSyntaxUID: String?) throws -> DicomWebMediaType {
        let uid = transferSyntaxUID?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !uid.isEmpty, uid != "*" else { return try DicomWebMediaType(acceptHeader(for: .instance)) }
        guard dicomIsValidUID(uid) else { throw DicomWebError(kind: .badRequest) }
        return try DicomWebMediaType("multipart/related; type=\"application/dicom\"; transfer-syntax=\(uid)")
    }

    private static func allowed(_ candidate: Representation, resource: ResourceKind) -> Bool {
        switch resource {
        case .instance: return candidate.multipart && candidate.mediaType == "application/dicom"
        case .metadata:
            return candidate.transferSyntaxUID == nil && ((candidate.mediaType == "application/dicom+json" && !candidate.multipart)
                || (candidate.mediaType == "application/dicom+xml" && candidate.multipart))
        case .rendered, .thumbnail:
            return candidate.transferSyntaxUID == nil && ["image/jpeg", "image/png", "image/gif"].contains(candidate.mediaType)
                && (resource != .thumbnail || !candidate.multipart)
        case .frames, .bulkdata:
            return (resource != .frames || candidate.multipart) && (["application/octet-stream", "application/x-deflate",
                "image/jpeg", "image/jls", "image/jp2", "image/jphc", "image/dicom-rle", "image/jxl"].contains(candidate.mediaType))
        }
    }
}
