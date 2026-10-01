import Foundation

/// Header evidence from one JPEG 2000 Part 1 or HTJ2K (Part 15) codestream, including
/// component and tile coding overrides. Tile-part lengths skip packets without decoding them.
public enum DicomJ2KCodestreamInspector {
    public enum Failure: Error, Equatable, Sendable { case invalidStream, limitExceeded }

    /// ISO/IEC 15444 file-format wrappers a frame may carry instead of the raw codestream DICOM requires (PS3.5 A.4.4):
    /// JP2 (Part 1 Annex I), JPX (Part 2 Annex M) and JPH (Part 15 Annex A). Identified by the signature box and the
    /// `ftyp` brand; the contiguous codestream box (`jp2c`) carries the codestream.
    public enum Container: String, Equatable, Sendable {
        case jp2
        case jpx
        case jph
    }

    /// Splits a wrapped frame into its container kind and the raw codestream carried by its first `jp2c` box.
    /// A raw codestream (SOC/SIZ) comes back unchanged with `container == nil`; a wrapper without a codestream box
    /// or with a malformed box structure throws `invalidStream`.
    public static func unwrap(_ data: Data) throws -> (codestream: Data, container: Container?) {
        let signature: [UInt8] = [0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
        guard data.count >= signature.count, Array(data.prefix(signature.count)) == signature else {
            return (data, nil)
        }
        var container = Container.jp2
        var cursor = data.startIndex
        while cursor + 8 <= data.endIndex {
            let header = data[cursor..<(cursor + 8)]
            var length = Int(header[header.startIndex]) << 24 | Int(header[header.startIndex + 1]) << 16
                | Int(header[header.startIndex + 2]) << 8 | Int(header[header.startIndex + 3])
            let type = String(decoding: header[(header.startIndex + 4)..<(header.startIndex + 8)], as: UTF8.self)
            var payloadStart = cursor + 8
            if length == 1 {
                guard cursor + 16 <= data.endIndex else { throw Failure.invalidStream }
                var extended = 0
                for offset in 8..<16 { extended = extended << 8 | Int(data[cursor + offset]) }
                length = extended
                payloadStart = cursor + 16
            } else if length == 0 {
                length = data.endIndex - cursor
            }
            guard length >= payloadStart - cursor, cursor + length <= data.endIndex else { throw Failure.invalidStream }
            let payload = data[payloadStart..<(cursor + length)]
            switch type {
            case "ftyp":
                let brand = payload.count >= 4 ? String(decoding: payload.prefix(4), as: UTF8.self) : ""
                switch brand {
                case "jpx ": container = .jpx
                case "jph ": container = .jph
                default: container = .jp2
                }
            case "jp2c":
                return (Data(payload), container)
            default:
                break
            }
            cursor += length
        }
        throw Failure.invalidStream
    }

    public struct Component: Equatable, Sendable {
        public let precision: Int
        public let isSigned: Bool
        public let horizontalSeparation: Int
        public let verticalSeparation: Int
    }

    /// ISO/IEC 15444-2 Annex J multiple component transformation signalling (issue #2331).
    public struct AnnexJ: Equatable, Sendable {
        public let componentCount: Int
        /// Stages of the MCO ordering.
        public let stageCount: Int
        public let arrayBasedCollections: Int
        public let waveletBasedCollections: Int
        public let reversibleCollections: Int
        public let decorrelationArrays: Int
        public let dependencyArrays: Int
        public let offsetArrays: Int
        /// Reconstructed component depths from the CBD marker segment, nil when absent.
        public let outputComponents: [Component]?
    }

    public struct Inspection: Equatable, Sendable {
        /// SIZ Rsiz capabilities; bit 14 (0x4000) declares Part 15 (HTJ2K) capabilities.
        public let capabilities: Int
        public let width: Int
        public let height: Int
        public let components: [Component]
        /// SGcod progression order: 0 LRCP, 1 RLCP, 2 RPCL, 3 PCRL, 4 CPRL.
        public let progressionOrder: Int
        public let layerCount: Int
        /// SGcod multiple component transformation: 1 when the Annex G RCT/ICT was applied.
        public let usesMultipleComponentTransform: Bool
        /// SPcod transformation: 1 for the reversible 5-3 filter, 0 for the irreversible 9-7 filter.
        public let usesReversibleTransform: Bool
        public let decompositionLevels: Int
        /// SPcod code-block style bit 6 (0x40): HT code-blocks (Part 15).
        public let usesHTCodeBlocks: Bool
        /// Sqcd quantization style: 0 none, 1 scalar derived, 2 scalar expounded.
        public let quantizationStyle: Int
        /// Whether a CAP marker segment declares Part 15 capabilities (Pcap bit 15).
        public let declaresHTCapabilities: Bool
        /// A TLM marker segment (T.800 A.7.1) is present in the main header (required by PS3.5 10.18.1 for .202).
        public let hasTileLengthMarkers: Bool
        /// SGcod multiple component transformation value: 0 none, 1 Annex G RCT/ICT, 2 Part 2 Annex J (T.801 Table A.8).
        public let multipleComponentTransformValue: Int
        /// Summary of the ISO/IEC 15444-2 Annex J marker segments (MCT/MCC/MCO/CBD) of the main header, nil when absent.
        public let annexJ: AnnexJ?
        public let hasEndOfCodestream: Bool
        /// The file-format wrapper the frame carried, when the codestream was not sent raw.
        public let container: Container?

        public let isLosslessCoding: Bool
        /// SIZ Rsiz bit 15: the codestream uses Part 2 extensions (T.801 Table A.2).
        public var usesPart2Extensions: Bool { capabilities & 0x8000 != 0 }
        public var isHighThroughput: Bool { capabilities & 0x4000 != 0 && declaresHTCapabilities && usesHTCodeBlocks }
    }

    public static func inspect(_ data: Data, maximumEncodedBytes: Int = 64 * 1024 * 1024) throws -> Inspection {
        guard data.count <= max(0, maximumEncodedBytes) else { throw Failure.limitExceeded }
        let (data, container) = try unwrap(data)
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0x4F, bytes[2] == 0xFF, bytes[3] == 0x51 else { throw Failure.invalidStream }
            func word(_ index: Int) -> Int { Int(bytes[index]) << 8 | Int(bytes[index + 1]) }
            func dword(_ index: Int) -> Int { word(index) << 16 | word(index + 2) }
            var cursor = 2
            var capabilities = 0, width = 0, height = 0, components: [Component] = []
            var cod: (progression: Int, layers: Int, mct: Bool, reversible: Bool, levels: Int, ht: Bool)?
            var quantization: Int?, cap = false, tlm = false, tileCount = 0
            var mctValue = 0, stages = 0, arrayCollections = 0, waveletCollections = 0, reversibleCollections = 0
            var decorrelationArrays = 0, dependencyArrays = 0, offsetArrays = 0, annexJMarkers = 0
            var outputComponents: [Component]?
            var componentTransforms: [Int: Bool] = [:], componentQuantization: [Int: Int] = [:]
            func componentIndex(_ start: Int) throws -> (index: Int, width: Int) {
                let width = components.count < 257 ? 1 : 2
                let index = width == 1 ? Int(bytes[start]) : word(start)
                guard components.indices.contains(index) else { throw Failure.invalidStream }
                return (index, width)
            }
            func componentTransform(_ start: Int, _ length: Int) throws -> (Int, Bool) {
                guard length >= 8 + (components.count < 257 ? 1 : 2) else { throw Failure.invalidStream }
                let component = try componentIndex(start)
                let transform = Int(bytes[start + component.width + 5])
                guard transform <= 1 else { throw Failure.invalidStream }
                return (component.index, transform == 1)
            }
            func componentQuantizer(_ start: Int, _ length: Int) throws -> (Int, Int) {
                guard length >= 4 + (components.count < 257 ? 1 : 2) else { throw Failure.invalidStream }
                let component = try componentIndex(start)
                let style = Int(bytes[start + component.width]) & 0x1F
                guard style <= 2 else { throw Failure.invalidStream }
                return (component.index, style)
            }
            while cursor + 4 <= bytes.count {
                guard bytes[cursor] == 0xFF else { throw Failure.invalidStream }
                let marker = bytes[cursor + 1]
                if marker == 0x90 || marker == 0xD9 { break }
                let length = word(cursor + 2)
                guard length >= 2, cursor + 2 + length <= bytes.count else { throw Failure.invalidStream }
                let start = cursor + 4
                switch marker {
                case 0x51:
                    guard cursor == 2, length >= 41 else { throw Failure.invalidStream }
                    capabilities = word(start)
                    let xsiz = dword(start + 2), ysiz = dword(start + 6), xosiz = dword(start + 10), yosiz = dword(start + 14)
                    let count = word(start + 34)
                    guard (1...16384).contains(count), length == 38 + count * 3, xsiz > xosiz, ysiz > yosiz else { throw Failure.invalidStream }
                    width = xsiz - xosiz; height = ysiz - yosiz
                    let tileWidth = dword(start + 18), tileHeight = dword(start + 22)
                    let tileX = dword(start + 26), tileY = dword(start + 30)
                    guard tileWidth > 0, tileHeight > 0, tileX <= xosiz, tileY <= yosiz,
                          tileX + tileWidth > xosiz, tileY + tileHeight > yosiz else { throw Failure.invalidStream }
                    let across = (xsiz - tileX + tileWidth - 1) / tileWidth
                    let down = (ysiz - tileY + tileHeight - 1) / tileHeight
                    guard across <= 65535, down <= 65535, across * down <= 65535 else { throw Failure.invalidStream }
                    tileCount = across * down
                    for index in 0..<count {
                        let offset = start + 36 + index * 3
                        let ssiz = Int(bytes[offset]), xr = Int(bytes[offset + 1]), yr = Int(bytes[offset + 2])
                        guard ssiz & 0x7F < 38, xr > 0, yr > 0 else { throw Failure.invalidStream }
                        components.append(.init(precision: (ssiz & 0x7F) + 1, isSigned: ssiz & 0x80 != 0, horizontalSeparation: xr, verticalSeparation: yr))
                    }
                case 0x52:
                    guard !components.isEmpty, length >= 12 else { throw Failure.invalidStream }
                    let progression = Int(bytes[start + 1]), layers = word(start + 2), mct = Int(bytes[start + 4])
                    let levels = Int(bytes[start + 5]), style = Int(bytes[start + 8]), transform = Int(bytes[start + 9])
                    guard progression <= 4, layers >= 1, mct <= 2, levels <= 32, transform <= 1 else { throw Failure.invalidStream }
                    cod = (progression, layers, mct == 1, transform == 1, levels, style & 0x40 != 0)
                    mctValue = mct
                case 0x75:
                    // MCT: Zmct (2), Imct (2: index bits 0–7, array type bits 8–9), Ymct (2), array bytes.
                    guard length >= 8 else { throw Failure.invalidStream }
                    annexJMarkers += 1
                    switch (word(start + 2) >> 8) & 0x3 {
                    case 0: dependencyArrays += 1
                    case 1: decorrelationArrays += 1
                    default: offsetArrays += 1
                    }
                case 0x77:
                    // MCC: Zmcc (2), Imcc (1), Ymcc (2), Qmcc (2), then per collection Xmcci, Nmcci + inputs, Mmcci + outputs, Tmcci (3).
                    guard length >= 9 else { throw Failure.invalidStream }
                    annexJMarkers += 1
                    var offset = start + 7
                    let end = cursor + 2 + length
                    for _ in 0..<word(start + 5) {
                        guard offset + 3 <= end else { throw Failure.invalidStream }
                        let kind = Int(bytes[offset]) & 0x1
                        let inputCount = word(offset + 1)
                        let inputWidth = inputCount & 0x8000 != 0 ? 2 : 1
                        offset += 3 + (inputCount & 0x7FFF) * inputWidth
                        guard offset + 2 <= end else { throw Failure.invalidStream }
                        let outputCount = word(offset)
                        let outputWidth = outputCount & 0x8000 != 0 ? 2 : 1
                        offset += 2 + (outputCount & 0x7FFF) * outputWidth
                        guard offset + 3 <= end else { throw Failure.invalidStream }
                        let tmcc = Int(bytes[offset]) << 16 | word(offset + 1)
                        offset += 3
                        if kind == 1 { arrayCollections += 1 } else { waveletCollections += 1 }
                        if (tmcc >> 16) & 1 == 1 { reversibleCollections += 1 }
                    }
                case 0x76:
                    guard length >= 3, length == 3 + Int(bytes[start]) else { throw Failure.invalidStream }
                    annexJMarkers += 1
                    stages = Int(bytes[start])
                case 0x78:
                    guard length >= 5 else { throw Failure.invalidStream }
                    annexJMarkers += 1
                    let ncbd = word(start)
                    let entries = (ncbd & 0x8000 != 0) ? 1 : (ncbd & 0x7FFF)
                    guard length == 4 + entries else { throw Failure.invalidStream }
                    let depths = (0..<entries).map { Component(precision: Int(bytes[start + 2 + $0] & 0x7F) + 1, isSigned: bytes[start + 2 + $0] & 0x80 != 0,
                                                                horizontalSeparation: 1, verticalSeparation: 1) }
                    outputComponents = ncbd & 0x8000 != 0 ? Array(repeating: depths[0], count: components.count) : depths
                case 0x5C:
                    guard length >= 4 else { throw Failure.invalidStream }
                    let style = Int(bytes[start]) & 0x1F
                    guard [0, 1, 2].contains(style) else { throw Failure.invalidStream }
                    quantization = style
                case 0x53:
                    let (component, reversible) = try componentTransform(start, length)
                    componentTransforms[component] = reversible
                case 0x5D:
                    let (component, style) = try componentQuantizer(start, length)
                    componentQuantization[component] = style
                case 0x50:
                    guard length >= 6 else { throw Failure.invalidStream }
                    cap = dword(start) & 0x0002_0000 != 0
                case 0x55:
                    guard length >= 4 else { throw Failure.invalidStream }
                    tlm = true
                default:
                    break
                }
                cursor += 2 + length
            }
            guard !components.isEmpty, let cod, let quantization else { throw Failure.invalidStream }
            // PS3.5 A.4: an odd fragment is padded to even length after EOC. Encoders pad with 0x00 or, like
            // GDCM and GE, with 0xFF (issue #2487); some leave whatever byte their buffer held (issue #2858). The
            // single byte after EOC is never part of the codestream, whatever its value.
            let terminated = bytes.count >= 2 && bytes[bytes.count - 2] == 0xFF && bytes[bytes.count - 1] == 0xD9
            let padded = !terminated && bytes.count >= 3 && bytes[bytes.count - 3] == 0xFF && bytes[bytes.count - 2] == 0xD9
            let eoc = terminated || padded
            let end = eoc ? bytes.count - (padded ? 3 : 2) : bytes.count
            let mainIrreversible = components.indices.filter { !(componentTransforms[$0] ?? cod.reversible) }.count
            let mainQuantized = components.indices.filter { (componentQuantization[$0] ?? quantization) != 0 }.count
            var nextParts: [Int: Int] = [:], declaredParts: [Int: Int] = [:]
            var lossless = true
            while cursor < end {
                guard cursor + 12 <= end, bytes[cursor] == 0xFF, bytes[cursor + 1] == 0x90,
                      word(cursor + 2) == 10 else { throw Failure.invalidStream }
                let tile = word(cursor + 4), size = dword(cursor + 6)
                let part = Int(bytes[cursor + 10]), parts = Int(bytes[cursor + 11])
                guard tile < tileCount, size == 0 || size >= 14 else { throw Failure.invalidStream }
                let tileEnd = size == 0 ? end : cursor + size
                guard tileEnd <= end else { throw Failure.invalidStream }
                // TNsot may undercount: some encoders declare one tile-part fewer than they write, which OpenJPEG
                // and GDCM accept (issue #2858). Parts stay in order and declarations must agree.
                guard part == nextParts[tile, default: 0],
                      declaredParts[tile] == nil || parts == 0 || declaredParts[tile] == parts else { throw Failure.invalidStream }
                nextParts[tile] = part + 1
                if parts != 0 { declaredParts[tile] = parts }
                cursor += 12
                var tileTransform: Bool?, tileQuantizer: Int?
                var transforms: [Int: Bool] = [:], quantizers: [Int: Int] = [:]
                var hasData = false
                while cursor + 2 <= tileEnd {
                    guard bytes[cursor] == 0xFF else { throw Failure.invalidStream }
                    let marker = bytes[cursor + 1]
                    if marker == 0x93 { hasData = true; break }
                    guard cursor + 4 <= tileEnd else { throw Failure.invalidStream }
                    let length = word(cursor + 2), start = cursor + 4
                    guard length >= 2, cursor + 2 + length <= tileEnd else { throw Failure.invalidStream }
                    switch marker {
                    case 0x52:
                        guard length >= 12, bytes[start + 9] <= 1 else { throw Failure.invalidStream }
                        tileTransform = bytes[start + 9] == 1
                    case 0x53:
                        let (component, reversible) = try componentTransform(start, length)
                        transforms[component] = reversible
                    case 0x5C:
                        guard length >= 4, bytes[start] & 0x1F <= 2 else { throw Failure.invalidStream }
                        tileQuantizer = Int(bytes[start] & 0x1F)
                    case 0x5D:
                        let (component, style) = try componentQuantizer(start, length)
                        quantizers[component] = style
                    default: break
                    }
                    cursor += 2 + length
                }
                guard hasData else { throw Failure.invalidStream }
                if part == 0 {
                    // Tile-component > tile default > main component > main default (T.800 A.6).
                    var irreversible = tileTransform.map { $0 ? 0 : components.count } ?? mainIrreversible
                    var quantized = tileQuantizer.map { $0 == 0 ? 0 : components.count } ?? mainQuantized
                    for (component, reversible) in transforms {
                        let inherited = tileTransform ?? componentTransforms[component] ?? cod.reversible
                        irreversible += (reversible ? 0 : 1) - (inherited ? 0 : 1)
                    }
                    for (component, style) in quantizers {
                        let inherited = tileQuantizer ?? componentQuantization[component] ?? quantization
                        quantized += (style == 0 ? 0 : 1) - (inherited == 0 ? 0 : 1)
                    }
                    lossless = lossless && irreversible == 0 && quantized == 0
                } else if tileTransform != nil || tileQuantizer != nil || !transforms.isEmpty || !quantizers.isEmpty {
                    // Coding overrides outside the first tile-part are unresolved by this inspector.
                    lossless = false
                }
                cursor = tileEnd
            }
            guard nextParts.count == tileCount, declaredParts.allSatisfy({ nextParts[$0.key, default: 0] >= $0.value }) else { throw Failure.invalidStream }
            let annexJ: AnnexJ? = annexJMarkers == 0 ? nil : AnnexJ(
                componentCount: components.count, stageCount: stages, arrayBasedCollections: arrayCollections,
                waveletBasedCollections: waveletCollections, reversibleCollections: reversibleCollections,
                decorrelationArrays: decorrelationArrays, dependencyArrays: dependencyArrays, offsetArrays: offsetArrays,
                outputComponents: outputComponents)
            return .init(capabilities: capabilities, width: width, height: height, components: components, progressionOrder: cod.progression,
                         layerCount: cod.layers, usesMultipleComponentTransform: cod.mct, usesReversibleTransform: cod.reversible,
                         decompositionLevels: cod.levels, usesHTCodeBlocks: cod.ht, quantizationStyle: quantization,
                         declaresHTCapabilities: cap, hasTileLengthMarkers: tlm, multipleComponentTransformValue: mctValue, annexJ: annexJ,
                         hasEndOfCodestream: eoc, container: container, isLosslessCoding: lossless)
        }
    }
}
