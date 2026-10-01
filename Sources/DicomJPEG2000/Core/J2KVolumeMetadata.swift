//
// J2KVolumeMetadata.swift
// J2KSwift
//
/// # J2KVolumeMetadata
///
/// Metadata types for volumetric JPEG 2000 datasets.
///
/// This file provides metadata structures for describing volumetric data,
/// including patient information, acquisition parameters, and modality details
/// commonly used in medical imaging and scientific visualization.

import Foundation

/// Metadata describing a volumetric dataset.
///
/// `J2KVolumeMetadata` stores information about the acquisition, patient,
/// and content of a volumetric image. All fields are optional to support
/// both medical and non-medical use cases.
///
/// Example:
/// ```swift
/// let metadata = J2KVolumeMetadata(
///     modality: .ct,
///     patientID: "ANON-001",
///     studyDescription: "Chest CT",
///     sliceThickness: 1.25
/// )
/// ```
public struct J2KVolumeMetadata: Sendable, Equatable {
    /// The imaging modality used to acquire the volume.
    public let modality: J2KVolumeModality

    /// The patient identifier (anonymized or pseudonymized).
    public let patientID: String?

    /// A description of the study.
    public let studyDescription: String?

    /// A description of the series within the study.
    public let seriesDescription: String?

    /// The institution where the volume was acquired.
    public let institution: String?

    /// The date and time of acquisition.
    public let acquisitionDate: Date?

    /// The slice thickness in physical units (e.g., millimeters).
    public let sliceThickness: Double?

    /// Window center for display (Hounsfield units for CT).
    public let windowCenter: Double?

    /// Window width for display.
    public let windowWidth: Double?

    /// The number of bits allocated per sample in the source data.
    public let bitsAllocated: Int?

    /// The number of bits stored per sample in the source data.
    public let bitsStored: Int?

    /// The high bit position.
    public let highBit: Int?

    /// Custom key-value metadata.
    public let customMetadata: [String: String]

    /// Creates volume metadata with the specified parameters.
    ///
    /// - Parameters:
    ///   - modality: The imaging modality (default: .unknown).
    ///   - patientID: Patient identifier (default: nil).
    ///   - studyDescription: Study description (default: nil).
    ///   - seriesDescription: Series description (default: nil).
    ///   - institution: Institution name (default: nil).
    ///   - acquisitionDate: Date of acquisition (default: nil).
    ///   - sliceThickness: Slice thickness in physical units (default: nil).
    ///   - windowCenter: Window center for display (default: nil).
    ///   - windowWidth: Window width for display (default: nil).
    ///   - bitsAllocated: Bits allocated per sample (default: nil).
    ///   - bitsStored: Bits stored per sample (default: nil).
    ///   - highBit: High bit position (default: nil).
    ///   - customMetadata: Custom key-value pairs (default: empty).
    public init(
        modality: J2KVolumeModality = .unknown,
        patientID: String? = nil,
        studyDescription: String? = nil,
        seriesDescription: String? = nil,
        institution: String? = nil,
        acquisitionDate: Date? = nil,
        sliceThickness: Double? = nil,
        windowCenter: Double? = nil,
        windowWidth: Double? = nil,
        bitsAllocated: Int? = nil,
        bitsStored: Int? = nil,
        highBit: Int? = nil,
        customMetadata: [String: String] = [:]
    ) {
        self.modality = modality
        self.patientID = patientID
        self.studyDescription = studyDescription
        self.seriesDescription = seriesDescription
        self.institution = institution
        self.acquisitionDate = acquisitionDate
        self.sliceThickness = sliceThickness
        self.windowCenter = windowCenter
        self.windowWidth = windowWidth
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.customMetadata = customMetadata
    }

    /// An empty metadata instance with no fields set.
    public static var empty: J2KVolumeMetadata {
        J2KVolumeMetadata()
    }
}

/// Imaging modality for volumetric data acquisition.
///
/// Describes the type of imaging device or technique used to produce
/// the volumetric dataset.
public enum J2KVolumeModality: String, Sendable, Equatable, CaseIterable {
    /// Computed Tomography.
    case ct = "CT"

    /// Magnetic Resonance Imaging.
    case mri = "MR"

    /// Positron Emission Tomography.
    case pet = "PT"

    /// Ultrasound.
    case ultrasound = "US"

    /// X-Ray Angiography.
    case xrayAngiography = "XA"

    /// Nuclear Medicine.
    case nuclearMedicine = "NM"

    /// Microscopy.
    case microscopy = "SM"

    /// Optical Coherence Tomography.
    case oct = "OCT"

    /// Scientific visualization / generic 3D data.
    case scientific = "SC"

    /// Geospatial raster data.
    case geospatial = "GEO"

    /// Unknown or unspecified modality.
    case unknown = "OT"
}
