//
//  MockLogger.swift
//
//  Mock implementation of LoggerProtocol for unit testing.
//  Provides configurable message capture and thread-safe
//  logging verification without producing actual log output.
//
//  Thread Safety:
//
//  All properties and methods are thread-safe using a serial
//  dispatch queue for synchronization. Tests can safely capture
//  and verify logged messages from multiple threads.
//

import Foundation
@testable import DicomCore

/// Mock implementation of LoggerProtocol for testing.
/// Captures all logged messages in memory for test verification.
/// Thread-safe and supports concurrent logging from multiple threads.
/// All mutable entries are serialized by `queue`.
public final class MockLogger: LoggerProtocol, @unchecked Sendable {

    // MARK: - Types

    /// Represents a captured log message with its level and content.
    public struct LogEntry: Equatable, Sendable {
        public let level: LogLevel
        public let message: String
        public let timestamp: Date

        public init(level: LogLevel, message: String, timestamp: Date = Date()) {
            self.level = level
            self.message = message
            self.timestamp = timestamp
        }
    }

    /// Log severity levels matching LoggerProtocol methods.
    public enum LogLevel: String, Equatable, Sendable {
        case debug
        case info
        case warning
        case error
    }

    // MARK: - Thread Safety

    private let queue = DispatchQueue(label: "com.dicomcore.mocklogger")

    // MARK: - Captured Messages

    private var _entries: [LogEntry] = []

    /// All captured log entries in chronological order.
    /// Thread-safe accessor for test verification.
    public var entries: [LogEntry] {
        queue.sync { _entries }
    }

    /// Count of all captured messages across all levels.
    public var messageCount: Int {
        queue.sync { _entries.count }
    }

    // MARK: - Level-Specific Accessors

    /// All debug messages in chronological order.
    public var debugMessages: [String] {
        queue.sync {
            _entries.filter { $0.level == .debug }.map { $0.message }
        }
    }

    /// All info messages in chronological order.
    public var infoMessages: [String] {
        queue.sync {
            _entries.filter { $0.level == .info }.map { $0.message }
        }
    }

    /// All warning messages in chronological order.
    public var warningMessages: [String] {
        queue.sync {
            _entries.filter { $0.level == .warning }.map { $0.message }
        }
    }

    /// All error messages in chronological order.
    public var errorMessages: [String] {
        queue.sync {
            _entries.filter { $0.level == .error }.map { $0.message }
        }
    }

    // MARK: - Initialization

    public init() {
        // Default initialization with empty message buffer
    }

    // MARK: - LoggerProtocol Implementation

    /// Logs a debug-level message.
    /// Captures the message for test verification without producing output.
    ///
    /// - Parameter message: The message to log
    public func debug(_ message: String) {
        queue.sync {
            _entries.append(LogEntry(level: .debug, message: message))
        }
    }

    /// Logs an informational message.
    /// Captures the message for test verification without producing output.
    ///
    /// - Parameter message: The message to log
    public func info(_ message: String) {
        queue.sync {
            _entries.append(LogEntry(level: .info, message: message))
        }
    }

    /// Logs a warning message.
    /// Captures the message for test verification without producing output.
    ///
    /// - Parameter message: The message to log
    public func warning(_ message: String) {
        queue.sync {
            _entries.append(LogEntry(level: .warning, message: message))
        }
    }

    /// Logs an error message.
    /// Captures the message for test verification without producing output.
    ///
    /// - Parameter message: The message to log
    public func error(_ message: String) {
        queue.sync {
            _entries.append(LogEntry(level: .error, message: message))
        }
    }

    // MARK: - Test Utilities

    /// Clears all captured log entries.
    /// Useful for resetting state between test cases.
    public func clear() {
        queue.sync {
            _entries.removeAll()
        }
    }

    /// Checks if any message at the specified level contains the given text.
    ///
    /// - Parameters:
    ///   - level: The log level to search
    ///   - text: The text to search for (case-sensitive)
    /// - Returns: True if any message at the level contains the text
    public func contains(level: LogLevel, text: String) -> Bool {
        queue.sync {
            _entries.filter { $0.level == level }.contains { $0.message.contains(text) }
        }
    }

    /// Checks if any message at any level contains the given text.
    ///
    /// - Parameter text: The text to search for (case-sensitive)
    /// - Returns: True if any message contains the text
    public func contains(text: String) -> Bool {
        queue.sync {
            _entries.contains { $0.message.contains(text) }
        }
    }

    /// Returns the count of messages at the specified level.
    ///
    /// - Parameter level: The log level to count
    /// - Returns: Number of messages at that level
    public func count(level: LogLevel) -> Int {
        queue.sync {
            _entries.filter { $0.level == level }.count
        }
    }

    /// Returns the most recent message at the specified level, if any.
    ///
    /// - Parameter level: The log level to search
    /// - Returns: The most recent message, or nil if no messages at that level
    public func lastMessage(level: LogLevel) -> String? {
        queue.sync {
            _entries.filter { $0.level == level }.last?.message
        }
    }

    /// Returns all messages (across all levels) in chronological order.
    ///
    /// - Returns: Array of all logged messages
    public var allMessages: [String] {
        queue.sync {
            _entries.map { $0.message }
        }
    }
}
