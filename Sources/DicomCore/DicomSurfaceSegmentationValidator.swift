/// Semantic checks for typed surface objects. Finite-volume and manifold claims are not topology certification.
public enum DicomSurfaceSegmentationValidator {
    public static func validate(_ segmentation: DicomSurfaceSegmentation) -> DicomSurfaceSegmentationReport {
        var diagnostics: [DicomSurfaceSegmentationDiagnostic] = []
        if segmentation.surfaces.isEmpty {
            diagnostics.append(.init(surfaceNumber: nil, segmentNumber: nil, code: .pointCount))
        }
        if segmentation.segments.isEmpty {
            diagnostics.append(.init(surfaceNumber: nil, segmentNumber: nil, code: .segmentSurfaceReference))
        }
        for (index, surface) in segmentation.surfaces.enumerated() {
            func record(_ code: DicomSurfaceSegmentationDiagnostic.Code) {
                diagnostics.append(.init(surfaceNumber: surface.number, segmentNumber: nil, code: code))
            }
            if surface.number != index + 1 { record(.surfaceNumber) }
            if surface.numberOfSurfacePoints != surface.points.count || surface.points.isEmpty { record(.pointCount) }
            if !surface.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) {
                record(.nonFiniteCoordinate)
            }
            if surface.vectors.count > 1 { record(.multipleVectorSets) }
            for vector in surface.vectors {
                if vector.dimensionality != 3 { record(.vectorDimensionality) }
                if vector.coordinates.count / 3 != surface.points.count || !vector.coordinates.count.isMultiple(of: 3) {
                    record(.normalsCount)
                }
                if !vector.coordinates.allSatisfy(\.isFinite) { record(.nonFiniteCoordinate) }
                if let accuracy = vector.accuracy, accuracy.count != 1 && accuracy.count != vector.dimensionality { record(.accuracyCount) }
            }
            if let accuracy = surface.pointCoordinatesAccuracy, accuracy.count != 3 { record(.accuracyCount) }
            if let box = surface.pointsBoundingBox, box.count != 6 { record(.boundingBoxCount) }
            if surface.primitives.isEmpty { record(.primitiveCount) }
            for primitive in surface.primitives {
                let indices: [UInt32]
                let validCount: Bool
                switch primitive {
                case .triangles(let values): indices = values; validCount = !values.isEmpty && values.count.isMultiple(of: 3)
                case .edges(let values): indices = values; validCount = !values.isEmpty && values.count.isMultiple(of: 2)
                case .line(let values): indices = values; validCount = values.count >= 2
                case .triangleStrip(let values), .triangleFan(let values), .facet(let values):
                    indices = values; validCount = values.count >= 3
                }
                if !validCount { record(.primitiveCount) }
                if indices.contains(where: { $0 == 0 || UInt64($0) > UInt64(surface.points.count) }) {
                    record(.indexOutOfBounds)
                }
            }
        }
        let numbers = Set(segmentation.surfaces.map(\.number))
        var seen = Set<Int>()
        for segment in segmentation.segments {
            if !seen.insert(segment.number).inserted {
                diagnostics.append(.init(surfaceNumber: nil, segmentNumber: segment.number, code: .duplicateSegmentNumber))
            }
            if segment.referencedSurfaceNumbers.isEmpty || !Set(segment.referencedSurfaceNumbers).isSubset(of: numbers) {
                diagnostics.append(.init(surfaceNumber: nil, segmentNumber: segment.number, code: .segmentSurfaceReference))
            }
        }
        return DicomSurfaceSegmentationReport(diagnostics: diagnostics)
    }
}
