import Foundation

public struct FHIRMeta: FHIRElementView {
    public static let typeName = "Meta"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var versionId: String? { get { string("versionId") } set { set("versionId", string: newValue) } }
    public var lastUpdated: FHIRDateTime? { dateTime("lastUpdated") }
    public var source: String? { string("source") }
    public var profiles: [String] { get { strings("profile") } set { set("profile", strings: newValue) } }
    public var security: [FHIRCoding] { views("security") }
    public var tags: [FHIRCoding] { views("tag") }
}

public struct FHIRNarrative: FHIRElementView {
    public static let typeName = "Narrative"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(status: String, div: String) {
        json = FHIRJSONObject()
        json["status"] = .string(status)
        json["div"] = .string(div)
    }
    public var status: String? { string("status") }
    public var div: String? { string("div") }
}

public struct FHIRCoding: FHIRElementView {
    public static let typeName = "Coding"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(system: String? = nil, code: String? = nil, display: String? = nil, version: String? = nil) {
        json = FHIRJSONObject()
        set("system", string: system); set("version", string: version); set("code", string: code); set("display", string: display)
    }
    public var system: String? { get { string("system") } set { set("system", string: newValue) } }
    public var version: String? { string("version") }
    public var code: String? { get { string("code") } set { set("code", string: newValue) } }
    public var display: String? { get { string("display") } set { set("display", string: newValue) } }
    public var userSelected: Bool? { bool("userSelected") }
}

public struct FHIRCodeableConcept: FHIRElementView {
    public static let typeName = "CodeableConcept"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(codings: [FHIRCoding] = [], text: String? = nil) {
        json = FHIRJSONObject()
        set("coding", views: codings); set("text", string: text)
    }
    public var codings: [FHIRCoding] { get { views("coding") } set { set("coding", views: newValue) } }
    public var text: String? { get { string("text") } set { set("text", string: newValue) } }
    public func coding(system: String) -> FHIRCoding? { codings.first { $0.system == system } }
}

public struct FHIRIdentifier: FHIRElementView {
    public static let typeName = "Identifier"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(system: String? = nil, value: String? = nil, use: String? = nil) {
        json = FHIRJSONObject()
        set("use", string: use); set("system", string: system); set("value", string: value)
    }
    public var use: String? { string("use") }
    public var type: FHIRCodeableConcept? { view("type") }
    public var system: String? { get { string("system") } set { set("system", string: newValue) } }
    public var value: String? { get { string("value") } set { set("value", string: newValue) } }
    public var period: FHIRPeriod? { view("period") }
    public var assigner: FHIRReference? { view("assigner") }
}

public struct FHIRPeriod: FHIRElementView {
    public static let typeName = "Period"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(start: String? = nil, end: String? = nil) {
        json = FHIRJSONObject()
        set("start", string: start); set("end", string: end)
    }
    public var start: FHIRDateTime? { dateTime("start") }
    public var end: FHIRDateTime? { dateTime("end") }
}

public struct FHIRRange: FHIRElementView {
    public static let typeName = "Range"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var low: FHIRQuantity? { view("low") }
    public var high: FHIRQuantity? { view("high") }
}

public struct FHIRQuantity: FHIRElementView {
    public static let typeName = "Quantity"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(value: FHIRNumber, unit: String? = nil, system: String? = nil, code: String? = nil, comparator: String? = nil) {
        json = FHIRJSONObject()
        json["value"] = .number(value)
        set("comparator", string: comparator); set("unit", string: unit); set("system", string: system); set("code", string: code)
    }
    public var value: FHIRNumber? { get { number("value") } set { set("value", number: newValue) } }
    public var comparator: String? { string("comparator") }
    public var unit: String? { get { string("unit") } set { set("unit", string: newValue) } }
    public var system: String? { string("system") }
    public var code: String? { string("code") }
}

public struct FHIRHumanName: FHIRElementView {
    public static let typeName = "HumanName"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(family: String? = nil, given: [String] = [], use: String? = nil, text: String? = nil) {
        json = FHIRJSONObject()
        set("use", string: use); set("text", string: text); set("family", string: family); set("given", strings: given)
    }
    public var use: String? { string("use") }
    public var text: String? { string("text") }
    public var family: String? { get { string("family") } set { set("family", string: newValue) } }
    public var given: [String] { get { strings("given") } set { set("given", strings: newValue) } }
    public var prefix: [String] { strings("prefix") }
    public var suffix: [String] { strings("suffix") }
    public var period: FHIRPeriod? { view("period") }
}

