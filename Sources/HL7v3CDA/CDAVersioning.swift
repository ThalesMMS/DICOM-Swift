import Foundation

public enum CDAVersioningError: Error, Equatable, Sendable {
    case missingDocumentID
    case invalidVersionNumber
    case cyclicLineage
    case invalidDocument
}

public struct CDALineageNode: Codable, Equatable, Sendable {
    public let relationTypeCode: String?
    public let id: CDATemplateReference? // kept as a compact root/extension carrier
    public let documentIDRoot: String?
    public let documentIDExtension: String?
    public let setIDRoot: String?
    public let setIDExtension: String?
    public let versionNumber: Int?

    public init(relationTypeCode: String?, documentIDRoot: String?, documentIDExtension: String?,
                setIDRoot: String?, setIDExtension: String?, versionNumber: Int?) {
        self.relationTypeCode = relationTypeCode
        self.documentIDRoot = documentIDRoot
        self.documentIDExtension = documentIDExtension
        self.setIDRoot = setIDRoot
        self.setIDExtension = setIDExtension
        self.versionNumber = versionNumber
        self.id = documentIDRoot.map { CDATemplateReference(root: $0, extension: documentIDExtension) }
    }

    public var typeCode: String? { relationTypeCode }
    public var idRoot: String? { documentIDRoot }
    public var idExtension: String? { documentIDExtension }
    public var setIdRoot: String? { setIDRoot }
    public var setIdExtension: String? { setIDExtension }
    public var documentID: CDATemplateReference? { id }
    public var setID: CDATemplateReference? {
        setIDRoot.map { CDATemplateReference(root: $0, extension: setIDExtension) }
    }
    public var version: Int? { versionNumber }
    public var relation: String? { relationTypeCode }
}

public typealias CDAVersionLineageEntry = CDALineageNode

public enum CDADocumentVersioning {
    public static func newVersion(of document: ClinicalDocument,
                                  replacing parent: ClinicalDocument? = nil) throws -> ClinicalDocument {
        try makeVersion(of: document, relation: "RPLC", parent: parent ?? document)
    }

    public static func appendix(of document: ClinicalDocument) throws -> ClinicalDocument {
        try makeVersion(of: document, relation: "APND", parent: document)
    }

    public static func lineage(from document: ClinicalDocument) throws -> [CDALineageNode] {
        guard let currentID = document.id, let currentRoot = currentID.root else { throw CDAVersioningError.missingDocumentID }
        let currentVersion = Int(document.versionNumber?.value ?? "")
        var result = [CDALineageNode(relationTypeCode: nil, documentIDRoot: currentRoot,
                                     documentIDExtension: currentID.extension,
                                     setIDRoot: document.setId?.root, setIDExtension: document.setId?.extension,
                                     versionNumber: currentVersion)]
        var seen: Set<String> = [identity(root: currentRoot, extension: currentID.extension, version: currentVersion)]
        var seenDocumentIDs: Set<String> = [documentIdentity(root: currentRoot, extension: currentID.extension)]
        struct RelationInfo {
            let relation: String?
            let parent: XMLNode
            let root: String
            let extensionValue: String?
            let setID: XMLNode?
            let version: Int?
        }
        let relations: [RelationInfo] = document.node.descendants().compactMap { related in
            guard related.name.localName == "relatedDocument", let parent = related.first("parentDocument"),
                  let idNode = parent.first("id"), let root = idNode[attribute: "root"] else { return nil }
            return RelationInfo(relation: related[attribute: "typeCode"], parent: parent, root: root,
                                extensionValue: idNode[attribute: "extension"], setID: parent.first("setId"),
                                version: Int(parent.first("versionNumber")?[attribute: "value"] ?? ""))
        }
        let currentDocumentKey = documentIdentity(root: currentRoot, extension: currentID.extension)
        if relations.contains(where: {
            documentIdentity(root: $0.root, extension: $0.extensionValue) == currentDocumentKey
        }) {
            throw CDAVersioningError.cyclicLineage
        }
        var unused = Set(relations.indices)
        var expectedVersion = currentVersion.map { $0 - 1 }
        while !unused.isEmpty {
            let ordered = unused.sorted {
                let lhs = relations[$0].version ?? -1, rhs = relations[$1].version ?? -1
                return lhs == rhs ? $0 < $1 : lhs > rhs
            }
            let candidateIndex = expectedVersion.flatMap { version in
                ordered.first { relations[$0].version == version }
            } ?? ordered.first
            guard let index = candidateIndex else { break }
            unused.remove(index)
            let info = relations[index]
            let root = info.root
            let extensionValue = info.extensionValue
            let setID = info.setID
            let version = info.version
            let key = identity(root: root, extension: extensionValue, version: version)
            let documentKey = documentIdentity(root: root, extension: extensionValue)
            guard seen.insert(key).inserted, seenDocumentIDs.insert(documentKey).inserted else {
                throw CDAVersioningError.cyclicLineage
            }
            result.append(CDALineageNode(relationTypeCode: info.relation,
                                         documentIDRoot: root, documentIDExtension: extensionValue,
                                         setIDRoot: setID?[attribute: "root"], setIDExtension: setID?[attribute: "extension"],
                                         versionNumber: version))
            expectedVersion = version.map { $0 - 1 }
        }
        return result
    }

    private static func makeVersion(of document: ClinicalDocument, relation: String,
                                    parent: ClinicalDocument) throws -> ClinicalDocument {
        guard let currentID = document.id, let root = currentID.root else { throw CDAVersioningError.missingDocumentID }
        let oldVersion: Int
        if let versionText = parent.versionNumber?.value {
            guard let parsed = Int(versionText), parsed >= 0 else {
                throw CDAVersioningError.invalidVersionNumber
            }
            oldVersion = parsed
        } else {
            oldVersion = 0
        }
        guard let parentID = parent.id, let parentRoot = parentID.root else { throw CDAVersioningError.missingDocumentID }
        var result = document
        let nextVersion = oldVersion + 1
        let newExtension = "v\(nextVersion)-" + UUID().uuidString.lowercased()
        result.id = try II(root: root, extension: newExtension)
        result.setId = document.setId ?? (try? II(root: root))
        result.versionNumber = try INT(String(nextVersion))

        let parentDocument = XMLNode("parentDocument", children: [
            XMLNode("id", attributes: attributes(root: parentRoot, extension: parentID.extension)),
            XMLNode("setId", attributes: attributes(root: parent.setId?.root ?? parentRoot, extension: parent.setId?.extension)),
            XMLNode("versionNumber", attributes: ["value": parent.versionNumber?.value ?? String(oldVersion)])
        ])
        let related = RelatedDocument(node: XMLNode("relatedDocument", attributes: ["typeCode": relation], children: [parentDocument]))
        result.relatedDocuments = result.relatedDocuments + [related]
        guard !result.validateLinks().contains(where: { $0.kind == .cycle }) else { throw CDAVersioningError.cyclicLineage }
        return result
    }

    private static func attributes(root: String, extension extensionValue: String?) -> [String: String] {
        var result = ["root": root]
        if let extensionValue { result["extension"] = extensionValue }
        return result
    }

    private static func identity(root: String, extension extensionValue: String?, version: Int?) -> String {
        root + "#" + (extensionValue ?? "") + "@" + (version.map(String.init) ?? "?")
    }

    private static func documentIdentity(root: String, extension extensionValue: String?) -> String {
        root + "#" + (extensionValue ?? "")
    }
}
