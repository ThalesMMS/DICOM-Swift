import Foundation

public protocol DicomRepresentationResolving: Sendable {
    func representations(for sourceSOPInstanceUID: String) async throws -> DicomRepresentationSet?
    func representations(for file: URL) async throws -> DicomRepresentationSet?
    func bytes(for representation: DicomArchiveRepresentation) async throws -> Data
    /// The representation, checked against its content hash, as a request ready to send. A store backed by files
    /// maps the file, so that sending it never loads the object (issue #2834).
    func storeRequest(for representation: DicomArchiveRepresentation) async throws -> DicomStoreRequest
}

public extension DicomRepresentationResolving {
    func representations(for file: URL) async throws -> DicomRepresentationSet? {
        try await representations(for: DicomStoreRequest(part10FileAt: file).sopInstanceUID)
    }

    func storeRequest(for representation: DicomArchiveRepresentation) async throws -> DicomStoreRequest {
        let bytes = try await bytes(for: representation)
        guard DicomArchiveRepresentation.hash(bytes) == representation.contentSHA256 else {
            throw DicomRepresentationRefusal.sourceChanged
        }
        return try DicomStoreRequest(part10Data: bytes)
    }
}

public protocol DicomRepresentationStoring: DicomRepresentationResolving {
    /// Atomically validates lineage and the limit before publication. Returns the stored descriptor.
    func store(bytes: Data, representation: DicomArchiveRepresentation, derivativeLimit: Int, expectedRevision: UInt64?) async throws
        -> DicomArchiveRepresentation
    func generationRevision(for sourceSOPInstanceUID: String) async throws -> UInt64
    func invalidate(sourceSOPInstanceUID: String, reason: DicomArchiveRepresentation.UnavailableReason) async throws
}

public actor DicomInMemoryRepresentationStore: DicomRepresentationStoring {
    private var sets: [String: DicomRepresentationSet] = [:]
    private var revisions: [String: UInt64] = [:]
    private var payloads: [String: Data] = [:]
    public init() {}

    public func representations(for sourceSOPInstanceUID: String) -> DicomRepresentationSet? {
        sets[sourceSOPInstanceUID]
    }

    public func bytes(for representation: DicomArchiveRepresentation) throws -> Data {
        guard case .stored(let locator) = representation.availability,
              let current = sets[representation.sourceSOPInstanceUID]?.representations.first(where: {
                  $0.contentSHA256 == representation.contentSHA256 && $0.availability == representation.availability
              }), case .stored = current.availability,
              let bytes = payloads[locator] else { throw DicomRepresentationRefusal.missingBytes }
        return bytes
    }

    public func generationRevision(for sourceSOPInstanceUID: String) -> UInt64 { revisions[sourceSOPInstanceUID, default: 0] }

    public func store(bytes: Data, representation: DicomArchiveRepresentation, derivativeLimit: Int = .max, expectedRevision: UInt64? = nil) throws
        -> DicomArchiveRepresentation {
        if Task.isCancelled { throw DicomRepresentationRefusal.cancelled }
        guard DicomArchiveRepresentation.hash(bytes) == representation.contentSHA256 else {
            throw DicomRepresentationRefusal.invalidOutput
        }
        let request = try DicomStoreRequest(part10Data: bytes)
        guard request.sopInstanceUID == representation.representationSOPInstanceUID,
              request.transferSyntax == representation.transferSyntax else { throw DicomRepresentationRefusal.invalidOutput }
        let decoded = try DCMDecoder(data: bytes)
        guard DicomArchiveRepresentation.Geometry(decoded.dataSet) == representation.geometry,
              DicomArchiveRepresentation.quality(decoded.dataSet) == representation.quality else {
            throw DicomRepresentationRefusal.invalidOutput
        }
        if representation.kind == .lossyDerived {
            guard decoded.dataSet.string(for: .imageType) == "DERIVED",
                  decoded.dataSet.string(for: .derivationDescription)?.isEmpty == false,
                  decoded.dataSet.element(for: .sourceImageSequence)?.sequenceItems.contains(where: {
                      $0.dataSet.string(for: .referencedSOPInstanceUID) == representation.sourceSOPInstanceUID
                  }) == true else { throw DicomRepresentationRefusal.invalidOutput }
        }
        let uid = representation.sourceSOPInstanceUID
        if let expectedRevision, expectedRevision != revisions[uid, default: 0] {
            throw DicomRepresentationRefusal.sourceChanged
        }
        var items = sets[uid]?.representations ?? []
        if let existing = items.first(where: { $0.contentSHA256 == representation.contentSHA256 }) {
            guard existing.sourceContentSHA256 == representation.sourceContentSHA256,
                  existing.provenance.configurationHash == representation.provenance.configurationHash,
                  existing.codec == representation.codec else { throw DicomRepresentationRefusal.sourceChanged }
            if case .stored = existing.availability { return existing }
            items.removeAll { $0.contentSHA256 == existing.contentSHA256 }
        }
        if let original = sets[uid]?.original {
            guard representation.kind != .original else { throw DicomRepresentationRefusal.replacementNotAuthorized }
            guard original.contentSHA256 == representation.sourceContentSHA256 else {
                throw DicomRepresentationRefusal.sourceChanged
            }
        }
        if representation.kind != .original {
            guard items.filter({ $0.kind != .original }).count < derivativeLimit else {
                throw DicomRepresentationRefusal.limitReached
            }
        }
        var stored = representation
        let locator = UUID().uuidString
        stored.availability = .stored(locator)
        let updated = try DicomRepresentationSet(items + [stored])
        payloads[locator] = bytes; sets[uid] = updated
        return stored
    }

    public func invalidate(sourceSOPInstanceUID: String, reason: DicomArchiveRepresentation.UnavailableReason) throws {
        guard let set = sets[sourceSOPInstanceUID] else { return }
        revisions[sourceSOPInstanceUID, default: 0] &+= 1
        sets[sourceSOPInstanceUID] = try .init(set.representations.map {
            var item = $0
            if item.kind != .original {
                if case let .stored(locator) = item.availability { payloads.removeValue(forKey: locator) }
                item.availability = .unavailable(reason)
            }
            return item
        })
    }

    /// Host supplies current configuration and codec identity; mismatching alternates remain visible as stale.
    public func invalidateStale(sourceSOPInstanceUID: String, sourceContentSHA256: String,
                                configurationHash: String, codec: DicomArchiveRepresentation.Codec) throws {
        guard let set = sets[sourceSOPInstanceUID] else { return }
        revisions[sourceSOPInstanceUID, default: 0] &+= 1
        sets[sourceSOPInstanceUID] = try .init(set.representations.map {
            var item = $0
            if item.kind != .original && (item.sourceContentSHA256 != sourceContentSHA256
                || item.provenance.configurationHash != configurationHash || item.codec != codec) {
                if case let .stored(locator) = item.availability { payloads.removeValue(forKey: locator) }
                item.availability = .unavailable(.stale)
            }
            return item
        })
    }
}
