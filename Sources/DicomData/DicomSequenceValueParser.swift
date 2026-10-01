import Foundation

public enum DicomDataSetParser {
    /// Reads through the existing parser with explicit value validation and a bounded recovery report.
    public static func read(from data: Data, transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
                            mode: DicomDataSetReadMode = .strict, limits: DicomDataSetParseLimits = .default,
                            privateDictionary: DicomPrivateDictionary = .standard,
                            maximumDiagnostics: Int = 128, dictionary: DCMDictionary = DCMDictionary(),
                            purpose: DicomDataSetPurpose = .instance) throws -> DicomDataSetReadResult {
        var state = DicomDataSetParseState(limits: limits, privateDictionary: privateDictionary,
                                          mode: mode, maximumDiagnostics: maximumDiagnostics, resolvesContext: true,
                                          dictionary: dictionary, purpose: purpose)
        let dataSet = try readDataSet(from: data, transferSyntax: transferSyntax, state: &state)
        return DicomDataSetReadResult(dataSet: dataSet, diagnostics: state.diagnostics)
    }

    static func readDataSet(from data: Data, transferSyntax: DicomTransferSyntax,
                            state: inout DicomDataSetParseState) throws -> DicomDataSet {
        try Task.checkCancellation()
        let payload = transferSyntax.usesDataSetDeflate ? try DicomDeflatedDataSetCodec.inflate(data) : data
        var offset = 0
        let parsed = try DicomSequenceValueParser.parseDataSet(in: payload, offset: &offset, end: payload.count,
            littleEndian: !transferSyntax.isBigEndian, explicitVR: transferSyntax.isExplicitVR, state: &state)
        return try DicomContextualVRResolver.resolve(parsed, state: &state)
    }

    /// Parses metadata elements from an encoded dataset.
    ///
    /// Pixel Data is intentionally omitted because the value-type dataset does not preserve
    /// encapsulated fragment boundaries. The parser still skips the encoded pixel payload and
    /// continues parsing any following metadata elements. Callers that need pixels must retain
    /// and consume the original encoded dataset bytes.
    public static func dataSet(from data: Data,
                               transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian) throws -> DicomDataSet {
        try dataSet(from: data, transferSyntax: transferSyntax, limits: .default)
    }

    /// Parses metadata elements with an explicit structural resource budget.
    public static func dataSet(from data: Data,
                               transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
                               limits: DicomDataSetParseLimits) throws -> DicomDataSet {
        try dataSet(from: data, transferSyntax: transferSyntax, limits: limits, privateDictionary: .standard)
    }

    /// Resolves private implicit VRs using each dataset item's own creator reservations.
    public static func dataSet(from data: Data,
                               transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
                               limits: DicomDataSetParseLimits,
                               privateDictionary: DicomPrivateDictionary) throws -> DicomDataSet {
        try dataSet(from: data, startingAt: 0, transferSyntax: transferSyntax, limits: limits,
                    privateDictionary: privateDictionary)
    }

    /// Parses the dataset that starts `offset` bytes into `data`, such as the one after a Part 10 File Meta,
    /// without copying it out first (issue #2793).
    public static func dataSet(from data: Data,
                               startingAt offset: Int,
                               transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
                               limits: DicomDataSetParseLimits = .default,
                               privateDictionary: DicomPrivateDictionary = .standard) throws -> DicomDataSet {
        try Task.checkCancellation()
        let payload = transferSyntax.usesDataSetDeflate
            ? try DicomDeflatedDataSetCodec.inflate(Data(data.dropFirst(offset)))
            : data
        try Task.checkCancellation()
        var offset = transferSyntax.usesDataSetDeflate ? 0 : offset
        var state = DicomDataSetParseState(limits: limits, privateDictionary: privateDictionary, resolvesContext: true)
        let parsed = try DicomSequenceValueParser.parseDataSet(
            in: payload,
            offset: &offset,
            end: payload.count,
            littleEndian: !transferSyntax.isBigEndian,
            explicitVR: transferSyntax.isExplicitVR,
            state: &state
        )
        return try DicomContextualVRResolver.resolve(parsed, state: &state)
    }
}

