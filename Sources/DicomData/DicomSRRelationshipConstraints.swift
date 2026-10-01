import Foundation

/// PS3.3 2026c Tables A.35.1-2, A.35.2-2, A.35.3-2 and A.35.4-2. Template constraints are separate.
public enum DicomSRRelationshipConstraints: String, Sendable {
    case basicText = "1.2.840.10008.5.1.4.1.1.88.11"
    case enhanced = "1.2.840.10008.5.1.4.1.1.88.22"
    case comprehensive3D = "1.2.840.10008.5.1.4.1.1.88.34"
    case comprehensive = "1.2.840.10008.5.1.4.1.1.88.33"
    case keyObject = "1.2.840.10008.5.1.4.1.1.88.59"

    private static let scalar: Set<String> = ["TEXT", "CODE", "NUM", "DATETIME", "DATE", "TIME", "UIDREF", "PNAME"]
    private static let values = scalar.union(["CONTAINER", "IMAGE", "COMPOSITE", "WAVEFORM", "SCOORD", "TCOORD"])

    /// Basic Text SR value types other than CONTAINER and the references (Table A.35.1-2, issue #2823).
    private static let basicScalar: Set<String> = ["TEXT", "CODE", "DATETIME", "DATE", "TIME", "UIDREF", "PNAME"]
    private static let references: Set<String> = ["IMAGE", "WAVEFORM", "COMPOSITE"]

    public func permits(source: String, relationship: String, target: String, byReference: Bool) -> Bool {
        if self == .basicText { return Self.permitsBasicText(source: source, relationship: relationship, target: target,
                                                            byReference: byReference) }
        let values = self == .comprehensive3D ? Self.values.union(["SCOORD3D"]) : Self.values
        guard values.contains(source), values.contains(target) else { return false }
        if byReference && ((self != .comprehensive && self != .comprehensive3D) || ["CONTAINS", "HAS CONCEPT MOD"].contains(relationship)) { return false }
        if self == .keyObject {
            switch relationship {
            case "CONTAINS": return source == "CONTAINER" && ["TEXT", "IMAGE", "WAVEFORM", "COMPOSITE", "CONTAINER"].contains(target)
            case "HAS OBS CONTEXT": return source == "CONTAINER" && ["TEXT", "CODE", "UIDREF", "PNAME", "CONTAINER"].contains(target)
            case "HAS CONCEPT MOD": return source == "CONTAINER" && target == "CODE"
            case "HAS ACQ CONTEXT": return ["CONTAINER", "IMAGE", "COMPOSITE", "WAVEFORM"].contains(source) &&
                ["CODE", "DATE", "TIME", "DATETIME", "UIDREF", "NUM", "TEXT"].contains(target)
            default: return false
            }
        }
        switch relationship {
        case "CONTAINS": return source == "CONTAINER"
        case "HAS OBS CONTEXT":
            if source == "CONTAINER" && target == "CONTAINER" { return true }
            return (source == "CONTAINER" || ((self == .comprehensive || self == .comprehensive3D) && ["TEXT", "CODE", "NUM"].contains(source))) &&
                Self.scalar.union(["COMPOSITE"]).contains(target)
        case "HAS ACQ CONTEXT":
            return ["CONTAINER", "IMAGE", "WAVEFORM", "COMPOSITE", "NUM"].contains(source) &&
                (Self.scalar.contains(target) || ((self == .comprehensive || self == .comprehensive3D) && target == "CONTAINER"))
        case "HAS CONCEPT MOD": return ["TEXT", "CODE"].contains(target)
        case "HAS PROPERTIES", "INFERRED FROM":
            if relationship == "HAS PROPERTIES" && source == "PNAME" {
                return ["TEXT", "CODE", "DATETIME", "DATE", "TIME", "UIDREF", "PNAME"].contains(target)
            }
            return ["TEXT", "CODE", "NUM"].contains(source) && ((self == .comprehensive || self == .comprehensive3D) || target != "CONTAINER")
        case "SELECTED FROM":
            return (source == "SCOORD" && target == "IMAGE") ||
                (source == "TCOORD" && (["SCOORD", "IMAGE", "WAVEFORM"].contains(target) || (self == .comprehensive3D && target == "SCOORD3D")))
        default: return false
        }
    }

    /// Table A.35.1-2: no by-reference relationships, and no NUM or coordinate content.
    private static func permitsBasicText(source: String, relationship: String, target: String,
                                         byReference: Bool) -> Bool {
        guard !byReference else { return false }
        switch relationship {
        case "CONTAINS":
            return source == "CONTAINER" && basicScalar.union(references).union(["CONTAINER"]).contains(target)
        case "HAS OBS CONTEXT":
            return source == "CONTAINER" && basicScalar.union(["COMPOSITE", "CONTAINER"]).contains(target)
        case "HAS ACQ CONTEXT":
            return references.union(["CONTAINER"]).contains(source) && basicScalar.contains(target)
        case "HAS CONCEPT MOD":
            return ["TEXT", "CODE"].contains(target)
        case "HAS PROPERTIES":
            if source == "PNAME" { return basicScalar.contains(target) }
            return source == "TEXT" && basicScalar.union(references).contains(target)
        case "INFERRED FROM":
            return source == "TEXT" && basicScalar.union(references).contains(target)
        default:
            return false
        }
    }
}
