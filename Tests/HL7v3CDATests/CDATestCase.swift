import Foundation
import XCTest

/// Keep failure locations visible with the task's mandated `tail -30` verification command.
class CDATestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = CDAFailureObserver.registered
    }
}

private final class CDAFailureObserver: NSObject, XCTestObservation, @unchecked Sendable {
    static let registered: CDAFailureObserver = {
        let observer = CDAFailureObserver()
        XCTestObservationCenter.shared.addTestObserver(observer)
        return observer
    }()
    private let lock = NSLock()
    private var failures: [String] = []
    func testCase(_ testCase: XCTestCase, didFailWithDescription description: String, inFile filePath: String?, atLine lineNumber: Int) {
        lock.lock()
        defer { lock.unlock() }
        failures.append("CDA failure: \(testCase.name) at \(URL(fileURLWithPath: filePath ?? "unknown").lastPathComponent):\(lineNumber)")
    }
    func testBundleDidFinish(_ testBundle: Bundle) {
        lock.lock()
        defer { lock.unlock() }
        for failure in failures { print(failure) }
    }
}
