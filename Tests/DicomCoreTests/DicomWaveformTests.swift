import XCTest
@testable import DicomCore

final class DicomWaveformTests: XCTestCase {
    func testSyntheticECGWaveformRoundTripsChannelsSamplingUnitsAndReferences() throws {
        let microvolt = DicomCodedConcept(codeValue: "uV", codingSchemeDesignator: "UCUM", codeMeaning: "microvolt")
        let sourceReference = DicomWaveformSourceReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9404",
            referencedWaveformChannels: [DicomWaveformChannelReference(multiplexGroupNumber: 1, channelNumber: 1)]
        )
        let group = DicomWaveformMultiplexGroup(
            label: "REST",
            samplingFrequency: 500,
            timeOffsetMilliseconds: 12.5,
            triggerTimeOffsetMilliseconds: -2,
            triggerSamplePosition: 2,
            sampleInterpretation: .signed16,
            waveformDataDisplayScale: 25,
            channels: [
                DicomWaveformChannel(
                    number: 1,
                    label: "I",
                    status: ["OK"],
                    source: DicomCodedConcept(
                        codeValue: "MDC_ECG_LEAD_I",
                        codingSchemeDesignator: "MDC",
                        codeMeaning: "Lead I"
                    ),
                    sourceWaveformReferences: [sourceReference],
                    sensitivity: 4.88,
                    sensitivityUnits: microvolt,
                    baseline: 0,
                    bitsStored: 16,
                    lowFrequency: 0.05,
                    highFrequency: 150,
                    notchFrequency: 60,
                    samples: [100, 104, 98, 110]
                ),
                DicomWaveformChannel(
                    number: 2,
                    label: "II",
                    source: DicomCodedConcept(
                        codeValue: "MDC_ECG_LEAD_II",
                        codingSchemeDesignator: "MDC",
                        codeMeaning: "Lead II"
                    ),
                    sensitivity: 4.88,
                    sensitivityUnits: microvolt,
                    bitsStored: 16,
                    samples: [-10, -12, -8, -6]
                )
            ]
        )

        let decoder = try open(
            groups: [group],
            options: DicomWaveformBuildOptions(
                kind: .twelveLeadECG,
                sopInstanceUID: "2.25.9400",
                studyInstanceUID: "2.25.9401",
                seriesInstanceUID: "2.25.9402",
                patientName: "Waveform^Patient",
                patientID: "ECG-1",
                studyID: "ECG-STUDY",
                studyDate: "20260528",
                studyTime: "160000",
                seriesNumber: 3,
                instanceNumber: 1,
                seriesDate: "20260528",
                seriesTime: "160100",
                seriesDescription: "Synthetic ECG",
                contentDate: "20260528",
                contentTime: "160200"
            )
        )
        let waveform = try XCTUnwrap(decoder.waveform)
        let decodedGroup = try XCTUnwrap(waveform.multiplexGroups.first)
        let decodedLeadI = try XCTUnwrap(decodedGroup.channels.first)
        let decodedLeadII = try XCTUnwrap(decodedGroup.channels.dropFirst().first)

        XCTAssertEqual(waveform.kind, .twelveLeadECG)
        XCTAssertEqual(waveform.sopClassUID, DicomWaveform.twelveLeadECGWaveformStorageSOPClassUID)
        XCTAssertEqual(waveform.sopInstanceUID, "2.25.9400")
        XCTAssertEqual(waveform.studyInstanceUID, "2.25.9401")
        XCTAssertEqual(waveform.seriesInstanceUID, "2.25.9402")
        XCTAssertEqual(waveform.modality, "ECG")
        XCTAssertEqual(waveform.patientName?.familyName, "Waveform")
        XCTAssertEqual(waveform.patientID, "ECG-1")
        XCTAssertEqual(waveform.totalChannelCount, 2)

        XCTAssertEqual(decodedGroup.label, "REST")
        XCTAssertEqual(decodedGroup.samplingFrequency, 500)
        XCTAssertEqual(decodedGroup.timeOffsetMilliseconds, 12.5)
        XCTAssertEqual(decodedGroup.triggerTimeOffsetMilliseconds, -2)
        XCTAssertEqual(decodedGroup.triggerSamplePosition, 2)
        XCTAssertEqual(decodedGroup.sampleInterpretation, .signed16)
        XCTAssertEqual(decodedGroup.waveformDataDisplayScale, 25)
        XCTAssertEqual(decodedGroup.numberOfSamples, 4)

