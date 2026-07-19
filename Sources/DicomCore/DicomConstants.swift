//
//  DicomConstants.swift
//
//  Centralized DICOM constants including tag definitions, Value
//  Representations, and transfer syntax UIDs. This module provides
//  type-safe enums to replace scattered magic numbers across the
//  codebase and improve maintainability.
//
//  Usage:
//
//    let decoder = DCMDecoder()
//    let patientName = decoder.info(for: DicomTag.patientName.rawValue)
//

import Foundation

// MARK: - DICOM Tag Constants

/// DICOM tag identifiers following the DICOM standard format.
///
/// ## Overview
///
/// ``DicomTag`` provides type-safe access to DICOM tag identifiers defined in the DICOM standard.
/// Each tag is a 32-bit value combining group and element numbers in the format `0xGGGGEEEE`,
/// where `GGGG` is the group number and `EEEE` is the element number. Tags are organized into
/// logical categories for improved discoverability and maintainability.
///
/// Using this enum eliminates magic numbers throughout the codebase and provides compile-time
/// safety when working with DICOM metadata. All standard DICOM tags used by the library are
/// represented here, from basic image dimensions to complex spatial geometry attributes.
///
/// ## Usage
///
/// Use ``DicomTag`` cases directly with ``DCMDecoder`` metadata accessors:
///
/// ```swift
/// let decoder = try DCMDecoder(contentsOf: url)
/// let patientName = decoder.info(for: .patientName)
/// let modality = decoder.info(for: .modality)
/// let rows = decoder.intValue(for: .rows) ?? 0
/// ```
///
/// For raw tag access (e.g., private tags not in this enum), use the `rawValue`:
///
/// ```swift
/// let customTag = decoder.info(for: 0x00091001)  // Private tag
/// ```
///
/// ## Topics
///
/// ### Image Pixel Description
///
/// - ``samplesPerPixel``
/// - ``photometricInterpretation``
/// - ``planarConfiguration``
/// - ``numberOfFrames``
/// - ``rows``
/// - ``columns``
/// - ``pixelSpacing``
/// - ``bitsAllocated``
/// - ``bitsStored``
/// - ``highBit``
/// - ``pixelRepresentation``
///
/// ### Display Parameters
///
/// - ``windowCenter``
/// - ``windowWidth``
/// - ``rescaleIntercept``
/// - ``rescaleSlope``
///
/// ### Patient Information
///
/// - ``patientName``
/// - ``patientID``
/// - ``patientSex``
/// - ``patientAge``
///
/// ### Study and Series Information
///
/// - ``studyInstanceUID``
/// - ``studyID``
/// - ``studyDate``
/// - ``seriesInstanceUID``
/// - ``seriesNumber``
/// - ``modality``
///
/// ### Spatial Geometry
///
/// - ``imagePositionPatient``
/// - ``imageOrientationPatient``
/// - ``sliceThickness``
/// - ``sliceSpacing``
///
/// ### Pixel Data
///
/// - ``pixelData``
/// - ``iconImageSequence``
public enum DicomTag: Int {

    // MARK: - Character Set

    /// (0008,0005) - Specific Character Set
    case specificCharacterSet = 0x00080005

    /// (0008,0008) - Image Type
    case imageType = 0x00080008

    /// (0008,0012) - Instance Creation Date
    case instanceCreationDate = 0x00080012

    /// (0008,0013) - Instance Creation Time
    case instanceCreationTime = 0x00080013

    // MARK: - Coded Concepts

    /// (0008,0100) - Code Value
    case codeValue = 0x00080100

    /// (0008,0102) - Coding Scheme Designator
    case codingSchemeDesignator = 0x00080102

    /// (0008,0104) - Code Meaning
    case codeMeaning = 0x00080104

    /// (0008,0105) - Mapping Resource
    case mappingResource = 0x00080105

    // MARK: - Image Pixel Description

    /// (0028,0002) - Samples per Pixel
    case samplesPerPixel = 0x00280002

    /// (0028,0004) - Photometric Interpretation (e.g., MONOCHROME1, RGB)
    case photometricInterpretation = 0x00280004

    /// (0028,0006) - Planar Configuration
    case planarConfiguration = 0x00280006

    /// (0028,0008) - Number of Frames
    case numberOfFrames = 0x00280008

    /// (0028,0009) - Frame Increment Pointer
    case frameIncrementPointer = 0x00280009

    /// (0028,0010) - Rows (image height)
    case rows = 0x00280010

    /// (0028,0011) - Columns (image width)
    case columns = 0x00280011

    /// (0028,0030) - Pixel Spacing
    case pixelSpacing = 0x00280030

    /// (0028,9110) - Pixel Measures Sequence
    case pixelMeasuresSequence = 0x00289110

    /// (0028,9145) - Pixel Value Transformation Sequence
    case pixelValueTransformationSequence = 0x00289145

    /// (0028,0100) - Bits Allocated
    case bitsAllocated = 0x00280100

    /// (0028,0101) - Bits Stored
    case bitsStored = 0x00280101

    /// (0028,0102) - High Bit
    case highBit = 0x00280102

    /// (0028,0103) - Pixel Representation (0=unsigned, 1=signed)
    case pixelRepresentation = 0x00280103

    // MARK: - Image Display Parameters

    /// (0028,1050) - Window Center
    case windowCenter = 0x00281050

    /// (0028,1051) - Window Width
    case windowWidth = 0x00281051

    /// (0028,1052) - Rescale Intercept
    case rescaleIntercept = 0x00281052

    /// (0028,1053) - Rescale Slope
    case rescaleSlope = 0x00281053

    /// (0028,1054) - Rescale Type
    case rescaleType = 0x00281054

    /// (0028,1055) - Window Center & Width Explanation
    case windowCenterWidthExplanation = 0x00281055

    /// (0028,3000) - Modality LUT Sequence
    case modalityLUTSequence = 0x00283000

    /// (0028,3002) - LUT Descriptor
    case lutDescriptor = 0x00283002

    /// (0028,3003) - LUT Explanation
    case lutExplanation = 0x00283003

    /// (0028,3004) - Modality LUT Type
    case modalityLUTType = 0x00283004

    /// (0028,3006) - LUT Data
    case lutData = 0x00283006

    /// (0028,3010) - VOI LUT Sequence
    case voiLUTSequence = 0x00283010

    /// (2050,0010) - Presentation LUT Sequence
    case presentationLUTSequence = 0x20500010

    /// (2050,0020) - Presentation LUT Shape
    case presentationLUTShape = 0x20500020

    /// (0040,9096) - Real World Value Mapping Sequence
    case realWorldValueMappingSequence = 0x00409096

    /// (0040,9210) - LUT Label
    case realWorldValueLUTLabel = 0x00409210

    /// (0040,9211) - Real World Value Last Value Mapped
    case realWorldValueLastValueMapped = 0x00409211

    /// (0040,9212) - Real World Value LUT Data
    case realWorldValueLUTData = 0x00409212

    /// (0040,9213) - Double Float Real World Value Last Value Mapped
    case doubleFloatRealWorldValueLastValueMapped = 0x00409213

