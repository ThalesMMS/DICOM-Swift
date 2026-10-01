import Foundation
import CryptoKit
import XCTest
@testable import DicomCore

/// Profile-level corpus for the fifteen waveform IODs and the five encapsulated document IODs: module
/// usage, the A.34 content constraints, multiplex group coherence, annotation channel references, the
/// document modality/MIME/length rules, the model equipment and frame of reference, and the referenced
/// instances against supplied targets. The producers are the toolkit's own builders.
final class DicomWaveformDocumentCorpusTests: XCTestCase {
    func test_enhancedEquipmentUsesManufacturerFallbackAndPreservesSuppliedValue() throws {
        for kind in DicomWaveformStorageKind.allCases where kind.requiresEnhancedGeneralEquipment {
            for manufacturer in [nil, "", "  ", "Known producer"] as [String?] {
                let dataSet = try waveform(kind, manufacturer: manufacturer)
                XCTAssertEqual(dataSet.string(for: 0x00080070), manufacturer == "Known producer" ? manufacturer : "DICOM-Swift")
            }
        }
    }

    private enum Expectation {
        case passed
        case failed(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
        case incomplete(DicomValidationReport.Code, [DicomValidationReport.PathComponent])
    }

    private let facts = DicomCompositeImageModules.Conditions(nonHumanPatient: .unsatisfied, nonBipedalAnatomy: .unsatisfied,
        pairedBodyPart: .unsatisfied, temporallyRelatedSeries: .unsatisfied, calibratedImage: .unsatisfied)
    private let requiredLayers = Set(DicomValidationReport.Layer.allCases.filter { $0 != .operation })
    private let imageUID = "2.25.23289980", studyUID = "2.25.23289996", seriesUID = "2.25.23289997", instanceUID = "2.25.23289901"
    private let group: [DicomValidationReport.PathComponent] = [.tag(0x54000100), .item(0)]

