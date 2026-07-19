import Foundation
import zlib

public enum DicomDeflatedDataSetError: Error, Equatable, Sendable {
    case malformedFileMetaInformation
    case dataSetTooLarge(byteCount: Int, limit: Int)
    case deflateFailed(code: Int32)
    case inflateFailed(code: Int32)
}

extension DicomDeflatedDataSetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedFileMetaInformation:
            return "DICOM file meta information could not be parsed before deflated dataset inflation."
        case .dataSetTooLarge(let byteCount, let limit):
            return "Inflated DICOM dataset size \(byteCount) exceeds the configured limit \(limit)."
        case .deflateFailed(let code):
            return "DICOM dataset deflate failed with zlib status \(code)."
        case .inflateFailed(let code):
            return "DICOM dataset inflate failed with zlib status \(code)."
        }
    }
}

public enum DicomDeflatedDataSetCodec {
    public static let defaultInflatedSizeLimit = 2 * 1024 * 1024 * 1024

    public static func deflate(_ data: Data) throws -> Data {
        try process(data, operation: .deflate)
    }

    public static func inflate(_ data: Data,
                               inflatedSizeLimit: Int = defaultInflatedSizeLimit) throws -> Data {
        try process(data, operation: .inflate(limit: inflatedSizeLimit))
    }

    static func inflatedPart10DataIfNeeded(_ data: Data,
                                           inflatedSizeLimit: Int = defaultInflatedSizeLimit) throws -> Data {
        guard let layout = try part10Layout(in: data),
              layout.transferSyntax.usesDataSetDeflate else {
            return data
        }

        let deflatedDataSet = data.subdata(in: layout.dataSetOffset..<data.count)
        let inflatedDataSet = try inflate(deflatedDataSet, inflatedSizeLimit: inflatedSizeLimit)
        var inflated = data.subdata(in: 0..<layout.dataSetOffset)
        inflated.append(inflatedDataSet)
        return inflated
    }

    private static func part10Layout(in data: Data) throws -> Part10Layout? {
        guard data.count >= 132 else { return nil }
        guard String(bytes: data[128..<132], encoding: .ascii) == "DICM" else { return nil }

        var offset = 132
        var transferSyntax: DicomTransferSyntax?

        while offset + 8 <= data.count {
            let tagOffset = offset
            guard let group = data.dicomIntegerIfPresent(
                at: offset,
                as: UInt16.self,
                littleEndian: true
            ) else {
                throw DicomDeflatedDataSetError.malformedFileMetaInformation
            }
            offset += 2
            guard let element = data.dicomIntegerIfPresent(
                at: offset,
                as: UInt16.self,
                littleEndian: true
            ) else {
                throw DicomDeflatedDataSetError.malformedFileMetaInformation
            }
            offset += 2

            guard group == 0x0002 else {
                return transferSyntax.map { Part10Layout(transferSyntax: $0, dataSetOffset: tagOffset) }
            }

            guard offset + 2 <= data.count,
                  let vr = DicomVR(code: String(bytes: data[offset..<(offset + 2)], encoding: .ascii) ?? "") else {
                throw DicomDeflatedDataSetError.malformedFileMetaInformation
            }
            offset += 2

            let length: Int
            if vr.uses32BitLength {
                guard offset + 6 <= data.count else {
                    throw DicomDeflatedDataSetError.malformedFileMetaInformation
                }
                offset += 2
                guard let encodedLength = data.dicomIntegerIfPresent(
                    at: offset,
                    as: UInt32.self,
                    littleEndian: true
                ) else {
                    throw DicomDeflatedDataSetError.malformedFileMetaInformation
                }
                length = Int(encodedLength)
                offset += 4
            } else {
                guard offset + 2 <= data.count else {
                    throw DicomDeflatedDataSetError.malformedFileMetaInformation
                }
                guard let encodedLength = data.dicomIntegerIfPresent(
                    at: offset,
                    as: UInt16.self,
                    littleEndian: true
                ) else {
                    throw DicomDeflatedDataSetError.malformedFileMetaInformation
                }
                length = Int(encodedLength)
                offset += 2
            }

            guard offset + length <= data.count else {
                throw DicomDeflatedDataSetError.malformedFileMetaInformation
            }

            if group == 0x0002 && element == 0x0010 {
                let value = String(bytes: data[offset..<(offset + length)], encoding: .ascii) ?? ""
                transferSyntax = DicomTransferSyntax(uid: value)
            }
            offset += length
        }

        return transferSyntax.map { Part10Layout(transferSyntax: $0, dataSetOffset: offset) }
    }

    private static func process(_ input: Data, operation: Operation) throws -> Data {
        var stream = z_stream()
        let initStatus: Int32

        switch operation {
        case .deflate:
            initStatus = deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                -MAX_WBITS,
                8,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        case .inflate:
            initStatus = inflateInit2_(
                &stream,
                -MAX_WBITS,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
        }

        guard initStatus == Z_OK else {
            switch operation {
            case .deflate:
                throw DicomDeflatedDataSetError.deflateFailed(code: initStatus)
            case .inflate:
                throw DicomDeflatedDataSetError.inflateFailed(code: initStatus)
            }
        }

        defer {
            switch operation {
            case .deflate:
                deflateEnd(&stream)
            case .inflate:
                inflateEnd(&stream)
            }
        }

        var output = Data()
        let chunkSize = 64 * 1024
        let inputCount = input.count

        try input.withUnsafeBytes { inputBuffer in
            let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress
            stream.next_in = UnsafeMutablePointer(mutating: inputBase)
            stream.avail_in = uInt(inputCount)

            while true {
                var chunk = [UInt8](repeating: 0, count: chunkSize)
                let status: Int32 = chunk.withUnsafeMutableBytes { outputBuffer in
                    stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(chunkSize)

                    switch operation {
                    case .deflate:
                        return zlib.deflate(&stream, Z_FINISH)
                    case .inflate:
                        return zlib.inflate(&stream, Z_NO_FLUSH)
                    }
                }

                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    switch operation {
                    case .deflate:
                        output.append(contentsOf: chunk.prefix(produced))
                    case .inflate(let limit):
                        let nextCount = output.count + produced
                        guard nextCount <= limit else {
                            throw DicomDeflatedDataSetError.dataSetTooLarge(byteCount: nextCount, limit: limit)
                        }
                        output.append(contentsOf: chunk.prefix(produced))
                    }
                }

                if status == Z_STREAM_END {
                    break
                }
                guard status == Z_OK else {
                    switch operation {
                    case .deflate:
                        throw DicomDeflatedDataSetError.deflateFailed(code: status)
                    case .inflate:
                        throw DicomDeflatedDataSetError.inflateFailed(code: status)
                    }
                }
            }
        }

        return output
    }
}

private struct Part10Layout {
    let transferSyntax: DicomTransferSyntax
    let dataSetOffset: Int
}

private enum Operation {
    case deflate
    case inflate(limit: Int)
}
