import DicomData
import Foundation

/// Decodes the narrow legacy envelope without searching inside DICOM values. Only a delimiter
/// at a top-level element boundary can terminate a part; undefined sequences and encapsulated
/// fragments must close first. No payload bytes are rewritten or inferred from MIME text.
struct DicomWebLegacyMultipartDecoder: Sendable {
    private enum State { case headers, fileMeta, element, value, delimiter, epilogue, finished }
    private enum Container { case sequence, item, fragments }
    private var state = State.headers
    private var buffer: [UInt8] = []
    private var cursor = 0
    private let marker: [UInt8]
    private let limits: DicomWebMultipartLimits
    private var total = 0
    private var count = 0
    private var partBytes = 0
    private var pendingPayload = Data()
    private var declaredLength: Int?
    private var metaOffset = 132
    private var syntax = DicomTransferSyntax.explicitVRLittleEndian
    private var stack: [Container] = []
    private var remaining = 0
    private var elements = 0
    private var headers: [String: String] = [:]
    private var headerSearchOffset = 0
    private var metaTags: Set<UInt32> = []
    private static let longVRs: Set<String> = ["OB", "OD", "OF", "OL", "OV", "OW", "SQ", "SV", "UC", "UN", "UR", "UT", "UV"]
    private static let shortVRs: Set<String> = ["AE", "AS", "AT", "CS", "DA", "DS", "DT", "FD", "FL", "IS", "LO", "LT", "PN", "SH", "SL", "SS", "ST", "TM", "UI", "UL", "US"]

    init(boundary: String, limits: DicomWebMultipartLimits) {
        marker = Array("--\(boundary)".utf8)
        self.limits = limits
    }

    mutating func feed(_ chunk: Data) throws -> [DicomWebMultipartEvent] {
        try Task.checkCancellation()
        guard state != .finished else { throw DicomWebMultipartStreamError.invalidState }
        try budget(total, adding: chunk.count, limit: limits.maximumTotalBytes, name: "maximumTotalBytes")
        total += chunk.count
        var events: [DicomWebMultipartEvent] = []
        for offset in stride(from: 0, to: chunk.count, by: 16 * 1024) {
            try Task.checkCancellation()
            if cursor > 0 { buffer.removeFirst(cursor); cursor = 0 }
            buffer.append(contentsOf: chunk.dropFirst(offset).prefix(16 * 1024))
            try drain(finishing: false, into: &events)
        }
        return events
    }

    mutating func finish() throws -> [DicomWebMultipartEvent] {
        try Task.checkCancellation()
        guard state != .finished else { throw DicomWebMultipartStreamError.invalidState }
        var events: [DicomWebMultipartEvent] = []
        try drain(finishing: true, into: &events)
        guard state == .epilogue else { throw DicomWebMultipartStreamError.missingFinalDelimiter }
        state = .finished
        return events
    }

