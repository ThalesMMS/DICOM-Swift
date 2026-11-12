//
//  MDLoopFilters.swift
//  DicomJPEGXL
//
//  Applies JPEG XL Modular loop filters to reconstructed image planes.
//
//  Thales Matheus Mendonça Santos — November 2026
//

// MDLoopFilters — the restoration filters of lossy Modular frames (issue #3254).
//
// libjxl runs the frame's loop filters on every frame encoding, not only VarDCT: a Modular frame that signals
// Gaborish or EPF (cjxl's lossy Modular mode does) has its colour channels turned into floats
// (`dec_modular.cc::ModularImageToDecodedRect`: sample × 1/(2^bits − 1), a grey channel replicated to three), then
// Gaborish and the EPF stages run over them with a constant sigma, `kInvSigmaNum / epf_sigma_for_modular`
// (`dec_frame.cc::ProcessDCGroup`), and the output stage (`stage_write.cc::MakeUnsigned`) clamps and rounds them
// back to the sample range, with libjxl 0.12's ordered dither for 8-bit output. Skipping the filters left the raw
// integer planes, which djxl never shows (up to 68 codes on the `grayscale_public_university` conformance vector).

import Foundation

extension MDFrameDecoder {
    /// Whether `frame` is a non-XYB regular Modular frame whose colour channels libjxl filters before output.
    static func needsLoopFilters(_ frame: MDModularFrame) -> Bool {
        let fh = frame.frameHeader
        return fh.frameType == .regular && fh.colorTransform == .none
            && (fh.loopFilter.gab || fh.loopFilter.epfIters > 0)
    }

    /// The constant per-block `inv_sigma` of a Modular frame's EPF (`kInvSigmaNum / epf_sigma_for_modular`).
    static func modularInvSigma(_ loopFilter: LoopFilter, width: Int, height: Int) -> [Float] {
        let blocks = ((width + 7) / 8) * ((height + 7) / 8)
        return [Float](repeating: EPF.kInvSigmaNum / loopFilter.epfSigmaForModular, count: blocks)
    }

    /// Gaborish, then the EPF stages, over three float colour planes, as the render pipeline orders them.
    static func applyLoopFilters(_ planes: inout [[Float]], width: Int, height: Int, loopFilter lf: LoopFilter) throws {
        precondition(planes.count == 3)
        if lf.gab {
            let gw = lf.gabWeights
            for c in 0..<3 {
                Gaborish.apply(to: &planes[c], width: width, height: height,
                               weight1: gw[2 * c], weight2: gw[2 * c + 1])
            }
        }
        if lf.epfIters > 0 {
            var x = planes[0], y = planes[1], b = planes[2]
            planes = []
            try EPF.applyAllStages(
                planeX: &x, planeY: &y, planeB: &b, width: width, height: height,
                invSigmaPerBlock: modularInvSigma(lf, width: width, height: height),
                params: EPFParams(loopFilter: lf))
            planes = [x, y, b]
        }
    }

    /// `frame` with its colour planes filtered and brought back to integer samples in [0, 2^bits − 1] the way djxl
    /// writes them; extra channels are untouched (libjxl does not filter them). Frames without filters are returned
    /// as they are.
    static func applyingLoopFilters(_ frame: MDModularFrame) throws -> MDModularFrame {
        guard needsLoopFilters(frame) else { return frame }
        let width = frame.width, height = frame.height
        let count = width * height
        let bits = Int(frame.metadata.bitDepth.bitsPerSample)
        let maxCode = (1 << bits) - 1
        let factorDouble = 1.0 / Double(maxCode)
        let factor = Float(factorDouble)
        var floats: [[Float]] = []
        floats.reserveCapacity(3)
        for c in 0..<3 {
            let source = frame.planes[frame.colourChannels == 1 ? 0 : c]
            var plane = [Float](repeating: 0, count: count)
            if bits < 23 {
                for i in 0..<count { plane[i] = Float(source[i]) * factor }
            } else {
                for i in 0..<count { plane[i] = Float(Double(source[i]) * factorDouble) }
            }
            floats.append(plane)
        }
        do {
            try applyLoopFilters(&floats, width: width, height: height, loopFilter: frame.frameHeader.loopFilter)
        } catch {
            throw MDFrameError.unsupported("Modular restoration filters: \(error)")
        }
        let maxValue = Float(maxCode)
        var planes = frame.planes
        for c in 0..<frame.colourChannels {
            let source = floats[c]
            var out = [Int32](repeating: 0, count: count)
            if bits <= 8 {
                for y in 0..<height {
                    for x in 0..<width {
                        out[y * width + x] = Int32(clamping: LibjxlOutput.sampleDithered(
                            source[y * width + x], maxValue: maxValue, x: x, y: y, channel: c))
                    }
                }
            } else {
                for i in 0..<count { out[i] = Int32(clamping: LibjxlOutput.sample(source[i], maxValue: maxValue)) }
            }
            planes[c] = out
        }
        return MDModularFrame(
            width: width, height: height, planes: planes, colourChannels: frame.colourChannels,
            metadata: frame.metadata, iccProfile: frame.iccProfile, frameHeader: frame.frameHeader,
            dcQuant: frame.dcQuant, transformData: frame.transformData)
    }
}
