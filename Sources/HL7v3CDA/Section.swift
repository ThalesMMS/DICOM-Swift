import Foundation

public struct Section: CDAElement {
    public static let elementName = "section"
    public static let childOrder = "realmCode typeId templateId id code title text confidentialityCode languageCode subject author informant entry component".split(separator: " ").map(String.init)
    public var node: XMLNode
    public init(node: XMLNode) { self.node = node }
}

extension Section {
    public var id: II? {
        get { value("id") }
        set { setValue("id", newValue) }
    }
    public var title: ST? {
        get { value("title") }
        set { setValue("title", newValue) }
    }
    public var entries: [Entry] {
        get { elements("entry") }
        set { setElements("entry", newValue) }
    }
}
