//
//  XCTestCase+DicomAssertions.swift
//  DicomCoreTests
//
//  Adds dicom assertions support to XCTestCase.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

extension XCTestCase {
    /// Asserts that evaluating `expression` throws `DICOMError.invalidDICOMFormat` and, if provided, that the error's reason contains `reasonContains`.
    /// - Parameters:
    ///   - expression: The throwing expression expected to produce a `DICOMError.invalidDICOMFormat`.
    ///   - reasonContains: Optional substring that must be present in the error's reason; if `nil`, the reason is not checked.
    ///   - file: The file name to use in failure messages. Default is the calling file.
    ///   - line: The line number to use in failure messages. Default is the calling line.
    func XCTAssertThrowsInvalidDICOMFormat<T>(
        _ expression: @autoclosure () throws -> T,
        reasonContains: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case let DICOMError.invalidDICOMFormat(reason) = error else {
                XCTFail("Expected invalidDICOMFormat, got \(error)", file: file, line: line)
                return
            }

            if let reasonContains {
                XCTAssertTrue(reason.contains(reasonContains), "Expected reason to contain '\(reasonContains)', got '\(reason)'", file: file, line: line)
            }
        }
    }

    /// Asserts that the provided async expression throws `DICOMError.invalidDICOMFormat` and optionally that the error's reason contains a given substring.
    /// - Parameters:
    ///   - expression: The async throwing expression to evaluate.
    ///   - reasonContains: If non-`nil`, asserts that the captured error reason contains this substring.
    ///   - file: The file where the assertion is called. Defaults to the caller's file.
    ///   - line: The line number where the assertion is called. Defaults to the caller's line.
    func XCTAssertThrowsInvalidDICOMFormat<T>(
        _ expression: @escaping () async throws -> T,
        reasonContains: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected invalidDICOMFormat to be thrown", file: file, line: line)
        } catch {
            guard case let DICOMError.invalidDICOMFormat(reason) = error else {
                XCTFail("Expected invalidDICOMFormat, got \(error)", file: file, line: line)
                return
            }

            if let reasonContains {
                XCTAssertTrue(reason.contains(reasonContains), "Expected reason to contain '\(reasonContains)', got '\(reason)'", file: file, line: line)
            }
        }
    }

    /// Asserts that evaluating `expression` throws `DICOMError.fileNotFound` and, if provided, that the thrown path contains `pathContains`.
    /// - Parameters:
    ///   - expression: The throwing expression to evaluate.
    ///   - pathContains: Optional substring that must be present in the file path carried by the thrown `fileNotFound` error.
    ///   - file: The file in which failure occurred. Defaults to the caller's file.
    ///   - line: The line number on which failure occurred. Defaults to the caller's line.
    func XCTAssertThrowsFileNotFound<T>(
        _ expression: @autoclosure () throws -> T,
        pathContains: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case let DICOMError.fileNotFound(path) = error else {
                XCTFail("Expected fileNotFound, got \(error)", file: file, line: line)
                return
            }

            if let pathContains {
                XCTAssertTrue(path.contains(pathContains), "Expected path to contain '\(pathContains)', got '\(path)'", file: file, line: line)
            }
        }
    }

    /// Asserts that the given asynchronous expression throws `DICOMError.fileNotFound` and, if provided, that the captured path contains a given substring.
    /// 
    /// If the expression completes without throwing or throws a different error, the assertion fails.
    /// - Parameters:
    ///   - pathContains: Optional substring that must be present in the `path` associated with the thrown `DICOMError.fileNotFound`. If `nil`, no path content check is performed.
    func XCTAssertThrowsFileNotFound<T>(
        _ expression: @escaping () async throws -> T,
        pathContains: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected fileNotFound to be thrown", file: file, line: line)
        } catch {
            guard case let DICOMError.fileNotFound(path) = error else {
                XCTFail("Expected fileNotFound, got \(error)", file: file, line: line)
                return
            }

            if let pathContains {
                XCTAssertTrue(path.contains(pathContains), "Expected path to contain '\(pathContains)', got '\(path)'", file: file, line: line)
            }
        }
    }

    /// Asserts that evaluating `expression` throws `DicomSeriesLoaderError.noDicomFiles`.
    /// 
    /// If `expression` does not throw or throws a different error, the assertion fails with a descriptive message.
    /// - Parameter expression: A throwing expression that is expected to raise `DicomSeriesLoaderError.noDicomFiles`.
    /// - Parameters:
    ///   - file: The file name to display in test failures. Defaults to the call site.
    ///   - line: The line number to display in test failures. Defaults to the call site.
    func XCTAssertThrowsNoDicomFiles<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case DicomSeriesLoaderError.noDicomFiles = error else {
                XCTFail("Expected noDicomFiles, got \(error)", file: file, line: line)
                return
            }
        }
    }

    /// Asserts that executing the provided expression throws `DicomSeriesLoaderError.noDicomFiles`.
    /// - Parameter expression: An async throwing expression that is expected to fail with `noDicomFiles`. If the expression returns normally or throws a different error, the assertion fails.
    func XCTAssertThrowsNoDicomFiles<T>(
        _ expression: @escaping () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected noDicomFiles to be thrown", file: file, line: line)
        } catch {
            guard case DicomSeriesLoaderError.noDicomFiles = error else {
                XCTFail("Expected noDicomFiles, got \(error)", file: file, line: line)
                return
            }
        }
    }
}
