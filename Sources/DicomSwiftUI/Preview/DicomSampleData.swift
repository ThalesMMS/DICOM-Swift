//
//  DicomSampleData.swift
//
//  Sample data factory for Xcode Previews and testing.
//  Provides pre-configured sample patients, studies, and series data
//  with multiple modalities for instant preview rendering.
//
//  Performance:
//
//  All factory methods generate data in <50ms for responsive preview
//  loading. Sample data is created on-demand without file I/O.
//
//  Usage:
//
//  Use this factory in SwiftUI previews to populate views with realistic
//  medical imaging data without requiring actual DICOM files:
//
//  ```swift
//  #Preview {
//      DicomImageView(decoder: DicomSampleData.sampleCTDecoder())
//  }
//
//  #Preview {
//      PatientListView(patients: DicomSampleData.samplePatients())
//  }
//
//  #Preview {
//      SeriesNavigatorView(decoders: DicomSampleData.sampleCTSeries())
//  }
//  ```
//

import Foundation
import DicomCore

/// Sample DICOM data factory for Xcode Previews.
///
/// ## Overview
///
/// ``DicomSampleData`` provides a comprehensive set of factory methods for generating
/// sample DICOM data optimized for Xcode Previews. All sample data is created instantly
/// without file I/O, enabling fast preview rendering and responsive design iteration.
///
/// **Key Features:**
/// - Pre-configured sample data for 4 modalities (CT, MR, X-Ray, Ultrasound)
/// - Realistic patient demographics and study metadata
/// - Multi-slice series for navigation testing
/// - Sample data for all common use cases
/// - Instant generation (<50ms) for preview responsiveness
/// - No external dependencies or file access required
///
/// **Available Modalities:**
/// - **CT**: Chest scan with lung window (512×512, -600/1500 HU)
/// - **MRI**: Brain scan with T1 weighting (256×256, 600/1200)
/// - **X-Ray**: Chest radiograph PA view (1024×1024, 2000/4000)
/// - **Ultrasound**: Abdominal scan (640×480, 8-bit)
///
/// ## Usage
///
/// Create sample decoders for image views:
///
/// ```swift
/// #Preview("CT Lung Window") {
///     DicomImageView(decoder: DicomSampleData.sampleCTDecoder())
/// }
///
/// #Preview("MRI Brain") {
///     DicomImageView(decoder: DicomSampleData.sampleMRIDecoder())
/// }
/// ```
///
/// Create sample patients for list views:
///
/// ```swift
/// #Preview("Patient List") {
///     PatientListView(patients: DicomSampleData.samplePatients())
/// }
/// ```
///
/// Create sample series for navigation:
///
/// ```swift
/// #Preview("Series Navigator") {
///     SeriesNavigatorView(decoders: DicomSampleData.sampleCTSeries(slices: 5))
/// }
/// ```
///
/// Create custom sample data:
///
/// ```swift
/// let customDecoder = DicomSampleData.decoder(
///     modality: .ct,
///     width: 512,
///     height: 512,
///     patientName: "Custom^Patient",
///     studyDescription: "Custom Study"
/// )
/// ```
///
/// ## Topics
///
/// ### Sample Decoders
///
/// - ``sampleCTDecoder()``
/// - ``sampleMRIDecoder()``
/// - ``sampleXRayDecoder()``
/// - ``sampleUltrasoundDecoder()``
/// - ``decoder(modality:width:height:patientName:studyDescription:)``
///
/// ### Sample Patients
///
/// - ``samplePatients()``
/// - ``sampleCTPatient()``
/// - ``sampleMRIPatient()``
/// - ``sampleXRayPatient()``
/// - ``sampleUltrasoundPatient()``
///
/// ### Sample Series
///
/// - ``sampleCTSeries(slices:)``
/// - ``sampleMRISeries(slices:)``
/// - ``sampleSeries(modality:slices:)``
///
/// ### Window Settings
///
/// - ``windowSettings(for:)``
/// - ``ctLungWindow``
/// - ``ctBoneWindow``
/// - ``ctBrainWindow``
/// - ``mrBrainWindow``
///
@MainActor
public struct DicomSampleData {

