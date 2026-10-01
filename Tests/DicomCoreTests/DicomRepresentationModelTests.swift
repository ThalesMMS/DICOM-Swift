import XCTest
@testable import DicomCore

// Synthetic identifiers and pixels only; shared by this lot's tests.
enum RepresentationFixture {
    static let uid = "2.25.2355"
    static func dataSet(history: Bool = false) -> DicomDataSet {
        var set = DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings([DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([uid])),
            .init(tag: DicomTag.studyInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23551"])),
            .init(tag: DicomTag.seriesInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.23552"])),
            .init(tag: DicomTag.imageType.rawValue, vr: .CS, value: .strings(["ORIGINAL", "PRIMARY"])),
            .init(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["SYNTHETIC^DO_NOT_LOG"])),
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.samplesPerPixel.rawValue, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.bitsStored.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.highBit.rawValue, vr: .US, value: .unsignedIntegers([7])),
            .init(tag: DicomTag.pixelRepresentation.rawValue, vr: .US, value: .unsignedIntegers([0])),
            .init(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["MONOCHROME2"])),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data((0..<64).map(UInt8.init))))
        ])
        if history {
            set.set(.init(tag: 0x00282110, vr: .CS, value: .strings(["01"])))
            set.set(.init(tag: 0x00282112, vr: .DS, value: .strings(["2"])))
            set.set(.init(tag: 0x00282114, vr: .CS, value: .strings(["ISO_10918_1"])))
        }
        return set
    }
    static func bytes(_ syntax: DicomTransferSyntax = .explicitVRLittleEndian, history: Bool = false) throws -> Data {
        try DicomDataSetWriter.part10Data(from: dataSet(history: history), options: .init(transferSyntax: syntax))
    }
    static func descriptor(_ bytes: Data, source: DicomArchiveRepresentation? = nil,
                           kind: DicomArchiveRepresentation.Kind = .original,
                           availability: DicomArchiveRepresentation.Availability = .stored("opaque")) throws
        -> DicomArchiveRepresentation {
        let request = try DicomStoreRequest(part10Data: bytes)
        let set = try DCMDecoder(data: bytes).dataSet
        let hash = DicomArchiveRepresentation.hash(bytes)
        return .init(kind: kind, sourceSOPInstanceUID: source?.sourceSOPInstanceUID ?? request.sopInstanceUID,
            representationSOPInstanceUID: request.sopInstanceUID, transferSyntax: request.transferSyntax,
            contentSHA256: hash, sourceContentSHA256: source?.contentSHA256 ?? hash,
            codec: .init(family: "dataset", identifier: "fixture", version: "1"), parameters: .init(),
            quality: DicomArchiveRepresentation.quality(set), geometry: .init(set),
            provenance: .init(createdAt: Date(timeIntervalSince1970: 0), creatorIdentifier: "fixture",
                sourceFingerprint: source?.contentSHA256 ?? hash, configurationHash: "config", toolkitVersion: "test"),
            availability: availability)
    }
    static func candidate(_ source: DicomArchiveRepresentation, syntax: DicomTransferSyntax,
                          kind: DicomArchiveRepresentation.Kind = .losslessEquivalent,
                          availability: DicomArchiveRepresentation.Availability = .stored("opaque-alternate"),
                          digest: String? = nil) -> DicomArchiveRepresentation {
        .init(kind: kind, sourceSOPInstanceUID: source.sourceSOPInstanceUID,
            representationSOPInstanceUID: kind == .lossyDerived ? "2.25.23559" : source.sourceSOPInstanceUID,
            transferSyntax: syntax, contentSHA256: digest ?? DicomArchiveRepresentation.hash(Data(syntax.rawValue.utf8)),
            sourceContentSHA256: source.contentSHA256, codec: source.codec,
            parameters: .init(intent: kind == .lossyDerived ? .irreversible(quality: 0.8) : .reversible),
            quality: kind == .lossyDerived ? .lossy(ratios: [2], methods: ["ISO_10918_1"]) : source.quality,
            geometry: source.geometry, provenance: source.provenance, availability: availability)
    }
    static func archive(history: Bool = false) async throws -> (DicomInMemoryRepresentationStore, DicomRepresentationSet, Data) {
        let bytes = try bytes(history: history)
        let store = DicomInMemoryRepresentationStore()
        let original = try await store.store(bytes: bytes, representation: descriptor(bytes), derivativeLimit: 10)
        return (store, try .init([original]), bytes)
    }
}

final class DicomRepresentationModelTests: XCTestCase {
    func test_multipleRepresentations_validateAndSort() throws {
        let original = try RepresentationFixture.descriptor(RepresentationFixture.bytes())
        let equivalent = RepresentationFixture.candidate(original, syntax: .rleLossless)
        let derived = RepresentationFixture.candidate(original, syntax: .jpegBaseline, kind: .lossyDerived)
        let set = try DicomRepresentationSet([derived, equivalent, original])
        XCTAssertEqual(set.representations.map(\.kind), [.original, .losslessEquivalent, .lossyDerived])
        XCTAssertThrowsError(try DicomRepresentationSet([equivalent]))
        XCTAssertThrowsError(try DicomRepresentationSet([original, original]))
        XCTAssertThrowsError(try DicomRepresentationSet([original,
            RepresentationFixture.candidate(original, syntax: .jpegBaseline)]))
    }

    func test_sameUIDDifferentBytes_retainsBothEncodings() throws {
        let bytes = try RepresentationFixture.bytes()
        let original = try RepresentationFixture.descriptor(bytes)
        let equivalent = try RepresentationFixture.descriptor(RepresentationFixture.bytes(.implicitVRLittleEndian),
                                                               source: original, kind: .losslessEquivalent)
        let set = try DicomRepresentationSet([equivalent, original])
        XCTAssertEqual(set.representations.count, 2)
        XCTAssertNotEqual(original.contentSHA256, equivalent.contentSHA256)
        XCTAssertEqual(original.representationSOPInstanceUID, equivalent.representationSOPInstanceUID)
    }
}
