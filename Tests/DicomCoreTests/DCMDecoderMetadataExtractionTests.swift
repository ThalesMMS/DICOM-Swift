//
//  DCMDecoderMetadataExtractionTests.swift
//  DicomCoreTests
//
//  Checks complete tag extraction and the dictionary returned by decoder metadata access.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class DCMDecoderMetadataExtractionTests: XCTestCase {
    // MARK: - Metadata Extraction Tests

    func testCommonDICOMTagsExtraction() {
        let decoder = DCMDecoder()

        XCTAssertEqual(decoder.info(for: .patientName), "", "Patient Name should return empty string")
        XCTAssertEqual(decoder.info(for: .patientID), "", "Patient ID should return empty string")
        XCTAssertEqual(decoder.info(for: 0x00100030), "", "Patient Birth Date should return empty string")
        XCTAssertEqual(decoder.info(for: .patientSex), "", "Patient Sex should return empty string")
        XCTAssertEqual(decoder.info(for: .studyInstanceUID), "", "Study Instance UID should return empty string")
        XCTAssertEqual(decoder.info(for: .studyDate), "", "Study Date should return empty string")
        XCTAssertEqual(decoder.info(for: .studyTime), "", "Study Time should return empty string")
        XCTAssertEqual(decoder.info(for: .studyDescription), "", "Study Description should return empty string")
        XCTAssertNil(decoder.intValue(for: .rows), "Rows should return nil")
        XCTAssertNil(decoder.intValue(for: .columns), "Columns should return nil")
        XCTAssertEqual(decoder.info(for: .modality), "", "Modality should return empty string")
    }

    func testPatientInformationTagsExtraction() {
        let decoder = DCMDecoder()

        XCTAssertEqual(decoder.info(for: .patientName), "", "Patient Name should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .patientID), "", "Patient ID should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: 0x00100030), "", "Patient Birth Date should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .patientSex), "", "Patient Sex should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .patientAge), "", "Patient Age should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: 0x00101030), "", "Patient Weight should be empty for uninitialized decoder")
    }

    func testStudyInformationTagsExtraction() {
        let decoder = DCMDecoder()

        XCTAssertEqual(decoder.info(for: .studyInstanceUID), "", "Study Instance UID should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .studyID), "", "Study ID should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .studyDate), "", "Study Date should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .studyTime), "", "Study Time should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .studyDescription), "", "Study Description should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .referringPhysicianName), "", "Referring Physician should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: 0x00080050), "", "Accession Number should be empty for uninitialized decoder")
    }

    func testSeriesInformationTagsExtraction() {
        let decoder = DCMDecoder()

        XCTAssertEqual(decoder.info(for: .seriesInstanceUID), "", "Series Instance UID should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .seriesNumber), "", "Series Number should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .seriesDate), "", "Series Date should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .seriesTime), "", "Series Time should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .seriesDescription), "", "Series Description should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .modality), "", "Modality should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .bodyPartExamined), "", "Body Part Examined should be empty for uninitialized decoder")
    }

    func testImageInformationTagsExtraction() {
        let decoder = DCMDecoder()

        XCTAssertNil(decoder.intValue(for: .rows), "Rows should return nil for uninitialized decoder")
        XCTAssertNil(decoder.intValue(for: .columns), "Columns should return nil for uninitialized decoder")
        XCTAssertNil(decoder.intValue(for: .bitsAllocated), "Bits Allocated should return nil for uninitialized decoder")
        XCTAssertNil(decoder.intValue(for: .bitsStored), "Bits Stored should return nil for uninitialized decoder")
        XCTAssertNil(decoder.intValue(for: .highBit), "High Bit should return nil for uninitialized decoder")
        XCTAssertNil(decoder.intValue(for: .samplesPerPixel), "Samples Per Pixel should return nil for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .photometricInterpretation), "", "Photometric Interpretation should be empty for uninitialized decoder")
        XCTAssertNil(decoder.intValue(for: .pixelRepresentation), "Pixel Representation should return nil for uninitialized decoder")
    }

    func testImagePositionOrientationTagsExtraction() {
        let decoder = DCMDecoder()

        XCTAssertEqual(decoder.info(for: .imagePositionPatient), "", "Image Position (Patient) should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .imageOrientationPatient), "", "Image Orientation (Patient) should be empty for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: 0x00201041), "Slice Location should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: .sliceThickness), "Slice Thickness should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: .pixelSpacing), "Pixel Spacing should return nil for uninitialized decoder")
    }

    func testWindowingTagsExtraction() {
        let decoder = DCMDecoder()

        XCTAssertNil(decoder.doubleValue(for: .windowCenter), "Window Center should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: .windowWidth), "Window Width should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: .rescaleIntercept), "Rescale Intercept should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: .rescaleSlope), "Rescale Slope should return nil for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: 0x00281054), "", "Rescale Type should be empty for uninitialized decoder")
    }

    func testModalitySpecificTagsExtraction() {
        let decoder = DCMDecoder()

        XCTAssertNil(decoder.doubleValue(for: 0x00180060), "KVP should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: 0x00181150), "Exposure Time should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: 0x00181151), "X-Ray Tube Current should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: 0x00180080), "Repetition Time should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: 0x00180081), "Echo Time should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: 0x00180087), "Magnetic Field Strength should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: 0x00180084), "Imaging Frequency should return nil for uninitialized decoder")
    }

    func testEquipmentInformationTagsExtraction() {
        let decoder = DCMDecoder()

        XCTAssertEqual(decoder.info(for: 0x00080070), "", "Manufacturer should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: 0x00081090), "", "Manufacturer Model Name should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: 0x00081010), "", "Station Name should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .institutionName), "", "Institution Name should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: 0x00181020), "", "Software Versions should be empty for uninitialized decoder")
    }

    func testInstanceInformationTagsExtraction() {
        let decoder = DCMDecoder()

        XCTAssertEqual(decoder.info(for: .sopInstanceUID), "", "SOP Instance UID should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: 0x00080016), "", "SOP Class UID should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .instanceNumber), "", "Instance Number should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .contentDate), "", "Content Date should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .contentTime), "", "Content Time should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .acquisitionDate), "", "Acquisition Date should be empty for uninitialized decoder")
        XCTAssertEqual(decoder.info(for: .acquisitionTime), "", "Acquisition Time should be empty for uninitialized decoder")
    }

    func testTagDataTypeValidation() {
        let decoder = DCMDecoder()

        XCTAssertTrue(decoder.info(for: .patientName).isEmpty, "info() should return empty string for uninitialized decoder")
        XCTAssertNil(decoder.intValue(for: .rows), "intValue() should return nil for uninitialized decoder")
        XCTAssertNil(decoder.doubleValue(for: .pixelSpacing), "doubleValue() should return nil for uninitialized decoder")
    }

    func testMissingTagHandling() {
        let decoder = DCMDecoder()

        XCTAssertEqual(decoder.info(for: 0xFFFFFFFF), "", "Non-existent tag should return empty string")
        XCTAssertEqual(decoder.info(for: 0x00000000), "", "Zero tag should return empty string")
        XCTAssertNil(decoder.intValue(for: 0xFFFFFFFF), "Non-existent tag should return nil for intValue")
        XCTAssertNil(decoder.doubleValue(for: 0xFFFFFFFF), "Non-existent tag should return nil for doubleValue")
    }

    func testMetadataExtractionConsistency() {
        let decoder = DCMDecoder()

        XCTAssertEqual(decoder.info(for: .patientName), decoder.info(for: .patientName), "Multiple calls should return consistent results")
        XCTAssertEqual(decoder.intValue(for: .rows), decoder.intValue(for: .rows), "Multiple intValue calls should return consistent results")
        XCTAssertEqual(decoder.doubleValue(for: .pixelSpacing), decoder.doubleValue(for: .pixelSpacing), "Multiple doubleValue calls should return consistent results")
    }

    func testGetAllTagsReturnsValidDictionary() {
        let decoder = DCMDecoder()
        let allTags = decoder.getAllTags()

        XCTAssertNotNil(allTags, "getAllTags should return a non-nil dictionary")
        XCTAssertTrue(allTags.isEmpty, "getAllTags should be empty for uninitialized decoder")
    }

    func testPatientInfoDictionaryStructure() {
        let decoder = DCMDecoder()
        let patientInfo = decoder.getPatientInfo()

        XCTAssertNotNil(patientInfo["Name"], "Patient info should have Name key")
        XCTAssertNotNil(patientInfo["ID"], "Patient info should have ID key")
        XCTAssertNotNil(patientInfo["Sex"], "Patient info should have Sex key")
        XCTAssertNotNil(patientInfo["Age"], "Patient info should have Age key")
    }

    func testStudyInfoDictionaryStructure() {
        let decoder = DCMDecoder()
        let studyInfo = decoder.getStudyInfo()

        XCTAssertNotNil(studyInfo["StudyInstanceUID"], "Study info should have StudyInstanceUID key")
        XCTAssertNotNil(studyInfo["StudyID"], "Study info should have StudyID key")
        XCTAssertNotNil(studyInfo["StudyDate"], "Study info should have StudyDate key")
        XCTAssertNotNil(studyInfo["StudyTime"], "Study info should have StudyTime key")
        XCTAssertNotNil(studyInfo["StudyDescription"], "Study info should have StudyDescription key")
        XCTAssertNotNil(studyInfo["ReferringPhysician"], "Study info should have ReferringPhysician key")
    }

    func testSeriesInfoDictionaryStructure() {
        let decoder = DCMDecoder()
        let seriesInfo = decoder.getSeriesInfo()

        XCTAssertNotNil(seriesInfo["SeriesInstanceUID"], "Series info should have SeriesInstanceUID key")
        XCTAssertNotNil(seriesInfo["SeriesNumber"], "Series info should have SeriesNumber key")
        XCTAssertNotNil(seriesInfo["SeriesDate"], "Series info should have SeriesDate key")
        XCTAssertNotNil(seriesInfo["SeriesTime"], "Series info should have SeriesTime key")
        XCTAssertNotNil(seriesInfo["SeriesDescription"], "Series info should have SeriesDescription key")
        XCTAssertNotNil(seriesInfo["Modality"], "Series info should have Modality key")
    }

    // MARK: - Memory and Performance Tests

    func testMetadataAccessPerformance() {
        let decoder = DCMDecoder()

        // Measure overall metadata access performance
        measure {
            for _ in 0..<1000 {
                _ = decoder.info(for: DicomTag.patientName.rawValue)
                _ = decoder.info(for: DicomTag.studyDate.rawValue)
                _ = decoder.intValue(for: DicomTag.rows.rawValue)
                _ = decoder.doubleValue(for: DicomTag.rescaleSlope.rawValue)
                _ = decoder.rescaleParametersV2
                _ = decoder.windowSettingsV2
            }
        }
    }
}
