//
//  ImageCompareCommand.swift
//
//  Pixel-level comparison of two DICOM images (issue #2836).
//

import ArgumentParser
import DicomCore
import Foundation

/// `dicomtool image compare <reference> <test>`: error metrics like DCMTK's dcmicmp, with limits whose violation
/// exits with status 65, and an optional amplified difference image.
struct ImageCompareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare a test image with a reference: max error, MAE, RMSE, PSNR and SNR",
        discussion: """
            Values are compared after Rescale Slope/Intercept by default (--stored compares stored samples), or
            after a linear VOI window with --window CENTER WIDTH. Rows, columns, frames and samples per pixel
            must match. A --check-* limit that is not met exits with status 65.
            """
    )

    enum Format: String, ExpressibleByArgument { case text, json }

    @Argument(help: "Reference DICOM image", completion: .file()) var reference: String
    @Argument(help: "Test DICOM image", completion: .file()) var test: String
    @Flag(name: .long, help: "Compare stored sample values instead of modality values") var stored = false
    @Option(name: .long, parsing: .upToNextOption, help: "Linear VOI window: CENTER WIDTH") var window: [Double] = []
    @Option(name: .long, help: "Fail when the maximum absolute error exceeds this") var checkError: Double?
    @Option(name: .long, help: "Fail when the mean absolute error exceeds this") var checkMae: Double?
    @Option(name: .long, help: "Fail when the RMSE exceeds this") var checkRmse: Double?
    @Option(name: .long, help: "Fail when the PSNR (dB) is below this") var checkPsnr: Double?
    @Option(name: .long, help: "Fail when the SNR (dB) is below this") var checkSnr: Double?
    @Option(name: .long, help: "Write |reference - test| as a 16-bit Secondary Capture here") var saveDiff: String?
    @Option(name: .long, help: "Amplification of the difference image") var amplify: Double = 1
    @Option(name: .long, help: "Output format: text or json") var format: Format = .text

    mutating func run() throws {
        let stage: DicomImageComparison.Stage
        if !window.isEmpty {
            guard window.count == 2 else {
                throw CLIError.invalidArgument(argument: "--window", value: "\(window)", reason: "expected CENTER WIDTH")
            }
            stage = .window(center: window[0], width: window[1])
        } else {
            stage = stored ? .stored : .modality
        }
        let referenceDecoder = try DCMDecoder(contentsOf: URL(fileURLWithPath: reference))
        let result = try DicomImageComparison.compare(reference: referenceDecoder,
                                                      test: try DCMDecoder(contentsOf: URL(fileURLWithPath: test)),
                                                      stage: stage, collectDifferences: saveDiff != nil)
        emit(result)
        if let saveDiff {
            try Self.differenceImage(result, like: referenceDecoder, amplification: amplify)
                .write(to: URL(fileURLWithPath: saveDiff))
        }
        let total = result.total
        let failures = [
            checkError.map { total.maximumAbsoluteError > $0 ? "maximum error" : nil },
            checkMae.map { total.meanAbsoluteError > $0 ? "MAE" : nil },
            checkRmse.map { total.rootMeanSquareError > $0 ? "RMSE" : nil },
            checkPsnr.map { total.peakSignalToNoiseRatio < $0 ? "PSNR" : nil },
            checkSnr.map { total.signalToNoiseRatio < $0 ? "SNR" : nil }
        ].compactMap { $0 ?? nil }
        if !failures.isEmpty {
            FileHandle.standardError.write(Data("Limit not met: \(failures.joined(separator: ", "))\n".utf8))
            throw ExitCode(65)
        }
    }

    private func emit(_ result: DicomImageComparison.Result) {
        func object(_ metrics: DicomImageComparison.Metrics) -> [String: Any] {
            ["maximumAbsoluteError": metrics.maximumAbsoluteError, "meanAbsoluteError": metrics.meanAbsoluteError,
             "rootMeanSquareError": metrics.rootMeanSquareError,
             "peakSignalToNoiseRatio": metrics.peakSignalToNoiseRatio.isFinite ? metrics.peakSignalToNoiseRatio : "inf",
             "signalToNoiseRatio": metrics.signalToNoiseRatio.isFinite ? metrics.signalToNoiseRatio : "inf",
             "sampleCount": metrics.sampleCount]
        }
        switch format {
        case .text:
            let total = result.total
            print("Maximum absolute error: \(total.maximumAbsoluteError)")
            print("Mean absolute error: \(total.meanAbsoluteError)")
            print("Root mean square error: \(total.rootMeanSquareError)")
            print("Peak signal-to-noise ratio: \(total.peakSignalToNoiseRatio)")
            print("Signal-to-noise ratio: \(total.signalToNoiseRatio)")
        case .json:
            let payload: [String: Any] = ["total": object(result.total), "frames": result.frames.map(object)]
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(data + Data("\n".utf8))
            }
        }
    }

    /// Multi-frame Grayscale Word Secondary Capture of the amplified absolute differences, clamped to 65 535.
    static func differenceImage(_ result: DicomImageComparison.Result, like reference: DCMDecoder,
                                amplification: Double) throws -> Data {
        var pixels = Data()
        for frame in result.absoluteDifferences {
            for difference in frame {
                let value = UInt16(min(65_535, max(0, (difference * amplification).rounded())))
                pixels.append(UInt8(value & 0xFF))
                pixels.append(UInt8(value >> 8))
            }
        }
        let sopClassUID = "1.2.840.10008.5.1.4.1.1.7.3"
        let sopInstanceUID = DicomDataSetWriter.makeUID()
        func text(_ tag: DicomTag, _ vr: DicomVR, _ value: String) -> DicomDataElement {
            DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
        }
        func short(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
            DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(value)]))
        }
        let samples = reference.samplesPerPixel
        let dataSet = DicomDataSet(elements: [
            text(.sopClassUID, .UI, sopClassUID), text(.sopInstanceUID, .UI, sopInstanceUID),
            text(.studyInstanceUID, .UI, DicomDataSetWriter.makeUID()),
            text(.seriesInstanceUID, .UI, DicomDataSetWriter.makeUID()),
            text(.modality, .CS, "OT"), DicomDataElement(tag: DicomTag.imageType.rawValue, vr: .CS, value: .strings(["DERIVED", "SECONDARY"])),
            text(.numberOfFrames, .IS, "\(result.absoluteDifferences.count)"),
            DicomDataElement(tag: 0x0028_0009, vr: .AT, value: .unsignedIntegers([0x0018_2002])),
            short(.samplesPerPixel, 1), text(.photometricInterpretation, .CS, "MONOCHROME2"),
            short(.rows, reference.height), short(.columns, reference.width * samples),
            short(.bitsAllocated, 16), short(.bitsStored, 16), short(.highBit, 15), short(.pixelRepresentation, 0),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(pixels))
        ])
        return try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(transferSyntax: .explicitVRLittleEndian,
                                              mediaStorageSOPClassUID: sopClassUID,
                                              mediaStorageSOPInstanceUID: sopInstanceUID)
        )
    }
}
