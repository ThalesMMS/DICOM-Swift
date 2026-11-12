//
//  LoggingTests.swift
//  DicomCoreTests
//
//  Checks logger creation and retention of log levels in recorded entries.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class LoggingTests: XCTestCase {

    // MARK: - DicomLogger Factory Tests

    func testDicomLoggerFactoryCreatesValidLogger() {
        let logger = DicomLogger.make(subsystem: "com.test.dicom", category: "test")
        XCTAssertNotNil(logger, "Factory should create valid logger")
    }

    func testDicomLoggerFactoryWithDifferentSubsystems() {
        let logger1 = DicomLogger.make(subsystem: "com.test.dicom", category: "decoder")
        let logger2 = DicomLogger.make(subsystem: "com.example.app", category: "networking")

        XCTAssertNotNil(logger1, "Should create logger with first subsystem")
        XCTAssertNotNil(logger2, "Should create logger with second subsystem")
    }

    func testDicomLoggerFactoryWithDifferentCategories() {
        let logger1 = DicomLogger.make(subsystem: "com.test.dicom", category: "decoder")
        let logger2 = DicomLogger.make(subsystem: "com.test.dicom", category: "processor")
        let logger3 = DicomLogger.make(subsystem: "com.test.dicom", category: "networking")

        XCTAssertNotNil(logger1, "Should create logger with decoder category")
        XCTAssertNotNil(logger2, "Should create logger with processor category")
        XCTAssertNotNil(logger3, "Should create logger with networking category")
    }

    // MARK: - DicomLogger LoggerProtocol Conformance Tests

    func testDicomLoggerConformsToLoggerProtocol() {
        let logger: LoggerProtocol = DicomLogger.make(subsystem: "com.test.dicom", category: "test")

        // Should not crash - verifies all protocol methods exist
        logger.debug("Test debug message")
        logger.info("Test info message")
        logger.warning("Test warning message")
        logger.error("Test error message")
    }

    func testDicomLoggerDebugMethod() {
        let logger = DicomLogger.make(subsystem: "com.test.dicom", category: "test")

        // Should not crash
        logger.debug("Debug: Processing DICOM file")
        logger.debug("Debug: Found 128 byte preamble")
    }

    func testDicomLoggerInfoMethod() {
        let logger = DicomLogger.make(subsystem: "com.test.dicom", category: "test")

        // Should not crash
        logger.info("Info: Loading DICOM file")
        logger.info("Info: Successfully parsed metadata")
    }

    func testDicomLoggerWarningMethod() {
        let logger = DicomLogger.make(subsystem: "com.test.dicom", category: "test")

        // Should not crash
        logger.warning("Warning: Missing optional tag")
        logger.warning("Warning: Using fallback value")
    }

    func testDicomLoggerErrorMethod() {
        let logger = DicomLogger.make(subsystem: "com.test.dicom", category: "test")

        // Should not crash
        logger.error("Error: Failed to read pixel data")
        logger.error("Error: Invalid DICOM format")
    }

    // MARK: - MockLogger Initialization Tests

    func testMockLoggerInitialization() {
        let mockLogger = MockLogger()

        XCTAssertNotNil(mockLogger, "MockLogger should initialize successfully")
        XCTAssertEqual(mockLogger.messageCount, 0, "Initial message count should be zero")
        XCTAssertTrue(mockLogger.entries.isEmpty, "Initial entries should be empty")
    }

    // MARK: - MockLogger LoggerProtocol Conformance Tests

    func testMockLoggerConformsToLoggerProtocol() {
        let mockLogger: LoggerProtocol = MockLogger()

        // Should not crash - verifies all protocol methods exist
        mockLogger.debug("Test debug")
        mockLogger.info("Test info")
        mockLogger.warning("Test warning")
        mockLogger.error("Test error")
    }

    // MARK: - MockLogger Message Capture Tests

    func testMockLoggerCapturesDebugMessages() {
        let mockLogger = MockLogger()

        mockLogger.debug("Debug message 1")
        mockLogger.debug("Debug message 2")

        XCTAssertEqual(mockLogger.debugMessages.count, 2, "Should capture 2 debug messages")
        XCTAssertEqual(mockLogger.debugMessages[0], "Debug message 1", "First message should match")
        XCTAssertEqual(mockLogger.debugMessages[1], "Debug message 2", "Second message should match")
    }

    func testMockLoggerCapturesInfoMessages() {
        let mockLogger = MockLogger()

        mockLogger.info("Info message 1")
        mockLogger.info("Info message 2")

        XCTAssertEqual(mockLogger.infoMessages.count, 2, "Should capture 2 info messages")
        XCTAssertEqual(mockLogger.infoMessages[0], "Info message 1", "First message should match")
        XCTAssertEqual(mockLogger.infoMessages[1], "Info message 2", "Second message should match")
    }

    func testMockLoggerCapturesWarningMessages() {
        let mockLogger = MockLogger()

        mockLogger.warning("Warning message 1")
        mockLogger.warning("Warning message 2")

        XCTAssertEqual(mockLogger.warningMessages.count, 2, "Should capture 2 warning messages")
        XCTAssertEqual(mockLogger.warningMessages[0], "Warning message 1", "First message should match")
        XCTAssertEqual(mockLogger.warningMessages[1], "Warning message 2", "Second message should match")
    }

    func testMockLoggerCapturesErrorMessages() {
        let mockLogger = MockLogger()

        mockLogger.error("Error message 1")
        mockLogger.error("Error message 2")

        XCTAssertEqual(mockLogger.errorMessages.count, 2, "Should capture 2 error messages")
        XCTAssertEqual(mockLogger.errorMessages[0], "Error message 1", "First message should match")
        XCTAssertEqual(mockLogger.errorMessages[1], "Error message 2", "Second message should match")
    }

    func testMockLoggerCapturesMixedLevelMessages() {
        let mockLogger = MockLogger()

        mockLogger.debug("Debug message")
        mockLogger.info("Info message")
        mockLogger.warning("Warning message")
        mockLogger.error("Error message")

        XCTAssertEqual(mockLogger.messageCount, 4, "Should capture all 4 messages")
        XCTAssertEqual(mockLogger.debugMessages.count, 1, "Should have 1 debug message")
        XCTAssertEqual(mockLogger.infoMessages.count, 1, "Should have 1 info message")
        XCTAssertEqual(mockLogger.warningMessages.count, 1, "Should have 1 warning message")
        XCTAssertEqual(mockLogger.errorMessages.count, 1, "Should have 1 error message")
    }

    // MARK: - MockLogger Entry Tests

    func testMockLoggerEntriesContainLevel() {
        let mockLogger = MockLogger()

        mockLogger.debug("Debug")
        mockLogger.info("Info")
        mockLogger.warning("Warning")
        mockLogger.error("Error")

        XCTAssertEqual(mockLogger.entries.count, 4, "Should have 4 entries")
        XCTAssertEqual(mockLogger.entries[0].level, .debug, "First entry should be debug")
        XCTAssertEqual(mockLogger.entries[1].level, .info, "Second entry should be info")
        XCTAssertEqual(mockLogger.entries[2].level, .warning, "Third entry should be warning")
        XCTAssertEqual(mockLogger.entries[3].level, .error, "Fourth entry should be error")
    }

    func testMockLoggerEntriesContainMessage() {
        let mockLogger = MockLogger()

        mockLogger.debug("Debug message")
        mockLogger.info("Info message")

        XCTAssertEqual(mockLogger.entries[0].message, "Debug message", "Entry should contain debug message")
        XCTAssertEqual(mockLogger.entries[1].message, "Info message", "Entry should contain info message")
    }

    func testMockLoggerEntriesContainTimestamp() {
        let mockLogger = MockLogger()
        let beforeTime = Date()

        mockLogger.info("Test message")

        let afterTime = Date()
        let timestamp = mockLogger.entries[0].timestamp

        XCTAssertTrue(timestamp >= beforeTime, "Timestamp should be after start time")
        XCTAssertTrue(timestamp <= afterTime, "Timestamp should be before end time")
    }

    func testMockLoggerEntriesAreInChronologicalOrder() {
        let mockLogger = MockLogger()

        mockLogger.debug("First")
        mockLogger.info("Second")
        mockLogger.warning("Third")

        let entries = mockLogger.entries
        XCTAssertEqual(entries[0].message, "First", "First entry should be first")
        XCTAssertEqual(entries[1].message, "Second", "Second entry should be second")
        XCTAssertEqual(entries[2].message, "Third", "Third entry should be third")

        // Timestamps should be in ascending order
        XCTAssertTrue(entries[1].timestamp >= entries[0].timestamp, "Second timestamp should be after first")
        XCTAssertTrue(entries[2].timestamp >= entries[1].timestamp, "Third timestamp should be after second")
    }

    // MARK: - MockLogger Test Utility Tests

    func testMockLoggerContainsMethodWithLevel() {
        let mockLogger = MockLogger()

        mockLogger.debug("Processing DICOM file")
        mockLogger.info("File loaded successfully")
        mockLogger.error("Failed to read pixel data")

        XCTAssertTrue(mockLogger.contains(level: .debug, text: "DICOM"), "Should find DICOM in debug")
        XCTAssertTrue(mockLogger.contains(level: .info, text: "loaded"), "Should find loaded in info")
        XCTAssertTrue(mockLogger.contains(level: .error, text: "pixel"), "Should find pixel in error")

        XCTAssertFalse(mockLogger.contains(level: .debug, text: "pixel"), "Should not find pixel in debug")
        XCTAssertFalse(mockLogger.contains(level: .warning, text: "anything"), "Should not find anything in warning")
    }

    func testMockLoggerContainsMethodWithoutLevel() {
        let mockLogger = MockLogger()

        mockLogger.debug("Debug: test")
        mockLogger.info("Info: test")
        mockLogger.error("Error: test")

        XCTAssertTrue(mockLogger.contains(text: "test"), "Should find test in any level")
        XCTAssertTrue(mockLogger.contains(text: "Debug"), "Should find Debug")
        XCTAssertTrue(mockLogger.contains(text: "Error"), "Should find Error")
        XCTAssertFalse(mockLogger.contains(text: "missing"), "Should not find missing text")
    }

    func testMockLoggerCountMethodByLevel() {
        let mockLogger = MockLogger()

        mockLogger.debug("Debug 1")
        mockLogger.debug("Debug 2")
        mockLogger.info("Info 1")
        mockLogger.error("Error 1")
        mockLogger.error("Error 2")
        mockLogger.error("Error 3")

        XCTAssertEqual(mockLogger.count(level: .debug), 2, "Should count 2 debug messages")
        XCTAssertEqual(mockLogger.count(level: .info), 1, "Should count 1 info message")
        XCTAssertEqual(mockLogger.count(level: .warning), 0, "Should count 0 warning messages")
        XCTAssertEqual(mockLogger.count(level: .error), 3, "Should count 3 error messages")
    }

    func testMockLoggerLastMessageMethod() {
        let mockLogger = MockLogger()

        mockLogger.debug("Debug 1")
        mockLogger.debug("Debug 2")
        mockLogger.info("Info 1")

        XCTAssertEqual(mockLogger.lastMessage(level: .debug), "Debug 2", "Should return last debug message")
        XCTAssertEqual(mockLogger.lastMessage(level: .info), "Info 1", "Should return last info message")
        XCTAssertNil(mockLogger.lastMessage(level: .warning), "Should return nil for warning")
        XCTAssertNil(mockLogger.lastMessage(level: .error), "Should return nil for error")
    }

    func testMockLoggerAllMessagesProperty() {
        let mockLogger = MockLogger()

        mockLogger.debug("Debug message")
        mockLogger.info("Info message")
        mockLogger.warning("Warning message")
        mockLogger.error("Error message")

        let allMessages = mockLogger.allMessages
        XCTAssertEqual(allMessages.count, 4, "Should have all 4 messages")
        XCTAssertEqual(allMessages[0], "Debug message", "First message should be debug")
        XCTAssertEqual(allMessages[1], "Info message", "Second message should be info")
        XCTAssertEqual(allMessages[2], "Warning message", "Third message should be warning")
        XCTAssertEqual(allMessages[3], "Error message", "Fourth message should be error")
    }

    func testMockLoggerClearMethod() {
        let mockLogger = MockLogger()

        mockLogger.debug("Debug")
        mockLogger.info("Info")
        mockLogger.warning("Warning")
        mockLogger.error("Error")

        XCTAssertEqual(mockLogger.messageCount, 4, "Should have 4 messages before clear")

        mockLogger.clear()

        XCTAssertEqual(mockLogger.messageCount, 0, "Should have 0 messages after clear")
        XCTAssertTrue(mockLogger.entries.isEmpty, "Entries should be empty after clear")
        XCTAssertTrue(mockLogger.debugMessages.isEmpty, "Debug messages should be empty")
        XCTAssertTrue(mockLogger.infoMessages.isEmpty, "Info messages should be empty")
        XCTAssertTrue(mockLogger.warningMessages.isEmpty, "Warning messages should be empty")
        XCTAssertTrue(mockLogger.errorMessages.isEmpty, "Error messages should be empty")
    }

    func testMockLoggerClearAllowsNewMessages() {
        let mockLogger = MockLogger()

        mockLogger.info("Before clear")
        mockLogger.clear()
        mockLogger.info("After clear")

        XCTAssertEqual(mockLogger.messageCount, 1, "Should have 1 message after clear and new log")
        XCTAssertEqual(mockLogger.infoMessages[0], "After clear", "Should only have message after clear")
    }

    // MARK: - MockLogger Thread Safety Tests

    func testMockLoggerThreadSafetyConcurrentWrites() {
        let mockLogger = MockLogger()
        let expectation = XCTestExpectation(description: "Concurrent logging completes")
        let iterations = 100

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            mockLogger.debug("Debug \(index)")
            mockLogger.info("Info \(index)")
            mockLogger.warning("Warning \(index)")
            mockLogger.error("Error \(index)")
        }

        DispatchQueue.main.async {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5.0)

        // Should capture all messages without data races
        XCTAssertEqual(mockLogger.messageCount, iterations * 4, "Should capture all messages from concurrent threads")
        XCTAssertEqual(mockLogger.debugMessages.count, iterations, "Should have all debug messages")
        XCTAssertEqual(mockLogger.infoMessages.count, iterations, "Should have all info messages")
        XCTAssertEqual(mockLogger.warningMessages.count, iterations, "Should have all warning messages")
        XCTAssertEqual(mockLogger.errorMessages.count, iterations, "Should have all error messages")
    }

    func testMockLoggerThreadSafetyConcurrentReads() {
        let mockLogger = MockLogger()

        // Pre-populate with messages
        for i in 0..<100 {
            mockLogger.info("Message \(i)")
        }

        let expectation = XCTestExpectation(description: "Concurrent reads complete")
        expectation.expectedFulfillmentCount = 10

        // Read from multiple threads
        for _ in 0..<10 {
            DispatchQueue.global().async {
                _ = mockLogger.messageCount
                _ = mockLogger.entries
                _ = mockLogger.infoMessages
                _ = mockLogger.allMessages
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)

        // Should not crash and should maintain consistent state
        XCTAssertEqual(mockLogger.messageCount, 100, "Count should remain consistent")
    }

    func testMockLoggerThreadSafetyConcurrentReadsDuringWrites() {
        let mockLogger = MockLogger()
        let writeExpectation = XCTestExpectation(description: "Writing completes")
        let readExpectation = XCTestExpectation(description: "Reading completes")
        readExpectation.expectedFulfillmentCount = 5

        // Write from one queue
        DispatchQueue.global().async {
            for i in 0..<100 {
                mockLogger.info("Write \(i)")
            }
            writeExpectation.fulfill()
        }

        // Read from multiple queues simultaneously
        for _ in 0..<5 {
            DispatchQueue.global().async {
                for _ in 0..<20 {
                    _ = mockLogger.messageCount
                    _ = mockLogger.infoMessages
                }
                readExpectation.fulfill()
            }
        }

        wait(for: [writeExpectation, readExpectation], timeout: 5.0)

        // Should not crash and should have all messages
        XCTAssertEqual(mockLogger.messageCount, 100, "Should capture all messages")
    }

    // MARK: - LogEntry Equality Tests

    func testLogEntryEquality() {
        let timestamp = Date()
        let entry1 = MockLogger.LogEntry(level: .info, message: "Test", timestamp: timestamp)
        let entry2 = MockLogger.LogEntry(level: .info, message: "Test", timestamp: timestamp)
        let entry3 = MockLogger.LogEntry(level: .debug, message: "Test", timestamp: timestamp)
        let entry4 = MockLogger.LogEntry(level: .info, message: "Different", timestamp: timestamp)

        XCTAssertEqual(entry1, entry2, "Identical entries should be equal")
        XCTAssertNotEqual(entry1, entry3, "Different levels should not be equal")
        XCTAssertNotEqual(entry1, entry4, "Different messages should not be equal")
    }

    // MARK: - LogLevel Tests

    func testLogLevelRawValues() {
        XCTAssertEqual(MockLogger.LogLevel.debug.rawValue, "debug")
        XCTAssertEqual(MockLogger.LogLevel.info.rawValue, "info")
        XCTAssertEqual(MockLogger.LogLevel.warning.rawValue, "warning")
        XCTAssertEqual(MockLogger.LogLevel.error.rawValue, "error")
    }

    func testLogLevelEquality() {
        XCTAssertEqual(MockLogger.LogLevel.debug, MockLogger.LogLevel.debug)
        XCTAssertEqual(MockLogger.LogLevel.info, MockLogger.LogLevel.info)
        XCTAssertNotEqual(MockLogger.LogLevel.debug, MockLogger.LogLevel.info)
        XCTAssertNotEqual(MockLogger.LogLevel.warning, MockLogger.LogLevel.error)
    }

    // MARK: - Integration Tests with Real Scenarios

    func testMockLoggerInDependencyInjectionPattern() {
        // Simulate using MockLogger with a service that accepts LoggerProtocol
        let mockLogger = MockLogger()
        let logger: LoggerProtocol = mockLogger

        // Service would log during operation
        logger.info("Starting DICOM file processing")
        logger.debug("Reading file header")
        logger.debug("Parsing metadata tags")
        logger.info("Successfully loaded file")

        // Test can verify logging behavior
        XCTAssertEqual(mockLogger.count(level: .info), 2, "Should have logged 2 info messages")
        XCTAssertEqual(mockLogger.count(level: .debug), 2, "Should have logged 2 debug messages")
        XCTAssertTrue(mockLogger.contains(level: .info, text: "processing"), "Should log processing start")
        XCTAssertTrue(mockLogger.contains(level: .info, text: "loaded"), "Should log success")
    }

    func testMockLoggerCapturingErrorScenarios() {
        let mockLogger = MockLogger()

        // Simulate error logging scenario
        mockLogger.info("Attempting to read DICOM file")
        mockLogger.warning("File size exceeds recommended limit")
        mockLogger.error("Failed to allocate memory for pixel data")
        mockLogger.error("Operation aborted")

        // Verify error handling was logged
        XCTAssertEqual(mockLogger.count(level: .error), 2, "Should log 2 errors")
        XCTAssertEqual(mockLogger.count(level: .warning), 1, "Should log 1 warning")
        XCTAssertTrue(mockLogger.contains(level: .error, text: "memory"), "Should log memory error")
        XCTAssertTrue(mockLogger.contains(level: .error, text: "aborted"), "Should log abort")

        let lastError = mockLogger.lastMessage(level: .error)
        XCTAssertEqual(lastError, "Operation aborted", "Last error should be abort message")
    }

    func testMockLoggerWithComplexLogMessages() {
        let mockLogger = MockLogger()

        // Test with messages containing special characters
        mockLogger.info("File path: /Users/test/DICOM/CT-1.dcm")
        mockLogger.debug("Tag value: Patient Name = \"Doe^John\"")
        mockLogger.warning("Missing tag: (0010,0030)")
        mockLogger.error("Invalid format: expected 'DICM', found '\u{0000}\u{0000}\u{0000}\u{0000}'")

        XCTAssertEqual(mockLogger.messageCount, 4, "Should capture all complex messages")
        XCTAssertTrue(mockLogger.contains(text: "Doe^John"), "Should handle quoted strings")
        XCTAssertTrue(mockLogger.contains(text: "(0010,0030)"), "Should handle tag format")
        XCTAssertTrue(mockLogger.contains(text: "/Users/test/DICOM"), "Should handle file paths")
    }

    func testMockLoggerWithEmptyMessages() {
        let mockLogger = MockLogger()

        mockLogger.debug("")
        mockLogger.info("")
        mockLogger.warning("")
        mockLogger.error("")

        XCTAssertEqual(mockLogger.messageCount, 4, "Should capture empty messages")
        XCTAssertEqual(mockLogger.debugMessages[0], "", "Debug message should be empty")
        XCTAssertEqual(mockLogger.infoMessages[0], "", "Info message should be empty")
        XCTAssertEqual(mockLogger.warningMessages[0], "", "Warning message should be empty")
        XCTAssertEqual(mockLogger.errorMessages[0], "", "Error message should be empty")
    }

    func testMockLoggerWithVeryLongMessages() {
        let mockLogger = MockLogger()
        let longMessage = String(repeating: "A", count: 10000)

        mockLogger.info(longMessage)

        XCTAssertEqual(mockLogger.messageCount, 1, "Should capture long message")
        XCTAssertEqual(mockLogger.infoMessages[0], longMessage, "Should preserve full message content")
        XCTAssertEqual(mockLogger.infoMessages[0].count, 10000, "Should preserve message length")
    }

    // MARK: - Type Conformance Tests

    func testLoggerProtocolAsParameter() {
        // Helper function that accepts LoggerProtocol
        func logOperation(with logger: LoggerProtocol, operation: String) {
            logger.info("Starting: \(operation)")
            logger.debug("Operation details: \(operation)")
            logger.info("Completed: \(operation)")
        }

        let mockLogger = MockLogger()
        logOperation(with: mockLogger, operation: "test operation")

        XCTAssertEqual(mockLogger.count(level: .info), 2, "Should log 2 info messages")
        XCTAssertEqual(mockLogger.count(level: .debug), 1, "Should log 1 debug message")
        XCTAssertTrue(mockLogger.contains(text: "test operation"), "Should contain operation name")
    }

    func testDicomLoggerAsLoggerProtocol() {
        let logger: LoggerProtocol = DicomLogger.make(subsystem: "com.test", category: "test")

        // Should be able to use as protocol type
        logger.debug("Debug")
        logger.info("Info")
        logger.warning("Warning")
        logger.error("Error")

        // No assertions needed - test passes if no crash occurs
    }

    func testMockLoggerAsLoggerProtocol() {
        let logger: LoggerProtocol = MockLogger()

        // Should be able to use as protocol type
        logger.debug("Debug")
        logger.info("Info")
        logger.warning("Warning")
        logger.error("Error")

        // Verify we can still access mock-specific functionality through original reference
        let mockLogger = logger as! MockLogger
        XCTAssertEqual(mockLogger.messageCount, 4, "Should have logged 4 messages")
    }

    // MARK: - Performance Tests

    func testMockLoggerPerformanceWithManyMessages() {
        measure {
            let mockLogger = MockLogger()
            for i in 0..<1000 {
                mockLogger.info("Message \(i)")
            }
            XCTAssertEqual(mockLogger.messageCount, 1000, "Should capture all messages")
        }
    }

    func testMockLoggerPerformanceWithMixedLevels() {
        measure {
            let mockLogger = MockLogger()
            for i in 0..<250 {
                mockLogger.debug("Debug \(i)")
                mockLogger.info("Info \(i)")
                mockLogger.warning("Warning \(i)")
                mockLogger.error("Error \(i)")
            }
            XCTAssertEqual(mockLogger.messageCount, 1000, "Should capture all messages")
        }
    }

    func testMockLoggerAccessorPerformance() {
        let mockLogger = MockLogger()

        // Pre-populate with messages
        for i in 0..<1000 {
            mockLogger.info("Message \(i)")
        }

        measure {
            _ = mockLogger.messageCount
            _ = mockLogger.infoMessages
            _ = mockLogger.allMessages
            _ = mockLogger.entries
        }
    }
}
