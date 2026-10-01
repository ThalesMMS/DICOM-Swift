//
//  DicomSOPClassGeometry.swift
//  DicomCore
//
//  Volume geometry of classic image objects whose spacing and position rules
//  depend on their SOP Class (issue #2813): Secondary Capture, Nuclear
//  Medicine and Ultrasound.
//

import Foundation
import simd

/// Where the voxel spacing, origin and axes of a classic (non-Enhanced) image object come from, by SOP Class
/// (issue #2813). The rule table follows GDCM's image helper with its Secondary Capture Image Plane option on:
///
/// - Secondary Capture: Pixel Spacing (0028,0030) when the object is calibrated, else Nominal Scanned Pixel Spacing
///   (0018,2010).
/// - Nuclear Medicine: Pixel Spacing, with Image Position/Orientation (Patient) from the first Detector Information
///   Sequence (0054,0022) item when the top level has none.
/// - Ultrasound: the first Sequence of Ultrasound Regions (0018,6011) item's Physical Delta X/Y. Unlike GDCM, which
///   returns them in the region's own unit, they count only when both axes are in centimetres, and become
///   millimetres.
///
/// The frame step is Spacing Between Slices (0018,0088), else Slice Thickness (0018,0050), else 1 mm; a spacing of
/// zero or less counts as absent (1 mm). A missing origin or orientation is left nil for the loader's default.
public struct DicomSOPClassGeometry: Equatable, Sendable {
    public static let secondaryCaptureSOPClassUID = "1.2.840.10008.5.1.4.1.1.7"
    public static let nuclearMedicineSOPClassUID = "1.2.840.10008.5.1.4.1.1.20"
    public static let ultrasoundSOPClassUIDs: Set<String> = [
        "1.2.840.10008.5.1.4.1.1.6.1",  // Ultrasound Image Storage
        "1.2.840.10008.5.1.4.1.1.3.1"   // Ultrasound Multi-frame Image Storage
    ]
    /// Every SOP Class this policy covers.
    public static let coveredSOPClassUIDs: Set<String> =
        ultrasoundSOPClassUIDs.union([secondaryCaptureSOPClassUID, nuclearMedicineSOPClassUID])

    /// Column (x) and row (y) spacing and the frame step (z), in millimetres.
    public var spacing: SIMD3<Double>
    /// Image Position (Patient) of the first frame.
    public var origin: SIMD3<Double>?
    /// Image Orientation (Patient): the row and column directions.
    public var orientation: (row: SIMD3<Double>, column: SIMD3<Double>)?

    /// Nil when `sopClassUID` is not one this policy covers.
    public init?(dataSet: DicomDataSet, sopClassUID: String) {
        let sopClassUID = sopClassUID.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0")))
        guard Self.coveredSOPClassUIDs.contains(sopClassUID) else { return nil }
        let inPlane: SIMD2<Double>
        if sopClassUID == Self.secondaryCaptureSOPClassUID {
            inPlane = Self.pixelSpacing(dataSet, 0x0028_0030) ?? Self.pixelSpacing(dataSet, 0x0018_2010) ?? .one
        } else if Self.ultrasoundSOPClassUIDs.contains(sopClassUID) {
            inPlane = Self.ultrasoundSpacing(dataSet) ?? .one
        } else {
            inPlane = Self.pixelSpacing(dataSet, 0x0028_0030) ?? .one
        }
        let step = [0x0018_0088, 0x0018_0050].lazy.compactMap { dataSet.floats(for: $0).first }
            .first { $0.isFinite && $0 > 0 } ?? 1
        spacing = SIMD3(inPlane.x, inPlane.y, step)

        var positioned = dataSet
        if sopClassUID == Self.nuclearMedicineSOPClassUID, dataSet.floats(for: 0x0020_0032).count < 3,
           let detector = dataSet.sequenceItems(for: 0x0054_0022).first?.dataSet {
            positioned = detector
        }
        let position = positioned.floats(for: 0x0020_0032)
        origin = position.count >= 3 && position.prefix(3).allSatisfy(\.isFinite)
            ? SIMD3(position[0], position[1], position[2]) : nil
        let cosines = positioned.floats(for: 0x0020_0037)
        if cosines.count >= 6, cosines.prefix(6).allSatisfy(\.isFinite) {
            let row = SIMD3(cosines[0], cosines[1], cosines[2])
            let column = SIMD3(cosines[3], cosines[4], cosines[5])
            orientation = simd_length(row) > 0 && simd_length(column) > 0
                ? (simd_normalize(row), simd_normalize(column)) : nil
        } else {
            orientation = nil
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.spacing == rhs.spacing && lhs.origin == rhs.origin
            && lhs.orientation?.row == rhs.orientation?.row && lhs.orientation?.column == rhs.orientation?.column
    }

    /// (column, row) spacing from a "row\column" pair; a zero component counts as 1 mm, like GDCM.
    private static func pixelSpacing(_ dataSet: DicomDataSet, _ tag: Int) -> SIMD2<Double>? {
        let values = dataSet.floats(for: tag)
        guard values.count >= 2, values[0].isFinite, values[1].isFinite, values[0] >= 0, values[1] >= 0 else {
            return nil
        }
        return SIMD2(values[1] == 0 ? 1 : values[1], values[0] == 0 ? 1 : values[0])
    }

    /// The first region's Physical Delta X/Y in millimetres, when both are positive and in centimetres (code 3).
    private static func ultrasoundSpacing(_ dataSet: DicomDataSet) -> SIMD2<Double>? {
        guard let region = dataSet.sequenceItems(for: 0x0018_6011).first?.dataSet,
              region.int(for: 0x0018_6024) == 3, region.int(for: 0x0018_6026) == 3,
              let deltaX = region.float(for: 0x0018_602C), let deltaY = region.float(for: 0x0018_602E),
              deltaX.isFinite, deltaY.isFinite, deltaX > 0, deltaY > 0 else { return nil }
        return SIMD2(deltaX * 10, deltaY * 10)
    }
}
