//
//  DicomBlockingAsyncOperationTests.swift
//  DicomCoreTests
//
//  IsiX-DICOM-Viewer #3220: the synchronous entry to the async JPEG 2000 decode ran every decode at
//  `.userInitiated`, so a background volume build competed with the viewer. The decode now takes
//  the priority it is given, or the calling thread's QoS.
//
//  Thales Matheus Mendonça Santos — November 2026
//

import Dispatch
import Foundation
import XCTest
@testable import DicomCore

final class DicomBlockingAsyncOperationTests: XCTestCase {
    func test_run_withAPriority_runsTheOperationAtThatPriority() throws {
        for priority in [TaskPriority.background, .utility, .userInitiated] {
            XCTAssertEqual(try DicomBlockingAsyncOperation.run(priority: priority) { Task.currentPriority }, priority)
        }
    }

    func test_run_withoutAPriority_inheritsTheCallingThreadsQoS() {
        let cases: [(DispatchQoS, TaskPriority)] = [
            (.utility, .utility), (.default, .medium), (.userInitiated, .userInitiated)
        ]
        for (qos, expected) in cases {
            let done = DispatchSemaphore(value: 0)
            let observed = PriorityBox()
            // Enforced, so the block runs at the queue's class rather than the test thread's.
            DispatchQueue.global(qos: qos.qosClass).async(qos: qos, flags: .enforceQoS) {
                observed.value = try? DicomBlockingAsyncOperation.run { Task.currentPriority }
                done.signal()
            }
            done.wait()
            XCTAssertEqual(observed.value, expected, "a decode called on a \(qos.qosClass) thread")
        }
    }

    func test_taskPriority_mapsEveryQoSClass() {
        XCTAssertEqual(DicomBlockingAsyncOperation.taskPriority(for: QOS_CLASS_USER_INTERACTIVE), .userInitiated)
        XCTAssertEqual(DicomBlockingAsyncOperation.taskPriority(for: QOS_CLASS_USER_INITIATED), .userInitiated)
        XCTAssertEqual(DicomBlockingAsyncOperation.taskPriority(for: QOS_CLASS_DEFAULT), .medium)
        XCTAssertEqual(DicomBlockingAsyncOperation.taskPriority(for: QOS_CLASS_UTILITY), .utility)
        XCTAssertEqual(DicomBlockingAsyncOperation.taskPriority(for: QOS_CLASS_BACKGROUND), .background)
        XCTAssertEqual(DicomBlockingAsyncOperation.taskPriority(for: QOS_CLASS_UNSPECIFIED), .medium)
    }

    func test_run_rethrowsTheOperationsError() {
        struct Failure: Error {}
        XCTAssertThrowsError(try DicomBlockingAsyncOperation.run(priority: .utility) { () throws -> Int in
            throw Failure()
        }) { XCTAssertTrue($0 is Failure) }
    }
}

private final class PriorityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TaskPriority?

    var value: TaskPriority? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
