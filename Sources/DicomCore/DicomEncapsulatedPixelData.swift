import Foundation

public enum DicomEncapsulatedPixelDataDiagnosticSeverity: Equatable, Sendable {
    case warning
    case error
}

public struct DicomEncapsulatedPixelDataDiagnostic: Equatable, Sendable {
    public let severity: DicomEncapsulatedPixelDataDiagnosticSeverity
    public let message: String

    public init(severity: DicomEncapsulatedPixelDataDiagnosticSeverity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public enum DicomEncapsulatedPixelDataError: Error, Equatable, LocalizedError, Sendable {
    case invalidPixelDataOffset(Int)
    case truncatedItemHeader(offset: Int)
    case expectedBasicOffsetTable(offset: Int, tag: Int)
    case unexpectedTag(offset: Int, tag: Int)
    case undefinedFragmentLength(index: Int)
    case truncatedItemValue(offset: Int, length: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidPixelDataOffset(let offset):
            return "Invalid encapsulated Pixel Data offset: \(offset)."
        case .truncatedItemHeader(let offset):
            return "Truncated encapsulated Pixel Data item header at offset \(offset)."
        case .expectedBasicOffsetTable(let offset, let tag):
            return String(format: "Expected Basic Offset Table item at offset %d, found tag %08X.", offset, tag)
        case .unexpectedTag(let offset, let tag):
            return String(format: "Unexpected encapsulated Pixel Data tag %08X at offset %d.", tag, offset)
        case .undefinedFragmentLength(let index):
            return "Encapsulated Pixel Data fragment \(index) uses undefined item length."
        case .truncatedItemValue(let offset, let length):
            return "Truncated encapsulated Pixel Data item value at offset \(offset), length \(length)."
        }
    }
}

public struct DicomBasicOffsetTable: Equatable, Sendable {
    public let offsets: [UInt32]
    public let byteRange: Range<Int>

    public init(offsets: [UInt32], byteRange: Range<Int>) {
        self.offsets = offsets
        self.byteRange = byteRange
    }

    public var isEmpty: Bool {
        offsets.isEmpty
    }
}

public struct DicomExtendedOffsetTable: Equatable, Sendable {
    public let offsets: [UInt64]
    public let lengths: [UInt64]

    public init(offsets: [UInt64], lengths: [UInt64]) {
        self.offsets = offsets
        self.lengths = lengths
    }
}

public struct DicomEncapsulatedPixelDataFragment: Equatable, Sendable {
    public let index: Int
    public let itemRange: Range<Int>
    public let valueRange: Range<Int>
    public let relativeItemOffset: Int

    public init(index: Int, itemRange: Range<Int>, valueRange: Range<Int>, relativeItemOffset: Int) {
        self.index = index
        self.itemRange = itemRange
        self.valueRange = valueRange
        self.relativeItemOffset = relativeItemOffset
    }

    public var length: Int {
        valueRange.count
    }
}

public struct DicomEncapsulatedPixelFrame: Equatable, Sendable {
    public let index: Int
    public let fragmentIndexes: [Int]
    public let fragments: [DicomEncapsulatedPixelDataFragment]
    public let data: Data

    public init(
        index: Int,
        fragmentIndexes: [Int],
        fragments: [DicomEncapsulatedPixelDataFragment],
        data: Data
    ) {
        self.index = index
        self.fragmentIndexes = fragmentIndexes
        self.fragments = fragments
        self.data = data
    }
}

public struct DicomEncapsulatedPixelDataDescriptor: Equatable, Sendable {
    public let pixelDataOffset: Int
    public let numberOfFrames: Int
    public let basicOffsetTable: DicomBasicOffsetTable
    public let extendedOffsetTable: DicomExtendedOffsetTable?
    public let fragments: [DicomEncapsulatedPixelDataFragment]
    public let frameFragmentIndexes: [[Int]]
    public let diagnostics: [DicomEncapsulatedPixelDataDiagnostic]

    public init(
        pixelDataOffset: Int,
        numberOfFrames: Int,
        basicOffsetTable: DicomBasicOffsetTable,
        extendedOffsetTable: DicomExtendedOffsetTable?,
        fragments: [DicomEncapsulatedPixelDataFragment],
        frameFragmentIndexes: [[Int]],
        diagnostics: [DicomEncapsulatedPixelDataDiagnostic]
    ) {
        self.pixelDataOffset = pixelDataOffset
        self.numberOfFrames = numberOfFrames
        self.basicOffsetTable = basicOffsetTable
        self.extendedOffsetTable = extendedOffsetTable
        self.fragments = fragments
        self.frameFragmentIndexes = frameFragmentIndexes
        self.diagnostics = diagnostics
    }

