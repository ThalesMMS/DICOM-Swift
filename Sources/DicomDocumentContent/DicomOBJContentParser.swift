import Foundation

public enum DicomOBJContentParser {
    public static let maximumDocumentBytes = 16 * 1_024 * 1_024
    public static let maximumElements = 250_000

    public static func parse(_ data: Data) -> DicomDocumentContentResult<DicomOBJMesh> {
        let limitations = ["Polygon triangulation uses a fan; concave or self-intersecting polygons are not tessellated correctly.",
                           "No material or texture files are opened. Freeform surfaces and unsupported directives are not interpreted."]
        guard data.count <= maximumDocumentBytes, let text = String(data: data, encoding: .ascii) else {
            return .init(value: nil, diagnostics: [.init(code: "inputLimit", reason: "ASCII input within the byte budget required.")], limitations: limitations)
        }
        var mesh = DicomOBJMesh()
        var diagnostics: [DicomDocumentContentDiagnostic] = []
        var groups: [String] = []
        var material: String?
        var records = 0
        for (lineIndex, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let tokens = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard let op = tokens.first else { continue }
            records += 1
            guard records <= maximumElements else {
                diagnostics.append(.init(code: "elementLimit", reason: "OBJ record budget exceeded.", line: lineIndex + 1))
                return .init(value: nil, diagnostics: diagnostics, limitations: limitations)
            }
            let args = Array(tokens.dropFirst())
            func invalid(_ reason: String) { diagnostics.append(.init(code: "invalidRecord", reason: reason, line: lineIndex + 1)) }
            switch op {
            case "v", "vn", "vt":
                let values = args.compactMap(Float.init)
                let validCount = op == "vt" ? (1...3).contains(values.count) :
                    (op == "v" ? (3...4).contains(values.count) : values.count == 3)
                guard values.count == args.count, validCount, values.allSatisfy(\.isFinite) else { invalid("Invalid vector."); continue }
                if op == "v" {
                    let w = values.count == 4 ? values[3] : 1
                    guard w != 0 else { invalid("Zero homogeneous coordinate."); continue }
                    let v = SIMD3(values[0], values[1], values[2]) / w
                    guard v.x.isFinite, v.y.isFinite, v.z.isFinite else { invalid("Coordinate overflow."); continue }
                    mesh.vertices.append(v)
                } else if op == "vn" { mesh.normals.append(.init(values[0], values[1], values[2])) }
                else { mesh.textureCoordinates.append(.init(values[0], values.count > 1 ? values[1] : 0, values.count > 2 ? values[2] : 0)) }
            case "f":
                guard args.count >= 3, args.count - 2 <= maximumElements - mesh.triangles.count else {
                    invalid("Invalid polygon or triangle budget exceeded."); continue
                }
                func index(_ token: Substring, count: Int) -> Int? {
                    guard let value = Int(token), value != 0, value >= -count, value <= count else { return nil }
                    return value > 0 ? value - 1 : count + value
                }
                let corners: [DicomOBJMesh.Corner] = args.compactMap { token in
                    let parts = token.split(separator: "/", omittingEmptySubsequences: false)
                    guard (1...3).contains(parts.count), let vertex = index(parts[0], count: mesh.vertices.count) else { return nil }
                    let texture = parts.count > 1 && !parts[1].isEmpty ? index(parts[1], count: mesh.textureCoordinates.count) : nil
                    let normal = parts.count > 2 ? index(parts[2], count: mesh.normals.count) : nil
                    if parts.count > 1 && !parts[1].isEmpty && texture == nil { return nil }
                    if parts.count > 2 && normal == nil { return nil }
                    return .init(vertex: vertex, textureCoordinate: texture, normal: normal)
                }
                guard corners.count == args.count else { invalid("Face index absent or out of range."); continue }
                for i in 1..<(corners.count - 1) {
                    mesh.triangles.append(.init(corners: [corners[0], corners[i], corners[i + 1]], groups: groups, material: material))
                }
            case "g": groups = args
            case "o": mesh.objectNames.append(args.joined(separator: " "))
            case "usemtl": material = args.joined(separator: " ")
            case "mtllib": mesh.materialLibraries += args
            default: break
            }
        }
        if mesh.vertices.isEmpty { diagnostics.append(.init(code: "emptyGeometry", reason: "No OBJ vertices.")) }
        return .init(value: diagnostics.isEmpty ? mesh : nil, diagnostics: diagnostics, limitations: limitations)
    }
}