public struct FHIRAddress: FHIRElementView {
    public static let typeName = "Address"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var use: String? { string("use") }
    public var type: String? { string("type") }
    public var text: String? { string("text") }
    public var lines: [String] { strings("line") }
    public var city: String? { string("city") }
    public var district: String? { string("district") }
    public var state: String? { string("state") }
    public var postalCode: String? { string("postalCode") }
    public var country: String? { string("country") }
}

public struct FHIRContactPoint: FHIRElementView {
    public static let typeName = "ContactPoint"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var system: String? { string("system") }
    public var value: String? { string("value") }
    public var use: String? { string("use") }
    public var rank: Int? { int("rank") }
}

public struct FHIRReference: FHIRElementView {
    public static let typeName = "Reference"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(reference: String? = nil, type: String? = nil, display: String? = nil, identifier: FHIRIdentifier? = nil) {
        json = FHIRJSONObject()
        set("reference", string: reference); set("type", string: type); set("identifier", view: identifier); set("display", string: display)
    }
    public var reference: String? { get { string("reference") } set { set("reference", string: newValue) } }
    public var type: String? { string("type") }
    public var identifier: FHIRIdentifier? { view("identifier") }
    public var display: String? { string("display") }

    /// Splits `[base/]Type/id[/_history/vid]`, `#contained` and `urn:` forms.
    public var parsed: FHIRReferenceTarget? { reference.flatMap(FHIRReferenceTarget.init) }
}

public struct FHIRReferenceTarget: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case relative, absolute(base: String), contained, urn }
    public let kind: Kind
    public let resourceType: String?
    public let id: String
    public let versionId: String?

    public init?(_ text: String) {
        if text.hasPrefix("#") {
            guard text.count > 1 else { return nil }
            kind = .contained; resourceType = nil; id = String(text.dropFirst()); versionId = nil
            return
        }
        if text.hasPrefix("urn:") { kind = .urn; resourceType = nil; id = text; versionId = nil; return }
        var parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var version: String? = nil
        if parts.count >= 4, parts[parts.count - 2] == "_history" {
            version = parts.removeLast(); parts.removeLast()
        }
        guard parts.count >= 2, let type = parts.dropLast().last, let identifier = parts.last, !identifier.isEmpty,
              type.first?.isUppercase == true else { return nil }
        let base = parts.dropLast(2).joined(separator: "/")
        kind = base.isEmpty ? .relative : .absolute(base: base)
        resourceType = type
        id = identifier
        versionId = version
    }
}

public struct FHIRAnnotation: FHIRElementView {
    public static let typeName = "Annotation"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var text: String? { string("text") }
    public var time: FHIRDateTime? { dateTime("time") }
    public var author: FHIRChoice? { choice("author") }
}

public struct FHIRAttachment: FHIRElementView {
    public static let typeName = "Attachment"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(contentType: String? = nil, url: String? = nil, data: Data? = nil, title: String? = nil, size: Int? = nil) {
        json = FHIRJSONObject()
        set("contentType", string: contentType); set("data", string: data?.base64EncodedString()); set("url", string: url)
        set("size", int: size); set("title", string: title)
    }
    public var contentType: String? { string("contentType") }
    public var language: String? { string("language") }
    public var data: Data? { string("data").flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } }
    public var url: String? { string("url") }
    public var size: Int? { int("size") }
    public var hash: Data? { string("hash").flatMap { Data(base64Encoded: $0) } }
    public var title: String? { string("title") }
    public var creation: FHIRDateTime? { dateTime("creation") }
}

public struct FHIRSignature: FHIRElementView {
    public static let typeName = "Signature"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var types: [FHIRCoding] { views("type") }
    public var when: FHIRDateTime? { dateTime("when") }
    public var who: FHIRReference? { view("who") }
    public var sigFormat: String? { string("sigFormat") }
    public var data: Data? { string("data").flatMap { Data(base64Encoded: $0) } }
}
