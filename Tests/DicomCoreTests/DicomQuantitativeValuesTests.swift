import XCTest
@testable import DicomCore

final class DicomQuantitativeValuesTests: XCTestCase {
    func test_frameProfile_rejectsTruncatedAndOverlongLUTMappings() throws {
        for lut in [[1.0], [1.0, 2.0, 3.0]] {
            let item = DicomDataSet(elements: [
                us(.realWorldValueFirstValueMapped, 0), us(.realWorldValueLastValueMapped, 1),
                fd(.realWorldValueLUTData, lut)
            ])
            let url = try makeTemporaryDICOM(pixelValues: [0, 1], frameCount: 2, extraElements: [
                sequence(.perFrameFunctionalGroupsSequence, [item, item].map {
                    DicomDataSet(elements: [sequence(.realWorldValueMappingSequence, [$0])])
                })
            ])
            defer { try? FileManager.default.removeItem(at: url) }
            let decoder = try DCMDecoder(contentsOf: url)
            for frame in 0..<2 {
                XCTAssertNil(decoder.quantitativeValue(at: 0, frame: frame)?.physicalValue)
                XCTAssertTrue(decoder.quantitativeValueProfile(forFrame: frame).diagnostics.contains {
                    $0.code == "invalid_real_world_value_mapping"
                })
            }
        }
        XCTAssertNil(DicomRealWorldValueMap(label: nil, explanation: nil,
            firstMappedValue: .min, lastMappedValue: .max, units: nil, intercept: nil, slope: nil, lutData: [1]))
    }