    /// (0040,9214) - Double Float Real World Value First Value Mapped
    case doubleFloatRealWorldValueFirstValueMapped = 0x00409214

    /// (0040,9216) - Real World Value First Value Mapped
    case realWorldValueFirstValueMapped = 0x00409216

    /// (0040,9220) - Quantity Definition Sequence
    case quantityDefinitionSequence = 0x00409220

    /// (0040,9224) - Real World Value Intercept
    case realWorldValueIntercept = 0x00409224

    /// (0040,9225) - Real World Value Slope
    case realWorldValueSlope = 0x00409225

    /// (0040,08EA) - Measurement Units Code Sequence
    case measurementUnitsCodeSequence = 0x004008EA

    // MARK: - Color Palettes

    /// (0028,1101) - Red Palette Color Lookup Table Descriptor
    case redPaletteDescriptor = 0x00281101

    /// (0028,1102) - Green Palette Color Lookup Table Descriptor
    case greenPaletteDescriptor = 0x00281102

    /// (0028,1103) - Blue Palette Color Lookup Table Descriptor
    case bluePaletteDescriptor = 0x00281103

    /// (0028,1201) - Red Palette Color Lookup Table
    case redPalette = 0x00281201

    /// (0028,1202) - Green Palette Color Lookup Table
    case greenPalette = 0x00281202

    /// (0028,1203) - Blue Palette Color Lookup Table
    case bluePalette = 0x00281203

    /// (0028,2000) - ICC Profile
    case iccProfile = 0x00282000

    /// (0028,2110) - Lossy Image Compression
    case lossyImageCompression = 0x00282110

    /// (0028,2112) - Lossy Image Compression Ratio
    case lossyImageCompressionRatio = 0x00282112

    /// (0028,2114) - Lossy Image Compression Method
    case lossyImageCompressionMethod = 0x00282114

    /// (0028,7FE0) - Pixel Data Provider URL
    case pixelDataProviderURL = 0x00287FE0

    // MARK: - Pixel Data

    /// (7FE0,0001) - Extended Offset Table
    case extendedOffsetTable = 0x7FE00001

    /// (7FE0,0002) - Extended Offset Table Lengths
    case extendedOffsetTableLengths = 0x7FE00002

    /// (7FE0,0008) - Float Pixel Data
    case floatPixelData = 0x7FE00008

    /// (7FE0,0009) - Double Float Pixel Data
    case doubleFloatPixelData = 0x7FE00009

    /// (7FE0,0010) - Pixel Data
    case pixelData = 0x7FE00010

    /// (0088,0200) - Icon Image Sequence
    case iconImageSequence = 0x00880200

    // MARK: - Patient Information

    /// (0010,0010) - Patient's Name
    case patientName = 0x00100010

    /// (0010,0020) - Patient ID
    case patientID = 0x00100020

    /// (0010,0040) - Patient's Sex
    case patientSex = 0x00100040

    /// (0010,1010) - Patient's Age
    case patientAge = 0x00101010

    /// (0010,1020) - Patient's Size
    case patientSize = 0x00101020

    /// (0010,1030) - Patient's Weight
    case patientWeight = 0x00101030

    // MARK: - Study Information

    /// (0020,000D) - Study Instance UID
    case studyInstanceUID = 0x0020000d

    /// (0020,0010) - Study ID
    case studyID = 0x00200010

    /// (0008,0020) - Study Date
    case studyDate = 0x00080020

    /// (0008,0030) - Study Time
    case studyTime = 0x00080030

    /// (0008,1030) - Study Description
    case studyDescription = 0x00081030

    /// (0020,1206) - Number of Study Related Series
    case numberOfStudyRelatedSeries = 0x00201206

    /// (0008,0061) - Modalities in Study
    case modalitiesInStudy = 0x00080061

    /// (0008,0090) - Referring Physician's Name
    case referringPhysicianName = 0x00080090

    // MARK: - Series Information

    /// (0020,000E) - Series Instance UID
    case seriesInstanceUID = 0x0020000e

    /// (0020,0011) - Series Number
    case seriesNumber = 0x00200011

    /// (0008,0021) - Series Date
    case seriesDate = 0x00080021

    /// (0008,0031) - Series Time
    case seriesTime = 0x00080031

    /// (0008,103E) - Series Description
    case seriesDescription = 0x0008103E

    /// (0020,1209) - Number of Series Related Instances
    case numberOfSeriesRelatedInstances = 0x00201209

    /// (0008,0060) - Modality
    case modality = 0x00080060

    /// (0008,0064) - Conversion Type
    case conversionType = 0x00080064

    /// (0008,2144) - Recommended Display Frame Rate
    case recommendedDisplayFrameRate = 0x00082144

    // MARK: - Protocol Names

    /// (0018,0040) - Cine Rate
    case cineRate = 0x00180040

    /// (0028,1030) - Protocol Name (Image level)
    case protocolName = 0x00281030

    /// (0018,1030) - Protocol Name (Acquisition level)
    case acquisitionProtocolName = 0x00181030

    /// (0018,1063) - Frame Time
    case frameTime = 0x00181063

    /// (0018,1065) - Frame Time Vector
    case frameTimeVector = 0x00181065

    /// (0018,1600) - Shutter Shape
    case shutterShape = 0x00181600

    /// (0018,1602) - Shutter Left Vertical Edge
    case shutterLeftVerticalEdge = 0x00181602

    /// (0018,1604) - Shutter Right Vertical Edge
    case shutterRightVerticalEdge = 0x00181604

    /// (0018,1606) - Shutter Upper Horizontal Edge
    case shutterUpperHorizontalEdge = 0x00181606

    /// (0018,1608) - Shutter Lower Horizontal Edge
    case shutterLowerHorizontalEdge = 0x00181608

    /// (0018,1610) - Center of Circular Shutter
    case centerOfCircularShutter = 0x00181610

    /// (0018,1612) - Radius of Circular Shutter
    case radiusOfCircularShutter = 0x00181612

    /// (0018,1620) - Vertices of the Polygonal Shutter
    case verticesOfPolygonalShutter = 0x00181620

    // MARK: - Image Position and Orientation

    /// (0020,0032) - Image Position (Patient)
    case imagePositionPatient = 0x00200032

    /// (0020,0037) - Image Orientation (Patient)
    case imageOrientationPatient = 0x00200037

    /// (0020,0052) - Frame of Reference UID
    case frameOfReferenceUID = 0x00200052

    /// (0020,9113) - Plane Position Sequence
    case planePositionSequence = 0x00209113

    /// (0020,9116) - Plane Orientation Sequence
    case planeOrientationSequence = 0x00209116

    /// (0020,9111) - Frame Content Sequence
    case frameContentSequence = 0x00209111

    /// (0020,9056) - Stack ID
    case stackID = 0x00209056

    /// (0020,9057) - In-Stack Position Number
    case inStackPositionNumber = 0x00209057

    /// (0020,9128) - Temporal Position Index
    case temporalPositionIndex = 0x00209128

    /// (0020,9156) - Frame Acquisition Number
    case frameAcquisitionNumber = 0x00209156

