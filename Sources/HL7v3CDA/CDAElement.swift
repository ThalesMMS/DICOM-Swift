import Foundation

/// Typed views share one lossless tree. Mutating an accessor updates that tree in CDA sequence order.
public protocol CDAElement: Equatable, Sendable {
    static var elementName: String { get }
    static var childOrder: [String] { get }
    var node: XMLNode { get set }
    init(node: XMLNode)
}

extension CDAElement {
    public init() { self.init(node: XMLNode(Self.elementName)) }
    public var classCode: String? {
        get { node[attribute: "classCode"] }
        set { node[attribute: "classCode"] = newValue }
    }
    public var moodCode: String? {
        get { node[attribute: "moodCode"] }
        set { node[attribute: "moodCode"] = newValue }
    }
    public var typeCode: String? {
        get { node[attribute: "typeCode"] }
        set { node[attribute: "typeCode"] = newValue }
    }
    public var templateIds: [II] {
        get { values("templateId") }
        set { setValues("templateId", newValue) }
    }
    public var ids: [II] {
        get { values("id") }
        set { setValues("id", newValue) }
    }
    public var code: CD? {
        get { value("code") }
        set { setValue("code", newValue) }
    }
    public var text: ED? {
        get { value("text") }
        set { setValue("text", newValue) }
    }
    public var statusCode: CS? {
        get { value("statusCode") }
        set { setValue("statusCode", newValue) }
    }
    public var effectiveTime: IVL_TS? {
        get { value("effectiveTime") }
        set { setValue("effectiveTime", newValue) }
    }
    public var authors: [Author] {
        get { elements("author") }
        set { setElements("author", newValue) }
    }
    public var participants: [Participant] {
        get { elements("participant") }
        set { setElements("participant", newValue) }
    }
    public var performers: [Performer] {
        get { elements("performer") }
        set { setElements("performer", newValue) }
    }
    public var entryRelationships: [EntryRelationship] {
        get { elements("entryRelationship") }
        set { setElements("entryRelationship", newValue) }
    }
    public var references: [Reference] {
        get { elements("reference") }
        set { setElements("reference", newValue) }
    }
    public var referenceRanges: [ReferenceRange] {
        get { elements("referenceRange") }
        set { setElements("referenceRange", newValue) }
    }
    public var values: [CDAAnyValue] {
        get { node.elements("value").map(CDAAnyValue.init(node:)) }
        set { node.replace("value", with: newValue.map(\.node), order: Self.childOrder) }
    }
    public var unknownChildren: [XMLNode] {
        get { node.children.filter { $0.name.namespaceURI != CDANamespace.hl7 || !Self.childOrder.contains($0.name.localName) } }
        set {
            node.content.removeAll {
                if case .element(let child) = $0 {
                    return child.name.namespaceURI != CDANamespace.hl7 || !Self.childOrder.contains(child.name.localName)
                }
                return false
            }
            node.content += newValue.map(XMLContent.element)
        }
    }
    func value<T: HL7DataType>(_ name: String) -> T? { node.first(name).flatMap { try? T(node: $0) } }
    func values<T: HL7DataType>(_ name: String) -> [T] { node.elements(name).compactMap { try? T(node: $0) } }
    mutating func setValue<T: HL7DataType>(_ name: String, _ value: T?) { setValues(name, value.map { [$0] } ?? []) }
    mutating func setValues<T: HL7DataType>(_ name: String, _ values: [T]) {
        node.replace(name, with: values.map { $0.xml(named: name) }, order: Self.childOrder)
    }
    func elements<T: CDAElement>(_ name: String) -> [T] { node.elements(name).map(T.init(node:)) }
    func element<T: CDAElement>(_ name: String) -> T? { node.first(name).map(T.init(node:)) }
    mutating func setElements<T: CDAElement>(_ name: String, _ values: [T]) {
        node.replace(name, with: values.map { value in
            var node = value.node
            node.name.localName = name
            return node
        }, order: Self.childOrder)
    }
    mutating func setElement<T: CDAElement>(_ name: String, _ value: T?) { setElements(name, value.map { [$0] } ?? []) }
}
