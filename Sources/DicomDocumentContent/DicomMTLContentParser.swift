import Foundation

public enum DicomMTLContentParser {
    public static let maximumDocumentBytes = 16 * 1_024 * 1_024
    public static let maximumMaterials = 4096
    public static let maximumRecords = 250_000

    public static func parse(_ data: Data) -> DicomDocumentContentResult<[DicomMTLMaterial]> {
        let limitations = ["RGB Ka/Kd/Ks and d/Tr only; illumination models are not evaluated.",
                           "Map names are retained without loading resources; map options and spectral/XYZ colors are unsupported."]
        guard data.count <= maximumDocumentBytes, let text = String(data: data, encoding: .ascii) else {
            return .init(value: nil, diagnostics: [.init(code: "inputLimit", reason: "ASCII input within byte budget required.")], limitations: limitations)
        }
        var materials: [DicomMTLMaterial] = []
        var diagnostics: [DicomDocumentContentDiagnostic] = []
        var records = 0
        for (lineNumber, line) in text.split(whereSeparator: \.isNewline).enumerated() {
            let tokens = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard let op = tokens.first else { continue }
            records += 1
            guard records <= maximumRecords else {
                return .init(value: nil, diagnostics: [.init(code: "recordLimit", reason: "MTL record budget exceeded.")], limitations: limitations)
            }
            let args = Array(tokens.dropFirst())
            func invalid(_ reason: String) { diagnostics.append(.init(code: "invalidRecord", reason: reason, line: lineNumber + 1)) }
            if op == "newmtl" {
                guard !args.isEmpty, materials.count < maximumMaterials else {
                    return .init(value: nil, diagnostics: [.init(code: "materialLimit", reason: "Missing name or material budget exceeded.")], limitations: limitations)
                }
                materials.append(.init(name: args.joined(separator: " ")))
                continue
            }
            guard ["Ka", "Kd", "Ks", "d", "Tr"].contains(op) || op.hasPrefix("map_") else { continue }
            guard !materials.isEmpty else { invalid("Material property before newmtl."); continue }
            let i = materials.count - 1
            if op.hasPrefix("map_") {
                guard !args.isEmpty, args.first?.hasPrefix("-") != true else { invalid("Missing map name or unsupported map options."); continue }
                materials[i].maps[op] = args.joined(separator: " ")
            } else {
                let values = args.compactMap(Float.init)
                guard values.count == args.count, values.allSatisfy(\.isFinite) else { invalid("Invalid numeric property."); continue }
                if op == "d" || op == "Tr" {
                    guard values.count == 1, (0...1).contains(values[0]) else { invalid("Opacity outside 0...1."); continue }
                    materials[i].opacity = op == "Tr" ? 1 - values[0] : values[0]
                } else {
                    guard values.count == 3 else { invalid("Expected RGB triplet."); continue }
                    let color = SIMD3(values[0], values[1], values[2])
                    switch op {
                    case "Ka": materials[i].ambient = color
                    case "Kd": materials[i].diffuse = color
                    default: materials[i].specular = color
                    }
                }
            }
        }
        if materials.isEmpty { diagnostics.append(.init(code: "emptyMaterials", reason: "No newmtl records.")) }
        return .init(value: diagnostics.isEmpty ? materials : nil, diagnostics: diagnostics, limitations: limitations)
    }
}