    /// (0020,9157) - Dimension Index Values
    case dimensionIndexValues = 0x00209157

    /// (0018,0050) - Slice Thickness
    case sliceThickness = 0x00180050

    /// (0018,0088) - Spacing Between Slices
    case sliceSpacing = 0x00180088

    // MARK: - Instance Information

    /// (0008,0016) - SOP Class UID
    case sopClassUID = 0x00080016

    /// (0008,0018) - SOP Instance UID
    case sopInstanceUID = 0x00080018

    /// (0008,1150) - Referenced SOP Class UID
    case referencedSOPClassUID = 0x00081150

    /// (0008,1155) - Referenced SOP Instance UID
    case referencedSOPInstanceUID = 0x00081155

    /// (0008,1160) - Referenced Frame Number
    case referencedFrameNumber = 0x00081160

    /// (0008,1199) - Referenced SOP Sequence
    case referencedSOPSequence = 0x00081199

    /// (0008,1140) - Referenced Image Sequence
    case referencedImageSequence = 0x00081140

    /// (0008,1115) - Referenced Series Sequence
    case referencedSeriesSequence = 0x00081115

    /// (0008,2112) - Source Image Sequence
    case sourceImageSequence = 0x00082112

    /// (0008,2111) - Derivation Description
    case derivationDescription = 0x00082111

    /// (0008,9124) - Derivation Image Sequence
    case derivationImageSequence = 0x00089124

    /// (0020,0013) - Instance Number
    case instanceNumber = 0x00200013

    /// (0008,0022) - Acquisition Date
    case acquisitionDate = 0x00080022

    /// (0008,0023) - Content Date
    case contentDate = 0x00080023

    /// (0008,0032) - Acquisition Time
    case acquisitionTime = 0x00080032

    /// (0008,0033) - Content Time
    case contentTime = 0x00080033

    /// (0040,A040) - Value Type
    case valueType = 0x0040A040

    /// (0040,A010) - Relationship Type
    case relationshipType = 0x0040A010

    /// (0040,A043) - Concept Name Code Sequence
    case conceptNameCodeSequence = 0x0040A043

    /// (0040,A050) - Continuity of Content
    case continuityOfContent = 0x0040A050

    /// (0040,A120) - DateTime
    case dateTime = 0x0040A120

    /// (0040,A121) - Date
    case date = 0x0040A121

    /// (0040,A122) - Time
    case time = 0x0040A122

    /// (0040,A123) - Person Name
    case personName = 0x0040A123

    /// (0040,A124) - UID
    case uid = 0x0040A124

    /// (0040,A160) - Text Value
    case textValue = 0x0040A160

    /// (0040,A161) - Floating Point Value
    case floatingPointValue = 0x0040A161

    /// (0040,A162) - Rational Numerator Value
    case rationalNumeratorValue = 0x0040A162

    /// (0040,A163) - Rational Denominator Value
    case rationalDenominatorValue = 0x0040A163

    /// (0040,A168) - Concept Code Sequence
    case conceptCodeSequence = 0x0040A168

    /// (0040,A30A) - Numeric Value
    case numericValue = 0x0040A30A

    /// (0040,A300) - Measured Value Sequence
    case measuredValueSequence = 0x0040A300

    /// (0040,A375) - Current Requested Procedure Evidence Sequence
    case currentRequestedProcedureEvidenceSequence = 0x0040A375

    /// (0040,A385) - Pertinent Other Evidence Sequence
    case pertinentOtherEvidenceSequence = 0x0040A385

    /// (0040,A491) - Completion Flag
    case completionFlag = 0x0040A491

    /// (0040,A493) - Verification Flag
    case verificationFlag = 0x0040A493

    /// (0040,A504) - Content Template Sequence
    case contentTemplateSequence = 0x0040A504

    /// (0040,A730) - Content Sequence
    case contentSequence = 0x0040A730

    /// (0042,0010) - Document Title
    case documentTitle = 0x00420010

    /// (0042,0011) - Encapsulated Document
    case encapsulatedDocument = 0x00420011

    /// (0042,0012) - MIME Type of Encapsulated Document
    case mimeTypeOfEncapsulatedDocument = 0x00420012

    /// (0042,0013) - Source Instance Sequence
    case sourceInstanceSequence = 0x00420013

    /// (0042,0014) - List of MIME Types
    case listOfMIMETypes = 0x00420014

    /// (0042,0015) - Encapsulated Document Length
    case encapsulatedDocumentLength = 0x00420015

    /// (0040,DB00) - Template Identifier
    case templateIdentifier = 0x0040DB00

    // MARK: - Waveform

    /// (0018,1068) - Multiplex Group Time Offset
    case multiplexGroupTimeOffset = 0x00181068

    /// (0018,1069) - Trigger Time Offset
    case triggerTimeOffset = 0x00181069

    /// (0018,106E) - Trigger Sample Position
    case triggerSamplePosition = 0x0018106E

    /// (003A,0004) - Waveform Originality
    case waveformOriginality = 0x003A0004

    /// (003A,0005) - Number of Waveform Channels
    case numberOfWaveformChannels = 0x003A0005

    /// (003A,0010) - Number of Waveform Samples
    case numberOfWaveformSamples = 0x003A0010

    /// (003A,001A) - Sampling Frequency
    case samplingFrequency = 0x003A001A

    /// (003A,0020) - Multiplex Group Label
    case multiplexGroupLabel = 0x003A0020

    /// (003A,0200) - Channel Definition Sequence
    case channelDefinitionSequence = 0x003A0200

    /// (003A,0202) - Waveform Channel Number
    case waveformChannelNumber = 0x003A0202

    /// (003A,0203) - Channel Label
    case channelLabel = 0x003A0203

    /// (003A,0205) - Channel Status
    case channelStatus = 0x003A0205

    /// (003A,0208) - Channel Source Sequence
    case channelSourceSequence = 0x003A0208

    /// (003A,0209) - Channel Source Modifiers Sequence
    case channelSourceModifiersSequence = 0x003A0209

    /// (003A,020A) - Source Waveform Sequence
    case sourceWaveformSequence = 0x003A020A

    /// (003A,020C) - Channel Derivation Description
    case channelDerivationDescription = 0x003A020C

    /// (003A,0210) - Channel Sensitivity
    case channelSensitivity = 0x003A0210

    /// (003A,0211) - Channel Sensitivity Units Sequence
    case channelSensitivityUnitsSequence = 0x003A0211

    /// (003A,0212) - Channel Sensitivity Correction Factor
    case channelSensitivityCorrectionFactor = 0x003A0212

    /// (003A,0213) - Channel Baseline
    case channelBaseline = 0x003A0213

    /// (003A,0214) - Channel Time Skew
    case channelTimeSkew = 0x003A0214

    /// (003A,0215) - Channel Sample Skew
    case channelSampleSkew = 0x003A0215

    /// (003A,0218) - Channel Offset
    case channelOffset = 0x003A0218

    /// (003A,021A) - Waveform Bits Stored
    case waveformBitsStored = 0x003A021A

