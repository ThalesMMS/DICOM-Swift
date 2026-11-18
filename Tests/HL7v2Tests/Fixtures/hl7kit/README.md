# HL7 v2.x Test Data

This directory contains comprehensive test data for validating the HL7kit v2.x implementation.

## Directory Structure

```
TestData/HL7v2x/
├── valid/              # Valid HL7 v2.x messages
├── invalid/            # Invalid messages for negative testing
├── edge-cases/         # Edge cases and boundary conditions
└── README.md          # This file
```

## Valid Test Messages

### ADT_A01_admission.hl7
Complete patient admission message (ADT^A01) with:
- Full patient demographics
- Visit information
- Next of kin
- Allergy information
- Diagnosis

### ADT_A03_discharge.hl7
Patient discharge message (ADT^A03) with:
- Patient identification
- Visit information
- Discharge disposition

### ADT_A08_update.hl7
Patient demographics update message (ADT^A08) with:
- Updated address
- Updated phone numbers
- Marital status change

### ORM_O01_lab_order.hl7
Laboratory order message (ORM^O01) with:
- Multiple test orders (Sodium, Potassium, Chloride)
- Order control information
- Observation requests

### ORU_R01_lab_results.hl7
Laboratory results message (ORU^R01) with:
- Results for multiple tests
- Normal and abnormal values
- Reference ranges
- Clinical notes

### ACK_general.hl7
General acknowledgement message (ACK) with:
- Positive acknowledgement
- Message control ID reference

## Edge Cases

### minimal_valid.hl7
Minimal valid message with only required fields and segments.
Tests parser's handling of minimal valid data.

### special_characters.hl7
Message containing special characters:
- Apostrophes (O'Brien, O'Malley)
- Accented characters (Seán, José, Siobhán)
- Escape sequences (\.br\ for line breaks)

### multiple_repeating.hl7
Message with multiple repeating segments:
- 5 allergy entries (AL1)
- 4 next of kin entries (NK1)
- 3 diagnosis entries (DG1)
Tests handling of repeating segments.

### long_field_values.hl7
Message with exceptionally long field values:
- Long patient identifiers
- Long names
- Long addresses
Tests field length handling and truncation.

### unicode_characters.hl7
Message with Unicode characters:
- Japanese characters (患者, 山田, 太郎)
- Japanese address
Tests multi-byte character encoding (UTF-8).

## Invalid Messages

### missing_required_evn.hl7
Message missing the required PID-5 (patient name) field.
Tests validation of required fields.

### missing_required_pv1.hl7
Message missing the required PV1 segment.
Tests validation of required segments.

### invalid_datetime.hl7
Message with invalid date/time formats:
- Malformed timestamp in MSH-7
- Invalid date in PID-7
Tests date/time validation.

### bad_segment_id.hl7
Message starting with invalid segment identifier (BADHEADER instead of MSH).
Tests segment identifier validation.

### invalid_coded_values.hl7
Message with invalid coded values:
- Invalid gender code
- Invalid patient class
Tests code validation against HL7 tables.

## Usage

### In Unit Tests

```swift
import XCTest
@testable import HL7v2Kit

class ParserTests: XCTestCase {
    func testValidADTAdmission() throws {
        let testDataURL = Bundle.module.url(
            forResource: "ADT_A01_admission",
            withExtension: "hl7",
            subdirectory: "TestData/HL7v2x/valid"
        )!
        let messageData = try Data(contentsOf: testDataURL)
        let message = try HL7v2Parser.parse(messageData)
        
        XCTAssertEqual(message.messageType, "ADT")
        XCTAssertEqual(message.triggerEvent, "A01")
        // Additional assertions...
    }
    
    func testInvalidDateTime() throws {
        let testDataURL = Bundle.module.url(
            forResource: "invalid_datetime",
            withExtension: "hl7",
            subdirectory: "TestData/HL7v2x/invalid"
        )!
        let messageData = try Data(contentsOf: testDataURL)
        
        XCTAssertThrowsError(try HL7v2Parser.parse(messageData)) { error in
            // Verify correct error type
            XCTAssertTrue(error is ValidationError)
        }
    }
}
```

### Loading Test Data

```swift
func loadTestMessage(_ filename: String, in directory: String = "valid") throws -> Data {
    let url = Bundle.module.url(
        forResource: filename,
        withExtension: "hl7",
        subdirectory: "TestData/HL7v2x/\(directory)"
    )!
    return try Data(contentsOf: url)
}

// Usage
let admissionData = try loadTestMessage("ADT_A01_admission")
let message = try HL7v2Parser.parse(admissionData)
```

## Test Coverage Requirements

To meet the 90% code coverage requirement, tests should:

1. **Valid Messages**: Verify all fields parse correctly
2. **Invalid Messages**: Verify appropriate errors are thrown
3. **Edge Cases**: Verify boundary conditions are handled
4. **Performance**: Benchmark parsing speed with these messages

## Message Format

All HL7 v2.x messages in this directory follow the standard format:
- Segments separated by line breaks (CR or CR+LF)
- Fields separated by pipe (`|`)
- Components separated by caret (`^`)
- Subcomponents separated by ampersand (`&`)
- Repetitions separated by tilde (`~`)
- Escape character: backslash (`\`)

## Version Compatibility

These test messages are primarily in HL7 v2.5.1 format but are designed to be compatible with:
- HL7 v2.3 and later (most segments)
- HL7 v2.5 and later (all segments)

## Adding New Test Messages

When adding new test messages:

1. Follow the naming convention: `{MessageType}_{Event}_{description}.hl7`
2. Use realistic, but not actual, patient data
3. Include comments in this README
4. Ensure message validity (for valid messages)
5. Document the specific test case being covered

## References

- HL7 v2.5.1 Specification: http://www.hl7.org/
- HL7 Message Examples: See HL7V2X_STANDARDS.md
- NIST Validation Tool: https://hl7v2-gvt.nist.gov/

---

*These test messages are synthetic data created for testing purposes only.*
