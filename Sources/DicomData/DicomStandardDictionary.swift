import Foundation

struct DicomStandardDictionary {
    private struct Pattern {
        let mask: Int
        let value: Int
        let definition: DicomDictionaryDefinition
    }

    static let shared = load()
    /// Keywords of the fixed-tag definitions, built on the first keyword lookup: no parse needs them (#3082).
    private static let tagsByKeyword: [String: Int] = {
        var tags: [String: Int] = [:]
        for (tag, index) in zip(shared.tags, shared.entryIndices) {
            let keyword = DicomStandardDictionaryTable.entries[index].keyword
            if !keyword.isEmpty { tags[keyword] = tag }
        }
        return tags
    }()

    let edition: String?
    /// Ascending fixed tags and, at the same position, the index of their table entry.
    private let tags: [Int]
    private let entryIndices: [Int]
    private let patterns: [Pattern]

    func tag(forKeyword keyword: String) -> Int? { Self.tagsByKeyword[keyword] }

    func definition(for tag: Int) -> DicomDictionaryDefinition? {
        guard (0...Int(UInt32.max)).contains(tag), (tag >> 16).isMultiple(of: 2) else { return nil }
        if let index = position(of: tag) { return Self.definition(DicomStandardDictionaryTable.entries[entryIndices[index]]) }
        // Overlay groups are limited to the sixteen planes defined by PS3.3.
        if tag >> 24 == 0x60, tag >> 16 > 0x601E { return nil }
        return patterns.first(where: { tag & $0.mask == $0.value })?.definition
    }

    private func position(of tag: Int) -> Int? {
        var low = 0
        var high = tags.count
        while low < high {
            let middle = (low + high) / 2
            if tags[middle] < tag { low = middle + 1 } else { high = middle }
        }
        return low < tags.count && tags[low] == tag ? low : nil
    }

    private static func definition(_ entry: DicomStandardDictionaryTable.Entry) -> DicomDictionaryDefinition {
        DicomDictionaryDefinition(standardVRs: entry.vrs, multiplicity: entry.vm, name: entry.name,
                                  keyword: entry.keyword, retired: entry.retired)
    }

    /// Reads the compiled table generated from `DCMDictionary-Definitions.json`; decoding that JSON was a one-time
    /// cost of the first parse of every process (#3041). Only the tags are read here and a lookup builds its definition
    /// from the table: hashing every definition and keyword into dictionaries was most of the first parse's remaining
    /// one-time cost (#3082). `DicomStandardDictionaryTableTests` checks that the table matches the JSON, which keeps
    /// the definitions valid.
    private static func load() -> Self {
        var tags: [Int] = []
        var entryIndices: [Int] = []
        var patterns: [Pattern] = []
        tags.reserveCapacity(DicomStandardDictionaryTable.entries.count)
        entryIndices.reserveCapacity(DicomStandardDictionaryTable.entries.count)
        // The generator emits the keys in ascending order, the order the JSON definitions were applied in; a repeated
        // key keeps its last definition, as the JSON did.
        for (index, entry) in DicomStandardDictionaryTable.entries.enumerated() {
            let key = entry.key
            if let tag = Int(key, radix: 16) {
                if let last = tags.last, last >= tag {
                    if last == tag { entryIndices[entryIndices.count - 1] = index; continue }
                    preconditionFailure("DicomStandardDictionaryTable keys must ascend: \(key)")
                }
                tags.append(tag)
                entryIndices.append(index)
            } else if key.count == 8,
                      let mask = Int(key.map { $0 == "X" ? "0" : "F" }.joined(), radix: 16),
                      let value = Int(key.replacingOccurrences(of: "X", with: "0"), radix: 16) {
                patterns.append(.init(mask: mask, value: value, definition: definition(entry)))
            }
        }
        patterns.sort { $0.mask.nonzeroBitCount > $1.mask.nonzeroBitCount }
        return .init(edition: DicomStandardDictionaryTable.edition, tags: tags, entryIndices: entryIndices,
                     patterns: patterns)
    }
}