        XCTAssertEqual(decodedLeadI.number, 1)
        XCTAssertEqual(decodedLeadI.label, "I")
        XCTAssertEqual(decodedLeadI.status, ["OK"])
        XCTAssertEqual(decodedLeadI.source?.codeValue, "MDC_ECG_LEAD_I")
        XCTAssertEqual(decodedLeadI.sensitivity, 4.88)
        XCTAssertEqual(decodedLeadI.sensitivityUnits, microvolt)
        XCTAssertEqual(decodedLeadI.bitsStored, 16)
        XCTAssertEqual(decodedLeadI.lowFrequency, 0.05)
        XCTAssertEqual(decodedLeadI.highFrequency, 150)
        XCTAssertEqual(decodedLeadI.notchFrequency, 60)
        XCTAssertEqual(decodedLeadI.samples, [100, 104, 98, 110])
        XCTAssertEqual(decodedLeadI.sourceWaveformReferences, [sourceReference])
        XCTAssertEqual(decodedLeadI.physicalValue(for: 100), 488)

        XCTAssertEqual(decodedLeadII.number, 2)
        XCTAssertEqual(decodedLeadII.label, "II")
        XCTAssertEqual(decodedLeadII.source?.codeValue, "MDC_ECG_LEAD_II")
        XCTAssertEqual(decodedLeadII.samples, [-10, -12, -8, -6])
    }

    func testMultiChannelRespiratoryWaveformRoundTripsPhysicalAndTemporalScale() throws {
        let litersPerSecond = DicomCodedConcept(
            codeValue: "L/s",
            codingSchemeDesignator: "UCUM",
            codeMeaning: "liter per second"
        )
        let decoder = try open(
            groups: [
                DicomWaveformMultiplexGroup(
                    label: "Airflow",
                    samplingFrequency: 100,
                    timeOffsetMilliseconds: 250,
                    sampleInterpretation: .signed16,
                    waveformDataDisplayScale: 50,
                    channels: [
                        DicomWaveformChannel(
                            number: 1,
                            label: "Nasal pressure",
                            sensitivity: 0.01,
                            sensitivityUnits: litersPerSecond,
                            sensitivityCorrectionFactor: 2,
                            baseline: -0.5,
                            samples: [-10, 0, 10]
                        ),
                        DicomWaveformChannel(
                            number: 2,
                            label: "Thermistor",
                            sensitivity: 0.02,
                            sensitivityUnits: litersPerSecond,
                            baseline: 1,
                            samples: [5, 10, 15]
                        )
                    ]
                ),
                DicomWaveformMultiplexGroup(
                    label: "Effort",
                    samplingFrequency: 25,
                    sampleInterpretation: .signed32,
                    channels: [
                        DicomWaveformChannel(label: "Thorax", samples: [100_000, 100_100])
                    ]
                )
            ],
            options: DicomWaveformBuildOptions(kind: .multiChannelRespiratory)
        )
        let waveform = try XCTUnwrap(decoder.waveform)

        XCTAssertEqual(waveform.kind, .multiChannelRespiratory)
        XCTAssertEqual(waveform.modality, "RESP")
        XCTAssertEqual(waveform.multiplexGroups.count, 2)
        XCTAssertEqual(waveform.totalChannelCount, 3)
        XCTAssertEqual(waveform.multiplexGroups[0].timeOffsetMilliseconds, 250)
        XCTAssertEqual(waveform.multiplexGroups[0].waveformDataDisplayScale, 50)
        XCTAssertEqual(waveform.multiplexGroups[0].channels[0].sensitivityUnits, litersPerSecond)
        XCTAssertEqual(waveform.multiplexGroups[0].channels[0].baseline, -0.5)
        XCTAssertEqual(waveform.multiplexGroups[0].channels[0].physicalValue(for: 10), -0.3)
        XCTAssertEqual(waveform.multiplexGroups[1].sampleInterpretation, .signed32)
    }

    func testMultiChannelRespiratoryBuilderRejectsUnsignedSamples() throws {
        let group = DicomWaveformMultiplexGroup(
            samplingFrequency: 100,
            sampleInterpretation: .unsigned16,
            channels: [DicomWaveformChannel(label: "Airflow", samples: [0, 1])]
        )

        XCTAssertThrowsError(try DicomWaveformBuilder.part10Data(
            multiplexGroups: [group],
            options: DicomWaveformBuildOptions(kind: .multiChannelRespiratory)
        )) { error in
            XCTAssertEqual(error as? DicomWaveformError, .unsupportedSampleInterpretation("US"))
        }
    }

    func testKnownWaveformRejectsPayloadWhenAnyMultiplexGroupIsMalformed() throws {
        var dataSet = try DicomWaveformBuilder.dataSet(
            multiplexGroups: [
                DicomWaveformMultiplexGroup(
                    samplingFrequency: 100,
                    channels: [DicomWaveformChannel(label: "Airflow", samples: [1, 2])]
                ),
                DicomWaveformMultiplexGroup(
                    samplingFrequency: 25,
                    channels: [DicomWaveformChannel(label: "Effort", samples: [3, 4])]
                )
            ],
            options: DicomWaveformBuildOptions(kind: .respiratory)
        )
        let groupItems = dataSet.sequenceItems(for: .waveformSequence)
        var malformedGroup = try XCTUnwrap(groupItems.last?.dataSet)
        var malformedPayload = try XCTUnwrap(malformedGroup.element(for: .waveformData)?.bytesValue)
        malformedPayload.append(0)
        malformedGroup.set(DicomDataElement(
            tag: DicomTag.waveformData.rawValue,
            vr: .OW,
            value: .bytes(malformedPayload)
        ))
        dataSet.set(DicomDataElement(
            tag: DicomTag.waveformSequence.rawValue,
            vr: .SQ,
            value: .sequence([
                try XCTUnwrap(groupItems.first),
                DicomSequenceItem(dataSet: malformedGroup)
            ])
        ))
        let malformedData = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomWaveform.respiratoryWaveformStorageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )

        XCTAssertNil(try open(data: malformedData).waveform)
    }

    func testBuilderRejectsInconsistentChannelSampleCounts() throws {
        let group = DicomWaveformMultiplexGroup(
            samplingFrequency: 250,
            channels: [
                DicomWaveformChannel(label: "I", samples: [1, 2, 3]),
                DicomWaveformChannel(label: "II", samples: [1, 2])
            ]
        )

        XCTAssertThrowsError(try DicomWaveformBuilder.part10Data(multiplexGroups: [group])) { error in
            XCTAssertEqual(error as? DicomWaveformError, .inconsistentSampleCounts(group: nil))
        }
    }

    func testBuilderRejectsOutOfRangeSamplesForInterpretation() throws {
        let group = DicomWaveformMultiplexGroup(
            samplingFrequency: 250,
            sampleInterpretation: .signed8,
            channels: [DicomWaveformChannel(label: "I", samples: [0, 128])]
        )

        XCTAssertThrowsError(try DicomWaveformBuilder.part10Data(multiplexGroups: [group])) { error in
            XCTAssertEqual(error as? DicomWaveformError, .sampleOutOfRange(value: 128, interpretation: "SB"))
        }
    }

    func test_builder_mixedLegacyDisplayScales_rejectsLossyRootProjection() {
        let variants: [[Double?]] = [[25, 50], [nil, 25, 50], [25, nil, 50]]
        for scales in variants {
            let groups = scales.map {
                DicomWaveformMultiplexGroup(samplingFrequency: 500, waveformDataDisplayScale: $0,
                    channels: [.init(samples: [1, 2, 3])])
            }
            XCTAssertThrowsError(try DicomWaveformBuilder.dataSet(multiplexGroups: groups)) {
                XCTAssertEqual($0 as? DicomWaveformError, .inconsistentDisplayScales)
            }
        }
    }

    func test_builder_matchingAndUnspecifiedLegacyDisplayScales_roundTripAtRoot() throws {
        let variants: [[Double?]] = [[nil, nil], [25, 25], [nil, 25], [25, nil]]
        for scales in variants {
            let groups = scales.map {
                DicomWaveformMultiplexGroup(samplingFrequency: 500, waveformDataDisplayScale: $0,
                    channels: [.init(samples: [1, 2, 3])])
            }
            let scale = scales.compactMap { $0 }.first
            let bytes = try DicomWaveformBuilder.part10Data(multiplexGroups: groups)
            let decoder = try DCMDecoder(data: bytes)
            XCTAssertEqual(decoder.dataSet.float(for: .waveformDataDisplayScale), scale)
            let waveform = try XCTUnwrap(decoder.waveform)
            XCTAssertEqual(waveform.multiplexGroups.map(\.waveformDataDisplayScale), [scale, scale])
        }
    }

    func test_builder_explicitDisplayScale_overridesLegacyGroupScales() throws {
        let groups = [25.0, 50.0].map {
            DicomWaveformMultiplexGroup(samplingFrequency: 500, waveformDataDisplayScale: $0,
                channels: [.init(samples: [1, 2, 3])])
        }
        let data = try DicomWaveformBuilder.dataSet(multiplexGroups: groups,
            displayScale: .init(millimetersPerSecond: 100))
        XCTAssertEqual(data.float(for: .waveformDataDisplayScale), 100)
        XCTAssertTrue(data.sequenceItems(for: .waveformSequence).allSatisfy {
            !$0.dataSet.contains(DicomTag.waveformDataDisplayScale.rawValue)
        })
    }

    func testWaveformRoundTripsImplicitVRLittleEndian() throws {
        let group = DicomWaveformMultiplexGroup(
            samplingFrequency: 250,
            channels: [
                DicomWaveformChannel(label: "I", samples: [1, 2, 3]),
                DicomWaveformChannel(label: "II", samples: [-1, -2, -3])
            ]
        )
        let dataSet = try DicomWaveformBuilder.dataSet(
            multiplexGroups: [group],
            options: DicomWaveformBuildOptions(
                sopInstanceUID: "2.25.9410",
                studyInstanceUID: "2.25.9411",
                seriesInstanceUID: "2.25.9412"
            )
        )
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                transferSyntax: .implicitVRLittleEndian,
                mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID),
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )

        let waveform = try XCTUnwrap(open(data: data).waveform)
        let decodedGroup = try XCTUnwrap(waveform.multiplexGroups.first)

        XCTAssertEqual(decodedGroup.sampleInterpretation, .signed16)
        XCTAssertEqual(decodedGroup.channels.map(\.samples), [[1, 2, 3], [-1, -2, -3]])
    }

    func testNeurophysiologyWaveformsRoundTripLargeCalibratedChannelSets() throws {
        let cases: [(DicomWaveformStorageKind, String)] = [
            (.routineScalpEEG, "EEG"),
            (.electromyogram, "EMG"),
            (.electrooculogram, "EOG"),
            (.sleepEEG, "EEG")
        ]
        let microvolts = DicomCodedConcept(
            codeValue: "uV",
            codingSchemeDesignator: "UCUM",
            codeMeaning: "microvolt"
        )
        let channels = (1...128).map { number in
            DicomWaveformChannel(
                number: number,
                label: "Channel \(number)",
                sensitivity: 0.25,
                sensitivityUnits: microvolts,
                sensitivityCorrectionFactor: 2,
                baseline: -1,
                samples: [0, number, -number, number * 2]
            )
        }

        for (kind, modality) in cases {
            let waveform = try XCTUnwrap(open(
                groups: [
                    DicomWaveformMultiplexGroup(
                        label: "Neurophysiology",
                        samplingFrequency: 512,
                        timeOffsetMilliseconds: 125,
                        channels: channels
                    )
                ],
                options: DicomWaveformBuildOptions(kind: kind)
            ).waveform)

            XCTAssertEqual(waveform.kind, kind)
            XCTAssertEqual(waveform.modality, modality)
            XCTAssertEqual(waveform.totalChannelCount, 128)
            let group = try XCTUnwrap(waveform.multiplexGroups.first)
            XCTAssertEqual(group.samplingFrequency, 512)
            XCTAssertEqual(group.timeOffsetMilliseconds, 125)
            let lastChannel = try XCTUnwrap(group.channels.last)
            XCTAssertEqual(lastChannel.sensitivityUnits, microvolts)
            XCTAssertEqual(lastChannel.physicalValue(for: 256), 127)
        }
    }

    func testAudioWaveformsRoundTripSupportedPCMAndCompandedFormats() throws {
        let cases: [(DicomWaveformStorageKind, DicomWaveformSampleInterpretation, [Int])] = [
            (.basicVoiceAudio, .unsigned8, [0, 128, 255]),
            (.basicVoiceAudio, .muLaw8, [0, 127, 255]),
            (.basicVoiceAudio, .aLaw8, [0, 85, 255]),
            (.generalAudio, .signed8, [-128, 0, 127]),
            (.generalAudio, .signed16, [-32_768, 0, 32_767])
        ]

        for (kind, interpretation, samples) in cases {
            let frequency = kind == .basicVoiceAudio ? 8_000.0 : 44_100.0
            let waveform = try XCTUnwrap(open(
                groups: [
                    DicomWaveformMultiplexGroup(
                        samplingFrequency: frequency,
                        sampleInterpretation: interpretation,
                        channels: [DicomWaveformChannel(label: "Audio", samples: samples)]
                    )
                ],
                options: DicomWaveformBuildOptions(kind: kind)
            ).waveform)

            XCTAssertEqual(waveform.kind, kind)
            XCTAssertEqual(waveform.modality, "AU")
            XCTAssertEqual(waveform.multiplexGroups.first?.sampleInterpretation, interpretation)
            XCTAssertEqual(waveform.multiplexGroups.first?.channels.first?.samples, samples)
        }
    }

    func testAudioWaveformsRejectInvalidFrequencyChannelsAndInterleaving() throws {
        let invalidFrequency = try open(
            groups: [
                DicomWaveformMultiplexGroup(
                    samplingFrequency: 16_000,
                    sampleInterpretation: .unsigned8,
                    channels: [DicomWaveformChannel(samples: [0, 1])]
                )
            ],
            options: DicomWaveformBuildOptions(kind: .basicVoiceAudio)
        )
        XCTAssertNil(invalidFrequency.waveform)

        let invalidChannels = try open(
            groups: [
                DicomWaveformMultiplexGroup(
                    samplingFrequency: 44_100,
                    sampleInterpretation: .signed16,
                    channels: (0..<3).map { DicomWaveformChannel(label: "\($0)", samples: [0, 1]) }
                )
            ],
            options: DicomWaveformBuildOptions(kind: .generalAudio)
        )
        XCTAssertNil(invalidChannels.waveform)

        var dataSet = try DicomWaveformBuilder.dataSet(
            multiplexGroups: [
                DicomWaveformMultiplexGroup(
                    samplingFrequency: 8_000,
                    sampleInterpretation: .unsigned8,
                    channels: [DicomWaveformChannel(samples: [0, 1])]
                )
            ],
            options: DicomWaveformBuildOptions(kind: .basicVoiceAudio)
        )
        var groupDataSet = try XCTUnwrap(dataSet.sequenceItems(for: .waveformSequence).first?.dataSet)
        var malformedPayload = try XCTUnwrap(groupDataSet.element(for: .waveformData)?.bytesValue)
        malformedPayload.append(contentsOf: [2, 3])
        groupDataSet.set(DicomDataElement(
            tag: DicomTag.waveformData.rawValue,
            vr: .OB,
            value: .bytes(malformedPayload)
        ))
        dataSet.set(DicomDataElement(
            tag: DicomTag.waveformSequence.rawValue,
            vr: .SQ,
            value: .sequence([DicomSequenceItem(dataSet: groupDataSet)])
        ))
        let malformedData = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: DicomWaveform.basicVoiceAudioWaveformStorageSOPClassUID,
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
        XCTAssertNil(try open(data: malformedData).waveform)
    }

    func testWaveformScopeListsSupportedStorageKindsAndSampleInterpretations() throws {
        XCTAssertEqual(
            DicomWaveformStorageKind.allCases.map(\.storageSOPClassUID),
            [
                DicomWaveform.twelveLeadECGWaveformStorageSOPClassUID,
                DicomWaveform.generalECGWaveformStorageSOPClassUID,
                DicomWaveform.ambulatoryECGWaveformStorageSOPClassUID,
                DicomWaveform.general32BitECGWaveformStorageSOPClassUID,
                DicomWaveform.hemodynamicWaveformStorageSOPClassUID,
                DicomWaveform.cardiacElectrophysiologyWaveformStorageSOPClassUID,
                DicomWaveform.arterialPulseWaveformStorageSOPClassUID,
                DicomWaveform.respiratoryWaveformStorageSOPClassUID,
                DicomWaveform.multiChannelRespiratoryWaveformStorageSOPClassUID,
                DicomWaveform.routineScalpEEGWaveformStorageSOPClassUID,
                DicomWaveform.electromyogramWaveformStorageSOPClassUID,
                DicomWaveform.electrooculogramWaveformStorageSOPClassUID,
                DicomWaveform.sleepEEGWaveformStorageSOPClassUID,
                DicomWaveform.basicVoiceAudioWaveformStorageSOPClassUID,
                DicomWaveform.generalAudioWaveformStorageSOPClassUID
            ]
        )
        XCTAssertTrue(
            DicomWaveform.supportedStorageSOPClassUIDs
                .isSubset(of: DicomStorageSOPClassUIDs.commonClinicalStorage)
        )
        XCTAssertEqual(
            DicomWaveformSampleInterpretation.allCases.map(\.rawValue),
            ["SB", "UB", "SS", "US", "SL", "UL", "MB", "AB"]
        )
        XCTAssertEqual(DicomWaveformStorageKind.respiratory.defaultModality, "RESP")

        let matrixRow = try XCTUnwrap(DicomExportSupportMatrix.packageDefault.row(feature: "Waveform"))
        XCTAssertTrue(matrixRow.requiredTags.contains("Waveform Sequence"))
        XCTAssertTrue(matrixRow.unsupportedCases.contains("Float/double samples"))
        XCTAssertTrue(matrixRow.typedFailure.contains("DicomWaveformError"))
    }

    func testSeriesLoaderSkipsWaveformAsNonImageVolumeInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform_series_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("waveform.dcm")
        try DicomWaveformBuilder.write(
            multiplexGroups: [
                DicomWaveformMultiplexGroup(
                    samplingFrequency: 500,
                    channels: [DicomWaveformChannel(label: "I", samples: [1, 2, 3])]
                )
            ],
            to: url,
            options: DicomWaveformBuildOptions(seriesDescription: "Not a volume")
        )

        XCTAssertThrowsError(try DicomSeriesLoader().loadSeries(in: directory)) { error in
            guard case DicomSeriesLoaderError.noDicomFiles = error else {
                return XCTFail("Expected noDicomFiles after skipping Waveform, got \(error)")
            }
        }
    }

    func test_explicitCalibrationWithoutSensitivity_roundTrips() throws {
        let group = DicomWaveformMultiplexGroup(label: "Calibration", samplingFrequency: 500,
            sampleInterpretation: .signed16, channels: [
                .init(number: 1, sensitivityCorrectionFactor: 2, baseline: -1, samples: [1, 2]),
                .init(number: 2, samples: [3, 4]),
                .init(number: 3, sensitivity: 1, samples: [5, 6])
            ])
        let decoder = try open(groups: [group], options: .init())
        let channels = try XCTUnwrap(decoder.waveform?.multiplexGroups.first?.channels)
        XCTAssertNil(channels[0].sensitivity)
        XCTAssertEqual(channels[0].sensitivityCorrectionFactor, 2)
        XCTAssertEqual(channels[0].baseline, -1)
        XCTAssertNil(channels[1].sensitivityCorrectionFactor)
        XCTAssertNil(channels[1].baseline)
        XCTAssertEqual(channels[2].sensitivityCorrectionFactor, 1)
        XCTAssertEqual(channels[2].baseline, 0)
    }

    private func open(
        groups: [DicomWaveformMultiplexGroup],
        options: DicomWaveformBuildOptions
    ) throws -> DCMDecoder {
        let data = try DicomWaveformBuilder.part10Data(multiplexGroups: groups, options: options)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func open(data: Data) throws -> DCMDecoder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("waveform_implicit_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }
}
