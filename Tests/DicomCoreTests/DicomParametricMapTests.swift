import simd
import XCTest
@testable import DicomCore

final class DicomParametricMapTests: XCTestCase {
    func testParametricMapParsesIntegerScalarVolumeWithUnitsQuantityGeometryAndSources() throws {
        let sourceReference = DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.4",
            referencedSOPInstanceUID: "2.25.6001",
            referencedFrameNumbers: [1]
        )
        let storedValues: [UInt16] = [100, 200, 300, 400, 500, 600, 700, 800]
        let units = DicomCodedConcept(codeValue: "mm2/s", codingSchemeDesignator: "UCUM", codeMeaning: "square millimeter per second")
        let quantityName = DicomCodedConcept(codeValue: "246205007", codingSchemeDesignator: "SCT", codeMeaning: "Quantity")
        let quantityCode = DicomCodedConcept(codeValue: "113041", codingSchemeDesignator: "DCM", codeMeaning: "Apparent Diffusion Coefficient")

        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomParametricMap.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.6101"),
            string(.modality, vr: .CS, "PM"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            string(.numberOfFrames, vr: .IS, "2"),
            us(.rows, 2),
            us(.columns, 2),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 0),
            sequence(.sharedFunctionalGroupsSequence, [
                DicomDataSet(elements: [
                    sequence(.pixelMeasuresSequence, [
                        DicomDataSet(elements: [
                            ds(.pixelSpacing, ["0.7", "0.8"]),
                            ds(.sliceThickness, ["2.5"]),
                            ds(.sliceSpacing, ["2.5"])
                        ])
                    ]),
                    sequence(.planeOrientationSequence, [
                        DicomDataSet(elements: [
                            ds(.imageOrientationPatient, ["1", "0", "0", "0", "1", "0"])
                        ])
                    ]),
                    sequence(.realWorldValueMappingSequence, [
                        realWorldValueMap(
                            label: "ADC",
                            first: 0,
                            last: 1000,
                            intercept: 0,
                            slope: 0.001,
                            units: units,
                            quantityName: quantityName,
                            quantityCode: quantityCode
                        )
                    ])
                ])
            ]),
            sequence(.perFrameFunctionalGroupsSequence, [
                frameFunctionalGroup(index: 0, z: 0, sourceReference: sourceReference),
                frameFunctionalGroup(index: 1, z: 2.5, sourceReference: sourceReference)
            ]),
            bytes(.pixelData, vr: .OW, uint16Data(storedValues))
        ])

        let decoder = try open(dataSet: dataSet)
        let map = try XCTUnwrap(decoder.parametricMap)

        XCTAssertEqual(map.sopInstanceUID, "2.25.6101")
        XCTAssertEqual(map.rows, 2)
        XCTAssertEqual(map.columns, 2)
        XCTAssertEqual(map.frameCount, 2)
        XCTAssertEqual(map.scalarVolume.scalarValues, storedValues.map(Double.init))
        assertEqual(map.scalarVolume.physicalValues ?? [], [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8], accuracy: 1e-12)
        XCTAssertEqual(map.scalarVolume.units, units)
        XCTAssertEqual(map.scalarVolume.quantityDefinitions.first?.conceptName, quantityName)
        XCTAssertEqual(map.scalarVolume.quantityDefinitions.first?.conceptCode, quantityCode)

        XCTAssertEqual(map.frames[0].sourceImageReferences, [sourceReference])
        XCTAssertEqual(map.frames[1].geometry?.imagePositionPatient, SIMD3<Double>(0, 0, 2.5))
        XCTAssertEqual(map.frames[0].geometry?.imageOrientationPatient?.normal, SIMD3<Double>(0, 0, 1))
        XCTAssertEqual(map.frames[0].geometry?.pixelMeasures?.pixelSpacing, SIMD2<Double>(0.7, 0.8))
        XCTAssertEqual(map.frames[0].realWorldValueMap?.label, "ADC")
        assertEqual(map.frames[1].physicalValues ?? [], [0.5, 0.6, 0.7, 0.8], accuracy: 1e-12)
    }

    func testParametricMapParsesFloatPixelDataAndDoubleFloatRealWorldValueRange() throws {
        let units = DicomCodedConcept(codeValue: "{ratio}", codingSchemeDesignator: "UCUM", codeMeaning: "ratio")
        let quantityName = DicomCodedConcept(codeValue: "246205007", codingSchemeDesignator: "SCT", codeMeaning: "Quantity")
        let quantityCode = DicomCodedConcept(codeValue: "126397", codingSchemeDesignator: "DCM", codeMeaning: "Relative Regional Blood Flow")
        let scalarValues = [1.5, 2.5, 3.5, 4.5]

        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomParametricMap.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.6201"),
            string(.modality, vr: .CS, "PM"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            string(.numberOfFrames, vr: .IS, "1"),
            us(.rows, 2),
            us(.columns, 2),
            us(.bitsAllocated, 32),
            sequence(.realWorldValueMappingSequence, [
                realWorldValueMap(
                    label: "rCBF",
                    doubleFirst: 0,
                    doubleLast: 10,
                    intercept: 1,
                    slope: 2,
                    units: units,
                    quantityName: quantityName,
                    quantityCode: quantityCode
                )
            ]),
            DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats(scalarValues))
        ])

        let decoder = try open(dataSet: dataSet)
        let map = try XCTUnwrap(decoder.parametricMap)

        assertEqual(map.scalarVolume.scalarValues, scalarValues, accuracy: 1e-6)
        assertEqual(map.scalarVolume.physicalValues ?? [], [4, 6, 8, 10], accuracy: 1e-6)
        XCTAssertEqual(map.frames[0].units, units)
        XCTAssertEqual(map.frames[0].quantityDefinitions.first?.conceptCode, quantityCode)
    }

    // MARK: - Per-pixel validity (issue #1875)

    func test_float_map_marks_nonfinite_and_out_of_range_pixels_missing() throws {
        // 3x2 frame: 2 valid, NaN, +inf, -inf, and one stored value outside 0...10.
        let stored: [Double] = [1.5, .nan, .infinity, 2.5, -.infinity, 42]
        let decoder = try open(dataSet: floatMapDataSet(scalarValues: stored, rows: 2, columns: 3))

        let map = try decoder.decodeParametricMap()
        let frame = map.frames[0]

        XCTAssertEqual(frame.pixelValidity, [
            .valid, .notANumber, .positiveInfinity, .valid, .negativeInfinity, .outsideMappingDomain
        ])
        let physical = try XCTUnwrap(frame.physicalValues)
        XCTAssertEqual(physical[0], 4, accuracy: 1e-9)
        XCTAssertEqual(physical[3], 6, accuracy: 1e-9)
        for index in [1, 2, 4, 5] {
            XCTAssertTrue(physical[index].isNaN, "pixel \(index) must be NaN, not a plausible number")
            XCTAssertNil(frame.physicalValue(atPixelIndex: index))
        }
        XCTAssertEqual(frame.physicalValue(atPixelIndex: 3), 6)
        // Stored values are preserved bit-exactly, including the non-finite ones.
        XCTAssertTrue(frame.scalarValues[1].isNaN)
        XCTAssertEqual(frame.scalarValues[2], .infinity)
        XCTAssertEqual(frame.scalarValues[4], -.infinity)
        XCTAssertEqual(frame.scalarValues[5], 42)

        let counts = map.validityCounts
        XCTAssertEqual(counts.totalCount, 6)
        XCTAssertEqual(counts.validCount, 2)
        XCTAssertEqual(counts.invalidCount, 4)
        XCTAssertEqual(counts.count(for: .notANumber), 1)
        XCTAssertEqual(counts.count(for: .positiveInfinity), 1)
        XCTAssertEqual(counts.count(for: .negativeInfinity), 1)
        XCTAssertEqual(counts.count(for: .outsideMappingDomain), 1)
        XCTAssertEqual(counts.count(for: .padding), 0)
        XCTAssertEqual(counts.validFraction, 2.0 / 6.0, accuracy: 1e-12)
        XCTAssertEqual(Set(map.validityDiagnostics.map(\.code)), [
            "PM_PIXEL_NAN", "PM_PIXEL_POSITIVE_INFINITY", "PM_PIXEL_NEGATIVE_INFINITY", "PM_PIXEL_OUTSIDE_MAPPING_DOMAIN"
        ])
        XCTAssertEqual(map.scalarVolume.pixelValidity, frame.pixelValidity)
        XCTAssertEqual(map.frames[0].units?.codeValue, "{ratio}")
    }

    func test_double_float_map_classifies_pixel_padding_value_and_range_limit() throws {
        // Double Float Pixel Padding Value -1000 with Range Limit -900: every
        // stored value in -1000...-900 is background, not an out-of-range error.
        let stored: [Double] = [1, -1000, -950, 3]
        var elements = baseElements(rows: 2, columns: 2, bitsAllocated: 64)
        elements.append(sequence(.realWorldValueMappingSequence, [ratioMap(doubleFirst: -100, doubleLast: 100)]))
        elements.append(DicomDataElement(tag: DicomTag.doubleFloatPixelPaddingValue.rawValue, vr: .FD, value: .floats([-1000])))
        elements.append(DicomDataElement(tag: DicomTag.doubleFloatPixelPaddingRangeLimit.rawValue, vr: .FD, value: .floats([-900])))
        elements.append(DicomDataElement(tag: DicomTag.doubleFloatPixelData.rawValue, vr: .OD, value: .floats(stored)))

        let map = try open(dataSet: DicomDataSet(elements: elements)).decodeParametricMap()

        XCTAssertEqual(map.pixelPadding, DicomParametricMapPixelPaddingRule(value: -1000, rangeLimit: -900))
        XCTAssertEqual(map.frames[0].pixelValidity, [.valid, .padding, .padding, .valid])
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 0), 3)
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 3), 7)
        XCTAssertEqual(map.validityCounts.count(for: .padding), 2)
        XCTAssertEqual(map.scalarVolume.scalarValues, stored)
    }

    func test_float_pixel_padding_value_marks_padding_before_mapping() throws {
        let stored: [Double] = [0, 5, 0, 7.5]
        var elements = baseElements(rows: 2, columns: 2, bitsAllocated: 32)
        elements.append(sequence(.realWorldValueMappingSequence, [ratioMap(doubleFirst: 0, doubleLast: 10)]))
        elements.append(DicomDataElement(tag: DicomTag.floatPixelPaddingValue.rawValue, vr: .FL, value: .floats([0])))
        elements.append(DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats(stored)))

        let map = try open(dataSet: DicomDataSet(elements: elements)).decodeParametricMap()

        XCTAssertEqual(map.frames[0].pixelValidity, [.padding, .valid, .padding, .valid])
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 1), 11)
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 3), 16)
    }

    func test_integer_map_uses_pixel_padding_value_and_range_limit_for_signed_stored_values() throws {
        let stored: [Int16] = [-32768, -32000, 100, 200]
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, DicomParametricMap.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.6301"),
            string(.modality, vr: .CS, "PM"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            string(.numberOfFrames, vr: .IS, "1"),
            us(.rows, 2),
            us(.columns, 2),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 1),
            DicomDataElement(tag: DicomTag.pixelPaddingValue.rawValue, vr: .SS, value: .signedIntegers([-32768])),
            DicomDataElement(tag: DicomTag.pixelPaddingRangeLimit.rawValue, vr: .SS, value: .signedIntegers([-32000])),
            sequence(.realWorldValueMappingSequence, [ratioMap(doubleFirst: -1000, doubleLast: 1000)]),
            bytes(.pixelData, vr: .OW, uint16Data(stored.map { UInt16(bitPattern: $0) }))
        ])

        let map = try open(dataSet: dataSet).decodeParametricMap()

        XCTAssertEqual(map.pixelPadding, DicomParametricMapPixelPaddingRule(value: -32768, rangeLimit: -32000))
        XCTAssertEqual(map.frames[0].pixelValidity, [.padding, .padding, .valid, .valid])
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 2), 201)
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 3), 401)
    }

    func test_lut_mapping_marks_out_of_table_values_and_rejects_nonfinite_entries() throws {
        let lut: [Double] = [10, 20, 30, 40]
        let stored: [Double] = [0, 3, 4, 1.5, 2, -1]
        var elements = baseElements(rows: 2, columns: 3, bitsAllocated: 32)
        elements.append(sequence(.realWorldValueMappingSequence, [lutMap(lut: lut, first: 0, last: 3)]))
        elements.append(DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats(stored)))

        let map = try open(dataSet: DicomDataSet(elements: elements)).decodeParametricMap()

        XCTAssertEqual(map.frames[0].pixelValidity, [
            .valid, .valid, .outsideMappingDomain, .outsideMappingDomain, .valid, .outsideMappingDomain
        ])
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 0), 10)
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 1), 40)
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 4), 30)
        XCTAssertEqual(map.validityCounts.count(for: .outsideMappingDomain), 3)

        // A LUT with a NaN entry is malformed metadata for the pixel that
        // hits it; the other entries keep mapping exactly.
        var malformedLUTElements = baseElements(rows: 2, columns: 3, bitsAllocated: 32)
        malformedLUTElements.append(sequence(.realWorldValueMappingSequence, [lutMap(lut: [10, .nan, 30, 40], first: 0, last: 3)]))
        malformedLUTElements.append(DicomDataElement(
            tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats([0, 1, 4, 1.5, 2, -1])
        ))
        let malformed = try open(dataSet: DicomDataSet(elements: malformedLUTElements)).decodeParametricMap()
        XCTAssertEqual(malformed.frames[0].pixelValidity, [
            .valid, .malformedMappingMetadata, .outsideMappingDomain, .outsideMappingDomain, .valid, .outsideMappingDomain
        ])
        XCTAssertEqual(malformed.frames[0].physicalValue(atPixelIndex: 0), 10)
        XCTAssertNil(malformed.frames[0].physicalValue(atPixelIndex: 1))
        XCTAssertEqual(malformed.validityCounts.count(for: .malformedMappingMetadata), 1)
    }

    func test_nonfinite_slope_rejects_an_object_without_valid_pixels() throws {
        var elements = baseElements(rows: 1, columns: 2, bitsAllocated: 32)
        elements.append(sequence(.realWorldValueMappingSequence, [
            ratioMap(doubleFirst: 0, doubleLast: 10, intercept: 1, slope: .infinity)
        ]))
        elements.append(DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats([1, 2])))

        XCTAssertThrowsError(try open(dataSet: DicomDataSet(elements: elements)).decodeParametricMap()) { error in
            guard let decodeError = error as? DicomParametricMapDecodeError,
                  case let .allPixelsInvalid(counts) = decodeError.reason else {
                return XCTFail("Expected allPixelsInvalid, got \(error)")
            }
            XCTAssertEqual(counts.count(for: .malformedMappingMetadata), 2)
            XCTAssertEqual(decodeError.reason.code, "PM_ALL_PIXELS_INVALID")
        }
    }

    func test_arithmetic_overflow_marks_only_the_affected_pixel_invalid() throws {
        // slope 1e300 overflows for 1e10 but not for 1.
        var elements = baseElements(rows: 1, columns: 2, bitsAllocated: 64)
        elements.append(sequence(.realWorldValueMappingSequence, [
            ratioMap(doubleFirst: 0, doubleLast: 1e12, intercept: 0, slope: 1e300)
        ]))
        elements.append(DicomDataElement(tag: DicomTag.doubleFloatPixelData.rawValue, vr: .OD, value: .floats([1, 1e10])))

        let map = try open(dataSet: DicomDataSet(elements: elements)).decodeParametricMap()

        XCTAssertEqual(map.frames[0].pixelValidity, [.valid, .arithmeticOverflow])
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 0), 1e300)
        XCTAssertNil(map.frames[0].physicalValue(atPixelIndex: 1))
    }

    func test_multiframe_variation_marks_an_unmapped_frame_as_missing_mapping() throws {
        // Frame 0 carries a per-frame mapping; frame 1 has none at any scope.
        let units = DicomCodedConcept(codeValue: "{ratio}", codingSchemeDesignator: "UCUM", codeMeaning: "ratio")
        let quantityName = DicomCodedConcept(codeValue: "246205007", codingSchemeDesignator: "SCT", codeMeaning: "Quantity")
        let quantityCode = DicomCodedConcept(codeValue: "126397", codingSchemeDesignator: "DCM", codeMeaning: "rCBF")
        var elements = baseElements(rows: 1, columns: 2, bitsAllocated: 32, frames: 2)
        elements.append(sequence(.perFrameFunctionalGroupsSequence, [
            DicomDataSet(elements: [
                sequence(.realWorldValueMappingSequence, [
                    realWorldValueMap(label: "F0", doubleFirst: 0, doubleLast: 10, intercept: 0, slope: 2,
                                      units: units, quantityName: quantityName, quantityCode: quantityCode)
                ])
            ]),
            DicomDataSet(elements: [
                sequence(.frameContentSequence, [DicomDataSet(elements: [string(.stackID, vr: .SH, "PM")])])
            ])
        ]))
        elements.append(DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats([1, .nan, 3, 4])))

        let map = try open(dataSet: DicomDataSet(elements: elements)).decodeParametricMap()

        XCTAssertEqual(map.frames[0].pixelValidity, [.valid, .notANumber])
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 0), 2)
        XCTAssertEqual(map.frames[1].pixelValidity, [.missingMapping, .missingMapping])
        XCTAssertNil(map.frames[1].physicalValues)
        XCTAssertNil(map.frames[1].units)
        XCTAssertNil(map.scalarVolume.physicalValues)
        XCTAssertEqual(map.scalarVolume.pixelValidity, [.valid, .notANumber, .missingMapping, .missingMapping])
        XCTAssertEqual(map.validityCounts.validCount, 1)
        XCTAssertEqual(map.validityCounts.count(for: .missingMapping), 2)
        XCTAssertEqual(map.frames[0].validityCounts.totalCount, 2)
        XCTAssertEqual(map.frames[1].validityCounts.count(for: .missingMapping), 2)
    }

    func test_all_invalid_pixels_reject_the_object_with_a_typed_reason() throws {
        var elements = baseElements(rows: 1, columns: 3, bitsAllocated: 32)
        elements.append(sequence(.realWorldValueMappingSequence, [ratioMap(doubleFirst: 0, doubleLast: 10)]))
        elements.append(DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats([.nan, .infinity, 99])))
        let decoder = try open(dataSet: DicomDataSet(elements: elements))

        XCTAssertNil(decoder.parametricMap)
        XCTAssertThrowsError(try decoder.decodeParametricMap()) { error in
            guard let decodeError = error as? DicomParametricMapDecodeError,
                  case let .allPixelsInvalid(counts) = decodeError.reason else {
                return XCTFail("Expected allPixelsInvalid, got \(error)")
            }
            XCTAssertEqual(counts.validCount, 0)
            XCTAssertEqual(counts.count(for: .notANumber), 1)
            XCTAssertEqual(counts.count(for: .positiveInfinity), 1)
            XCTAssertEqual(counts.count(for: .outsideMappingDomain), 1)
            XCTAssertFalse(decodeError.reason.message.isEmpty)
        }

        // The pixel-object classifier carries the typed reason.
        XCTAssertThrowsError(try DicomPixelObjectClassifier.typedPayload(from: decoder)) { error in
            let rejection = error as? DicomPixelObjectError
            XCTAssertTrue(rejection?.reason.contains("PM_ALL_PIXELS_INVALID") == true, "\(String(describing: rejection))")
        }
    }

    func test_missing_mapping_and_missing_units_have_distinct_object_level_reasons() throws {
        var noMapping = baseElements(rows: 1, columns: 2, bitsAllocated: 32)
        noMapping.append(DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats([1, 2])))
        XCTAssertThrowsError(try open(dataSet: DicomDataSet(elements: noMapping)).decodeParametricMap()) { error in
            XCTAssertEqual((error as? DicomParametricMapDecodeError)?.reason, .missingRealWorldValueMapping)
        }

        var noUnits = baseElements(rows: 1, columns: 2, bitsAllocated: 32)
        noUnits.append(sequence(.realWorldValueMappingSequence, [
            DicomDataSet(elements: [
                string(.realWorldValueLUTLabel, vr: .SH, "no units"),
                fd(.doubleFloatRealWorldValueFirstValueMapped, [0]),
                fd(.doubleFloatRealWorldValueLastValueMapped, [10]),
                fd(.realWorldValueIntercept, [0]),
                fd(.realWorldValueSlope, [1])
            ])
        ]))
        noUnits.append(DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats([1, 2])))
        XCTAssertThrowsError(try open(dataSet: DicomDataSet(elements: noUnits)).decodeParametricMap()) { error in
            XCTAssertEqual((error as? DicomParametricMapDecodeError)?.reason, .missingMeasurementUnits)
        }
    }

    func test_overlapping_mappings_are_rejected_as_ambiguous() throws {
        var elements = baseElements(rows: 1, columns: 2, bitsAllocated: 32)
        elements.append(sequence(.realWorldValueMappingSequence, [
            ratioMap(doubleFirst: 0, doubleLast: 10, intercept: 0, slope: 1),
            ratioMap(doubleFirst: 5, doubleLast: 20, intercept: 100, slope: 1)
        ]))
        elements.append(DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats([1, 2])))
        let decoder = try open(dataSet: DicomDataSet(elements: elements))

        XCTAssertNil(decoder.parametricMap)
        XCTAssertThrowsError(try decoder.decodeParametricMap()) { error in
            XCTAssertEqual((error as? DicomParametricMapDecodeError)?.reason,
                           .ambiguousRealWorldValueMapping(frameIndices: [0]))
        }
    }

    func test_disjoint_mappings_with_same_units_map_each_pixel_by_domain() throws {
        var elements = baseElements(rows: 1, columns: 4, bitsAllocated: 32)
        elements.append(sequence(.realWorldValueMappingSequence, [
            ratioMap(doubleFirst: 0, doubleLast: 10, intercept: 0, slope: 1),
            ratioMap(doubleFirst: 20, doubleLast: 30, intercept: 1000, slope: 1)
        ]))
        elements.append(DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats([1, 25, 15, 30])))

        let map = try open(dataSet: DicomDataSet(elements: elements)).decodeParametricMap()

        XCTAssertEqual(map.frames[0].pixelValidity, [.valid, .valid, .outsideMappingDomain, .valid])
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 0), 1)
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 1), 1025)
        XCTAssertEqual(map.frames[0].physicalValue(atPixelIndex: 3), 1030)
        XCTAssertEqual(map.frames[0].units?.codeValue, "{ratio}")
    }

    func test_mapping_outcome_never_falls_back_to_a_plausible_number() {
        let linear = DicomParametricMapRealWorldValueMap(
            firstMappedValue: 0, lastMappedValue: 10, units: ratioUnits, intercept: 1, slope: 2
        )
        XCTAssertEqual(linear.mappingOutcome(forStoredValue: 4), .value(9))
        XCTAssertEqual(linear.mappingOutcome(forStoredValue: .nan), .invalid(.notANumber))
        XCTAssertEqual(linear.mappingOutcome(forStoredValue: .infinity), .invalid(.positiveInfinity))
        XCTAssertEqual(linear.mappingOutcome(forStoredValue: -.infinity), .invalid(.negativeInfinity))
        XCTAssertEqual(linear.mappingOutcome(forStoredValue: 11), .invalid(.outsideMappingDomain))
        XCTAssertFalse(linear.contains(storedValue: .nan))
        XCTAssertNil(linear.physicalValue(forStoredValue: .nan))

        let malformed = DicomParametricMapRealWorldValueMap(units: ratioUnits, intercept: .nan, slope: 1)
        XCTAssertTrue(malformed.isMalformed)
        XCTAssertEqual(malformed.mappingOutcome(forStoredValue: 1), .invalid(.malformedMappingMetadata))

        let padding = DicomParametricMapPixelPaddingRule(value: .nan)
        XCTAssertEqual(DicomParametricMapPixelValidity.storedValueProblem(.nan, padding: padding), .padding)
        XCTAssertEqual(DicomParametricMapPixelValidity.storedValueProblem(.nan, padding: nil), .notANumber)
    }

    func test_linear_mapping_nonfinite_bounds_are_malformed() {
        let mappings = [
            DicomParametricMapRealWorldValueMap(
                firstMappedValue: .infinity,
                lastMappedValue: 10,
                units: ratioUnits,
                intercept: 0,
                slope: 1
            ),
            DicomParametricMapRealWorldValueMap(
                firstMappedValue: 0,
                lastMappedValue: -.infinity,
                units: ratioUnits,
                intercept: 0,
                slope: 1
            ),
            DicomParametricMapRealWorldValueMap(
                firstMappedValue: .nan,
                lastMappedValue: 10,
                units: ratioUnits,
                intercept: 0,
                slope: 1
            ),
            DicomParametricMapRealWorldValueMap(
                firstMappedValue: .infinity,
                lastMappedValue: 10,
                units: ratioUnits,
                lutData: [1, 2]
            )
        ]

        for mapping in mappings {
            XCTAssertTrue(mapping.isMalformed)
            XCTAssertEqual(mapping.mappingOutcome(forStoredValue: 1), .invalid(.malformedMappingMetadata))
        }
    }

    func test_decoded_dimensions_overflow_is_rejected() throws {
        for (rows, columns, frameCount) in [(Int.max, 2, 1), (1, 2, Int.max)] {
            let decoder = try open(dataSet: floatMapDataSet(scalarValues: [1], rows: 1, columns: 1))
            decoder.height = rows
            decoder.width = columns
            decoder.nImages = frameCount

            XCTAssertThrowsError(try decoder.decodeParametricMap()) { error in
                XCTAssertEqual(
                    (error as? DicomParametricMapDecodeError)?.reason,
                    .invalidDimensions(rows: rows, columns: columns, frameCount: frameCount)
                )
            }
        }
    }

    func test_decoded_payload_byteCountOverflow_isRejectedWithoutTrapping() throws {
        let decoder = try open(dataSet: floatMapDataSet(scalarValues: [1], rows: 1, columns: 1))
        decoder.height = Int.max / MemoryLayout<UInt32>.size + 1
        decoder.width = 1
        decoder.nImages = 1

        XCTAssertThrowsError(try decoder.decodeParametricMap()) { error in
            XCTAssertEqual((error as? DicomParametricMapDecodeError)?.reason, .unreadablePixelPayload)
        }
    }

    func test_validity_counts_merge_and_diagnostics_carry_no_phi() {
        let first = DicomParametricMapValidityCounts(validity: [.valid, .notANumber, .padding])
        let second = DicomParametricMapValidityCounts(validity: [.valid, .valid, .padding])
        let merged = first.merging(second)
        XCTAssertEqual(merged.totalCount, 6)
        XCTAssertEqual(merged.validCount, 3)
        XCTAssertEqual(merged.count(for: .padding), 2)
        XCTAssertEqual(merged.count(for: .notANumber), 1)
        XCTAssertEqual(merged.invalidCountsByReason.keys.contains(.valid), false)
        XCTAssertEqual(merged.diagnostics.map(\.code), ["PM_PIXEL_PADDING", "PM_PIXEL_NAN"])
        XCTAssertEqual(DicomParametricMapPixelValidity.padding.rawValue, 1)
        XCTAssertEqual(MemoryLayout<DicomParametricMapPixelValidity>.size, 1)
    }

    // MARK: - Fixture helpers (issue #1875)

    private var ratioUnits: DicomCodedConcept {
        DicomCodedConcept(codeValue: "{ratio}", codingSchemeDesignator: "UCUM", codeMeaning: "ratio")
    }

    private func baseElements(rows: Int, columns: Int, bitsAllocated: Int, frames: Int = 1) -> [DicomDataElement] {
        [
            string(.sopClassUID, vr: .UI, DicomParametricMap.storageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "2.25.1875.\(bitsAllocated)"),
            string(.modality, vr: .CS, "PM"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            string(.numberOfFrames, vr: .IS, String(frames)),
            us(.rows, rows),
            us(.columns, columns),
            us(.bitsAllocated, bitsAllocated)
        ]
    }

    private func floatMapDataSet(scalarValues: [Double], rows: Int, columns: Int) -> DicomDataSet {
        var elements = baseElements(rows: rows, columns: columns, bitsAllocated: 32)
        elements.append(sequence(.realWorldValueMappingSequence, [ratioMap(doubleFirst: 0, doubleLast: 10)]))
        elements.append(DicomDataElement(tag: DicomTag.floatPixelData.rawValue, vr: .OF, value: .floats(scalarValues)))
        return DicomDataSet(elements: elements)
    }

    private func ratioMap(doubleFirst: Double, doubleLast: Double, intercept: Double = 1, slope: Double = 2) -> DicomDataSet {
        realWorldValueMap(
            label: "rCBF",
            doubleFirst: doubleFirst,
            doubleLast: doubleLast,
            intercept: intercept,
            slope: slope,
            units: ratioUnits,
            quantityName: DicomCodedConcept(codeValue: "246205007", codingSchemeDesignator: "SCT", codeMeaning: "Quantity"),
            quantityCode: DicomCodedConcept(codeValue: "126397", codingSchemeDesignator: "DCM", codeMeaning: "Relative Regional Blood Flow")
        )
    }

    private func lutMap(lut: [Double], first: Int, last: Int) -> DicomDataSet {
        DicomDataSet(elements: [
            string(.realWorldValueLUTLabel, vr: .SH, "LUT"),
            us(.realWorldValueFirstValueMapped, first),
            us(.realWorldValueLastValueMapped, last),
            fd(.realWorldValueLUTData, lut),
            sequence(.measurementUnitsCodeSequence, [codedConceptDataSet(ratioUnits)])
        ])
    }

    private func open(dataSet: DicomDataSet) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(mediaStorageSOPClassUID: DicomParametricMap.storageSOPClassUID)
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("parametric_map_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func realWorldValueMap(
        label: String,
        first: Int? = nil,
        last: Int? = nil,
        doubleFirst: Double? = nil,
        doubleLast: Double? = nil,
        intercept: Double,
        slope: Double,
        units: DicomCodedConcept,
        quantityName: DicomCodedConcept,
        quantityCode: DicomCodedConcept
    ) -> DicomDataSet {
        var elements: [DicomDataElement] = [
            string(.realWorldValueLUTLabel, vr: .SH, label),
            fd(.realWorldValueIntercept, [intercept]),
            fd(.realWorldValueSlope, [slope]),
            sequence(.measurementUnitsCodeSequence, [codedConceptDataSet(units)]),
            sequence(.quantityDefinitionSequence, [
                DicomDataSet(elements: [
                    string(.valueType, vr: .CS, "CODE"),
                    sequence(.conceptNameCodeSequence, [codedConceptDataSet(quantityName)]),
                    sequence(.conceptCodeSequence, [codedConceptDataSet(quantityCode)])
                ])
            ])
        ]
        if let first {
            elements.append(us(.realWorldValueFirstValueMapped, first))
        }
        if let last {
            elements.append(us(.realWorldValueLastValueMapped, last))
        }
        if let doubleFirst {
            elements.append(fd(.doubleFloatRealWorldValueFirstValueMapped, [doubleFirst]))
        }
        if let doubleLast {
            elements.append(fd(.doubleFloatRealWorldValueLastValueMapped, [doubleLast]))
        }
        return DicomDataSet(elements: elements)
    }

    private func frameFunctionalGroup(
        index: Int,
        z: Double,
        sourceReference: DicomSourceImageReference
    ) -> DicomDataSet {
        DicomDataSet(elements: [
            sequence(.frameContentSequence, [
                DicomDataSet(elements: [
                    ul(.dimensionIndexValues, [index + 1]),
                    string(.stackID, vr: .SH, "PM"),
                    ul(.inStackPositionNumber, [index + 1])
                ])
            ]),
            sequence(.planePositionSequence, [
                DicomDataSet(elements: [
                    ds(.imagePositionPatient, ["0", "0", String(z)])
                ])
            ]),
            sequence(.derivationImageSequence, [
                DicomDataSet(elements: [
                    sequence(.sourceImageSequence, [sourceImageDataSet(sourceReference)])
                ])
            ])
        ])
    }

    private func sourceImageDataSet(_ reference: DicomSourceImageReference) -> DicomDataSet {
        var elements: [DicomDataElement] = []
        if let sopClassUID = reference.referencedSOPClassUID {
            elements.append(string(.referencedSOPClassUID, vr: .UI, sopClassUID))
        }
        if let sopInstanceUID = reference.referencedSOPInstanceUID {
            elements.append(string(.referencedSOPInstanceUID, vr: .UI, sopInstanceUID))
        }
        if !reference.referencedFrameNumbers.isEmpty {
            elements.append(DicomDataElement(
                tag: DicomTag.referencedFrameNumber.rawValue,
                vr: .IS,
                value: .strings(reference.referencedFrameNumbers.map(String.init))
            ))
        }
        return DicomDataSet(elements: elements)
    }

    private func codedConceptDataSet(_ concept: DicomCodedConcept) -> DicomDataSet {
        var elements = [
            string(.codeValue, vr: .SH, concept.codeValue),
            string(.codingSchemeDesignator, vr: .SH, concept.codingSchemeDesignator)
        ]
        if let meaning = concept.codeMeaning {
            elements.append(string(.codeMeaning, vr: .LO, meaning))
        }
        return DicomDataSet(elements: elements)
    }

    private func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)]))
    }

    private func ul(_ tag: DicomTag, _ values: [Int]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .UL, value: .unsignedIntegers(values.map { UInt($0) }))
    }

    private func ds(_ tag: DicomTag, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values))
    }

    private func fd(_ tag: DicomTag, _ values: [Double]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .FD, value: .floats(values))
    }

    private func bytes(_ tag: DicomTag, vr: DicomVR, _ data: Data) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .bytes(data))
    }

    private func uint16Data(_ values: [UInt16]) -> Data {
        values.reduce(into: Data()) { data, value in
            data.append(UInt8(value & 0x00FF))
            data.append(UInt8((value >> 8) & 0x00FF))
        }
    }

    private func assertEqual(
        _ actual: [Double],
        _ expected: [Double],
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(actualValue, expectedValue, accuracy: accuracy, file: file, line: line)
        }
    }
}
