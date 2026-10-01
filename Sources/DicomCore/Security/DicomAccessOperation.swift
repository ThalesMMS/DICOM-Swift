public enum DicomAccessOperation: String, Codable, CaseIterable, Sendable {
    case store, query, readMetadata, readBytes, export, route, derive, cacheRead, cacheWrite, delete, evict
    case receiveMessage, sendMessage
    case modifyProtection, configure, auditRead, auditExport, notify, workitemChange, subscribe
}
