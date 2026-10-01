import Foundation

enum DicomMPEG2StreamParser {
    static func parse(_ stream: Data) throws -> DicomVideoStreamDescription {
        let bytes = [UInt8](stream)
        var result = DicomVideoStreamDescription(codec: .mpeg2)
        result.framing = "MPEG-2 elementary"
        var markers: [(Int, UInt8)] = []
        guard bytes.count >= 4 else { throw DicomVideoInspectionError.malformedStream }
        for index in 0..<(bytes.count - 3) where bytes[index] == 0 && bytes[index + 1] == 0 && bytes[index + 2] == 1 {
            markers.append((index, bytes[index + 3]))
        }
        var gopStart = 0
        var pending = 0
        var closed = true
        var sawGOP = false
        var prefixPending = false
        for (i, marker) in markers.enumerated() {
            let end = i + 1 < markers.count ? markers[i + 1].0 : bytes.count
            guard end >= marker.0 + 4 else { throw DicomVideoInspectionError.malformedStream }
            var bits = DicomVideoBits(Data(bytes[marker.0 + 4..<end]), headerBytes: 0,
                                      removeEmulationPreventionBytes: false)
            if [0xB3, 0xB8].contains(marker.1), !result.accessUnits.isEmpty, !prefixPending {
                let old = result.accessUnits.removeLast()
                result.accessUnits.append(.init(decodeIndex: old.decodeIndex, presentationIndex: old.presentationIndex,
                    byteRange: old.byteRange.lowerBound..<marker.0, sliceType: old.sliceType,
                    isKeyFrame: old.isKeyFrame, temporalReference: old.temporalReference))
                pending = marker.0
                prefixPending = true
            }
            switch marker.1 {
            case 0xB3:
                result.width = try bits.read(12)
                result.height = try bits.read(12)
                _ = try bits.read(4)
                result.frameRateCode = try bits.read(4)
                result.bitRate = try bits.read(18) * 400
                let rates = [1: (24000, 1001), 2: (24, 1), 3: (25, 1), 4: (30000, 1001), 5: (30, 1), 6: (50, 1), 7: (60000, 1001), 8: (60, 1)]
                if let rate = rates[result.frameRateCode!] {
                    result.timeScale = rate.0; result.numUnitsInTick = rate.1; result.fixedFrameRateFlag = true
                }
            case 0xB5:
                if try bits.read(4) == 1 {
                    let profileLevel = try bits.read(8)
                    result.profileIDC = (profileLevel >> 4) & 7
                    result.levelIDC = profileLevel & 15
                    result.profile = [1: "High", 2: "Spatially Scalable", 3: "SNR Scalable", 4: "Main", 5: "Simple"][result.profileIDC!]
                    result.frameMbsOnly = try bits.read(1) == 1
                    result.chromaFormat = try bits.read(2)
                    result.bitDepth = 8
                    result.chromaBitDepth = 8
                    let widthExtension = try bits.read(2), heightExtension = try bits.read(2)
                    if let width = result.width { result.width = width | (widthExtension << 12) }
                    if let height = result.height { result.height = height | (heightExtension << 12) }
                }
            case 0xB8:
                sawGOP = true
                _ = try bits.read(25)
                closed = (try bits.read(1) == 1) && closed
                _ = try bits.read(1) // broken_link
                gopStart = result.accessUnits.count
            case 0x00:
                let reference = try bits.read(10)
                let type = try bits.read(3)
                guard (1...3).contains(type) else { throw DicomVideoInspectionError.malformedStream }
                if !result.accessUnits.isEmpty, !prefixPending {
                    let old = result.accessUnits.removeLast()
                    result.accessUnits.append(.init(decodeIndex: old.decodeIndex, presentationIndex: old.presentationIndex,
                        byteRange: old.byteRange.lowerBound..<marker.0, sliceType: old.sliceType,
                        isKeyFrame: old.isKeyFrame, temporalReference: old.temporalReference))
                    pending = marker.0
                }
                prefixPending = false
                result.accessUnits.append(.init(decodeIndex: result.accessUnits.count,
                    presentationIndex: gopStart + reference, byteRange: pending..<bytes.count,
                    sliceType: ["I", "P", "B"][type - 1], isKeyFrame: type == 1, temporalReference: reference))
            default: break
            }
        }
        guard result.width != nil, !result.accessUnits.isEmpty else { throw DicomVideoInspectionError.malformedStream }
        result.closedGOP = sawGOP ? closed : nil
        result.limitations = ["MPEG2-sequence-extensions-and-field-pictures-not-qualified"]
        return result
    }
}
