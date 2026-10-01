import Foundation

/// A C-STORE dataset received straight into a Part 10 file (issue #2793), as the DCMTK storescp
/// `--bit-preserving` mode does: the preamble and a File Meta built from the command's identity first, then every
/// PDV fragment appended as it arrives, so the dataset bytes on disk are the ones sent and memory holds one PDU.
final class DicomReceivedPart10File {
    let url: URL
    /// Where the dataset starts in the file.
    let dataSetOffset: Int
    private let handle: FileHandle

    /// Nil for a dataset-deflate syntax, whose File Meta cannot be written ahead of an encoded dataset: such an
    /// object is received in memory.
    init?(directory: URL, sopClassUID: String, sopInstanceUID: String, transferSyntax: DicomTransferSyntax) throws {
        guard !transferSyntax.usesDataSetDeflate else { return nil }
        let header = try DicomDataSetWriter.part10Data(fromEncodedDataSet: Data(), transferSyntax: transferSyntax,
                                                       mediaStorageSOPClassUID: sopClassUID,
                                                       mediaStorageSOPInstanceUID: sopInstanceUID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("\(UUID().uuidString).received")
        guard FileManager.default.createFile(atPath: url.path, contents: header,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        do {
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        dataSetOffset = header.count
    }

    deinit { try? handle.close() }

    func append(_ fragment: Data) throws {
        try handle.write(contentsOf: fragment)
    }

    /// Closes the file and maps the dataset it holds.
    func finish() throws -> Data {
        try handle.close()
        return try DicomMappedFileData.data(contentsOf: url, from: dataSetOffset)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
