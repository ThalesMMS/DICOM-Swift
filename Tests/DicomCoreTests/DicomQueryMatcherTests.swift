import XCTest
@testable import DicomCore

final class DicomQueryMatcherTests: XCTestCase {
    private func data(_ vr: DicomVR, _ value: String, tag: Int = 0x00100010) -> DicomDataSet {
        DicomDataSet(elements: [DicomDataElement(tag: tag, vr: vr, value: .strings([value]))])
    }

    func test_singleUniversalAndWildcard_matchingRules() throws {
        let matcher = DicomQueryMatcher()
        XCTAssertTrue(try matcher.matches(data(.PN, "Doe^Ana"), identifier: data(.PN, "D*^?na")))
        XCTAssertFalse(try matcher.matches(data(.PN, "Doe^Ana"), identifier: data(.PN, "doe^Ana")))
        XCTAssertTrue(try matcher.matches(DicomDataSet(), identifier: data(.LO, "")))
        XCTAssertTrue(try matcher.matches(DicomDataSet(), identifier: data(.LO, "*")))
        XCTAssertFalse(try matcher.matches(data(.LO, "abc"), identifier: data(.LO, "a?")))
        XCTAssertTrue(try matcher.matches(data(.LO, "a.b"), identifier: data(.LO, "a.b")))
        XCTAssertFalse(try matcher.matches(data(.LO, "axb"), identifier: data(.LO, "a.b")))
        XCTAssertTrue(try matcher.matches(data(.IS, "007"), identifier: data(.IS, "+7")))
    }

    func test_UIDList_andNegotiatedMultipleValues() throws {
        XCTAssertTrue(try DicomQueryMatcher().matches(data(.UI, "1.2.3"), identifier: data(.UI, "1.2.4\\1.2.3")))
        XCTAssertThrowsError(try DicomQueryMatcher().matches(data(.CS, "CT\\PT"), identifier: data(.CS, "CT\\PT")))
        let matcher = DicomQueryMatcher(multipleValueMatching: true)
        XCTAssertTrue(try matcher.matches(data(.CS, "PT\\MR\\CT"), identifier: data(.CS, "CT\\PT")))
        XCTAssertFalse(try matcher.matches(data(.CS, "CT"), identifier: data(.CS, "CT\\PT")))
    }

    func test_emptyAndUnknownRequiredKeys() throws {
        XCTAssertTrue(try DicomQueryMatcher(requiredKeys: [0x00100010]).matches(data(.PN, ""), identifier: data(.PN, "Doe")))
        XCTAssertFalse(try DicomQueryMatcher().matches(DicomDataSet(), identifier: data(.LO, "\"\"")))
        XCTAssertTrue(try DicomQueryMatcher(emptyValueMatching: true).matches(DicomDataSet(), identifier: data(.LO, "\"\"")))
    }

    func test_temporalRanges_precisionOffsetsAndMidnight() throws {
        let matcher = DicomQueryMatcher()
        XCTAssertTrue(try matcher.matches(data(.DA, "20260911"), identifier: data(.DA, "20260901-20260911")))
        XCTAssertTrue(try matcher.matches(data(.DA, "20260911"), identifier: data(.DA, "-20260911")))
        XCTAssertFalse(try matcher.matches(data(.DA, "20260831"), identifier: data(.DA, "20260901-")))
        XCTAssertTrue(try matcher.matches(data(.TM, "223000"), identifier: data(.TM, "2230")))
        XCTAssertThrowsError(try matcher.matches(data(.TM, "010000"), identifier: data(.TM, "2300-0200")))
        XCTAssertTrue(try matcher.matches(data(.DT, "19980128073000-0300"), identifier: data(.DT, "19980128103000+0000")))
        XCTAssertTrue(try matcher.matches(data(.DT, "19980128103000.0000"), identifier: data(.DT, "19980128103000")))
        XCTAssertTrue(try matcher.matches(data(.DT, "20260101120000-0300"),
            identifier: data(.DT, "20260101110000-0300-20260101130000-0300")))
        XCTAssertFalse(try matcher.matches(data(.DA, "20260230"), identifier: data(.DA, "20260101-20261231")))
    }

    func test_sequenceKeys_matchTogetherWithinOneItem() throws {
        func sequence(_ items: [DicomDataSet]) -> DicomDataSet {
            DicomDataSet(elements: [DicomDataElement(tag: 0x00400100, vr: .SQ,
                value: .sequence(items.map { DicomSequenceItem(dataSet: $0) }))])
        }
        let name = data(.PN, "Doe")
        let identifier = data(.LO, "123", tag: 0x00100020)
        var both = name
        both.set(identifier.elements[0])
        XCTAssertFalse(try DicomQueryMatcher().matches(sequence([name, identifier]), identifier: sequence([both])))
        XCTAssertTrue(try DicomQueryMatcher().matches(sequence([both]), identifier: sequence([both])))
        XCTAssertTrue(try DicomQueryMatcher().matches(DicomDataSet(), identifier: sequence([DicomDataSet()])))
        XCTAssertThrowsError(try DicomQueryMatcher().matches(sequence([both]), identifier: sequence([name, identifier])))
        XCTAssertTrue(try DicomQueryMatcher().matches(sequence([sequence([both])]), identifier: sequence([sequence([name])])) )
    }

    func test_combinedDateTime_negotiatedRangeIncludesIntermediateDays() throws {
        var candidate = data(.DA, "20060706", tag: 0x00080020)
        candidate.set(data(.TM, "020000", tag: 0x00080030).elements[0])
        var query = data(.DA, "20060705-20060707", tag: 0x00080020)
        query.set(data(.TM, "1000-1800", tag: 0x00080030).elements[0])
        XCTAssertFalse(try DicomQueryMatcher().matches(candidate, identifier: query))
        XCTAssertTrue(try DicomQueryMatcher(dateTimeMatching: true).matches(candidate, identifier: query))
    }
}
