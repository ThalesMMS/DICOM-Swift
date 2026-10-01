import Foundation

/// DICOM's fixed G0/GL and G1/GR model, without SI/SO, SS2/SS3 or G2/G3.
/// Each invocation owns its state; values, lines, PN components and items cannot
/// inherit an escape designation from the preceding boundary.
struct DicomISO2022Codec {
    private typealias Repertoire = DicomISO2022Repertoire
    private typealias Failure = DicomSpecificCharacterSet.Failure
    private let repertoires: [Repertoire]
    private let initialG0: Repertoire
    private let initialG1: Repertoire?
    private let allowsEscapes: Bool

    init(terms: [String]) throws {
        let normalized = terms.enumerated().map { index, term in
            index == 0 && term.isEmpty ? "ISO 2022 IR 6" : term
        }
        let prefix = terms.count > 1 ? "ISO 2022 IR " : "ISO_IR "
        var declared: [Repertoire] = []
        for term in normalized {
            // A single ISO 2022 term is tolerated only for a single-byte table;
            // it still cannot invoke code extension without multiple values.
            let actualPrefix = normalized.count == 1 && term.hasPrefix("ISO 2022 IR ") ? "ISO 2022 IR " : prefix
            guard term.hasPrefix(actualPrefix), let number = Int(term.dropFirst(actualPrefix.count)),
                  let repertoire = Repertoire(rawValue: number), repertoire != .romaji,
                  !declared.contains(repertoire) else { throw Failure.unsupportedDeclaration }
            declared.append(repertoire)
        }
        guard let first = declared.first, first.width == 1 else { throw Failure.unsupportedDeclaration }
        initialG0 = first == .katakana ? .romaji : .ascii
        initialG1 = first.isG0 ? nil : first
        allowsEscapes = terms.count > 1
        var available = [initialG0]
        for repertoire in declared where !available.contains(repertoire) { available.append(repertoire) }
        if declared.contains(.katakana), !available.contains(.romaji) { available.append(.romaji) }
        if !available.contains(.ascii) { available.append(.ascii) }
        repertoires = available
    }

    func decode(_ data: Data, vr: DicomVR) throws -> String {
        let bytes = Array(data)
        var index = 0
        var g0 = initialG0
        var g1 = initialG1
        var alphabetic = vr == .PN
        var result = ""
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x1B {
                guard allowsEscapes, !alphabetic,
                      let repertoire = repertoires.first(where: { bytes[index...].starts(with: $0.escape) }) else {
                    throw Failure.invalidEncodedText
                }
                if repertoire.isG0 { g0 = repertoire } else { g1 = repertoire }
                index += repertoire.escape.count
                continue
            }
            let singleByte = g0.width == 1 || byte < 0x21 || byte >= 0x80
            if singleByte && Self.isBoundary(byte, vr: vr) {
                guard isInitial(g0: g0, g1: g1), Self.isAllowedControl(byte, vr: vr) else {
                    throw Failure.invalidEncodedText
                }
                result.unicodeScalars.append(Unicode.Scalar(byte))
                if vr == .PN, byte == 0x3D { alphabetic = false }
                if vr == .PN, byte == 0x5C { alphabetic = true }
                g0 = initialG0
                g1 = initialG1
                index += 1
                continue
            }
            if byte == 0x20 { result.append(" "); index += 1; continue }
            guard byte >= 0x21, byte != 0x7F, !(0x80...0x9F).contains(byte),
                  let repertoire = byte < 0x80 ? g0 : g1,
                  repertoire.width <= bytes.count - index,
                  let text = repertoire.decode(Array(bytes[index..<(index + repertoire.width)])) else {
                throw Failure.invalidEncodedText
            }
            result += text
            index += repertoire.width
        }
        guard isInitial(g0: g0, g1: g1) else { throw Failure.invalidEncodedText }
        return result
    }

    func encode(_ value: String, vr: DicomVR) throws -> Data {
        var result = Data()
        var g0 = initialG0
        var g1 = initialG1
        var alphabetic = vr == .PN
        for scalar in value.unicodeScalars {
            if scalar.value < 0x80, Self.isBoundary(UInt8(scalar.value), vr: vr) {
                guard Self.isAllowedControl(UInt8(scalar.value), vr: vr) else { throw Failure.unrepresentableText }
                reset(g0: &g0, g1: &g1, into: &result)
                result.append(UInt8(scalar.value))
                if vr == .PN, scalar == "=" { alphabetic = false }
                if vr == .PN, scalar == "\\" { alphabetic = true }
                g0 = initialG0
                g1 = initialG1
                continue
            }
            if scalar == " " { result.append(0x20); continue }
            let candidates = [g0, g1].compactMap { $0 } + repertoires
            guard let candidate = candidates.lazy.compactMap({ repertoire -> (Repertoire, [UInt8])? in
                guard (!alphabetic && allowsEscapes) || repertoire == self.initialG0 || repertoire == self.initialG1,
                      let bytes = repertoire.encode(scalar) else { return nil }
                return (repertoire, bytes)
            }).first else { throw Failure.unrepresentableText }
            let (repertoire, bytes) = candidate
            // In JIS X 0201, YEN maps to the byte used for VM separation.
            // A literal yen cannot masquerade as a second textual value.
            guard bytes != [0x5C] || [DicomVR.LT, .ST, .UT].contains(vr) else {
                throw Failure.unrepresentableText
            }
            if repertoire.isG0, g0 != repertoire { result.append(contentsOf: repertoire.escape); g0 = repertoire }
            if !repertoire.isG0, g1 != repertoire { result.append(contentsOf: repertoire.escape); g1 = repertoire }
            result.append(contentsOf: bytes)
        }
        reset(g0: &g0, g1: &g1, into: &result)
        return result
    }

    private func isInitial(g0: Repertoire, g1: Repertoire?) -> Bool {
        // With no initial G1, a still-active initial G0 is sufficient (PS3.5 6.1.2.5.3 note).
        g0 == initialG0 && (initialG1 == nil || g1 == initialG1)
    }

    private func reset(g0: inout Repertoire, g1: inout Repertoire?, into data: inout Data) {
        if g0 != initialG0 { data.append(contentsOf: initialG0.escape); g0 = initialG0 }
        if let initialG1, g1 != initialG1 { data.append(contentsOf: initialG1.escape); g1 = initialG1 }
    }

    private static func isBoundary(_ byte: UInt8, vr: DicomVR) -> Bool {
        byte < 0x20 || (byte == 0x5C && ![DicomVR.LT, .ST, .UT].contains(vr))
            || (vr == .PN && [UInt8(0x5E), 0x3D].contains(byte))
    }

    private static func isAllowedControl(_ byte: UInt8, vr: DicomVR) -> Bool {
        byte >= 0x20 || ([DicomVR.LT, .ST, .UT].contains(vr) && [UInt8(9), 10, 12, 13].contains(byte))
    }
}
