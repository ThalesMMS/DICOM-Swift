import XCTest
@testable import DicomCore

final class DicomRepresentationSelectorTests: XCTestCase {
    func test_incompatiblePeer_neverFallsBackToOriginal() throws {
        let original = try RepresentationFixture.descriptor(RepresentationFixture.bytes())
        XCTAssertThrowsError(try DicomRepresentationSelector.select(set: .init([original]),
            peer: .init(acceptedTransferSyntaxes: [.jpegBaseline]), policy: .losslessEquivalents))
    }

    func test_rejectedOriginal_selectsStoredEquivalentBeforeGeneration() throws {
        let original = try RepresentationFixture.descriptor(RepresentationFixture.bytes())
        let stored = RepresentationFixture.candidate(original, syntax: .rleLossless)
        let generated = RepresentationFixture.candidate(original, syntax: .jpegLSLossless, availability: .generatable)
        let result = try DicomRepresentationSelector.select(set: .init([original, stored, generated]),
            peer: .init(acceptedTransferSyntaxes: [.jpegLSLossless, .rleLossless]), policy: .losslessEquivalents,
            cost: .init(generationAllowed: true, estimate: { _ in .init(codecAvailable: true) }))
        XCTAssertEqual(result.chosenRepresentation.transferSyntax, .rleLossless)
        XCTAssertEqual(result.reasonCodes, [.storedEquivalent])
        XCTAssertFalse(String(describing: result).contains("SYNTHETIC"))
        XCTAssertFalse(String(describing: result).contains("opaque"))
    }

    func test_lossy_requiresNonemptyAuthorization() throws {
        let original = try RepresentationFixture.descriptor(RepresentationFixture.bytes())
        let derived = RepresentationFixture.candidate(original, syntax: .jpegBaseline, kind: .lossyDerived)
        let set = try DicomRepresentationSet([original, derived])
        for policy: DicomRepresentationLossPolicy in [.originalOnly, .losslessEquivalents, .lossyDerivedAllowed(authorization: " ")] {
            XCTAssertThrowsError(try DicomRepresentationSelector.select(set: set,
                peer: .init(acceptedTransferSyntaxes: [.jpegBaseline]), policy: policy))
        }
        let result = try DicomRepresentationSelector.select(set: set,
            peer: .init(acceptedTransferSyntaxes: [.jpegBaseline]), policy: .lossyDerivedAllowed(authorization: "approved-token"))
        XCTAssertEqual(result.reasonCodes, [.authorizedStoredDerivative])
        XCTAssertFalse(String(describing: result).contains("approved-token"))
        XCTAssertThrowsError(try DicomRepresentationSelector.select(set: set,
            peer: .init(acceptedTransferSyntaxes: [.jpegBaseline], acceptsLossy: false),
            policy: .lossyDerivedAllowed(authorization: "approved")))
    }

    func test_ties_allSetAndPeerPermutations_areIdentical() throws {
        let original = try RepresentationFixture.descriptor(RepresentationFixture.bytes())
        let a = RepresentationFixture.candidate(original, syntax: .rleLossless)
        let b = RepresentationFixture.candidate(original, syntax: .jpegLSLossless)
        let c = RepresentationFixture.candidate(original, syntax: .jpegLSLossless,
                                                digest: String(repeating: "0", count: 64))
        func permutations<T>(_ values: [T]) -> [[T]] {
            if values.isEmpty { return [[]] }
            return values.indices.flatMap { index in
                var rest = values; let first = rest.remove(at: index)
                return permutations(rest).map { [first] + $0 }
            }
        }
        var baseline: DicomRepresentationDecision?
        for items in permutations([original, a, b, c]) {
            for peer in [[a.transferSyntax, b.transferSyntax], [b.transferSyntax, a.transferSyntax]] {
                let result = try DicomRepresentationSelector.select(set: .init(items),
                    peer: .init(acceptedTransferSyntaxes: peer), policy: .losslessEquivalents)
                if let baseline { XCTAssertEqual(result, baseline) } else { baseline = result }
                XCTAssertEqual(result.chosenRepresentation.contentSHA256, c.contentSHA256)
            }
        }
    }

    func test_missingCodecAndStale_refuseWithTypedReasons() throws {
        let original = try RepresentationFixture.descriptor(RepresentationFixture.bytes())
        for availability: DicomArchiveRepresentation.Availability in [.generatable, .unavailable(.stale)] {
            let item = RepresentationFixture.candidate(original, syntax: .rleLossless, availability: availability)
            XCTAssertThrowsError(try DicomRepresentationSelector.select(set: .init([original, item]),
                peer: .init(acceptedTransferSyntaxes: [.rleLossless]), policy: .losslessEquivalents,
                cost: .init(generationAllowed: true))) { error in
                guard case DicomRepresentationRefusal.noEligibleRepresentation(let rejected) = error else {
                    return XCTFail("Expected typed refusal")
                }
                XCTAssertTrue(rejected.flatMap(\.reasonCodes).contains(availability == .generatable ? .codecUnavailable : .stale))
            }
        }
    }
}
