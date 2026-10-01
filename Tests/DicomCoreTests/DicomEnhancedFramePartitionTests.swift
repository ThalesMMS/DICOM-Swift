import XCTest
@testable import DicomCore

final class DicomEnhancedFramePartitionTests: XCTestCase {
    func test_shuffledStacksTimesAndEchoes_preservesOriginalFrameIndices() throws {
        let coordinates = [
            [2, 9, 2, 1], [1, 7, 1, 2], [2, 7, 2, 1],
            [1, 9, 1, 2], [1, 7, 1, 1], [1, 9, 1, 1]
        ]
        let partitions = try DicomEnhancedFramePartition.resolve(groups(coordinates))
        XCTAssertEqual(partitions.map(\.frameIndices), [[4, 5], [1, 3], [0, 2]])
        XCTAssertEqual(partitions.map(\.selection.ordinals), [
            [1, nil, 1, 1], [1, nil, 1, 2], [2, nil, 2, 1]
        ])
        XCTAssertEqual(partitions.first?.selection.axes.map(\.role), [.stack, .spatial, .time, .echo])
        XCTAssertEqual(Set(partitions.map(\.selection)).count, 3)
        XCTAssertTrue(partitions.allSatisfy { !$0.hasDuplicateCoordinates })
    }

    func test_repeatedCoordinates_preservesFramesAndReportsAmbiguity() throws {
        let partitions = try DicomEnhancedFramePartition.resolve(groups([[1, 1, 1, 1], [1, 1, 1, 1]]))
        XCTAssertEqual(partitions.first?.frameIndices, [0, 1])
        XCTAssertEqual(partitions.first?.hasDuplicateCoordinates, true)
    }

    func test_cardiacAndRespiratoryPhases_remainIndependentOfSpatialPosition() throws {
        let axes = [axis(0x0020_9057), axis(0x0020_9241, group: 0x0018_9118),
                    axis(0x0020_9245, group: 0x0020_9253)]
        let partitions = try DicomEnhancedFramePartition.resolve(groups(
            [[2, 1, 2], [1, 2, 1], [1, 1, 2], [2, 2, 1]], axes: axes
        ))
        XCTAssertEqual(partitions.map(\.frameIndices), [[0, 2], [1, 3]])
        XCTAssertEqual(partitions.map(\.selection.ordinals), [[nil, 1, 2], [nil, 2, 1]])
        XCTAssertEqual(partitions.first?.selection.axes.map(\.role), [.spatial, .cardiacPhase, .respiratoryPhase])
    }

    func test_missingPerFrameItem_isNotHiddenBySharedResolution() {
        let source = groups([[1, 1, 1, 1]])
        let incomplete = DicomEnhancedMultiframeFunctionalGroups(
            shared: source.perFrame.first, perFrame: source.perFrame, declaredFrameCount: 2,
            dimensionOrganization: source.dimensionOrganization
        )
        XCTAssertEqual(incomplete.frameCount, 2)
        XCTAssertThrowsError(try DicomEnhancedFramePartition.resolve(incomplete)) {
            XCTAssertEqual($0 as? DicomEnhancedFramePartition.ResolutionError, .incompleteFrameGroups)
        }
    }

    func test_invalidCoordinateMultiplicityOrOrdinal_rejectsPartition() {
        for values in [[1, 1], [1, 1, 0, 1], [1, -1, 1, 1]] {
            XCTAssertThrowsError(try DicomEnhancedFramePartition.resolve(groups([values]))) {
                XCTAssertEqual($0 as? DicomEnhancedFramePartition.ResolutionError, .invalidFrameCoordinates(frame: 0))
            }
        }
    }

    func test_privateAxis_requiresCreatorAndRemainsInSelection() throws {
        let missingCreator = axis(0x0019_1010, group: 0x0018_9114)
        XCTAssertThrowsError(try DicomEnhancedFramePartition.resolve(groups([[1], [2]], axes: [missingCreator])))
        let privateAxis = DicomEnhancedDimensionIndex(
            organizationUID: "1.2.3", dimensionIndexPointer: 0x0019_1010,
            functionalGroupPointer: 0x0018_9114, dimensionIndexPrivateCreator: "TEST",
            descriptionLabel: "Parameter"
        )
        let partitions = try DicomEnhancedFramePartition.resolve(groups([[1], [2]], axes: [privateAxis]))
        XCTAssertEqual(partitions.map(\.frameIndices), [[0], [1]])
        XCTAssertEqual(partitions.first?.selection.axes.first?.role, .declared)
        XCTAssertEqual(partitions.first?.selection.axes.first?.dimensionIndexPrivateCreator, "TEST")
    }

    func test_multipleOrganizations_preservesAxisScope() throws {
        let other = DicomEnhancedDimensionIndex(
            organizationUID: "1.2.4", dimensionIndexPointer: 0x0018_9082, functionalGroupPointer: 0x0018_9114
        )
        let source = groups([[3, 1], [4, 1]], axes: [axis(0x0020_9057), other])
        let groups = DicomEnhancedMultiframeFunctionalGroups(
            shared: nil, perFrame: source.perFrame, declaredFrameCount: 2,
            dimensionOrganization: .init(organizationUIDs: ["1.2.3", "1.2.4"], indexes: [axis(0x0020_9057), other])
        )
        let partitions = try DicomEnhancedFramePartition.resolve(groups)
        XCTAssertEqual(partitions.first?.frameIndices, [0, 1])
        XCTAssertEqual(partitions.first?.selection.axes.map(\.organizationUID), ["1.2.3", "1.2.4"])
    }

    private func axis(_ pointer: Int, group: Int = 0x0020_9111) -> DicomEnhancedDimensionIndex {
        .init(organizationUID: "1.2.3", dimensionIndexPointer: pointer, functionalGroupPointer: group)
    }

    private func groups(
        _ coordinates: [[Int]], axes: [DicomEnhancedDimensionIndex]? = nil
    ) -> DicomEnhancedMultiframeFunctionalGroups {
        .init(
            shared: nil,
            perFrame: coordinates.map { values in
                .init(frameContent: .init(
                    dimensionIndexValues: values, stackID: "Stack",
                    inStackPositionNumber: 100, temporalPositionIndex: nil, frameAcquisitionNumber: nil
                ))
            },
            declaredFrameCount: coordinates.count,
            dimensionOrganization: .init(
                organizationUIDs: ["1.2.3"],
                indexes: axes ?? [axis(0x0020_9056), axis(0x0020_9057), axis(0x0020_9128),
                                  axis(0x0018_9082, group: 0x0018_9114)]
            )
        )
    }
}
