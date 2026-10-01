import CryptoKit
import Foundation

/// Metadata only: no patient attributes or source paths belong in this descriptor.
public struct DicomArchiveRepresentation: Equatable, Sendable {
    public enum Kind: Int, Sendable { case original, losslessEquivalent, lossyDerived }
    public enum UnavailableReason: String, Sendable { case stale, missing, invalidated, codecUnavailable }
    public enum Availability: Equatable, Sendable {
        /// An opaque store-owned key, never a patient-derived filename.
        case stored(String), generatable, unavailable(UnavailableReason)
    }
    public struct Codec: Equatable, Sendable {
        public let family: String
        public let identifier: String
        public let version: String
        public init(family: String, identifier: String, version: String) {
            self.family = family; self.identifier = identifier; self.version = version
        }
    }
    public struct Parameters: Equatable, Sendable {
        public let intent: DicomEncodingIntent
        public init(intent: DicomEncodingIntent = .reversible) { self.intent = intent }
        public var hash: String {
            let fields: [String]
            switch intent {
            case .reversible: fields = ["reversible"]
            case .irreversible(let quality): fields = ["irreversible", String(quality)]
            case .jpegLSNearLossless(let near): fields = ["near", String(near)]
            case .jpegLossless(let o):
                fields = ["jpeg", String(o.predictor), String(o.pointTransform), String(o.restartIntervalRows)]
            case .jpegLS(let o):
                fields = ["jls", String(o.near), o.interleave?.rawValue ?? "default", String(o.restartIntervalLines)]
            case .jpegXL(let o):
                fields = ["jxl", String(o.distance), String(o.effort), String(o.gaborish), String(o.adaptiveQuantization)]
            }
            return DicomArchiveRepresentation.hash(Data(fields.joined(separator: "|").utf8))
        }
    }
    public enum Quality: Equatable, Sendable {
        case lossless
        /// Histories include every inherited lossy step, even in a lossless encoding.
        case lossy(ratios: [Double], methods: [String])
    }
    public struct Geometry: Equatable, Sendable {
        public let rows: Int
        public let columns: Int
        public let frames: Int
        public let samples: Int
        public let bitsAllocated: Int
        public let bitsStored: Int
        public let photometric: String
        public init(rows: Int, columns: Int, frames: Int = 1, samples: Int = 1,
                    bitsAllocated: Int = 8, bitsStored: Int = 8, photometric: String = "MONOCHROME2") {
            self.rows = rows; self.columns = columns; self.frames = frames; self.samples = samples
            self.bitsAllocated = bitsAllocated; self.bitsStored = bitsStored; self.photometric = photometric
        }
        init(_ set: DicomDataSet) {
            self.init(rows: Int(set.string(for: .rows) ?? "") ?? 0,
                      columns: Int(set.string(for: .columns) ?? "") ?? 0,
                      frames: Int(set.string(for: .numberOfFrames) ?? "") ?? 1,
                      samples: Int(set.string(for: .samplesPerPixel) ?? "") ?? 1,
                      bitsAllocated: Int(set.string(for: .bitsAllocated) ?? "") ?? 0,
                      bitsStored: Int(set.string(for: .bitsStored) ?? "") ?? 0,
                      photometric: set.string(for: .photometricInterpretation) ?? "")
        }
    }
    public struct Provenance: Equatable, Sendable {
        public let createdAt: Date
        public let creatorIdentifier: String
        public let sourceFingerprint: String
        public let configurationHash: String
        public let toolkitVersion: String
        public init(createdAt: Date, creatorIdentifier: String, sourceFingerprint: String,
                    configurationHash: String, toolkitVersion: String) {
            self.createdAt = createdAt; self.creatorIdentifier = creatorIdentifier
            self.sourceFingerprint = sourceFingerprint; self.configurationHash = configurationHash
            self.toolkitVersion = toolkitVersion
        }
    }
    public let kind: Kind
    public let sourceSOPInstanceUID: String
    public let representationSOPInstanceUID: String
    public let transferSyntax: DicomTransferSyntax
    public let contentSHA256: String
    public let sourceContentSHA256: String
    public let codec: Codec
    public let parameters: Parameters
    public let quality: Quality
    public let geometry: Geometry
    public let provenance: Provenance
    public var availability: Availability

    public init(kind: Kind, sourceSOPInstanceUID: String, representationSOPInstanceUID: String,
                transferSyntax: DicomTransferSyntax, contentSHA256: String, sourceContentSHA256: String,
                codec: Codec, parameters: Parameters, quality: Quality, geometry: Geometry,
                provenance: Provenance, availability: Availability) {
        self.kind = kind; self.sourceSOPInstanceUID = sourceSOPInstanceUID
        self.representationSOPInstanceUID = representationSOPInstanceUID; self.transferSyntax = transferSyntax
        self.contentSHA256 = contentSHA256; self.sourceContentSHA256 = sourceContentSHA256
        self.codec = codec; self.parameters = parameters; self.quality = quality; self.geometry = geometry
        self.provenance = provenance; self.availability = availability
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 1_024 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func quality(_ set: DicomDataSet) -> Quality {
        guard set.string(for: 0x00282110) == "01" else { return .lossless }
        return .lossy(ratios: set.strings(for: 0x00282112).compactMap { Double($0) },
                      methods: set.strings(for: 0x00282114))
    }
}
