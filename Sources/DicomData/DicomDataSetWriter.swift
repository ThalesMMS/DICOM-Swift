import Foundation

public struct DicomPart10WriterOptions: Equatable, Sendable {
    public var transferSyntax: DicomTransferSyntax
    public var mediaStorageSOPClassUID: String?
    public var mediaStorageSOPInstanceUID: String?
    public var implementationClassUID: String
    public var implementationVersionName: String
    /// Nil retains compatibility writing; a purpose enables standard VR/VM and value validation.
    public var validationPurpose: DicomDataSetPurpose?
    public var validationLimits: DicomDataSetParseLimits

    public init(transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
                mediaStorageSOPClassUID: String? = nil,
                mediaStorageSOPInstanceUID: String? = nil,
                implementationClassUID: String = DicomDataSetWriter.defaultImplementationClassUID,
                implementationVersionName: String = "DICOMCORE_1") {
        self.init(transferSyntax: transferSyntax, mediaStorageSOPClassUID: mediaStorageSOPClassUID,
            mediaStorageSOPInstanceUID: mediaStorageSOPInstanceUID, implementationClassUID: implementationClassUID,
            implementationVersionName: implementationVersionName, validationPurpose: nil)
    }

    public init(transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
                mediaStorageSOPClassUID: String? = nil,
                mediaStorageSOPInstanceUID: String? = nil,
                implementationClassUID: String = DicomDataSetWriter.defaultImplementationClassUID,
                implementationVersionName: String = "DICOMCORE_1",
                validationPurpose: DicomDataSetPurpose?, validationLimits: DicomDataSetParseLimits = .default) {
        self.transferSyntax = transferSyntax
        self.mediaStorageSOPClassUID = mediaStorageSOPClassUID
        self.mediaStorageSOPInstanceUID = mediaStorageSOPInstanceUID
        self.implementationClassUID = implementationClassUID
        self.implementationVersionName = implementationVersionName
        self.validationPurpose = validationPurpose
        self.validationLimits = validationLimits
    }
}

public enum DicomDataSetWriterError: Error, Equatable, Sendable {
    case compressedTransferSyntaxUnsupported(String)
    case transferSyntaxWriteUnsupported(uid: String, reason: String)
    case pixelRecompressionUnsupported(source: String, destination: String, reason: String)
    case invalidUID(String)
    case elementLengthTooLarge(tag: Int, length: Int)
    case unsupportedValue(tag: Int, vr: DicomVR, reason: String)
}

extension DicomDataSetWriterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .compressedTransferSyntaxUnsupported(let uid):
            return "Writing compressed transfer syntax \(uid) is not supported."
        case .transferSyntaxWriteUnsupported(let uid, let reason):
            return "Writing transfer syntax \(uid) is not supported: \(reason)"
        case .pixelRecompressionUnsupported(let source, let destination, let reason):
            return "Cannot transcode \(source) to transfer syntax \(destination): \(reason)"
        case .invalidUID(let uid):
            return "Invalid DICOM UID: \(uid)"
        case .elementLengthTooLarge(let tag, let length):
            return String(format: "Element %08X is too large to encode (%d bytes).", tag, length)
        case .unsupportedValue(let tag, let vr, let reason):
            return String(format: "Element %08X with VR %@ cannot be encoded: %@.", tag, vr.code, reason)
        }
    }
}

public enum DicomDataSetWriter {
    public static let defaultSecondaryCaptureImageStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    public static let defaultImplementationClassUID = "2.25.330343123637717097393106239205252367490"

    private static let sopClassUIDTag = 0x00080016
    private static let fileMetaGroupLengthTag = 0x00020000
    private static let fileMetaInformationVersionTag = 0x00020001
    private static let mediaStorageSOPClassUIDTag = 0x00020002
    private static let mediaStorageSOPInstanceUIDTag = 0x00020003
    private static let implementationClassUIDTag = 0x00020012
    private static let implementationVersionNameTag = 0x00020013
    private static let itemTag = 0xFFFEE000
    private static let undefinedLength = UInt32.max

    public static func makeUID() -> String {
        let uuid = UUID().uuid
        let bytes = [
            uuid.0, uuid.1, uuid.2, uuid.3,
            uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11,
            uuid.12, uuid.13, uuid.14, uuid.15
        ]
        return "2.25.\(decimalString(forUUIDBytes: bytes))"
    }

