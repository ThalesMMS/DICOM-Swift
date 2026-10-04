import Foundation

/// Reads a DICOM JSON document (PS3.18 F.2) one data set at a time as its bytes arrive, as dcm4che's
/// `JSONReader.readDatasets` does. Only the data set being read is held, so `DecodingOptions.maximumBytes`
/// bounds each data set rather than the whole document. The root is an array of objects or a single object.
public struct DicomJSONStreamDecoder: Sendable {
    private enum State: Sendable { case root, firstEntry, entry, object, afterEntry, end }

    private let options: DicomJSONCodec.DecodingOptions
    private var state = State.root
    private var singleObject = false
    private var pending = Data()
    private var depth = 0
    private var inString = false
    private var escaped = false

    public init(options: DicomJSONCodec.DecodingOptions = .init()) {
        self.options = options
    }

    /// The data sets completed by `chunk`, in document order.
    public mutating func feed(_ chunk: Data) throws -> [DicomJSONCodec.Decoded] {
        var objects: [Data] = []
        try chunk.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var start = 0
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                switch state {
                case .object:
                    if inString {
                        if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                    } else if byte == 0x22 {
                        inString = true
                    } else if byte == 0x7B || byte == 0x5B {
                        depth += 1
                    } else if byte == 0x7D || byte == 0x5D {
                        depth -= 1
                        if depth == 0 {
                            try append(bytes[start...index])
                            objects.append(pending)
                            pending = Data()
                            state = singleObject ? .end : .afterEntry
                        }
                    }
                case .root, .firstEntry, .entry, .afterEntry, .end:
                    guard !Self.isWhitespace(byte) else { break }
                    switch (state, byte) {
                    case (.root, 0x5B): state = .firstEntry
                    case (.root, 0x7B), (.firstEntry, 0x7B), (.entry, 0x7B):
                        singleObject = state == .root
                        state = .object
                        depth = 1
                        start = index
                    case (.firstEntry, 0x5D), (.afterEntry, 0x5D): state = .end
                    case (.afterEntry, 0x2C): state = .entry
                    case (.root, _): throw DicomJSONCodec.Error.invalidDocument("root must be an object or an array of objects")
                    case (.firstEntry, _), (.entry, _): throw DicomJSONCodec.Error.invalidDocument("array entries must be objects")
                    default: throw DicomJSONCodec.Error.invalidDocument("not valid JSON")
                    }
                }
                index += 1
            }
            if state == .object { try append(bytes[start...]) }
        }
        return try objects.map(decode)
    }

    /// Checks that the document ended where it should. An empty document holds no data set.
    public mutating func finish() throws {
        guard state == .end || state == .root else { throw DicomJSONCodec.Error.invalidDocument("not valid JSON") }
        state = .end
    }

    private mutating func append(_ bytes: Slice<UnsafeRawBufferPointer>) throws {
        let count = pending.count + bytes.count
        guard count <= options.maximumBytes else {
            throw DicomJSONCodec.Error.inputTooLarge(byteCount: count, limit: options.maximumBytes)
        }
        pending.append(contentsOf: bytes)
    }

    private func decode(_ object: Data) throws -> DicomJSONCodec.Decoded {
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: object) } catch {
            throw DicomJSONCodec.Error.invalidDocument("not valid JSON")
        }
        guard let dictionary = root as? [String: Any] else {
            throw DicomJSONCodec.Error.invalidDocument("array entries must be objects")
        }
        return try DicomJSONCodec.decode(object: dictionary, options: options)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}
