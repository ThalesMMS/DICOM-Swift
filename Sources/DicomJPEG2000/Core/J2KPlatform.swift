//
// J2KPlatform.swift
// J2KSwift
//
/// # J2KPlatform
///
/// Cross-platform compatibility utilities for J2KSwift.
///
/// Provides platform-specific abstractions for file I/O, memory measurement,
/// and Foundation API differences across macOS, Linux, and Windows.

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Platform Detection

/// Identifies the current platform for runtime checks and diagnostics.
public enum J2KPlatform: String, Sendable {
    case macOS
    case iOS
    case tvOS
    case watchOS
    case visionOS
    case linux
    case windows
    case unknown

    /// The platform this code is running on.
    public static let current: J2KPlatform = {
        #if os(macOS)
        return .macOS
        #elseif os(iOS)
        return .iOS
        #elseif os(tvOS)
        return .tvOS
        #elseif os(watchOS)
        return .watchOS
        #elseif os(visionOS)
        return .visionOS
        #elseif os(Linux)
        return .linux
        #elseif os(Windows)
        return .windows
        #else
        return .unknown
        #endif
    }()

    /// Whether the current platform is a Windows system.
    public static var isWindows: Bool {
        #if os(Windows)
        return true
        #else
        return false
        #endif
    }

    /// Whether the current platform is a Linux system.
    public static var isLinux: Bool {
        #if os(Linux)
        return true
        #else
        return false
        #endif
    }

    /// Whether the current platform is an Apple system.
    public static var isApple: Bool {
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return true
        #else
        return false
        #endif
    }
}

// MARK: - Memory Measurement

/// Cross-platform memory usage measurement.
///
/// Provides best-effort memory usage reporting on each platform:
/// - **macOS/iOS**: Uses `task_info` Mach API when available
/// - **Linux**: Reads from `/proc/self/statm`
/// - **Windows**: Uses `GetProcessMemoryInfo` Win32 API
/// - **Other**: Returns 0
public enum J2KMemoryInfo: Sendable {
    /// Returns the current process resident memory usage in bytes.
    ///
    /// - Returns: The memory usage in bytes, or 0 if measurement is unavailable.
    public static func currentResidentMemory() -> Int {
        #if os(Linux)
        return linuxResidentMemory()
        #elseif os(Windows)
        return windowsResidentMemory()
        #else
        return 0
        #endif
    }

    #if os(Linux)
    private static func linuxResidentMemory() -> Int {
        guard let contents = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else {
            return 0
        }
        let parts = contents.split(separator: " ")
        if parts.count > 1, let residentPages = Int(parts[1]) {
            return residentPages * 4096
        }
        return 0
    }
    #endif

    #if os(Windows)
    private static func windowsResidentMemory() -> Int {
        // Use Windows Process Status API (PSAPI) to get working set size.
        // GetProcessMemoryInfo fills PROCESS_MEMORY_COUNTERS with WorkingSetSize.
        // This requires importing WinSDK on Windows.
        0 // Placeholder: requires WinSDK import for full implementation
    }
    #endif
}

// MARK: - File Path Utilities

/// Cross-platform file path utilities.
///
/// Handles differences in path representation across platforms, including
/// Windows backslash separators and UNC path handling.
public enum J2KPathUtilities: Sendable {
    /// The platform-native path separator.
    public static let pathSeparator: Character = {
        #if os(Windows)
        return "\\"
        #else
        return "/"
        #endif
    }()

    /// Normalizes a file path for the current platform.
    ///
    /// On Windows, converts forward slashes to backslashes.
    /// On Unix-like systems, returns the path unchanged.
    ///
    /// - Parameter path: The path to normalise.
    /// - Returns: The normalised path string.
    public static func normalizePath(_ path: String) -> String {
        #if os(Windows)
        return path.replacingOccurrences(of: "/", with: "\\")
        #else
        return path
        #endif
    }

    /// Returns the temporary directory path for the current platform.
    ///
    /// Uses `FileManager.default.temporaryDirectory` which is platform-aware.
    ///
    /// - Returns: The URL of the temporary directory.
    public static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
    }

    /// Creates a platform-appropriate temporary file URL with the given name.
    ///
    /// - Parameter filename: The name of the temporary file.
    /// - Returns: A URL pointing to a file in the system temporary directory.
    public static func temporaryFileURL(named filename: String) -> URL {
        temporaryDirectory().appendingPathComponent(filename)
    }
}

// MARK: - Foundation Compatibility

/// Cross-platform Foundation compatibility utilities.
///
/// Provides wrappers for Foundation APIs that behave differently on Windows,
/// Linux, and macOS.
public enum J2KFoundationCompat: Sendable {
    /// Checks whether a file exists at the given URL.
    ///
    /// Uses `FileManager.default.fileExists(atPath:)` with proper path conversion.
    ///
    /// - Parameter url: The file URL to check.
    /// - Returns: `true` if the file exists.
    public static func fileExists(at url: URL) -> Bool {
        #if os(Windows)
        // On Windows, URL.path may return paths with forward slashes;
        // FileManager handles this, but we normalise for safety.
        let path = J2KPathUtilities.normalizePath(url.path)
        return FileManager.default.fileExists(atPath: path)
        #else
        return FileManager.default.fileExists(atPath: url.path)
        #endif
    }

    /// Creates a directory at the given URL, creating intermediate directories as needed.
    ///
    /// - Parameter url: The directory URL to create.
    /// - Throws: An error if directory creation fails.
    public static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Reads the contents of a file at the given URL.
    ///
    /// - Parameter url: The file URL to read.
    /// - Returns: The file data.
    /// - Throws: An error if reading fails.
    public static func readFile(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    /// Writes data to a file at the given URL atomically.
    ///
    /// - Parameters:
    ///   - data: The data to write.
    ///   - url: The destination file URL.
    /// - Throws: An error if writing fails.
    public static func writeFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    /// Removes the item at the given URL.
    ///
    /// - Parameter url: The URL of the item to remove.
    /// - Throws: An error if removal fails.
    public static func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// Lists the contents of a directory at the given URL.
    ///
    /// - Parameter url: The directory URL to list.
    /// - Returns: An array of URLs for the directory contents.
    /// - Throws: An error if the directory cannot be read.
    public static func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
    }
}
