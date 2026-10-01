import ArgumentParser
import DicomCore
import Foundation

struct WaveformCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "waveform",
        abstract: "Inspect and export waveform measurements.", subcommands: [Inspect.self, Export.self])

    struct Inspect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "inspect")
        @Argument var file: String

        mutating func run() async throws {
            let source = try await DicomByteSource.openFile(URL(fileURLWithPath: file))
            do {
                let index = try await DicomWaveformSourceIndex.build(from: source)
                print(try WaveformCommand.inspectionJSON(index))
                await source.close()
            } catch { await source.close(); throw error }
        }
    }

    static func inspectionJSON(_ index: DicomWaveformSourceIndex) throws -> String {
        let groups: [[String: Any]] = index.groups.enumerated().map { offset, group in
            ["group": offset + 1, "samples": group.numberOfSamples,
             "samplingFrequency": group.metadata.samplingFrequency,
             "channels": group.metadata.channels.enumerated().map { ordinal, channel -> [String: Any] in
                ["channel": ordinal + 1, "label": channel.label as Any? ?? NSNull(),
                 "units": channel.sensitivityUnits?.codeValue as Any? ?? NSNull()]
             }]
        }
        let annotations: [[String: Any]] = index.annotations.map {
            ["text": $0.text as Any? ?? NSNull(), "codeMeaning": $0.conceptCode?.codeMeaning as Any? ?? NSNull(),
             "rangeType": $0.temporalRangeType?.rawValue as Any? ?? NSNull(),
             "samplePositions": $0.referencedSamplePositions, "timeOffsets": $0.referencedTimeOffsets,
             "channels": $0.referencedChannels.map { ["group": $0.multiplexGroupNumber, "channel": $0.channelNumber] }]
        }
        return try json(["groups": groups, "annotations": annotations])
    }

    static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "export")
        @Argument var file: String
        @Option var group: Int = 1
        @Option(help: "Comma-separated one-based channel ordinals.") var channels: String
        @Option(help: "Start time in seconds, inclusive.") var start: Double
        @Option(help: "End time in seconds, exclusive.") var end: Double
        @Option var format: String = "csv"

        mutating func run() async throws {
            guard start.isFinite, end.isFinite, end >= start, ["csv", "json"].contains(format) else {
                throw ValidationError("Expected finite start <= end and format csv or json.")
            }
            let tokens = channels.split(separator: ",", omittingEmptySubsequences: false)
            let selected = tokens.compactMap { Int($0) }
            guard selected.count == tokens.count else { throw ValidationError("Invalid channel ordinals.") }
            let source = try await DicomByteSource.openFile(URL(fileURLWithPath: file))
            do {
                let reader = try await DicomWaveformSegmentReader.open(source: source)
                let values = try await reader.samples(group: group, channels: selected, timeRange: start..<end)
                print(try Self.output(values, format: format))
                await source.close()
            } catch { await source.close(); throw error }
        }

        static func output(_ values: [DicomWaveformSegmentReader.ChannelSamples], format: String) throws -> String {
            if format == "json" {
                return try WaveformCommand.json(values.map {
                    ["channel": $0.channel, "startTime": $0.timeSeries.startTime,
                     "samplingFrequency": $0.timeSeries.samplingFrequency,
                     "units": $0.timeSeries.units as Any? ?? NSNull(),
                     "values": $0.timeSeries.physicalSamples.map { $0 as Any? ?? NSNull() }] as [String: Any]
                })
            }
            func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
            var rows = ["channel,time_seconds,value,units"]
            for channel in values {
                for (index, value) in channel.timeSeries.physicalSamples.enumerated() {
                    let time = channel.timeSeries.startTime + Double(index) / channel.timeSeries.samplingFrequency
                    rows.append("\(channel.channel),\(time),\(value.map { String($0) } ?? ""),\(quoted(channel.timeSeries.units ?? ""))")
                }
            }
            return rows.joined(separator: "\n")
        }
    }
}
