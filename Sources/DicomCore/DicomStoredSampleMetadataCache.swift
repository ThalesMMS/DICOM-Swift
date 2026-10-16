import Foundation

/// The frame metadata of the direct native read (issue #3111), shared by the objects of a series whose headers differ
/// only in per-instance identity, time and position, so the header of each slice is not written and parsed again.
///
/// The key is the source header without `instanceTags`, which the frame metadata never reads. An entry is reused only
/// when it describes the same frame of a header that writes the same way: the declared character set is absent or
/// supported, and every per-instance element of both objects encodes on its own (`DicomSingleFramePart10Writer` then
/// keeps or drops the same metadata elements for both). Anything else is written and parsed per frame.
final class DicomStoredSampleMetadataCache: @unchecked Sendable {
    struct Key: Equatable {
        let dataSet: DicomDataSet
        let transferSyntax: DicomTransferSyntax
        let frameCount: Int
        /// The frame, when per-frame functional groups make each frame's header different; nil otherwise.
        let perFrame: Int?
        let rows: Int
        let columns: Int
    }

    static let shared = DicomStoredSampleMetadataCache()

    /// Per-instance identity, time and position: (0008,0012/0013) instance creation, (0008,0018) SOP Instance UID,
    /// (0008,0022/0023/0032/0033) acquisition and content date and time, (0020,0012) Acquisition Number, (0020,0013)
    /// Instance Number, (0020,0032) Image Position (Patient), (0020,1041) Slice Location.
    static let instanceTags = [0x0008_0012, 0x0008_0013, 0x0008_0018, 0x0008_0022, 0x0008_0023, 0x0008_0032,
                               0x0008_0033, 0x0020_0012, 0x0020_0013, 0x0020_0032, 0x0020_1041]

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [(key: Key, metadata: DicomDecodedFrameMetadata)] = []

    init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    /// The key of `frame` of an object, or nil when its header may write differently from another object with the
    /// same key.
    static func key(dataSet: DicomDataSet, transferSyntax: DicomTransferSyntax, frameCount: Int, frame: Int,
                    rows: Int, columns: Int) -> Key? {
        let declared = dataSet.element(for: .specificCharacterSet)
        if let declared {
            guard (try? DicomSpecificCharacterSet(definedTerms: declared.stringValues).validateDeclaration()) != nil else {
                return nil
            }
        }
        var keyed = dataSet
        for tag in instanceTags {
            guard let element = dataSet.element(for: tag) else { continue }
            let alone = DicomDataSet(elements: [declared, element].compactMap { $0 })
            guard (try? DicomDataSetWriter.dataSetData(from: alone)) != nil else { return nil }
            keyed.remove(tag)
        }
        for tag in [DicomTag.pixelData.rawValue, 0x7FE0_0008, 0x7FE0_0009] { keyed.remove(tag) }
        let perFrame = dataSet[.perFrameFunctionalGroupsSequence] == nil ? nil : frame
        return Key(dataSet: keyed, transferSyntax: transferSyntax, frameCount: frameCount, perFrame: perFrame,
                   rows: rows, columns: columns)
    }

    func metadata(for key: Key) -> DicomDecodedFrameMetadata? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.lastIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.metadata
    }

    func insert(_ metadata: DicomDecodedFrameMetadata, for key: Key) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.key == key }
        entries.append((key, metadata))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}
