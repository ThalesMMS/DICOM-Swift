import Foundation
import DicomData

/// Returning from receive supplies backpressure. A sink may write to disk or enforce its own memory budget.
public protocol DicomWebRetrieveSink: Sendable {
    func receive(_ event: DicomWebMultipartEvent) async throws
}

public actor DicomWebMemoryRetrieveSink: DicomWebRetrieveSink {
    private var parts: [DicomWebMultipartPart] = []
    private var total = 0
    private let maximumBytes: Int
    public init(maximumBytes: Int = 128 * 1024 * 1024) { self.maximumBytes = maximumBytes }
    public func receive(_ event: DicomWebMultipartEvent) throws {
        try Task.checkCancellation()
        switch event {
        case .partHeaders(let headers, let isRoot):
            var part = DicomWebMultipartPart(headers: headers, body: Data())
            part.isRoot = isRoot
            parts.append(part)
        case .payload(let data):
            guard !parts.isEmpty else { throw DicomWebMultipartStreamError.invalidState }
            guard data.count <= maximumBytes - total else { throw DicomWebError(kind: .tooLarge) }
            total += data.count
            parts[parts.count - 1].body.append(data)
        default: break
        }
    }
    public func result() -> [DicomWebMultipartPart] { parts }
}

/// Files have generated local names; untrusted Content-Location is retained only as metadata.
public actor DicomWebFileRetrieveSink: DicomWebRetrieveSink {
    public struct Part: Sendable {
        public let url: URL
        public let headers: [String: String]
        public var contentLocation: String? { headers.dicomWebHeaderValue("Content-Location") }
    }
    private let directory: URL
    private var handle: FileHandle?
    private var current: Part?
    private var completed: [Part] = []
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? handle?.close() }
    public func receive(_ event: DicomWebMultipartEvent) throws {
        try Task.checkCancellation()
        switch event {
        case .partHeaders(let headers, _):
            guard handle == nil else { throw DicomWebMultipartStreamError.invalidState }
            let url = directory.appendingPathComponent(UUID().uuidString + ".dcm")
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw DicomWebError(kind: .server) }
            handle = try FileHandle(forWritingTo: url)
            current = .init(url: url, headers: headers)
        case .payload(let data):
            guard let handle else { throw DicomWebMultipartStreamError.invalidState }
            try handle.write(contentsOf: data)
        case .partEnd:
            try handle?.close()
            handle = nil
            if let current { completed.append(current) }
            current = nil
        case .epilogue: break
        }
    }
    /// Removes only the incomplete part after a failed or cancelled retrieval.
    public func discardIncompletePart() {
        try? handle?.close()
        handle = nil
        if let current { try? FileManager.default.removeItem(at: current.url) }
        current = nil
    }
    public func result() -> [Part] { completed }
}

/// A part of a retrieve that arrived in another transfer syntax than the one asked for.
public struct DicomWebTransferSyntaxMismatch: Error, Equatable, LocalizedError, Sendable {
    public let expectedTransferSyntaxUID: String
    /// Nil when the part carries no readable File Meta Information.
    public let receivedTransferSyntaxUID: String?
    public var errorDescription: String? {
        guard let receivedTransferSyntaxUID else {
            return "The server sent a part without File Meta Information; transfer syntax \(expectedTransferSyntaxUID) was requested."
        }
        return "The server sent a part in transfer syntax \(receivedTransferSyntaxUID) instead of the requested \(expectedTransferSyntaxUID)."
    }
}

/// Passes events on to `sink` and refuses every part whose transfer syntax differs from the requested one. The
/// syntax is checked in both the Content-Type parameter (when concrete) and the File Meta Information, even when
/// the header matches. Missing or wildcard parameters use File Meta. An expected `*` accepts any File Meta syntax.
/// Only a bounded prefix is kept, never the part.
public actor DicomWebTransferSyntaxCheckingSink: DicomWebRetrieveSink {
    /// File Meta Information longer than this is refused as unreadable.
    static let maximumFileMetaBytes = 64 * 1024
    private let expected: String
    private let sink: any DicomWebRetrieveSink
    private var prefix = Data()
    private var decided = true
    private var declaredSyntax: String?

    public init(expectedTransferSyntaxUID: String, wrapping sink: any DicomWebRetrieveSink) {
        expected = expectedTransferSyntaxUID
        self.sink = sink
    }

    public func receive(_ event: DicomWebMultipartEvent) async throws {
        switch event {
        case .partHeaders(let headers, _):
            prefix = Data()
            decided = false
            declaredSyntax = nil
            if let declared = headers.dicomWebHeaderValue("Content-Type").flatMap({ try? DicomWebMediaType($0) })?
                .parameters["transfer-syntax"] {
                if declared != "*" {
                    try check(declared)
                    declaredSyntax = declared
                }
            }
        case .payload(let data) where !decided:
            prefix.append(data.prefix(Self.maximumFileMetaBytes - prefix.count))
            // A prefix ending at an element boundary is not yet the complete File Meta. Wait for the next group.
            if let meta = try? DicomPart10FileMetaParser.parse(prefix),
               prefix.count - meta.dataSetOffset >= 4, let received = meta.transferSyntaxUID {
                try checkFileMeta(received)
                decided = true
                prefix = Data()
            } else if prefix.count >= Self.maximumFileMetaBytes {
                throw DicomWebTransferSyntaxMismatch(expectedTransferSyntaxUID: expected, receivedTransferSyntaxUID: nil)
            }
        case .partEnd where !decided:
            guard let meta = try? DicomPart10FileMetaParser.parse(prefix), let received = meta.transferSyntaxUID,
                  prefix.count == meta.dataSetOffset || prefix.count - meta.dataSetOffset >= 4 else {
                throw DicomWebTransferSyntaxMismatch(expectedTransferSyntaxUID: expected, receivedTransferSyntaxUID: nil)
            }
            try checkFileMeta(received)
            decided = true
            prefix = Data()
        default: break
        }
        try await sink.receive(event)
    }

    private func checkFileMeta(_ received: String) throws {
        try check(received)
        if let declaredSyntax, received != declaredSyntax {
            throw DicomWebTransferSyntaxMismatch(expectedTransferSyntaxUID: declaredSyntax, receivedTransferSyntaxUID: received)
        }
    }

    private func check(_ received: String) throws {
        let received = received.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        guard dicomIsValidUID(received), expected == "*" || received == expected else {
            throw DicomWebTransferSyntaxMismatch(expectedTransferSyntaxUID: expected, receivedTransferSyntaxUID: received)
        }
    }
}
