import Foundation

public struct HL7InspectionNode: Codable, Equatable, Sendable {
    public let path: String
    public let dataType: String?
    /// Length in Unicode scalars, excluding structural delimiters.
    public let length: Int
    public let state: String?
    public let value: String?
    public let children: [HL7InspectionNode]
}

public enum HL7Inspector {
    public static func tree(_ message: HL7Message, includeValues: Bool = false) -> HL7InspectionNode {
        let schema = message.version.flatMap { HL7SchemaRegistry.shared.schema(for: $0) }
        var occurrences: [String: Int] = [:]
        func node(_ path: String, _ type: String? = nil, children: [HL7InspectionNode]) -> HL7InspectionNode {
            .init(path: path, dataType: type, length: children.reduce(0) { $0 + $1.length },
                  state: nil, value: nil, children: children)
        }
        let segments = message.segments.map { segment in
            occurrences[segment.name, default: 0] += 1
            let path = segment.name + "[\(occurrences[segment.name]!)]"
            let fields = segment.fields.enumerated().map { f, field in
                let fieldPath = path + "-\(f + 1)"
                let definition = schema?.segments[segment.name]?[f + 1]
                let dynamicType = definition?.dataTypeField.flatMap { segment[$0][1][1][1].text }
                    .flatMap(HL7DataTypeName.init(rawValue:))
                let type = dynamicType?.rawValue ?? definition?.dataType.rawValue
                if !field.isPresent {
                    return HL7InspectionNode(path: fieldPath, dataType: type, length: 0,
                                             state: "absent", value: nil, children: [])
                }
                let repetitions = field.repetitions.enumerated().map { r, repetition in
                    let repPath = fieldPath + "[\(r + 1)]"
                    return node(repPath, type, children: repetition.components.enumerated().map { c, component in
                        let componentPath = repPath + ".\(c + 1)"
                        return node(componentPath, children: component.subcomponents.enumerated().map { s, value in
                            let state: String
                            switch value {
                            case .absent: state = "absent"
                            case .empty: state = "empty"
                            case .null: state = "null"
                            case .text: state = "text"
                            }
                            return HL7InspectionNode(path: componentPath + ".\(s + 1)", dataType: nil,
                                length: value.text?.unicodeScalars.count ?? 0, state: state,
                                value: includeValues ? value.text : nil, children: [])
                        })
                    })
                }
                return node(fieldPath, type, children: repetitions)
            }
            return node(path, children: fields)
        }
        return node("message", children: segments)
    }

    public static func describe(_ message: HL7Message, includeValues: Bool = false) -> String {
        func render(_ node: HL7InspectionNode, depth: Int) -> [String] {
            var line = String(repeating: "  ", count: depth) + node.path
            if let type = node.dataType { line += " type=" + type }
            line += " length=\(node.length)"
            if let state = node.state { line += " state=" + state }
            if let value = node.value { line += " value=" + String(reflecting: value) }
            return [line] + node.children.flatMap { render($0, depth: depth + 1) }
        }
        return render(tree(message, includeValues: includeValues), depth: 0).joined(separator: "\n")
    }
}
