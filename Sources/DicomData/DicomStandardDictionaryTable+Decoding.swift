extension DicomStandardDictionaryTable {
    /// Decodes the generated text once per process: one definition per line, `|` between fields, spaces between VRs
    /// and `1` for a retired definition. The generator restricts every field to ASCII without those separators.
    static func decodeEntries(_ text: String) -> [Entry] {
        var text = text
        return text.withUTF8 { bytes in
            var entries: [Entry] = []
            entries.reserveCapacity(entryCount)
            for line in bytes.split(separator: UInt8(ascii: "\n")) {
                let fields = line.split(separator: UInt8(ascii: "|"), omittingEmptySubsequences: false)
                precondition(fields.count == 6, "Malformed DicomStandardDictionaryTable line")
                entries.append((key: String(decoding: fields[0], as: UTF8.self),
                                vrs: fields[1].split(separator: UInt8(ascii: " ")).map { String(decoding: $0, as: UTF8.self) },
                                vm: String(decoding: fields[2], as: UTF8.self),
                                name: String(decoding: fields[3], as: UTF8.self),
                                keyword: String(decoding: fields[4], as: UTF8.self),
                                retired: fields[5].first == UInt8(ascii: "1")))
            }
            precondition(entries.count == entryCount, "DicomStandardDictionaryTable entry count mismatch")
            return entries
        }
    }
}
