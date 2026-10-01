import Foundation

public struct DicomIngestMetadata: Sendable {
    public let studyInstanceUID: String
    public let seriesInstanceUID: String
    public let sopInstanceUID: String
    public let sopClassUID: String
    public let transferSyntaxUID: String
    public let dataSet: DicomDataSet
    public let attributes: [Int: String]

    // issue #2532: bounded range reads skip Pixel Data instead of loading a whole file for a preview.
    public static func read(at path: URL) async throws -> Self {
        let source = try await DicomByteSource.openFile(path)
        do {
            let metadata = try await read(from: source)
            await source.close()
            return metadata
        } catch { await source.close(); throw error }
    }

    static func read(from source: DicomByteSource) async throws -> Self {
        let metadata = try await DicomSourceMetadata.readPart10(from: source)
        let set = metadata.dataSet
        guard let study = set.string(for: .studyInstanceUID), !study.isEmpty,
              let series = set.string(for: .seriesInstanceUID), !series.isEmpty,
              let sop = set.string(for: .sopInstanceUID), !sop.isEmpty,
              let sopClass = set.string(for: .sopClassUID), !sopClass.isEmpty,
              metadata.fileMetaInformation.string(for: 0x00020003) == sop,
              metadata.fileMetaInformation.string(for: 0x00020002) == sopClass else {
            throw DicomIngestError.invalidIdentity
        }
        let tags = [0x00100010, 0x00100020, 0x00100021, 0x00100030, 0x00100040,
                    0x00080020, 0x00080030, 0x00080050, 0x00080060, 0x00080080,
                    0x00080090, 0x00081030, 0x0008103E, 0x00181030, 0x00200011, 0x00200013]
        return .init(studyInstanceUID: study, seriesInstanceUID: series, sopInstanceUID: sop,
                     sopClassUID: sopClass, transferSyntaxUID: metadata.transferSyntax.rawValue,
                     dataSet: set, attributes: Dictionary(uniqueKeysWithValues: tags.compactMap { tag in
                         set.string(for: tag).map { (tag, $0) }
                     }))
    }
}
