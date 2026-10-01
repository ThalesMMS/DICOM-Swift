import Foundation

/// Any FHIR resource as a lossless JSON object; typed views are obtained with `as(_:)`.
public struct FHIRResource: FHIRElementView {
    public static let typeName = "Resource"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }

    public init(resourceType: String, id: String? = nil) {
        json = FHIRJSONObject()
        json["resourceType"] = .string(resourceType)
        if let id { json["id"] = .string(id) }
    }

    /// Parses JSON bytes and checks that the object is a resource.
    public init(jsonData: Data, limits: FHIRLimits = FHIRLimits()) throws {
        let object = try FHIRJSONParser(limits: limits).parseObject(jsonData)
        guard object["resourceType"]?.string != nil else { throw FHIRJSONError.notAResource }
        json = object
        try Self.checkBundleLimit(object, limits: limits)
    }

    /// Parses FHIR XML bytes through the safe XML converter.
    public init(xmlData: Data, limits: FHIRLimits = FHIRLimits(), schema: FHIRSchema = .r4) throws {
        json = try FHIRXMLConverter(limits: limits, schema: schema).resource(fromXML: xmlData)
        try Self.checkBundleLimit(json, limits: limits)
    }

    static func checkBundleLimit(_ object: FHIRJSONObject, limits: FHIRLimits) throws {
        guard object["resourceType"]?.string == "Bundle" else { return }
        if (object["entry"]?.array?.count ?? 0) > limits.maxBundleEntries { throw FHIRJSONError.bundleEntryLimit }
    }

    public var resourceType: String { string("resourceType") ?? "" }
    public var id: String? { get { string("id") } set { set("id", string: newValue) } }
    public var meta: FHIRMeta? { get { view("meta") } set { set("meta", view: newValue) } }
    public var implicitRules: String? { string("implicitRules") }
    public var language: String? { string("language") }
    public var text: FHIRNarrative? { get { view("text") } set { set("text", view: newValue) } }
    public var contained: [FHIRResource] { get { views("contained") } set { set("contained", views: newValue) } }

    public func containedResource(id: String) -> FHIRResource? { contained.first { $0.id == id } }

    /// Typed view when the resource type matches; nil otherwise.
    public func `as`<T: FHIRResourceView>(_ type: T.Type = T.self) -> T? {
        resourceType == T.resourceType ? T(json: json) : nil
    }

    public func jsonData(pretty: Bool = false) -> Data { FHIRJSONWriter(pretty: pretty).write(json) }
    public func xmlData(indentation: Int? = nil, schema: FHIRSchema = .r4) throws -> Data {
        try FHIRXMLConverter(schema: schema).xml(from: json, indentation: indentation)
    }

    /// `Type/id` when both are present.
    public var relativeReference: String? { id.map { resourceType + "/" + $0 } }

    /// Canonical key order for stable output: resourceType, id, meta, then the element-table order.
    public mutating func normalizeKeyOrder(schema: FHIRSchema = .r4) {
        let order = ["resourceType", "id", "meta", "implicitRules", "language", "text", "contained", "extension", "modifierExtension"]
            + (schema.type(resourceType)?.elements.map(\.name) ?? [])
        var expanded: [String] = []
        for key in order {
            expanded.append(key)
            expanded.append("_" + key)
        }
        json.moveToFront(expanded)
    }
}

/// A typed view of one resource type.
public protocol FHIRResourceView: FHIRElementView {
    static var resourceType: String { get }
}

public extension FHIRResourceView {
    static var typeName: String { resourceType }
    var resource: FHIRResource { FHIRResource(json: json) }
    var id: String? { get { string("id") } set { set("id", string: newValue) } }
    var meta: FHIRMeta? { get { view("meta") } set { set("meta", view: newValue) } }
    var text: FHIRNarrative? { get { view("text") } set { set("text", view: newValue) } }
    var contained: [FHIRResource] { get { views("contained") } set { set("contained", views: newValue) } }
    var identifiers: [FHIRIdentifier] { get { views("identifier") } set { set("identifier", views: newValue) } }

    init(id: String? = nil) {
        var object = FHIRJSONObject()
        object["resourceType"] = .string(Self.resourceType)
        if let id { object["id"] = .string(id) }
        self.init(json: object)
    }

    init?(resource: FHIRResource) {
        guard resource.resourceType == Self.resourceType else { return nil }
        self.init(json: resource.json)
    }
}

// MARK: - Bundle

public struct FHIRBundle: FHIRResourceView {
    public static let resourceType = "Bundle"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }

    public init(type: String, entries: [FHIRBundleEntry] = []) {
        self.init()
        set("type", string: type)
        set("entry", views: entries)
    }

    public var type: String? { get { string("type") } set { set("type", string: newValue) } }
    public var timestamp: FHIRDateTime? { dateTime("timestamp") }
    public var total: Int? { get { int("total") } set { set("total", int: newValue) } }
    public var links: [FHIRBundleLink] { get { views("link") } set { set("link", views: newValue) } }
    public var entries: [FHIRBundleEntry] { get { views("entry") } set { set("entry", views: newValue) } }

    public func link(relation: String) -> String? { links.first { $0.relation == relation }?.url }
    public var nextLink: String? { link(relation: "next") }
    public var resources: [FHIRResource] { entries.compactMap(\.resource) }
    public func resources<T: FHIRResourceView>(of type: T.Type) -> [T] { resources.compactMap { $0.as(T.self) } }

    /// Resolves `fullUrl`, relative `Type/id` and `urn:uuid` references against entries.
    public func resolve(reference: String) -> FHIRResource? {
        for entry in entries {
            guard let resource = entry.resource else { continue }
            if entry.fullUrl == reference { return resource }
            if resource.relativeReference == reference { return resource }
            if let fullUrl = entry.fullUrl, fullUrl.hasSuffix("/" + reference) { return resource }
        }
        return nil
    }
}

