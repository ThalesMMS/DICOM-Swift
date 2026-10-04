import Foundation
import ImageIO
import XCTest
@testable import DicomCore

/// Rendered and thumbnail representations of instances stored with compressed Pixel Data.
final class DicomWebCompressedRenderedTests: XCTestCase {
    private static let serviceURL = "https://server.example/dicom-web"
    private static let study = "2.25.29830001"
    private static let series = "2.25.29830002"

    func test_renderedAndThumbnail_ofJPEGLSJPEG2000AndJPEGLossless_answerWithTheRequestedSize() async throws {
        let syntaxes: [DicomTransferSyntax] = [.jpegLSLossless, .jpeg2000Lossless, .jpegLosslessFirstOrder]
        let storage = DicomWebInMemoryStorage()
        for (index, syntax) in syntaxes.enumerated() {
            let native = try Self.nativeInstance(sop: "2.25.2983\(index + 10)")
            let compressed = try await DicomCodecWorkflowEngine().transcode(native, to: syntax).data
            let stored = try storage.add(part10Data: compressed)
            XCTAssertEqual(stored.transferSyntax, syntax)
        }
        let server = DicomWebServer(configuration: DicomWebServerConfiguration(cacheEnabled: false), storage: storage)
        for (index, syntax) in syntaxes.enumerated() {
            let instance = "\(Self.serviceURL)/studies/\(Self.study)/series/\(Self.series)/instances/2.25.2983\(index + 10)"
            for (path, type, width, height) in [("rendered?viewport=40,30", "image/png", 40, 30),
                                                ("thumbnail?viewport=32,24", "image/jpeg", 32, 24),
                                                ("frames/1/rendered", "image/png", 64, 48)] {
                let response = try await server.send(.init(method: .get, url: URL(string: "\(instance)/\(path)")!,
                                                           headers: ["Accept": type]))
                XCTAssertEqual(response.statusCode, 200, "\(syntax) \(path)")
                XCTAssertEqual(response.headers["Content-Type"], type, "\(syntax) \(path)")
                let image = try XCTUnwrap(CGImageSourceCreateWithData(response.body as CFData, nil)
                    .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }, "\(syntax) \(path)")
                XCTAssertEqual(image.width, width, "\(syntax) \(path)")
                XCTAssertEqual(image.height, height, "\(syntax) \(path)")
            }
        }
        let seriesThumbnail = try await server.send(.init(method: .get,
            url: URL(string: "\(Self.serviceURL)/studies/\(Self.study)/series/\(Self.series)/thumbnail?viewport=16,12")!,
            headers: ["Accept": "image/jpeg"]))
        XCTAssertEqual(seriesThumbnail.statusCode, 200)
    }

    /// A 64×48 16-bit gradient, so a decoded frame differs from an empty one.
    private static func nativeInstance(sop: String) throws -> Data {
        let rows = 48, columns = 64
        var pixels = Data(capacity: rows * columns * 2)
        for value in 0..<(rows * columns) {
            withUnsafeBytes(of: UInt16(value * 13 % 4096).littleEndian) { pixels.append(contentsOf: $0) }
        }
        func string(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement {
            .init(tag: tag.rawValue, vr: vr, value: .strings([value]))
        }
        func short(_ tag: DicomTag, _ value: UInt) -> DicomDataElement {
            .init(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([value]))
        }
        let dataSet = DicomDataSet(elements: [
            string(.sopClassUID, .UI, DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID),
            string(.sopInstanceUID, .UI, sop), string(.studyInstanceUID, .UI, study),
            string(.seriesInstanceUID, .UI, series), string(.modality, .CS, "CT"),
            short(.samplesPerPixel, 1), string(.photometricInterpretation, .CS, "MONOCHROME2"),
            short(.rows, UInt(rows)), short(.columns, UInt(columns)), short(.bitsAllocated, 16),
            short(.bitsStored, 12), short(.highBit, 11), short(.pixelRepresentation, 0),
            .init(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixels))
        ])
        return try DicomDataSetWriter.part10Data(from: dataSet, options: .init(transferSyntax: .explicitVRLittleEndian,
            mediaStorageSOPClassUID: DicomDataSetWriter.defaultSecondaryCaptureImageStorageSOPClassUID,
            mediaStorageSOPInstanceUID: sop))
    }
}
