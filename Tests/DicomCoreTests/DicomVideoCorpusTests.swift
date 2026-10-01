import Foundation
import XCTest
@testable import DicomCore

final class DicomVideoCorpusTests: XCTestCase {
    static func data(_ fixture: String = "known-pframes.h264", kind: DicomVideoStorageKind = .endoscopic,
                     syntax: DicomTransferSyntax = .mpeg4AVCH264HighProfileLevel41,
                     vector: Bool = false, fragmented: Bool = false) throws -> DicomDataSet {
        let stream = try DicomVideoStreamInspectorTests.fixture(fixture)
        let fragments: [Data]
        if fragmented {
            let split = (stream.count / 3) & ~1
            fragments = [stream.subdata(in: 0..<split), stream.subdata(in: split..<split * 2), stream.subdata(in: split * 2..<stream.count)]
        } else { fragments = [stream] }
        let duration = syntax == .mpeg2MainProfileMainLevel ? 40.0 : 1000.0 / 12
        let pixels = try DicomVideoPixelData(fragments: fragments, transferSyntax: syntax,
            columns: 128, rows: 64, numberOfFrames: 96,
            frameTimeMilliseconds: vector ? nil : duration,
            frameTimeVectorMilliseconds: vector ? [0] + Array(repeating: duration, count: 95) : [])
        var data = try DicomVideoBuilder.dataSet(video: pixels, options: .init(kind: kind,
            sopInstanceUID: "2.25.234913", studyInstanceUID: "2.25.2349", seriesInstanceUID: "2.25.23491",
            patientName: "Video^Synthetic", patientID: "VIDEO", studyID: "2349", studyDate: "20260910", studyTime: "120000",
            seriesNumber: 1, instanceNumber: 1))
        for (tag, vr) in [(0x00100030, DicomVR.DA), (0x00100040, .CS), (0x00080050, .SH),
                          (0x00080090, .PN), (0x00080070, .LO), (0x00200020, .CS)] {
            data = data.setting(.init(tag: tag, vr: vr, value: .strings([])))
        }
        data = data.setting(.init(tag: 0x00082218, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
            .init(tag: 0x00080100, vr: .SH, value: .strings(["818981001"])),
            .init(tag: 0x00080102, vr: .SH, value: .strings(["SCT"])),
            .init(tag: 0x00080104, vr: .LO, value: .strings(["Abdomen"]))
        ]))])))
        data = data.setting(.init(tag: 0x00280034, vr: .IS, value: .strings(["1", "1"])))
        data = data.setting(.init(tag: 0x00400555, vr: .SQ, value: .sequence([])))
        return data
    }

    static func bytes(_ data: DicomDataSet, syntax: DicomTransferSyntax) throws -> Data {
        try DicomDataSetWriter.part10Data(from: data, options: .init(transferSyntax: syntax,
            mediaStorageSOPClassUID: data.string(for: 0x00080016), mediaStorageSOPInstanceUID: data.string(for: 0x00080018)))
    }

    func test_conditionalModules_requireExternalFactsForAllVideoProfiles() throws {
        func facts(_ specimen: DicomAttributeRule.Truth, _ extraction: DicomAttributeRule.Truth) -> DicomCompositeImageModules.Conditions {
            .init(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied, pairedBodyPart: .unsatisfied,
                  temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied,
                  imagingSubjectIsSpecimen: specimen, frameLevelRetrieveResponse: extraction)
        }
        let layers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
        for kind in DicomVideoStorageKind.allCases {
            let data = try Self.data(kind: kind)
            let bytes = try Self.bytes(data, syntax: .mpeg4AVCH264HighProfileLevel41)
            let unknown = try DicomInstanceValidator.validate(bytes, imageConditions: facts(.undetermined, .undetermined))
            XCTAssertEqual(unknown.outcome(requiring: layers), .incomplete)
            for tag in [0x00400560, 0x00081164] {
                XCTAssertTrue(unknown.diagnostics.contains { $0.code == .conditionUndetermined && $0.path == [.tag(tag)] })
            }
            for (specimen, extraction, tag) in [(DicomAttributeRule.Truth.satisfied, DicomAttributeRule.Truth.unsatisfied, 0x00400560),
                                               (.unsatisfied, .satisfied, 0x00081164)] {
                let required = try DicomInstanceValidator.validate(bytes, imageConditions: facts(specimen, extraction))
                XCTAssertEqual(required.outcome(requiring: layers), .failed)
                XCTAssertTrue(required.diagnostics.contains { $0.code == .requiredAttributeMissing && $0.path == [.tag(tag)] })
            }
        }
    }

    func test_corpus_qualifiesVideoAndSeparatesTemporalLimitations() throws {
        let base = try Self.data()
        func text(_ tag: Int, _ value: String, _ vr: DicomVR = .CS) -> DicomDataElement {
            .init(tag: tag, vr: vr, value: .strings([value]))
        }
        var full = DicomVideoCine()
        full.frameTimeMilliseconds = 1000 / 12; full.startTrim = 2; full.stopTrim = 95
        full.cineRate = 12; full.recommendedDisplayFrameRate = 12; full.preferredPlaybackSequencing = 1
        full.frameDelayMilliseconds = 10; full.imageTriggerDelayMilliseconds = 5
        full.effectiveDurationSeconds = 8; full.actualFrameDurationMilliseconds = 83
        full.multiplexedAudioChannels = []
        let extraction = DicomDataElement(tag: 0x00081164, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
            text(0x00081167, "2.25.234900", .UI),
            .init(tag: 0x00081161, vr: .UL, value: .unsignedIntegers(Array(1...96).map(UInt.init)))
        ]))]))
        let h264 = DicomTransferSyntax.mpeg4AVCH264HighProfileLevel41
        var cases: [(String, DicomDataSet, DicomTransferSyntax, Bool)] = [
            ("video-endoscopic-h264-pframes", base, h264, true),
            ("video-photographic-h264-bframes", try Self.data("known-bframes.h264", kind: .photographic, vector: true), h264, true),
            ("video-microscopic-hevc", try Self.data("known-hevc.hevc", kind: .microscopic, syntax: .hevcH265MainProfileLevel51), .hevcH265MainProfileLevel51, true),
            ("video-endoscopic-mpeg2", try Self.data("known-mpeg2.m2v", syntax: .mpeg2MainProfileMainLevel), .mpeg2MainProfileMainLevel, true),
            ("video-fragmented-h264", try Self.data(syntax: .mpeg4AVCH264HighProfileLevel41Fragmentable, fragmented: true), .mpeg4AVCH264HighProfileLevel41Fragmentable, true),
            ("video-cine-full-module", try full.applying(to: base), h264, true),
            ("video-frame-extraction", base.setting(extraction), h264, true),
            ("video-modality-wrong", base.setting(text(0x00080060, "CT")), h264, false),
            ("video-frame-count-mismatch", base.setting(text(0x00280008, "95", .IS)), h264, false),
            ("video-dimensions-mismatch", base.setting(.init(tag: 0x00280010, vr: .US, value: .unsignedIntegers([96]))), h264, false),
            ("video-frame-time-vector-length", base.setting(.init(tag: 0x00280009, vr: .AT, value: .unsignedIntegers([0x00181065])))
                .setting(.init(tag: 0x00181065, vr: .DS, value: .strings(["0", "40"]))), h264, false),
            ("video-lossy-flag-missing", base.removing(0x00282110), h264, false),
            ("video-forbidden-module-present", base.setting(text(0x00281050, "128", .DS)).setting(text(0x00281051, "256", .DS)), h264, false),
            ("video-timeline-open-gop", try Self.data("unsupported-open-gop.h264"), h264, true)
        ]
        // Each qualified SOP Class needs its own positive and negative evidence, even when it shares the VL rules.
        let invalidCases = cases.filter { !$0.3 }
        for (kind, suffix, modality) in [(DicomVideoStorageKind.microscopic, "microscopic", "GM"),
                                       (.photographic, "photographic", "XC")] {
            for (name, data, syntax, _) in invalidCases {
                var variant = data.setting(text(0x00080016, kind.storageSOPClassUID, .UI))
                if name != "video-modality-wrong" { variant.set(text(0x00080060, modality)) }
                cases.append((name + "-" + suffix, variant, syntax, false))
            }
            cases.append(("video-frame-extraction-" + suffix, try Self.data(kind: kind).setting(extraction), h264, true))
        }
        for kind in DicomVideoStorageKind.allCases {
            let specimen = try Self.data(kind: kind)
                .setting(text(0x00400512, "Container-2370", .LO))
                .setting(.init(tag: 0x00400513, vr: .SQ, value: .sequence([])))
                .setting(.init(tag: 0x00400518, vr: .SQ, value: .sequence([])))
                .setting(.init(tag: 0x00400560, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
                    text(0x00400551, "Specimen-2370", .LO), text(0x00400554, "2.25.2370", .UI),
                    .init(tag: 0x00400562, vr: .SQ, value: .sequence([])),
                    .init(tag: 0x00400610, vr: .SQ, value: .sequence([]))
                ]))])))
            cases.append(("video-specimen-" + kind.defaultModality.lowercased(), specimen, h264, true))
        }
        XCTAssertEqual(cases.count, 31)
        let layers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
        let directory = ProcessInfo.processInfo.environment["DICOM_VIDEO_CORPUS_DIRECTORY"].map { URL(fileURLWithPath: $0) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        for (name, data, syntax, valid) in cases {
            let specimen = name.hasPrefix("video-specimen-")
            let extraction = name.hasPrefix("video-frame-extraction")
            let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
                pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied,
                imagingSubjectIsSpecimen: specimen ? .satisfied : .unsatisfied,
                frameLevelRetrieveResponse: extraction ? .satisfied : .unsatisfied)
            let bytes = try Self.bytes(data, syntax: syntax)
            let report = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
            let outcome = report.outcome(requiring: layers)
            XCTAssertEqual(outcome, valid ? .passed : .failed, "\(name): \(report.diagnostics)")
            let video = try XCTUnwrap(DCMDecoder(data: bytes).video)
            let timeline = try DicomVideoTimeline(video: video)
            let description = timeline.description
            var metadata: [String: Any] = ["outcome": outcome.rawValue, "exit": valid ? 0 : 1,
                "facts": ["subject-is-specimen=" + (specimen ? "yes" : "no"),
                          "frame-retrieve-response=" + (extraction ? "yes" : "no")],
                "sopClass": data.string(for: 0x00080016)!, "width": description.width!, "height": description.height!,
                "profile": description.profile ?? "unknown", "codec": video.codec.rawValue,
                "frameCount": description.accessUnits.count, "sliceTypes": description.accessUnits.map(\.sliceType),
                "presentationOrder": description.accessUnits.map { $0.presentationIndex ?? -1 },
                "pts": timeline.accessUnits.map { $0.pts ?? -1 }, "timescale": timeline.timescale ?? 0,
                "temporalReferences": description.accessUnits.map { $0.temporalReference ?? -1 }]
            if name == "video-timeline-open-gop" {
                XCTAssertThrowsError(try timeline.temporalRead(range: 0..<1)) {
                    XCTAssertEqual($0 as? DicomVideoInspectionError, .openGOPDependencies)
                }
                metadata["temporalReadRefusal"] = "openGOPDependencies"
            }
            if let directory {
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }
}
