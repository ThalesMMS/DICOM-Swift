import DicomObjects
import XCTest

final class DicomObjectsProductTests: XCTestCase {
    func test_waveformConsumer_preservesPhysicalCalibrationWithoutCore() throws {
        let units = DicomCodedConcept(codeValue: "mV", codingSchemeDesignator: "UCUM")
        let channel = DicomWaveformChannel(sensitivity: 0.5, sensitivityUnits: units,
                                          sensitivityCorrectionFactor: 2, baseline: 10, samples: [1, 2])
        XCTAssertEqual(channel.physicalValue(for: 2), 12)
        XCTAssertEqual(channel.sensitivityUnits?.codeValue, "mV")
        XCTAssertThrowsError(try DicomWaveformBuilder.dataSet(multiplexGroups: [])) { error in
            XCTAssertEqual(error as? DicomWaveformError, .emptyMultiplexGroups)
        }
    }
}