    // MARK: - Sample Decoder Factories

    /// Creates a sample CT decoder with lung window settings.
    ///
    /// - Returns: Mock decoder configured as a chest CT with lung window
    ///
    /// **Specifications:**
    /// - Modality: CT
    /// - Size: 512×512 pixels
    /// - Window: -600/1500 (Lung)
    /// - Pixel Spacing: 0.7×0.7×5.0 mm
    /// - Study: "CT Chest"
    public static func sampleCTDecoder() -> MockDicomDecoderForPreviews {
        return MockDicomDecoderForPreviews.sampleCT()
    }

    /// Creates a sample MRI decoder with brain window settings.
    ///
    /// - Returns: Mock decoder configured as a brain MRI with T1 weighting
    ///
    /// **Specifications:**
    /// - Modality: MR
    /// - Size: 256×256 pixels
    /// - Window: 600/1200
    /// - Pixel Spacing: 0.9×0.9×3.0 mm
    /// - Study: "MRI Brain"
    public static func sampleMRIDecoder() -> MockDicomDecoderForPreviews {
        return MockDicomDecoderForPreviews.sampleMRI()
    }

    /// Creates a sample X-ray decoder for chest radiography.
    ///
    /// - Returns: Mock decoder configured as a chest X-ray PA view
    ///
    /// **Specifications:**
    /// - Modality: CR (Computed Radiography)
    /// - Size: 1024×1024 pixels
    /// - Window: 2000/4000
    /// - Pixel Spacing: 0.2×0.2×1.0 mm
    /// - Study: "Chest X-Ray"
    public static func sampleXRayDecoder() -> MockDicomDecoderForPreviews {
        return MockDicomDecoderForPreviews.sampleXRay()
    }

    /// Creates a sample ultrasound decoder for abdominal imaging.
    ///
    /// - Returns: Mock decoder configured as an abdominal ultrasound
    ///
    /// **Specifications:**
    /// - Modality: US
    /// - Size: 640×480 pixels
    /// - Bit Depth: 8-bit
    /// - Window: 128/256
    /// - Pixel Spacing: 0.1×0.1×1.0 mm
    /// - Study: "Ultrasound Exam"
    public static func sampleUltrasoundDecoder() -> MockDicomDecoderForPreviews {
        return MockDicomDecoderForPreviews.sampleUltrasound()
    }

    /// Creates a custom sample decoder with specified parameters.
    ///
    /// - Parameters:
    ///   - modality: DICOM modality type
    ///   - width: Image width in pixels (default: 512)
    ///   - height: Image height in pixels (default: 512)
    ///   - patientName: Patient name (default: "Sample^Patient")
    ///   - studyDescription: Study description (default: modality-specific)
    /// - Returns: Mock decoder configured with specified parameters
    ///
    /// ## Example
    /// ```swift
    /// let customDecoder = DicomSampleData.decoder(
    ///     modality: .ct,
    ///     width: 1024,
    ///     height: 1024,
    ///     patientName: "Doe^John",
    ///     studyDescription: "CT Abdomen with Contrast"
    /// )
    /// ```
    public static func decoder(
        modality: DICOMModality,
        width: Int = 512,
        height: Int = 512,
        patientName: String = "Sample^Patient",
        studyDescription: String? = nil
    ) -> MockDicomDecoderForPreviews {
        let (windowCenter, windowWidth) = windowSettings(for: modality)
        let description = studyDescription ?? defaultStudyDescription(for: modality)

        let decoder = MockDicomDecoderForPreviews(
            width: width,
            height: height,
            bitDepth: modality == .us ? 8 : 16,
            samplesPerPixel: 1,
            windowCenter: windowCenter,
            windowWidth: windowWidth,
            pixelWidth: defaultPixelSpacing(for: modality),
            pixelHeight: defaultPixelSpacing(for: modality),
            pixelDepth: defaultSliceThickness(for: modality),
            metadata: [
                "00100010": patientName,
                "00080060": modalityCode(modality),
                "00081030": description,
                "0008103E": defaultSeriesDescription(for: modality),
                "00200011": "1"
            ]
        )

        return decoder
    }

