import Foundation

/// Resolves partitions across explicitly supplied objects from the same series.
/// Selection describes dimensions; Reference describes provenance. Neither is a filename.
public struct DicomEnhancedFrameCollection: Equatable, Sendable {
    public struct Reference: Hashable, Sendable {
        public let sopClassUID: String
        public let sopInstanceUID: String
        public let frameIndex: Int
        public let concatenationUID: String?
        public let concatenationFrameIndex: Int?
    }

    public struct Partition: Equatable, Sendable {
        public let selection: DicomEnhancedFramePartition.Selection
        public let frames: [Reference]
        public let hasDuplicateCoordinates: Bool
    }

    public enum Completeness: String, Equatable, Sendable {
        case complete, incomplete, unknown
    }

    public enum ResolutionError: Error, Equatable, Sendable {
        case incompatibleObjects
        case duplicateObjectIdentity
        case invalidConcatenation
        case overlappingConcatenationFrames
    }

    public let partitions: [Partition]
    public let concatenations: [String: Completeness]

    public init(sources: [DicomEnhancedFrameSource]) throws {
        guard let first = sources.first, !first.sopClassUID.isEmpty, !first.seriesInstanceUID.isEmpty,
              sources.count == 1 || !(first.frameOfReferenceUID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
              sources.allSatisfy({
                  !$0.sopInstanceUID.isEmpty && $0.sopClassUID == first.sopClassUID
                      && $0.seriesInstanceUID == first.seriesInstanceUID
                      && $0.frameOfReferenceUID == first.frameOfReferenceUID
                      && $0.groups.dimensionOrganization == first.groups.dimensionOrganization
              }) else { throw ResolutionError.incompatibleObjects }
        guard Set(sources.map(\.sopInstanceUID)).count == sources.count else {
            throw ResolutionError.duplicateObjectIdentity
        }
        concatenations = try Self.validateConcatenations(sources)
        var references: [DicomEnhancedFramePartition.Selection: [Reference]] = [:]
        var tuples: [DicomEnhancedFramePartition.Selection: Set<[Int]>] = [:]
        var duplicates = Set<DicomEnhancedFramePartition.Selection>()
        for source in sources {
            for partition in try DicomEnhancedFramePartition.resolve(source.groups) {
                for index in partition.frameIndices {
                    let values = source.groups.frames[index].functionalGroups.frameContent?.dimensionIndexValues ?? []
                    if !tuples[partition.selection, default: []].insert(values).inserted {
                        duplicates.insert(partition.selection)
                    }
                    references[partition.selection, default: []].append(Reference(
                        sopClassUID: source.sopClassUID, sopInstanceUID: source.sopInstanceUID, frameIndex: index,
                        concatenationUID: source.concatenation?.uid,
                        concatenationFrameIndex: source.concatenation?.frameOffset.map { $0 + index }
                    ))
                }
            }
        }
        partitions = references.keys.sorted {
            $0.ordinals.map { $0 ?? 0 }.lexicographicallyPrecedes($1.ordinals.map { $0 ?? 0 })
        }.map { selection in
            Partition(
                selection: selection,
                frames: (references[selection] ?? []).sorted {
                    if $0.concatenationUID != $1.concatenationUID {
                        return ($0.concatenationUID ?? "") < ($1.concatenationUID ?? "")
                    }
                    if $0.concatenationUID == $1.concatenationUID,
                       let left = $0.concatenationFrameIndex, let right = $1.concatenationFrameIndex {
                        return left < right
                    }
                    if $0.sopInstanceUID != $1.sopInstanceUID { return $0.sopInstanceUID < $1.sopInstanceUID }
                    return $0.frameIndex < $1.frameIndex
                },
                hasDuplicateCoordinates: duplicates.contains(selection)
            )
        }
    }

    private static func validateConcatenations(
        _ sources: [DicomEnhancedFrameSource]
    ) throws -> [String: Completeness] {
        guard Set(sources.map { $0.concatenation?.uid }).count <= 1 else {
            throw ResolutionError.invalidConcatenation
        }
        let grouped = Dictionary(grouping: sources.filter { $0.concatenation != nil }) { $0.concatenation?.uid ?? "" }
        var results: [String: Completeness] = [:]
        for (uid, objects) in grouped {
            guard !uid.isEmpty,
                  objects.allSatisfy({
                      guard let metadata = $0.concatenation else { return false }
                      return !(metadata.sourceSOPInstanceUID?.isEmpty ?? true)
                          && (1...65_535).contains(metadata.number ?? 0) && (metadata.frameOffset ?? -1) >= 0
                          && (metadata.totalNumber == nil || (metadata.totalNumber ?? 0) > 0)
                  }),
                  Set(objects.map { $0.concatenation?.sourceSOPInstanceUID }).count == 1,
                  Set(objects.map { $0.concatenation?.totalNumber }).count <= 1,
                  Set(objects.compactMap { $0.concatenation?.number }).count == objects.count else {
                throw ResolutionError.invalidConcatenation
            }
            let ordered = objects.sorted { ($0.concatenation?.frameOffset ?? 0) < ($1.concatenation?.frameOffset ?? 0) }
            var expectedOffset = 0
            var expectedNumber = 1
            var missing = false
            for object in ordered {
                let offset = object.concatenation?.frameOffset ?? 0
                let number = object.concatenation?.number ?? 0
                guard offset >= expectedOffset else { throw ResolutionError.overlappingConcatenationFrames }
                guard number >= expectedNumber else { throw ResolutionError.invalidConcatenation }
                missing = missing || offset != expectedOffset || number != expectedNumber
                let (nextOffset, overflow) = offset.addingReportingOverflow(object.groups.declaredFrameCount)
                guard !overflow, object.groups.declaredFrameCount > 0 else {
                    throw ResolutionError.invalidConcatenation
                }
                expectedOffset = nextOffset
                expectedNumber = number + 1
            }
            if let total = objects.compactMap({ $0.concatenation?.totalNumber }).first {
                guard expectedNumber - 1 <= total else { throw ResolutionError.invalidConcatenation }
                results[uid] = !missing && objects.count == total ? .complete : .incomplete
            } else {
                results[uid] = missing ? .incomplete : .unknown
            }
        }
        return results
    }
}