package enum DicomSequenceValueParser {
    package typealias ValueLengthLimit = @Sendable (
        _ tag: Int,
        _ vr: DicomVR,
        _ precedingElements: [DicomDataElement]
    ) -> Int?
    package typealias ValueDataReader = (_ data: Data, _ range: Range<Int>, _ tag: Int, _ vr: DicomVR) -> Data

    private static let itemTag = 0xFFFEE000
    private static let itemDelimiterTag = 0xFFFEE00D
    private static let sequenceDelimiterTag = 0xFFFEE0DD
    private static let undefinedLength = UInt32.max
    private static let tagDictionary = DCMDictionary()

    package static func undefinedLengthSequenceBounds(
        in data: Data,
        valueOffset: Int,
        end: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        characterSet: DicomSpecificCharacterSet = .defaultCharacterSet,
        valueLengthLimit: ValueLengthLimit? = nil,
        valueDataReader: ValueDataReader? = nil,
        limits: DicomDataSetParseLimits = .default
    ) throws -> (valueLength: Int, endOffset: Int) {
        var offset = valueOffset
        var state = DicomDataSetParseState(limits: limits)
        let sequenceDepth = try state.nestedSequenceDepth(after: 0)
        let result = try parseSequenceItemsResult(
            in: data,
            offset: &offset,
            end: end,
            littleEndian: littleEndian,
            explicitVR: explicitVR,
            characterSet: characterSet,
            requiresSequenceDelimiter: true,
            valueLengthLimit: valueLengthLimit,
            valueDataReader: valueDataReader,
            state: &state,
            sequenceDepth: sequenceDepth
        )
        guard let delimiterOffset = result.delimiterOffset else {
            throw DicomSequenceValueParserError.missingSequenceDelimiter
        }
        return (delimiterOffset - valueOffset, offset)
    }

    package static func parseItems(
        in data: Data,
        valueOffset: Int,
        valueLength: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        characterSet: DicomSpecificCharacterSet = .defaultCharacterSet,
        valueLengthLimit: ValueLengthLimit? = nil,
        valueDataReader: ValueDataReader? = nil,
        limits: DicomDataSetParseLimits = .default
    ) throws -> [DicomSequenceItem] {
        try parseItems(in: data, valueOffset: valueOffset, valueLength: valueLength,
            littleEndian: littleEndian, explicitVR: explicitVR, characterSet: characterSet,
            valueLengthLimit: valueLengthLimit, valueDataReader: valueDataReader, limits: limits,
            parentContext: nil, parentSequenceTag: 0)
    }

    package static func parseItems(
        in data: Data,
        valueOffset: Int,
        valueLength: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        characterSet: DicomSpecificCharacterSet = .defaultCharacterSet,
        valueLengthLimit: ValueLengthLimit? = nil,
        valueDataReader: ValueDataReader? = nil,
        limits: DicomDataSetParseLimits = .default,
        parentContext: DicomPixelValueContext?,
        parentSequenceTag: Int
    ) throws -> [DicomSequenceItem] {
        guard valueOffset >= 0,
              valueLength >= 0,
              valueOffset <= data.count,
              valueLength <= data.count - valueOffset else {
            throw DicomSequenceValueParserError.invalidBounds
        }

        var offset = valueOffset
        var state = DicomDataSetParseState(limits: limits, resolvesContext: parentContext != nil)
        if parentContext != nil { state.itemPath = [parentSequenceTag] }
        let sequenceDepth = try state.nestedSequenceDepth(after: 0)
        let items = try parseSequenceItemsResult(
            in: data,
            offset: &offset,
            end: valueOffset + valueLength,
            littleEndian: littleEndian,
            explicitVR: explicitVR,
            characterSet: characterSet,
            requiresSequenceDelimiter: false,
            valueLengthLimit: valueLengthLimit,
            valueDataReader: valueDataReader,
            state: &state,
            sequenceDepth: sequenceDepth
        ).items
        guard let parentContext else { return items }
        return try items.enumerated().map { index, item in
            .init(dataSet: try DicomContextualVRResolver.resolve(item.dataSet,
                path: [parentSequenceTag, index], inheritedContext: parentContext, state: &state))
        }
    }

    static func parseDataSet(
        in data: Data,
        offset: inout Int,
        end: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        characterSet: DicomSpecificCharacterSet = .defaultCharacterSet,
        state: inout DicomDataSetParseState
    ) throws -> DicomDataSet {
        try parseDataSet(
            in: data,
            offset: &offset,
            end: end,
            littleEndian: littleEndian,
            explicitVR: explicitVR,
            inheritedCharacterSet: characterSet,
            requiresItemDelimiter: false,
            valueLengthLimit: nil,
            valueDataReader: nil,
            state: &state,
            sequenceDepth: 0
        )
    }

    private static func parseDataSet(
        in data: Data,
        offset: inout Int,
        end: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        inheritedCharacterSet: DicomSpecificCharacterSet?,
        requiresItemDelimiter: Bool,
        valueLengthLimit: ValueLengthLimit?,
        valueDataReader: ValueDataReader?,
        state: inout DicomDataSetParseState,
        sequenceDepth: Int
    ) throws -> DicomDataSet {
        var elements: [DicomDataElement] = []
        var characterSet = inheritedCharacterSet
        // Each item owns its reservations. Parent creators are deliberately absent.
        var privateCreators: [Int: String] = [:]
        var privateCreatorNames: [Int: Set<String>] = [:]
        var seenTags: Set<Int> = []

        while offset < end {
            try Task.checkCancellation()
            state.recordStructuralLocation()
            guard offset + 8 <= end else {
                throw requiresItemDelimiter
                    ? DicomSequenceValueParserError.missingItemDelimiter
                    : DicomSequenceValueParserError.unexpectedEnd
            }

            let tag = try readTag(data, offset: &offset, littleEndian: littleEndian)
            if tag == itemDelimiterTag || tag == sequenceDelimiterTag {
                let delimiterLength = try readUInt32(data, offset: &offset, littleEndian: littleEndian)
                try validateDelimiterLength(delimiterLength, tag: tag)
                if tag == itemDelimiterTag, requiresItemDelimiter {
                    return DicomDataSet(elements: elements)
                }
                throw tag == itemDelimiterTag
                    ? DicomSequenceValueParserError.unexpectedItemDelimiter
                    : DicomSequenceValueParserError.unexpectedSequenceDelimiter
            }
            state.recordStructuralLocation(tag: tag)
            try state.consumeElement()
            var elementHeader = try readElementHeader(
                data,
                offset: &offset,
                tag: tag,
                littleEndian: littleEndian,
                explicitVR: explicitVR,
                dictionary: state.dictionary
            )
            if state.mode != nil, !seenTags.insert(tag).inserted {
                // A dataset cannot represent both values. Recovery must not
                // discard one, especially a creator or a contextual discriminator.
                throw state.diagnostic(.duplicateElement, tag: tag, offset: offset)
            }
            if !explicitVR {
                if DicomPrivateDictionary.isCreatorTag(tag) {
                    elementHeader.vr = .LO
                } else if !(tag >> 16).isMultiple(of: 2), tag & 0xFFFF >= 0x1000 {
                    let creatorTag = (tag & 0xFFFF0000) | ((tag >> 8) & 0xFF)
                    elementHeader.vr = privateCreators[creatorTag].flatMap {
                        state.privateDictionary.vr(group: UInt16(tag >> 16), creator: $0, offset: UInt8(tag & 0xFF))
                    } ?? .UN
                }
            }
            if state.mode != nil, DicomPrivateDictionary.isCreatorTag(tag), elementHeader.vr == .SQ {
                throw state.diagnostic(.invalidPrivateCreator, tag: tag, offset: offset)
            }
            let definition = state.dictionary.definition(forTag: tag)
            if state.mode != nil, let definition,
               elementHeader.vr == .SQ || definition.valueRepresentations.contains(.SQ),
               elementHeader.vr != .UN, !definition.valueRepresentations.contains(elementHeader.vr) {
                // A conflicting sequence changes structural interpretation and is fatal in both modes.
                throw state.diagnostic(.incompatibleVR, tag: tag, offset: offset)
            }

            if [0x7FE00010, 0x7FE00008, 0x7FE00009].contains(tag) {
                state.recordPixelDataHeader(tag: tag, vr: elementHeader.vr, length: elementHeader.length, valueOffset: offset)
            }
            if tag == DicomTag.pixelData.rawValue {
                state.recordOmittedPixelData(tag: tag)
                if state.mode != nil, elementHeader.vr != .UN,
                   let definition, !definition.valueRepresentations.contains(elementHeader.vr) {
                    try state.diagnose(.incompatibleVR, tag: tag, offset: offset)
                }
                try skipPixelData(
                    in: data,
                    offset: &offset,
                    end: end,
                    length: elementHeader.length,
                    littleEndian: littleEndian,
                    state: &state
                )
                continue
            }

            if elementHeader.vr == .SQ {
                state.itemPath.append(tag)
                defer { state.itemPath.removeLast() }
                let nestedDepth = try state.nestedSequenceDepth(after: sequenceDepth)
                let items: [DicomSequenceItem]
                if elementHeader.length == undefinedLength {
                    items = try parseSequenceItemsResult(
                        in: data,
                        offset: &offset,
                        end: end,
                        littleEndian: littleEndian,
                        explicitVR: explicitVR,
                        characterSet: characterSet,
                        requiresSequenceDelimiter: true,
                        valueLengthLimit: valueLengthLimit,
                        valueDataReader: valueDataReader,
                        state: &state,
                        sequenceDepth: nestedDepth
                    ).items
                } else {
                    let sequenceEnd = try boundedEnd(
                        offset: offset,
                        length: Int(elementHeader.length),
                        end: end,
                        error: DicomSequenceValueParserError.elementExceedsBounds(tag)
                    )
                    items = try parseSequenceItemsResult(
                        in: data,
                        offset: &offset,
                        end: sequenceEnd,
                        littleEndian: littleEndian,
                        explicitVR: explicitVR,
                        characterSet: characterSet,
                        requiresSequenceDelimiter: false,
                        valueLengthLimit: valueLengthLimit,
                        valueDataReader: valueDataReader,
                        state: &state,
                        sequenceDepth: nestedDepth
                    ).items
                    offset = sequenceEnd
                }
                elements.append(DicomDataElement(tag: tag, vr: .SQ, value: .sequence(items)))
            } else {
                if elementHeader.vr == .UN && elementHeader.length == undefinedLength {
                    state.itemPath.append(tag)
                    defer { state.itemPath.removeLast() }
                    let nestedDepth = try state.nestedSequenceDepth(after: sequenceDepth)
                    let items = try parseSequenceItemsResult(
                        in: data,
                        offset: &offset,
                        end: end,
                        littleEndian: littleEndian,
                        explicitVR: false,
                        characterSet: characterSet,
                        requiresSequenceDelimiter: true,
                        valueLengthLimit: valueLengthLimit,
                        valueDataReader: valueDataReader,
                        state: &state,
                        sequenceDepth: nestedDepth
                    ).items
                    elements.append(DicomDataElement(tag: tag, vr: .SQ, value: .sequence(items)))
                    continue
                }
                guard elementHeader.length != undefinedLength else {
                    throw DicomSequenceValueParserError.unsupportedUndefinedLengthElement(tag)
                }
                let declaredValueLength = Int(elementHeader.length)
                let valueEnd = try boundedEnd(
                    offset: offset,
                    length: declaredValueLength,
                    end: end,
                    error: DicomSequenceValueParserError.elementExceedsBounds(tag)
                )
                let requestedValueLength = min(
                    declaredValueLength,
                    max(0, valueLengthLimit?(tag, elementHeader.vr, elements) ?? declaredValueLength)
                )
                let valueRange = offset..<(offset + requestedValueLength)
                let absoluteRange = (data.startIndex + valueRange.lowerBound)..<(data.startIndex + valueRange.upperBound)
                let valueData = valueDataReader?(data, absoluteRange, tag, elementHeader.vr)
                    ?? Data(data[absoluteRange])
                offset = valueEnd
                // Issue #2835: an explicit UN on a public tag whose dictionary gives it one VR carries that VR's
                // value in Implicit VR Little Endian (PS3.5 6.2.2); multi-VR tags keep their contextual rules.
                var valueLittleEndian = littleEndian
                if explicitVR, elementHeader.vr == .UN, (tag >> 16).isMultiple(of: 2),
                   !DicomContextualVRResolver.needsContext(tag),
                   let vrs = definition?.valueRepresentations, vrs.count == 1, let dictionaryVR = vrs.first,
                   dictionaryVR != .SQ, dictionaryVR != .UN {
                    elementHeader.vr = dictionaryVR
                    valueLittleEndian = true
                }
                if state.resolvesContext, DicomContextualVRResolver.needsContext(tag),
                   valueData.count.isMultiple(of: 2), !valueData.isEmpty {
                    state.contextualValues[state.itemPath + [tag]] = .init(bytes: valueData, vr: elementHeader.vr,
                        explicitVR: explicitVR, littleEndian: valueLittleEndian, offset: valueRange.lowerBound)
                }
                let decodedValue: DicomDataValue
                if state.mode != nil {
                    var textFailure: DicomDataSetReadResult.Diagnostic.Reason?
                    do {
                        if DicomPrivateDictionary.isCreatorTag(tag),
                           let creator = try DicomPrivateDictionary.creatorIdentifier(vr: elementHeader.vr, bytes: valueData),
                           privateCreatorNames[tag >> 16, default: []].contains(creator) {
                            throw DicomDataSetReadResult.Diagnostic.Reason.duplicatePrivateCreator
                        }
                        if let definition, elementHeader.vr != .UN, !definition.valueRepresentations.contains(elementHeader.vr) {
                            throw DicomDataSetReadResult.Diagnostic.Reason.incompatibleVR
                        }
                        if !explicitVR, !valueData.isEmpty, let definition, definition.valueRepresentations.count > 1,
                           !definition.valueRepresentations.contains(.OW), !DicomContextualVRResolver.needsContext(tag) {
                            throw DicomDataSetReadResult.Diagnostic.Reason.ambiguousVR
                        }
                        // An invalid text value comes back as a reason, not as a throw: it is the
                        // common finding in old data sets and a throw per value is measurable.
                        switch try validatedValue(for: elementHeader.vr, data: valueData,
                            littleEndian: valueLittleEndian,
                            characterSet: DicomPrivateDictionary.isCreatorTag(tag) ? .defaultCharacterSet : characterSet,
                            purpose: state.purpose, preserveLeadingWhitespace: tag == 0x00080201) {
                        case .failure(let reason):
                            textFailure = reason
                            decodedValue = .bytes(valueData)
                        case .success(let value):
                            if let definition, elementHeader.vr != .UN,
                               !definition.acceptsMultiplicity(of: DicomDataElement(tag: tag, vr: elementHeader.vr, value: value),
                                   purpose: state.purpose) {
                                throw DicomDataSetReadResult.Diagnostic.Reason.invalidMultiplicity
                            }
                            decodedValue = value
                        }
                    } catch {
                        let reason: DicomDataSetReadResult.Diagnostic.Reason
                        if let failure = error as? DicomDataSetReadResult.Diagnostic.Reason { reason = failure }
                        else if error as? DicomSpecificCharacterSet.Failure == .unsupportedDeclaration { reason = .unsupportedCharacterSet }
                        else { reason = .invalidTextEncoding }
                        try state.diagnose(reason, tag: tag, offset: valueRange.lowerBound)
                        elementHeader.vr = .UN
                        decodedValue = .bytes(valueData)
                    }
                    if let textFailure {
                        try state.diagnose(textFailure, tag: tag, offset: valueRange.lowerBound)
                        elementHeader.vr = .UN
                    }
                } else {
                    decodedValue = value(for: elementHeader.vr, data: valueData,
                                         littleEndian: valueLittleEndian, characterSet: characterSet ?? .defaultCharacterSet)
                }
                elements.append(DicomDataElement(
                    tag: tag,
                    vr: elementHeader.vr,
                    value: decodedValue
                ))
                if DicomPrivateDictionary.isCreatorTag(tag),
                   let creator = try? DicomPrivateDictionary.creatorIdentifier(vr: elementHeader.vr, bytes: valueData),
                   privateCreatorNames[tag >> 16, default: []].insert(creator).inserted {
                    privateCreators[tag] = creator
                }
                if tag == DicomTag.specificCharacterSet.rawValue {
                    switch decodedValue {
                    case .strings(let terms):
                        let declared = DicomSpecificCharacterSet(definedTerms: terms)
                        characterSet = declared
                        if state.mode != nil {
                            do { try declared.validateDeclaration() }
                            catch { try state.diagnose(.unsupportedCharacterSet, tag: tag, offset: valueRange.lowerBound) }
                        }
                    case .empty: characterSet = .defaultCharacterSet
                    default:
                        // Recovery retained the declaration's bytes, but its
                        // meaning is unavailable to this dataset and descendants.
                        characterSet = nil
                    }
                }
            }
        }

        if requiresItemDelimiter {
            state.recordStructuralLocation()
            throw DicomSequenceValueParserError.missingItemDelimiter
        }
        return DicomDataSet(elements: elements)
    }

    private struct SequenceParseResult {
        let items: [DicomSequenceItem]
        let delimiterOffset: Int?
    }

    private static func parseSequenceItemsResult(
        in data: Data,
        offset: inout Int,
        end: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        characterSet: DicomSpecificCharacterSet?,
        requiresSequenceDelimiter: Bool,
        valueLengthLimit: ValueLengthLimit? = nil,
        valueDataReader: ValueDataReader? = nil,
        state: inout DicomDataSetParseState,
        sequenceDepth: Int
    ) throws -> SequenceParseResult {
        var items: [DicomSequenceItem] = []

        while offset < end {
            try Task.checkCancellation()
            state.recordStructuralLocation()
            guard offset + 8 <= end else {
                throw requiresSequenceDelimiter
                    ? DicomSequenceValueParserError.missingSequenceDelimiter
                    : DicomSequenceValueParserError.unexpectedEnd
            }

            let tagOffset = offset
            let tag = try readTag(data, offset: &offset, littleEndian: littleEndian)
            let length = try readUInt32(data, offset: &offset, littleEndian: littleEndian)

            if tag == sequenceDelimiterTag {
                try validateDelimiterLength(length, tag: tag)
                guard requiresSequenceDelimiter else {
                    throw DicomSequenceValueParserError.unexpectedSequenceDelimiter
                }
                return SequenceParseResult(items: items, delimiterOffset: tagOffset)
            }

            if tag == itemDelimiterTag {
                try validateDelimiterLength(length, tag: tag)
                throw DicomSequenceValueParserError.unexpectedItemDelimiter
            }

            guard tag == itemTag else {
                throw DicomSequenceValueParserError.expectedItem(tag)
            }
            state.recordStructuralLocation(item: items.count)
            try state.consumeItem()
            state.itemPath.append(items.count)
            defer { state.itemPath.removeLast() }

            if length == undefinedLength {
                let dataSet = try parseDataSet(
                    in: data,
                    offset: &offset,
                    end: end,
                    littleEndian: littleEndian,
                    explicitVR: explicitVR,
                    inheritedCharacterSet: characterSet,
                    requiresItemDelimiter: true,
                    valueLengthLimit: valueLengthLimit,
                    valueDataReader: valueDataReader,
                    state: &state,
                    sequenceDepth: sequenceDepth
                )
                items.append(DicomSequenceItem(dataSet: dataSet))
            } else {
                let itemEnd = try boundedEnd(
                    offset: offset,
                    length: Int(length),
                    end: end,
                    error: DicomSequenceValueParserError.itemExceedsBounds
                )
                let dataSet = try parseDataSet(
                    in: data,
                    offset: &offset,
                    end: itemEnd,
                    littleEndian: littleEndian,
                    explicitVR: explicitVR,
                    inheritedCharacterSet: characterSet,
                    requiresItemDelimiter: false,
                    valueLengthLimit: valueLengthLimit,
                    valueDataReader: valueDataReader,
                    state: &state,
                    sequenceDepth: sequenceDepth
                )
                items.append(DicomSequenceItem(dataSet: dataSet))
                offset = itemEnd
            }
        }

        if requiresSequenceDelimiter {
            state.recordStructuralLocation()
            throw DicomSequenceValueParserError.missingSequenceDelimiter
        }
        return SequenceParseResult(items: items, delimiterOffset: nil)
    }

    private static func validateDelimiterLength(_ length: UInt32, tag: Int) throws {
        guard length == 0 else {
            throw DicomSequenceValueParserError.invalidDelimiterLength(tag: tag, length: length)
        }
    }

    private static func boundedEnd(offset: Int, length: Int, end: Int, error: Error) throws -> Int {
        guard offset >= 0, length >= 0, offset <= end, length <= end - offset else {
            throw error
        }
        return offset + length
    }

    package static func readElementHeader(
        _ data: Data,
        offset: inout Int,
        tag: Int,
        littleEndian: Bool,
        explicitVR: Bool
    ) throws -> (vr: DicomVR, length: UInt32) {
        try readElementHeader(data, offset: &offset, tag: tag, littleEndian: littleEndian,
                              explicitVR: explicitVR, dictionary: tagDictionary)
    }

    private static func readElementHeader(
        _ data: Data, offset: inout Int, tag: Int, littleEndian: Bool,
        explicitVR: Bool, dictionary: DCMDictionary
    ) throws -> (vr: DicomVR, length: UInt32) {
        if explicitVR {
            let vrCode = try readASCII(data, offset: &offset, length: 2)
            guard let vr = DicomVR(code: vrCode) else {
                throw DicomSequenceValueParserError.unsupportedVR(vrCode)
            }
            if vr.uses32BitLength {
                guard offset + 2 <= data.count else {
                    throw DicomSequenceValueParserError.unexpectedEnd
                }
                offset += 2
                return (vr, try readUInt32(data, offset: &offset, littleEndian: littleEndian))
            }
            return (vr, UInt32(try readUInt16(data, offset: &offset, littleEndian: littleEndian)))
        }

        let vr = dictionary.vrCode(forTag: tag).flatMap(DicomVR.init(code:)) ?? implicitVR(for: tag)
        return (vr, try readUInt32(data, offset: &offset, littleEndian: littleEndian))
    }

    private static func implicitVR(for tag: Int) -> DicomVR {
        switch tag {
        case DicomTag.sharedFunctionalGroupsSequence.rawValue,
             DicomTag.perFrameFunctionalGroupsSequence.rawValue,
             DicomTag.frameContentSequence.rawValue,
             DicomTag.planePositionSequence.rawValue,
             DicomTag.planeOrientationSequence.rawValue,
             DicomTag.pixelMeasuresSequence.rawValue,
             DicomTag.frameVOILUTSequence.rawValue,
             DicomTag.derivationImageSequence.rawValue,
             DicomTag.sourceImageSequence.rawValue,
             DicomTag.referencedSOPSequence.rawValue,
             DicomTag.referencedSeriesSequence.rawValue,
             DicomTag.segmentSequence.rawValue,
             DicomTag.segmentedPropertyCategoryCodeSequence.rawValue,
             DicomTag.segmentedPropertyTypeCodeSequence.rawValue,
             DicomTag.segmentIdentificationSequence.rawValue,
             DicomTag.surfaceSequence.rawValue,
             DicomTag.surfacePointsSequence.rawValue,
             DicomTag.surfacePointsNormalsSequence.rawValue,
             DicomTag.surfaceMeshPrimitivesSequence.rawValue,
             DicomTag.triangleStripSequence.rawValue,
             DicomTag.triangleFanSequence.rawValue,
             DicomTag.lineSequence.rawValue,
             DicomTag.referencedSurfaceSequence.rawValue,
             DicomTag.segmentSurfaceSourceInstanceSequence.rawValue,
             DicomTag.facetSequence.rawValue,
             DicomTag.referencedFrameOfReferenceSequence.rawValue,
             DicomTag.rtReferencedStudySequence.rawValue,
             DicomTag.rtReferencedSeriesSequence.rawValue,
             DicomTag.contourImageSequence.rawValue,
             DicomTag.structureSetROISequence.rawValue,
             DicomTag.rtROIObservationsSequence.rawValue,
             DicomTag.roiContourSequence.rawValue,
             DicomTag.contourSequence.rawValue,
             DicomTag.beamSequence.rawValue,
             DicomTag.controlPointSequence.rawValue,
             DicomTag.patientSetupSequence.rawValue,
             DicomTag.referencedSetupImageSequence.rawValue,
             DicomTag.referencedRTPlanSequence.rawValue,
             DicomTag.referencedReferenceImageSequence.rawValue,
             DicomTag.referencedStructureSetSequence.rawValue,
             DicomTag.referencedDoseSequence.rawValue,
             DicomTag.modalityLUTSequence.rawValue,
             DicomTag.voiLUTSequence.rawValue,
             DicomTag.presentationLUTSequence.rawValue,
             DicomTag.realWorldValueMappingSequence.rawValue,
             DicomTag.quantityDefinitionSequence.rawValue,
             DicomTag.measurementUnitsCodeSequence.rawValue,
             DicomTag.conceptNameCodeSequence.rawValue,
             DicomTag.conceptCodeSequence.rawValue,
             DicomTag.measuredValueSequence.rawValue,
             DicomTag.currentRequestedProcedureEvidenceSequence.rawValue,
             DicomTag.pertinentOtherEvidenceSequence.rawValue,
             DicomTag.contentTemplateSequence.rawValue,
             DicomTag.contentSequence.rawValue,
             DicomTag.sourceInstanceSequence.rawValue,
             DicomTag.waveformSequence.rawValue,
             DicomTag.channelDefinitionSequence.rawValue,
             DicomTag.channelSourceSequence.rawValue,
             DicomTag.channelSourceModifiersSequence.rawValue,
             DicomTag.sourceWaveformSequence.rawValue,
             DicomTag.channelSensitivityUnitsSequence.rawValue,
             DicomTag.waveformPresentationGroupSequence.rawValue,
             DicomTag.referencedImageSequence.rawValue,
             DicomTag.graphicAnnotationSequence.rawValue,
             DicomTag.textObjectSequence.rawValue,
             DicomTag.graphicObjectSequence.rawValue,
             DicomTag.graphicLayerSequence.rawValue,
             DicomTag.displayedAreaSelectionSequence.rawValue,
             DicomTag.radiopharmaceuticalInformationSequence.rawValue:
            return .SQ
        case DicomTag.dimensionIndexValues.rawValue,
             DicomTag.temporalPositionIndex.rawValue,
             DicomTag.frameAcquisitionNumber.rawValue,
             DicomTag.inStackPositionNumber.rawValue,
             DicomTag.numberOfWaveformSamples.rawValue,
             DicomTag.triggerSamplePosition.rawValue,
             DicomTag.numberOfSurfaces.rawValue,
             DicomTag.surfaceNumber.rawValue,
             DicomTag.numberOfSurfacePoints.rawValue,
             DicomTag.numberOfVectors.rawValue,
             DicomTag.surfaceCount.rawValue,
             DicomTag.referencedSurfaceNumber.rawValue:
            return .UL
        case DicomTag.longPrimitivePointIndexList.rawValue,
             DicomTag.longTrianglePointIndexList.rawValue:
            return .OL
        case DicomTag.lutDescriptor.rawValue,
             DicomTag.realWorldValueFirstValueMapped.rawValue,
             DicomTag.realWorldValueLastValueMapped.rawValue,
             DicomTag.segmentNumber.rawValue,
             DicomTag.referencedSegmentNumber.rawValue,
             DicomTag.recommendedDisplayCIELabValue.rawValue,
             DicomTag.maximumFractionalValue.rawValue,
             DicomTag.numberOfWaveformChannels.rawValue,
             DicomTag.waveformBitsStored.rawValue,
             DicomTag.waveformBitsAllocated.rawValue,
             DicomTag.referencedWaveformChannels.rawValue,
             DicomTag.graphicLayerRecommendedDisplayGrayscaleValue.rawValue,
             DicomTag.graphicLayerRecommendedDisplayCIELabValue.rawValue,
             DicomTag.graphicDimensions.rawValue,
             DicomTag.numberOfGraphicPoints.rawValue,
             DicomTag.imageRotation.rawValue:
            return .US
        case DicomTag.vectorDimensionality.rawValue:
            return .US
        case DicomTag.pointCoordinatesData.rawValue,
             DicomTag.vectorCoordinateData.rawValue:
            return .OF
        case DicomTag.recommendedPresentationOpacity.rawValue:
            return .FL
        case DicomTag.trianglePointIndexList.rawValue,
             DicomTag.primitivePointIndexList.rawValue:
            return .OW
        case DicomTag.lutData.rawValue:
            // LUT Data is US or OW. In Implicit VR, preserving the raw words
            // lets the descriptor-aware validator handle both encodings,
            // including packed 8-bit OW data.
            return .OW
        case DicomTag.roiNumber.rawValue,
             DicomTag.roiDisplayColor.rawValue,
             DicomTag.numberOfContourPoints.rawValue,
             DicomTag.contourNumber.rawValue,
             DicomTag.observationNumber.rawValue,
             DicomTag.referencedROINumber.rawValue,
             DicomTag.beamNumber.rawValue,
             DicomTag.numberOfControlPoints.rawValue,
             DicomTag.controlPointIndex.rawValue,
             DicomTag.waveformChannelNumber.rawValue,
             DicomTag.shutterLeftVerticalEdge.rawValue,
             DicomTag.shutterRightVerticalEdge.rawValue,
             DicomTag.shutterUpperHorizontalEdge.rawValue,
             DicomTag.shutterLowerHorizontalEdge.rawValue,
             DicomTag.centerOfCircularShutter.rawValue,
             DicomTag.radiusOfCircularShutter.rawValue,
             DicomTag.verticesOfPolygonalShutter.rawValue,
             DicomTag.graphicLayerOrder.rawValue:
            return .IS
        case DicomTag.realWorldValueSlope.rawValue,
             DicomTag.realWorldValueIntercept.rawValue,
             DicomTag.realWorldValueLUTData.rawValue,
             DicomTag.doubleFloatRealWorldValueFirstValueMapped.rawValue,
             DicomTag.doubleFloatRealWorldValueLastValueMapped.rawValue,
             DicomTag.floatingPointValue.rawValue:
            return .FD
        case DicomTag.referencedFrameNumber.rawValue,
             DicomTag.seriesNumber.rawValue,
             DicomTag.instanceNumber.rawValue,
             DicomTag.numberOfSeriesRelatedInstances.rawValue:
            return .IS
        case DicomTag.displayedAreaTopLeftHandCorner.rawValue,
             DicomTag.displayedAreaBottomRightHandCorner.rawValue:
            return .SL
        case DicomTag.pixelSpacing.rawValue,
             DicomTag.imagePositionPatient.rawValue,
             DicomTag.imageOrientationPatient.rawValue,
             DicomTag.sliceThickness.rawValue,
             DicomTag.sliceSpacing.rawValue,
             DicomTag.gridFrameOffsetVector.rawValue,
             DicomTag.doseGridScaling.rawValue,
             DicomTag.contourData.rawValue,
             DicomTag.sourceAxisDistance.rawValue,
             DicomTag.nominalBeamEnergy.rawValue,
             DicomTag.gantryAngle.rawValue,
             DicomTag.beamLimitingDeviceAngle.rawValue,
             DicomTag.patientSupportAngle.rawValue,
             DicomTag.tableTopEccentricAngle.rawValue,
             DicomTag.isocenterPosition.rawValue,
             DicomTag.cumulativeMetersetWeight.rawValue,
             DicomTag.windowCenter.rawValue,
             DicomTag.windowWidth.rawValue,
             DicomTag.rescaleIntercept.rawValue,
             DicomTag.rescaleSlope.rawValue,
             DicomTag.patientSize.rawValue,
             DicomTag.patientWeight.rawValue,
             DicomTag.radionuclideTotalDose.rawValue,
             DicomTag.radionuclideHalfLife.rawValue,
             DicomTag.decayFactor.rawValue,
             DicomTag.numericValue.rawValue,
             DicomTag.multiplexGroupTimeOffset.rawValue,
             DicomTag.triggerTimeOffset.rawValue,
             DicomTag.samplingFrequency.rawValue,
             DicomTag.channelSensitivity.rawValue,
             DicomTag.channelSensitivityCorrectionFactor.rawValue,
             DicomTag.channelBaseline.rawValue,
             DicomTag.channelTimeSkew.rawValue,
             DicomTag.channelSampleSkew.rawValue,
             DicomTag.channelOffset.rawValue,
             DicomTag.filterLowFrequency.rawValue,
             DicomTag.filterHighFrequency.rawValue,
             DicomTag.notchFilterFrequency.rawValue:
            return .DS
        case DicomTag.stackID.rawValue,
             DicomTag.codeValue.rawValue,
             DicomTag.codingSchemeDesignator.rawValue,
             DicomTag.mappingResource.rawValue,
             DicomTag.templateIdentifier.rawValue,
             DicomTag.realWorldValueLUTLabel.rawValue,
             DicomTag.multiplexGroupLabel.rawValue,
             DicomTag.channelLabel.rawValue:
            return .SH
        case DicomTag.referencedSOPClassUID.rawValue,
             DicomTag.referencedSOPInstanceUID.rawValue,
             DicomTag.sopClassUID.rawValue,
             DicomTag.sopInstanceUID.rawValue,
             DicomTag.referencedFrameOfReferenceUID.rawValue,
             DicomTag.trackingUID.rawValue,
             DicomTag.uid.rawValue:
            return .UI
        case DicomTag.photometricInterpretation.rawValue,
             DicomTag.imageType.rawValue,
             DicomTag.conversionType.rawValue,
             DicomTag.presentationLUTShape.rawValue,
             DicomTag.voiLUTFunction.rawValue,
             DicomTag.valueType.rawValue,
             DicomTag.relationshipType.rawValue,
             DicomTag.continuityOfContent.rawValue,
             DicomTag.graphicType.rawValue,
             DicomTag.graphicAnnotationUnits.rawValue,
             DicomTag.graphicFilled.rawValue,
             DicomTag.presentationSizeMode.rawValue,
             DicomTag.imageHorizontalFlip.rawValue,
             DicomTag.shutterShape.rawValue,
             DicomTag.completionFlag.rawValue,
             DicomTag.verificationFlag.rawValue,
             DicomTag.segmentationType.rawValue,
             DicomTag.segmentAlgorithmType.rawValue,
             DicomTag.segmentationFractionalType.rawValue,
             DicomTag.doseUnits.rawValue,
             DicomTag.doseType.rawValue,
             DicomTag.doseSummationType.rawValue,
             DicomTag.contourGeometricType.rawValue,
             DicomTag.roiGenerationAlgorithm.rawValue,
             DicomTag.rtROIInterpretedType.rawValue,
             DicomTag.rtPlanGeometry.rawValue,
             DicomTag.rtPlanRelationship.rawValue,
             DicomTag.beamType.rawValue,
             DicomTag.radiationType.rawValue,
             DicomTag.primaryDosimeterUnit.rawValue:
            return .CS
        case DicomTag.units.rawValue,
             DicomTag.suvType.rawValue,
             DicomTag.decayCorrection.rawValue,
             DicomTag.correctedImage.rawValue,
             DicomTag.patientSex.rawValue,
             DicomTag.modalitiesInStudy.rawValue,
             DicomTag.waveformOriginality.rawValue,
             DicomTag.channelStatus.rawValue,
             DicomTag.waveformSampleInterpretation.rawValue:
            return .CS
        case DicomTag.windowCenterWidthExplanation.rawValue,
             DicomTag.rescaleType.rawValue,
             DicomTag.lutExplanation.rawValue,
             DicomTag.modalityLUTType.rawValue,
             DicomTag.codeMeaning.rawValue,
             DicomTag.segmentLabel.rawValue,
             DicomTag.segmentAlgorithmName.rawValue,
             DicomTag.trackingID.rawValue,
             DicomTag.contentLabel.rawValue,
             DicomTag.graphicLayer.rawValue,
             DicomTag.structureSetName.rawValue,
             DicomTag.roiName.rawValue,
             DicomTag.roiObservationLabel.rawValue,
             DicomTag.rtPlanName.rawValue,
             DicomTag.beamName.rawValue,
             DicomTag.beamDescription.rawValue,
             DicomTag.treatmentMachineName.rawValue,
             DicomTag.secondaryCaptureDeviceID.rawValue,
             DicomTag.secondaryCaptureDeviceManufacturer.rawValue,
             DicomTag.secondaryCaptureDeviceManufacturerModelName.rawValue,
             DicomTag.secondaryCaptureDeviceSoftwareVersions.rawValue,
             DicomTag.channelDerivationDescription.rawValue:
            return .LO
        case DicomTag.segmentDescription.rawValue,
             DicomTag.contentDescription.rawValue,
             DicomTag.unformattedTextValue.rawValue,
             DicomTag.graphicLayerDescription.rawValue,
             DicomTag.structureSetDescription.rawValue,
             DicomTag.roiDescription.rawValue,
             DicomTag.rtPlanDescription.rawValue,
             DicomTag.derivationDescription.rawValue:
            return .ST
        case DicomTag.textValue.rawValue:
            return .UT
        case DicomTag.rationalNumeratorValue.rawValue:
            return .SL
        case DicomTag.rationalDenominatorValue.rawValue,
             DicomTag.encapsulatedDocumentLength.rawValue:
            return .UL
        case DicomTag.encapsulatedDocument.rawValue:
            return .OB
        case DicomTag.waveformData.rawValue,
             DicomTag.waveformPaddingValue.rawValue:
            return .OW
        case DicomTag.contentCreatorName.rawValue,
             DicomTag.roiInterpreter.rawValue,
             DicomTag.personName.rawValue:
            return .PN
        case DicomTag.radiopharmaceuticalStartTime.rawValue,
             DicomTag.acquisitionTime.rawValue,
             DicomTag.instanceCreationTime.rawValue,
             DicomTag.contentTime.rawValue,
             DicomTag.presentationCreationTime.rawValue,
             DicomTag.timeOfSecondaryCapture.rawValue,
             DicomTag.seriesTime.rawValue,
             DicomTag.time.rawValue:
            return .TM
        case DicomTag.radiopharmaceuticalStartDateTime.rawValue,
             DicomTag.dateTime.rawValue:
            return .DT
        case DicomTag.date.rawValue,
             DicomTag.instanceCreationDate.rawValue,
             DicomTag.contentDate.rawValue,
             DicomTag.presentationCreationDate.rawValue,
             DicomTag.dateOfSecondaryCapture.rawValue:
            return .DA
        case DicomTag.graphicData.rawValue,
             DicomTag.boundingBoxTopLeftHandCorner.rawValue,
             DicomTag.boundingBoxBottomRightHandCorner.rawValue,
             DicomTag.anchorPoint.rawValue,
             DicomTag.waveformDataDisplayScale.rawValue:
            return .FL
        case DicomTag.documentTitle.rawValue:
            return .ST
        case DicomTag.mimeTypeOfEncapsulatedDocument.rawValue,
             DicomTag.listOfMIMETypes.rawValue:
            return .LO
        default:
            return dictionaryVR(for: tag) ?? .UN
        }
    }

    /// Fallback for tags outside the curated switch above: resolves the VR from
    /// the bundled DICOM dictionary. Without this, implicit-VR network datasets
    /// (for example C-FIND responses) decode identifier tags as UN, whose bytes
    /// are dropped by every string accessor.
    private static func dictionaryVR(for tag: Int) -> DicomVR? {
        guard let code = tagDictionary.vrCode(forTag: tag) else { return nil }
        return DicomVR(code: code)
    }

    private static func value(
        for vr: DicomVR,
        data: Data,
        littleEndian: Bool,
        characterSet: DicomSpecificCharacterSet
    ) -> DicomDataValue {
        if let value = DicomDataValueDecoder.binaryValue(for: vr, data: data, littleEndian: littleEndian) {
            return value
        }
        if [.LT, .ST, .UT].contains(vr) {
            var value = data
            while value.last == 0x20 { value.removeLast() }
            let text = characterSet.decodePreservingWhitespace(value, vr: vr)
            return text.isEmpty ? .empty : .strings([text])
        }
        let text = characterSet.decode(data, vr: vr)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        let values = text.split(separator: "\\", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        }
        return values.isEmpty || (values.count == 1 && values[0].isEmpty) ? .empty : .strings(values)
    }

    private static func validatedValue(for vr: DicomVR, data: Data, littleEndian: Bool,
                                       characterSet: DicomSpecificCharacterSet?, purpose: DicomDataSetPurpose,
                                       preserveLeadingWhitespace: Bool) throws
        -> Result<DicomDataValue, DicomDataSetReadResult.Diagnostic.Reason> {
        let width: Int
        switch vr {
        case .US, .SS, .OW: width = 2
        case .UL, .SL, .FL, .OF, .OL, .AT: width = 4
        case .UV, .SV, .FD, .OD, .OV: width = 8
        default: width = 1
        }
        guard data.count.isMultiple(of: width) else { throw DicomDataSetReadResult.Diagnostic.Reason.invalidBinaryLength }
        guard data.count.isMultiple(of: 2) else { throw DicomDataSetReadResult.Diagnostic.Reason.invalidValueLength }
        if data.isEmpty { return .success(.empty) }
        if let binary = DicomDataValueDecoder.binaryValue(for: vr, data: data, littleEndian: littleEndian) { return .success(binary) }
        let extended = [DicomVR.SH, .LO, .PN, .LT, .ST, .UC, .UT].contains(vr)
        guard let encoding = extended ? characterSet : .defaultCharacterSet else {
            throw DicomSpecificCharacterSet.Failure.unsupportedDeclaration
        }
        let text = try encoding.decodeValidated(data, vr: vr)
        if let reason = DicomTextValueValidator.failure(text, vr: vr, characterSet: encoding, purpose: purpose,
                                                         includesPadding: true) { return .failure(reason) }
        if [.LT, .ST, .UT, .UR].contains(vr) {
            var value = text
            while value.last == " " { value.removeLast() }
            return .success(value.isEmpty ? .empty : .strings([value]))
        }
        let values = text.split(separator: "\\", omittingEmptySubsequences: false).map {
            // Timezone Offset From UTC forbids leading spaces despite its SH representation.
            // Keep that evidence for SOP Common without hiding source multiplicity.
            if preserveLeadingWhitespace, vr == .SH {
                var value = String($0)
                while value.last == " " { value.removeLast() }
                return value
            }
            return String($0).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\0")))
        }
        return .success(values.count == 1 && values[0].isEmpty ? .empty : .strings(values))
    }

    private static func skipPixelData(
        in data: Data,
        offset: inout Int,
        end: Int,
        length: UInt32,
        littleEndian: Bool,
        state: inout DicomDataSetParseState
    ) throws {
        try Task.checkCancellation()
        if length != undefinedLength {
            let valueEnd = try boundedEnd(
                offset: offset,
                length: Int(length),
                end: end,
                error: DicomSequenceValueParserError.elementExceedsBounds(DicomTag.pixelData.rawValue)
            )
            offset = valueEnd
            return
        }

        var fragmentIndex = 0
        while offset < end {
            try Task.checkCancellation()
            state.recordStructuralLocation(tag: DicomTag.pixelData.rawValue)
            guard offset + 8 <= end else {
                throw DicomSequenceValueParserError.unexpectedEnd
            }
            let tag = try readTag(data, offset: &offset, littleEndian: littleEndian)
            let itemLength = try readUInt32(data, offset: &offset, littleEndian: littleEndian)
            if tag == sequenceDelimiterTag {
                try validateDelimiterLength(itemLength, tag: tag)
                return
            }
            guard tag == itemTag else {
                throw DicomSequenceValueParserError.expectedItem(tag)
            }
            state.recordStructuralLocation(tag: DicomTag.pixelData.rawValue, item: fragmentIndex)
            try state.consumeItem()
            guard itemLength != undefinedLength else {
                throw DicomSequenceValueParserError.unsupportedUndefinedLengthElement(tag)
            }
            let itemEnd = try boundedEnd(
                offset: offset,
                length: Int(itemLength),
                end: end,
                error: DicomSequenceValueParserError.elementExceedsBounds(tag)
            )
            offset = itemEnd
            fragmentIndex += 1
        }
        state.recordStructuralLocation(tag: DicomTag.pixelData.rawValue)
        throw DicomSequenceValueParserError.missingSequenceDelimiter
    }

    package static func readTag(_ data: Data, offset: inout Int, littleEndian: Bool) throws -> Int {
        let group = try readUInt16(data, offset: &offset, littleEndian: littleEndian)
        let element = try readUInt16(data, offset: &offset, littleEndian: littleEndian)
        return Int(group) << 16 | Int(element)
    }

    private static func readASCII(_ data: Data, offset: inout Int, length: Int) throws -> String {
        guard offset >= 0, length >= 0, offset <= data.count, length <= data.count - offset else {
            throw DicomSequenceValueParserError.unexpectedEnd
        }
        let start = data.startIndex + offset
        let value = String(data: data[start..<(start + length)], encoding: .ascii) ?? ""
        offset += length
        return value
    }

    private static func readUInt16(_ data: Data, offset: inout Int, littleEndian: Bool) throws -> UInt16 {
        guard let value = data.dicomIntegerIfPresent(at: offset, as: UInt16.self, littleEndian: littleEndian) else {
            throw DicomSequenceValueParserError.unexpectedEnd
        }
        offset += 2
        return value
    }

    private static func readUInt32(_ data: Data, offset: inout Int, littleEndian: Bool) throws -> UInt32 {
        guard let value = data.dicomIntegerIfPresent(at: offset, as: UInt32.self, littleEndian: littleEndian) else {
            throw DicomSequenceValueParserError.unexpectedEnd
        }
        offset += 4
        return value
    }
}

package enum DicomSequenceValueParserError: Error, Equatable {
    case invalidBounds
    case unexpectedEnd
    case unsupportedVR(String)
    case expectedItem(Int)
    case itemExceedsBounds
    case elementExceedsBounds(Int)
    case unsupportedUndefinedLengthElement(Int)
    case missingItemDelimiter
    case missingSequenceDelimiter
    case unexpectedItemDelimiter
    case unexpectedSequenceDelimiter
    case invalidDelimiterLength(tag: Int, length: UInt32)
}
