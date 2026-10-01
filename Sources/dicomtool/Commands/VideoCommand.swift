import ArgumentParser
import DicomCore
import Foundation
#if canImport(DicomAppleMedia)
import DicomAppleMedia
#endif

struct VideoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "video",
        abstract: "Inspect, extract and remux DICOM video streams.",
        subcommands: [Inspect.self, ExtractStream.self, Remux.self])

    static func load(_ file: String) async throws -> DicomVideo {
        let decoder = try await DCMDecoder(contentsOf: URL(fileURLWithPath: file))
        guard let video = decoder.video else { throw ValidationError("No supported video stream.") }
        return video
    }

    static func inspectionJSON(_ video: DicomVideo) throws -> String {
        let timeline = try DicomVideoTimeline(video: video)
        let description = timeline.description
        return try WaveformCommand.json([
            "stream": ["codec": String(describing: description.codec), "framing": description.framing,
                       "profile": description.profile as Any? ?? NSNull(),
                       "width": description.width as Any? ?? NSNull(), "height": description.height as Any? ?? NSNull(),
                       "bitDepth": description.bitDepth as Any? ?? NSNull(),
                       "closedGOP": description.closedGOP as Any? ?? NSNull(), "limitations": description.limitations],
            "timescale": timeline.timescale as Any? ?? NSNull(),
            "timeline": timeline.accessUnits.map {
                ["decodeIndex": $0.decodeIndex, "presentationIndex": $0.presentationIndex as Any? ?? NSNull(),
                 "pts": $0.pts as Any? ?? NSNull(), "dts": $0.dts as Any? ?? NSNull(),
                 "duration": $0.duration as Any? ?? NSNull(), "keyFrame": $0.isKeyFrame,
                 "fragments": $0.fragmentIndexes, "byteStart": $0.byteRange.lowerBound,
                 "byteEnd": $0.byteRange.upperBound] as [String: Any]
            }, "diagnostics": timeline.diagnostics.map { String(describing: $0.code) }
        ])
    }

    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "inspect")
        @Argument var file: String
        mutating func run() async throws { print(try VideoCommand.inspectionJSON(await VideoCommand.load(file))) }
    }

    struct ExtractStream: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "extract-stream")
        @Argument var file: String
        @Argument var out: String
        mutating func run() async throws {
            try await VideoCommand.load(file).streamData.write(to: URL(fileURLWithPath: out), options: .atomic)
        }
    }

    struct Remux: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remux")
        @Argument var file: String
        @Argument var out: String
        mutating func run() async throws {
            #if canImport(DicomAppleMedia)
            let video = try await VideoCommand.load(file)
            let timeline = try DicomVideoTimeline(video: video)
            guard let scale = timeline.timescale, let duration = timeline.accessUnits.first?.duration, duration > 0,
                  timeline.accessUnits.allSatisfy({ $0.duration == duration }) else {
                throw ValidationError("Remux requires known constant timing.")
            }
            try await DicomVideoRemuxer.writePlayableContainer(for: video,
                frameRate: Double(scale) / Double(duration), to: URL(fileURLWithPath: out))
            #else
            throw ValidationError("Video remux is unsupported on this platform; it requires Apple media frameworks.")
            #endif
        }
    }
}