    public func fragmentIndexes(forFrame index: Int) -> [Int]? {
        guard index >= 0, index < frameFragmentIndexes.count else { return nil }
        return frameFragmentIndexes[index]
    }

    public func frame(_ index: Int, in data: Data) -> DicomEncapsulatedPixelFrame? {
        guard let indexes = fragmentIndexes(forFrame: index), !indexes.isEmpty else { return nil }

        var frameFragments: [DicomEncapsulatedPixelDataFragment] = []
        frameFragments.reserveCapacity(indexes.count)
        var payload = Data()

        for fragmentIndex in indexes {
            guard fragments.indices.contains(fragmentIndex) else { return nil }
            let fragment = fragments[fragmentIndex]
            guard fragment.valueRange.lowerBound >= 0,
                  fragment.valueRange.upperBound <= data.count else {
                return nil
            }
            frameFragments.append(fragment)
            payload.append(Data(data[fragment.valueRange]))
        }

        return DicomEncapsulatedPixelFrame(
            index: index,
            fragmentIndexes: indexes,
            fragments: frameFragments,
            data: payload
        )
    }
}

public struct DicomEncapsulatedPixelDataParser: Sendable {
    public init() {}

    public func parse(
        data: Data,
        pixelDataOffset: Int,
        numberOfFrames: Int,
        extendedOffsetTableData: Data? = nil,
        extendedOffsetTableLengthsData: Data? = nil
    ) throws -> DicomEncapsulatedPixelDataDescriptor {
        guard pixelDataOffset >= 0, pixelDataOffset < data.count else {
            throw DicomEncapsulatedPixelDataError.invalidPixelDataOffset(pixelDataOffset)
        }
        guard pixelDataOffset + Self.itemHeaderLength <= data.count else {
            throw DicomEncapsulatedPixelDataError.truncatedItemHeader(offset: pixelDataOffset)
        }

        var diagnostics: [DicomEncapsulatedPixelDataDiagnostic] = []
        var cursor = pixelDataOffset
        let botTag = try Self.readTag(data, at: cursor)
        guard botTag == Self.itemTag else {
            throw DicomEncapsulatedPixelDataError.expectedBasicOffsetTable(offset: cursor, tag: botTag)
        }

        let botLength = Int(try Self.readUInt32(data, at: cursor + 4))
        let botValueStart = cursor + Self.itemHeaderLength
        let botValueEnd = botValueStart + botLength
        guard botValueEnd <= data.count else {
            throw DicomEncapsulatedPixelDataError.truncatedItemValue(offset: botValueStart, length: botLength)
        }
        let botRange = botValueStart..<botValueEnd
        let botOffsets = Self.readUInt32Values(Data(data[botRange]), diagnostics: &diagnostics)
        let basicOffsetTable = DicomBasicOffsetTable(offsets: botOffsets, byteRange: botRange)

        cursor = botValueEnd
        var parsedFragments: [(itemRange: Range<Int>, valueRange: Range<Int>)] = []
        while cursor < data.count {
            guard cursor + Self.itemHeaderLength <= data.count else {
                throw DicomEncapsulatedPixelDataError.truncatedItemHeader(offset: cursor)
            }
            let tag = try Self.readTag(data, at: cursor)
            let length = Int(try Self.readUInt32(data, at: cursor + 4))

            if tag == Self.sequenceDelimiterTag {
                break
            }
            guard tag == Self.itemTag else {
                throw DicomEncapsulatedPixelDataError.unexpectedTag(offset: cursor, tag: tag)
            }
            if length == Self.undefinedLength {
                throw DicomEncapsulatedPixelDataError.undefinedFragmentLength(index: parsedFragments.count)
            }

            let valueStart = cursor + Self.itemHeaderLength
            let valueEnd = valueStart + length
            guard valueEnd <= data.count else {
                throw DicomEncapsulatedPixelDataError.truncatedItemValue(offset: valueStart, length: length)
            }
            parsedFragments.append((itemRange: cursor..<valueEnd, valueRange: valueStart..<valueEnd))
            cursor = valueEnd
        }

        let firstFragmentOffset = parsedFragments.first?.itemRange.lowerBound ?? cursor
        let fragments = parsedFragments.enumerated().map { index, ranges in
            DicomEncapsulatedPixelDataFragment(
                index: index,
                itemRange: ranges.itemRange,
                valueRange: ranges.valueRange,
                relativeItemOffset: ranges.itemRange.lowerBound - firstFragmentOffset
            )
        }

        let extended = Self.extendedOffsetTable(
            offsetsData: extendedOffsetTableData,
            lengthsData: extendedOffsetTableLengthsData,
            diagnostics: &diagnostics
        )
        let frameCount = max(1, numberOfFrames)
        let frameFragments = Self.mapFrames(
            numberOfFrames: frameCount,
            fragments: fragments,
            basicOffsetTable: basicOffsetTable,
            extendedOffsetTable: extended,
            diagnostics: &diagnostics
        )

        return DicomEncapsulatedPixelDataDescriptor(
            pixelDataOffset: pixelDataOffset,
            numberOfFrames: frameCount,
            basicOffsetTable: basicOffsetTable,
            extendedOffsetTable: extended,
            fragments: fragments,
            frameFragmentIndexes: frameFragments,
            diagnostics: diagnostics
        )
    }
}

private extension DicomEncapsulatedPixelDataParser {
    static let itemTag = 0xFFFEE000
    static let sequenceDelimiterTag = 0xFFFEE0DD
    static let itemHeaderLength = 8
    static let undefinedLength = 0xFFFFFFFF

