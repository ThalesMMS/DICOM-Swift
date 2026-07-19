# ``DicomCore``

Pure Swift DICOM decoder for iOS and macOS. Read DICOM files, extract medical metadata, and process pixel data without UIKit or Objective-C dependencies.

## Overview

DicomCore is a complete DICOM decoder written in Swift, modernized from a legacy medical viewer. It provides comprehensive support for parsing DICOM files, extracting metadata, processing pixel data, and applying medical image windowing operations.

DICOM (Digital Imaging and Communications in Medicine) is the standard for medical imaging used by CT, MRI, X-ray, ultrasound, and hospital PACS systems. This library is suitable for lightweight DICOM viewers, PACS clients, telemedicine apps, and research tools.

### Key Features

- Complete DICOM file parsing (metadata and pixels)
- Support for 8-bit, 16-bit grayscale and 24-bit RGB images
- PNG, JPEG, TIFF, 16-bit TIFF, and multiframe image export
- UI-independent print/export preprocessing with resize and explicit annotation burn-in
- Export, Secondary Capture, print, waveform, and video support matrix with typed unsupported-path diagnostics
- Transfer syntax registry, conservative transcode planning, explicit-intent CPU JPEG 2000/HTJ2K encoding, and experimental JPEG XL routes
- Encapsulated Pixel Data frame indexing before codec decode
- Deflated Explicit VR Little Endian dataset read/write support through zlib
- JPIP referenced pixel data and progressive volume update streams with injected transport
- DICOMweb client/server helpers with a tested conformance matrix for QIDO-RS, WADO-RS, WADO-URI, STOW-RS, BulkDataURI retrieval, pagination, auth hooks, multipart handling, and stable unsupported-route errors
- Package-only series volume assembly for single-frame 8/16/32-bit MONOCHROME1/2 grayscale inputs normalized to `Int16`; compressed slices decode through the production frame reader when the transfer syntax has an active backend
- Enhanced CT/MR multiframe volume assembly from one object via Shared/Per-Frame Functional Groups (geometry, position ordering, per-frame rescale), native or compressed
- DICOM Segmentation parsing, labelmap extraction, and synthetic SEG dataset building
- RT Structure Set, RT Dose, and RT Plan parsing for contour, dose-volume, and beam inspection
- Parametric Map scalar layer parsing with units, quantity definitions, RWV, geometry, and source references
- Structured Report and Key Object Selection parsing with navigable content trees, measurements, ROI references, CAD findings, key image references, and scoped semantic validation for Enhanced/Comprehensive SR TID 1500 plus KOS references
- Secondary Capture snapshot dataset building and parsing with patient/study/series context and source image references
- External inference builders for SR findings, SEG masks, GSPS graphic annotations, and derived images
- Grayscale Softcopy Presentation State graphic annotation dataset building/parsing
- Encapsulated PDF, CDA, and STL document dataset building/parsing with MIME, title, concept, payload, and source instance metadata
- ECG and waveform dataset building/parsing with channel samples, sampling frequency, units, and waveform source references
- Video Endoscopic/Microscopic/Photographic dataset building/parsing with MPEG-2, H.264, and H.265 stream forwarding
- Window/level operations with medical presets and GPU acceleration
- Modern async/await APIs for non-blocking operations
- File validation before processing
- Pure Swift implementation with ZIP archive support through ZIPFoundation

## Topics

### Getting Started

- <doc:GettingStarted>
- <doc:Installation>
- <doc:QuickStart>

### Core Components

