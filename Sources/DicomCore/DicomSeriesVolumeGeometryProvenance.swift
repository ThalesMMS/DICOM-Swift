//
//  DicomSeriesVolumeGeometryProvenance.swift
//  DicomCore
//
//  Where a loaded volume's slice order, slice interval, in-plane spacing and
//  orientation come from (issue #3037), so consumers can tell measured
//  geometry from a guess or a default.
//

import Foundation

public struct DicomSeriesVolumeGeometryProvenance: Equatable, Sendable {
    public enum SliceOrdering: String, Equatable, Sendable {
        /// Image Position (Patient) projected on the slice normal; for Enhanced objects, the Plane Position
        /// (Patient) of each frame's functional groups.
        case imagePositionPatient
        /// Instance Number, used when a slice has no position.
        case instanceNumber
        /// File name, used when neither a position nor an Instance Number orders the slices.
        case fileName
        /// The frames of one classic multi-frame object, in stored order.
        case storedFrames
    }

    public enum SliceSpacingSource: String, Equatable, Sendable {
        /// The median distance between adjacent slice positions along the normal.
        case imagePositionPatient
        /// The slice positions are not evenly spaced (issue #3116): the median distance between adjacent positions,
        /// one interval for the whole volume, as Horos takes one; out-of-plane geometry is approximate.
        case irregularImagePositionPatient
        case spacingBetweenSlices
        case sliceThickness
        /// No attribute gave an interval: the slices stand 1 mm apart.
        case defaultValue
    }

    public let sliceOrdering: SliceOrdering
    public let sliceSpacingSource: SliceSpacingSource
    /// Whether the in-plane spacing came from an attribute (Pixel Spacing, or the spacing the SOP Class
    /// defines) rather than the 1 mm default.
    public let isInPlaneSpacingCalibrated: Bool
    /// Whether every slice declares the row and column directions, rather than some or all taking another slice's
    /// or the identity default.
    public let hasDeclaredOrientation: Bool

    public init(sliceOrdering: SliceOrdering, sliceSpacingSource: SliceSpacingSource,
                isInPlaneSpacingCalibrated: Bool, hasDeclaredOrientation: Bool) {
        self.sliceOrdering = sliceOrdering
        self.sliceSpacingSource = sliceSpacingSource
        self.isInPlaneSpacingCalibrated = isInPlaneSpacingCalibrated
        self.hasDeclaredOrientation = hasDeclaredOrientation
    }
}
