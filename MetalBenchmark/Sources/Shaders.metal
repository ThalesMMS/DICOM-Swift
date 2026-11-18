//
//  Shaders.metal
//  MetalBenchmark
//
//  Metal shader implementation of DICOM windowing/level
//  transformation.  This kernel transforms 16-bit grayscale
//  pixels to 8-bit output using a linear window/level mapping.
//  The algorithm mirrors the CPU implementation in
//  DCMWindowingProcessor.applyWindowLevel.
//

#include <metal_stdlib>
using namespace metal;

/// Applies a linear window/level transformation to 16-bit
/// grayscale pixel data.  Each thread processes one pixel,
/// calculating the output value by:
///
/// 1. Subtracting the minimum level (center - width/2)
/// 2. Scaling by the range inverse (255 / window width)
/// 3. Clamping the result to [0, 255]
///
/// This transformation is the GPU equivalent of the CPU
/// implementation in DCMWindowingProcessor.applyWindowLevel.
///
/// - Parameters:
///   - inputPixels: Buffer of 16-bit unsigned pixel intensities
///   - outputPixels: Buffer for 8-bit output pixels
///   - center: Window center value
///   - width: Window width value
///   - pixelCount: Total number of pixels to process
///   - gid: Global thread ID (unique pixel index)
kernel void applyWindowLevel(
    device const ushort* inputPixels [[buffer(0)]],
    device uchar* outputPixels [[buffer(1)]],
    constant float& center [[buffer(2)]],
    constant float& width [[buffer(3)]],
    constant uint& pixelCount [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    // Bounds check: ensure thread index is within pixel array
    if (gid >= pixelCount) {
        return;
    }

    // Calculate window boundaries
    float minLevel = center - width / 2.0f;
    float maxLevel = center + width / 2.0f;
    float range = maxLevel - minLevel;

    // Calculate scaling factor (with guard against division by zero)
    float rangeInv = (range > 0.0f) ? (255.0f / range) : 1.0f;

    // Read input pixel and convert to float
    float pixelValue = float(inputPixels[gid]);

    // Apply window/level transformation:
    // 1. Subtract minimum level
    pixelValue -= minLevel;

    // 2. Scale to 0-255 range
    pixelValue *= rangeInv;

    // 3. Clamp to valid 8-bit range
    pixelValue = clamp(pixelValue, 0.0f, 255.0f);

    // Write result to output buffer
    outputPixels[gid] = uchar(pixelValue);
}
