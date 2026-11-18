//
//  JPEGLosslessDecoder+Prediction.swift
//  DicomCore
//
//  Adds prediction support to JPEGLosslessDecoder.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

extension JPEGLosslessDecoder {
    // MARK: - Prediction

    /// Computes the predictor value for a pixel based on the selection value
    /// - Parameters:
    ///   - x: Horizontal pixel position (0-indexed)
    ///   - y: Vertical pixel position (0-indexed)
    ///   - pixels: Decoded pixel buffer (values decoded so far)
    ///   - width: Image width in pixels
    ///   - precision: Sample precision in bits (8, 12, or 16)
    ///   - selectionValue: Predictor selection value (0-7)
    /// Compute the JPEG Lossless predictor value for the pixel at (x, y) using already-decoded neighbor samples.
    ///
    /// The `pixels` buffer is interpreted row-major (index = y * width + x). The `selectionValue` selects one of the ITU‑T T.81/DICOM lossless predictors:
    /// 0 = no prediction (0), 1 = left, 2 = top, 3 = top-left, 4 = planar (Ra + Rb - Rc), 5 = Ra + ((Rb - Rc) >> 1),
    /// 6 = Rb + ((Ra - Rc) >> 1), 7 = (Ra + Rb) / 2. For boundary cases where required neighbors are unavailable,
    /// the first sample of a scan returns the bias value 1 << (precision - pointTransform - 1).
    /// - Parameters:
    ///   - x: Column index of the target pixel.
    ///   - y: Row index of the target pixel.
    ///   - pixels: Decoded pixel samples (UInt16) in row-major order.
    ///   - width: Image width (samples per row).
    ///   - precision: Sample precision in bits.
    ///   - selectionValue: Predictor selector (expected 0–7).
    ///   - pointTransform: JPEG lossless point transform (Pt), used for the initial predictor.
    ///   - isFirstSampleInScan: True for the first sample after SOS or a restart interval.
    /// - Returns: The predictor sample value to be used for the pixel at (x, y).
    internal func computePredictor(
        x: Int,
        y: Int,
        pixels: [UInt16],
        width: Int,
        precision: Int,
        selectionValue: Int,
        pointTransform: Int = 0,
        isFirstSampleInScan: Bool? = nil
    ) -> Int {
        // Selection Value determines which predictor formula to use
        // Reference: ITU-T T.81 Annex H, DICOM PS3.5 Section 8.2.4
        let firstSample = isFirstSampleInScan ?? (x == 0 && y == 0)
        let initialPredictor = 1 << max(0, precision - pointTransform - 1)

        if firstSample, selectionValue != 0 {
            return initialPredictor
        }

        if x == 0, y > 0, selectionValue != 0 {
            return Int(pixels[(y - 1) * width])
        }

        switch selectionValue {
        case 0:
            // Selection Value 0: No prediction
            // Predictor is always 0 (raw pixel values encoded as differences)
            return 0

        case 1:
            // Selection Value 1: First-order prediction using left neighbor (Ra)
            //
            // Predictor formula:
            // - First sample: Predictor = 2^(P-Pt-1)
            // - Row starts after the first sample: Predictor = Rb (above)
            // - Other columns: Predictor = Ra (left neighbor)

            if x == 0 {
                // First sample fallback; later row starts were handled before the switch.
                // For 16-bit: 2^15 = 32768
                // For 12-bit: 2^11 = 2048
                // For 8-bit: 2^7 = 128
                return initialPredictor
            } else {
                // Use left neighbor (Ra) as predictor
                let index = y * width + (x - 1)
                return Int(pixels[index])
            }

        case 2:
            // Selection Value 2: Prediction using top neighbor (Rb)
            //
            // Predictor formula:
            // - First row (y=0): Predictor = 2^(P-1) where P is precision
            // - Other rows: Predictor = Rb (top neighbor)

            if y == 0 {
                // First-row fallback for predictors that reference an unavailable top neighbor.
                // For 16-bit: 2^15 = 32768
                // For 12-bit: 2^11 = 2048
                // For 8-bit: 2^7 = 128
                return initialPredictor
            } else {
                // Use top neighbor (Rb) as predictor
                let index = (y - 1) * width + x
                return Int(pixels[index])
            }

        case 3:
            // Selection Value 3: Prediction using top-left neighbor (Rc)
            //
            // Predictor formula:
            // - First row (y=0): Predictor = 2^(P-Pt-1)
            // - Row starts after the first sample: Predictor = Rb (above)
            // - Other positions: Predictor = Rc (top-left diagonal neighbor)

            if x == 0 || y == 0 {
                // First-row fallback; later row starts were handled before the switch.
                // For 16-bit: 2^15 = 32768
                // For 12-bit: 2^11 = 2048
                // For 8-bit: 2^7 = 128
                return initialPredictor
            } else {
                // Use top-left neighbor (Rc) as predictor
                let index = (y - 1) * width + (x - 1)
                return Int(pixels[index])
            }

        case 4:
            // Selection Value 4: Planar prediction using Ra + Rb - Rc
            //
            // Predictor formula:
            // - First row (y=0): Predictor = 2^(P-Pt-1)
            // - Row starts after the first sample: Predictor = Rb (above)
            // - Other positions: Predictor = Ra + Rb - Rc
            //   where Ra = left neighbor, Rb = top neighbor, Rc = top-left neighbor

            if x == 0 || y == 0 {
                // First-row fallback; later row starts were handled before the switch.
                // For 16-bit: 2^15 = 32768
                // For 12-bit: 2^11 = 2048
                // For 8-bit: 2^7 = 128
                return initialPredictor
            } else {
                // Use planar predictor: Ra + Rb - Rc
                let indexRa = y * width + (x - 1)        // Left neighbor
                let indexRb = (y - 1) * width + x        // Top neighbor
                let indexRc = (y - 1) * width + (x - 1)  // Top-left neighbor

                let ra = Int(pixels[indexRa])
                let rb = Int(pixels[indexRb])
                let rc = Int(pixels[indexRc])

                return ra + rb - rc
            }

        case 5:
            // Selection Value 5: Left neighbor plus half vertical gradient
            //
            // Predictor formula:
            // - First row (y=0): Predictor = 2^(P-Pt-1)
            // - Row starts after the first sample: Predictor = Rb (above)
            // - Other positions: Predictor = Ra + ((Rb - Rc) >> 1)
            //   where Ra = left neighbor, Rb = top neighbor, Rc = top-left neighbor

            if x == 0 || y == 0 {
                // First-row fallback; later row starts were handled before the switch.
                // For 16-bit: 2^15 = 32768
                // For 12-bit: 2^11 = 2048
                // For 8-bit: 2^7 = 128
                return initialPredictor
            } else {
                // Use left + half vertical gradient predictor: Ra + ((Rb - Rc) >> 1)
                let indexRa = y * width + (x - 1)        // Left neighbor
                let indexRb = (y - 1) * width + x        // Top neighbor
                let indexRc = (y - 1) * width + (x - 1)  // Top-left neighbor

                let ra = Int(pixels[indexRa])
                let rb = Int(pixels[indexRb])
                let rc = Int(pixels[indexRc])

                return ra + ((rb - rc) >> 1)
            }

        case 6:
            // Selection Value 6: Top neighbor plus half horizontal gradient
            //
            // Predictor formula:
            // - First row (y=0): Predictor = 2^(P-Pt-1)
            // - Row starts after the first sample: Predictor = Rb (above)
            // - Other positions: Predictor = Rb + ((Ra - Rc) >> 1)
            //   where Ra = left neighbor, Rb = top neighbor, Rc = top-left neighbor

            if x == 0 || y == 0 {
                // First-row fallback; later row starts were handled before the switch.
                // For 16-bit: 2^15 = 32768
                // For 12-bit: 2^11 = 2048
                // For 8-bit: 2^7 = 128
                return initialPredictor
            } else {
                // Use top + half horizontal gradient predictor: Rb + ((Ra - Rc) >> 1)
                let indexRa = y * width + (x - 1)        // Left neighbor
                let indexRb = (y - 1) * width + x        // Top neighbor
                let indexRc = (y - 1) * width + (x - 1)  // Top-left neighbor

                let ra = Int(pixels[indexRa])
                let rb = Int(pixels[indexRb])
                let rc = Int(pixels[indexRc])

                return rb + ((ra - rc) >> 1)
            }

        case 7:
            // Selection Value 7: Average of left and top neighbors
            //
            // Predictor formula:
            // - First row (y=0): Predictor = 2^(P-Pt-1)
            // - Row starts after the first sample: Predictor = Rb (above)
            // - Other positions: Predictor = (Ra + Rb) / 2
            //   where Ra = left neighbor, Rb = top neighbor

            if x == 0 || y == 0 {
                // First-row fallback; later row starts were handled before the switch.
                // For 16-bit: 2^15 = 32768
                // For 12-bit: 2^11 = 2048
                // For 8-bit: 2^7 = 128
                return initialPredictor
            } else {
                // Use average of left and top neighbors: (Ra + Rb) / 2
                let indexRa = y * width + (x - 1)        // Left neighbor
                let indexRb = (y - 1) * width + x        // Top neighbor

                let ra = Int(pixels[indexRa])
                let rb = Int(pixels[indexRb])

                return (ra + rb) / 2
            }

        default:
            // Unsupported selection values (should not occur with valid JPEG Lossless)
            // Fall back to Selection Value 1 behavior
            if x == 0 {
                return initialPredictor
            } else {
                let index = y * width + (x - 1)
                return Int(pixels[index])
            }
        }
    }

}
