import XCTest
@testable import DicomCore

final class DicomSynchronousResultTests: XCTestCase {
    func testResolveKeepsFirstTerminalResult() throws {
        let result = DicomSynchronousResult<Int>()

        XCTAssertTrue(result.resolve(.success(7)))
        XCTAssertFalse(result.resolve(.success(9)))
        XCTAssertEqual(try result.get(), 7)
    }

    func testConcurrentResolutionAcceptsExactlyOneResult() async throws {
        let result = DicomSynchronousResult<Int>()

        let acceptedCount = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for value in 0..<20 {
                group.addTask {
                    result.resolve(.success(value))
                }
            }

            var count = 0
            for await accepted in group where accepted {
                count += 1
            }
            return count
        }

        XCTAssertEqual(acceptedCount, 1)
        XCTAssertNotNil(try result.get())
    }
}
