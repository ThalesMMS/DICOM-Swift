//
//  DCMWindowingProcessor+Batch.swift
//  DicomCore
//
//  Adds batch support to DCMWindowingProcessor.
//
//  Thales Matheus Mendonça Santos — June 2026
//

extension DCMWindowingProcessor {
    /// Computes optimal window/level settings for each image in a batch.
    /// - Parameter imagePixels: An array where each element is a 16‑bit pixel buffer for one image.
    /// - Returns: An array of `WindowSettings`, one entry for each input pixel buffer.
    public static func batchCalculateOptimalWindowLevelV2(imagePixels: [[UInt16]]) -> [WindowSettings] {
        return imagePixels.map { pixels in
            calculateOptimalWindowLevelV2(pixels16: pixels)
        }
    }
}
