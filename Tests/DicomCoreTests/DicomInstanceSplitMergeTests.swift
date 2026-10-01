import DicomCore
import DicomTestSupport
import Foundation
import XCTest

/// Merge classic CT/MR into Legacy Converted Enhanced and split multi-frame objects back (#2323).
final class DicomInstanceSplitMergeTests: XCTestCase {
    func test_singleBitFixture_packsContinuouslyAcrossFrameBoundaries() throws {
        for (frames, expected) in [(1, Data([0])), (3, Data([0, 1, 2]))] {
            let bytes = try DicomStructuralFixtures.multiframeSecondaryCapture(frames: frames, bitsAllocated: 1)
            let dataSet = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: bytes))
            XCTAssertEqual(dataSet[.pixelData]?.bytesValue, expected)
        }
    }

    func test_bigEndianNativePixels_keepTheirMeaningWhenSplitAndAreRejectedByMerge() throws {
        let source = try DicomStructuralFixtures.multiframeSecondaryCapture(frames: 2, bitsAllocated: 16)
        var dataSet = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: source))
        dataSet.set(DicomStructuralFixtures.number(.rows, 2))
        let bytes = Data([0x01, 0x23, 0x04, 0x56, 0x07, 0x89, 0x0A, 0xBC, 0x0D, 0xEF, 0x12, 0x34, 0x56, 0x78, 0x7F, 0xFF])
        dataSet.set(.init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(bytes)))
        let bigEndian = try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .explicitVRBigEndian))
        let split = try DicomInstanceSplitter().split(bigEndian)
        for (index, instance) in split.instances.enumerated() {
            let decoder = try DCMDecoder(data: instance.part10Data)
            XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.explicitVRBigEndian.rawValue)
            let expected = stride(from: index * 8, to: (index + 1) * 8, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
            XCTAssertEqual(decoder.getPixels16(), expected)
        }
        let inputs = try (1...2).map { index in
            let data = try DicomStructuralFixtures.ctSlice(index: index, position: [0, 0, Double(index)])
            let dataSet = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: data))
            return try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .explicitVRBigEndian))
        }
        XCTAssertThrowsError(try DicomInstanceMerger().merge(inputs)) {
            XCTAssertEqual($0 as? DicomInstanceMerger.MergeError, .unsupportedTransferSyntax(DicomTransferSyntax.explicitVRBigEndian.rawValue))
        }
    }

    func test_merge_buildsLegacyConvertedEnhancedCTWithProvenanceAndSplitsBack() throws {
        let slices = [
            try DicomStructuralFixtures.ctSlice(index: 3, position: [0, 0, 4], extra: [DicomDataElement(tag: 0x0020_0012, vr: .IS, value: .strings(["3"]))]),
            try DicomStructuralFixtures.ctSlice(index: 1, position: [0, 0, 0], extra: [DicomDataElement(tag: 0x0020_0012, vr: .IS, value: .strings(["1"]))]),
            try DicomStructuralFixtures.ctSlice(index: 2, position: [0, 0, 2], window: ["50", "500"], extra: [DicomDataElement(tag: 0x0020_0012, vr: .IS, value: .strings(["2"]))])
        ]
        let identifiers = DicomInstanceMerger.Identifiers(seriesInstanceUID: "2.25.23269910", sopInstanceUID: "2.25.23269911", dimensionOrganizationUID: "2.25.23269912")
        let merged = try DicomInstanceMerger().merge(slices, identifiers: identifiers)
        XCTAssertEqual(merged.sopClassUID, DicomInstanceMerger.legacyConvertedCTSOPClassUID)
        XCTAssertEqual(merged.frameCount, 3)
        XCTAssertEqual(merged.sourceSOPInstanceUIDs, ["2.25.23269901", "2.25.23269902", "2.25.23269903"], "ordered along the normal, not by input order")
        XCTAssertEqual(merged.perFrameTags, [0x0020_0012])
        let decoder = try DCMDecoder(data: merged.part10Data)
        let dataSet = decoder.dataSet
        XCTAssertEqual(decoder.nImages, 3)
        XCTAssertEqual(dataSet.string(for: .seriesInstanceUID), "2.25.23269910")
        XCTAssertEqual(dataSet.string(for: .studyInstanceUID), "2.25.23269902")
        XCTAssertEqual(dataSet.string(for: .frameOfReferenceUID), "2.25.23269904")
        XCTAssertEqual(dataSet.string(for: 0x0018_0060), "120", "shared attributes stay at the top level")
        XCTAssertFalse(dataSet.contains(0x0020_0012), "varying attributes move to the per-frame unassigned group")
        XCTAssertFalse(dataSet.contains(.imagePositionPatient))
        let groups = try XCTUnwrap(decoder.enhancedMultiframeFunctionalGroups)
        XCTAssertEqual(groups.perFrame.count, 3)
        XCTAssertEqual((0..<3).map { groups.geometry(forFrame: $0)?.imagePositionPatient?.z }, [0, 2, 4])
        XCTAssertEqual(groups.shared?.pixelMeasures?.spacingBetweenSlices, 2)
        XCTAssertEqual(groups.dimensionOrganization?.indexes.map(\.dimensionIndexPointer), [DicomTag.stackID.rawValue, DicomTag.inStackPositionNumber.rawValue])
        let perFrame = try XCTUnwrap(dataSet[.perFrameFunctionalGroupsSequence]?.sequenceItems)
        XCTAssertEqual(perFrame.map { $0[0x0020_9172]?.sequenceItems.first?[.referencedSOPInstanceUID]?.stringValue }, merged.sourceSOPInstanceUIDs)
        XCTAssertEqual(perFrame.map { $0[0x0020_9171]?.sequenceItems.first?[0x0020_0012]?.stringValue }, ["1", "2", "3"])
        XCTAssertEqual(perFrame.map { $0[.frameVOILUTSequence]?.sequenceItems.first?[.windowCenter]?.stringValue }, ["40", "50", "40"], "VOI differs per frame")
        XCTAssertNil(dataSet[.sharedFunctionalGroupsSequence]?.sequenceItems.first?[.frameVOILUTSequence])
        XCTAssertNotNil(dataSet[.sharedFunctionalGroupsSequence]?.sequenceItems.first?[.pixelValueTransformationSequence])
        XCTAssertEqual(dataSet[.sourceImageSequence]?.sequenceItems.count, 3)
        // Pixel bytes are the ordered concatenation of the sources.
        let pixels = try XCTUnwrap(try DicomPart10PixelDataPreserver.dataSet(from: decoder).element(for: .pixelData)?.bytesValue)
        let expected = try [1, 2, 3].map { try XCTUnwrap(try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: slices[[1, 2, 0][$0 - 1]])).element(for: .pixelData)?.bytesValue) }
        XCTAssertEqual(pixels, expected[0] + expected[1] + expected[2])
        // The merged object splits back into equivalent classic instances (identity and derivation aside).
        let split = try DicomInstanceSplitter().split(merged.part10Data)
        XCTAssertEqual(split.sopClassUID, "1.2.840.10008.5.1.4.1.1.2")
        XCTAssertEqual(split.instances.count, 3)
        let ignored: Set<Int> = [DicomTag.instanceNumber.rawValue, DicomTag.imageType.rawValue, DicomTag.sourceImageSequence.rawValue, DicomTag.sliceSpacing.rawValue,
                                 DicomTag.derivationDescription.rawValue, DicomTag.contentDate.rawValue, DicomTag.contentTime.rawValue]
        for (frame, original) in zip(split.instances, [slices[1], slices[2], slices[0]]) {
            let before = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: original))
            let after = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: frame.part10Data))
            let diff = DicomDataSetDiff.compare(before, after, options: .init(ignoredTags: ignored, ignoresUIDs: true))
            XCTAssertTrue(diff.isEmpty, "frame \(frame.sourceFrameNumber): \(diff.changes)")
            XCTAssertEqual(after.string(for: 0x0020_0012), before.string(for: 0x0020_0012), "unassigned per-frame attribute restored")
            XCTAssertEqual(after[.sourceImageSequence]?.sequenceItems.first?[.referencedSOPInstanceUID]?.stringValue, "2.25.23269911")
        }
    }

    func test_merge_rejectsIncompatibleCombinationsWithSpecificReasons() throws {
        let a = try DicomStructuralFixtures.ctSlice(index: 1, position: [0, 0, 0]), b = try DicomStructuralFixtures.ctSlice(index: 2, position: [0, 0, 2])
        func failure(_ inputs: [Data], identifiers: DicomInstanceMerger.Identifiers? = nil) -> DicomInstanceMerger.MergeError? {
            do { _ = try DicomInstanceMerger().merge(inputs, identifiers: identifiers); return nil } catch let error as DicomInstanceMerger.MergeError { return error } catch { XCTFail("\(error)"); return nil }
        }
        XCTAssertEqual(failure([a]), .tooFewInstances(1))
        XCTAssertEqual(failure([a, Data([1, 2, 3])]), .notPart10(index: 1))
        XCTAssertEqual(failure([a, try DicomStructuralFixtures.ctSlice(index: 2, position: [0, 0, 2], sopClass: "1.2.840.10008.5.1.4.1.1.4")]), .mixedSOPClasses(["1.2.840.10008.5.1.4.1.1.2", "1.2.840.10008.5.1.4.1.1.4"]))
        XCTAssertEqual(failure([try DicomStructuralFixtures.ctSlice(index: 1, sopClass: "1.2.840.10008.5.1.4.1.1.7"), try DicomStructuralFixtures.ctSlice(index: 2, position: [0, 0, 2], sopClass: "1.2.840.10008.5.1.4.1.1.7")]), .unsupportedSOPClass("1.2.840.10008.5.1.4.1.1.7"))
        XCTAssertEqual(failure([a, try DicomStructuralFixtures.ctSlice(index: 2, position: [0, 0, 2], series: "2.25.9")]), .identityDiffers(attribute: "Series Instance UID", values: ["2.25.23269903", "2.25.9"]))
        XCTAssertEqual(failure([a, try DicomStructuralFixtures.ctSlice(index: 2, position: [0, 0, 2], frameOfReference: "2.25.8")]), .identityDiffers(attribute: "Frame of Reference UID", values: ["2.25.23269904", "2.25.8"]))
        XCTAssertEqual(failure([a, a]), .duplicateSOPInstanceUID("2.25.23269901"))
        XCTAssertEqual(failure([a, try DicomStructuralFixtures.ctSlice(index: 2, position: [0, 0, 2], extra: [DicomStructuralFixtures.number(.bitsStored, 16), DicomStructuralFixtures.number(.highBit, 15)])]), .pixelStructureDiffers(attribute: "Bits Stored"))
        XCTAssertEqual(failure([a, try DicomStructuralFixtures.ctSlice(index: 2, position: [0, 0, 2], orientation: [0, 1, 0, 0, 0, 1])]), .orientationDiffers(sopInstanceUID: "2.25.23269902"))
        XCTAssertEqual(failure([a, try DicomStructuralFixtures.ctSlice(index: 2, position: [0, 0, 2], spacing: [1, 1])]), .pixelSpacingDiffers(sopInstanceUID: "2.25.23269902"))
        XCTAssertEqual(failure([a, try DicomStructuralFixtures.ctSlice(index: 2, position: [0, 0, 0])]), .duplicatePosition(sopInstanceUIDs: ["2.25.23269901", "2.25.23269902"]))
        var noGeometry = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: b))
        noGeometry.remove(.imagePositionPatient)
        XCTAssertEqual(failure([a, try DicomDataSetWriter.part10Data(from: noGeometry)]), .missingGeometry(sopInstanceUID: "2.25.23269902"))
        XCTAssertEqual(failure([a, try DicomStructuralFixtures.multiframeSecondaryCapture(frames: 2)]), .mixedSOPClasses(["1.2.840.10008.5.1.4.1.1.2", "1.2.840.10008.5.1.4.1.1.7.2"]))
        XCTAssertEqual(failure([a, b], identifiers: .init(seriesInstanceUID: "2.25.23269903", sopInstanceUID: "2.25.1", dimensionOrganizationUID: "2.25.2")), .invalidIdentifier("output UIDs must differ from every UID in the sources"))
        XCTAssertEqual(failure([a, b], identifiers: .init(seriesInstanceUID: "2.25.1", sopInstanceUID: "2.25.1", dimensionOrganizationUID: "2.25.2")), .invalidIdentifier("output UIDs must be unique"))
        XCTAssertEqual(failure([a, b], identifiers: .init(seriesInstanceUID: "bad", sopInstanceUID: "2.25.1", dimensionOrganizationUID: "2.25.2")), .invalidIdentifier("malformed UID"))
        var multiframe = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: b))
        multiframe.set(DicomStructuralFixtures.string(.numberOfFrames, .IS, ["2"]))
        XCTAssertEqual(failure([a, try DicomDataSetWriter.part10Data(from: multiframe)]), .multiframeSource(sopInstanceUID: "2.25.23269902"))
        // An MR pair merges into Legacy Converted Enhanced MR.
        let mr = try DicomInstanceMerger().merge([try DicomStructuralFixtures.ctSlice(index: 5, sopClass: "1.2.840.10008.5.1.4.1.1.4"), try DicomStructuralFixtures.ctSlice(index: 6, position: [0, 0, 1], sopClass: "1.2.840.10008.5.1.4.1.1.4")])
        XCTAssertEqual(mr.sopClassUID, DicomInstanceMerger.legacyConvertedMRSOPClassUID)
        XCTAssertEqual(try DicomInstanceSplitter().split(mr.part10Data).sopClassUID, "1.2.840.10008.5.1.4.1.1.4")
    }

    func test_merge_rejectsNonAdjacentDuplicatePositionsOnTheSamePlane() throws {
        let inputs = try [[0.0, 0, 0], [10, 0, 0], [0, 0, 0]].enumerated().map {
            try DicomStructuralFixtures.ctSlice(index: $0.offset + 1, position: $0.element)
        }
        XCTAssertThrowsError(try DicomInstanceMerger().merge(inputs)) {
            XCTAssertEqual($0 as? DicomInstanceMerger.MergeError,
                           .duplicatePosition(sopInstanceUIDs: ["2.25.23269901", "2.25.23269903"]))
        }
    }

    func test_split_secondaryCaptureFramesNativeAndEncapsulated() throws {
        let source = try DicomStructuralFixtures.multiframeSecondaryCapture(frames: 3, bitsAllocated: 16)
        let ids = DicomInstanceSplitter.Identifiers(seriesInstanceUID: "2.25.23269960", sopInstanceUIDs: ["2.25.23269961", "2.25.23269962", "2.25.23269963"])
        let result = try DicomInstanceSplitter().split(source, identifiers: ids)
        XCTAssertEqual(result.sopClassUID, DicomInstanceSplitter.secondaryCaptureSOPClassUID)
        XCTAssertEqual(result.instances.map(\.sopInstanceUID), ids.sopInstanceUIDs)
        let sourcePixels = try XCTUnwrap(try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: source)).element(for: .pixelData)?.bytesValue)
        for (index, instance) in result.instances.enumerated() {
            let decoder = try DCMDecoder(data: instance.part10Data)
            XCTAssertEqual(decoder.nImages, 1)
            XCTAssertEqual(decoder.info(for: .seriesInstanceUID), "2.25.23269960")
            XCTAssertEqual(decoder.info(for: .instanceNumber), String(index + 1))
            XCTAssertEqual(decoder.dataSet[0x0020_1041]?.stringValue, String(index * 2), "Slice Location Vector entry preserved")
            XCTAssertFalse(decoder.dataSet.contains(0x0018_2005))
            XCTAssertFalse(decoder.dataSet.contains(.frameIncrementPointer))
            XCTAssertEqual(decoder.dataSet[.sourceImageSequence]?.sequenceItems.first?[.referencedSOPInstanceUID]?.stringValue, "2.25.23269950")
            XCTAssertEqual(decoder.dataSet[.sourceImageSequence]?.sequenceItems.first?[.referencedFrameNumber]?.stringValue, String(index + 1))
            XCTAssertEqual(try DicomPart10PixelDataPreserver.dataSet(from: decoder).element(for: .pixelData)?.bytesValue, sourcePixels[sourcePixels.startIndex + index * 12..<sourcePixels.startIndex + (index + 1) * 12])
        }
        // RGB 8-bit and single-bit (byte-aligned) frames split too; a non-aligned single-bit frame is refused.
        XCTAssertEqual(try DicomInstanceSplitter().split(try DicomStructuralFixtures.multiframeSecondaryCapture(frames: 2, samples: 3, sopClass: "1.2.840.10008.5.1.4.1.1.7.4")).instances.count, 2)
        // Single-bit frames: the decoder does not open them, and the splitter reports that rather than guessing.
        XCTAssertThrowsError(try DicomInstanceSplitter().split(try DicomStructuralFixtures.multiframeSecondaryCapture(frames: 2, bitsAllocated: 1, sopClass: "1.2.840.10008.5.1.4.1.1.7.1"))) {
            switch $0 as? DicomInstanceSplitter.SplitError {
            case .unsupportedPixelStructure, .unreadable: break
            default: XCTFail("\($0)")
            }
        }
        // Encapsulated frames are carried as one fragment each in the source transfer syntax.
        var encapsulated = try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: try DicomStructuralFixtures.multiframeSecondaryCapture(frames: 2)))
        let fragments = [Data([0xFF, 0xD8, 1, 2, 3, 0xFF, 0xD9]), Data([0xFF, 0xD8, 9, 8, 7, 6, 0xFF, 0xD9])]
        var region = Data([0xFE, 0xFF, 0x00, 0xE0, 0, 0, 0, 0])
        for fragment in fragments {
            var padded = fragment; if !padded.count.isMultiple(of: 2) { padded.append(0) }
            region.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0]); withUnsafeBytes(of: UInt32(padded.count).littleEndian) { region.append(contentsOf: $0) }; region.append(padded)
        }
        region.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
        encapsulated.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OB, value: .bytes(region)))
        let jpeg = try DicomDataSetWriter.part10Data(from: encapsulated, options: .init(transferSyntax: .jpegBaseline))
        let compressed = try DicomInstanceSplitter().split(jpeg)
        XCTAssertEqual(compressed.instances.count, 2)
        for (index, instance) in compressed.instances.enumerated() {
            let decoder = try DCMDecoder(data: instance.part10Data)
            XCTAssertEqual(decoder.info(for: .transferSyntaxUID), DicomTransferSyntax.jpegBaseline.rawValue)
            let reader = try DicomEncapsulatedPixelFrameReader(descriptor: try XCTUnwrap(decoder.encapsulatedPixelDataDescriptor), fileData: instance.part10Data)
            XCTAssertEqual(reader.frameCount, 1)
            XCTAssertEqual(try reader.frame(at: 0).data.prefix(fragments[index].count), fragments[index])
        }
        // Refusals.
        func failure(_ data: Data, identifiers: DicomInstanceSplitter.Identifiers? = nil) -> DicomInstanceSplitter.SplitError? {
            do { _ = try DicomInstanceSplitter().split(data, identifiers: identifiers); return nil } catch let error as DicomInstanceSplitter.SplitError { return error } catch { XCTFail("\(error)"); return nil }
        }
        XCTAssertEqual(failure(Data([1, 2, 3])), .notPart10)
        XCTAssertEqual(failure(try DicomStructuralFixtures.ctSlice(index: 1)), .unsupportedSOPClass("1.2.840.10008.5.1.4.1.1.2"))
        XCTAssertEqual(failure(try DicomStructuralFixtures.multiframeSecondaryCapture(frames: 1)), .singleFrame)
        XCTAssertEqual(failure(source, identifiers: .init(seriesInstanceUID: "2.25.1", sopInstanceUIDs: ["2.25.2"])), .invalidIdentifiers("expected 3 SOP Instance UIDs"))
        XCTAssertEqual(failure(source, identifiers: .init(seriesInstanceUID: "2.25.23269951", sopInstanceUIDs: ["2.25.2", "2.25.3", "2.25.4"])), .invalidIdentifiers("output UIDs must differ from the source identities"))
        if case .converter = failure(try DicomStructuralFixtures.ctSlice(index: 1, sopClass: "1.2.840.10008.5.1.4.1.1.2.1")) {} else { XCTFail("converter diagnostic expected") }
    }
}
