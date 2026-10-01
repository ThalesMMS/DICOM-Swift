import DicomData
import Foundation
import XCTest

@MainActor
final class DicomSourceMetadataTests: XCTestCase {
    func test_memorySource_readsEveryMetadataValueWithoutReadingPixelPayload() async throws {
        let fixture = try fixtureData()
        let decoder = try DicomDataSetParser.dataSet(from: fixture.dataset)
        let source = DicomByteSource(data: fixture.part10)
        let metadata = try await DicomSourceMetadata.readPart10(from: source)
        XCTAssertEqual(metadata.dataSet, decoder)
        let pixelRange = try XCTUnwrap(metadata.pixelDataRange)
        XCTAssertEqual(pixelRange.count, 65536)
        let metrics = await source.metrics
        XCTAssertFalse(metrics.ranges.contains { $0.overlaps(pixelRange) })
        XCTAssertLessThan(metrics.receivedBytes, 1024)
        XCTAssertEqual(metadata.sourceRevision, source.revision)
        XCTAssertEqual(metadata.dataSet.string(for: .patientName), "SYNTHETIC^RANGE")
        XCTAssertEqual(metadata.dataSet.string(for: .studyDescription), "Sintético Δ")
        XCTAssertEqual(metadata.dataSet[0xFFFCFFFC]?.value, .bytes(Data([1, 2])))
    }

    func test_dataSetSlice_usesLogicalOffsetsForVRAndValues() throws {
        let fixture = try fixtureData()
        var padded = Data(repeating: 0xEE, count: 19)
        padded.append(fixture.dataset)
        XCTAssertEqual(try DicomDataSetParser.dataSet(from: padded.dropFirst(19)),
                       try DicomDataSetParser.dataSet(from: fixture.dataset))
    }

    func test_metadataBudget_rejectsBeforeReadingOversizedValue() async throws {
        let fixture = try fixtureData()
        let source = DicomByteSource(data: fixture.part10)
        do {
            _ = try await DicomSourceMetadata.readPart10(from: source, maximumMetadataBytes: 16)
            XCTFail("Metadata budget ignored")
        } catch {
            XCTAssertEqual(error as? DicomSourceMetadata.Failure, .metadataLimit)
        }
        let metrics = await source.metrics
        XCTAssertLessThan(metrics.receivedBytes, 200)
    }

