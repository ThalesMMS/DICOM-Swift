import simd

/// Opt-in geometry checks in patient millimeters; no rasterization or topology certification.
public enum DicomRTContourGeometryValidator {
    public static func validate(
        _ structureSet: DicomRTStructureSet,
        tolerance: Double = 0.01,
        maximumPointsForIntersectionTest: Int = 4096,
        imagePlanes: [String: DicomRTImagePlane] = [:]
    ) -> DicomRTContourGeometryReport {
        var diagnostics: [DicomRTContourGeometryDiagnostic] = []
        var limitations: [DicomRTContourGeometryDiagnostic] = []
        guard tolerance.isFinite, tolerance >= 0, maximumPointsForIntersectionTest >= 0 else {
            return .init(diagnostics: [.init(roiNumber: 0, contourIndex: 0, code: .invalidValidationOptions)],
                         limitations: [])
        }
        for (roiNumber, contours) in structureSet.contoursByROINumber.sorted(by: { $0.key < $1.key }) {
            let roiFrame = structureSet.rois.first { $0.number == roiNumber }?.referencedFrameOfReferenceUID
            let allowedImages = Set(structureSet.referencedFramesOfReference.filter {
                $0.frameOfReferenceUID == roiFrame
            }.flatMap(\.studies).flatMap(\.series).flatMap(\.instances).compactMap(\.referencedSOPInstanceUID))
            let hasXOR = contours.contains { $0.knownGeometricType == .closedPlanarXOR }
            let planes = contours.map { plane($0.points) }
            for (index, contour) in contours.enumerated() {
                func finding(_ code: DicomRTContourGeometryDiagnostic.Code, _ value: Double? = nil)
                    -> DicomRTContourGeometryDiagnostic {
                    .init(roiNumber: roiNumber, contourIndex: index, code: code, measuredValue: value)
                }
                let points = contour.points
                guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
                    diagnostics.append(finding(.nonFinitePoint))
                    continue
                }
                let type = contour.knownGeometricType
                if type == nil { diagnostics.append(finding(.unknownGeometricType)) }
                let closed = type == .closedPlanar || type == .closedPlanarXOR
                let minimum = type == .point ? 1 : (closed ? 3 : 2)
                if type != nil && (points.count < minimum || (type == .point && points.count != 1)) {
                    diagnostics.append(finding(.invalidPointCount, Double(points.count)))
                }
                if zip(points, points.dropFirst()).contains(where: { $0 == $1 }) ||
                    (closed && points.count > 1 && points.first == points.last) {
                    diagnostics.append(finding(.consecutiveDuplicatePoints))
                }
                if hasXOR && type != .closedPlanarXOR { diagnostics.append(finding(.mixedXORROI)) }
                if let plane = planes[index], type != .openNonplanar && type != .point {
                    let maximum = maximumDistance(points, plane)
                    if maximum > tolerance { diagnostics.append(finding(.nonPlanarContour, maximum)) }
                    if closed, points.count <= maximumPointsForIntersectionTest,
                       maximum <= tolerance && intersects(points, normal: plane.normal) {
                        diagnostics.append(finding(.selfIntersection))
                    }
                } else if closed {
                    diagnostics.append(finding(.degenerateClosedContour))
                }
                if closed && points.count > maximumPointsForIntersectionTest {
                    limitations.append(finding(.intersectionTestPointLimit, Double(points.count)))
                }
                if type == .closedPlanarXOR {
                    let companion = contours.indices.contains { other in
                        guard other != index, let own = planes[index], let otherPlane = planes[other] else { return false }
                        return maximumDistance(contours[other].points, own) <= tolerance &&
                            maximumDistance(points, otherPlane) <= tolerance
                    }
                    if !companion { diagnostics.append(finding(.xorWithoutCoplanarCompanion)) }
                }
                for reference in contour.sourceImageReferences {
                    let uid = reference.referencedSOPInstanceUID
                    if !structureSet.referencedFramesOfReference.isEmpty &&
                        (uid == nil || !allowedImages.contains(uid!)) {
                        diagnostics.append(finding(.referencedImageOutsideFrameOfReference))
                    }
                    guard let uid, let image = imagePlanes[uid] else { continue }
                    let row = image.orientation.row, column = image.orientation.column
                    let normal = simd_cross(row, column)
                    guard image.rows > 0, image.columns > 0, image.spacing.x > 0, image.spacing.y > 0,
                          image.spacing.x.isFinite, image.spacing.y.isFinite,
                          abs(simd_length(row) - 1) < 1e-6, abs(simd_length(column) - 1) < 1e-6,
                          abs(simd_dot(row, column)) < 1e-6,
                          image.position.x.isFinite, image.position.y.isFinite, image.position.z.isFinite else {
                        diagnostics.append(finding(.invalidImagePlane))
                        continue
                    }
                    let distance = maximumDistance(points, (image.position, simd_normalize(normal)))
                    if distance > tolerance { diagnostics.append(finding(.imageOffPlane, distance)) }
                    // Pixel centers start at Image Position; the extent includes the outer half pixels.
                    let outside = points.contains { point in
                        let offset = point - image.position
                        let x = simd_dot(offset, row), y = simd_dot(offset, column)
                        return x < -image.spacing.y / 2 - tolerance || y < -image.spacing.x / 2 - tolerance ||
                            x > (Double(image.columns) - 0.5) * image.spacing.y + tolerance ||
                            y > (Double(image.rows) - 0.5) * image.spacing.x + tolerance
                    }
                    if outside { diagnostics.append(finding(.imageOutsideExtent)) }
                }
            }
        }
        return .init(diagnostics: diagnostics, limitations: limitations)
    }

    private static func plane(_ points: [SIMD3<Double>]) -> (origin: SIMD3<Double>, normal: SIMD3<Double>)? {
        guard let origin = points.first,
              let second = points.dropFirst().first(where: { simd_distance($0, origin) > 1e-12 }) else { return nil }
        let direction = simd_normalize(second - origin)
        for point in points.dropFirst() {
            let normal = simd_cross(direction, point - origin)
            if simd_length(normal) > 1e-12 { return (origin, simd_normalize(normal)) }
        }
        return nil
    }

    private static func maximumDistance(_ points: [SIMD3<Double>],
                                        _ plane: (origin: SIMD3<Double>, normal: SIMD3<Double>)) -> Double {
        points.map { abs(simd_dot($0 - plane.origin, plane.normal)) }.max() ?? 0
    }

    private static func intersects(_ points: [SIMD3<Double>], normal: SIMD3<Double>) -> Bool {
        let axis = abs(normal.x) > abs(normal.y) ? (abs(normal.x) > abs(normal.z) ? 0 : 2) :
            (abs(normal.y) > abs(normal.z) ? 1 : 2)
        let projected = points.map { point in
            axis == 0 ? SIMD2(point.y, point.z) : (axis == 1 ? SIMD2(point.x, point.z) : SIMD2(point.x, point.y))
        }
        func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
            let u = b - a, v = c - a
            return u.x * v.y - u.y * v.x
        }
        func onSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ p: SIMD2<Double>) -> Bool {
            abs(cross(a, b, p)) <= 1e-12 && p.x >= min(a.x, b.x) && p.x <= max(a.x, b.x) &&
                p.y >= min(a.y, b.y) && p.y <= max(a.y, b.y)
        }
        for first in projected.indices {
            let next = (first + 1) % projected.count
            for second in (first + 1)..<projected.count {
                let end = (second + 1) % projected.count
                if second == next || end == first { continue }
                let a = projected[first], b = projected[next], c = projected[second], d = projected[end]
                let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
                if (abC * abD < 0 && cdA * cdB < 0) || onSegment(a, b, c) || onSegment(a, b, d) ||
                    onSegment(c, d, a) || onSegment(c, d, b) { return true }
            }
        }
        return false
    }
}
