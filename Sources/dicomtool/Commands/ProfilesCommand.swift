//
//  ProfilesCommand.swift
//
//  Lists the SOP Classes whose IOD composition the instance validator qualifies.
//

import ArgumentParser
import DicomCore
import Foundation

/// Prints `DicomQualifiedProfileCatalog`: the exact scope of `dicomtool validate --composed` exit 0,
/// with the family, lot, coverage map and oracle of each profile. This list is the input of the
/// generated conformance declaration; it asserts no conformance beyond the composed layers.
struct ProfilesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "List the SOP Classes qualified by composed validation",
        discussion: """
            Each row is a SOP Class whose IOD modules are composed on native transfer syntaxes,
            with a profile corpus and an independent comparison. Other SOP Classes keep the
            moduleRuleUnavailable limitation. The list is not a general conformance statement.
            """
    )

    @Option(name: [.short, .long], help: "Output format: text or json (default: text)")
    var format: OutputFormat = .text

    mutating func run() throws {
        let profiles = DicomQualifiedProfileCatalog.profiles
        if format == .json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            print(String(decoding: try encoder.encode(profiles), as: UTF8.self))
        } else {
            for profile in profiles {
                print("\(profile.sopClassUID)\t\(profile.name)\t\(profile.family)\t\(profile.lot)\t\(profile.coverageDocument)")
            }
        }
    }
}