public struct FHIRBundleLink: FHIRElementView {
    public static let typeName = "BundleLink"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(relation: String, url: String) {
        json = FHIRJSONObject()
        set("relation", string: relation); set("url", string: url)
    }
    public var relation: String? { string("relation") }
    public var url: String? { string("url") }
}

public struct FHIRBundleEntry: FHIRElementView {
    public static let typeName = "BundleEntry"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(fullUrl: String? = nil, resource: FHIRResource? = nil, request: FHIRBundleRequest? = nil) {
        json = FHIRJSONObject()
        set("fullUrl", string: fullUrl); set("resource", view: resource); set("request", view: request)
    }
    public var fullUrl: String? { get { string("fullUrl") } set { set("fullUrl", string: newValue) } }
    public var resource: FHIRResource? { get { view("resource") } set { set("resource", view: newValue) } }
    public var search: FHIRBundleSearch? { view("search") }
    public var request: FHIRBundleRequest? { get { view("request") } set { set("request", view: newValue) } }
    public var response: FHIRBundleResponse? { get { view("response") } set { set("response", view: newValue) } }
}

public struct FHIRBundleSearch: FHIRElementView {
    public static let typeName = "BundleEntrySearch"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var mode: String? { string("mode") }
    public var score: FHIRNumber? { number("score") }
}

public struct FHIRBundleRequest: FHIRElementView {
    public static let typeName = "BundleEntryRequest"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(method: String, url: String, ifMatch: String? = nil, ifNoneMatch: String? = nil, ifNoneExist: String? = nil) {
        json = FHIRJSONObject()
        set("method", string: method); set("url", string: url); set("ifNoneMatch", string: ifNoneMatch)
        set("ifMatch", string: ifMatch); set("ifNoneExist", string: ifNoneExist)
    }
    public var method: String? { string("method") }
    public var url: String? { string("url") }
    public var ifMatch: String? { string("ifMatch") }
    public var ifNoneMatch: String? { string("ifNoneMatch") }
    public var ifNoneExist: String? { string("ifNoneExist") }
}

public struct FHIRBundleResponse: FHIRElementView {
    public static let typeName = "BundleEntryResponse"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var status: String? { string("status") }
    public var location: String? { string("location") }
    public var etag: String? { string("etag") }
    public var lastModified: FHIRDateTime? { dateTime("lastModified") }
    public var outcome: FHIRResource? { view("outcome") }
    /// Numeric HTTP status parsed from `"201 Created"` style values.
    public var statusCode: Int? { status.flatMap { Int($0.split(separator: " ").first ?? "") } }
}

// MARK: - OperationOutcome and Parameters

public struct FHIROperationOutcome: FHIRResourceView {
    public static let resourceType = "OperationOutcome"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(issues: [FHIROperationOutcomeIssue]) {
        self.init()
        set("issue", views: issues)
    }
    public var issues: [FHIROperationOutcomeIssue] { get { views("issue") } set { set("issue", views: newValue) } }
    public var hasErrors: Bool { issues.contains { $0.severity == "error" || $0.severity == "fatal" } }
}

public struct FHIROperationOutcomeIssue: FHIRElementView {
    public static let typeName = "OperationOutcomeIssue"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public init(severity: String, code: String, diagnostics: String? = nil, expression: [String] = []) {
        json = FHIRJSONObject()
        set("severity", string: severity); set("code", string: code); set("diagnostics", string: diagnostics); set("expression", strings: expression)
    }
    public var severity: String? { string("severity") }
    public var code: String? { string("code") }
    public var details: FHIRCodeableConcept? { view("details") }
    public var diagnostics: String? { string("diagnostics") }
    public var expressions: [String] { strings("expression") }
}

public struct FHIRParameters: FHIRResourceView {
    public static let resourceType = "Parameters"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var parameters: [FHIRParameter] { get { views("parameter") } set { set("parameter", views: newValue) } }
    public func parameter(named name: String) -> FHIRParameter? { parameters.first { $0.name == name } }
    public mutating func add(name: String, valueSuffix: String, value: FHIRJSON) {
        var parameter = FHIRParameter()
        parameter.set("name", string: name)
        parameter.json["value" + valueSuffix] = value
        append("parameter", parameter)
    }
    public mutating func add(name: String, resource: FHIRResource) {
        var parameter = FHIRParameter()
        parameter.set("name", string: name)
        parameter.set("resource", view: resource)
        append("parameter", parameter)
    }
}

public struct FHIRParameter: FHIRElementView {
    public static let typeName = "ParametersParameter"
    public var json: FHIRJSONObject
    public init(json: FHIRJSONObject) { self.json = json }
    public var name: String? { string("name") }
    public var value: FHIRChoice? { choice("value") }
    public var resource: FHIRResource? { view("resource") }
    public var parts: [FHIRParameter] { views("part") }
}