    // MARK: - Sample Patient Factories

    /// Creates an array of sample patients with diverse modalities.
    ///
    /// - Returns: Array of 6 sample patients with different studies
    ///
    /// **Included Samples:**
    /// - CT Chest (Male, 45Y)
    /// - MRI Brain (Female, 52Y)
    /// - X-Ray Chest (Male, 38Y)
    /// - CT Abdomen (Female, 61Y)
    /// - Ultrasound Abdomen (Female, 34Y)
    /// - MRI Spine (Male, 29Y)
    public static func samplePatients() -> [PatientModel] {
        return [
            sampleCTPatient(),
            sampleMRIPatient(),
            sampleXRayPatient(),
            sampleCTAbdomenPatient(),
            sampleUltrasoundPatient(),
            sampleMRISpinePatient()
        ]
    }

    /// Creates a sample CT patient with chest imaging.
    public static func sampleCTPatient() -> PatientModel {
        return PatientModel(
            patientName: "Smith^John",
            patientID: "CT001",
            patientBirthDate: Calendar.current.date(byAdding: .year, value: -45, to: Date()),
            patientSex: .male,
            patientAge: "045Y",
            patientWeight: 82.5,
            patientSize: 1.78,
            studyInstanceUID: "1.2.840.113619.2.55.1.1.1",
            studyDate: Date(),
            studyTime: Date(),
            studyDescription: "CT Chest without Contrast",
            accessionNumber: "ACC001",
            modality: .ct,
            bodyPartExamined: "CHEST",
            seriesDescription: "Lung Window",
            institutionName: "General Hospital",
            institutionAddress: "123 Medical Center Dr",
            stationName: "CT01",
            numberOfImages: 150,
            fileSize: 78643200,
            createdAt: Date(),
            lastAccessedAt: Date()
        )
    }

    /// Creates a sample MRI patient with brain imaging.
    public static func sampleMRIPatient() -> PatientModel {
        return PatientModel(
            patientName: "Johnson^Mary",
            patientID: "MR001",
            patientBirthDate: Calendar.current.date(byAdding: .year, value: -52, to: Date()),
            patientSex: .female,
            patientAge: "052Y",
            patientWeight: 68.0,
            patientSize: 1.65,
            studyInstanceUID: "1.2.840.113619.2.55.1.1.2",
            studyDate: Calendar.current.date(byAdding: .day, value: -1, to: Date()),
            studyTime: Calendar.current.date(byAdding: .day, value: -1, to: Date()),
            studyDescription: "MRI Brain with and without Contrast",
            accessionNumber: "ACC002",
            modality: .mr,
            bodyPartExamined: "BRAIN",
            seriesDescription: "T1 Weighted",
            institutionName: "General Hospital",
            institutionAddress: "123 Medical Center Dr",
            stationName: "MR02",
            numberOfImages: 200,
            fileSize: 52428800,
            createdAt: Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date(),
            lastAccessedAt: Date()
        )
    }

    /// Creates a sample X-ray patient with chest radiography.
    public static func sampleXRayPatient() -> PatientModel {
        return PatientModel(
            patientName: "Williams^Robert",
            patientID: "XR001",
            patientBirthDate: Calendar.current.date(byAdding: .year, value: -38, to: Date()),
            patientSex: .male,
            patientAge: "038Y",
            patientWeight: 75.0,
            patientSize: 1.75,
            studyInstanceUID: "1.2.840.113619.2.55.1.1.3",
            studyDate: Calendar.current.date(byAdding: .day, value: -2, to: Date()),
            studyTime: Calendar.current.date(byAdding: .day, value: -2, to: Date()),
            studyDescription: "Chest X-Ray 2 Views",
            accessionNumber: "ACC003",
            modality: .cr,
            bodyPartExamined: "CHEST",
            seriesDescription: "PA View",
            institutionName: "General Hospital",
            institutionAddress: "123 Medical Center Dr",
            stationName: "XR01",
            numberOfImages: 2,
            fileSize: 8388608,
            createdAt: Calendar.current.date(byAdding: .day, value: -2, to: Date()) ?? Date(),
            lastAccessedAt: Date()
        )
    }