    func test_undefinedSequencesAndEncapsulation_preserveMetadataAndSkipEveryFragment() async throws {
        var encoded = Data([0x08, 0, 0x15, 0x11, 0x53, 0x51, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        encoded.append(contentsOf: [0xFE, 0xFF, 0, 0xE0, 0xFF, 0xFF, 0xFF, 0xFF])
        encoded.append(try DicomDataSetWriter.dataSetData(from: .init(elements: [
            .init(tag: DicomTag.seriesDescription.rawValue, vr: .LO, value: .strings(["NESTED"]))
        ])))
        encoded.append(contentsOf: [0xFE, 0xFF, 0x0D, 0xE0, 0, 0, 0, 0])
        encoded.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
        encoded.append(contentsOf: [0xE0, 0x7F, 0x10, 0, 0x4F, 0x42, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
        encoded.append(contentsOf: [0xFE, 0xFF, 0, 0xE0, 0, 0, 0, 0])
        encoded.append(contentsOf: [0xFE, 0xFF, 0, 0xE0, 0, 0, 0x10, 0])
        let fragmentStart = encoded.count
        encoded.append(Data(repeating: 0xA5, count: 1048576))
        encoded.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
        let part10 = try DicomDataSetWriter.part10Data(fromEncodedDataSet: encoded,
                                                      transferSyntax: .rleLossless,
                                                      mediaStorageSOPClassUID: "1.2.840.10008.5.1.4.1.1.7",
                                                      mediaStorageSOPInstanceUID: "2.25.2318002")
        let base = part10.count - encoded.count
        let source = DicomByteSource(data: part10)
        let limits = DicomDataSetParseLimits(maximumSequenceDepth: 1, maximumElementCount: 100, maximumItemCount: 3)
        let metadata = try await DicomSourceMetadata.readPart10(from: source, limits: limits)
        XCTAssertEqual(metadata.dataSet, try DicomDataSetParser.dataSet(from: encoded, transferSyntax: .rleLossless))
        XCTAssertTrue(metadata.pixelDataIsEncapsulated)
        XCTAssertEqual(metadata.dataSet.sequenceItems(for: 0x00081115).first?.dataSet.string(for: .seriesDescription), "NESTED")
        let metrics = await source.metrics
        XCTAssertLessThan(metrics.receivedBytes, 1024)
        XCTAssertFalse(metrics.ranges.contains { $0.overlaps((base + fragmentStart)..<(base + fragmentStart + 1048576)) })
        let limited = DicomByteSource(data: part10)
        do {
            _ = try await DicomSourceMetadata.readPart10(from: limited,
                limits: .init(maximumSequenceDepth: 1, maximumElementCount: 100, maximumItemCount: 1))
            XCTFail("Item budget ignored")
        } catch {
            XCTAssertEqual(error as? DicomDataSetParseError, .maximumItemCountExceeded(limit: 1))
        }
    }

    func test_validatedPart10_preservesSeparateMetaAndNeverReadsPixelPayload() async throws {
        let fixture = try fixtureData()
        let source = DicomByteSource(data: fixture.part10)
        let result = try await DicomSourceMetadata.readPart10(from: source, mode: .strict)
        XCTAssertEqual(result.dataSet, try DicomDataSetParser.read(from: fixture.dataset).dataSet)
        XCTAssertEqual(result.fileMetaInformation.string(for: .transferSyntaxUID), DicomTransferSyntax.explicitVRLittleEndian.rawValue)
        XCTAssertTrue(result.fileMetaDiagnostics.isEmpty)
        XCTAssertTrue(result.dataSetDiagnostics.isEmpty)
        let range = try XCTUnwrap(result.pixelDataRange)
        let metrics = await source.metrics
        XCTAssertFalse(metrics.ranges.contains { $0.overlaps(range) })
    }

    func test_part10Recovery_reportsSeparateBuffersWithOneSharedDiagnosticBudget() async throws {
        var bytes = try fixtureData().part10
        let metaHeader = try XCTUnwrap(bytes.range(of: Data([2, 0, 0x13, 0, 0x53, 0x48])))
        bytes.replaceSubrange((metaHeader.lowerBound + 4)..<(metaHeader.lowerBound + 6), with: [0x4C, 0x4F])
        let trailingHeader = try XCTUnwrap(bytes.range(of: Data([0xFC, 0xFF, 0xFC, 0xFF, 0x4F, 0x42, 0, 0, 2, 0, 0, 0])))
        bytes.replaceSubrange((trailingHeader.lowerBound + 4)..<(trailingHeader.lowerBound + 6), with: [0x4F, 0x46])
        for mode in [DicomDataSetReadMode.strict, .recover] {
            do {
                _ = try await DicomSourceMetadata.readPart10(from: DicomByteSource(data: bytes), mode: mode, maximumDiagnostics: 1)
                XCTFail("Strict rejection or shared diagnostic budget was ignored")
            } catch {
                XCTAssertEqual((error as? DicomDataSetReadResult.Diagnostic)?.reason, .incompatibleVR)
            }
        }
        let source = DicomByteSource(data: bytes)
        let result = try await DicomSourceMetadata.readPart10(from: source, mode: .recover, maximumDiagnostics: 2)
        await source.close()
        bytes.removeAll()
        XCTAssertEqual(result.fileMetaDiagnostics.map(\.tag), [0x00020013])
        XCTAssertEqual(result.dataSetDiagnostics.map(\.tag), [0xFFFCFFFC])
        XCTAssertLessThan(try XCTUnwrap(result.dataSetDiagnostics.first?.offset), 1024)
        XCTAssertEqual(result.dataSet[0xFFFCFFFC]?.vr, .UN)
        XCTAssertEqual(result.dataSet[0xFFFCFFFC]?.bytesValue, Data([1, 2]))
        XCTAssertEqual(result.fileMetaInformation[0x00020013]?.vr, .UN)
    }

    func test_validatedSource_resolvesPrivateAndLocalImplicitDefinitions() async throws {
        let privateDictionary = try DicomPrivateDictionary(entries: [.init(group: 0x7777, creator: "ISIS", offset: 1, vr: .US)])
        let dictionary = try DCMDictionary(extendingWith: [
            0x77781001: .init(valueRepresentations: [.UC], multiplicity: "1", name: "Local label")
        ])
        let dataset = DicomDataSet(elements: [
            .init(tag: 0x77770010, vr: .LO, value: .strings(["ISIS"])),
            .init(tag: 0x77771001, vr: .US, value: .unsignedIntegers([42])),
            .init(tag: 0x77781001, vr: .UC, value: .strings(["LOCAL"]))
        ])
        let bytes = try DicomDataSetWriter.part10Data(from: dataset, options: .init(transferSyntax: .implicitVRLittleEndian))
        let result = try await DicomSourceMetadata.readPart10(from: DicomByteSource(data: bytes), mode: .strict,
            privateDictionary: privateDictionary, dictionary: dictionary)
        XCTAssertEqual(result.dataSet, dataset)
    }

    func test_bigEndianDatasetGroup0200_doesNotBecomeLittleEndianFileMeta() async throws {
        let dataset = DicomDataSet(elements: [.init(tag: 0x02001001, vr: .LO, value: .strings(["LOCAL"]))])
        let bytes = try DicomDataSetWriter.part10Data(from: dataset, options: .init(transferSyntax: .explicitVRBigEndian))
        let result = try await DicomSourceMetadata.readPart10(from: DicomByteSource(data: bytes), mode: .strict)
        XCTAssertEqual(result.dataSet, dataset)
        XCTAssertTrue(result.fileMetaInformation.elements.allSatisfy { $0.group == 2 })
    }

    func test_validatedPart10_rejectsMissingOverrunAndPartialFileMetaBoundaries() async throws {
        let original = try fixtureData().part10
        // The Part 10 writer starts with a 12-byte File Meta Group Length element.
        var missing = original
        missing.removeSubrange(132..<144)
        var partial = original
        partial.replaceSubrange(140..<144, with: [1, 0, 0, 0])
        var overrun = original
        overrun.replaceSubrange(140..<144, with: [0xFF, 0xFF, 0xFF, 0xFF])
        for bytes in [missing, partial, overrun] {
            for mode in [DicomDataSetReadMode.strict, .recover] {
                do {
                    _ = try await DicomSourceMetadata.readPart10(from: DicomByteSource(data: bytes), mode: mode)
                    XCTFail("A structural File Meta boundary was guessed")
                } catch {
                    XCTAssertEqual(error as? DicomSourceMetadata.Failure, .invalidFileMetaLength)
                }
            }
        }
        // Explicit compatibility mode can still consume historical files without group length.
        let legacy = try await DicomSourceMetadata.readPart10(from: DicomByteSource(data: missing))
        XCTAssertEqual(legacy.dataSet.string(for: .patientName), "SYNTHETIC^RANGE")
    }

    private func fixtureData() throws -> (part10: Data, dataset: Data) {
        let dataset = DicomDataSet(elements: [
            .init(tag: DicomTag.sopClassUID.rawValue, vr: .UI, value: .strings(["1.2.840.10008.5.1.4.1.1.7"])),
            .init(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings(["2.25.2318001"])),
            .init(tag: DicomTag.patientName.rawValue, vr: .PN, value: .strings(["SYNTHETIC^RANGE"])),
            .init(tag: DicomTag.specificCharacterSet.rawValue, vr: .CS, value: .strings(["ISO_IR 192"])),
            .init(tag: DicomTag.studyDescription.rawValue, vr: .LO, value: .strings(["Sintético Δ"])),
            .init(tag: DicomTag.rows.rawValue, vr: .US, value: .unsignedIntegers([256])),
            .init(tag: DicomTag.columns.rawValue, vr: .US, value: .unsignedIntegers([256])),
            .init(tag: DicomTag.bitsAllocated.rawValue, vr: .US, value: .unsignedIntegers([8])),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(Data(repeating: 7, count: 65536))),
            .init(tag: 0xFFFCFFFC, vr: .OB, value: .bytes(Data([1, 2])))
        ])
        return (try DicomDataSetWriter.part10Data(from: dataset),
                try DicomDataSetWriter.dataSetData(from: dataset))
    }
}