    /// (003A,0220) - Filter Low Frequency
    case filterLowFrequency = 0x003A0220

    /// (003A,0221) - Filter High Frequency
    case filterHighFrequency = 0x003A0221

    /// (003A,0222) - Notch Filter Frequency
    case notchFilterFrequency = 0x003A0222

    /// (003A,0230) - Waveform Data Display Scale
    case waveformDataDisplayScale = 0x003A0230

    /// (003A,0240) - Waveform Presentation Group Sequence
    case waveformPresentationGroupSequence = 0x003A0240

    /// (0040,A0B0) - Referenced Waveform Channels
    case referencedWaveformChannels = 0x0040A0B0

    /// (5400,0100) - Waveform Sequence
    case waveformSequence = 0x54000100

    /// (5400,1004) - Waveform Bits Allocated
    case waveformBitsAllocated = 0x54001004

    /// (5400,1006) - Waveform Sample Interpretation
    case waveformSampleInterpretation = 0x54001006

    /// (5400,100A) - Waveform Padding Value
    case waveformPaddingValue = 0x5400100A

    /// (5400,1010) - Waveform Data
    case waveformData = 0x54001010

    // MARK: - Content Identification

    /// (0070,0080) - Content Label
    case contentLabel = 0x00700080

    /// (0070,0081) - Content Description
    case contentDescription = 0x00700081

    /// (0070,0082) - Presentation Creation Date
    case presentationCreationDate = 0x00700082

    /// (0070,0083) - Presentation Creation Time
    case presentationCreationTime = 0x00700083

    /// (0070,0084) - Content Creator's Name
    case contentCreatorName = 0x00700084

    /// (0070,0100) - Presentation Size Mode
    case presentationSizeMode = 0x00700100

    /// (0070,0001) - Graphic Annotation Sequence
    case graphicAnnotationSequence = 0x00700001

    /// (0070,0002) - Graphic Layer
    case graphicLayer = 0x00700002

    /// (0070,0005) - Graphic Annotation Units
    case graphicAnnotationUnits = 0x00700005

    /// (0070,0006) - Unformatted Text Value
    case unformattedTextValue = 0x00700006

    /// (0070,0008) - Text Object Sequence
    case textObjectSequence = 0x00700008

    /// (0070,0009) - Graphic Object Sequence
    case graphicObjectSequence = 0x00700009

    /// (0070,0010) - Bounding Box Top Left Hand Corner
    case boundingBoxTopLeftHandCorner = 0x00700010

    /// (0070,0011) - Bounding Box Bottom Right Hand Corner
    case boundingBoxBottomRightHandCorner = 0x00700011

    /// (0070,0014) - Anchor Point
    case anchorPoint = 0x00700014

    /// (0070,0020) - Graphic Dimensions
    case graphicDimensions = 0x00700020

    /// (0070,0021) - Number of Graphic Points
    case numberOfGraphicPoints = 0x00700021

    /// (0070,0022) - Graphic Data
    case graphicData = 0x00700022

    /// (0070,0023) - Graphic Type
    case graphicType = 0x00700023

    /// (0070,0024) - Graphic Filled
    case graphicFilled = 0x00700024

    /// (0070,0052) - Displayed Area Top Left Hand Corner
    case displayedAreaTopLeftHandCorner = 0x00700052

    /// (0070,0053) - Displayed Area Bottom Right Hand Corner
    case displayedAreaBottomRightHandCorner = 0x00700053

    /// (0070,005A) - Displayed Area Selection Sequence
    case displayedAreaSelectionSequence = 0x0070005A

    /// (0070,0041) - Image Horizontal Flip
    case imageHorizontalFlip = 0x00700041

    /// (0070,0042) - Image Rotation
    case imageRotation = 0x00700042

    /// (0070,0060) - Graphic Layer Sequence
    case graphicLayerSequence = 0x00700060

    /// (0070,0062) - Graphic Layer Order
    case graphicLayerOrder = 0x00700062

    /// (0070,0066) - Graphic Layer Recommended Display Grayscale Value
    case graphicLayerRecommendedDisplayGrayscaleValue = 0x00700066

    /// (0070,0068) - Graphic Layer Description
    case graphicLayerDescription = 0x00700068

    /// (0070,0401) - Graphic Layer Recommended Display CIELab Value
    case graphicLayerRecommendedDisplayCIELabValue = 0x00700401

    // MARK: - Segmentation

    /// (0062,0001) - Segmentation Type
    case segmentationType = 0x00620001

    /// (0062,0002) - Segment Sequence
    case segmentSequence = 0x00620002

    /// (0062,0003) - Segmented Property Category Code Sequence
    case segmentedPropertyCategoryCodeSequence = 0x00620003

    /// (0062,0004) - Segment Number
    case segmentNumber = 0x00620004

    /// (0062,0005) - Segment Label
    case segmentLabel = 0x00620005

    /// (0062,0006) - Segment Description
    case segmentDescription = 0x00620006

    /// (0062,0008) - Segment Algorithm Type
    case segmentAlgorithmType = 0x00620008

    /// (0062,0009) - Segment Algorithm Name
    case segmentAlgorithmName = 0x00620009

    /// (0062,000A) - Segment Identification Sequence
    case segmentIdentificationSequence = 0x0062000A

    /// (0062,000B) - Referenced Segment Number
    case referencedSegmentNumber = 0x0062000B

    /// (0062,000D) - Recommended Display CIELab Value
    case recommendedDisplayCIELabValue = 0x0062000D

    /// (0062,000E) - Maximum Fractional Value
    case maximumFractionalValue = 0x0062000E

    /// (0062,000F) - Segmented Property Type Code Sequence
    case segmentedPropertyTypeCodeSequence = 0x0062000F

    /// (0062,0010) - Segmentation Fractional Type
    case segmentationFractionalType = 0x00620010

    /// (0062,0020) - Tracking ID
    case trackingID = 0x00620020

    /// (0062,0021) - Tracking UID
    case trackingUID = 0x00620021

    // MARK: - Radiotherapy Dose

    /// (3004,0002) - Dose Units
    case doseUnits = 0x30040002

    /// (3004,0004) - Dose Type
    case doseType = 0x30040004

    /// (3004,000A) - Dose Summation Type
    case doseSummationType = 0x3004000A

    /// (3004,000C) - Grid Frame Offset Vector
    case gridFrameOffsetVector = 0x3004000C

    /// (3004,000E) - Dose Grid Scaling
    case doseGridScaling = 0x3004000E

    // MARK: - Radiotherapy Structure Set

    /// (3006,0002) - Structure Set Label
    case structureSetLabel = 0x30060002

    /// (3006,0004) - Structure Set Name
    case structureSetName = 0x30060004

    /// (3006,0006) - Structure Set Description
    case structureSetDescription = 0x30060006

    /// (3006,0010) - Referenced Frame of Reference Sequence
    case referencedFrameOfReferenceSequence = 0x30060010

    /// (3006,0012) - RT Referenced Study Sequence
    case rtReferencedStudySequence = 0x30060012

