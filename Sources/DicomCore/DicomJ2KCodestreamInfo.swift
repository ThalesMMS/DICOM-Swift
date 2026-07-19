import Foundation

struct DicomJ2KCodestreamInfo: Sendable, Equatable {
    let decompositionLevels: Int
    let qualityLayerCount: Int

    static func parse(_ data: Data) throws -> DicomJ2KCodestreamInfo {
        guard data.count >= 6, data[0] == 0xFF, data[1] == 0x4F else {
            throw DicomPartialFrameDecodeError.decodeFailed("the frame has no JPEG 2000 SOC marker")
        }

        var offset = 2
        while offset + 4 <= data.count {
            guard data[offset] == 0xFF else {
                throw DicomPartialFrameDecodeError.decodeFailed("the JPEG 2000 main header is malformed")
            }
            let marker = data[offset + 1]
            if marker == 0x52 {
                let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
                guard length >= 10, offset + 2 + length <= data.count else {
                    throw DicomPartialFrameDecodeError.decodeFailed("the JPEG 2000 COD marker is truncated")
                }
                let layers = Int(data[offset + 6]) << 8 | Int(data[offset + 7])
                return DicomJ2KCodestreamInfo(
                    decompositionLevels: Int(data[offset + 9]),
                    qualityLayerCount: max(1, layers)
                )
            }
            if marker == 0x90 {
                break
            }
            let length = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            guard length >= 2, offset + 2 + length <= data.count else {
                throw DicomPartialFrameDecodeError.decodeFailed("the JPEG 2000 main header is truncated")
            }
            offset += 2 + length
        }
        throw DicomPartialFrameDecodeError.decodeFailed("the JPEG 2000 main header has no COD marker")
    }
}
