import XCTest
@testable import DicomCore

final class DicomRepresentationConflictTests: XCTestCase {
    func test_sameUID_notADuplicateWithoutMatchingBytes() throws {
        let original = try RepresentationFixture.descriptor(RepresentationFixture.bytes())
        let other = RepresentationFixture.candidate(original, syntax: .rleLossless)
        XCTAssertEqual(DicomRepresentationConflict.classify(existing: original, incoming: original), .identicalBytes)
        XCTAssertEqual(DicomRepresentationConflict.classify(existing: original, incoming: other), .conflictingContent)
        XCTAssertEqual(DicomRepresentationConflict.classify(existing: original, incoming: other,
            verifiedDecodedPixelsAndAttributesEqual: true), .equivalentEncoding)
    }

    func test_keepBoth_mintsUIDAndRecordsPreviousAttributes() throws {
        let bytes = try RepresentationFixture.bytes(history: true)
        let result = try DicomRepresentationConflictPolicy.keepBoth(mintNewIdentity: true)
            .resolve(incoming: bytes, creatorIdentifier: "test")
        XCTAssertTrue(result.retainExisting)
        let output = try XCTUnwrap(result.incomingBytes)
        let set = try DCMDecoder(data: output).dataSet
        XCTAssertNotEqual(set.string(for: .sopInstanceUID), RepresentationFixture.uid)
        XCTAssertEqual(set.string(for: 0x00282110), "01")
        XCTAssertEqual(set.string(for: 0x00282112), "2")
        XCTAssertTrue(set.string(for: .imageType)?.hasPrefix("DERIVED") == true)
        let prior = set.element(for: 0x04000561)?.sequenceItems.first?.dataSet
            .element(for: 0x04000550)?.sequenceItems.first?.dataSet
        XCTAssertEqual(prior?.string(for: .sopInstanceUID), RepresentationFixture.uid)
        XCTAssertEqual(set.element(for: .sourceImageSequence)?.sequenceItems.first?.dataSet.string(for: .referencedSOPInstanceUID),
                       RepresentationFixture.uid)
    }

    func test_replacementAndKeepBoth_requireExplicitAuthorization() throws {
        let bytes = try RepresentationFixture.bytes()
        XCTAssertThrowsError(try DicomRepresentationConflictPolicy.replace(authorization: " ")
            .resolve(incoming: bytes, creatorIdentifier: "test"))
        XCTAssertThrowsError(try DicomRepresentationConflictPolicy.keepBoth(mintNewIdentity: false)
            .resolve(incoming: bytes, creatorIdentifier: "test"))
        let kept = try DicomRepresentationConflictPolicy.keepExisting.resolve(incoming: bytes, creatorIdentifier: "test")
        XCTAssertTrue(kept.retainExisting)
        XCTAssertNil(kept.incomingBytes)
    }
}
