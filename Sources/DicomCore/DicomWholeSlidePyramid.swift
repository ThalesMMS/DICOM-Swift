import Foundation

/// Pure aggregation of instance metadata. Each concatenation member retains its source identity.
public struct DicomWholeSlidePyramid: Sendable, Equatable {
    public struct Level: Sendable, Equatable {
        public let metadata: DicomWholeSlideMicroscopyMetadata
        public let scaleFactorFromBase: Double
        public var sopInstanceUID: String { metadata.sopInstanceUID }
        public var sopClassUID: String { metadata.sopClassUID }
        public var seriesUID: String { metadata.seriesUID }
        public var concatenation: DicomWholeSlideConcatenation? { metadata.concatenation }
    }

    public let pyramidUID: String?
    public let levels: [Level]
    public let auxiliaryImages: [DicomWholeSlideMicroscopyMetadata]
    public let diagnostics: [DicomWholeSlideDiagnostic]

    /// Auxiliary-only groups preserve images that cannot safely be associated with a volume pyramid.
    public static func group(_ instances: [DicomWholeSlideMicroscopyMetadata]) -> [Self] {
        let sorted = instances.sorted(by: precedes)
        var groups: [[DicomWholeSlideMicroscopyMetadata]] = []
        for instance in sorted where instance.imageType.flavor == .volume {
            if let index = groups.firstIndex(where: { samePyramid($0[0], instance) }) {
                groups[index].append(instance)
            } else {
                groups.append([instance])
            }
        }
        var auxiliary = Array(repeating: [DicomWholeSlideMicroscopyMetadata](), count: groups.count)
        var unmatched: [DicomWholeSlideMicroscopyMetadata] = []
        for instance in sorted where instance.imageType.flavor != .volume {
            let matches = groups.indices.filter { index in
                let base = groups[index][0]
                if let uid = nonempty(instance.pyramidUID) { return uid == nonempty(base.pyramidUID) }
                // LABEL and OVERVIEW need not share a Frame of Reference or physical extent.
                return !base.seriesUID.isEmpty && base.seriesUID == instance.seriesUID &&
                    nonempty(base.containerIdentifier) != nil && base.containerIdentifier == instance.containerIdentifier
            }
            if matches.count == 1 { auxiliary[matches[0]].append(instance) } else { unmatched.append(instance) }
        }
        var result = groups.indices.map { build(groups[$0], auxiliary: auxiliary[$0]) }
        if !unmatched.isEmpty {
            result.append(.init(pyramidUID: nil, levels: [], auxiliaryImages: unmatched, diagnostics: []))
        }
        return result
    }

    private static func build(_ instances: [DicomWholeSlideMicroscopyMetadata], auxiliary: [DicomWholeSlideMicroscopyMetadata]) -> Self {
        let base = instances[0]
        var levels: [Level] = []
        var diagnostics: [DicomWholeSlideDiagnostic] = []
        for (index, instance) in instances.enumerated() {
            guard pathIDs(instance) == pathIDs(base), focalPlanesMatch(instance, base) else {
                diagnostics.append(.init(code: .pyramidLevelMismatch, levelIndex: index))
                continue
            }
            guard let bx = base.pixelSpacingXMillimeters, let by = base.pixelSpacingYMillimeters,
                  let x = instance.pixelSpacingXMillimeters, let y = instance.pixelSpacingYMillimeters,
                  [bx, by, x, y].allSatisfy({ $0.isFinite && $0 > 0 }),
                  instance.matrixWidth > 0, instance.matrixHeight > 0 else {
                diagnostics.append(.init(code: .pyramidGeometryMissing, levelIndex: index))
                continue
            }
            let scale = x / bx
            let sy = y / by
            let mx = Double(base.matrixWidth) / Double(instance.matrixWidth)
            let my = Double(base.matrixHeight) / Double(instance.matrixHeight)
            if abs(scale / sy - 1) > 0.01 || abs(scale / mx - 1) > 0.01 || abs(sy / my - 1) > 0.01 {
                diagnostics.append(.init(code: .pyramidScaleMismatch, levelIndex: index))
            }
            levels.append(.init(metadata: instance, scaleFactorFromBase: scale))
        }
        return .init(pyramidUID: base.pyramidUID, levels: levels, auxiliaryImages: auxiliary, diagnostics: diagnostics)
    }

    private static func focalPlanesMatch(_ a: DicomWholeSlideMicroscopyMetadata, _ b: DicomWholeSlideMicroscopyMetadata) -> Bool {
        let ac = a.totalPixelMatrixFocalPlanes ?? a.focalPlaneOffsetsMillimeters.count
        let bc = b.totalPixelMatrixFocalPlanes ?? b.focalPlaneOffsetsMillimeters.count
        return ac == bc && a.focalPlaneOffsetsMillimeters.count == b.focalPlaneOffsetsMillimeters.count &&
            zip(a.focalPlaneOffsetsMillimeters, b.focalPlaneOffsetsMillimeters).allSatisfy { abs($0 - $1) <= 1e-6 }
    }

    private static func samePyramid(_ a: DicomWholeSlideMicroscopyMetadata, _ b: DicomWholeSlideMicroscopyMetadata) -> Bool {
        if let uid = nonempty(a.pyramidUID) { return uid == nonempty(b.pyramidUID) }
        guard nonempty(b.pyramidUID) == nil,
              let frame = nonempty(a.frameOfReferenceUID), frame == nonempty(b.frameOfReferenceUID),
              let container = nonempty(a.containerIdentifier), container == nonempty(b.containerIdentifier),
              pathIDs(a) == pathIDs(b), let av = a.imagedVolume, let bv = b.imagedVolume,
              let ao = a.totalPixelMatrixOrigin, let bo = b.totalPixelMatrixOrigin else { return false }
        return zip([av.widthMillimeters, av.heightMillimeters, av.depthMicrometers,
                    ao.xMillimeters, ao.yMillimeters, ao.zMicrometers],
                   [bv.widthMillimeters, bv.heightMillimeters, bv.depthMicrometers,
                    bo.xMillimeters, bo.yMillimeters, bo.zMicrometers]).allSatisfy { abs($0 - $1) <= 1e-6 }
    }

    private static func pathIDs(_ instance: DicomWholeSlideMicroscopyMetadata) -> Set<String> {
        Set(instance.opticalPaths.map(\.identifier))
    }

    private static func nonempty(_ value: String?) -> String? { value?.isEmpty == false ? value : nil }

    private static func precedes(_ a: DicomWholeSlideMicroscopyMetadata, _ b: DicomWholeSlideMicroscopyMetadata) -> Bool {
        let ax = a.pixelSpacingXMillimeters.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? .infinity
        let bx = b.pixelSpacingXMillimeters.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? .infinity
        if ax != bx { return ax < bx }
        let ay = a.pixelSpacingYMillimeters ?? .infinity
        let by = b.pixelSpacingYMillimeters ?? .infinity
        if ay != by { return ay < by }
        if a.sopInstanceUID != b.sopInstanceUID { return a.sopInstanceUID < b.sopInstanceUID }
        return (a.concatenation?.frameOffsetNumber ?? 0) < (b.concatenation?.frameOffsetNumber ?? 0)
    }
}