    static func readTag(_ data: Data, at offset: Int) throws -> Int {
        guard let group = data.dicomIntegerIfPresent(
                  at: offset,
                  as: UInt16.self,
                  littleEndian: true
              ),
              let element = data.dicomIntegerIfPresent(
                  at: offset + 2,
                  as: UInt16.self,
                  littleEndian: true
              ) else {
            throw DicomEncapsulatedPixelDataError.truncatedItemHeader(offset: offset)
        }
        return (Int(group) << 16) | Int(element)
    }

    static func readUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
        guard let value = data.dicomIntegerIfPresent(
            at: offset,
            as: UInt32.self,
            littleEndian: true
        ) else {
            throw DicomEncapsulatedPixelDataError.truncatedItemHeader(offset: offset)
        }
        return value
    }

    static func readUInt32Values(
        _ data: Data,
        diagnostics: inout [DicomEncapsulatedPixelDataDiagnostic]
    ) -> [UInt32] {
        guard !data.isEmpty else { return [] }
        guard data.count % 4 == 0 else {
            diagnostics.append(.init(
                severity: .error,
                message: "Basic Offset Table length \(data.count) is not divisible by 4."
            ))
            return []
        }
        return stride(from: 0, to: data.count, by: 4).map { offset in
            readUInt32Value(data, at: offset)
        }
    }

    static func readUInt64Values(
        _ data: Data,
        label: String,
        diagnostics: inout [DicomEncapsulatedPixelDataDiagnostic]
    ) -> [UInt64]? {
        guard data.count % 8 == 0 else {
            diagnostics.append(.init(
                severity: .error,
                message: "\(label) length \(data.count) is not divisible by 8."
            ))
            return nil
        }
        return stride(from: 0, to: data.count, by: 8).map { offset in
            readUInt64Value(data, at: offset)
        }
    }

    static func readUInt32Value(_ data: Data, at offset: Int) -> UInt32 {
        data.dicomIntegerIfPresent(at: offset, as: UInt32.self, littleEndian: true) ?? 0
    }

    static func readUInt64Value(_ data: Data, at offset: Int) -> UInt64 {
        data.dicomIntegerIfPresent(at: offset, as: UInt64.self, littleEndian: true) ?? 0
    }

    static func extendedOffsetTable(
        offsetsData: Data?,
        lengthsData: Data?,
        diagnostics: inout [DicomEncapsulatedPixelDataDiagnostic]
    ) -> DicomExtendedOffsetTable? {
        guard offsetsData != nil || lengthsData != nil else { return nil }
        guard let offsetsData, let lengthsData else {
            diagnostics.append(.init(
                severity: .error,
                message: "Extended Offset Table is incomplete; both offsets and lengths are required."
            ))
            return nil
        }
        guard let offsets = readUInt64Values(offsetsData, label: "Extended Offset Table", diagnostics: &diagnostics),
              let lengths = readUInt64Values(lengthsData, label: "Extended Offset Table Lengths", diagnostics: &diagnostics) else {
            return nil
        }
        guard offsets.count == lengths.count else {
            diagnostics.append(.init(
                severity: .error,
                message: "Extended Offset Table has \(offsets.count) offsets and \(lengths.count) lengths."
            ))
            return nil
        }
        return DicomExtendedOffsetTable(offsets: offsets, lengths: lengths)
    }

