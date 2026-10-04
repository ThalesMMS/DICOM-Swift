import Foundation

public typealias DicomWebInMemoryStore = DicomWebInMemoryStorage

public final class DicomWebInMemoryStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let reportsDurability: Bool
    private var storage: [String: DicomWebStoredInstance] = [:]
    private var conflicts: [DicomWebStoredInstance] = []
    private var orderedInstanceUIDs: [String] = []
    private var studyInstanceCounts: [String: Int] = [:]
    private var studySeriesIDs: [String: Set<String>] = [:]
    private var studyModalities: [String: Set<String>] = [:]
    private var seriesInstanceCounts: [[String]: Int] = [:]

    public func conflictingInstances() -> [DicomWebStoredInstance] { lock.withLock { conflicts } }

    public convenience init(instances: [DicomWebStoredInstance] = []) {
        self.init(instances: instances, reportsDurability: false)
    }

    public init(instances: [DicomWebStoredInstance] = [], reportsDurability: Bool) {
        self.reportsDurability = reportsDurability
        for instance in instances {
            if let prior = storage[instance.sopInstanceUID] {
                if prior.part10Data != instance.part10Data { conflicts.append(instance) }
            } else { insert(instance) }
        }
    }

    @discardableResult
    public func add(dataSet: DicomDataSet,
                    part10Data: Data? = nil,
                    transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian) throws -> DicomWebStoredInstance {
        let normalized = Self.normalizedDataSet(dataSet)
        let data = try part10Data ?? DicomDataSetWriter.part10Data(
            from: normalized.dataSet,
            options: DicomPart10WriterOptions(transferSyntax: transferSyntax,
                                              mediaStorageSOPClassUID: normalized.sopClassUID,
                                              mediaStorageSOPInstanceUID: normalized.sopInstanceUID)
        )
        let instance = DicomWebStoredInstance(dataSet: normalized.dataSet,
                                             part10Data: data,
                                             studyInstanceUID: normalized.studyInstanceUID,
                                             seriesInstanceUID: normalized.seriesInstanceUID,
                                             sopInstanceUID: normalized.sopInstanceUID,
                                             sopClassUID: normalized.sopClassUID,
                                             transferSyntax: transferSyntax)
        lock.lock()
        if let prior = storage[instance.sopInstanceUID] {
            if prior.part10Data != instance.part10Data { conflicts.append(instance) }
        } else { insert(instance) }
        lock.unlock()
        return instance
    }

    @discardableResult
    public func add(part10Data: Data,
                    transferSyntax: DicomTransferSyntax? = nil) throws -> DicomWebStoredInstance {
        let meta = try DicomPart10FileMetaParser.parse(part10Data)
        guard let uid = meta.transferSyntaxUID, let syntax = DicomTransferSyntax(rawValue: uid),
              transferSyntax == nil || transferSyntax == syntax else {
            throw DicomWebError(kind: .unsupportedMediaType)
        }
        let dataSet = try Self.dataSet(fromPart10Data: part10Data, dataSetOffset: meta.dataSetOffset, syntax: syntax)
        let normalized = Self.normalizedDataSet(dataSet)
        let instance = DicomWebStoredInstance(dataSet: normalized.dataSet,
                                             part10Data: part10Data,
                                             studyInstanceUID: normalized.studyInstanceUID,
                                             seriesInstanceUID: normalized.seriesInstanceUID,
                                             sopInstanceUID: normalized.sopInstanceUID,
                                             sopClassUID: normalized.sopClassUID,
                                             transferSyntax: syntax)
        lock.lock()
        if let prior = storage[instance.sopInstanceUID] {
            if prior.part10Data != instance.part10Data { conflicts.append(instance) }
        } else { insert(instance) }
        lock.unlock()
        return instance
    }

    public func allInstances() -> [DicomWebStoredInstance] {
        lock.lock()
        let values = Array(storage.values)
        lock.unlock()
        return values.sorted { $0.sopInstanceUID < $1.sopInstanceUID }
    }

    public func instances(studyInstanceUID: String) -> [DicomWebStoredInstance] {
        allInstances().filter { $0.studyInstanceUID == studyInstanceUID }
    }

    public func instance(studyInstanceUID: String,
                         seriesInstanceUID: String,
                         sopInstanceUID: String) -> DicomWebStoredInstance? {
        lock.lock()
        let value = storage[sopInstanceUID]
        lock.unlock()
        guard value?.studyInstanceUID == studyInstanceUID,
              value?.seriesInstanceUID == seriesInstanceUID else {
            return nil
        }
        return value
    }

    public var count: Int {
        lock.lock()
        let value = storage.count
        lock.unlock()
        return value
    }

    /// Called only during initialization or while holding the storage lock.
    private func insert(_ instance: DicomWebStoredInstance) {
        storage[instance.sopInstanceUID] = instance
        var low = 0, high = orderedInstanceUIDs.count
        while low < high {
            let middle = low + (high - low) / 2
            if orderedInstanceUIDs[middle] < instance.sopInstanceUID { low = middle + 1 }
            else { high = middle }
        }
        orderedInstanceUIDs.insert(instance.sopInstanceUID, at: low)
        studyInstanceCounts[instance.studyInstanceUID, default: 0] += 1
        studySeriesIDs[instance.studyInstanceUID, default: []].insert(instance.seriesInstanceUID)
        if let modality = instance.dataSet.string(for: .modality) {
            studyModalities[instance.studyInstanceUID, default: []].insert(modality)
        }
        seriesInstanceCounts[[instance.studyInstanceUID, instance.seriesInstanceUID], default: 0] += 1
    }

    private static func normalizedDataSet(_ dataSet: DicomDataSet) -> (
        dataSet: DicomDataSet,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String,
        sopClassUID: String
    ) {
        var copy = dataSet
        let studyUID = dataSet.string(for: .studyInstanceUID)?.dicomWebNonEmpty ?? DicomDataSetWriter.makeUID()
        let seriesUID = dataSet.string(for: .seriesInstanceUID)?.dicomWebNonEmpty ?? DicomDataSetWriter.makeUID()
        let sopUID = dataSet.string(for: .sopInstanceUID)?.dicomWebNonEmpty ?? DicomDataSetWriter.makeUID()
        let sopClassUID = dataSet.string(for: .sopClassUID)?.dicomWebNonEmpty ??
            DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID

        copy.set(dicomWebStringElement(DicomTag.studyInstanceUID.rawValue, .UI, studyUID))
        copy.set(dicomWebStringElement(DicomTag.seriesInstanceUID.rawValue, .UI, seriesUID))
        copy.set(dicomWebStringElement(DicomTag.sopInstanceUID.rawValue, .UI, sopUID))
        copy.set(dicomWebStringElement(DicomTag.sopClassUID.rawValue, .UI, sopClassUID))
        return (copy, studyUID, seriesUID, sopUID, sopClassUID)
    }

    private static func dataSet(fromPart10Data data: Data, dataSetOffset: Int,
                                syntax: DicomTransferSyntax) throws -> DicomDataSet {
        var set = try DicomDataSetParser.read(from: Data(data.dropFirst(dataSetOffset)), transferSyntax: syntax).dataSet
        if let decoder = try? DCMDecoder(data: data), let descriptor = decoder.pixelDataDescriptor {
            let start = descriptor.pixelDataOffset, end = descriptor.pixelDataOffset + descriptor.totalPixelBytes
            if start >= 0, end <= data.count {
                set.set(.init(tag: 0x7FE00010, vr: descriptor.bitsAllocated > 8 ? .OW : .OB,
                              value: .bytes(Data(data[start..<end]))))
            }
        }
        return set
    }

}