    func test_originalCorpus_qualifiesWaveformAndEncapsulatedDocumentIODsAndRejectsViolations() async throws {
        let channel = group + [.tag(0x003A0200), .item(0)]
        let annotation: [DicomValidationReport.PathComponent] = [.tag(0x0040B020), .item(0)]
        var cases: [(String, (DicomDataSet) -> DicomDataSet, Expectation)] = []
        // One conformant instance per waveform IOD.
        for kind in DicomWaveformStorageKind.allCases {
            cases.append(("wf-\(kind.corpusName)", { _ in try! self.waveform(kind) }, .passed))
        }
        cases += [
            ("wf-hemodynamic-derived-without-sync", { _ in try! self.waveform(.hemodynamic, originality: "DERIVED").removingSynchronization() }, .passed),
            ("wf-ecg-annotated", { _ in try! self.waveform(.twelveLeadECG).setting(self.sequence(0x0040B020, [self.annotation(text: "Normal", channels: [1, 0])])) }, .passed),
            ("wf-ecg-source-reference", { _ in try! self.waveform(.twelveLeadECG, source: true) }, .passed),
            ("wf-ecg-modality-wrong", { _ in try! self.waveform(.twelveLeadECG).setting(self.text(0x00080060, "HD", .CS)) },
             .failed(.attributeValueNotAllowed, [.tag(0x00080060)])),
            ("wf-ecg-too-many-groups", { _ in try! self.waveform(.twelveLeadECG, groups: 6) }, .failed(.sequenceItemCountInvalid, [.tag(0x54000100)])),
            ("wf-ecg-channel-count-mismatch", { _ in try! self.waveform(.twelveLeadECG).replacingGroup { $0.setting(self.number(0x003A0005, 3)) } },
             .failed(.attributeValueContradiction, self.group + [.tag(0x003A0200)])),
            ("wf-ecg-samples-exceeded", { _ in try! self.waveform(.twelveLeadECG, samples: 16385) }, .failed(.attributeValueNotAllowed, self.group + [.tag(0x003A0010)])),
            ("wf-ecg-frequency-out-of-range", { _ in try! self.waveform(.twelveLeadECG, frequency: 100) }, .failed(.attributeValueNotAllowed, self.group + [.tag(0x003A001A)])),
            ("wf-ecg-interpretation-not-allowed", { _ in try! self.waveform(.twelveLeadECG, interpretation: .signed8) },
             .failed(.attributeValueNotAllowed, self.group + [.tag(0x54001006)])),
            ("wf-ecg-bits-allocated-mismatch", { _ in try! self.waveform(.twelveLeadECG).replacingGroup { $0.setting(self.number(0x54001004, 8)) } },
             .failed(.attributeValueContradiction, self.group + [.tag(0x54001004)])),
            ("wf-ecg-bits-stored-exceeds-allocated", { _ in try! self.waveform(.twelveLeadECG, bitsStored: 32) },
             .failed(.attributeValueContradiction, channel + [.tag(0x003A021A)])),
            ("wf-ecg-data-length-wrong", { _ in try! self.waveform(.twelveLeadECG).replacingGroup { $0.setting(.init(tag: 0x54001010, vr: .OW, value: .bytes(Data(count: 6)))) } },
             .failed(.attributeValueContradiction, self.group + [.tag(0x54001010)])),
            ("wf-ecg-originality-wrong", { _ in try! self.waveform(.twelveLeadECG, originality: "COPY") },
             .failed(.attributeValueNotAllowed, self.group + [.tag(0x003A0004)])),
            ("wf-ecg-missing-acquisition-datetime", { _ in try! self.waveform(.twelveLeadECG).removing(0x0008002A) },
             .failed(.requiredAttributeMissing, [.tag(0x0008002A)])),
            ("wf-ecg-missing-acquisition-context", { _ in try! self.waveform(.twelveLeadECG).removing(0x00400555) },
             .failed(.requiredAttributeMissing, [.tag(0x00400555)])),
            ("wf-ecg-annotation-unknown-channel", { _ in try! self.waveform(.twelveLeadECG).setting(self.sequence(0x0040B020, [self.annotation(text: "Normal", channels: [2, 1])])) },
             .failed(.referenceSelectionInvalid, annotation + [.tag(0x0040A0B0)])),
            ("wf-ecg-annotation-text-and-concept", { _ in try! self.waveform(.twelveLeadECG).setting(self.sequence(0x0040B020, [self.annotation(text: "Normal", channels: [1, 1])
                .setting(self.sequence(0x0040A043, [self.code("122147", "DCM", "Baseline")]))])) },
             .failed(.conditionalAttributeForbidden, annotation + [.tag(0x00700006)])),
            ("wf-ecg-source-class-mismatch", { _ in try! self.waveform(.twelveLeadECG, source: true, sourceClass: "1.2.840.10008.5.1.4.1.1.4") },
             .failed(.referenceIdentityContradiction, channel + [.tag(0x003A020A), .item(0), .tag(0x00081150)])),
            ("wf-audio-frequency-wrong", { _ in try! self.waveform(.basicVoiceAudio, frequency: 11025) }, .failed(.attributeValueNotAllowed, self.group + [.tag(0x003A001A)])),
            ("wf-eog-three-channels", { _ in try! self.waveform(.electrooculogram, channels: 3) }, .failed(.attributeValueNotAllowed, self.group + [.tag(0x003A0005)])),
            ("wf-respiratory-without-sync", { _ in try! self.waveform(.respiratory).removingSynchronization() }, .failed(.requiredAttributeMissing, [.tag(0x00200200)])),
            ("wf-hemodynamic-original-without-sync", { _ in try! self.waveform(.hemodynamic).removingSynchronization() }, .failed(.requiredAttributeMissing, [.tag(0x00200200)])),
            ("wf-eeg-missing-serial-number", { _ in try! self.waveform(.routineScalpEEG).removing(0x00181000) }, .failed(.requiredAttributeMissing, [.tag(0x00181000)])),
            ("wf-eeg-two-groups", { _ in try! self.waveform(.routineScalpEEG, groups: 2) }, .failed(.sequenceItemCountInvalid, [.tag(0x54000100)])),
            // A3 envelope corpus. The missing MIME list is a content-dependent envelope failure,
            // while its raw profile remains passed without embedded-component facts.
            ("document-obj-with-mtl-reference", { _ in try! self.fullDocument(.obj) }, .passed),
            ("document-mtl", { _ in try! self.fullDocument(.mtl) }, .passed),
            ("document-pdf-full-envelope", { _ in try! self.fullDocument(.pdf) }, .passed),
            ("document-cda-hl7-identifier", { _ in try! self.fullDocument(.cda) }, .passed),
            ("document-stl-model-module-full", { _ in try! self.fullDocument(.stl) }, .passed),
            ("document-mime-mismatch", { _ in try! self.document(.pdf, mime: "text/plain") }, .failed(.attributeValueNotAllowed, [.tag(0x00420012)])),
            ("document-length-mismatch", { _ in try! self.document(.pdf).setting(.init(tag: 0x00420015, vr: .UL, value: .unsignedIntegers([5]))) },
             .failed(.attributeValueContradiction, [.tag(0x00420015)])),
            ("document-cda-without-hl7-identifier", { _ in try! self.document(.cda, hl7: nil) }, .failed(.requiredAttributeMissing, [.tag(0x0040E001)])),
            ("document-m3d-without-units", { _ in try! self.document(.stl).removing(0x004008EA) }, .failed(.requiredAttributeMissing, [.tag(0x004008EA)])),
            ("document-list-of-mime-missing", { _ in try! self.fullDocument(.cda).removing(0x00420014) }, .passed),
            // Encapsulated documents.
            ("doc-pdf", { _ in try! self.document(.pdf) }, .passed),
            ("doc-pdf-with-source", { _ in try! self.document(.pdf, source: true) }, .passed),
            ("doc-cda", { _ in try! self.document(.cda) }, .passed),
            ("doc-stl", { _ in try! self.document(.stl) }, .passed),
            ("doc-obj", { _ in try! self.model("1.2.840.10008.5.1.4.1.1.104.4", "model/obj") }, .passed),
            ("doc-mtl", { _ in try! self.model("1.2.840.10008.5.1.4.1.1.104.5", "model/mtl").removing(0x00200052).removing(0x00201040) }, .passed),
            ("doc-stl-with-source", { _ in try! self.document(.stl, source: true).setting(self.commonInstanceReference()) }, .passed),
            ("doc-pdf-modality-wrong", { _ in try! self.document(.pdf).setting(self.text(0x00080060, "M3D", .CS)) }, .failed(.attributeValueNotAllowed, [.tag(0x00080060)])),
            ("doc-pdf-mime-wrong", { _ in try! self.document(.pdf, mime: "text/plain") }, .failed(.attributeValueNotAllowed, [.tag(0x00420012)])),
            ("doc-pdf-missing-burned-in", { _ in try! self.document(.pdf).removing(0x00280301) }, .failed(.requiredAttributeMissing, [.tag(0x00280301)])),
            ("doc-pdf-burned-in-wrong", { _ in try! self.document(.pdf).setting(self.text(0x00280301, "MAYBE", .CS)) }, .failed(.attributeValueNotAllowed, [.tag(0x00280301)])),
            ("doc-pdf-length-wrong", { _ in try! self.document(.pdf).setting(.init(tag: 0x00420015, vr: .UL, value: .unsignedIntegers([5]))) },
             .failed(.attributeValueContradiction, [.tag(0x00420015)])),
            ("doc-pdf-missing-conversion-type", { _ in try! self.document(.pdf).removing(0x00080064) }, .failed(.requiredAttributeMissing, [.tag(0x00080064)])),
            ("doc-pdf-missing-document-title", { _ in try! self.document(.pdf).removing(0x00420010) }, .failed(.requiredAttributeMissing, [.tag(0x00420010)])),
            ("doc-pdf-missing-series-number", { _ in try! self.document(.pdf).removing(0x00200011) }, .failed(.requiredAttributeMissing, [.tag(0x00200011)])),
            ("doc-pdf-hl7-identifier", { _ in try! self.document(.pdf).setting(self.text(0x0040E001, "1.2.3^ABC", .ST)) },
             .failed(.conditionalAttributeForbidden, [.tag(0x0040E001)])),
            ("doc-pdf-source-class-mismatch", { _ in try! self.document(.pdf, source: true, sourceClass: "1.2.840.10008.5.1.4.1.1.4") },
             .failed(.referenceIdentityContradiction, [.tag(0x00420013), .item(0), .tag(0x00081150)])),
            ("doc-pdf-content-sequence", { _ in try! self.document(.pdf).setting(self.sequence(0x0040A730, [.init(elements: [self.text(0x0040A010, "CONTAINS", .CS)])]))
                .setting(self.text(0x0040A040, "CONTAINER", .CS)).setting(self.text(0x0040A050, "SEPARATE", .CS)) },
             .incomplete(.conditionUndetermined, [.tag(0x0040A730)])),
            ("doc-cda-without-identifier", { _ in try! self.document(.cda, hl7: nil) }, .failed(.requiredAttributeMissing, [.tag(0x0040E001)])),
            ("doc-stl-missing-frame-of-reference", { _ in try! self.document(.stl).removing(0x00200052).removing(0x00201040) },
             .failed(.requiredAttributeMissing, [.tag(0x00200052)])),
            ("doc-stl-missing-units", { _ in try! self.document(.stl).removing(0x004008EA) }, .failed(.requiredAttributeMissing, [.tag(0x004008EA)])),
            ("doc-stl-missing-serial-number", { _ in try! self.document(.stl).removing(0x00181000) }, .failed(.requiredAttributeMissing, [.tag(0x00181000)])),
            ("doc-stl-source-without-reference-module", { _ in try! self.document(.stl, source: true) }, .failed(.requiredAttributeMissing, [.tag(0x00081115)])),
            ("doc-obj-mime-wrong", { _ in try! self.model("1.2.840.10008.5.1.4.1.1.104.4", "model/stl") }, .failed(.attributeValueNotAllowed, [.tag(0x00420012)])),
            ("doc-mtl-modality-wrong", { _ in try! self.model("1.2.840.10008.5.1.4.1.1.104.5", "model/mtl").removing(0x00200052).removing(0x00201040)
                .setting(self.text(0x00080060, "DOC", .CS)) }, .failed(.attributeValueNotAllowed, [.tag(0x00080060)]))
        ]
        for (name, make, expectation) in cases {
            let instance = make(.init(elements: []))
            let sop = instance[0x00080016]?.stringValue ?? ""
            let bytes = try DicomDataSetWriter.part10Data(from: instance, options: .init(mediaStorageSOPClassUID: sop, mediaStorageSOPInstanceUID: instanceUID))
            let report = try DicomInstanceValidator.validate(bytes, targets: targets(), imageConditions: facts)
            let outcome = report.outcome(requiring: requiredLayers)
            switch expectation {
            case .passed:
                XCTAssertEqual(outcome, .passed, "\(name): \(report.diagnostics)")
            case .failed(let code, let path):
                XCTAssertEqual(outcome, .failed, name)
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path && $0.severity == .error }, "\(name): \(report.diagnostics)")
            case .incomplete(let code, let path):
                XCTAssertEqual(outcome, .incomplete, "\(name): \(report.diagnostics)")
                XCTAssertFalse(report.diagnostics.contains { $0.severity == .error }, "\(name): \(report.diagnostics)")
                XCTAssertTrue(report.diagnostics.contains { $0.code == code && $0.path == path }, "\(name): \(report.diagnostics)")
            }
            XCTAssertFalse(report.diagnostics.contains { $0.code == .moduleRuleUnavailable }, name)
            XCTAssertEqual(try DicomCodecWorkflowEngine().validateInstance(bytes, targets: targets(), imageConditions: facts), report, name)
            if let folder = ProcessInfo.processInfo.environment["DICOM_WAVEFORM_DOCUMENT_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                let decoded: Any = instance.contains(0x54000100) ? try await decodedFacts(bytes) : NSNull()
                let documentFacts: Any = instance.contains(0x00420011) ? try self.documentFacts(bytes, name: name) : NSNull()
                try JSONSerialization.data(withJSONObject: ["document": documentFacts, "decoded": decoded, "outcome": outcome.rawValue, "sopClass": sop, "waveform": instance.contains(0x54000100),
                    "references": instance.referencesInstances,
                    "exit": outcome == .passed ? 0 : outcome == .failed ? 1 : 2], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    func test_completenessCorpus_exportsTypedAndDecodedWitnesses() async throws {
        let reference = DicomWaveformChannelReference(multiplexGroupNumber: 1, channel: .all)
        let code = DicomCodedConcept(codeValue: "122147", codingSchemeDesignator: "DCM", codeMeaning: "Baseline")
        let units = DicomCodedConcept(codeValue: "uV", codingSchemeDesignator: "UCUM", codeMeaning: "microvolt")
        var allTypes = DicomWaveformAnnotation.TemporalRangeType.allCases.map { type in
            let count: Int
            switch type {
            case .point, .begin, .end: count = 1
            case .segment, .multipoint: count = 2
            case .multisegment: count = 4
            }
            return DicomWaveformAnnotation(referencedChannels: [reference], groupNumber: 1, text: "Event",
                temporalRangeType: type, referencedSamplePositions: Array(1...count))
        }
        allTypes += [
            .init(referencedChannels: [reference], conceptName: code, conceptCode: code,
                  conceptNameModifiers: [code], conceptCodeModifiers: [code]),
            .init(referencedChannels: [reference], conceptName: code, numericValues: [2.5], measurementUnits: units,
                  temporalRangeType: .segment, referencedTimeOffsets: [0, 0.002]),
            .init(referencedChannels: [reference], conceptName: code, temporalRangeType: .point,
                  referencedDateTimes: ["20260909120000"])]
        let unknown = DicomWaveformAnnotation(referencedChannels: [.init(multiplexGroupNumber: 1, channel: .channel(99))], text: "Event")
        let outside = DicomWaveformAnnotation(referencedChannels: [reference], text: "Event", temporalRangeType: .point, referencedSamplePositions: [999])
        let mismatch = DicomWaveformAnnotation(referencedChannels: [reference], text: "Event", temporalRangeType: .segment, referencedSamplePositions: [1])
        let cases: [(String, DicomWaveformSampleInterpretation, [DicomWaveformAnnotation], DicomWaveformDiagnostic.Code?)] = [
            ("waveform-annotations-all-types", .signed16, allTypes, nil),
            ("waveform-channel-zero-reference", .signed16, [.init(referencedChannels: [reference], text: "Event")], nil),
            ("waveform-padding-value", .signed16, [], nil),
            ("waveform-mulaw-audio", .muLaw8, [], nil),
            ("waveform-alaw-audio", .aLaw8, [], nil),
            ("waveform-32bit-ecg-minmax", .signed32, [], nil),
            ("waveform-annotation-unknown-channel", .signed16, [unknown], .unknownChannel),
            ("waveform-annotation-samples-out-of-range", .signed16, [outside], .samplePositionOutOfRange),
            ("waveform-annotation-temporal-mismatch", .signed16, [mismatch], .temporalMismatch)]
        for (name, interpretation, annotations, diagnostic) in cases {
            let audio = interpretation == .muLaw8 || interpretation == .aLaw8
            let samples = audio ? Array(0...255) : [1, -2, 100, -32768, 3, -4, 10, 2, 9, -1, 0, 5]
            let padding = name == "waveform-padding-value" ? try DicomWaveformSampleValue(rawValue: -32768, interpretation: interpretation) : nil
            let channel = DicomWaveformChannel(number: 1, source: code, sensitivity: 0.5, sensitivityUnits: units,
                sensitivityCorrectionFactor: 2, baseline: 3,
                minimumValue: name == "waveform-32bit-ecg-minmax" ? try .init(rawValue: -2_000_000_000, interpretation: interpretation) : nil,
                maximumValue: name == "waveform-32bit-ecg-minmax" ? try .init(rawValue: 2_000_000_000, interpretation: interpretation) : nil, samples: samples)
            let group = DicomWaveformMultiplexGroup(samplingFrequency: audio ? 8000 : 500, sampleInterpretation: interpretation,
                paddingValue: padding, channels: [channel])
            let kind: DicomWaveformStorageKind = audio ? .basicVoiceAudio : interpretation == .signed32 ? .general32BitECG : .generalECG
            let bytes = try DicomWaveformBuilder.part10Data(multiplexGroups: [group], annotations: annotations,
                options: .init(kind: kind, sopInstanceUID: instanceUID, studyInstanceUID: studyUID, seriesInstanceUID: seriesUID,
                    seriesNumber: 1, contentDate: "20260909", contentTime: "120000"))
            let parsed = try XCTUnwrap(DCMDecoder(data: bytes).waveform)
            XCTAssertEqual(parsed.annotations, annotations, name)
            XCTAssertEqual(parsed.diagnostics.map(\.code), diagnostic.map { [$0] } ?? [], name)
            let report = try DicomInstanceValidator.validate(bytes, imageConditions: facts)
            let outcome = report.outcome(requiring: requiredLayers)
            if diagnostic == nil { XCTAssertEqual(outcome, .passed, "\(name): \(report.diagnostics)") }
            let decoded = try await decodedFacts(bytes)
            if let folder = ProcessInfo.processInfo.environment["DICOM_WAVEFORM_DOCUMENT_CORPUS_DIRECTORY"] {
                let directory = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try bytes.write(to: directory.appendingPathComponent(name + ".dcm"))
                try JSONSerialization.data(withJSONObject: ["outcome": outcome.rawValue, "sopClass": kind.storageSOPClassUID,
                    "waveform": true, "references": false, "exit": outcome == .passed ? 0 : outcome == .failed ? 1 : 2,
                    "typedDiagnostics": parsed.diagnostics.map { $0.code.rawValue }, "decoded": decoded], options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent(name + ".json"))
            }
        }
    }

    /// Stable weighted checksum and first/last eight physical values, excluding padding.
    /// Every decodable waveform also exercises an actual source-backed window.
    private func decodedFacts(_ bytes: Data) async throws -> Any {
        guard let waveform = try DCMDecoder(data: bytes).waveform else { return NSNull() }
        let reader: DicomWaveformSegmentReader?
        do { reader = try await .open(source: DicomByteSource(data: bytes)) }
        catch { reader = nil }
        var groups: [[String: Any]] = []
        for (index, group) in waveform.multiplexGroups.enumerated() {
            let range = min(1, group.numberOfSamples)..<min(9, group.numberOfSamples)
            let window = try await reader?.samples(group: index + 1, channels: Array(1...group.numberOfChannels), sampleRange: range)
            let channels: [[String: Any]] = group.channels.enumerated().map { ordinal, channel in
                let physical = channel.physicalSamples()
                let valid = physical.compactMap { $0 }
                if let window {
                    XCTAssertEqual(window[ordinal].rawValues, Array(channel.samples[range]))
                    XCTAssertEqual(window[ordinal].timeSeries.physicalSamples, Array(physical[range]))
                }
                return ["count": valid.count, "checksum": valid.enumerated().reduce(0.0) { $0 + Double($1.offset + 1) * $1.element },
                    "first": Array(valid.prefix(8)), "last": Array(valid.suffix(8)),
                    "windowRaw": window.map { $0[ordinal].rawValues } as Any? ?? NSNull(),
                    "windowPhysical": window.map { $0[ordinal].timeSeries.physicalSamples.map { $0 as Any? ?? NSNull() } } as Any? ?? NSNull()]
            }
            var facts: [String: Any] = ["channels": channels, "windowStart": range.lowerBound, "windowEnd": range.upperBound]
            if group.sampleInterpretation == .muLaw8 || group.sampleInterpretation == .aLaw8 {
                facts["linearPCM16Table"] = (0...255).map { Int(group.sampleInterpretation.linearPCM16(from: $0)!) }
            }
            groups.append(facts)
        }
        return groups
    }

    // MARK: - Producers

    /// The referenced two-frame CT image, keyed by SOP Instance UID.
    private func targets() -> [String: DicomDataSet] {
        [imageUID: .init(elements: [text(0x00080016, "1.2.840.10008.5.1.4.1.1.2", .UI), text(0x00080018, imageUID, .UI), text(0x0020000D, studyUID, .UI),
                                    text(0x0020000E, "2.25.23289981", .UI), text(0x00280008, "2", .IS)]),
         "2.25.234950": .init(elements: [text(0x00080016, DicomEncapsulatedDocument.encapsulatedMTLStorageSOPClassUID, .UI),
             text(0x00080018, "2.25.234950", .UI), text(0x0020000D, studyUID, .UI), text(0x0020000E, seriesUID, .UI)])]
    }

    private func waveform(_ kind: DicomWaveformStorageKind, groups: Int = 1, channels: Int? = nil, samples: Int = 4, frequency: Double? = nil,
                          interpretation: DicomWaveformSampleInterpretation? = nil, bitsStored: Int? = nil, originality: String = "ORIGINAL",
                          source: Bool = false, sourceClass: String = "1.2.840.10008.5.1.4.1.1.2", manufacturer: String? = nil) throws -> DicomDataSet {
        let interpretation = interpretation ?? kind.corpusInterpretation
        let reference = DicomWaveformSourceReference(referencedSOPClassUID: sourceClass, referencedSOPInstanceUID: imageUID,
                                                     referencedWaveformChannels: [.init(multiplexGroupNumber: 1, channelNumber: 1)])
        let multiplexGroups = (0..<groups).map { index in
            DicomWaveformMultiplexGroup(label: "G\(index + 1)", originality: originality, samplingFrequency: frequency ?? kind.corpusFrequency,
                                        sampleInterpretation: interpretation, channels: (0..<(channels ?? kind.corpusChannels)).map { number in
                DicomWaveformChannel(number: number + 1, label: "CH\(number + 1)", source: DicomCodedConcept(codeValue: "MDC_ECG_LEAD_I", codingSchemeDesignator: "MDC", codeMeaning: "Lead I"),
                                     sourceWaveformReferences: source && number == 0 ? [reference] : [],
                                     sensitivity: 1, sensitivityUnits: DicomCodedConcept(codeValue: "uV", codingSchemeDesignator: "UCUM", codeMeaning: "microvolt"), bitsStored: bitsStored,
                                     samples: Array(repeating: 1, count: samples))
            })
        }
        return try DicomWaveformBuilder.dataSet(multiplexGroups: multiplexGroups, options: .init(kind: kind, sopInstanceUID: instanceUID,
            studyInstanceUID: studyUID, seriesInstanceUID: seriesUID, seriesNumber: 1, instanceNumber: 1, contentDate: "20260909", contentTime: "120000", manufacturer: manufacturer))
    }

    private func document(_ kind: DicomEncapsulatedDocumentKind, mime: String? = nil, hl7: String? = "2.25.7^CDA-1", source: Bool = false,
                          sourceClass: String = "1.2.840.10008.5.1.4.1.1.2") throws -> DicomDataSet {
        let payload: Data
        switch kind {
        case .pdf: payload = Data("%PDF-1.4\n%%EOF\n".utf8)
        case .cda: payload = Data("<ClinicalDocument/>".utf8)
        case .stl: payload = binaryDocumentTriangle()
        case .obj: payload = Data("mtllib materials.mtl\nv 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8)
        case .mtl: payload = Data("newmtl bone\nKd 1 1 1\n".utf8)
        }
        return try DicomEncapsulatedDocumentBuilder.dataSet(documentData: payload, options: .init(kind: kind, sopInstanceUID: instanceUID,
            studyInstanceUID: studyUID, seriesInstanceUID: seriesUID, seriesNumber: 1, instanceNumber: 1, contentDate: "20260909", contentTime: "120000",
            documentTitle: "Corpus document", mimeType: mime, frameOfReferenceUID: kind == .stl ? "2.25.23289998" : nil,
            measurementUnits: kind == .stl ? DicomCodedConcept(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter") : nil,
            sourceInstances: source ? [.init(referencedSOPClassUID: sourceClass, referencedSOPInstanceUID: imageUID)] : [],
            hl7InstanceIdentifier: kind == .cda ? hl7 : nil))
    }

    private func binaryDocumentTriangle() -> Data {
        var bytes = Data(repeating: 0, count: 80)
        bytes.append(contentsOf: [1, 0, 0, 0])
        for value: Float in [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        bytes.append(contentsOf: [0, 0])
        return bytes
    }

    private func fullDocument(_ kind: DicomEncapsulatedDocumentKind) throws -> DicomDataSet {
        let concept = DicomCodedConcept(codeValue: "18748-4", codingSchemeDesignator: "LN", codeMeaning: "Diagnostic Imaging Report")
        let source = DicomEncapsulatedDocumentSourceInstance(referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: imageUID, purposeCodes: [.init(codeValue: "121322", codingSchemeDesignator: "DCM", codeMeaning: "Source image for image processing operation")])
        var options = DicomEncapsulatedDocumentBuildOptions(kind: kind, sopInstanceUID: instanceUID,
            studyInstanceUID: studyUID, seriesInstanceUID: seriesUID, instanceNumber: 4,
            contentDate: "20260910", contentTime: "120000", documentTitle: "Corpus document", conceptName: concept,
            acquisitionDateTime: "20260910115900", hl7InstanceIdentifier: kind == .cda ? "2.25.7^CDA-1" : nil)
        options.imageLaterality = "U"
        options.recognizableVisualFeatures = "NO"
        options.verificationFlag = "UNVERIFIED"
        options.documentClassCodes = [concept]
        if kind == .pdf {
            options.listOfMIMETypes = ["text/xml"]
            options.referencedInstances = [.init(referencedSOPClassUID: DicomEncapsulatedDocument.encapsulatedMTLStorageSOPClassUID,
                referencedSOPInstanceUID: "2.25.234950", purposeCodes: [concept], relativeURIReference: "materials.mtl")]
            options.sourceInstances = [source]
            options.referencedImages = [source]
            options.predecessorDocuments = [.init(studyInstanceUID: studyUID, seriesInstanceUID: "2.25.23289981", instances: [source])]
            options.identicalDocuments = options.predecessorDocuments
        }
        if kind == .stl || kind == .obj || kind == .mtl {
            options.manufacturing3DModel = .init(measurementUnits: .init(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter"),
                modelModification: "NO", modelMirroring: "NO", usageCode: .init(codeValue: "121322", codingSchemeDesignator: "DCM", codeMeaning: "Source image for image processing operation"),
                contentDescription: "Synthetic model", derivationAlgorithm: .init(name: "Synthetic", version: "1", family: concept),
                modelGroupUID: "2.25.234951", recommendedDisplayCIELabValue: [32768, 32768, 32768], recommendedPresentationOpacity: 0.5)
        }
        if kind == .obj {
            options.referencedInstances = [.init(referencedSOPClassUID: DicomEncapsulatedDocument.encapsulatedMTLStorageSOPClassUID,
                referencedSOPInstanceUID: "2.25.234950", relativeURIReference: "materials.mtl")]
        }
        var payload = try document(kind)[0x00420011]!.bytesValue!
        if kind == .pdf {
            payload = Data("%PDF-1.4\n1 0 obj << /Type /EmbeddedFile /Subtype /text#2Fxml /Length 7 >> stream\n<root/>\nendstream endobj\ntrailer <<>>\n%%EOF\n".utf8)
        }
        if kind == .cda {
            payload = Data("<ClinicalDocument><title>Corpus document</title><component><nonXMLBody><text mediaType=\"application/pdf\" representation=\"B64\">JVBERi0xLjQ=</text></nonXMLBody></component></ClinicalDocument>".utf8)
            options.listOfMIMETypes = ["application/pdf"]
        }
        var result = try DicomEncapsulatedDocumentBuilder.dataSet(documentData: payload, options: options)
        if kind == .obj {
            result = result.setting(sequence(0x00081115, [.init(elements: [text(0x0020000E, seriesUID, .UI),
                sequence(0x0008114A, options.referencedInstances.map { reference in
                    EncDocFields.reference(.init(referencedSOPClassUID: reference.referencedSOPClassUID,
                        referencedSOPInstanceUID: reference.referencedSOPInstanceUID))
                })])]))
        }
        return result
    }

    private func documentFacts(_ bytes: Data, name: String) throws -> [String: Any] {
        let document = try XCTUnwrap(DCMDecoder(data: bytes).encapsulatedDocument)
        let report = DicomEncapsulatedDocumentEnvelopeValidator.validate(document,
            embeddedMIMETypes: name == "document-list-of-mime-missing" || name == "document-cda-hl7-identifier" ? ["application/pdf"] : nil)
        if name == "document-list-of-mime-missing" { XCTAssertEqual(report.diagnostics.map(\.code), [.missingMIMEList]) }
        if ["document-obj-with-mtl-reference", "document-mtl", "document-pdf-full-envelope", "document-cda-hl7-identifier", "document-stl-model-module-full"].contains(name) {
            XCTAssertTrue(report.isValid, "\(name): \(report.diagnostics)")
            XCTAssertEqual(report.contentPlausibility.verdict, .plausible)
        }
        return ["sha256": SHA256.hash(data: document.documentData).map { String(format: "%02x", $0) }.joined(),
                "payloadBase64": document.documentData.base64EncodedString(),
                "envelopeValid": report.isValid, "diagnostics": report.diagnostics.map { $0.code.rawValue },
                "plausibility": report.contentPlausibility.verdict.rawValue]
    }

    /// An OBJ or MTL model derived from the STL producer: the same equipment, frame of reference and units.
    private func model(_ sop: String, _ mime: String) throws -> DicomDataSet {
        try document(sop.hasSuffix(".4") ? .obj : .mtl).setting(sequence(0x004008EA, [code("mm", "UCUM", "millimeter")])).setting(text(0x00420012, mime, .LO))
    }

    private func commonInstanceReference() -> DicomDataElement {
        sequence(0x00081115, [.init(elements: [text(0x0020000E, "2.25.23289981", .UI), sequence(0x0008114A, [
            .init(elements: [text(0x00081150, "1.2.840.10008.5.1.4.1.1.2", .UI), text(0x00081155, imageUID, .UI)])])])])
    }

    private func annotation(text value: String, channels: [UInt]) -> DicomDataSet {
        .init(elements: [.init(tag: 0x0040A0B0, vr: .US, value: .unsignedIntegers(channels)), text(0x00700006, value, .ST)])
    }

    private func code(_ value: String, _ scheme: String, _ meaning: String) -> DicomDataSet {
        .init(elements: [text(0x00080100, value, .SH), text(0x00080102, scheme, .SH), text(0x00080104, meaning, .LO)])
    }

    private func number(_ tag: Int, _ value: UInt) -> DicomDataElement { .init(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func text(_ tag: Int, _ value: String, _ vr: DicomVR) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .strings(value.components(separatedBy: "\\")))
    }
    private func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        .init(tag: tag, vr: .SQ, value: .sequence(items.map { .init(dataSet: $0) }))
    }
}

private extension DicomDataSet {
    /// Whether any item at any depth carries a Referenced SOP Instance UID.
    var referencesInstances: Bool {
        contains(0x00081155) || elements.contains { $0.vr == .SQ && $0.sequenceItems.contains { $0.dataSet.referencesInstances } }
    }

    func replacingGroup(_ transform: (DicomDataSet) -> DicomDataSet) -> DicomDataSet {
        var groups = (self[0x54000100]?.sequenceItems ?? []).map(\.dataSet)
        groups[0] = transform(groups[0])
        return setting(.init(tag: 0x54000100, vr: .SQ, value: .sequence(groups.map { .init(dataSet: $0) })))
    }

    func removingSynchronization() -> DicomDataSet {
        removing(0x00200200).removing(0x0018106A).removing(0x00181800)
    }
}

private extension DicomWaveformStorageKind {
    var corpusName: String {
        switch self {
        case .twelveLeadECG: return "twelve-lead-ecg"
        case .generalECG: return "general-ecg"
        case .ambulatoryECG: return "ambulatory-ecg"
        case .general32BitECG: return "general-32bit-ecg"
        case .hemodynamic: return "hemodynamic"
        case .cardiacElectrophysiology: return "cardiac-electrophysiology"
        case .basicVoiceAudio: return "basic-voice-audio"
        case .generalAudio: return "general-audio"
        case .arterialPulse: return "arterial-pulse"
        case .respiratory: return "respiratory"
        case .multiChannelRespiratory: return "multichannel-respiratory"
        case .routineScalpEEG: return "routine-scalp-eeg"
        case .electromyogram: return "electromyogram"
        case .electrooculogram: return "electrooculogram"
        case .sleepEEG: return "sleep-eeg"
        }
    }

    /// A.34.x.4: a channel count, sampling frequency and sample interpretation inside each IOD's constraints.
    var corpusChannels: Int { self == .electrooculogram ? 2 : self == .arterialPulse || self == .respiratory ? 1 : 2 }

    var corpusFrequency: Double {
        switch self {
        case .basicVoiceAudio: return 8000
        case .generalAudio: return 44100
        case .respiratory, .multiChannelRespiratory: return 50
        case .arterialPulse, .hemodynamic: return 250
        default: return 500
        }
    }

    var corpusInterpretation: DicomWaveformSampleInterpretation { self == .basicVoiceAudio ? .unsigned8 : .signed16 }
}