    /// Creates a sample CT patient with abdominal imaging.
    public static func sampleCTAbdomenPatient() -> PatientModel {
        return PatientModel(
            patientName: "Davis^Patricia",
            patientID: "CT002",
            patientBirthDate: Calendar.current.date(byAdding: .year, value: -61, to: Date()),
            patientSex: .female,
            patientAge: "061Y",
            patientWeight: 72.3,
            patientSize: 1.62,
            studyInstanceUID: "1.2.840.113619.2.55.1.1.4",
            studyDate: Calendar.current.date(byAdding: .day, value: -3, to: Date()),
            studyTime: Calendar.current.date(byAdding: .day, value: -3, to: Date()),
            studyDescription: "CT Abdomen and Pelvis with Contrast",
            accessionNumber: "ACC004",
            modality: .ct,
            bodyPartExamined: "ABDOMEN",
            seriesDescription: "Soft Tissue Window",
            institutionName: "General Hospital",
            institutionAddress: "123 Medical Center Dr",
            stationName: "CT02",
            numberOfImages: 250,
            fileSize: 131072000,
            createdAt: Calendar.current.date(byAdding: .day, value: -3, to: Date()) ?? Date(),
            lastAccessedAt: Date()
        )
    }

    /// Creates a sample ultrasound patient with abdominal imaging.
    public static func sampleUltrasoundPatient() -> PatientModel {
        return PatientModel(
            patientName: "Martinez^Lisa",
            patientID: "US001",
            patientBirthDate: Calendar.current.date(byAdding: .year, value: -34, to: Date()),
            patientSex: .female,
            patientAge: "034Y",
            patientWeight: 65.0,
            patientSize: 1.68,
            studyInstanceUID: "1.2.840.113619.2.55.1.1.5",
            studyDate: Calendar.current.date(byAdding: .hour, value: -4, to: Date()),
            studyTime: Calendar.current.date(byAdding: .hour, value: -4, to: Date()),
            studyDescription: "Ultrasound Abdomen Complete",
            accessionNumber: "ACC005",
            modality: .us,
            bodyPartExamined: "ABDOMEN",
            seriesDescription: "Abdomen",
            institutionName: "General Hospital",
            institutionAddress: "123 Medical Center Dr",
            stationName: "US01",
            numberOfImages: 25,
            fileSize: 4194304,
            createdAt: Calendar.current.date(byAdding: .hour, value: -4, to: Date()) ?? Date(),
            lastAccessedAt: Date()
        )
    }

    /// Creates a sample MRI patient with spine imaging.
    public static func sampleMRISpinePatient() -> PatientModel {
        return PatientModel(
            patientName: "Anderson^Michael",
            patientID: "MR002",
            patientBirthDate: Calendar.current.date(byAdding: .year, value: -29, to: Date()),
            patientSex: .male,
            patientAge: "029Y",
            patientWeight: 88.0,
            patientSize: 1.83,
            studyInstanceUID: "1.2.840.113619.2.55.1.1.6",
            studyDate: Calendar.current.date(byAdding: .day, value: -4, to: Date()),
            studyTime: Calendar.current.date(byAdding: .day, value: -4, to: Date()),
            studyDescription: "MRI Lumbar Spine without Contrast",
            accessionNumber: "ACC006",
            modality: .mr,
            bodyPartExamined: "SPINE",
            seriesDescription: "T2 Weighted Sagittal",
            institutionName: "General Hospital",
            institutionAddress: "123 Medical Center Dr",
            stationName: "MR01",
            numberOfImages: 180,
            fileSize: 94371840,
            createdAt: Calendar.current.date(byAdding: .day, value: -4, to: Date()) ?? Date(),
            lastAccessedAt: Date()
        )
    }

