import Foundation

/// Profile, level and Blu-ray format constraints each video transfer syntax places on its bitstream (PS3.5 §8.2,
/// Table 8-4). A violation is reported, never refused: the H.264 parser also reads Main-profile streams, and real
/// files and ffmpeg fixtures carry them under .102 (issue #2905).
enum DicomVideoConformance {
    struct Violation: Equatable, Sendable {
        let detail: String
    }

    /// MPEG-2 `profile_and_level_indication` (ISO/IEC 13818-2 Table 8-2/8-3): a smaller level code is a higher level.
    private static let mpeg2Levels = [10: "Low", 8: "Main", 6: "High 1440", 4: "High"]
    private static let mpeg2Profiles = [1: "High", 2: "Spatially Scalable", 3: "SNR Scalable", 4: "Main", 5: "Simple"]
    private static let h264Profiles = [66: "Baseline", 77: "Main", 88: "Extended", 100: "High", 110: "High 10",
                                       118: "Multiview High", 122: "High 4:2:2", 128: "Stereo High",
                                       244: "High 4:4:4 Predictive"]
    private static let hevcProfiles = [1: "Main", 2: "Main 10", 3: "Main Still Picture"]

    static func violations(of syntax: DicomTransferSyntax,
                           in description: DicomVideoStreamDescription) -> [Violation] {
        switch syntax {
        case .mpeg2MainProfileMainLevel, .mpeg2MainProfileMainLevelFragmentable:
            return mpeg2(description, maximumLevel: 8)
        case .mpeg2MainProfileHighLevel, .mpeg2MainProfileHighLevelFragmentable:
            return mpeg2(description, maximumLevel: 4)
        case .mpeg4AVCH264HighProfileLevel41, .mpeg4AVCH264HighProfileLevel41Fragmentable:
            return h264(description, profiles: [100], maximumLevel: 41)
        case .mpeg4AVCH264BDCompatibleHighProfileLevel41, .mpeg4AVCH264BDCompatibleHighProfileLevel41Fragmentable:
            return h264(description, profiles: [100], maximumLevel: 41) + blurayFormat(description)
        case .mpeg4AVCH264HighProfileLevel42For2DVideo, .mpeg4AVCH264HighProfileLevel42For2DVideoFragmentable,
             .mpeg4AVCH264HighProfileLevel42For3DVideo, .mpeg4AVCH264HighProfileLevel42For3DVideoFragmentable:
            return h264(description, profiles: [100], maximumLevel: 42)
        case .mpeg4AVCH264StereoHighProfileLevel42, .mpeg4AVCH264StereoHighProfileLevel42Fragmentable:
            // The base view is coded as High; the Stereo High profile is signalled in the subset SPS.
            return h264(description, profiles: [100, 128], maximumLevel: 42)
        case .hevcH265MainProfileLevel51:
            return hevc(description, profiles: [1], maximumLevel: 153)
        case .hevcH265Main10ProfileLevel51:
            // Main is a subset of Main 10.
            return hevc(description, profiles: [1, 2], maximumLevel: 153)
        default:
            return []
        }
    }

    private static func mpeg2(_ description: DicomVideoStreamDescription, maximumLevel: Int) -> [Violation] {
        var violations: [Violation] = []
        if let profile = description.profileIDC, profile != 4 {
            violations.append(.init(detail: "MPEG-2 profile \(mpeg2Profiles[profile] ?? "code \(profile)"), expected Main"))
        }
        if let level = description.levelIDC {
            // Valid level codes are 4, 6, 8 and 10; a code below the maximum's is a higher level.
            if mpeg2Levels[level] == nil || level < maximumLevel {
                violations.append(.init(detail: "MPEG-2 level \(mpeg2Levels[level] ?? "code \(level)"), "
                                        + "expected at most \(mpeg2Levels[maximumLevel] ?? "\(maximumLevel)") Level"))
            }
        }
        return violations
    }

    private static func h264(_ description: DicomVideoStreamDescription, profiles: Set<Int>,
                             maximumLevel: Int) -> [Violation] {
        var violations: [Violation] = []
        if let profile = description.profileIDC, !profiles.contains(profile) {
            let expected = profiles.sorted().map { "\(h264Profiles[$0] ?? "\($0)") (\($0))" }.joined(separator: " or ")
            violations.append(.init(detail: "H.264 profile \(h264Profiles[profile] ?? "unknown") (\(profile)), "
                                    + "expected \(expected)"))
        }
        // level_idc is ten times the level number.
        if let level = description.levelIDC, level > maximumLevel {
            violations.append(.init(detail: "H.264 level \(levelName(level, scale: 10)) (level_idc \(level)), "
                                    + "expected at most \(levelName(maximumLevel, scale: 10))"))
        }
        return violations
    }

    private static func hevc(_ description: DicomVideoStreamDescription, profiles: Set<Int>,
                             maximumLevel: Int) -> [Violation] {
        var violations: [Violation] = []
        if let profile = description.profileIDC, !profiles.contains(profile) {
            let expected = profiles.sorted().map { "\(hevcProfiles[$0] ?? "\($0)") (\($0))" }.joined(separator: " or ")
            violations.append(.init(detail: "HEVC profile \(hevcProfiles[profile] ?? "unknown") (\(profile)), "
                                    + "expected \(expected)"))
        }
        // general_level_idc is thirty times the level number.
        if let level = description.levelIDC, level > maximumLevel {
            violations.append(.init(detail: "HEVC level \(levelName(level, scale: 30)) (level_idc \(level)), "
                                    + "expected at most \(levelName(maximumLevel, scale: 30))"))
        }
        return violations
    }

    /// PS3.5 §8.2.8: the BD-compatible syntax admits 1920×1080 at 25 or 29.97 frames/s interlaced or 23.976 or
    /// 24 frames/s progressive, and 1280×720 at 50, 59.94, 23.976 or 24 frames/s progressive.
    private static func blurayFormat(_ description: DicomVideoStreamDescription) -> [Violation] {
        guard let width = description.width, let height = description.height else {
            return [.init(detail: "Blu-ray format: frame size unknown")]
        }
        let frameRate: Double? = {
            guard let tick = description.numUnitsInTick, let scale = description.timeScale, tick > 0 else { return nil }
            return Double(scale) / Double(2 * tick)
        }()
        let interlaced = description.frameMbsOnly == false
        let admitted: [(width: Int, height: Int, rate: Double, interlaced: Bool)] = [
            (1920, 1080, 25, true), (1920, 1080, 30000.0 / 1001, true),
            (1920, 1080, 24000.0 / 1001, false), (1920, 1080, 24, false),
            (1280, 720, 50, false), (1280, 720, 60000.0 / 1001, false),
            (1280, 720, 24000.0 / 1001, false), (1280, 720, 24, false)
        ]
        let rateText = frameRate.map { String(format: "%.3f", $0) } ?? "unsignalled"
        let found = "\(width)x\(height) at \(rateText) frames/s \(interlaced ? "interlaced" : "progressive")"
        guard let frameRate, admitted.contains(where: {
            $0.width == width && $0.height == height && abs($0.rate - frameRate) < 0.01 && $0.interlaced == interlaced
        }) else {
            return [.init(detail: "Blu-ray format \(found), expected 1920x1080 at 25 or 29.97 interlaced or 23.976 or "
                          + "24 progressive, or 1280x720 at 50, 59.94, 23.976 or 24 progressive")]
        }
        return []
    }

    private static func levelName(_ idc: Int, scale: Int) -> String {
        idc % scale == 0 ? "\(idc / scale)" : String(format: "%.1f", Double(idc) / Double(scale))
    }
}