    private var available: Int { buffer.count - cursor }
    private func budget(_ value: Int, adding: Int, limit: Int, name: String) throws {
        guard value <= limit, adding <= limit - value else {
            throw DicomWebMultipartStreamError.limitExceeded(name, limit: limit)
        }
    }
    private func unsafe() -> DicomWebMultipartStreamError { .unsafeLegacyFraming }
    private func uint(_ offset: Int, _ width: Int, little: Bool = true) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<width {
            value |= UInt32(buffer[cursor + offset + index]) << (8 * (little ? index : width - index - 1))
        }
        return value
    }
    private func vr(_ offset: Int) -> String { String(bytes: buffer[(cursor + offset)..<(cursor + offset + 2)], encoding: .ascii) ?? "" }
    private mutating func payload(_ size: Int, into events: inout [DicomWebMultipartEvent]) throws {
        try budget(partBytes, adding: size, limit: limits.maximumPartBytes, name: "maximumPartBytes")
        if let declaredLength, size > declaredLength - partBytes { throw unsafe() }
        let end = cursor + size
        while cursor < end {
            let next = min(end, cursor + 16 * 1024 - pendingPayload.count)
            pendingPayload.append(contentsOf: buffer[cursor..<next])
            cursor = next
            if pendingPayload.count == 16 * 1024 {
                events.append(.payload(pendingPayload))
                pendingPayload = Data()
            }
        }
        partBytes += size
    }

    private mutating func endPart(into events: inout [DicomWebMultipartEvent]) {
        if !pendingPayload.isEmpty {
            events.append(.payload(pendingPayload))
            pendingPayload = Data()
        }
        events.append(.partEnd)
    }

    private mutating func drain(finishing: Bool, into events: inout [DicomWebMultipartEvent]) throws {
        while available > 0 {
            try Task.checkCancellation()
            switch state {
            case .headers:
                let searchStart = cursor + headerSearchOffset
                guard let end = (searchStart..<buffer.count).first(where: { index in
                    index + 3 < buffer.count && buffer[index..<index + 4].elementsEqual([13, 10, 13, 10])
                }) else {
                    try budget(0, adding: available, limit: limits.maximumHeaderBytes, name: "maximumHeaderBytes")
                    headerSearchOffset = max(0, available - 3)
                    return
                }
                try budget(0, adding: end - cursor, limit: limits.maximumHeaderBytes, name: "maximumHeaderBytes")
                guard let text = String(bytes: buffer[cursor..<end], encoding: .ascii),
                      text.lowercased().hasPrefix("content-type:") else { throw unsafe() }
                headers = [:]
                headerSearchOffset = 0
                metaTags = []
                for line in text.components(separatedBy: "\r\n") {
                    guard let colon = line.firstIndex(of: ":") else { throw unsafe() }
                    let name = String(line[..<colon]).lowercased()
                    guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                          headers[name] == nil else { throw unsafe() }
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    guard value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw unsafe() }
                    headers[name] = value
                }
                guard let type = headers["content-type"], (try? DicomWebMediaType(type))?.type == "application/dicom",
                      headers["content-transfer-encoding"] == nil else { throw unsafe() }
                declaredLength = nil
                if let value = headers["content-length"] {
                    guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(value) else { throw unsafe() }
                    declaredLength = length
                }
                try budget(count, adding: 1, limit: limits.maximumPartCount, name: "maximumPartCount")
                count += 1
                partBytes = 0
                elements = 0
                metaOffset = 132
                cursor = end + 4
                state = .fileMeta
            case .fileMeta:
                guard available >= 132 else { return }
                guard buffer[(cursor + 128)..<(cursor + 132)].elementsEqual("DICM".utf8) else { throw unsafe() }
                while available >= metaOffset + 8 {
                    guard uint(metaOffset, 2) == 2 else { break }
                    let code = vr(metaOffset + 4)
                    let long = Self.longVRs.contains(code)
                    guard long || Self.shortVRs.contains(code) else { throw unsafe() }
                    let size = long ? 12 : 8
                    guard available >= metaOffset + size else { return }
                    if long, uint(metaOffset + 6, 2) != 0 { throw unsafe() }
                    let length = Int(uint(metaOffset + (long ? 8 : 6), long ? 4 : 2))
                    try budget(metaOffset, adding: size + length, limit: limits.maximumHeaderBytes, name: "maximumHeaderBytes")
                    guard available >= metaOffset + size + length else { return }
                    guard length % 2 == 0, metaTags.insert(uint(metaOffset + 2, 2)).inserted else { throw unsafe() }
                    metaOffset += size + length
                }
                guard available >= metaOffset + 8 else { return }
                let meta = try DicomPart10FileMetaParser.parse(Data(buffer[cursor..<cursor + metaOffset]))
                guard let uid = meta.transferSyntaxUID, let detected = DicomTransferSyntax(rawValue: uid),
                      detected.isExplicitVR, uid != "1.2.840.10008.1.2.1.99", meta.mediaStorageSOPInstanceUID?.isEmpty == false,
                      meta.mediaStorageSOPClassUID?.isEmpty == false else { throw unsafe() }
                if let advertised = (try? DicomWebMediaType(headers["content-type"]!))?.parameters["transfer-syntax"],
                   advertised != uid, advertised != "*" { throw unsafe() }
                syntax = detected
                events.append(.partHeaders(headers, isRoot: false))
                try payload(metaOffset, into: &events)
                state = .element
            case .element:
                // MIME bytes have meaning only between top-level DICOM elements. Values, including
                // whole delimiter lines inside Pixel Data, have already been skipped by their lengths.
                if stack.isEmpty, elements > 0 {
                    let prefix = Array(buffer[cursor...].prefix(marker.count))
                    if marker.starts(with: prefix) {
                        guard available >= marker.count + 2 else { return }
                        // A marker that also encodes an explicit element header has two possible
                        // interpretations; refuse it rather than choosing a MIME interpretation.
                        if available >= 8, Self.longVRs.contains(vr(4)) || Self.shortVRs.contains(vr(4)) { throw unsafe() }
                        if let declaredLength, partBytes != declaredLength { throw unsafe() }
                        state = .delimiter
                        continue
                    }
                }
                guard available >= 8 else { return }
                let little = !syntax.isBigEndian
                let group = uint(0, 2, little: little)
                let tag = (group << 16) | uint(2, 2, little: little)
                var headerSize = 8
                var length: UInt32
                var code = ""
                if group == 0xfffe {
                    length = uint(4, 4, little: little)
                    switch tag {
                    case 0xfffee000:
                        guard stack.last == .sequence || stack.last == .fragments else { throw unsafe() }
                        if length == .max {
                            guard stack.last != .fragments else { throw unsafe() }
                            stack.append(.item)
                        }
                    case 0xfffee00d:
                        guard length == 0, stack.last == .item else { throw unsafe() }
                        stack.removeLast()
                    case 0xfffee0dd:
                        guard length == 0, stack.last == .sequence || stack.last == .fragments else { throw unsafe() }
                        stack.removeLast()
                    default: throw unsafe()
                    }
                } else {
                    guard group != 2, stack.last != .sequence, stack.last != .fragments else { throw unsafe() }
                    code = vr(4)
                    if Self.longVRs.contains(code) {
                        guard available >= 12 else { return }
                        guard uint(6, 2, little: little) == 0 else { throw unsafe() }
                        headerSize = 12
                        length = uint(8, 4, little: little)
                    } else {
                        guard Self.shortVRs.contains(code) else { throw unsafe() }
                        length = uint(6, 2, little: little)
                    }
                    if length == .max {
                        if tag == 0x7fe00010, syntax.isCompressed { stack.append(.fragments) }
                        else if code == "SQ" { stack.append(.sequence) }
                        else { throw unsafe() }
                    }
                }
                guard stack.count <= 64 else { throw DicomWebMultipartStreamError.limitExceeded("maximumDICOMDepth", limit: 64) }
                elements += 1
                guard elements <= 1_000_000 else { throw DicomWebMultipartStreamError.limitExceeded("maximumDICOMElements", limit: 1_000_000) }
                guard length == .max || length % 2 == 0 else { throw unsafe() }
                try payload(headerSize, into: &events)
                remaining = length == .max ? 0 : Int(length)
                try budget(partBytes, adding: remaining, limit: limits.maximumPartBytes, name: "maximumPartBytes")
                state = remaining == 0 ? .element : .value
            case .value:
                let size = min(available, remaining)
                try payload(size, into: &events)
                remaining -= size
                if remaining == 0 { state = .element }
            case .delimiter:
                guard available >= marker.count + 2, buffer[cursor..<cursor + marker.count].elementsEqual(marker) else { throw unsafe() }
                let suffix = Array(buffer[cursor + marker.count..<cursor + marker.count + 2])
                if suffix == [13, 10] {
                    cursor += marker.count + 2
                    endPart(into: &events)
                    state = .headers
                } else if suffix == [45, 45] {
                    let end = cursor + marker.count + 2
                    // Closing at EOF is legal; otherwise require CRLF and no unexpected epilogue.
                    if buffer.count == end, !finishing { return }
                    if buffer.count != end {
                        guard buffer.count >= end + 2 else { return }
                        guard buffer[end..<end + 2].elementsEqual([13, 10]) else { throw unsafe() }
                        cursor = end + 2
                    } else { cursor = end }
                    endPart(into: &events)
                    state = .epilogue
                } else { throw unsafe() }
            case .epilogue:
                // This vendor profile carries only Part 10 parts, never arbitrary trailing data.
                throw unsafe()
            case .finished: throw DicomWebMultipartStreamError.invalidState
            }
        }
    }
}
