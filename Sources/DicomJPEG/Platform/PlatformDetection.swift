// SPDX-License-Identifier: Apache-2.0
// Copyright 2024 Raster Lab. All rights reserved.

/// Reports the compile-time CPU architecture for the build, plus whether Metal is
/// likely to be usable at runtime.
///
/// JLISwift only targets Apple platforms, so Accelerate (vDSP/vImage) is always
/// available and there is no field for it. Metal availability is a runtime check
/// because some Apple devices (watchOS, headless servers, certain VMs) lack a GPU
/// device even though the framework imports.
public struct JLIPlatformCapabilities: Sendable {
    public let architecture: Architecture
    /// Whether ARM NEON SIMD is available (true on all Apple Silicon builds).
    public let hasNEON: Bool
    /// Whether Intel SSE2+ SIMD is available (true on Intel macOS builds).
    public let hasSSE: Bool

    public enum Architecture: String, Sendable {
        case arm64
        case x86_64
        case unknown
    }

    public static let current: JLIPlatformCapabilities = {
        #if arch(arm64)
        return JLIPlatformCapabilities(architecture: .arm64, hasNEON: true, hasSSE: false)
        #elseif arch(x86_64)
        return JLIPlatformCapabilities(architecture: .x86_64, hasNEON: false, hasSSE: true)
        #else
        return JLIPlatformCapabilities(architecture: .unknown, hasNEON: false, hasSSE: false)
        #endif
    }()
}