func dicomWebStringElement(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return DicomDataElement(tag: tag, vr: vr, value: trimmed.isEmpty ? .empty : .strings([trimmed]))
}

extension String {
    var dicomWebNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension DicomWebInMemoryStorage: DicomWebStorageProviding {
    public func searchStudies(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] {
        try search(parameters, key: .studyInstanceUID)
    }
    public func searchSeries(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] {
        try search(parameters, key: .seriesInstanceUID)
    }
    public func searchInstances(parameters: DicomWebSearchParameters) async throws -> [DicomDataSet] {
        try search(parameters, key: .sopInstanceUID)
    }
    private func search(_ parameters: DicomWebSearchParameters, key: DicomTag) throws -> [DicomDataSet] {
        var identifier = DicomDataSet()
        // A key with several values matches when any one of them does. UID lists are matched that way by the
        // matcher itself; every other list becomes one single-valued identifier per value.
        var alternatives: [[DicomDataSet]] = []
        for match in parameters.matches {
            guard let tag = DicomWebSearchAttributes.tag(match.attribute) else { throw DicomWebError(kind: .badRequest) }
            if match.vr != .UI, match.values.count > 1 {
                alternatives.append(match.values.map {
                    DicomDataSet(elements: [.init(tag: tag, vr: match.vr, value: .strings([$0]))])
                })
            } else {
                identifier.set(.init(tag: tag, vr: match.vr, value: .strings(match.values)))
            }
        }
        let limit = max(0, parameters.limit ?? Int.max)
        guard limit > 0 else { return [] }
        return try lock.withLock {
            var offset = max(0, parameters.offset ?? 0)
            var seen: Set<String> = []
            var selected: [DicomDataSet] = []
            for uid in orderedInstanceUIDs {
                try Task.checkCancellation()
                guard let instance = storage[uid],
                      parameters.studyInstanceUID == nil || parameters.studyInstanceUID == instance.studyInstanceUID,
                      parameters.seriesInstanceUID == nil || parameters.seriesInstanceUID == instance.seriesInstanceUID else { continue }
                var set = instance.dataSet.removing(.pixelData)
                if key == .studyInstanceUID {
                    set.set(.init(tag: 0x00201206, vr: .IS,
                                  value: .strings([String(studySeriesIDs[instance.studyInstanceUID]?.count ?? 0)])))
                    set.set(.init(tag: 0x00201208, vr: .IS,
                                  value: .strings([String(studyInstanceCounts[instance.studyInstanceUID] ?? 0)])))
                    set.set(.init(tag: DicomTag.modalitiesInStudy.rawValue, vr: .CS,
                                  value: .strings(studyModalities[instance.studyInstanceUID]?.sorted() ?? [])))
                }
                if key == .seriesInstanceUID {
                    set.set(.init(tag: 0x00201209, vr: .IS,
                                  value: .strings([String(seriesInstanceCounts[[instance.studyInstanceUID, instance.seriesInstanceUID]] ?? 0)])))
                }
                let matcher = DicomQueryMatcher()
                guard try matcher.matches(set, identifier: identifier),
                      try alternatives.allSatisfy({ try $0.contains { try matcher.matches(set, identifier: $0) } }),
                      seen.insert(set.string(for: key) ?? "").inserted else { continue }
                if offset > 0 { offset -= 1; continue }
                selected.append(set)
                if selected.count == limit { break }
            }
            return selected
        }
    }
    public func metadata(study: String, series: String?, instance: String?) async throws -> [DicomDataSet] {
        allInstances().filter { $0.studyInstanceUID == study && (series == nil || $0.seriesInstanceUID == series)
            && (instance == nil || $0.sopInstanceUID == instance) }.map(\.dataSet)
    }
    public func instance(study: String, series: String, instance: String) async throws -> DicomWebStoredInstance {
        guard let found = self.instance(studyInstanceUID: study, seriesInstanceUID: series, sopInstanceUID: instance) else {
            throw DicomWebServerFailure(404, "Instance not found.")
        }
        return found
    }
    public func bulkData(uri: String) async throws -> Data {
        let parts = uri.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts.count.isMultiple(of: 2), let tag = Int(parts.last!, radix: 16) else {
            throw DicomWebServerFailure(404, "Bulk data not found.")
        }
        let stored = try await instance(study: parts[0], series: parts[1], instance: parts[2])
        var set = stored.dataSet
        for offset in stride(from: 3, to: parts.count - 1, by: 2) {
            guard let sequence = Int(parts[offset], radix: 16), let index = Int(parts[offset + 1]),
                  index >= 0, index < set.sequenceItems(for: sequence).count else {
                throw DicomWebServerFailure(404, "Bulk data not found.")
            }
            set = set.sequenceItems(for: sequence)[index].dataSet
        }
        guard let element = set[tag] else { throw DicomWebServerFailure(404, "Bulk data not found.") }
        return try DicomDataSetRepresentation.binaryValueBytes(of: element)
    }
    public func store(instances: [DicomWebStoredInstance]) async throws -> [DicomWebStorageResult] {
        instances.map { instance in
            lock.withLock {
                var warning: Int?
                if let prior = storage[instance.sopInstanceUID] {
                    if DicomArchiveRepresentation.hash(prior.part10Data) != DicomArchiveRepresentation.hash(instance.part10Data) {
                        conflicts.append(instance)
                        // The retained conflict is accepted while the original stays canonical (issue #2529).
                        warning = 0xB000
                    }
                } else { insert(instance) }
                return .init(sopClassUID: instance.sopClassUID, sopInstanceUID: instance.sopInstanceUID,
                             warningReason: warning, durability: reportsDurability ? .receivedInMemory : nil)
            }
        }
    }
}
