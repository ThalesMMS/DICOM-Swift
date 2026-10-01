#if DEBUG

import Foundation

enum MetadataPreviewFixtures {
    static let ct = MockDicomDecoderForPreviews(
        width: 512,
        height: 512,
        bitDepth: 16,
        samplesPerPixel: 1,
        windowCenter: -600.0,
        windowWidth: 1500.0,
        pixelWidth: 0.7,
        pixelHeight: 0.7,
        pixelDepth: 5.0,
        metadata: [
            "00100010": "Smith^John",           // Patient Name
            "00100020": "CT123456",             // Patient ID
            "00100040": "M",                    // Patient Sex
            "00101010": "055Y",                 // Patient Age
            "00081030": "CT Chest",             // Study Description
            "00080020": "20240215",             // Study Date
            "00080030": "143025",               // Study Time
            "00200010": "STU20240215143025",    // Study ID
            "00080060": "CT",                   // Modality
            "00080080": "General Hospital",     // Institution Name
            "0008103E": "Lung Window",          // Series Description
            "00200011": "1",                    // Series Number
            "00200013": "42",                   // Instance Number
            "00201209": "125",                  // Number of Series Related Instances
            "00180050": "5.0",                  // Slice Thickness
            "00280100": "16",                   // Bits Allocated
            "00280004": "MONOCHROME2"           // Photometric Interpretation
        ]
    )

    static let mri = MockDicomDecoderForPreviews(
        width: 256,
        height: 256,
        bitDepth: 16,
        samplesPerPixel: 1,
        windowCenter: 600.0,
        windowWidth: 1200.0,
        pixelWidth: 0.9,
        pixelHeight: 0.9,
        pixelDepth: 3.0,
        metadata: [
            "00100010": "Doe^Jane",             // Patient Name
            "00100020": "MR789012",             // Patient ID
            "00100040": "F",                    // Patient Sex
            "00101010": "032Y",                 // Patient Age
            "00081030": "MRI Brain",            // Study Description
            "00080020": "20240214",             // Study Date
            "00080030": "091530",               // Study Time
            "00200010": "STU20240214091530",    // Study ID
            "00080060": "MR",                   // Modality
            "00080080": "University Medical",   // Institution Name
            "0008103E": "T1 Weighted",          // Series Description
            "00200011": "2",                    // Series Number
            "00200013": "18",                   // Instance Number
            "00201209": "80",                   // Number of Series Related Instances
            "00180050": "3.0",                  // Slice Thickness
            "00280100": "16",                   // Bits Allocated
            "00280004": "MONOCHROME2"           // Photometric Interpretation
        ]
    )

    static let xray = MockDicomDecoderForPreviews(
        width: 1024,
        height: 1024,
        bitDepth: 16,
        samplesPerPixel: 1,
        windowCenter: 2000.0,
        windowWidth: 4000.0,
        pixelWidth: 0.2,
        pixelHeight: 0.2,
        pixelDepth: 1.0,
        metadata: [
            "00100010": "Johnson^Robert",       // Patient Name
            "00100020": "XR345678",             // Patient ID
            "00100040": "M",                    // Patient Sex
            "00101010": "047Y",                 // Patient Age
            "00081030": "Chest X-Ray",          // Study Description
            "00080020": "20240216",             // Study Date
            "00080030": "161045",               // Study Time
            "00200010": "STU20240216161045",    // Study ID
            "00080060": "CR",                   // Modality (Computed Radiography)
            "00080080": "City Imaging Center",  // Institution Name
            "0008103E": "PA View",              // Series Description
            "00200011": "1",                    // Series Number
            "00200013": "1",                    // Instance Number
            "00201209": "1",                    // Number of Series Related Instances
            "00180050": "1.0",                  // Slice Thickness
            "00280100": "16",                   // Bits Allocated
            "00280004": "MONOCHROME2"           // Photometric Interpretation
        ]
    )

    static let ultrasound = MockDicomDecoderForPreviews(
        width: 640,
        height: 480,
        bitDepth: 8,
        samplesPerPixel: 1,
        windowCenter: 128.0,
        windowWidth: 256.0,
        pixelWidth: 0.1,
        pixelHeight: 0.1,
        pixelDepth: 1.0,
        metadata: [
            "00100010": "Williams^Mary",        // Patient Name
            "00100020": "US901234",             // Patient ID
            "00100040": "F",                    // Patient Sex
            "00101010": "028Y",                 // Patient Age
            "00081030": "Ultrasound Exam",      // Study Description
            "00080020": "20240217",             // Study Date
            "00080030": "104515",               // Study Time
            "00200010": "STU20240217104515",    // Study ID
            "00080060": "US",                   // Modality
            "00080080": "Downtown Clinic",      // Institution Name
            "0008103E": "Abdomen",              // Series Description
            "00200011": "1",                    // Series Number
            "00200013": "25",                   // Instance Number
            "00201209": "50",                   // Number of Series Related Instances
            "00180050": "1.0",                  // Slice Thickness
            "00280100": "8",                    // Bits Allocated
            "00280004": "MONOCHROME2"           // Photometric Interpretation
        ]
    )

    static let minimal = MockDicomDecoderForPreviews(
        width: 512,
        height: 512,
        metadata: [:]
    )
}

#endif