- ``DCMDecoder``
- ``DCMWindowingProcessor``
- ``MetalWindowingProcessor``
- ``DicomSeriesLoader``
- ``DicomSeriesLoaderSupportMatrix``
- ``DicomSeriesLoaderPixelFormat``
- ``DicomJP3DVolumeDocument``
- ``DicomJPIPClient``
- ``DicomJPIPReferencedPixelData``
- ``DicomWebClient``
- ``DicomWebServer``
- ``DicomWebConformanceMatrix``
- ``DicomWebConformanceStatement``
- ``DicomDeflatedDataSetCodec``
- ``DicomSegmentationBuilder``
- ``DicomRTStructureSet``
- ``DicomRTDoseVolume``
- ``DicomRTPlan``
- ``DicomParametricMap``
- ``DicomSRDocument``
- ``DicomStructuredReportBuilder``
- ``DicomKeyObjectSelectionBuilder``
- ``DicomSRSupportMatrix``
- ``DicomSRSemanticValidator``
- ``DicomSecondaryCaptureBuilder``
- ``DicomAIInferenceBuilder``
- ``DicomGrayscalePresentationState``
- ``DicomGrayscalePresentationStateBuilder``
- ``DicomSecondaryCaptureImage``
- ``DicomSecondaryCapturePixelData``
- ``DicomSecondaryCaptureBuildOptions``
- ``DicomSecondaryCaptureValidationScope``
- ``DicomEncapsulatedDocument``
- ``DicomEncapsulatedDocumentBuilder``
- ``DicomEncapsulatedDocumentBuildOptions``
- ``DicomEncapsulatedDocumentKind``
- ``DicomEncapsulatedDocumentSourceInstance``
- ``DicomWaveform``
- ``DicomWaveformBuilder``
- ``DicomWaveformBuildOptions``
- ``DicomWaveformMultiplexGroup``
- ``DicomWaveformChannel``
- ``DicomWaveformStorageKind``
- ``DicomWaveformSampleInterpretation``
- ``DicomWaveformSourceReference``
- ``DicomVideo``
- ``DicomVideoBuilder``
- ``DicomVideoBuildOptions``
- ``DicomVideoPixelData``
- ``DicomVideoStorageKind``
- ``DicomVideoCodec``
- ``DicomImageExporter``
- ``DicomExportSupportMatrix``
- ``DicomExportSupportRow``
- ``DicomPrintManagementSupport``
- ``DicomPrintManagementUnsupportedService``
- ``DicomImagePreprocessor``
- ``DicomBitmapResizer``
- ``DicomAnnotationRenderer``
- ``DicomTransferSyntaxRegistry``
- ``DicomTranscodePlan``
- ``DicomEncapsulatedPixelDataParser``
- ``DicomEncapsulatedPixelDataDescriptor``

### Data Models

- ``PatientModel``
- ``StudyModel``
- ``SeriesModel``
- ``ImageModel``
- ``DicomSeriesVolume``
- ``DicomJP3DVolumeGeometry``
- ``DicomProgressiveLayer``
- ``DicomProgressiveVolumeUpdate``
- ``DicomSegmentation``
- ``DicomSegmentationFrame``
- ``DicomSegment``
- ``DicomSegmentLabelmap``
- ``DicomRTROI``
- ``DicomRTContour``
- ``DicomRTROIContour``
- ``DicomRTBeam``
- ``DicomRTControlPoint``
- ``DicomParametricMapFrame``
- ``DicomParametricMapScalarVolume``
- ``DicomQuantityDefinition``
- ``DicomSRContentItem``
- ``DicomSRMeasurement``
- ``DicomSRGraphicRegion``
- ``DicomSRCADFinding``
- ``DicomKeyObjectReference``
- ``DicomDecodedSeries``
- ``DicomSeriesSource``

### Value Types

- ``WindowSettings``
- ``PixelSpacing``
- ``RescaleParameters``
- ``DicomTag``
- ``DicomTransferSyntax``
- ``DicomSegmentationType``
- ``DicomSegmentationFractionalType``

### Services

- ``StudyDataService``
- ``DCMDictionary``

### Error Handling

- ``DICOMError``
- ``DicomDeflatedDataSetError``

### Image Processing

- <doc:WindowingAndLeveling>
- <doc:GPUAcceleration>
- <doc:MedicalPresets>

### Advanced Topics

- <doc:SeriesLoading>
- <doc:DicomLoading>
- <doc:GeometryAndOrientation>
- <doc:PerformanceOptimization>

### Reference

- <doc:SupportedFormats>
- <doc:ConformanceStatement>
- <doc:DicomGlossary>
- <doc:Troubleshooting>