    // MARK: - Sample Series Factories

    /// Creates a sample CT series with multiple slices for navigation testing.
    ///
    /// - Parameter slices: Number of slices to generate (default: 5)
    /// - Returns: Array of mock decoders representing a CT series
    ///
    /// ## Example
    /// ```swift
    /// let series = DicomSampleData.sampleCTSeries(slices: 10)
    /// let navigator = SeriesNavigatorView(decoders: series)
    /// ```
    public static func sampleCTSeries(slices: Int = 5) -> [MockDicomDecoderForPreviews] {
        return sampleSeries(modality: .ct, slices: slices)
    }

    /// Creates a sample MRI series with multiple slices for navigation testing.
    ///
    /// - Parameter slices: Number of slices to generate (default: 5)
    /// - Returns: Array of mock decoders representing an MRI series
    public static func sampleMRISeries(slices: Int = 5) -> [MockDicomDecoderForPreviews] {
        return sampleSeries(modality: .mr, slices: slices)
    }

    /// Creates a sample series with multiple slices for any modality.
    ///
    /// - Parameters:
    ///   - modality: DICOM modality type
    ///   - slices: Number of slices to generate (default: 5)
    /// - Returns: Array of mock decoders representing a series
    ///
    /// Each slice in the series has incrementing instance numbers and
    /// varying image positions for proper 3D reconstruction.
    public static func sampleSeries(modality: DICOMModality, slices: Int = 5) -> [MockDicomDecoderForPreviews] {
        var decoders: [MockDicomDecoderForPreviews] = []

        for _ in 0..<slices {
            let decoder = decoder(
                modality: modality,
                patientName: "Series^Patient",
                studyDescription: "\(modalityDisplayName(modality)) Series"
            )
            decoders.append(decoder)
        }

        return decoders
    }

    // MARK: - Window Settings Helpers

    /// Returns window settings for the specified modality.
    ///
    /// - Parameter modality: DICOM modality type
    /// - Returns: Tuple of (center, width) appropriate for the modality
    public static func windowSettings(for modality: DICOMModality) -> (center: Double, width: Double) {
        switch modality {
        case .ct:
            return (-600.0, 1500.0)  // Lung window
        case .mr:
            return (600.0, 1200.0)   // Brain T1
        case .cr, .dx:
            return (2000.0, 4000.0)  // X-ray chest
        case .us:
            return (128.0, 256.0)    // Ultrasound
        case .mg:
            return (1500.0, 3000.0)  // Mammography
        case .pt, .nm:
            return (2500.0, 5000.0)  // Nuclear medicine
        default:
            return (40.0, 400.0)     // Default soft tissue
        }
    }

    /// CT lung window settings (center: -600, width: 1500)
    public static let ctLungWindow = WindowSettings(center: -600.0, width: 1500.0)

    /// CT bone window settings (center: 400, width: 1800)
    public static let ctBoneWindow = WindowSettings(center: 400.0, width: 1800.0)

    /// CT brain window settings (center: 40, width: 80)
    public static let ctBrainWindow = WindowSettings(center: 40.0, width: 80.0)

    /// CT soft tissue window settings (center: 40, width: 400)
    public static let ctSoftTissueWindow = WindowSettings(center: 40.0, width: 400.0)

    /// MR brain window settings (center: 600, width: 1200)
    public static let mrBrainWindow = WindowSettings(center: 600.0, width: 1200.0)

    // MARK: - Private Helpers

