import Foundation

public struct DicomPart10WriterOptions: Equatable, Sendable {
    public var transferSyntax: DicomTransferSyntax
    public var mediaStorageSOPClassUID: String?
    public var mediaStorageSOPInstanceUID: String?
    public var implementationClassUID: String
    public var implementationVersionName: String

    public init(transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian,
                mediaStorageSOPClassUID: String? = nil,
                mediaStorageSOPInstanceUID: String? = nil,
                implementationClassUID: String = DicomDataSetWriter.defaultImplementationClassUID,
                implementationVersionName: String = "DICOMCORE_1") {
        self.transferSyntax = transferSyntax
        self.mediaStorageSOPClassUID = mediaStorageSOPClassUID
        self.mediaStorageSOPInstanceUID = mediaStorageSOPInstanceUID
        self.implementationClassUID = implementationClassUID
        self.implementationVersionName = implementationVersionName
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

        var data = Data(count: 128)
        data.append(contentsOf: "DICM".utf8)

        data.append(try fileMetaData(for: dataSet, options: options))
        let encodedDataSet = try encodeDataSet(
            dataSet,
            context: .init(transferSyntax: options.transferSyntax,
                           characterSet: DicomSpecificCharacterSet(dataSet.string(for: .specificCharacterSet))),
            skipFileMeta: true
        )
        if options.transferSyntax.usesDataSetDeflate {
            data.append(try DicomDeflatedDataSetCodec.deflate(encodedDataSet))
        } else {
            data.append(encodedDataSet)
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
        try validateWriteSupport(for: dataSet, transferSyntax: transferSyntax)

        let encodedDataSet = try encodeDataSet(
            dataSet,
            context: .init(transferSyntax: transferSyntax,
                           characterSet: DicomSpecificCharacterSet(dataSet.string(for: .specificCharacterSet))),
            skipFileMeta: true
        )
        if transferSyntax.usesDataSetDeflate {
            return try DicomDeflatedDataSetCodec.deflate(encodedDataSet)
        }
        return encodedDataSet
    }

    public static func write(_ dataSet: DicomDataSet,
                             to url: URL,
                             options: DicomPart10WriterOptions = DicomPart10WriterOptions()) throws {
        let data = try part10Data(from: dataSet, options: options)
        try data.write(to: url, options: [.atomic])
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

        let context = EncodingContext(transferSyntax: .explicitVRLittleEndian)
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
        for element in dataSet.elements where !(skipFileMeta && element.group == 0x0002) {
            try appendElement(element, to: &data, context: context)
        }
        return data
    }

    private static func appendElement(_ element: DicomDataElement,
                                      to data: inout Data,
                                      context: EncodingContext) throws {
        let vr = writableVR(element.vr)
        if shouldWriteEncapsulatedPixelData(element, context: context) {
            appendEncapsulatedPixelDataElement(element, vr: vr, to: &data, context: context)
            return
        }

        let value = try valueData(for: element, vr: vr, context: context)
        let length = value.count

        appendTag(element.tag, to: &data, littleEndian: context.littleEndian)
        if context.explicitVR {
            data.append(contentsOf: vr.code.utf8)
            if vr.uses32BitLength {
                data.append(contentsOf: [0x00, 0x00])
                try appendUInt32Length(length, tag: element.tag, to: &data, littleEndian: context.littleEndian)
            } else {
                guard length <= Int(UInt16.max) else {
                    throw DicomDataSetWriterError.elementLengthTooLarge(tag: element.tag, length: length)
                }
                appendUInt16(UInt16(length), to: &data, littleEndian: context.littleEndian)
            }
        } else {
            try appendUInt32Length(length, tag: element.tag, to: &data, littleEndian: context.littleEndian)
        }
        data.append(value)
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
        case .OB, .OW, .OV, .UN:
            return paddedBytes(binaryData(for: element), padding: 0x00)
        case .OF:
            if element.bytesValue != nil {
                return paddedBytes(binaryData(for: element), padding: 0x00)
            }
            return floats(for: element).reduce(into: Data()) {
                appendUInt32(Float($1).bitPattern, to: &$0, littleEndian: context.littleEndian)
            }
        case .OD:
            if element.bytesValue != nil {
                return paddedBytes(binaryData(for: element), padding: 0x00)
            }
            return floats(for: element).reduce(into: Data()) {
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
            return try signedIntegers(for: element).reduce(into: Data()) {
                guard let value = Int16(exactly: $1) else {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr, reason: "SS value is outside Int16 range")
                }
                appendUInt16(UInt16(bitPattern: value), to: &$0, littleEndian: context.littleEndian)
            }
        case .UL:
            return try unsignedIntegers(for: element).reduce(into: Data()) {
                guard let value = UInt32(exactly: $1) else {
                    throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: vr, reason: "UL value is outside UInt32 range")
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
        case .FL:
            return floats(for: element).reduce(into: Data()) {
                appendUInt32(Float($1).bitPattern, to: &$0, littleEndian: context.littleEndian)
            }
        case .FD:
            return floats(for: element).reduce(into: Data()) {
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
            return paddedStringData(for: element, vr: vr, context: context)
        }
    }

    private static func sequenceData(for element: DicomDataElement,
                                     context: EncodingContext) throws -> Data {
        guard case .sequence(let items) = element.value else {
            throw DicomDataSetWriterError.unsupportedValue(tag: element.tag, vr: .SQ, reason: "expected sequence items")
        }

        var data = Data()
        for item in items {
            let itemData = try encodeDataSet(item.dataSet, context: context, skipFileMeta: true)
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
                                         context: EncodingContext) -> Data {
        let padding: UInt8 = vr == .UI ? 0x00 : 0x20
        let data = context.characterSet.encode(stringValues(for: element).joined(separator: "\\"))
        return paddedBytes(data, padding: padding)
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

    private static func signedIntegers(for element: DicomDataElement) -> [Int] {
        switch element.value {
        case .signedIntegers(let values):
            return values
        case .unsignedIntegers(let values):
            return values.compactMap { Int(exactly: $0) }
        default:
            return stringValues(for: element).compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    private static func unsignedIntegers(for element: DicomDataElement) -> [UInt] {
        switch element.value {
        case .unsignedIntegers(let values):
            return values
        case .signedIntegers(let values):
            return values.compactMap { UInt(exactly: $0) }
        default:
            return stringValues(for: element).compactMap { UInt($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    private static func floats(for element: DicomDataElement) -> [Double] {
        switch element.value {
        case .floats(let values):
            return values
        default:
            return stringValues(for: element).compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
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

private struct EncodingContext {
    let transferSyntax: DicomTransferSyntax
    var characterSet: DicomSpecificCharacterSet = .defaultCharacterSet

    var littleEndian: Bool {
        !transferSyntax.isBigEndian
    }

    var explicitVR: Bool {
        transferSyntax.isExplicitVR
    }
}