    /// (3006,0014) - RT Referenced Series Sequence
    case rtReferencedSeriesSequence = 0x30060014

    /// (3006,0016) - Contour Image Sequence
    case contourImageSequence = 0x30060016

    /// (3006,0020) - Structure Set ROI Sequence
    case structureSetROISequence = 0x30060020

    /// (3006,0022) - ROI Number
    case roiNumber = 0x30060022

    /// (3006,0024) - Referenced Frame of Reference UID
    case referencedFrameOfReferenceUID = 0x30060024

    /// (3006,0026) - ROI Name
    case roiName = 0x30060026

    /// (3006,0028) - ROI Description
    case roiDescription = 0x30060028

    /// (3006,002A) - ROI Display Color
    case roiDisplayColor = 0x3006002A

    /// (3006,0036) - ROI Generation Algorithm
    case roiGenerationAlgorithm = 0x30060036

    /// (3006,0039) - ROI Contour Sequence
    case roiContourSequence = 0x30060039

    /// (3006,0040) - Contour Sequence
    case contourSequence = 0x30060040

    /// (3006,0042) - Contour Geometric Type
    case contourGeometricType = 0x30060042

    /// (3006,0046) - Number of Contour Points
    case numberOfContourPoints = 0x30060046

    /// (3006,0048) - Contour Number
    case contourNumber = 0x30060048

    /// (3006,0050) - Contour Data
    case contourData = 0x30060050

    /// (3006,0080) - RT ROI Observations Sequence
    case rtROIObservationsSequence = 0x30060080

    /// (3006,0082) - Observation Number
    case observationNumber = 0x30060082

    /// (3006,0084) - Referenced ROI Number
    case referencedROINumber = 0x30060084

    /// (3006,0085) - ROI Observation Label
    case roiObservationLabel = 0x30060085

    /// (3006,00A4) - RT ROI Interpreted Type
    case rtROIInterpretedType = 0x300600A4

    /// (3006,00A6) - ROI Interpreter
    case roiInterpreter = 0x300600A6

    // MARK: - Radiotherapy Plan

    /// (300A,0002) - RT Plan Label
    case rtPlanLabel = 0x300A0002

    /// (300A,0003) - RT Plan Name
    case rtPlanName = 0x300A0003

    /// (300A,0004) - RT Plan Description
    case rtPlanDescription = 0x300A0004

    /// (300A,000C) - RT Plan Geometry
    case rtPlanGeometry = 0x300A000C

    /// (300A,00B0) - Beam Sequence
    case beamSequence = 0x300A00B0

    /// (300A,00B2) - Treatment Machine Name
    case treatmentMachineName = 0x300A00B2

    /// (300A,00B3) - Primary Dosimeter Unit
    case primaryDosimeterUnit = 0x300A00B3

    /// (300A,00B4) - Source-Axis Distance
    case sourceAxisDistance = 0x300A00B4

    /// (300A,00C0) - Beam Number
    case beamNumber = 0x300A00C0

    /// (300A,00C2) - Beam Name
    case beamName = 0x300A00C2

    /// (300A,00C3) - Beam Description
    case beamDescription = 0x300A00C3

    /// (300A,00C4) - Beam Type
    case beamType = 0x300A00C4

    /// (300A,00C6) - Radiation Type
    case radiationType = 0x300A00C6

    /// (300A,0110) - Number of Control Points
    case numberOfControlPoints = 0x300A0110

    /// (300A,0111) - Control Point Sequence
    case controlPointSequence = 0x300A0111

    /// (300A,0112) - Control Point Index
    case controlPointIndex = 0x300A0112

    /// (300A,0114) - Nominal Beam Energy
    case nominalBeamEnergy = 0x300A0114

    /// (300A,011E) - Gantry Angle
    case gantryAngle = 0x300A011E

    /// (300A,0120) - Beam Limiting Device Angle
    case beamLimitingDeviceAngle = 0x300A0120

    /// (300A,0122) - Patient Support Angle
    case patientSupportAngle = 0x300A0122

    /// (300A,0125) - Table Top Eccentric Angle
    case tableTopEccentricAngle = 0x300A0125

    /// (300A,012C) - Isocenter Position
    case isocenterPosition = 0x300A012C

    /// (300A,0134) - Cumulative Meterset Weight
    case cumulativeMetersetWeight = 0x300A0134

    // MARK: - Acquisition Parameters

    /// (0018,5100) - Patient Position
    case patientPosition = 0x00185100

    /// (0018,0015) - Body Part Examined
    case bodyPartExamined = 0x00180015

    /// (0018,1072) - Radiopharmaceutical Start Time
    case radiopharmaceuticalStartTime = 0x00181072

    /// (0018,1074) - Radionuclide Total Dose
    case radionuclideTotalDose = 0x00181074

    /// (0018,1075) - Radionuclide Half Life
    case radionuclideHalfLife = 0x00181075

    /// (0018,1078) - Radiopharmaceutical Start DateTime
    case radiopharmaceuticalStartDateTime = 0x00181078

    /// (0028,0051) - Corrected Image
    case correctedImage = 0x00280051

    /// (0054,0016) - Radiopharmaceutical Information Sequence
    case radiopharmaceuticalInformationSequence = 0x00540016

    /// (0054,1001) - Units
    case units = 0x00541001

    /// (0054,1006) - SUV Type
    case suvType = 0x00541006

    /// (0054,1102) - Decay Correction
    case decayCorrection = 0x00541102

    /// (0054,1321) - Decay Factor
    case decayFactor = 0x00541321

    // MARK: - Secondary Capture

    /// (0018,1010) - Secondary Capture Device ID
    case secondaryCaptureDeviceID = 0x00181010

    /// (0018,1012) - Date of Secondary Capture
    case dateOfSecondaryCapture = 0x00181012

    /// (0018,1014) - Time of Secondary Capture
    case timeOfSecondaryCapture = 0x00181014

    /// (0018,1016) - Secondary Capture Device Manufacturer
    case secondaryCaptureDeviceManufacturer = 0x00181016

    /// (0018,1018) - Secondary Capture Device Manufacturer's Model Name
    case secondaryCaptureDeviceManufacturerModelName = 0x00181018

    /// (0018,1019) - Secondary Capture Device Software Version(s)
    case secondaryCaptureDeviceSoftwareVersions = 0x00181019

    // MARK: - Institutional Information

    /// (0008,0080) - Institution Name
    case institutionName = 0x00080080

    // MARK: - Transfer Syntax

    /// (0002,0010) - Transfer Syntax UID
    case transferSyntaxUID = 0x00020010

    // MARK: - Enhanced Multi-frame

    /// (5200,9229) - Shared Functional Groups Sequence
    case sharedFunctionalGroupsSequence = 0x52009229

    /// (5200,9230) - Per-frame Functional Groups Sequence
    case perFrameFunctionalGroupsSequence = 0x52009230
}

// MARK: - DICOM Value Representation (VR)