    static func mapFrames(
        numberOfFrames: Int,
        fragments: [DicomEncapsulatedPixelDataFragment],
        basicOffsetTable: DicomBasicOffsetTable,
        extendedOffsetTable: DicomExtendedOffsetTable?,
        diagnostics: inout [DicomEncapsulatedPixelDataDiagnostic]
    ) -> [[Int]] {
        guard !fragments.isEmpty else {
            diagnostics.append(.init(severity: .error, message: "Encapsulated Pixel Data contains no fragments."))
            return []
        }

        if let extendedOffsetTable {
            if extendedOffsetTable.offsets.count == numberOfFrames,
               let mapped = mapUsingOffsets(extendedOffsetTable.offsets, fragments: fragments, diagnostics: &diagnostics) {
                validateExtendedLengths(extendedOffsetTable.lengths, frameFragments: mapped, fragments: fragments, diagnostics: &diagnostics)
                return mapped
            }
            diagnostics.append(.init(
                severity: .error,
                message: "Extended Offset Table does not match \(numberOfFrames) frame(s)."
            ))
        }

        if !basicOffsetTable.offsets.isEmpty {
            if basicOffsetTable.offsets.count == numberOfFrames,
               let mapped = mapUsingOffsets(basicOffsetTable.offsets.map(UInt64.init), fragments: fragments, diagnostics: &diagnostics) {
                return mapped
            }
            diagnostics.append(.init(
                severity: .error,
                message: "Basic Offset Table has \(basicOffsetTable.offsets.count) entries for \(numberOfFrames) frame(s)."
            ))
        } else {
            diagnostics.append(.init(
                severity: .warning,
                message: "Basic Offset Table is empty; using fragment-count fallback when safe."
            ))
        }

        if numberOfFrames == 1 {
            return [fragments.map(\.index)]
        }
        if fragments.count == numberOfFrames {
            return fragments.map { [$0.index] }
        }

        diagnostics.append(.init(
            severity: .error,
            message: "Cannot safely map \(fragments.count) fragment(s) to \(numberOfFrames) frame(s) without a usable offset table."
        ))
        return []
    }

    static func mapUsingOffsets(
        _ offsets: [UInt64],
        fragments: [DicomEncapsulatedPixelDataFragment],
        diagnostics: inout [DicomEncapsulatedPixelDataDiagnostic]
    ) -> [[Int]]? {
        var startIndexes: [Int] = []
        startIndexes.reserveCapacity(offsets.count)

        for offset in offsets {
            guard let intOffset = Int(exactly: offset),
                  let fragment = fragments.first(where: { $0.relativeItemOffset == intOffset }) else {
                diagnostics.append(.init(
                    severity: .error,
                    message: "Offset table entry \(offset) does not point to a fragment item."
                ))
                return nil
            }
            startIndexes.append(fragment.index)
        }

        guard startIndexes == startIndexes.sorted(), Set(startIndexes).count == startIndexes.count else {
            diagnostics.append(.init(
                severity: .error,
                message: "Offset table entries must be strictly increasing."
            ))
            return nil
        }

        var frameFragments: [[Int]] = []
        frameFragments.reserveCapacity(startIndexes.count)
        for frameIndex in 0..<startIndexes.count {
            let start = startIndexes[frameIndex]
            let end = frameIndex + 1 < startIndexes.count ? startIndexes[frameIndex + 1] : fragments.count
            guard start < end else {
                diagnostics.append(.init(
                    severity: .error,
                    message: "Offset table maps frame \(frameIndex) to an empty fragment range."
                ))
                return nil
            }
            frameFragments.append(Array(start..<end))
        }
        return frameFragments
    }

    static func validateExtendedLengths(
        _ lengths: [UInt64],
        frameFragments: [[Int]],
        fragments: [DicomEncapsulatedPixelDataFragment],
        diagnostics: inout [DicomEncapsulatedPixelDataDiagnostic]
    ) {
        guard lengths.count == frameFragments.count else { return }
        for frameIndex in frameFragments.indices {
            let actualLength = frameFragments[frameIndex].reduce(0) { partial, fragmentIndex in
                fragments.indices.contains(fragmentIndex) ? partial + fragments[fragmentIndex].length : partial
            }
            if UInt64(actualLength) != lengths[frameIndex] {
                diagnostics.append(.init(
                    severity: .warning,
                    message: "Extended Offset Table length for frame \(frameIndex) is \(lengths[frameIndex]) but fragments contain \(actualLength) byte(s)."
                ))
            }
        }
    }
}
