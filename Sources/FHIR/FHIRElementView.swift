import Foundation

/// A typed view over a JSON object of the lossless tree. Views never copy or drop unknown keys.
public protocol FHIRElementView: Sendable, Equatable {
    static var typeName: String { get }
    var json: FHIRJSONObject { get set }
    init(json: FHIRJSONObject)
}

public extension FHIRElementView {
    init() { self.init(json: FHIRJSONObject()) }

    var elementID: String? {
        get { json["id"]?.string }
        set { json["id"] = newValue.map(FHIRJSON.string) }
    }

    var extensions: [FHIRExtension] {
        get { views("extension") }
        set { set("extension", views: newValue) }
    }

    var modifierExtensions: [FHIRExtension] {
        get { views("modifierExtension") }
        set { set("modifierExtension", views: newValue) }
    }

    func extensions(url: String) -> [FHIRExtension] { extensions.filter { $0.url == url } }

    // MARK: primitives

    func string(_ key: String) -> String? { json[key]?.string }
    func bool(_ key: String) -> Bool? { json[key]?.bool }
    func int(_ key: String) -> Int? { json[key]?.number?.intValue }
    func number(_ key: String) -> FHIRNumber? { json[key]?.number }
    func decimal(_ key: String) -> Decimal? { json[key]?.number?.decimalValue }
    func strings(_ key: String) -> [String] { json[key]?.array?.compactMap(\.string) ?? [] }
    func date(_ key: String) -> FHIRDate? { string(key).flatMap(FHIRDate.init) }
    func dateTime(_ key: String) -> FHIRDateTime? { string(key).flatMap(FHIRDateTime.init) }

    mutating func set(_ key: String, string value: String?) { json[key] = value.map(FHIRJSON.string) }
    mutating func set(_ key: String, bool value: Bool?) { json[key] = value.map(FHIRJSON.bool) }
    mutating func set(_ key: String, int value: Int?) { json[key] = value.map { .number(FHIRNumber($0)) } }
    mutating func set(_ key: String, number value: FHIRNumber?) { json[key] = value.map(FHIRJSON.number) }
    mutating func set(_ key: String, strings value: [String]) { json[key] = value.isEmpty ? nil : .array(value.map(FHIRJSON.string)) }

    /// The `_name` companion carrying id/extensions of a primitive.
    func primitiveExtension(_ key: String) -> FHIRJSONObject? { json["_" + key]?.object }
    mutating func setPrimitiveExtension(_ key: String, _ value: FHIRJSONObject?) { json["_" + key] = value.map(FHIRJSON.object) }

    // MARK: complex

    func object(_ key: String) -> FHIRJSONObject? { json[key]?.object }
    func objects(_ key: String) -> [FHIRJSONObject] { json[key]?.array?.compactMap(\.object) ?? [] }
    func view<T: FHIRElementView>(_ key: String) -> T? { object(key).map(T.init(json:)) }
    func views<T: FHIRElementView>(_ key: String) -> [T] { objects(key).map(T.init(json:)) }
    mutating func set<T: FHIRElementView>(_ key: String, view value: T?) { json[key] = value.map { .object($0.json) } }
    mutating func set<T: FHIRElementView>(_ key: String, views value: [T]) {
        json[key] = value.isEmpty ? nil : .array(value.map { .object($0.json) })
    }
    mutating func append<T: FHIRElementView>(_ key: String, _ value: T) {
        var items = json[key]?.array ?? []
        items.append(.object(value.json))
        json[key] = .array(items)
    }

    // MARK: choice types

    /// Resolves a `[x]` choice by JSON key prefix: `choice("value")` finds `valueQuantity` etc.
    func choice(_ group: String) -> FHIRChoice? {
        for key in json.keys where key.hasPrefix(group) && key.count > group.count && !key.hasPrefix("_") {
            let suffix = String(key.dropFirst(group.count))
            guard suffix.first?.isUppercase == true, let value = json[key] else { continue }
            return FHIRChoice(group: group, typeSuffix: suffix, key: key, value: value)
        }
        return nil
    }

    mutating func setChoice(_ group: String, typeSuffix: String, value: FHIRJSON?) {
        for key in json.keys where key.hasPrefix(group) && key.count > group.count && key.dropFirst(group.count).first?.isUppercase == true {
            json.removeValue(forKey: key)
            json.removeValue(forKey: "_" + key)
        }
        json[group + typeSuffix] = value
    }
}

public struct FHIRChoice: Equatable, Sendable {
    public let group: String
    /// Capitalized type suffix, e.g. `Quantity`, `String`, `DateTime`.
    public let typeSuffix: String
    public let key: String
    public let value: FHIRJSON

    public var typeName: String {
        let lower = typeSuffix.prefix(1).lowercased() + typeSuffix.dropFirst()
        return FHIRPrimitiveType(rawValue: lower) != nil ? lower : typeSuffix
    }
    public var string: String? { value.string }
    public var number: FHIRNumber? { value.number }
    public var bool: Bool? { value.bool }
    public func view<T: FHIRElementView>() -> T? { value.object.map(T.init(json:)) }
}

public struct FHIRExtension: FHIRElementView {
    public static let typeName = "Extension"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }

    public init(url: String, valueSuffix: String? = nil, value: FHIRJSON? = nil) {
        json = FHIRJSONObject()
        json["url"] = .string(url)
        if let valueSuffix, let value { json["value" + valueSuffix] = value }
    }

    public var url: String { string("url") ?? "" }
    public var value: FHIRChoice? { choice("value") }
    /// Complex extensions carry nested extensions instead of a value.
    public var isComplex: Bool { value == nil && !extensions.isEmpty }
}
