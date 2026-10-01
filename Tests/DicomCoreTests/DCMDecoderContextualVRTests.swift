import Foundation
import XCTest
@testable import DicomCore

final class DCMDecoderContextualVRTests: XCTestCase {
    func test_dataSetAndSingleElement_usePixelSignAndMixedLUTWords() throws {
        var source = base()
        source.set(.init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([1])))
        source.set(.init(tag: 0x00280120, vr: .SS, value: .signedIntegers([-1024])))
        source.set(.init(tag: 0x00281101, vr: .SS, value: .signedIntegers([65535, -1, 16])))
        for syntax in [DicomTransferSyntax.implicitVRLittleEndian, .explicitVRLittleEndian,
                       .explicitVRBigEndian, .deflatedExplicitVRLittleEndian] {
            let decoder = try DCMDecoder(data: DicomDataSetWriter.part10Data(from: source,
                options: .init(transferSyntax: syntax)))
            XCTAssertEqual(decoder.redPaletteDescriptor?.firstMappedValue, -1, syntax.rawValue)
            for tag in [0x00280120, 0x00281101] {
                XCTAssertEqual(decoder.dataElement(for: tag)?.vr, .SS, syntax.rawValue)
                XCTAssertEqual(decoder.dataElement(for: tag)?.value, source[tag]?.value, syntax.rawValue)
                XCTAssertEqual(decoder.dataSet[tag]?.value, source[tag]?.value, syntax.rawValue)
                XCTAssertEqual(decoder.info(for: tag), source[tag]?.stringValues.joined(separator: "\\"), syntax.rawValue)
            }
        }
    }

    func test_sequenceItems_inheritContextAndRespectLocalOverrides() throws {
        var source = base()
        source.set(.init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([1])))
        let inherited = DicomDataSet(elements: [.init(tag: 0x00280120, vr: .SS, value: .signedIntegers([-7]))])
        let overridden = DicomDataSet(elements: [
            .init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([0])),
            .init(tag: 0x00280120, vr: .US, value: .unsignedIntegers([65000]))
        ])
        source.set(.init(tag: 0x00081115, vr: .SQ, value: .sequence([inherited, overridden, inherited].map { .init(dataSet: $0) })))
        let decoder = try DCMDecoder(data: DicomDataSetWriter.part10Data(from: source,
            options: .init(transferSyntax: .implicitVRLittleEndian)))
        let items = decoder.dataSet.sequenceItems(for: 0x00081115)
        XCTAssertEqual(items.map { $0.dataSet[0x00280120]?.vr }, [.SS, .US, .SS])
        XCTAssertEqual(items.map { $0.dataSet[0x00280120]?.intValues }, [[-7], [65000], [-7]])
        XCTAssertEqual(decoder.dataElement(for: 0x00081115)?.value, .sequence(items))
    }

    func test_voiDescriptor_usesRescaledRangeInLegacyDataset() throws {
        var source = base()
        source.set(.init(tag: 0x00281052, vr: .DS, value: .strings(["-1024"])))
        source.set(.init(tag: 0x00281053, vr: .DS, value: .strings(["1"])))
        source.set(.init(tag: 0x00283010, vr: .SQ, value: .sequence([.init(dataSet: .init(elements: [
            .init(tag: 0x00283002, vr: .SS, value: .signedIntegers([1, -1024, 16])),
            .init(tag: 0x00283006, vr: .US, value: .unsignedIntegers([42]))
        ]))])))
        let decoder = try DCMDecoder(data: DicomDataSetWriter.part10Data(from: source,
            options: .init(transferSyntax: .implicitVRLittleEndian)))
        let descriptor = decoder.dataSet.sequenceItems(for: 0x00283010).first?.dataSet[0x00283002]
        XCTAssertEqual(descriptor?.vr, .SS)
        XCTAssertEqual(descriptor?.intValues, [1, -1024, 16])
    }

    func test_modernVRs_readFullLengthHeadersAndLazyValues() throws {
        var source = base()
        source.set(.init(tag: 0x00720082, vr: .SV, value: .signedIntegers([Int.min])))
        source.set(.init(tag: 0x0008040C, vr: .UV, value: .unsignedIntegers([UInt.max])))
        source.set(.init(tag: 0x00080119, vr: .UC, value: .strings([String(repeating: "LONG LABEL ", count: 12) + "END"])))
        for syntax in [DicomTransferSyntax.explicitVRLittleEndian, .explicitVRBigEndian,
                       .implicitVRLittleEndian, .deflatedExplicitVRLittleEndian] {
            let decoder = try DCMDecoder(data: DicomDataSetWriter.part10Data(from: source, options: .init(transferSyntax: syntax)))
            for tag in [0x00720082, 0x0008040C, 0x00080119] {
                XCTAssertEqual(decoder.dataElement(for: tag)?.value, source[tag]?.value, syntax.rawValue)
                XCTAssertEqual(decoder.info(for: tag), source[tag]?.stringValue, syntax.rawValue)
            }
        }
    }

    private func base() -> DicomDataSet {
        .init(elements: [
            .init(tag: 0x00280002, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: 0x00280004, vr: .CS, value: .strings(["MONOCHROME2"])),
            .init(tag: 0x00280010, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: 0x00280011, vr: .US, value: .unsignedIntegers([1])),
            .init(tag: 0x00280100, vr: .US, value: .unsignedIntegers([16])),
            .init(tag: 0x00280101, vr: .US, value: .unsignedIntegers([12])),
            .init(tag: 0x00280102, vr: .US, value: .unsignedIntegers([11])),
            .init(tag: 0x00280103, vr: .US, value: .unsignedIntegers([0])),
            .init(tag: 0x7FE00010, vr: .OW, value: .bytes(Data([0, 0])))
        ])
    }
}
