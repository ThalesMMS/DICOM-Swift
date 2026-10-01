import Foundation

/// SMART App Launch scope (v1 `patient/Observation.read` and v2 `patient/Observation.rs` grammars,
/// launch, identity and refresh scopes). Parsing never throws: unknown strings are kept verbatim.
public struct SMARTScope: Hashable, Sendable, CustomStringConvertible {
    public enum Context: String, Sendable { case patient, user, system }
    public struct Permissions: Hashable, Sendable {
        public var create = false, read = false, update = false, delete = false, search = false
        public init(create: Bool = false, read: Bool = false, update: Bool = false, delete: Bool = false, search: Bool = false) {
            self.create = create; self.read = read; self.update = update; self.delete = delete; self.search = search
        }
        public static let readOnly = Permissions(read: true, search: true)
        public static let writeOnly = Permissions(create: true, update: true, delete: true)
        public static let all = Permissions(create: true, read: true, update: true, delete: true, search: true)
        /// v2 letters in canonical order.
        public var v2: String { (create ? "c" : "") + (read ? "r" : "") + (update ? "u" : "") + (delete ? "d" : "") + (search ? "s" : "") }
        public func covers(_ other: Permissions) -> Bool {
            (!other.create || create) && (!other.read || read) && (!other.update || update) && (!other.delete || delete) && (!other.search || search)
        }
    }

    public let raw: String
    public let context: Context?
    /// `*` for all resource types.
    public let resourceType: String?
    public let permissions: Permissions?

    public init(_ raw: String) {
        self.raw = raw
        let scope = raw.prefix(while: { $0 != "?" })
        guard let slash = scope.firstIndex(of: "/"), let dot = scope.lastIndex(of: "."), slash < dot,
              let context = Context(rawValue: String(raw[..<slash])) else {
            self.context = nil; resourceType = nil; permissions = nil
            return
        }
        let type = String(raw[raw.index(after: slash)..<dot])
        let access = String(raw[raw.index(after: dot)...]).split(separator: "?").first.map(String.init) ?? ""
        var permissions: Permissions
        switch access {
        case "read": permissions = .readOnly
        case "write": permissions = .writeOnly
        case "*": permissions = .all
        default:
            guard !access.isEmpty, access.allSatisfy({ "cruds".contains($0) }) else {
                self.context = nil; resourceType = nil; self.permissions = nil
                return
            }
            permissions = Permissions(create: access.contains("c"), read: access.contains("r"), update: access.contains("u"),
                                      delete: access.contains("d"), search: access.contains("s"))
        }
        self.context = context
        resourceType = type
        self.permissions = permissions
    }

    public var isResourceScope: Bool { context != nil }
    public var description: String { raw }

    public static let launch = SMARTScope("launch")
    public static let launchPatient = SMARTScope("launch/patient")
    public static let launchEncounter = SMARTScope("launch/encounter")
    public static let openid = SMARTScope("openid")
    public static let fhirUser = SMARTScope("fhirUser")
    public static let offlineAccess = SMARTScope("offline_access")
    public static let onlineAccess = SMARTScope("online_access")

    public static func patient(_ resourceType: String, _ permissions: Permissions = .readOnly) -> SMARTScope {
        SMARTScope("patient/" + resourceType + "." + permissions.v2)
    }
    public static func user(_ resourceType: String, _ permissions: Permissions = .readOnly) -> SMARTScope {
        SMARTScope("user/" + resourceType + "." + permissions.v2)
    }

    /// True when `granted` scopes satisfy this scope (wildcards and permission supersets count).
    public func isCovered(by granted: [SMARTScope]) -> Bool {
        if granted.contains(where: { $0.raw == raw }) { return true }
        guard let context, let resourceType, let permissions else { return false }
        return granted.contains { candidate in
            guard candidate.context == context, let type = candidate.resourceType, let candidatePermissions = candidate.permissions else { return false }
            return (type == "*" || type == resourceType) && candidatePermissions.covers(permissions)
        }
    }

    public static func parse(_ scopeString: String) -> [SMARTScope] {
        scopeString.split(whereSeparator: { $0 == " " }).map { SMARTScope(String($0)) }
    }

    public static func missing(requested: [SMARTScope], granted: [SMARTScope]) -> [SMARTScope] {
        requested.filter { !$0.isCovered(by: granted) }
    }
}