    func test_frameProfile_reportsMalformedAndNonFiniteMappingsWithoutBorrowingAnotherFrame() throws {
        let valid = DicomDataSet(elements: [
            us(.realWorldValueFirstValueMapped, 0), us(.realWorldValueLastValueMapped, 100),
            fd(.realWorldValueSlope, [2]), fd(.realWorldValueIntercept, [1])
        ])
        let malformed = DicomDataSet(elements: [fd(.realWorldValueSlope, [3])])
        var nonFinite = valid
        nonFinite.set(fd(.realWorldValueSlope, [.infinity]))
        let url = try makeTemporaryDICOM(pixelValues: [10, 10, 10], frameCount: 3, extraElements: [
            sequence(.perFrameFunctionalGroupsSequence, [valid, malformed, nonFinite].map {
                DicomDataSet(elements: [sequence(.realWorldValueMappingSequence, [$0])])
            })
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)
        XCTAssertEqual(decoder.quantitativeValue(at: 0, frame: 0)?.physicalValue, 21)
        XCTAssertNil(decoder.quantitativeValue(at: 0, frame: 1)?.physicalValue)
        XCTAssertNil(decoder.quantitativeValue(at: 0, frame: 2)?.physicalValue)
        XCTAssertTrue(decoder.quantitativeValueProfile(forFrame: 1).diagnostics.contains {
            $0.code == "invalid_real_world_value_mapping"
        })
        XCTAssertTrue(decoder.quantitativeValueProfile(forFrame: 2).diagnostics.contains {
            $0.code == "non_finite_real_world_value_mapping"
        })
        XCTAssertTrue(decoder.quantitativeValueProfile(forFrame: 3).diagnostics.contains {
            $0.code == "quantitative_frame_out_of_range"
        })
    }

    func test_perFrameMapping_usesRequestedFrameInsteadOfFlattenedFirstMap() throws {
        let frames = [2.0, 3.0].map { slope in
            DicomDataSet(elements: [sequence(.realWorldValueMappingSequence, [
                DicomDataSet(elements: [
                    us(.realWorldValueFirstValueMapped, 0), us(.realWorldValueLastValueMapped, 100),
                    fd(.realWorldValueSlope, [slope]), fd(.realWorldValueIntercept, [1]),
                    unitSequence(codeValue: "1", codingScheme: "UCUM", meaning: "ratio")
                ])
            ])])
        }
        let url = try makeTemporaryDICOM(pixelValues: [10, 10], frameCount: 2, extraElements: [
            sequence(.perFrameFunctionalGroupsSequence, frames)
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = try DCMDecoder(contentsOf: url)
        XCTAssertEqual(decoder.quantitativeValue(at: 0, frame: 0)?.physicalValue, 21)
        XCTAssertEqual(decoder.quantitativeValue(at: 0, frame: 1)?.physicalValue, 31)
    }

    func test_nonFiniteLinearMapping_doesNotProducePhysicalValuesOrRange() throws {
        for slope in [Double.nan, Double.infinity, -Double.infinity, Double.greatestFiniteMagnitude] {
            let mapping = try XCTUnwrap(DicomRealWorldValueMap(
                label: "INVALID", explanation: nil, firstMappedValue: 2, lastMappedValue: 3,
                units: nil, intercept: 0, slope: slope, lutData: []
            ))
            XCTAssertNil(mapping.physicalValue(forStoredPixelValue: 2))
            XCTAssertNil(mapping.physicalRange)
        }
    }

    func test_nonFiniteLUTEntry_preservesValidSamplesWithoutInventingPhysicalRange() throws {
        let mapping = try XCTUnwrap(DicomRealWorldValueMap(
            label: "PARTIAL", explanation: nil, firstMappedValue: 0, lastMappedValue: 2,
            units: nil, intercept: nil, slope: nil, lutData: [1.25, .nan, .infinity]
        ))
        XCTAssertEqual(mapping.physicalValue(forStoredPixelValue: 0), 1.25)
        XCTAssertNil(mapping.physicalValue(forStoredPixelValue: 1))
        XCTAssertNil(mapping.physicalValue(forStoredPixelValue: 2))
        XCTAssertNil(mapping.physicalRange)
        XCTAssertTrue(mapping.lutData[1].isNaN)
    }

    func testRealWorldValueLinearMappingReturnsPhysicalUnits() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [4, 10],
            extraElements: [
                sequence(.realWorldValueMappingSequence, [
                    DicomDataSet(elements: [
                        us(.realWorldValueFirstValueMapped, 0),
                        us(.realWorldValueLastValueMapped, 100),
                        string(.realWorldValueLUTLabel, vr: .SH, "LINEAR"),
                        fd(.realWorldValueIntercept, [2.0]),
                        fd(.realWorldValueSlope, [0.5]),
                        unitSequence(codeValue: "mg/ml", codingScheme: "UCUM", meaning: "milligram per milliliter")
                    ])
                ])
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let profile = decoder.quantitativeValueProfile
        let value = try XCTUnwrap(decoder.quantitativeValue(at: 1))

        XCTAssertEqual(profile.realWorldValueMaps.count, 1)
        XCTAssertEqual(profile.realWorldValue(forStoredPixelValue: 10), 7.0)
        XCTAssertEqual(value.storedValue, 10)
        XCTAssertEqual(value.modalityValue, 10.0)
        XCTAssertEqual(value.physicalValue, 7.0)
        XCTAssertEqual(value.physicalUnit?.codeValue, "mg/ml")
        XCTAssertEqual(value.physicalRange, 2.0...52.0)
        XCTAssertEqual(value.source, .realWorldValueMap(label: "LINEAR"))
    }

    /// Isis issue #2842: Philips MR conversions write a linear item without First/Last Value Mapped (Type 1). It maps
    /// every stored value, as GDCM reads it, with a diagnostic; a LUT still needs its first value.
    func testLinearMappingWithoutRangeAppliesToEveryStoredValueWithADiagnostic() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [4, 10],
            extraElements: [
                sequence(.realWorldValueMappingSequence, [
                    DicomDataSet(elements: [
                        fd(.realWorldValueIntercept, [0.0]),
                        fd(.realWorldValueSlope, [10.25])
                    ]),
                    DicomDataSet(elements: [fd(.realWorldValueLUTData, [1, 2, 3])])
                ])
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let profile = try DCMDecoder(contentsOf: url).quantitativeValueProfile
        XCTAssertEqual(profile.realWorldValueMaps.count, 1, "the LUT without a first value stays refused")
        XCTAssertEqual(profile.realWorldValueMaps.first?.declaresMappedRange, false)
        XCTAssertNil(profile.realWorldValueMaps.first?.physicalRange)
        XCTAssertNil(profile.physicalRange)
        XCTAssertEqual(profile.realWorldValue(forStoredPixelValue: 10), 102.5)
        XCTAssertEqual(profile.realWorldValue(forStoredPixelValue: 60_000), 615_000)
        XCTAssertEqual(Set(profile.diagnostics.map(\.code)),
                       ["real_world_value_mapping_without_range", "invalid_real_world_value_mapping"])
    }

    func testRealWorldValueLUTMappingReturnsLookupEntry() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [2],
            extraElements: [
                sequence(.realWorldValueMappingSequence, [
                    DicomDataSet(elements: [
                        us(.realWorldValueFirstValueMapped, 1),
                        us(.realWorldValueLastValueMapped, 3),
                        string(.realWorldValueLUTLabel, vr: .SH, "LUT"),
                        fd(.realWorldValueLUTData, [10.0, 20.0, 30.0]),
                        unitSequence(codeValue: "1", codingScheme: "UCUM", meaning: "ratio")
                    ])
                ])
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let value = try XCTUnwrap(decoder.quantitativeValue(
            at: 0,
            preferredRealWorldValueMapLabel: "LUT"
        ))

        XCTAssertEqual(value.storedValue, 2)
        XCTAssertEqual(value.physicalValue, 20.0)
        XCTAssertEqual(value.physicalUnit?.codeMeaning, "ratio")
        XCTAssertEqual(value.physicalRange, 10.0...30.0)
    }

    func testSUVBodyWeightUsesPETMetadataWhenPresent() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [1000],
            modality: "PT",
            extraElements: [
                string(.units, vr: .CS, "BQML"),
                string(.rescaleType, vr: .LO, "BQML"),
                ds(.patientWeight, ["70"]),
                string(.decayCorrection, vr: .CS, "ADMIN"),
                ds(.decayFactor, ["1"]),
                sequence(.radiopharmaceuticalInformationSequence, [
                    DicomDataSet(elements: [
                        ds(.radionuclideTotalDose, ["350000000"])
                    ])
                ])
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let value = try XCTUnwrap(decoder.quantitativeValue(at: 0, suvType: .bw))

        XCTAssertEqual(value.storedValue, 1000)
        XCTAssertEqual(value.modalityValue, 1000.0)
        XCTAssertEqual(value.modalityUnit, "BQML")
        XCTAssertEqual(value.physicalValue ?? .nan, 0.2, accuracy: 0.000001)
        XCTAssertEqual(value.physicalUnit?.codeMeaning, "Standardized Uptake Value body weight")
        XCTAssertEqual(value.source, .suv(.bw))
        XCTAssertEqual(decoder.quantitativeValueProfile.suvMetadata?.diagnostics(for: .bw), [])
    }

    func testSUVVariantsUsePatientSizeCorrectionFactors() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [1000],
            modality: "PT",
            extraElements: [
                string(.units, vr: .CS, "BQML"),
                ds(.patientWeight, ["70"]),
                ds(.patientSize, ["1.75"]),
                string(.patientSex, vr: .CS, "M"),
                string(.decayCorrection, vr: .CS, "ADMIN"),
                ds(.decayFactor, ["1"]),
                sequence(.radiopharmaceuticalInformationSequence, [
                    DicomDataSet(elements: [
                        ds(.radionuclideTotalDose, ["350000000"])
                    ])
                ])
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let metadata = try XCTUnwrap(decoder.quantitativeValueProfile.suvMetadata)

        XCTAssertEqual(metadata.patientSizeCorrectionFactor(for: .lbm) ?? .nan, 57_800, accuracy: 0.001)
        XCTAssertEqual(metadata.patientSizeCorrectionFactor(for: .ibw) ?? .nan, 72_380, accuracy: 0.001)
        XCTAssertEqual(metadata.suvValue(forActivityConcentrationBqPerMl: 1000, type: .lbm) ?? .nan, 0.165142857, accuracy: 0.000001)
        XCTAssertEqual(metadata.suvValue(forActivityConcentrationBqPerMl: 1000, type: .ibw) ?? .nan, 0.2068, accuracy: 0.000001)
        XCTAssertNotNil(metadata.suvValue(forActivityConcentrationBqPerMl: 1000, type: .bsa))
        XCTAssertEqual(metadata.diagnostics(for: .lbm), [])
        XCTAssertEqual(metadata.diagnostics(for: .bsa), [])
        XCTAssertEqual(metadata.diagnostics(for: .ibw), [])
    }

    func testSUVBodyWeightAcceptsAlreadyNormalizedGMLUnits() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [5],
            modality: "PT",
            extraElements: [
                string(.units, vr: .CS, "GML")
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let value = try XCTUnwrap(decoder.quantitativeValue(at: 0, suvType: .bw))
        let metadata = try XCTUnwrap(decoder.quantitativeValueProfile.suvMetadata)

        XCTAssertEqual(value.physicalValue, 5.0)
        XCTAssertEqual(metadata.diagnostics(for: .bw), [])
    }

    func testSUVBodyWeightRejectsGMLDeclaredAsLeanBodyMass() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [5],
            modality: "PT",
            extraElements: [
                string(.units, vr: .CS, "GML"),
                string(.suvType, vr: .CS, "LBM")
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let value = try XCTUnwrap(decoder.quantitativeValue(at: 0, suvType: .bw))
        let metadata = try XCTUnwrap(decoder.quantitativeValueProfile.suvMetadata)

        XCTAssertNil(value.physicalValue)
        XCTAssertTrue(metadata.diagnostics(for: .bw).contains { diagnostic in
            diagnostic.code == "incompatible_suv_type"
                && diagnostic.tag == DicomTag.suvType.rawValue
        })
    }

    func testSUVBodyWeightAppliesHalfLifeDecayBetweenInjectionAndAcquisition() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [5_000],
            modality: "PT",
            extraElements: [
                string(.units, vr: .CS, "BQML"),
                ds(.patientWeight, ["75"]),
                string(.decayCorrection, vr: .CS, "START"),
                string(.acquisitionTime, vr: .TM, "100000"),
                sequence(.radiopharmaceuticalInformationSequence, [
                    DicomDataSet(elements: [
                        ds(.radionuclideTotalDose, ["370000000"]),
                        ds(.radionuclideHalfLife, ["6586.2"]),
                        string(.radiopharmaceuticalStartTime, vr: .TM, "090000")
                    ])
                ])
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let value = try XCTUnwrap(decoder.quantitativeValue(at: 0, suvType: .bw))

        XCTAssertEqual(value.physicalValue ?? .nan, 1.480_375_080_6, accuracy: 0.000_000_1)
        XCTAssertEqual(decoder.quantitativeValueProfile.suvMetadata?.diagnostics(for: .bw), [])
    }

    func testSUVReportsMissingRequiredPETMetadata() throws {
        let url = try makeTemporaryDICOM(
            pixelValues: [1000],
            modality: "PT",
            extraElements: [
                string(.units, vr: .CS, "BQML")
            ]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let decoder = try DCMDecoder(contentsOf: url)
        let profile = decoder.quantitativeValueProfile
        let value = try XCTUnwrap(decoder.quantitativeValue(at: 0, suvType: .bw))
        let missingTags = Set(profile.suvMetadata?.diagnostics(for: .bw).compactMap(\.tag) ?? [])

        XCTAssertNil(value.physicalValue)
        XCTAssertTrue(missingTags.contains(DicomTag.patientWeight.rawValue))
        XCTAssertTrue(missingTags.contains(DicomTag.radionuclideTotalDose.rawValue))
        // Without Decay Correction nothing says what the values were corrected
        // to, and that is the first thing missing.
        XCTAssertTrue(missingTags.contains(DicomTag.decayCorrection.rawValue))
    }

    /// Decay Correction START: the dose is decayed from the administration to
    /// the scan's reference time. The frame's Decay Factor is already in the
    /// pixel values and takes no part. Numbers of a whole-body F-18 series:
    /// 73 kg, 378 MBq at 09:30:00, scan started at 10:37:00.859 (4020.859 s later).
    func testSUVScanStartDecaysTheDoseFromAdministration_notByTheFrameDecayFactor() throws {
        func metadata(decayFactor: Double?, acquisition: String?, series: String?) -> DicomSUVMetadata {
            DicomSUVMetadata(
                units: "BQML", suvType: nil, correctedImage: ["ATTN", "DECY"], decayCorrection: "START",
                decayFactor: decayFactor, patientWeightKg: 73, patientSizeMeters: nil, patientSex: nil,
                injectedDoseBq: 378_000_000, radionuclideHalfLifeSeconds: 6_586.2,
                radiopharmaceuticalStartTime: DicomTime("093000.000000"), radiopharmaceuticalStartDateTime: nil,
                acquisitionTime: acquisition.flatMap { DicomTime($0) }, seriesTime: series.flatMap { DicomTime($0) }
            )
        }
        let expected = 73_000.0 / (378_000_000.0 * pow(2.0, -4_020.859 / 6_586.2))
        XCTAssertEqual(expected, 2.948_6e-4, accuracy: 1e-8, "the hand calculation this test stands on")

        // A later bed position: its Acquisition Time is not the reference; the
        // earlier Series Time, the scan start, is (issue #2775).
        let laterBed = metadata(decayFactor: 1.090_752_2, acquisition: "104916.406000", series: "103700.859000")
        XCTAssertEqual(laterBed.suvValue(forActivityConcentrationBqPerMl: 1, type: .bw) ?? .nan, expected, accuracy: 1e-10)
        XCTAssertEqual(laterBed.decayTimeSeconds() ?? .nan, 4_020.859, accuracy: 0.001)
        // Every bed of the volume gets the same factor.
        let firstBed = metadata(decayFactor: 1, acquisition: "103700.859000", series: "103700.859000")
        XCTAssertEqual(
            firstBed.suvValue(forActivityConcentrationBqPerMl: 1, type: .bw),
            laterBed.suvValue(forActivityConcentrationBqPerMl: 1, type: .bw)
        )
        XCTAssertEqual(laterBed.diagnostics(for: .bw), [])

        // The Decay Factor changes nothing.
        let otherFactor = metadata(decayFactor: 1.4, acquisition: "104916.406000", series: "103700.859000")
        XCTAssertEqual(
            otherFactor.suvValue(forActivityConcentrationBqPerMl: 1, type: .bw),
            laterBed.suvValue(forActivityConcentrationBqPerMl: 1, type: .bw)
        )

        // A derived series: created an hour later, acquired at the scan start.
        let derived = metadata(decayFactor: 1.133_770_8, acquisition: "103700.859000", series: "113724.077000")
        XCTAssertEqual(derived.suvValue(forActivityConcentrationBqPerMl: 1, type: .bw) ?? .nan, expected, accuracy: 1e-10)

        // Series Time alone does not identify the acquisition reference.
        let seriesOnly = metadata(decayFactor: nil, acquisition: nil, series: "103700.859000")
        XCTAssertNil(seriesOnly.suvValue(forActivityConcentrationBqPerMl: 1, type: .bw))
        XCTAssertTrue(seriesOnly.diagnostics(for: .bw).contains { $0.tag == DicomTag.acquisitionTime.rawValue })
        let neither = metadata(decayFactor: 1.09, acquisition: nil, series: nil)
        XCTAssertNil(neither.suvValue(forActivityConcentrationBqPerMl: 1, type: .bw))
        XCTAssertTrue(neither.diagnostics(for: .bw).contains { $0.tag == DicomTag.acquisitionTime.rawValue })
    }

    func test_decayTiming_readsAcquisitionDateTimeAndSeparateDateTimeTags() {
        let radiopharm = DicomDataSet(elements: [
            string(.radiopharmaceuticalStartDateTime, vr: .DT, "20260920093000-0300")
        ])
        for elements in [
            [string(0x0008002A, vr: .DT, "20260922130000+0000")],
            [string(.acquisitionDate, vr: .DA, "20260922"),
             string(.acquisitionTime, vr: .TM, "130000"), string(0x00080201, vr: .SH, "+0000")]
        ] {
            let metadata = DicomSUVMetadata(dataSet: DicomDataSet(elements: elements), radiopharmaceuticalDataSet: radiopharm)
            XCTAssertEqual(metadata.decayTimeSeconds(), 174_600)
        }
    }

    func test_decayTiming_comparesDatedSeriesAndAcquisitionInstants() {
        let cases: [(start: String, seriesDate: String?, seriesTime: String, acquisition: String, expected: Double)] = [
            ("20260920233000", "20260920", "234500", "20260921003000", 900),
            ("20260920090000", "20260920", "093000", "20260921100000", 1_800),
            ("20260920230000", "20260921", "003000", "20260920234500", 2_700),
            ("20260920090000", nil, "093000", "20260921100000", 90_000)
        ]
        for test in cases {
            var elements = [
                string(.seriesTime, vr: .TM, test.seriesTime),
                string(0x0008002A, vr: .DT, test.acquisition)
            ]
            if let date = test.seriesDate { elements.append(string(.seriesDate, vr: .DA, date)) }
            let radiopharm = DicomDataSet(elements: [
                string(.radiopharmaceuticalStartDateTime, vr: .DT, test.start)
            ])
            let metadata = DicomSUVMetadata(dataSet: DicomDataSet(elements: elements), radiopharmaceuticalDataSet: radiopharm)
            XCTAssertEqual(metadata.decayTimeSeconds(), test.expected, "\(test)")
        }
    }

    func test_decayTiming_resolvesEachOffsetIndependently_andRejectsMixedUnknownOffsets() {
        let cases: [(startSuffix: String, acquisitionSuffix: String, datasetOffset: String?, expected: Double?)] = [
            ("+0100", "", "+0200", 1_800),
            ("", "+0200", "+0100", 1_800),
            ("+0100", "", nil, nil),
            ("", "+0200", nil, nil),
            ("+0100", "+0100", "+0200", 5_400),
            ("+0100", "+0100", nil, 5_400),
            ("", "", "+0200", 5_400),
            ("", "", nil, 5_400)
        ]
        for test in cases {
            var elements = [
                string(.units, vr: .CS, "BQML"),
                string(.decayCorrection, vr: .CS, "START"),
                string(0x0008002A, vr: .DT, "20260920110000" + test.acquisitionSuffix)
            ]
            if let offset = test.datasetOffset { elements.append(string(0x00080201, vr: .SH, offset)) }
            let radiopharm = DicomDataSet(elements: [
                string(.radiopharmaceuticalStartDateTime, vr: .DT, "20260920093000" + test.startSuffix)
            ])
            let metadata = DicomSUVMetadata(dataSet: DicomDataSet(elements: elements), radiopharmaceuticalDataSet: radiopharm)
            XCTAssertEqual(metadata.decayTimeSeconds(), test.expected, "\(test)")
            if test.expected == nil {
                XCTAssertTrue(metadata.diagnostics.contains { $0.code == "inconsistent_pet_timing" })
            }
        }
    }

    func test_decayTiming_appliesDatasetOffsetToAcquisitionTimeWithoutDate() {
        let cases: [(start: String, time: String, offset: String?, expected: Double?)] = [
            ("20260920093000+0100", "100000", "+0200", nil),
            ("20260920093000+0100", "110000", "+0200", 1_800),
            ("20260920093000+0100", "100000", "+0100", 1_800),
            ("20260920093000+0100", "100000", nil, nil),
            ("20260920233000+0100", "003000", "+0100", 3_600),
            ("20260920233000", "003000", nil, 3_600)
        ]
        for test in cases {
            let radiopharm = DicomDataSet(elements: [
                string(.radiopharmaceuticalStartDateTime, vr: .DT, test.start)
            ])
            var elements = [
                string(.units, vr: .CS, "BQML"),
                string(.decayCorrection, vr: .CS, "START"),
                string(.acquisitionTime, vr: .TM, test.time)
            ]
            if let offset = test.offset { elements.append(string(0x00080201, vr: .SH, offset)) }
            let metadata = DicomSUVMetadata(dataSet: DicomDataSet(elements: elements), radiopharmaceuticalDataSet: radiopharm)
            XCTAssertNil(metadata.acquisitionDateTime)
            XCTAssertEqual(metadata.decayTimeSeconds(), test.expected, "\(test)")
            if test.expected == nil {
                XCTAssertTrue(metadata.diagnostics.contains { $0.code == "inconsistent_pet_timing" })
            }
        }
    }

    func test_decayTiming_preservesDatesAndOffsets_andOnlyRollsOverTimeOnlyValues() throws {
        func metadata(start: String?, time: String, reference: String?,
                      series: String? = nil, seriesDate: String? = nil) -> DicomSUVMetadata {
            DicomSUVMetadata(
                units: "BQML", suvType: nil, correctedImage: ["DECY"], decayCorrection: "START",
                decayFactor: nil, patientWeightKg: 70, patientSizeMeters: nil, patientSex: nil,
                injectedDoseBq: 350_000_000, radionuclideHalfLifeSeconds: 6_586.2,
                radiopharmaceuticalStartTime: DicomTime("233000"),
                radiopharmaceuticalStartDateTime: start.flatMap(DicomDateTime.init),
                acquisitionTime: DicomTime(time), seriesTime: series.flatMap(DicomTime.init),
                seriesDate: seriesDate.flatMap(DicomDate.init),
                acquisitionDateTime: reference.flatMap(DicomDateTime.init)
            )
        }
        let nextDay = metadata(start: "20260920233000", time: "003000", reference: "20260921003000")
        XCTAssertEqual(nextDay.decayTimeSeconds(), 3_600)
        let twoDays = metadata(start: "20260920093000", time: "100000", reference: "20260922100000")
        XCTAssertEqual(twoDays.decayTimeSeconds(), 174_600)
        let offsets = metadata(start: "20260920093000-0300", time: "130000", reference: "20260920130000+0000")
        XCTAssertEqual(offsets.decayTimeSeconds(), 1_800)
        XCTAssertEqual(metadata(start: nil, time: "234500", reference: nil).decayTimeSeconds(), 900)
        XCTAssertEqual(metadata(start: nil, time: "003000", reference: nil).decayTimeSeconds(), 3_600)
        for series in [nil, "094500"] {
            let reversed = metadata(start: "20260921093000", time: "100000", reference: "20260920100000", series: series)
            XCTAssertNil(reversed.decayTimeSeconds())
            XCTAssertNil(reversed.suvValue(forActivityConcentrationBqPerMl: 1, type: .bw))
            XCTAssertTrue(reversed.diagnostics.contains { $0.code == "inconsistent_pet_timing" })
        }
        for series in ["094500", "110000"] {
            let ambiguous = metadata(start: "20260920093000", time: "100000", reference: nil,
                                     series: series, seriesDate: "20260920")
            XCTAssertNil(ambiguous.decayTimeSeconds())
            XCTAssertNil(ambiguous.suvValue(forActivityConcentrationBqPerMl: 1, type: .bw))
            XCTAssertTrue(ambiguous.diagnostics.contains { $0.code == "inconsistent_pet_timing" })
        }
        let conflicting = metadata(start: "20260920093000", time: "100000", reference: "20260920110000")
        XCTAssertNil(conflicting.decayTimeSeconds())
        XCTAssertTrue(conflicting.diagnostics(for: .bw).contains { $0.code == "inconsistent_pet_timing" })
    }

    func testSUVDecayReference_followsDecayCorrection() {
        func metadata(_ decayCorrection: String?, corrected: [String] = []) -> DicomSUVMetadata {
            DicomSUVMetadata(
                units: "BQML", suvType: nil, correctedImage: corrected, decayCorrection: decayCorrection,
                decayFactor: 1.09, patientWeightKg: 70, patientSizeMeters: nil, patientSex: nil,
                injectedDoseBq: 350_000_000, radionuclideHalfLifeSeconds: 6_586.2,
                radiopharmaceuticalStartTime: DicomTime("090000"), radiopharmaceuticalStartDateTime: nil,
                acquisitionTime: DicomTime("100000"), seriesTime: nil
            )
        }
        // Corrected to the administration: the dose as injected.
        let admin = metadata("ADMIN")
        XCTAssertEqual(admin.decayReference, .administration)
        XCTAssertEqual(admin.suvValue(forActivityConcentrationBqPerMl: 1_000, type: .bw) ?? .nan, 0.2, accuracy: 1e-9)

        // Not corrected: no SUV, and the reason is said.
        let none = metadata("NONE")
        XCTAssertNil(none.decayReference)
        XCTAssertNil(none.suvValue(forActivityConcentrationBqPerMl: 1_000, type: .bw))
        XCTAssertTrue(none.diagnostics(for: .bw).contains { $0.code == "decay_not_corrected" })

        // Corrected Image alone does not say what the values were corrected to.
        let corrected = metadata(nil, corrected: ["DECY"])
        XCTAssertNil(corrected.decayReference)
        XCTAssertNil(corrected.suvValue(forActivityConcentrationBqPerMl: 1_000, type: .bw))
        XCTAssertTrue(corrected.diagnostics(for: .bw).contains {
            $0.tag == DicomTag.decayCorrection.rawValue
                && $0.code == "missing_required_metadata"
                && $0.message.contains("Decay Correction")
        })
        let silent = metadata(nil)
        XCTAssertNil(silent.suvValue(forActivityConcentrationBqPerMl: 1_000, type: .bw))
        XCTAssertTrue(silent.diagnostics(for: .bw).contains { $0.tag == DicomTag.decayCorrection.rawValue })
    }

    private func makeTemporaryDICOM(
        pixelValues: [UInt16],
        frameCount: Int = 1,
        modality: String = "OT",
        extraElements: [DicomDataElement] = []
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quantitative_values_\(UUID().uuidString).dcm")
        let dataSet = DicomDataSet(elements: [
            string(0x00080016, vr: .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(.sopInstanceUID, vr: .UI, "1.2.826.0.1.3680043.10.224.\(Int.random(in: 1...999999))"),
            string(.modality, vr: .CS, modality),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            us(.rows, 1),
            us(.columns, pixelValues.count / frameCount),
            string(.numberOfFrames, vr: .IS, String(frameCount)),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 0),
            bytes(.pixelData, vr: .OW, Data(littleEndianBytes(values: pixelValues)))
        ] + extraElements)

        let data = try DicomDataSetWriter.part10Data(from: dataSet)
        try data.write(to: url)
        return url
    }

    private func unitSequence(codeValue: String, codingScheme: String, meaning: String) -> DicomDataElement {
        sequence(.measurementUnitsCodeSequence, [
            DicomDataSet(elements: [
                string(.codeValue, vr: .SH, codeValue),
                string(.codingSchemeDesignator, vr: .SH, codingScheme),
                string(.codeMeaning, vr: .LO, meaning)
            ])
        ])
    }

    private func sequence(_ tag: DicomTag, _ dataSets: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(
            tag: tag.rawValue,
            vr: .SQ,
            value: .sequence(dataSets.map { DicomSequenceItem(dataSet: $0) })
        )
    }

    private func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        string(tag.rawValue, vr: vr, value)
    }

    private func string(_ tag: Int, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings([value]))
    }

    private func ds(_ tag: DicomTag, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .DS, value: .strings(values))
    }

    private func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        us(tag, [value])
    }

    private func us(_ tag: DicomTag, _ values: [Int]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers(values.map(UInt.init)))
    }

    private func fd(_ tag: DicomTag, _ values: [Double]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .FD, value: .floats(values))
    }

    private func bytes(_ tag: DicomTag, vr: DicomVR, _ value: Data) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .bytes(value))
    }

    private func littleEndianBytes(values: [UInt16]) -> [UInt8] {
        values.flatMap { value in
            withUnsafeBytes(of: value.littleEndian) { Array($0) }
        }
    }
}
