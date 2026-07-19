//
//  CodecCommandTests.swift
//  dicomtoolTests
//

import ArgumentParser
import DicomCore
import XCTest
@testable import dicomtool

final class CodecCommandTests: XCTestCase {
    func test_exitMappingCoversEveryTypedWorkflowState() {
        let mappings: [(DicomCodecWorkflowError, ExitCode)] = [
            (.invalidDICOM(reason: "invalid"), ExitCode(65)),
            (.corruptFrame(index: 0, reason: "corrupt"), ExitCode(65)),
            (.artifactValidation(reason: "invalid artifact"), ExitCode(65)),
            (
                .unsupported(sourceUID: "source", targetUID: "target", reasons: ["unsupported"]),
                ExitCode(64)
            ),
            (.backendUnavailable(identifier: "codec", reason: "not linked"), ExitCode(69))
        ]

        for (error, expected) in mappings {
            XCTAssertEqual(CodecCommandSupport.exit(for: error) as? ExitCode, expected)
        }
    }
}
