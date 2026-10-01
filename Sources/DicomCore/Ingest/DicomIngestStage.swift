import Foundation

public enum DicomIngestStage: String, Codable, CaseIterable, Sendable {
    case received, validated, staged, checksummed, published, registered
}

public enum DicomIngestError: Error, Equatable, Sendable, LocalizedError {
    case diskFull(required: Int64, available: Int64?)
    case permissionDenied(path: String)
    case invalidIdentity
    case checksumMismatch(path: String)
    /// The bytes handed to the ingest are not the bytes the caller inspected (its expected SHA-256).
    case contentChanged
    case missingFile(path: String)
    case invalidJournal
    case insufficientDurability(achieved: DicomDurabilityLevel, required: DicomDurabilityLevel)

    public var storageStatus: UInt16 {
        if case .diskFull = self { return 0xA700 }
        return 0xC000
    }

    public var errorDescription: String? {
        switch self {
        case .diskFull(let required, let available):
            if let available { return "Not enough disk space: \(required) bytes needed, \(available) available." }
            return "Not enough disk space: \(required) bytes needed."
        case .permissionDenied(let path): return "Permission denied writing to \(path)."
        case .invalidIdentity: return "The dataset's SOP Class/Instance UIDs do not match its file meta information."
        case .checksumMismatch(let path): return "The staged bytes at \(path) do not match the received bytes."
        case .contentChanged: return "The received bytes are not the bytes that were inspected."
        case .missingFile(let path): return "The ingest file at \(path) is missing."
        case .invalidJournal: return "The ingest journal entry is incomplete."
        case .insufficientDurability(let achieved, let required):
            return "The ingest reached \(achieved) durability, below the required \(required)."
        }
    }

    static func mapped(_ error: Error, path: URL, required: Int64 = 0) -> Error {
        if error is DicomIngestError || error is DicomIngestCrash { return error }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            if ns.code == Int(ENOSPC) { return Self.diskFull(required: required, available: nil) }
            if ns.code == Int(EACCES) || ns.code == Int(EPERM) { return Self.permissionDenied(path: path.path) }
        }
        if ns.domain == NSCocoaErrorDomain {
            if ns.code == NSFileWriteOutOfSpaceError { return Self.diskFull(required: required, available: nil) }
            if ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError {
                return Self.permissionDenied(path: path.path)
            }
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return mapped(underlying, path: path, required: required)
        }
        return error
    }
}

public struct DicomIngestCrash: Error, Sendable { public init() {} }

public struct DicomIngestResult: Sendable {
    public let record: DicomIngestRecord
    public let classification: DicomIngestClassification
    public let durability: DicomDurabilityLevel
}
