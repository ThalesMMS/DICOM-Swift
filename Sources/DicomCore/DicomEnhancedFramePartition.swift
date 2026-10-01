import Foundation

/// A metadata-only partition. Frame indices still address the original object's pixel data.
/// Geometric eligibility is deliberately checked separately when constructing a volume.
public struct DicomEnhancedFramePartition: Equatable, Sendable {
    public struct Selection: Hashable, Sendable {
        public let axes: [DicomEnhancedDimensionIndex]
        /// Logical ordinals, not physical attribute values. Nil selects all spatial positions.
        public let ordinals: [Int?]
    }

    public let selection: Selection
    public let frameIndices: [Int]
    public let hasDuplicateCoordinates: Bool

    public enum ResolutionError: Error, Equatable, Sendable {
        case incompleteFrameGroups
        case missingDimensionOrganization
        case invalidDimensionDefinition(index: Int)
        case invalidFrameCoordinates(frame: Int)
    }

    public static func resolve(
        _ groups: DicomEnhancedMultiframeFunctionalGroups
    ) throws -> [Self] {
        guard groups.declaredFrameCount > 0,
              groups.perFrame.count == groups.declaredFrameCount else {
            throw ResolutionError.incompleteFrameGroups
        }
        guard let organization = groups.dimensionOrganization, !organization.indexes.isEmpty else {
            throw ResolutionError.missingDimensionOrganization
        }
        let axes = organization.indexes
        for (index, axis) in axes.enumerated() {
            guard let uid = axis.organizationUID, !uid.isEmpty,
                  organization.organizationUIDs.contains(uid),
                  let pointer = axis.dimensionIndexPointer, pointer > 0,
                  pointer != 0x0020_9111, pointer != 0x0020_9157,
                  !isPrivate(pointer) || hasValue(axis.dimensionIndexPrivateCreator),
                  !isPrivate(axis.functionalGroupPointer ?? 0) || hasValue(axis.functionalGroupPrivateCreator),
                  !axes.prefix(index).contains(where: {
                      $0.organizationUID == uid && $0.dimensionIndexPointer == pointer
                          && $0.functionalGroupPointer == axis.functionalGroupPointer
                          && $0.dimensionIndexPrivateCreator == axis.dimensionIndexPrivateCreator
                          && $0.functionalGroupPrivateCreator == axis.functionalGroupPrivateCreator
                  }) else {
                throw ResolutionError.invalidDimensionDefinition(index: index)
            }
        }

        var framesBySelection: [[Int?]: [Int]] = [:]
        var tuplesBySelection: [[Int?]: Set<[Int]>] = [:]
        var duplicates = Set<[Int?]>()
        for frame in groups.frames {
            guard let values = frame.functionalGroups.frameContent?.dimensionIndexValues,
                  values.count == axes.count, values.allSatisfy({ $0 > 0 }) else {
                throw ResolutionError.invalidFrameCoordinates(frame: frame.index)
            }
            let key = zip(axes, values).map { axis, value -> Int? in
                axis.role == .spatial ? nil : value
            }
            framesBySelection[key, default: []].append(frame.index)
            if !tuplesBySelection[key, default: []].insert(values).inserted {
                duplicates.insert(key)
            }
        }
        return framesBySelection.keys.sorted {
            $0.map { $0 ?? 0 }.lexicographicallyPrecedes($1.map { $0 ?? 0 })
        }.map { key in
            Self(
                selection: Selection(axes: axes, ordinals: key),
                frameIndices: framesBySelection[key] ?? [],
                hasDuplicateCoordinates: duplicates.contains(key)
            )
        }
    }

    private static func isPrivate(_ tag: Int) -> Bool { ((tag >> 16) & 1) == 1 }

    private static func hasValue(_ value: String?) -> Bool {
        !(value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