/// Value Representation codes expressed as their 16-bit ASCII representation.
///
/// ## Overview
///
/// ``DicomVR`` defines type-safe identifiers for DICOM Value Representations (VRs), which specify
/// the data type and encoding of DICOM data elements. Each VR is represented by a two-character
/// ASCII code (e.g., "AE", "AS", "AT") stored as a 16-bit integer. The VR determines how to
/// interpret the value field of a data element, including string encoding, numeric representation,
/// or binary format.
///
/// The enum includes all standard DICOM VRs plus special cases for implicit VR encoding and
/// unknown VRs. Each VR case includes its maximum length constraints and encoding rules as
/// defined in DICOM Part 5.
///
/// ## Usage
///
/// VRs are primarily used internally by the parser to interpret data element values:
///
/// ```swift
/// // VR determines how to parse the value field
/// if vr == .US {
///     // Parse as unsigned 16-bit integer
/// } else if vr == .DS {
///     // Parse as decimal string
/// }
/// ```
///
/// Check if a VR requires a 32-bit length field:
///
/// ```swift
/// if vr.uses32BitLength {
///     // Read 32-bit length for OB, OW, SQ, UN, UT
/// }
/// ```
///
/// ## Topics
///
/// ### String Types
///
/// - ``AE``
/// - ``AS``
/// - ``CS``
/// - ``DA``
/// - ``DS``
/// - ``DT``
/// - ``LO``
/// - ``LT``
/// - ``PN``
/// - ``SH``
/// - ``ST``
/// - ``TM``
/// - ``UI``
/// - ``UT``
///
/// ### Numeric Types
///
/// - ``FD``
/// - ``FL``
/// - ``IS``
/// - ``SL``
/// - ``SS``
/// - ``UL``
/// - ``US``
///
/// ### Binary Types
///
/// - ``OB``
/// - ``OW``
/// - ``SQ``
/// - ``UN``
///
/// ### Helper Methods
///
/// - ``uses32BitLength``
public enum DicomVR: Int, Sendable {

    // MARK: - String Types

    /// Application Entity (max 16 chars)
    case AE = 0x4145

    /// Age String (4 chars fixed)
    case AS = 0x4153

    /// Attribute Tag (4 bytes)
    case AT = 0x4154

    /// Code String (max 16 chars)
    case CS = 0x4353

    /// Date (8 bytes fixed, YYYYMMDD)
    case DA = 0x4441

    /// Decimal String (max 16 chars)
    case DS = 0x4453

    /// Date Time (max 26 chars)
    case DT = 0x4454

    /// Long String (max 64 chars)
    case LO = 0x4C4F

    /// Long Text (max 10240 chars)
    case LT = 0x4C54

    /// Person Name (max 64 chars per component)
    case PN = 0x504E

    /// Short String (max 16 chars)
    case SH = 0x5348

    /// Short Text (max 1024 chars)
    case ST = 0x5354

    /// Time (max 16 chars)
    case TM = 0x544D

    /// Unique Identifier (max 64 chars)
    case UI = 0x5549

    /// Universal Resource Identifier or Locator
    case UR = 0x5552

    /// Unlimited Text (max 2^32-2 chars)
    case UT = 0x5554

    // MARK: - Numeric Types

    /// Floating Point Double (8 bytes)
    case FD = 0x4644

    /// Floating Point Single (4 bytes)
    case FL = 0x464C

    /// Integer String (max 12 chars)
    case IS = 0x4953

    /// Signed Long (4 bytes)
    case SL = 0x534C

    /// Signed Short (2 bytes)
    case SS = 0x5353

    /// Unsigned Long (4 bytes)
    case UL = 0x554C

    /// Unsigned Short (2 bytes)
    case US = 0x5553

    // MARK: - Binary Types

    /// Other Byte (variable length)
    case OB = 0x4F42

    /// Other Double (variable length)
    case OD = 0x4F44

    /// Other Float (variable length)
    case OF = 0x4F46

    /// Other Word (variable length)
    case OW = 0x4F57

    /// Other 64-bit Very Long (variable length)
    case OV = 0x4F56

    /// Sequence of Items
    case SQ = 0x5351

    /// Unknown (variable length)
    case UN = 0x554E

    // MARK: - Special Cases

    /// Query/Retrieve Level (retired)
    case QQ = 0x3F3F

    /// Retired (variable length)
    case RT = 0x5254

    /// Implicit VR (represented as "--")
    case implicitRaw = 0x2D2D

    /// Unknown or unrecognized VR
    case unknown = 0

    // MARK: - Helper Methods

    /// Returns true if this VR expects a 32-bit length field when
    /// using explicit VR encoding. Most VRs use 16-bit length
    /// fields, but OB, OW, SQ, UN, and UT require 32-bit lengths
    /// to accommodate larger data elements.
    public var uses32BitLength: Bool {
        switch self {
        case .OB, .OD, .OF, .OW, .OV, .SQ, .UN, .UR, .UT:
            return true
        default:
            return false
        }
    }
}

// MARK: - DICOM Transfer Syntax UIDs

