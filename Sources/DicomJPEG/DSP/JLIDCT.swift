// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// 8×8 forward and inverse DCT-II for JPEG.
///
/// Thin façade over ``AccelerateDSP`` — every Apple platform ships Accelerate, so
/// there is no scalar fallback. Hot encoding/decoding paths should call the
/// `into:scratch:` variants on `AccelerateDSP` directly to avoid per-block allocation.
enum DCT {
    /// Allocates output. Convenience for tests and one-off callers.
    static func forward(_ block: [Float]) -> [Float] {
        AccelerateDSP.forwardDCT(block)
    }

    /// Allocates output. Convenience for tests and one-off callers.
    static func inverse(_ block: [Float]) -> [Float] {
        AccelerateDSP.inverseDCT(block)
    }
}