    public static func part10Data(from dataSet: DicomDataSet,
                                  options: DicomPart10WriterOptions = DicomPart10WriterOptions()) throws -> Data {
        try validateWriteSupport(for: dataSet, transferSyntax: options.transferSyntax)
        if options.validationPurpose != nil { try validateStructure(dataSet, limits: options.validationLimits) }

        var data = Data(capacity: estimatedEncodedSize(of: dataSet))
        data.append(contentsOf: [UInt8](repeating: 0, count: 128))
        data.append(contentsOf: "DICM".utf8)

        data.append(try fileMetaData(for: dataSet, options: options))
        let context = part10EncodingContext(for: dataSet, options: options)
        if options.transferSyntax.usesDataSetDeflate {
            let encodedDataSet = try encodeDataSet(dataSet, context: context, skipFileMeta: true)
            data.append(try DicomDeflatedDataSetCodec.deflate(encodedDataSet))
        } else {
            // Encoding straight into the output keeps one copy of large values instead of two.
            try forEachEncodableElement(of: dataSet, context: context, skipFileMeta: true) { element, context in
                try appendElement(element, to: &data, context: context)
            }
        }
        return data
    }

    /// Wraps an already encoded dataset in DICOM Part 10 file metadata without re-encoding it.
    public static func part10Data(fromEncodedDataSet dataSetData: Data,
                                  transferSyntax: DicomTransferSyntax,
                                  mediaStorageSOPClassUID: String,
                                  mediaStorageSOPInstanceUID: String) throws -> Data {
        guard !transferSyntax.usesDataSetDeflate else {
            throw DicomDataSetWriterError.transferSyntaxWriteUnsupported(
                uid: transferSyntax.rawValue,
                reason: "fromEncodedDataSet writing does not support deflate transfer syntaxes."
            )
        }
        let options = DicomPart10WriterOptions(
            transferSyntax: transferSyntax,
            mediaStorageSOPClassUID: mediaStorageSOPClassUID,
            mediaStorageSOPInstanceUID: mediaStorageSOPInstanceUID
        )
        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)
        data.append(try fileMetaData(for: DicomDataSet(), options: options))
        data.append(dataSetData)
        return data
    }

    public static func dataSetData(from dataSet: DicomDataSet,
                                   transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian) throws -> Data {
        try encodeDataSetData(from: dataSet, transferSyntax: transferSyntax, purpose: nil, limits: .default)
    }

    /// Validates standard VR/VM, textual forms and contextual values before returning encoded bytes.
    public static func dataSetData(from dataSet: DicomDataSet,
                                   transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
                                   purpose: DicomDataSetPurpose,
                                   limits: DicomDataSetParseLimits = .default) throws -> Data {
        try encodeDataSetData(from: dataSet, transferSyntax: transferSyntax, purpose: purpose, limits: limits)
    }

    private static func encodeDataSetData(from dataSet: DicomDataSet, transferSyntax: DicomTransferSyntax,
                                          purpose: DicomDataSetPurpose?, limits: DicomDataSetParseLimits) throws -> Data {
        if purpose != nil { try validateStructure(dataSet, limits: limits) }
        try validateWriteSupport(for: dataSet, transferSyntax: transferSyntax)

        let encodedDataSet = try encodeDataSet(
            dataSet,
            context: .init(transferSyntax: transferSyntax,
                           characterSet: DicomSpecificCharacterSet(dataSet.string(for: .specificCharacterSet)), purpose: purpose),
            skipFileMeta: true
        )
        if transferSyntax.usesDataSetDeflate {
            return try DicomDeflatedDataSetCodec.deflate(encodedDataSet)
        }
        return encodedDataSet
    }

    /// Writes the Part 10 file in blocks: large binary values (Pixel Data) go from the dataset
    /// to the file without an encoded copy. The file appears at `url` only when complete.
    public static func write(_ dataSet: DicomDataSet,
                             to url: URL,
                             options: DicomPart10WriterOptions = DicomPart10WriterOptions()) throws {
        guard !options.transferSyntax.usesDataSetDeflate else {
            // Dataset deflate compresses the whole encoded dataset at once.
            let data = try part10Data(from: dataSet, options: options)
            try data.write(to: url, options: [.atomic])
            return
        }
        try validateWriteSupport(for: dataSet, transferSyntax: options.transferSyntax)
        if options.validationPurpose != nil { try validateStructure(dataSet, limits: options.validationLimits) }

        let fileManager = FileManager.default
        let partial = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).partial")
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: partial.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            var buffer = Data(capacity: streamingFlushSize)
            buffer.append(contentsOf: [UInt8](repeating: 0, count: 128))
            buffer.append(contentsOf: "DICM".utf8)
            buffer.append(try fileMetaData(for: dataSet, options: options))
            let context = part10EncodingContext(for: dataSet, options: options)
            try forEachEncodableElement(of: dataSet, context: context, skipFileMeta: true) { element, context in
                if (element.bytesValue?.count ?? 0) >= streamingValueThreshold,
                   !shouldWriteEncapsulatedPixelData(element, context: context) {
                    let (vr, value) = try encodedValue(for: element, context: context)
                    try appendElementHeader(tag: element.tag, vr: vr, length: value.count, to: &buffer, context: context)
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                    try handle.write(contentsOf: value)
                } else {
                    try appendElement(element, to: &buffer, context: context)
                    if buffer.count >= streamingFlushSize {
                        try handle.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            }
            try handle.write(contentsOf: buffer)
            try handle.synchronize()
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: partial)
            } else {
                try fileManager.moveItem(at: partial, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    /// Values at least this large are written from the dataset instead of being copied into a block.
    private static let streamingValueThreshold = 1 << 20
    private static let streamingFlushSize = 4 << 20

    private static func part10EncodingContext(for dataSet: DicomDataSet,
                                              options: DicomPart10WriterOptions) -> EncodingContext {
        .init(transferSyntax: options.transferSyntax,
              characterSet: DicomSpecificCharacterSet(dataSet.string(for: .specificCharacterSet)),
              purpose: options.validationPurpose)
    }

    /// Preamble, file meta and the top-level binary values, so the output buffer rarely grows.
    private static func estimatedEncodedSize(of dataSet: DicomDataSet) -> Int {
        dataSet.elements.reduce(64 << 10) { $0 + ($1.bytesValue?.count ?? 0) + 16 }
    }

    private static func fileMetaData(for dataSet: DicomDataSet,
                                     options: DicomPart10WriterOptions) throws -> Data {
        let sopClassUID = try validUID(
            options.mediaStorageSOPClassUID ??
            dataSet.string(for: sopClassUIDTag) ??
            defaultSecondaryCaptureImageStorageSOPClassUID
        )
        let sopInstanceUID = try validUID(
            options.mediaStorageSOPInstanceUID ??
            dataSet.string(for: .sopInstanceUID) ??
            makeUID()
        )
        let implementationClassUID = try validUID(options.implementationClassUID)

        let metaWithoutLength = DicomDataSet(elements: [
            DicomDataElement(tag: fileMetaInformationVersionTag, vr: .OB, value: .bytes(Data([0x00, 0x01]))),
            DicomDataElement(tag: mediaStorageSOPClassUIDTag, vr: .UI, value: .strings([sopClassUID])),
            DicomDataElement(tag: mediaStorageSOPInstanceUIDTag, vr: .UI, value: .strings([sopInstanceUID])),
            DicomDataElement(tag: DicomTag.transferSyntaxUID.rawValue, vr: .UI, value: .strings([options.transferSyntax.rawValue])),
            DicomDataElement(tag: implementationClassUIDTag, vr: .UI, value: .strings([implementationClassUID])),
            DicomDataElement(tag: implementationVersionNameTag, vr: .SH, value: .strings([options.implementationVersionName]))
        ])

        let context = EncodingContext(transferSyntax: .explicitVRLittleEndian, purpose: options.validationPurpose)
        let encodedMeta = try encodeDataSet(metaWithoutLength, context: context, skipFileMeta: false)
        let groupLength = DicomDataSet(elements: [
            DicomDataElement(tag: fileMetaGroupLengthTag,
                             vr: .UL,
                             value: .unsignedIntegers([UInt(encodedMeta.count)]))
        ])

        var data = try encodeDataSet(groupLength, context: context, skipFileMeta: false)
        data.append(encodedMeta)
        return data
    }

    private static func encodeDataSet(_ dataSet: DicomDataSet,
                                      context: EncodingContext,
                                      skipFileMeta: Bool) throws -> Data {
        var data = Data()
        try forEachEncodableElement(of: dataSet, context: context, skipFileMeta: skipFileMeta) { element, context in
            try appendElement(element, to: &data, context: context)
        }
        return data
    }

    /// Resolves the character set and pixel context, validates each element for the purpose, and hands
    /// every element to `body` in order, so callers choose where the encoded bytes go.
    private static func forEachEncodableElement(of dataSet: DicomDataSet,
                                                context: EncodingContext,
                                                skipFileMeta: Bool,
                                                _ body: (DicomDataElement, EncodingContext) throws -> Void) throws {
        var context = context
        if context.purpose != nil { context.pixelContext = DicomPixelValueContext(dataSet, inheriting: context.pixelContext) }
        if let terms = dataSet.element(for: .specificCharacterSet)?.stringValues {
            context.characterSet = DicomSpecificCharacterSet(definedTerms: terms)
            if context.purpose != nil {
                do { try context.characterSet.validateDeclaration() }
                catch {
                    throw DicomDataSetWriterError.unsupportedValue(tag: DicomTag.specificCharacterSet.rawValue,
                        vr: .CS, reason: "Unsupported Specific Character Set declaration")
                }
            }
        }
        var privateCreatorNames: [Int: Set<String>] = [:]
        for element in dataSet.elements where !(skipFileMeta && element.group == 0x0002) {
            if context.purpose != nil, element.vr != .UN, let definition = context.dictionary.definition(forTag: element.tag) {
                guard definition.valueRepresentations.contains(element.vr),
                      definition.acceptsMultiplicity(of: element, purpose: context.purpose ?? .instance) else {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: element.vr,
                        reason: "Value representation or multiplicity conflicts with the standard dictionary")
                }
            }
            // UN retains opaque bytes from recovery without establishing a reservation.
            if context.purpose != nil, DicomPrivateDictionary.isCreatorTag(element.tag), element.vr != .UN {
                let values: [String]
                switch element.value {
                case .empty: values = []
                case .strings(let strings): values = strings
                default:
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: element.vr,
                        reason: "Private Creator requires LO text with VM 1")
                }
                guard values.count <= 1 else {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: element.vr,
                        reason: "Private Creator requires VM 1")
                }
                let creator: String?
                do {
                    creator = try DicomPrivateDictionary.creatorIdentifier(vr: element.vr,
                        bytes: Data((values.first ?? "").utf8))
                } catch {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: element.vr,
                        reason: "Invalid Private Creator identifier")
                }
                if let creator, !privateCreatorNames[element.group, default: []].insert(creator).inserted {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: element.vr,
                        reason: "Private Creator identifier already reserves a block in this group")
                }
            }
            try body(element, context)
        }
    }

    private static func validateStructure(_ dataSet: DicomDataSet, limits: DicomDataSetParseLimits) throws {
        var state = DicomDataSetParseState(limits: limits)
        try validateStructure(dataSet, depth: 0, state: &state)
    }

    private static func validateStructure(_ dataSet: DicomDataSet, depth: Int,
                                          state: inout DicomDataSetParseState) throws {
        for element in dataSet.elements {
            try Task.checkCancellation()
            try state.consumeElement()
            if case .sequence(let items) = element.value {
                let nestedDepth = try state.nestedSequenceDepth(after: depth)
                for item in items {
                    try state.consumeItem()
                    try validateStructure(item.dataSet, depth: nestedDepth, state: &state)
                }
            }
        }
    }

    private static func appendElement(_ element: DicomDataElement,
                                      to data: inout Data,
                                      context: EncodingContext) throws {
        if shouldWriteEncapsulatedPixelData(element, context: context) {
            appendEncapsulatedPixelDataElement(element, vr: writableVR(element.vr), to: &data, context: context)
            return
        }
        let (vr, value) = try encodedValue(for: element, context: context)
        try appendElementHeader(tag: element.tag, vr: vr, length: value.count, to: &data, context: context)
        data.append(value)
    }

    /// The written VR and value bytes of a native element, validated for the context.
    private static func encodedValue(for element: DicomDataElement,
                                     context: EncodingContext) throws -> (vr: DicomVR, value: Data) {
        let vr = writableVR(element.vr)
        let value = try valueData(for: element, vr: vr, context: context)
        if context.purpose != nil, DicomContextualVRResolver.needsContext(element.tag), !value.isEmpty {
            try DicomContextualVRResolver.validateWrittenElement(element, bytes: value,
                explicitVR: context.explicitVR, littleEndian: context.littleEndian,
                context: context.pixelContext, path: context.itemPath)
        }
        return (vr, value)
    }

    private static func appendElementHeader(tag: Int, vr: DicomVR, length: Int,
                                            to data: inout Data, context: EncodingContext) throws {
        appendTag(tag, to: &data, littleEndian: context.littleEndian)
        if context.explicitVR {
            // Issue #2835: a value too long for a 16-bit length (a large Contour Data, say) goes out as UN with a
            // 32-bit length, as GDCM and DCMTK write it; readers take its VR back from the dictionary.
            if !vr.uses32BitLength, length > Int(UInt16.max) {
                oversizedValueLogger.warning(String(format: "(%04X,%04X) %@ value of %d bytes written as UN",
                                                    (tag >> 16) & 0xFFFF, tag & 0xFFFF, vr.code, length))
                data.append(contentsOf: DicomVR.UN.code.utf8)
                data.append(contentsOf: [0x00, 0x00])
                try appendUInt32Length(length, tag: tag, to: &data, littleEndian: context.littleEndian)
                return
            }
            data.append(contentsOf: vr.code.utf8)
            if vr.uses32BitLength {
                data.append(contentsOf: [0x00, 0x00])
                try appendUInt32Length(length, tag: tag, to: &data, littleEndian: context.littleEndian)
            } else {
                guard length <= Int(UInt16.max) else {
                    throw DicomDataSetWriterError.elementLengthTooLarge(tag: tag, length: length)
                }
                appendUInt16(UInt16(length), to: &data, littleEndian: context.littleEndian)
            }
        } else {
            try appendUInt32Length(length, tag: tag, to: &data, littleEndian: context.littleEndian)
        }
    }

    private static func appendEncapsulatedPixelDataElement(_ element: DicomDataElement,
                                                           vr: DicomVR,
                                                           to data: inout Data,
                                                           context: EncodingContext) {
        appendTag(element.tag, to: &data, littleEndian: context.littleEndian)
        if context.explicitVR {
            data.append(contentsOf: vr.code.utf8)
            data.append(contentsOf: [0x00, 0x00])
        }
        appendUInt32(undefinedLength, to: &data, littleEndian: context.littleEndian)
        data.append(binaryData(for: element))
    }

    private static func shouldWriteEncapsulatedPixelData(_ element: DicomDataElement,
                                                         context: EncodingContext) -> Bool {
        element.tag == DicomTag.pixelData.rawValue &&
            context.transferSyntax.writeSupport.status == .encapsulatedPassThrough &&
            hasEncapsulatedPixelData(element)
    }

    static func validateWriteSupport(for dataSet: DicomDataSet,
                                     transferSyntax: DicomTransferSyntax) throws {
        let support = transferSyntax.writeSupport
        let pixelData = dataSet.element(for: .pixelData)
        let hasPixelData = pixelData != nil
        let hasEncapsulatedPixels = hasEncapsulatedPixelData(in: dataSet)

        switch support.status {
        case .nativeDataset, .deflatedDataset:
            if hasEncapsulatedPixels {
                throw DicomDataSetWriterError.pixelRecompressionUnsupported(
                    source: "encapsulated Pixel Data",
                    destination: transferSyntax.rawValue,
                    reason: "native and deflated dataset writing require native pixel bytes; "
                        + "decode the compressed frames before writing this transfer syntax."
                )
            }
        case .encapsulatedPassThrough:
            guard hasEncapsulatedPixels else {
                throw DicomDataSetWriterError.pixelRecompressionUnsupported(
                    source: hasPixelData ? "native Pixel Data" : "missing Pixel Data",
                    destination: transferSyntax.rawValue,
                    reason: "compressed transfer syntax writing only preserves already encapsulated Pixel Data; "
                        + "DICOM-Swift does not encode compressed frames."
                )
            }
        case .referencedDataset:
            if hasPixelData {
                throw DicomDataSetWriterError.transferSyntaxWriteUnsupported(
                    uid: transferSyntax.rawValue,
                    reason: "referenced transfer syntaxes use Pixel Data Provider URL; "
                        + "local Pixel Data is not rewritten."
                )
            }
            guard hasPixelDataProviderURL(in: dataSet) else {
                throw DicomDataSetWriterError.transferSyntaxWriteUnsupported(
                    uid: transferSyntax.rawValue,
                    reason: "referenced transfer syntax writing requires Pixel Data Provider URL (0028,7FE0)."
                )
            }
        case .unsupported:
            throw DicomDataSetWriterError.transferSyntaxWriteUnsupported(
                uid: transferSyntax.rawValue,
                reason: support.diagnostic
            )
        }
    }

    private static func valueData(for element: DicomDataElement,
                                  vr: DicomVR,
                                  context: EncodingContext) throws -> Data {
        switch vr {
        case .OW where context.purpose != nil:
            return try validatedBinaryData(for: element, wordWidth: 2)
        case .OW:
            if case .bytes(let data) = element.value { return paddedBytes(data, padding: 0x00) }
            return try unsignedIntegers(for: element).reduce(into: Data()) {
                guard let value = UInt16(exactly: $1) else {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr, reason: "OW value is outside UInt16 range")
                }
                appendUInt16(value, to: &$0, littleEndian: context.littleEndian)
            }
        case .OB, .UN:
            let data = context.purpose == nil ? binaryData(for: element) : try validatedBinaryData(for: element)
            return paddedBytes(data, padding: 0x00)
        case .OV:
            if context.purpose != nil { return try validatedBinaryData(for: element, wordWidth: 8) }
            if case .bytes(let data) = element.value { return paddedBytes(data, padding: 0x00) }
            return try unsignedIntegers(for: element).reduce(into: Data()) {
                appendUInt64(UInt64($1), to: &$0, littleEndian: context.littleEndian)
            }
        case .OF:
            if element.bytesValue != nil {
                return try validatedBinaryData(for: element, wordWidth: 4)
            }
            return try floats(for: element).reduce(into: Data()) {
                appendUInt32(try float32($1, element: element).bitPattern, to: &$0, littleEndian: context.littleEndian)
            }
        case .OD:
            if element.bytesValue != nil {
                return try validatedBinaryData(for: element, wordWidth: 8)
            }
            return try floats(for: element).reduce(into: Data()) {
                appendUInt64($1.bitPattern, to: &$0, littleEndian: context.littleEndian)
            }
        case .SQ:
            return try sequenceData(for: element, context: context)
        case .US:
            return try unsignedIntegers(for: element).reduce(into: Data()) {
                guard let value = UInt16(exactly: $1) else {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr, reason: "US value is outside UInt16 range")
                }
                appendUInt16(value, to: &$0, littleEndian: context.littleEndian)
            }
        case .SS:
            let values = try signedIntegers(for: element)
            return try values.enumerated().reduce(into: Data()) { output, component in
                if DicomContextualVRResolver.lutDescriptorTags.contains(element.tag), values.count == 3,
                   component.offset != 1, let value = UInt16(exactly: component.element) {
                    appendUInt16(value, to: &output, littleEndian: context.littleEndian)
                    return
                }
                guard let value = Int16(exactly: component.element) else {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr, reason: "SS value is outside Int16 range")
                }
                appendUInt16(UInt16(bitPattern: value), to: &output, littleEndian: context.littleEndian)
            }
        case .OL, .UL:
            return try unsignedIntegers(for: element).reduce(into: Data()) {
                guard let value = UInt32(exactly: $1) else {
                    throw DicomDataSetWriterError.unsupportedValue(
                        tag: element.tag,
                        vr: vr,
                        reason: "\(vr.code) value is outside UInt32 range"
                    )
                }
                appendUInt32(value, to: &$0, littleEndian: context.littleEndian)
            }
        case .SL:
            return try signedIntegers(for: element).reduce(into: Data()) {
                guard let value = Int32(exactly: $1) else {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr, reason: "SL value is outside Int32 range")
                }
                appendUInt32(UInt32(bitPattern: value), to: &$0, littleEndian: context.littleEndian)
            }
        case .SV:
            return try signedIntegers(for: element).reduce(into: Data()) {
                appendUInt64(UInt64(bitPattern: Int64($1)), to: &$0, littleEndian: context.littleEndian)
            }
        case .UV:
            return try unsignedIntegers(for: element).reduce(into: Data()) {
                appendUInt64(UInt64($1), to: &$0, littleEndian: context.littleEndian)
            }
        case .FL:
            return try floats(for: element).reduce(into: Data()) {
                appendUInt32(try float32($1, element: element).bitPattern, to: &$0, littleEndian: context.littleEndian)
            }
        case .FD:
            return try floats(for: element).reduce(into: Data()) {
                appendUInt64($1.bitPattern, to: &$0, littleEndian: context.littleEndian)
            }
        case .AT:
            return try unsignedIntegers(for: element).reduce(into: Data()) {
                guard let tag = UInt32(exactly: $1) else {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr, reason: "AT value is outside UInt32 range")
                }
                appendUInt16(UInt16((tag >> 16) & 0xFFFF), to: &$0, littleEndian: context.littleEndian)
                appendUInt16(UInt16(tag & 0xFFFF), to: &$0, littleEndian: context.littleEndian)
            }
        default:
            return try paddedStringData(for: element, vr: vr, context: context)
        }
    }

    private static func sequenceData(for element: DicomDataElement,
                                     context: EncodingContext) throws -> Data {
        let items: [DicomSequenceItem]
        switch element.value {
        case .sequence(let sequenceItems): items = sequenceItems
        // A zero-length sequence is a legal empty value (PS3.5 7.5): it encodes with no items.
        case .empty: items = []
        default: throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: .SQ, reason: "expected sequence items")
        }

        var data = Data()
        for (index, item) in items.enumerated() {
            var itemContext = context
            itemContext.itemPath += [element.tag, index]
            let itemData = try encodeDataSet(item.dataSet, context: itemContext, skipFileMeta: true)
            appendTag(itemTag, to: &data, littleEndian: context.littleEndian)
            try appendUInt32Length(itemData.count, tag: element.tag, to: &data, littleEndian: context.littleEndian)
            data.append(itemData)
        }
        return data
    }

    private static func writableVR(_ vr: DicomVR) -> DicomVR {
        switch vr {
        case .unknown, .implicitRaw:
            return .UN
        default:
            return vr
        }
    }

    private static func binaryData(for element: DicomDataElement) -> Data {
        if let data = element.bytesValue {
            return data
        }
        return Data(stringValues(for: element).joined(separator: "\\").utf8)
    }

    private static func validatedBinaryData(for element: DicomDataElement, wordWidth: Int = 1) throws -> Data {
        let bytes: Data
        switch element.value {
        case .empty: bytes = Data()
        case .bytes(let value): bytes = value
        default:
            throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: element.vr, reason: "Expected binary bytes")
        }
        guard bytes.count.isMultiple(of: wordWidth) else {
            throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: element.vr, reason: "Incomplete binary word")
        }
        return bytes
    }

    private static func float32(_ value: Double, element: DicomDataElement) throws -> Float {
        let result = Float(value)
        guard !value.isFinite || result.isFinite else {
            throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: element.vr, reason: "Finite value exceeds Float32 range")
        }
        return result
    }

    private static func hasEncapsulatedPixelData(in dataSet: DicomDataSet) -> Bool {
        guard let element = dataSet.element(for: .pixelData) else { return false }
        return hasEncapsulatedPixelData(element)
    }

    private static func hasPixelDataProviderURL(in dataSet: DicomDataSet) -> Bool {
        guard let url = dataSet.string(for: .pixelDataProviderURL) else { return false }
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasEncapsulatedPixelData(_ element: DicomDataElement) -> Bool {
        guard element.tag == DicomTag.pixelData.rawValue else { return false }
        let data = binaryData(for: element)
        guard data.count >= 8 else { return false }
        return data[0] == 0xFE &&
            data[1] == 0xFF &&
            data[2] == 0x00 &&
            data[3] == 0xE0
    }

    private static func paddedBytes(_ data: Data, padding: UInt8) -> Data {
        var copy = data
        if copy.count % 2 != 0 {
            copy.append(padding)
        }
        return copy
    }

    private static func paddedStringData(for element: DicomDataElement,
                                         vr: DicomVR,
                                         context: EncodingContext) throws -> Data {
        switch element.value {
        case .bytes, .sequence:
            throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr, reason: "Expected text values")
        default: break
        }
        let values: [String]
        if vr == .DS, case .floats(let numbers) = element.value {
            values = try numbers.map { try decimalString($0, tag: element.tag) }
        } else {
            values = stringValues(for: element)
        }
        if vr == .DS {
            for value in values { try validateDecimalString(value, tag: element.tag) }
        }
        let singleValue = [DicomVR.LT, .ST, .UT, .UR].contains(vr)
        guard singleValue ? values.count <= 1 : !values.contains(where: { $0.contains("\\") }) else {
            throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr,
                reason: "Text components would change multiplicity when encoded")
        }
        let extended = [DicomVR.SH, .LO, .PN, .LT, .ST, .UC, .UT].contains(vr)
            && !DicomPrivateDictionary.isCreatorTag(element.tag)
        let characterSet = extended ? context.characterSet : .defaultCharacterSet
        if let purpose = context.purpose {
            do {
                try DicomTextValueValidator.validate(values.joined(separator: "\\"), vr: vr,
                    characterSet: characterSet, purpose: purpose, includesPadding: false)
            } catch {
                throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr, reason: "Invalid textual value")
            }
        }
        let data: Data
        do { data = try characterSet.encodeValidated(values.joined(separator: "\\"), vr: vr) }
        catch {
            throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr,
                reason: "Text cannot be represented in the declared character set")
        }
        let padding: UInt8 = vr == .UI ? 0x00 : 0x20
        return paddedBytes(data, padding: padding)
    }

    private static func validateDecimalString(_ value: String, tag: Int) throws {
        let grammar = #"\A *[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)? *\z"#
        let isEmpty = value.allSatisfy { $0 == " " }
        guard value.utf8.count <= 16,
              isEmpty || (value.range(of: grammar, options: .regularExpression) != nil &&
                Double(value.trimmingCharacters(in: CharacterSet(charactersIn: " ")))?.isFinite == true) else {
            throw DicomDataSetWriterError.unsupportedValue(tag: tag, vr: .DS,
                reason: "DS requires a finite decimal number with optional SPACE padding in at most 16 bytes")
        }
    }

    private static func decimalString(_ value: Double, tag: Int) throws -> String {
        if value.isFinite {
            for precision in stride(from: 17, through: 1, by: -1) {
                let text = String(format: "%.*g", locale: Locale(identifier: "en_US_POSIX"), precision, value)
                if text.utf8.count <= 16, let parsed = Double(text), parsed.isFinite {
                    return text
                }
            }
        }
        throw DicomDataSetWriterError.unsupportedValue(tag: tag, vr: .DS,
            reason: "DS requires a finite decimal value representable in at most 16 characters")
    }

    private static func stringValues(for element: DicomDataElement) -> [String] {
        switch element.value {
        case .empty:
            return []
        case .strings(let values):
            return values
        case .signedIntegers(let values):
            return values.map { String($0) }
        case .unsignedIntegers(let values):
            return values.map { String($0) }
        case .floats(let values):
            return values.map { String($0) }
        case .bytes(let data):
            return String(data: data, encoding: .ascii).map { [$0] } ?? []
        case .sequence:
            return []
        }
    }

    private static func signedIntegers(for element: DicomDataElement) throws -> [Int] {
        switch element.value {
        case .signedIntegers(let values):
            return values
        case .unsignedIntegers(let values):
            return try values.map {
                guard let value = Int(exactly: $0) else { throw invalidNumericValue(element) }
                return value
            }
        default:
            return try numericStrings(for: element).map {
                guard let value = Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw invalidNumericValue(element) }
                return value
            }
        }
    }

    private static func unsignedIntegers(for element: DicomDataElement) throws -> [UInt] {
        switch element.value {
        case .unsignedIntegers(let values):
            return values
        case .signedIntegers(let values):
            return try values.map {
                guard let value = UInt(exactly: $0) else { throw invalidNumericValue(element) }
                return value
            }
        default:
            return try numericStrings(for: element).map {
                guard let value = UInt($0.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw invalidNumericValue(element) }
                return value
            }
        }
    }

    private static func floats(for element: DicomDataElement) throws -> [Double] {
        switch element.value {
        case .floats(let values):
            return values
        default:
            return try numericStrings(for: element).map {
                guard let value = Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw invalidNumericValue(element) }
                return value
            }
        }
    }

    private static func numericStrings(for element: DicomDataElement) throws -> [String] {
        switch element.value {
        case .bytes, .sequence: throw invalidNumericValue(element)
        default: stringValues(for: element)
        }
    }

    private static func invalidNumericValue(_ element: DicomDataElement) -> DicomDataSetWriterError {
        .unsupportedValue(tag: element.tag, vr: element.vr, reason: "Numeric value cannot be represented without dropping a component")
    }

    private static func validUID(_ value: String) throws -> String {
        let uid = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        let isValid = !uid.isEmpty &&
            uid.count <= 64 &&
            uid.first != "." &&
            uid.last != "." &&
            uid.allSatisfy { $0.isNumber || $0 == "." } &&
            !uid.contains("..")
        guard isValid else {
            throw DicomDataSetWriterError.invalidUID(value)
        }
        return uid
    }

    private static func appendTag(_ tag: Int, to data: inout Data, littleEndian: Bool) {
        appendUInt16(UInt16((tag >> 16) & 0xFFFF), to: &data, littleEndian: littleEndian)
        appendUInt16(UInt16(tag & 0xFFFF), to: &data, littleEndian: littleEndian)
    }

    private static func appendUInt32Length(_ length: Int,
                                           tag: Int,
                                           to data: inout Data,
                                           littleEndian: Bool) throws {
        guard length <= Int(UInt32.max) else {
            throw DicomDataSetWriterError.elementLengthTooLarge(tag: tag, length: length)
        }
        appendUInt32(UInt32(length), to: &data, littleEndian: littleEndian)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data, littleEndian: Bool) {
        if littleEndian {
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8(value >> 8))
        } else {
            data.append(UInt8(value >> 8))
            data.append(UInt8(value & 0x00FF))
        }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data, littleEndian: Bool) {
        if littleEndian {
            data.append(UInt8(value & 0x000000FF))
            data.append(UInt8((value >> 8) & 0x000000FF))
            data.append(UInt8((value >> 16) & 0x000000FF))
            data.append(UInt8(value >> 24))
        } else {
            data.append(UInt8(value >> 24))
            data.append(UInt8((value >> 16) & 0x000000FF))
            data.append(UInt8((value >> 8) & 0x000000FF))
            data.append(UInt8(value & 0x000000FF))
        }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data, littleEndian: Bool) {
        if littleEndian {
            for shift in stride(from: 0, through: 56, by: 8) {
                data.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        } else {
            for shift in stride(from: 56, through: 0, by: -8) {
                data.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
        }
    }

    private static func decimalString(forUUIDBytes bytes: [UInt8]) -> String {
        var working = bytes
        var digits: [UInt8] = []

        while working.contains(where: { $0 != 0 }) {
            var remainder = 0
            for index in working.indices {
                let value = remainder * 256 + Int(working[index])
                working[index] = UInt8(value / 10)
                remainder = value % 10
            }
            digits.append(UInt8(remainder))
        }

        if digits.isEmpty {
            return "0"
        }
        return digits.reversed().map { String($0) }.joined()
    }
}

private let oversizedValueLogger = DicomLogger.make(subsystem: "com.dicomviewer", category: "DicomDataSetWriter")

private struct EncodingContext {
    let transferSyntax: DicomTransferSyntax
    var characterSet: DicomSpecificCharacterSet = .defaultCharacterSet
    var purpose: DicomDataSetPurpose?
    var pixelContext = DicomPixelValueContext()
    var itemPath: [Int] = []
    let dictionary = DCMDictionary()

    var littleEndian: Bool {
        !transferSyntax.isBigEndian
    }

    var explicitVR: Bool {
        transferSyntax.isExplicitVR
    }
}
