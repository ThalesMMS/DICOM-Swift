import Foundation
import XCTest
import DicomTestSupport
@testable import DicomCore

#if os(macOS)
/// Issue #2794: DCMTK renders an image through a GSPS that DCMTK itself made
/// (`dcmpsmk`, then `dcmodify` for the variants) with `dcmp2pgm`; the P-values
/// this package computes from the same two files must match its 8-bit PGM
/// within one step, the rounding of two independent 8-bit quantisations.
final class DicomDCMTKPresentationOracleTests: XCTestCase {
    private var dcmtk: DCMTKToolchain!
    private var directory: URL!

    private static let ctFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CT/ct_synthetic.dcm")

    override func setUpWithError() throws {
        try super.setUpWithError()
        dcmtk = try DCMTKToolchain.required()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("isis-dcmtk-gsps-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    func test_imageWindow_identityShape_matchesDcmp2pgm() throws {
        try assertMatchesDCMTK(named: "image-window", modifications: [])
    }

    func test_ownWindow_inverseShape_matchesDcmp2pgm() throws {
        try assertMatchesDCMTK(named: "inverse", modifications: [
            "(0028,3110)[0].(0028,1050)=100", "(0028,3110)[0].(0028,1051)=250", "(2050,0020)=INVERSE"
        ])
    }

    func test_ownRescale_matchesDcmp2pgm() throws {
        try assertMatchesDCMTK(named: "rescale", modifications: [
            "(0028,1052)=-1000", "(0028,1053)=2", "(0028,3110)[0].(0028,1050)=0",
            "(0028,3110)[0].(0028,1051)=1000"
        ])
    }

    private func assertMatchesDCMTK(named name: String, modifications: [String],
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let state = directory.appendingPathComponent("\(name).gsps.dcm")
        let rendered = directory.appendingPathComponent("\(name).pgm")
        try dcmtk.run("dcmpsmk", ["+Vw", Self.ctFixture.path, state.path])
        if !modifications.isEmpty {
            try dcmtk.run("dcmodify", ["-nb"] + modifications.flatMap { ["-m", $0] } + [state.path])
        }
        try dcmtk.run("dcmp2pgm", ["-p", state.path, Self.ctFixture.path, rendered.path])
        let oracle = try Self.pgmSamples(Data(contentsOf: rendered))

        let image = try DCMDecoder(contentsOf: Self.ctFixture)
        let presentation = try XCTUnwrap(DCMDecoder(contentsOf: state).grayscalePresentationState,
                                         file: file, line: line)
        let profile = presentation.voiSelections.first?.displayTransformProfile
            ?? presentation.displayTransformProfile
        let stored = try XCTUnwrap(image.storedPixelValues(), file: file, line: line)
        XCTAssertEqual(oracle.width * oracle.height, stored.count, "the displayed area is the whole image",
                       file: file, line: line)
        var largest = 0
        for (index, value) in stored.enumerated() {
            let ours = try XCTUnwrap(profile.displayValue(forStoredPixelValue: Double(value)), file: file, line: line)
            largest = max(largest, abs(Int(ours) - Int(oracle.samples[index])))
        }
        XCTAssertLessThanOrEqual(largest, 1, "\(name): largest P-value difference from dcmp2pgm",
                                 file: file, line: line)
    }

    /// A binary 8-bit PGM (P5): the header, one whitespace, then the samples.
    private static func pgmSamples(_ data: Data) throws -> (width: Int, height: Int, samples: [UInt8]) {
        var fields: [String] = []
        var index = data.startIndex
        while fields.count < 4, index < data.endIndex {
            while index < data.endIndex, data[index] == UInt8(ascii: "#") {
                while index < data.endIndex, data[index] != UInt8(ascii: "\n") { index += 1 }
                index += 1
            }
            var field = ""
            while index < data.endIndex, !Character(UnicodeScalar(data[index])).isWhitespace {
                field.append(Character(UnicodeScalar(data[index])))
                index += 1
            }
            if !field.isEmpty { fields.append(field) }
            index += 1
        }
        guard fields.count == 4, fields[0] == "P5", let width = Int(fields[1]), let height = Int(fields[2]),
              fields[3] == "255", data.endIndex - index == width * height else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return (width, height, Array(data[index...]))
    }
}
#endif