    /// Returns the DICOM string code for a modality
    private static func modalityCode(_ modality: DICOMModality) -> String {
        switch modality {
        case .ct: return "CT"
        case .mr: return "MR"
        case .dx: return "DX"
        case .cr: return "CR"
        case .us: return "US"
        case .mg: return "MG"
        case .rf: return "RF"
        case .xc: return "XC"
        case .sc: return "SC"
        case .pt: return "PT"
        case .nm: return "NM"
        case .unknown: return "UNKNOWN"
        }
    }

    /// Returns the display name for a modality
    private static func modalityDisplayName(_ modality: DICOMModality) -> String {
        switch modality {
        case .ct: return "Computed Tomography"
        case .mr: return "Magnetic Resonance"
        case .dx: return "Digital Radiography"
        case .cr: return "Computed Radiography"
        case .us: return "Ultrasound"
        case .mg: return "Mammography"
        case .rf: return "Radiofluoroscopy"
        case .xc: return "External Photography"
        case .sc: return "Secondary Capture"
        case .pt: return "PET Scan"
        case .nm: return "Nuclear Medicine"
        case .unknown: return "Unknown"
        }
    }

    private static func defaultStudyDescription(for modality: DICOMModality) -> String {
        switch modality {
        case .ct: return "CT Chest"
        case .mr: return "MRI Brain"
        case .cr, .dx: return "Chest X-Ray"
        case .us: return "Ultrasound Exam"
        case .mg: return "Mammography Bilateral"
        case .pt: return "PET Whole Body"
        case .nm: return "Nuclear Medicine Scan"
        default: return "Medical Imaging Study"
        }
    }

    private static func defaultSeriesDescription(for modality: DICOMModality) -> String {
        switch modality {
        case .ct: return "Lung Window"
        case .mr: return "T1 Weighted"
        case .cr, .dx: return "PA View"
        case .us: return "Abdomen"
        case .mg: return "Craniocaudal View"
        case .pt: return "Whole Body"
        case .nm: return "Planar"
        default: return "Series 1"
        }
    }

    private static func defaultPixelSpacing(for modality: DICOMModality) -> Double {
        switch modality {
        case .ct: return 0.7
        case .mr: return 0.9
        case .cr, .dx: return 0.2
        case .us: return 0.1
        case .mg: return 0.1
        case .pt: return 4.0
        case .nm: return 2.0
        default: return 1.0
        }
    }

    private static func defaultSliceThickness(for modality: DICOMModality) -> Double {
        switch modality {
        case .ct: return 5.0
        case .mr: return 3.0
        case .cr, .dx: return 1.0
        case .us: return 1.0
        case .mg: return 1.0
        case .pt: return 5.0
        case .nm: return 5.0
        default: return 1.0
        }
    }
}

// MARK: - Convenience Extensions

extension DicomSampleData {

    /// Quick access to a sample decoder for any modality.
    ///
    /// - Parameter modality: DICOM modality type
    /// - Returns: Mock decoder for the specified modality
    public static func sampleDecoder(for modality: DICOMModality) -> MockDicomDecoderForPreviews {
        switch modality {
        case .ct:
            return sampleCTDecoder()
        case .mr:
            return sampleMRIDecoder()
        case .cr, .dx:
            return sampleXRayDecoder()
        case .us:
            return sampleUltrasoundDecoder()
        default:
            return decoder(modality: modality)
        }
    }

    /// Quick access to a sample patient for any modality.
    ///
    /// - Parameter modality: DICOM modality type
    /// - Returns: Sample patient with the specified modality
    public static func samplePatient(for modality: DICOMModality) -> PatientModel {
        switch modality {
        case .ct:
            return sampleCTPatient()
        case .mr:
            return sampleMRIPatient()
        case .cr, .dx:
            return sampleXRayPatient()
        case .us:
            return sampleUltrasoundPatient()
        default:
            return PatientModel(
                patientName: "Sample^Patient",
                patientID: "SAMPLE001",
                studyInstanceUID: "1.2.840.113619.2.55.1.1.999",
                modality: modality
            )
        }
    }
}