/// DICOM transfer syntax unique identifiers (UIDs) as defined in DICOM Part 5.
///
/// ## Overview
///
/// ``DicomTransferSyntax`` defines type-safe identifiers for DICOM transfer syntaxes, which specify
/// the encoding rules used for a DICOM file. Transfer syntaxes control three key aspects:
///
/// 1. **Byte Ordering**: Little-endian (most common) or big-endian (retired)
/// 2. **VR Encoding**: Explicit VR (includes VR code) or Implicit VR (requires dictionary lookup)
/// 3. **Compression**: Uncompressed or compressed (JPEG, JPEG 2000, HTJ2K, JPEG-LS, RLE)
///
/// The library fully supports uncompressed transfer syntaxes and selected compressed syntaxes
/// through native JPEG Lossless/RLE decoding, JPEG-LS decoding when the CharLS runtime is
/// available, and explicit JPEG/JPEG 2000 decode paths when
/// platform support can preserve the requested pixel precision.
///
/// ## Usage
///
/// Transfer syntaxes are typically read from the DICOM file header and used to configure parsing:
///
/// ```swift
/// // Check transfer syntax from DICOM metadata
/// if let tsUID = decoder.info(for: .transferSyntaxUID),
///    let ts = DicomTransferSyntax(uid: tsUID) {
///     if ts.isCompressed {
///         print("Compressed: \(ts.rawValue)")
///     }
///     if ts.isBigEndian {
///         print("Big-endian encoding")
///     }
/// }
/// ```
///
/// Check compression status:
///
/// ```swift
/// let syntax = DicomTransferSyntax.jpegLossless
/// if syntax.isCompressed {
///     // Requires decompression
/// }
/// ```
///
/// ## Topics
///
/// ### Uncompressed Transfer Syntaxes
///
/// - ``implicitVRLittleEndian``
/// - ``explicitVRLittleEndian``
/// - ``explicitVRBigEndian``
///
/// ### JPEG Compressed Transfer Syntaxes
///
/// - ``jpegBaseline``
/// - ``jpegExtended``
/// - ``jpegLossless``
/// - ``jpegLosslessFirstOrder``
///
/// ### JPEG-LS Compressed Transfer Syntaxes
///
/// - ``jpegLSLossless``
/// - ``jpegLSNearLossless``
///
/// ### JPEG 2000 Compressed Transfer Syntaxes
///
/// - ``jpeg2000Lossless``
/// - ``jpeg2000``
/// - ``jpeg2000Part2MulticomponentLossless``
/// - ``jpeg2000Part2Multicomponent``
///
/// ### HTJ2K Compressed Transfer Syntaxes
///
/// - ``htj2kLossless``
/// - ``htj2kLosslessRPCL``
/// - ``htj2k``
///
/// ### RLE Compressed Transfer Syntax
///
/// - ``rleLossless``
///
/// ### Helper Methods
///
/// - ``isCompressed``
/// - ``isBigEndian``
/// - ``isExplicitVR``
/// - ``init(uid:)``
/// - ``matches(_:)``
public enum DicomTransferSyntax: String, CaseIterable, Sendable {
    private static let uidPaddingCharacters = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "\0")
    )

    // MARK: - Uncompressed Transfer Syntaxes

    /// Implicit VR Little Endian (Default Transfer Syntax for DICOM)
    /// UID: 1.2.840.10008.1.2
    case implicitVRLittleEndian = "1.2.840.10008.1.2"

    /// Explicit VR Little Endian
    /// UID: 1.2.840.10008.1.2.1
    case explicitVRLittleEndian = "1.2.840.10008.1.2.1"

    /// Deflated Explicit VR Little Endian
    /// UID: 1.2.840.10008.1.2.1.99
    case deflatedExplicitVRLittleEndian = "1.2.840.10008.1.2.1.99"

    /// Explicit VR Big Endian (Retired)
    /// UID: 1.2.840.10008.1.2.2
    case explicitVRBigEndian = "1.2.840.10008.1.2.2"

    // MARK: - JPEG Compressed Transfer Syntaxes

    /// JPEG Baseline (Process 1): Default Transfer Syntax for Lossy
    /// JPEG 8 Bit Image Compression
    /// UID: 1.2.840.10008.1.2.4.50
    case jpegBaseline = "1.2.840.10008.1.2.4.50"

    /// JPEG Extended (Process 2 & 4): Default Transfer Syntax for
    /// Lossy JPEG 12 Bit Image Compression
    /// UID: 1.2.840.10008.1.2.4.51
    case jpegExtended = "1.2.840.10008.1.2.4.51"

    /// JPEG Lossless, Non-Hierarchical (Process 14)
    /// UID: 1.2.840.10008.1.2.4.57
    case jpegLossless = "1.2.840.10008.1.2.4.57"

    /// JPEG Lossless, Non-Hierarchical, First-Order Prediction
    /// (Process 14 [Selection Value 1])
    /// UID: 1.2.840.10008.1.2.4.70
    case jpegLosslessFirstOrder = "1.2.840.10008.1.2.4.70"

    // MARK: - JPEG-LS Compressed Transfer Syntaxes

    /// JPEG-LS Lossless Image Compression
    /// UID: 1.2.840.10008.1.2.4.80
    case jpegLSLossless = "1.2.840.10008.1.2.4.80"

    /// JPEG-LS Lossy (Near-Lossless) Image Compression
    /// UID: 1.2.840.10008.1.2.4.81
    case jpegLSNearLossless = "1.2.840.10008.1.2.4.81"

    // MARK: - JPEG 2000 Compressed Transfer Syntaxes

    /// JPEG 2000 Image Compression (Lossless Only)
    /// UID: 1.2.840.10008.1.2.4.90
    case jpeg2000Lossless = "1.2.840.10008.1.2.4.90"

    /// JPEG 2000 Image Compression
    /// UID: 1.2.840.10008.1.2.4.91
    case jpeg2000 = "1.2.840.10008.1.2.4.91"

    /// JPEG 2000 Part 2 Multi-component Image Compression (Lossless Only)
    /// UID: 1.2.840.10008.1.2.4.92
    case jpeg2000Part2MulticomponentLossless = "1.2.840.10008.1.2.4.92"

    /// JPEG 2000 Part 2 Multi-component Image Compression
    /// UID: 1.2.840.10008.1.2.4.93
    case jpeg2000Part2Multicomponent = "1.2.840.10008.1.2.4.93"

    /// DICOM JPIP Referenced Transfer Syntax (Explicit VR)
    /// UID: 1.2.840.10008.1.2.4.94
    case jpipReferenced = "1.2.840.10008.1.2.4.94"

    /// DICOM JPIP Referenced Deflate Transfer Syntax (Explicit VR)
    /// UID: 1.2.840.10008.1.2.4.95
    case jpipReferencedDeflate = "1.2.840.10008.1.2.4.95"

    // MARK: - Video Compressed Transfer Syntaxes

    /// MPEG2 Main Profile / Main Level
    /// UID: 1.2.840.10008.1.2.4.100
    case mpeg2MainProfileMainLevel = "1.2.840.10008.1.2.4.100"

    /// Fragmentable MPEG2 Main Profile / Main Level
    /// UID: 1.2.840.10008.1.2.4.100.1
    case mpeg2MainProfileMainLevelFragmentable = "1.2.840.10008.1.2.4.100.1"

    /// MPEG2 Main Profile / High Level
    /// UID: 1.2.840.10008.1.2.4.101
    case mpeg2MainProfileHighLevel = "1.2.840.10008.1.2.4.101"

    /// Fragmentable MPEG2 Main Profile / High Level
    /// UID: 1.2.840.10008.1.2.4.101.1
    case mpeg2MainProfileHighLevelFragmentable = "1.2.840.10008.1.2.4.101.1"

    /// MPEG-4 AVC/H.264 High Profile / Level 4.1
    /// UID: 1.2.840.10008.1.2.4.102
    case mpeg4AVCH264HighProfileLevel41 = "1.2.840.10008.1.2.4.102"

    /// Fragmentable MPEG-4 AVC/H.264 High Profile / Level 4.1
    /// UID: 1.2.840.10008.1.2.4.102.1
    case mpeg4AVCH264HighProfileLevel41Fragmentable = "1.2.840.10008.1.2.4.102.1"

    /// MPEG-4 AVC/H.264 BD-compatible High Profile / Level 4.1
    /// UID: 1.2.840.10008.1.2.4.103
    case mpeg4AVCH264BDCompatibleHighProfileLevel41 = "1.2.840.10008.1.2.4.103"

    /// Fragmentable MPEG-4 AVC/H.264 BD-compatible High Profile / Level 4.1
    /// UID: 1.2.840.10008.1.2.4.103.1
    case mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable = "1.2.840.10008.1.2.4.103.1"

    /// MPEG-4 AVC/H.264 High Profile / Level 4.2 For 2D Video
    /// UID: 1.2.840.10008.1.2.4.104
    case mpeg4AVCH264HighProfileLevel42For2DVideo = "1.2.840.10008.1.2.4.104"

    /// Fragmentable MPEG-4 AVC/H.264 High Profile / Level 4.2 For 2D Video
    /// UID: 1.2.840.10008.1.2.4.104.1
    case mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable = "1.2.840.10008.1.2.4.104.1"

    /// MPEG-4 AVC/H.264 High Profile / Level 4.2 For 3D Video
    /// UID: 1.2.840.10008.1.2.4.105
    case mpeg4AVCH264HighProfileLevel42For3DVideo = "1.2.840.10008.1.2.4.105"

    /// Fragmentable MPEG-4 AVC/H.264 High Profile / Level 4.2 For 3D Video
    /// UID: 1.2.840.10008.1.2.4.105.1
    case mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable = "1.2.840.10008.1.2.4.105.1"

    /// MPEG-4 AVC/H.264 Stereo High Profile / Level 4.2
    /// UID: 1.2.840.10008.1.2.4.106
    case mpeg4AVCH264StereoHighProfileLevel42 = "1.2.840.10008.1.2.4.106"

    /// Fragmentable MPEG-4 AVC/H.264 Stereo High Profile / Level 4.2
    /// UID: 1.2.840.10008.1.2.4.106.1
    case mpeg4AVCH264StereoHighProfileLevel42Fragmentable = "1.2.840.10008.1.2.4.106.1"

    /// HEVC/H.265 Main Profile / Level 5.1
    /// UID: 1.2.840.10008.1.2.4.107
    case hevcH265MainProfileLevel51 = "1.2.840.10008.1.2.4.107"

    /// HEVC/H.265 Main 10 Profile / Level 5.1
    /// UID: 1.2.840.10008.1.2.4.108
    case hevcH265Main10ProfileLevel51 = "1.2.840.10008.1.2.4.108"

    // MARK: - JPEG XL Compressed Transfer Syntaxes

    /// JPEG XL Lossless
    /// UID: 1.2.840.10008.1.2.4.110
    case jpegXLLossless = "1.2.840.10008.1.2.4.110"

    /// JPEG XL JPEG Recompression
    /// UID: 1.2.840.10008.1.2.4.111
    case jpegXLJPEGRecompression = "1.2.840.10008.1.2.4.111"

    /// JPEG XL (lossy, lossless, or JPEG recompression)
    /// UID: 1.2.840.10008.1.2.4.112
    case jpegXL = "1.2.840.10008.1.2.4.112"

    // MARK: - High-Throughput JPEG 2000 Compressed Transfer Syntaxes

    /// High-Throughput JPEG 2000 Image Compression (Lossless Only)
    /// UID: 1.2.840.10008.1.2.4.201
    case htj2kLossless = "1.2.840.10008.1.2.4.201"

    /// High-Throughput JPEG 2000 Image Compression (Lossless RPCL)
    /// UID: 1.2.840.10008.1.2.4.202
    case htj2kLosslessRPCL = "1.2.840.10008.1.2.4.202"

    /// High-Throughput JPEG 2000 Image Compression
    /// UID: 1.2.840.10008.1.2.4.203
    case htj2k = "1.2.840.10008.1.2.4.203"

    // MARK: - RLE Compressed Transfer Syntax

    /// RLE Lossless
    /// UID: 1.2.840.10008.1.2.5
    case rleLossless = "1.2.840.10008.1.2.5"

    // MARK: - Helper Methods

    /// Returns true if this transfer syntax requires decompression
    /// before pixel data can be accessed. The decoder currently
    /// supports limited decompression through explicit native and
    /// ImageIO-backed compressed pixel backends.
    public var isCompressed: Bool {
        switch self {
        case .implicitVRLittleEndian,
             .explicitVRLittleEndian,
             .explicitVRBigEndian,
             .jpipReferenced:
            return false
        case .jpegBaseline,
             .jpegExtended,
             .jpegLossless,
             .jpegLosslessFirstOrder,
             .jpegLSLossless,
             .jpegLSNearLossless,
             .jpeg2000Lossless,
             .jpeg2000,
             .jpeg2000Part2MulticomponentLossless,
             .jpeg2000Part2Multicomponent,
             .deflatedExplicitVRLittleEndian,
             .jpipReferencedDeflate,
             .mpeg2MainProfileMainLevel,
             .mpeg2MainProfileMainLevelFragmentable,
             .mpeg2MainProfileHighLevel,
             .mpeg2MainProfileHighLevelFragmentable,
             .mpeg4AVCH264HighProfileLevel41,
             .mpeg4AVCH264HighProfileLevel41Fragmentable,
             .mpeg4AVCH264BDCompatibleHighProfileLevel41,
             .mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable,
             .mpeg4AVCH264HighProfileLevel42For2DVideo,
             .mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable,
             .mpeg4AVCH264HighProfileLevel42For3DVideo,
             .mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable,
             .mpeg4AVCH264StereoHighProfileLevel42,
             .mpeg4AVCH264StereoHighProfileLevel42Fragmentable,
             .hevcH265MainProfileLevel51,
             .hevcH265Main10ProfileLevel51,
             .jpegXLLossless,
             .jpegXLJPEGRecompression,
             .jpegXL,
             .htj2kLossless,
             .htj2kLosslessRPCL,
             .htj2k,
             .rleLossless:
            return true
        }
    }

    /// Returns true if this transfer syntax uses big-endian byte
    /// ordering. Most DICOM files use little-endian encoding; big
    /// endian is rare and has been retired from the standard.
    public var isBigEndian: Bool {
        switch self {
        case .explicitVRBigEndian:
            return true
        default:
            return false
        }
    }

    /// Returns true if this transfer syntax uses explicit VR encoding.
    /// Explicit VR includes the two-character VR code in each data
    /// element, while implicit VR requires a data dictionary lookup.
    public var isExplicitVR: Bool {
        switch self {
        case .implicitVRLittleEndian:
            return false
        default:
            // All other transfer syntaxes use explicit VR
            return true
        }
    }

    /// Initializes a transfer syntax from a UID string. Returns nil
    /// if the UID is not recognized. The UID string may contain
    /// trailing whitespace or null characters, which are automatically
    /// trimmed.
    ///
    /// - Parameter uid: The transfer syntax UID string
    public init?(uid: String) {
        let trimmed = uid.trimmingCharacters(in: Self.uidPaddingCharacters)
        self.init(rawValue: trimmed)
    }

    /// Returns true if the UID string matches this transfer syntax,
    /// accounting for potential trailing whitespace or null padding.
    ///
    /// - Parameter uid: The UID string to check
    /// - Returns: True if the UID matches this transfer syntax
    public func matches(_ uid: String) -> Bool {
        let trimmed = uid.trimmingCharacters(in: Self.uidPaddingCharacters)
        return self.rawValue == trimmed
    }

    /// True when the DICOM dataset references pixel data by URL instead of carrying
    /// a local Pixel Data element.
    public var usesPixelDataProviderURL: Bool {
        switch self {
        case .jpipReferenced, .jpipReferencedDeflate:
            return true
        default:
            return false
        }
    }

    /// True when the Part 10 dataset payload after file meta information
    /// is deflated while the file meta information remains explicit VR little endian.
    public var usesDataSetDeflate: Bool {
        switch self {
        case .deflatedExplicitVRLittleEndian, .jpipReferencedDeflate:
            return true
        default:
            return false
        }
    }
}
