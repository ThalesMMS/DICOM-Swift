import XCTest
@testable import DicomCore

final class DicomRoutingSubjectTests: XCTestCase {
    func test_syntheticDataSet_extractsMetadataAndKeepsHostEvidenceSeparate() throws {
        var set = RepresentationFixture.dataSet()
        let fields: [(Int, DicomVR, String)] = [
            (DicomTag.modality.rawValue, .CS, "CT"),
            (DicomTag.institutionName.rawValue, .LO, "Hospital"),
            (DicomTag.studyDescription.rawValue, .LO, "Chest CT"),
            (DicomTag.bodyPartExamined.rawValue, .CS, "CHEST"),
            (0x00081010, .SH, "SCANNER"),
            (0x00080054, .AE, "CONTENT_AE"),
            (0x00081190, .UR, "https://untrusted.example/retrieve")
        ]
        for (tag, vr, value) in fields { set.set(.init(tag: tag, vr: vr, value: .strings([value]))) }
        let bytes = try DicomDataSetWriter.part10Data(from: set,
            options: .init(transferSyntax: .explicitVRLittleEndian))
        let parsed = try DCMDecoder(data: bytes).dataSet
        let subject = DicomRoutingSubject.subject(from: parsed,
            transferSyntaxUID: DicomTransferSyntax.explicitVRLittleEndian.rawValue,
            callingAETitle: "HOST_CALLER", calledAETitle: "HOST_RECEIVER", priority: .stat, phiAuthorized: true)
        XCTAssertEqual(subject.sopInstanceUID, RepresentationFixture.uid)
        XCTAssertEqual(subject.sopClassUID, set.string(for: .sopClassUID))
        XCTAssertEqual(subject.studyInstanceUID, "2.25.23551")
        XCTAssertEqual(subject.seriesInstanceUID, "2.25.23552")
        XCTAssertEqual(subject.modality, "CT")
        XCTAssertEqual(subject.institutionName, "Hospital")
        XCTAssertEqual(subject.studyDescription, "Chest CT")
        XCTAssertEqual(subject.bodyPartExamined, "CHEST")
        XCTAssertEqual(subject.stationName, "SCANNER")
        XCTAssertEqual(subject.callingAETitle, "HOST_CALLER")
        XCTAssertEqual(subject.calledAETitle, "HOST_RECEIVER")
        XCTAssertEqual(subject.priority, .stat)
        XCTAssertTrue(subject.phiAuthorized)
        XCTAssertFalse(subject.isDerived)
        XCTAssertEqual(subject.transferSyntaxUID, DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        XCTAssertEqual(subject.contentReferences, ["CONTENT_AE", "https://untrusted.example/retrieve"])
    }

    func test_lossyHistoryOrDerivedImageType_marksDerived() {
        var derived = RepresentationFixture.dataSet()
        derived.set(.init(tag: DicomTag.imageType.rawValue, vr: .CS, value: .strings(["DERIVED", "PRIMARY"])))
        for set in [derived, RepresentationFixture.dataSet(history: true)] {
            XCTAssertTrue(DicomRoutingSubject.subject(from: set, transferSyntaxUID: "syntax").isDerived)
        }
        XCTAssertFalse(DicomRoutingSubject.subject(from: RepresentationFixture.dataSet(),
                                                   transferSyntaxUID: "syntax").isDerived)
    }

    func test_missingMetadata_doesNotInventAssociationOrAuthorization() {
        let subject = DicomRoutingSubject.subject(from: .init(), transferSyntaxUID: "syntax")
        XCTAssertEqual(subject.sopInstanceUID, "")
        XCTAssertNil(subject.modality)
        XCTAssertNil(subject.callingAETitle)
        XCTAssertNil(subject.calledAETitle)
        XCTAssertFalse(subject.phiAuthorized)
        XCTAssertEqual(subject.priority, .routine)
        XCTAssertTrue(subject.contentReferences.isEmpty)
        for criterion: DicomRoutingCriterion in [.modality(in: ["CT"]), .institutionName(matches: "Hospital"),
                                                .studyDescription(contains: "CT"), .callingAETitle(in: ["AE"])] {
            XCTAssertFalse(criterion.matches(subject))
        }
    }
}
