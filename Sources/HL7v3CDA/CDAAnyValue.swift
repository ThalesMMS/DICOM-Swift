import Foundation

public enum CDAAnyValue: Equatable, Sendable {
    case cd(CD)
    case ce(CE)
    case cs(CS)
    case cv(CV)
    case pq(PQ)
    case st(ST)
    case ed(ED)
    case int(INT)
    case real(REAL)
    case bl(BL)
    case ts(TS)
    case ivl_ts(IVL_TS)
    case ivl_pq(IVL_PQ)
    case pivl_ts(PIVL_TS)
    case ii(II)
    case tel(TEL)
    case ad(AD)
    case en(EN)
    case pn(PN)
    case on(ON)
    case unknown(XMLNode)

    public init(node: XMLNode) {
        guard let qualifiedType = node.schemaTypeName, qualifiedType.namespaceURI == CDANamespace.hl7 else {
            self = .unknown(node)
            return
        }
        let type = qualifiedType.localName
        switch type {
        case "CD": if let value = try? CD(node: node) { self = .cd(value) } else { self = .unknown(node) }
        case "CE": if let value = try? CE(node: node) { self = .ce(value) } else { self = .unknown(node) }
        case "CS": if let value = try? CS(node: node) { self = .cs(value) } else { self = .unknown(node) }
        case "CV": if let value = try? CV(node: node) { self = .cv(value) } else { self = .unknown(node) }
        case "PQ": if let value = try? PQ(node: node) { self = .pq(value) } else { self = .unknown(node) }
        case "ST": if let value = try? ST(node: node) { self = .st(value) } else { self = .unknown(node) }
        case "ED": if let value = try? ED(node: node) { self = .ed(value) } else { self = .unknown(node) }
        case "INT": if let value = try? INT(node: node) { self = .int(value) } else { self = .unknown(node) }
        case "REAL": if let value = try? REAL(node: node) { self = .real(value) } else { self = .unknown(node) }
        case "BL": if let value = try? BL(node: node) { self = .bl(value) } else { self = .unknown(node) }
        case "TS": if let value = try? TS(node: node) { self = .ts(value) } else { self = .unknown(node) }
        case "IVL_TS": if let value = try? IVL_TS(node: node) { self = .ivl_ts(value) } else { self = .unknown(node) }
        case "IVL_PQ": if let value = try? IVL_PQ(node: node) { self = .ivl_pq(value) } else { self = .unknown(node) }
        case "PIVL_TS": if let value = try? PIVL_TS(node: node) { self = .pivl_ts(value) } else { self = .unknown(node) }
        case "II": if let value = try? II(node: node) { self = .ii(value) } else { self = .unknown(node) }
        case "TEL": if let value = try? TEL(node: node) { self = .tel(value) } else { self = .unknown(node) }
        case "AD": if let value = try? AD(node: node) { self = .ad(value) } else { self = .unknown(node) }
        case "EN": if let value = try? EN(node: node) { self = .en(value) } else { self = .unknown(node) }
        case "PN": if let value = try? PN(node: node) { self = .pn(value) } else { self = .unknown(node) }
        case "ON": if let value = try? ON(node: node) { self = .on(value) } else { self = .unknown(node) }
        default: self = .unknown(node)
        }
    }

    public var node: XMLNode {
        switch self {
        case .cd(let value): return Self.typedNode(value)
        case .ce(let value): return Self.typedNode(value)
        case .cs(let value): return Self.typedNode(value)
        case .cv(let value): return Self.typedNode(value)
        case .pq(let value): return Self.typedNode(value)
        case .st(let value): return Self.typedNode(value)
        case .ed(let value): return Self.typedNode(value)
        case .int(let value): return Self.typedNode(value)
        case .real(let value): return Self.typedNode(value)
        case .bl(let value): return Self.typedNode(value)
        case .ts(let value): return Self.typedNode(value)
        case .ivl_ts(let value): return Self.typedNode(value)
        case .ivl_pq(let value): return Self.typedNode(value)
        case .pivl_ts(let value): return Self.typedNode(value)
        case .ii(let value): return Self.typedNode(value)
        case .tel(let value): return Self.typedNode(value)
        case .ad(let value): return Self.typedNode(value)
        case .en(let value): return Self.typedNode(value)
        case .pn(let value): return Self.typedNode(value)
        case .on(let value): return Self.typedNode(value)
        case .unknown(let node): return node
        }
    }

    private static func typedNode<T: HL7DataType>(_ value: T) -> XMLNode {
        if value.node.attributes.keys.contains(where: { $0.namespaceURI == CDANamespace.xsi && $0.localName == "type" }) {
            return value.node
        }
        return value.xml(named: "value", anyTyped: true)
    }
}
