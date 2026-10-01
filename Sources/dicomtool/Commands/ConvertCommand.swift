//
//  ConvertCommand.swift
//
//  Converts a DICOM data set between Part 10, PS3.18 DICOM JSON and PS3.19 Native DICOM Model XML.
//

import ArgumentParser
import DicomCore
import Foundation

/// `dicomtool convert <input> --to dicom|json|xml [--output path]`. The input representation is detected
/// from its bytes. JSON and XML keep every VR, multiplicity, empty value, person-name group, private tag and
/// binary; DS/IS/SV/UV are written as text unless `--numbers` asks for exact JSON numbers; bulk-data
/// references are reported, never fetched, and a Part 10 output refuses unresolved references.
struct ConvertCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "convert",
        abstract: "Convert between Part 10, DICOM JSON and Native DICOM XML",
        discussion: """
            Reads a Part 10 file, a DICOM JSON object (or array with one object) or a Native DICOM Model
            document and writes the requested representation. Pixel Data is carried inline unless
            --omit-pixel-data is given. Part 10 output uses Explicit VR Little Endian. Exit 65 means the
            input could not be represented without loss; the reason is printed.
            """
    )

    enum Representation: String, ExpressibleByArgument, CaseIterable { case dicom, json, xml }

    @Argument(help: "Input file (Part 10, .json or .xml)", completion: .file())
    var input: String

    @Option(name: .long, help: "Output representation: dicom, json or xml")
    var to: Representation

    @Option(name: [.short, .long], help: "Output file; standard output when omitted")
    var output: String?

    @Flag(name: .long, help: "Write DS/IS/SV/UV as JSON numbers when exactly representable")
    var numbers = false

    @Flag(name: .long, help: "Leave Pixel Data (7FE0,0010) out of JSON/XML output")
    var omitPixelData = false

    @Option(name: .long, help: "Maximum input bytes accepted (default 256 MiB)")
    var maximumBytes: Int = 256 * 1024 * 1024

    mutating func run() throws {
        do {
            try convert()
        } catch let error as ConvertError {
            switch error {
            case .unrepresentable, .unresolvedBulkData:
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                throw ExitCode(65)
            default:
                throw error
            }
        }
    }

    private func convert() throws {
        let url = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError.fileNotReadable(path: input, reason: "File does not exist") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw CLIError.fileNotReadable(path: input, reason: "input exceeds \(maximumBytes) bytes") }
        let decoded = try Self.decode(data, limits: .init(maximumBytes: maximumBytes))
        let options = DicomDataSetRepresentation.EncodingOptions(decimals: numbers ? .numbersWhenExact : .preserveText,
                                                                 binary: omitPixelData ? .omit([DicomTag.pixelData.rawValue]) : .inline)
        let bytes: Data
        do {
            switch to {
            case .json: bytes = try DicomJSONCodec.encode(decoded.dataSet, options: options)
            case .xml: bytes = try DicomNativeXMLCodec.encode(decoded.dataSet, options: options)
            case .dicom:
                guard decoded.bulkData.isEmpty else {
                    throw ConvertError.unresolvedBulkData(decoded.bulkData.map { String(format: "%08X", $0.tag) })
                }
                bytes = try DicomDataSetWriter.part10Data(from: decoded.dataSet, options: .init(transferSyntax: .explicitVRLittleEndian))
            }
        } catch let error as DicomDataSetRepresentation.Error {
            throw ConvertError.unrepresentable(error)
        }
        for reference in decoded.bulkData {
            FileHandle.standardError.write(Data("bulk data reference kept: \(String(format: "%08X", reference.tag)) \(reference.uri)\n".utf8))
        }
        for diagnostic in decoded.diagnostics {
            FileHandle.standardError.write(Data("diagnostic: \(diagnostic.code.rawValue) at \(diagnostic.path)\n".utf8))
        }
        if let output {
            try bytes.write(to: URL(fileURLWithPath: output), options: [.atomic])
        } else {
            FileHandle.standardOutput.write(bytes)
        }
    }

    /// Detects Part 10 (DICM at offset 128), JSON (`{`/`[`) or XML (`<`) from the bytes.
    static func decode(_ data: Data, limits: DicomDataSetRepresentation.DecodingOptions) throws -> DicomDataSetRepresentation.Decoded {
        if DicomPart10FileMetaParser.hasPart10Prefix(data) {
            let decoder = try DCMDecoder(data: data)
            return .init(dataSet: try DicomPart10PixelDataPreserver.dataSet(from: decoder))
        }
        let first = data.first { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 || $0 == 0xEF || $0 == 0xBB || $0 == 0xBF) }
        do {
            switch first {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                let decoded = try DicomJSONCodec.decode(data, options: limits)
                guard decoded.count == 1, let only = decoded.first else { throw ConvertError.multipleDataSets(decoded.count) }
                return only
            case UInt8(ascii: "<"):
                return try DicomNativeXMLCodec.decode(data, options: limits)
            default:
                throw ConvertError.unrecognizedInput
            }
        } catch let error as DicomDataSetRepresentation.Error {
            throw ConvertError.unrepresentable(error)
        }
    }

    enum ConvertError: Error, CustomStringConvertible {
        case unrecognizedInput
        case multipleDataSets(Int)
        case unresolvedBulkData([String])
        case unrepresentable(DicomDataSetRepresentation.Error)

        var description: String {
            switch self {
            case .unrecognizedInput: return "input is neither Part 10, DICOM JSON nor Native DICOM XML"
            case .multipleDataSets(let count): return "input carries \(count) data sets; convert exactly one"
            case .unresolvedBulkData(let tags): return "Part 10 output needs resolved bulk data for \(tags.joined(separator: ", "))"
            case .unrepresentable(let error): return "not representable without loss: \(error)"
            }
        }
    }
}
