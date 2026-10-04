import Foundation

struct DicomStandardDictionary {
    private struct Archive: Decodable {
        let schemaVersion: Int
        let dicomEdition: String
        let definitions: [String: DicomDictionaryDefinition]
    }
    private struct Pattern {
        let mask: Int
        let value: Int
        let definition: DicomDictionaryDefinition
    }

    static let shared = load()
    let edition: String?
    private let definitions: [Int: DicomDictionaryDefinition]
    private let patterns: [Pattern]
    /// Keywords of the fixed-tag definitions; repeating-group patterns have no single tag.
    private let tagsByKeyword: [String: Int]

    func tag(forKeyword keyword: String) -> Int? { tagsByKeyword[keyword] }

    func definition(for tag: Int) -> DicomDictionaryDefinition? {
        guard (0...Int(UInt32.max)).contains(tag), (tag >> 16).isMultiple(of: 2) else { return nil }
        if let definition = definitions[tag] { return definition }
        // Overlay groups are limited to the sixteen planes defined by PS3.3.
        if tag >> 24 == 0x60, tag >> 16 > 0x601E { return nil }
        return patterns.first(where: { tag & $0.mask == $0.value })?.definition
    }

    private static func load() -> Self {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: "DCMDictionary-Definitions", withExtension: "json"),
              let bytes = try? Data(contentsOf: url), let archive = try? JSONDecoder().decode(Archive.self, from: bytes),
              archive.schemaVersion == 1, archive.definitions.values.allSatisfy(\.isValid) else {
            DicomLogger.make(subsystem: "com.dicomviewer", category: "DCMDictionary")
                .warning("Standard VR/VM definitions unavailable or invalid")
            return .init(edition: nil, definitions: [:], patterns: [], tagsByKeyword: [:])
        }
        var definitions: [Int: DicomDictionaryDefinition] = [:]
        var patterns: [Pattern] = []
        for (key, definition) in archive.definitions.sorted(by: { $0.key < $1.key }) {
            if let tag = Int(key, radix: 16) {
                definitions[tag] = definition
            } else if key.count == 8,
                      let mask = Int(key.map { $0 == "X" ? "0" : "F" }.joined(), radix: 16),
                      let value = Int(key.replacingOccurrences(of: "X", with: "0"), radix: 16) {
                patterns.append(.init(mask: mask, value: value, definition: definition))
            }
        }
        patterns.sort { $0.mask.nonzeroBitCount > $1.mask.nonzeroBitCount }
        var tagsByKeyword: [String: Int] = [:]
        for (tag, definition) in definitions where !definition.keyword.isEmpty { tagsByKeyword[definition.keyword] = tag }
        return .init(edition: archive.dicomEdition, definitions: definitions, patterns: patterns,
                     tagsByKeyword: tagsByKeyword)
    }
}
