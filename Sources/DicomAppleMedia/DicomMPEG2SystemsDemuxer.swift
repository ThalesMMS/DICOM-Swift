import Foundation

/// Extracts the MPEG-2 video elementary stream from an MPEG-2 Program Stream or a sequence of PES packets
/// (ISO/IEC 13818-1 2.4 and 2.5).
///
/// PS3.5 8.2.5 (MPEG2 MP@ML, MP@HL and their fragmentable forms) leaves the container unconstrained: the bit stream
/// may be MPEG-2 Transport Stream, Program Stream, Elementary Stream, PES or MP4. A Program Stream starts with a pack
/// header (`00 00 01 BA`); bare PES packets start with a stream ID start code. Packet headers inside an access unit
/// corrupt playback, so the first video stream (`E0`–`EF`) is reassembled before the elementary-stream parser runs.
/// Audio, padding and private streams are dropped.
enum DicomMPEG2SystemsDemuxer {
    /// The video elementary stream of a Program Stream or PES payload; nil when `stream` is neither (an elementary
    /// stream, a Transport Stream or an ISO base media file), which is passed on unchanged.
    static func videoElementaryStream(from stream: Data) throws -> Data? {
        let bytes = [UInt8](stream)
        guard bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1,
              bytes[3] == 0xBA || isPESStreamID(bytes[3]) else { return nil }
        var output = Data()
        var videoStreamID: UInt8?
        var offset = 0
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0, bytes[offset + 1] == 0, bytes[offset + 2] == 1 else {
                throw DicomVideoRemuxError.malformedSystemsStream
            }
            let code = bytes[offset + 3]
            switch code {
            case 0xB9:
                // MPEG_program_end_code.
                return try finished(output)
            case 0xBA:
                offset += try packHeaderLength(bytes, at: offset)
            case 0xBB, 0xBC...0xFF:
                let (length, payload) = try pesPacket(bytes, at: offset)
                if (0xE0...0xEF).contains(code), videoStreamID == nil || videoStreamID == code {
                    videoStreamID = code
                    if let payload { output.append(contentsOf: bytes[payload]) }
                }
                offset += length
            default:
                throw DicomVideoRemuxError.malformedSystemsStream
            }
        }
        guard offset == bytes.count else { throw DicomVideoRemuxError.malformedSystemsStream }
        return try finished(output)
    }

    private static func finished(_ output: Data) throws -> Data {
        guard !output.isEmpty else { throw DicomVideoRemuxError.noVideoFrames(codec: .mpeg2) }
        return output
    }

    /// Program stream map, private streams, padding, audio, video and the other stream IDs of Table 2-22.
    private static func isPESStreamID(_ code: UInt8) -> Bool { code >= 0xBC }

    /// MPEG-2 pack header (`01` marker: 14 bytes plus stuffing) or MPEG-1 pack header (`0010` marker: 12 bytes).
    private static func packHeaderLength(_ bytes: [UInt8], at offset: Int) throws -> Int {
        guard offset + 5 <= bytes.count else { throw DicomVideoRemuxError.malformedSystemsStream }
        if bytes[offset + 4] & 0xC0 == 0x40 {
            guard offset + 14 <= bytes.count else { throw DicomVideoRemuxError.malformedSystemsStream }
            let length = 14 + Int(bytes[offset + 13] & 0x07)
            guard offset + length <= bytes.count else { throw DicomVideoRemuxError.malformedSystemsStream }
            return length
        }
        guard bytes[offset + 4] & 0xF0 == 0x20, offset + 12 <= bytes.count else { throw DicomVideoRemuxError.malformedSystemsStream }
        return 12
    }

    /// The length of a system header or PES packet and the range of its payload (nil for a system header).
    /// PES_packet_length 0, allowed only for video, runs to the next system start code.
    private static func pesPacket(_ bytes: [UInt8], at offset: Int) throws -> (length: Int, payload: Range<Int>?) {
        guard offset + 6 <= bytes.count else { throw DicomVideoRemuxError.malformedSystemsStream }
        let code = bytes[offset + 3]
        let declared = Int(bytes[offset + 4]) << 8 | Int(bytes[offset + 5])
        var end = offset + 6 + declared
        if declared == 0 {
            guard (0xE0...0xEF).contains(code) else { throw DicomVideoRemuxError.malformedSystemsStream }
            end = nextSystemStartCode(bytes, after: offset + 6) ?? bytes.count
        }
        guard end <= bytes.count else { throw DicomVideoRemuxError.malformedSystemsStream }
        // System header, program stream map, padding, private stream 2, ECM, EMM, directory and DSM-CC carry no
        // PES header extension (Table 2-21).
        guard code != 0xBB, ![0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xF2, 0xF8, 0xFF].contains(code) else { return (end - offset, nil) }
        let start = try payloadStart(bytes, headerAt: offset + 6, end: end)
        return (end - offset, start..<end)
    }

    /// Skips the MPEG-2 PES header (`10` marker) or the MPEG-1 one (stuffing, STD buffer size, PTS/DTS).
    private static func payloadStart(_ bytes: [UInt8], headerAt start: Int, end: Int) throws -> Int {
        guard start < end else { throw DicomVideoRemuxError.malformedSystemsStream }
        if bytes[start] & 0xC0 == 0x80 {
            guard start + 3 <= end else { throw DicomVideoRemuxError.malformedSystemsStream }
            let payload = start + 3 + Int(bytes[start + 2])
            guard payload <= end else { throw DicomVideoRemuxError.malformedSystemsStream }
            return payload
        }
        var index = start
        while index < end, bytes[index] == 0xFF { index += 1 }
        if index < end, bytes[index] & 0xC0 == 0x40 { index += 2 }
        guard index < end else { throw DicomVideoRemuxError.malformedSystemsStream }
        switch bytes[index] & 0xF0 {
        case 0x20: index += 5
        case 0x30: index += 10
        default:
            guard bytes[index] == 0x0F else { throw DicomVideoRemuxError.malformedSystemsStream }
            index += 1
        }
        guard index <= end else { throw DicomVideoRemuxError.malformedSystemsStream }
        return index
    }

    /// Video start codes stop at `B8`; `B9`–`FF` are system start codes, so the next one ends an unbounded packet.
    private static func nextSystemStartCode(_ bytes: [UInt8], after offset: Int) -> Int? {
        var index = offset
        while index + 4 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1, bytes[index + 3] >= 0xB9 { return index }
            index += 1
        }
        return nil
    }
}
