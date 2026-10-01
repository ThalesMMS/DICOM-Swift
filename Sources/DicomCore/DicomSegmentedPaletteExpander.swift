import Foundation

internal enum DicomSegmentedPaletteExpander {
    enum ExpansionError: Error, Equatable {
        case malformedData
        case invalidOffset
        case entryCountMismatch
    }

    static func expand(words: [UInt16], entryCount: Int) throws -> [UInt16] {
        guard entryCount > 0, entryCount <= 65_536 else { throw ExpansionError.entryCountMismatch }
        var result: [UInt16] = []
        var boundaries: Set<Int> = []
        var cursor = 0
        while cursor < words.count {
            guard cursor + 1 < words.count, words[cursor + 1] > 0 else {
                throw ExpansionError.malformedData
            }
            guard boundaries.count < entryCount else { throw ExpansionError.entryCountMismatch }
            boundaries.insert(cursor)
            switch words[cursor] {
            case 0: cursor += 2 + Int(words[cursor + 1])
            case 1: cursor += 3
            case 2: cursor += 4
            default: throw ExpansionError.malformedData
            }
            guard cursor <= words.count else { throw ExpansionError.malformedData }
        }

        func segment(at start: Int) throws -> Int {
            guard start >= 0, start + 1 < words.count else { throw ExpansionError.malformedData }
            let count = Int(words[start + 1])
            guard count > 0 else { throw ExpansionError.malformedData }
            switch words[start] {
            case 0:
                guard count <= words.count - start - 2 else { throw ExpansionError.malformedData }
                guard count <= entryCount - result.count else { throw ExpansionError.entryCountMismatch }
                result.append(contentsOf: words[(start + 2)..<(start + 2 + count)])
                return start + 2 + count
            case 1:
                guard start + 2 < words.count, let previous = result.last else {
                    throw ExpansionError.malformedData
                }
                guard count <= entryCount - result.count else { throw ExpansionError.entryCountMismatch }
                let first = Double(previous)
                let delta = Double(words[start + 2]) - first
                for index in 1...count {
                    result.append(UInt16((first + delta * Double(index) / Double(count)).rounded()))
                }
                return start + 3
            case 2:
                guard start + 3 < words.count else { throw ExpansionError.malformedData }
                let offset = UInt32(words[start + 2]) | UInt32(words[start + 3]) << 16
                guard offset.isMultiple(of: 2), Int(offset / 2) < words.count else {
                    throw ExpansionError.invalidOffset
                }
                var cursor = Int(offset / 2)
                for _ in 0..<count {
                    guard boundaries.contains(cursor), words[cursor] != 2 else {
                        throw ExpansionError.invalidOffset
                    }
                    cursor = try segment(at: cursor)
                }
                return start + 4
            default:
                throw ExpansionError.malformedData
            }
        }

        cursor = 0
        while cursor < words.count {
            cursor = try segment(at: cursor)
        }
        guard result.count == entryCount else { throw ExpansionError.entryCountMismatch }
        return result
    }
}
