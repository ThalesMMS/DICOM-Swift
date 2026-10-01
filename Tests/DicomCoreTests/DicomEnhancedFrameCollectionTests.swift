import XCTest
@testable import DicomCore

final class DicomEnhancedFrameCollectionTests: XCTestCase {
    func test_mixedConcatenationTotals_rejectsUnknownCompleteness() {
        let totalPairs: [[Int?]] = [[2, nil], [nil, 2]]
        for totals in totalPairs {
            let first = source(uid: "1", number: 1, offset: 0, total: totals[0], coordinates: [1, 2])
            let second = source(uid: "2", number: 2, offset: 2, total: totals[1], coordinates: [3, 4])
            for sources in [[first, second], [second, first]] {
                XCTAssertThrowsError(try DicomEnhancedFrameCollection(sources: sources)) {
                    XCTAssertEqual($0 as? DicomEnhancedFrameCollection.ResolutionError, .invalidConcatenation)
                }
            }
        }
    }

    func test_distinctCompleteConcatenations_rejectsCombinedVolume() throws {
        let first = source(uid: "1", number: 1, offset: 0, total: 1, coordinates: [1, 2])
        let second = source(uid: "2", number: 1, offset: 0, total: 1, coordinates: [3, 4],
                            concatenationUID: "1.2.10")
        XCTAssertEqual(try DicomEnhancedFrameCollection(sources: [first]).concatenations["1.2.8"], .complete)
        XCTAssertEqual(try DicomEnhancedFrameCollection(sources: [second]).concatenations["1.2.10"], .complete)
        for sources in [[first, second], [second, first]] {
            XCTAssertThrowsError(try DicomEnhancedFrameCollection(sources: sources)) {
                XCTAssertEqual($0 as? DicomEnhancedFrameCollection.ResolutionError, .invalidConcatenation)
            }
        }
    }

    func test_concatenationAndStandaloneObject_rejectsCombinedVolume() {
        let first = source(uid: "1", number: 1, offset: 0, total: 1, coordinates: [1, 2])
        let second = source(uid: "2", number: 1, offset: 0, coordinates: [3, 4], concatenationUID: nil)
        for sources in [[first, second], [second, first]] {
            XCTAssertThrowsError(try DicomEnhancedFrameCollection(sources: sources)) {
                XCTAssertEqual($0 as? DicomEnhancedFrameCollection.ResolutionError, .invalidConcatenation)
            }
        }
    }

    func test_objectsWithoutFrameOfReference_doNotAssumeACommonCoordinateSystem() {
        XCTAssertThrowsError(try DicomEnhancedFrameCollection(sources: [
            source(uid: "1", number: 1, offset: 0, frameOfReferenceUID: nil),
            source(uid: "2", number: 2, offset: 2, frameOfReferenceUID: nil)
        ])) {
            XCTAssertEqual($0 as? DicomEnhancedFrameCollection.ResolutionError, .incompatibleObjects)
        }
    }

    func test_reversedObjects_usesConcatenationOffsetsAndRetainsLocalReferences() throws {
        let first = source(uid: "9", number: 1, offset: 0, coordinates: [1, 2])
        let second = source(uid: "1", number: 2, offset: 2, coordinates: [3, 4])
        let collection = try DicomEnhancedFrameCollection(sources: [second, first])
        let partition = try XCTUnwrap(collection.partitions.first)
        XCTAssertEqual(collection.concatenations["1.2.8"], .complete)
        XCTAssertEqual(partition.frames.map(\.sopInstanceUID), ["9", "9", "1", "1"])
        XCTAssertEqual(partition.frames.map(\.frameIndex), [0, 1, 0, 1])
        XCTAssertEqual(partition.frames.map(\.concatenationFrameIndex), [0, 1, 2, 3])
        XCTAssertFalse(partition.hasDuplicateCoordinates)
    }

    func test_missingObjectOrUnspecifiedTotal_doesNotClaimComplete() throws {
        let missing = try DicomEnhancedFrameCollection(sources: [source(uid: "1", number: 2, offset: 2)])
        XCTAssertEqual(missing.concatenations["1.2.8"], .incomplete)
        let unknown = try DicomEnhancedFrameCollection(sources: [source(uid: "1", number: 1, offset: 0, total: nil)])
        XCTAssertEqual(unknown.concatenations["1.2.8"], .unknown)
        let allUnknown = try DicomEnhancedFrameCollection(sources: [
            source(uid: "1", number: 1, offset: 0, total: nil, coordinates: [1, 2]),
            source(uid: "2", number: 2, offset: 2, total: nil, coordinates: [3, 4])
        ])
        XCTAssertEqual(allUnknown.concatenations["1.2.8"], .unknown)
    }

    func test_overlappingOffsets_rejectsAmbiguousConcatenation() {
        XCTAssertThrowsError(try DicomEnhancedFrameCollection(sources: [
            source(uid: "1", number: 1, offset: 0), source(uid: "2", number: 2, offset: 1)
        ])) {
            XCTAssertEqual($0 as? DicomEnhancedFrameCollection.ResolutionError, .overlappingConcatenationFrames)
        }
    }

    func test_duplicateSOPIdentity_rejectsDuplicateObject() {
        let object = source(uid: "1", number: 1, offset: 0)
        XCTAssertThrowsError(try DicomEnhancedFrameCollection(sources: [object, object])) {
            XCTAssertEqual($0 as? DicomEnhancedFrameCollection.ResolutionError, .duplicateObjectIdentity)
        }
    }

    func test_repeatedCoordinatesAcrossObjects_preservesBothAndReportsAmbiguity() throws {
        let collection = try DicomEnhancedFrameCollection(sources: [
            source(uid: "1", number: 1, offset: 0), source(uid: "2", number: 2, offset: 2)
        ])
        XCTAssertEqual(collection.partitions.first?.frames.count, 4)
        XCTAssertEqual(collection.partitions.first?.hasDuplicateCoordinates, true)
    }

    private func source(
        uid: String, number: Int, offset: Int, total: Int? = 2, coordinates: [Int] = [1, 2],
        frameOfReferenceUID: String? = "1.2.6", concatenationUID: String? = "1.2.8"
    ) -> DicomEnhancedFrameSource {
        .init(
            sopClassUID: "1.2.840.10008.5.1.4.1.1.2.1", sopInstanceUID: uid,
            seriesInstanceUID: "1.2.5", frameOfReferenceUID: frameOfReferenceUID,
            concatenation: concatenationUID.map {
                .init(uid: $0, sourceSOPInstanceUID: "1.2.9", number: number,
                      totalNumber: total, frameOffset: offset)
            },
            groups: .init(
                shared: nil,
                perFrame: coordinates.map {
                    .init(frameContent: .init(
                        dimensionIndexValues: [$0], stackID: "A", inStackPositionNumber: $0,
                        temporalPositionIndex: nil, frameAcquisitionNumber: nil
                    ))
                },
                declaredFrameCount: coordinates.count,
                dimensionOrganization: .init(organizationUIDs: ["1.2.7"], indexes: [
                    .init(organizationUID: "1.2.7", dimensionIndexPointer: 0x0020_9057, functionalGroupPointer: 0x0020_9111)
                ])
            )
        )
    }
}
