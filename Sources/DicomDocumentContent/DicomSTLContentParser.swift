import Foundation
import DicomCore

public enum DicomSTLContentParser {
    public static let maximumDocumentBytes = 16 * 1_024 * 1_024
    public static let maximumFacetCount = 250_000

    private static func parseMesh(
        _ data: Data,
        millimetersPerUnit: Float
    ) throws -> DicomSTLMesh {
        guard !data.isEmpty else { throw DicomSTLContentError.malformedSTL }
        guard data.count <= maximumDocumentBytes else {
            throw DicomSTLContentError.documentTooLarge
        }
        guard millimetersPerUnit.isFinite, millimetersPerUnit > 0 else {
            throw DicomSTLContentError.unsupportedScale
        }

        if let facetCount = binaryFacetCount(in: data) {
            let expectedByteCount = 84 + facetCount * 50
            if expectedByteCount == data.count {
                guard facetCount <= maximumFacetCount else {
                    throw DicomSTLContentError.tooManyFacets
                }
                return try parseBinary(
                    data,
                    facetCount: facetCount,
                    millimetersPerUnit: millimetersPerUnit
                )
            }
            if looksLikeASCII(data) {
                return try parseASCII(data, millimetersPerUnit: millimetersPerUnit)
            }
            if facetCount > maximumFacetCount {
                throw DicomSTLContentError.tooManyFacets
            }
        }
        return try parseASCII(data, millimetersPerUnit: millimetersPerUnit)
    }

    private static func parseBinary(
        _ data: Data,
        facetCount: Int,
        millimetersPerUnit: Float
    ) throws -> DicomSTLMesh {
        guard facetCount > 0 else { throw DicomSTLContentError.malformedSTL }
        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(facetCount * 3)
        normals.reserveCapacity(facetCount * 3)
        indices.reserveCapacity(facetCount * 3)

        for facet in 0..<facetCount {
            let offset = 84 + facet * 50
            let suppliedNormal = try vector(in: data, at: offset)
            let triangle = try (0..<3).map { vertexIndex in
                try scaledVector(
                    in: data,
                    at: offset + 12 + vertexIndex * 12,
                    millimetersPerUnit: millimetersPerUnit
                )
            }
            try appendTriangle(
                triangle,
                suppliedNormal: suppliedNormal,
                vertices: &vertices,
                normals: &normals,
                indices: &indices
            )
        }
        return DicomSTLMesh(
            verticesMillimeters: vertices,
            normals: normals,
            indices: indices
        )
    }

    private static func parseASCII(
        _ data: Data,
        millimetersPerUnit: Float
    ) throws -> DicomSTLMesh {
        guard let source = String(data: data, encoding: .utf8) else {
            throw DicomSTLContentError.malformedSTL
        }
        let lines = source.split(whereSeparator: \.isNewline).map { line in
            line.split(whereSeparator: \.isWhitespace).map(String.init)
        }.filter { !$0.isEmpty }
        guard let first = lines.first,
              first.first?.lowercased() == "solid" else {
            throw DicomSTLContentError.malformedSTL
        }

        var vertices: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var lineIndex = 1
        var foundEnd = false

        while lineIndex < lines.count {
            let line = lines[lineIndex]
            if line.first?.lowercased() == "endsolid" {
                foundEnd = true
                lineIndex += 1
                break
            }
            guard vertices.count / 3 < maximumFacetCount else {
                throw DicomSTLContentError.tooManyFacets
            }
            guard line.count == 5,
                  line[0].lowercased() == "facet",
                  line[1].lowercased() == "normal" else {
                throw DicomSTLContentError.malformedSTL
            }
            let suppliedNormal = try vector(tokens: Array(line[2...4]), scale: 1)
            lineIndex += 1
            guard lineIndex < lines.count,
                  lines[lineIndex].map({ $0.lowercased() }) == ["outer", "loop"] else {
                throw DicomSTLContentError.malformedSTL
            }
            lineIndex += 1

            var triangle: [SIMD3<Float>] = []
            for _ in 0..<3 {
                guard lineIndex < lines.count,
                      lines[lineIndex].count == 4,
                      lines[lineIndex][0].lowercased() == "vertex" else {
                    throw DicomSTLContentError.malformedSTL
                }
                triangle.append(try vector(
                    tokens: Array(lines[lineIndex][1...3]),
                    scale: millimetersPerUnit
                ))
                lineIndex += 1
            }
            guard lineIndex < lines.count,
                  lines[lineIndex].map({ $0.lowercased() }) == ["endloop"] else {
                throw DicomSTLContentError.malformedSTL
            }
            lineIndex += 1
            guard lineIndex < lines.count,
                  lines[lineIndex].map({ $0.lowercased() }) == ["endfacet"] else {
                throw DicomSTLContentError.malformedSTL
            }
            lineIndex += 1
            try appendTriangle(
                triangle,
                suppliedNormal: suppliedNormal,
                vertices: &vertices,
                normals: &normals,
                indices: &indices
            )
        }

        guard foundEnd, lineIndex == lines.count, !indices.isEmpty else {
            throw DicomSTLContentError.malformedSTL
        }
        return DicomSTLMesh(
            verticesMillimeters: vertices,
            normals: normals,
            indices: indices
        )
    }

    private static func appendTriangle(
        _ triangle: [SIMD3<Float>],
        suppliedNormal: SIMD3<Float>,
        vertices: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) throws {
        guard triangle.count == 3 else { throw DicomSTLContentError.malformedSTL }
        let cross = crossProduct(triangle[1] - triangle[0], triangle[2] - triangle[0])
        let crossLength = length(cross)
        guard crossLength.isFinite, crossLength > 0 else {
            throw DicomSTLContentError.degenerateFacet
        }
        let suppliedLength = length(suppliedNormal)
        let normal = suppliedLength.isFinite && suppliedLength > 0
            ? suppliedNormal / suppliedLength
            : cross / crossLength
        guard normal.x.isFinite, normal.y.isFinite, normal.z.isFinite else {
            throw DicomSTLContentError.nonFiniteValue
        }

        let start = UInt32(vertices.count)
        vertices.append(contentsOf: triangle)
        normals.append(contentsOf: repeatElement(normal, count: 3))
        indices.append(contentsOf: [start, start + 1, start + 2])
    }

    private static func binaryFacetCount(in data: Data) -> Int? {
        guard data.count >= 84 else { return nil }
        return Int(uint32(in: data, at: 80))
    }

    private static func looksLikeASCII(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(512), encoding: .utf8) else { return false }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("solid")
    }

    private static func scaledVector(
        in data: Data,
        at offset: Int,
        millimetersPerUnit: Float
    ) throws -> SIMD3<Float> {
        let value = try vector(in: data, at: offset) * millimetersPerUnit
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
            throw DicomSTLContentError.nonFiniteValue
        }
        return value
    }

    private static func vector(in data: Data, at offset: Int) throws -> SIMD3<Float> {
        let value = SIMD3<Float>(
            Float(bitPattern: uint32(in: data, at: offset)),
            Float(bitPattern: uint32(in: data, at: offset + 4)),
            Float(bitPattern: uint32(in: data, at: offset + 8))
        )
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
            throw DicomSTLContentError.nonFiniteValue
        }
        return value
    }

    private static func vector(tokens: [String], scale: Float) throws -> SIMD3<Float> {
        guard tokens.count == 3,
              let x = Float(tokens[0]),
              let y = Float(tokens[1]),
              let z = Float(tokens[2]) else {
            throw DicomSTLContentError.malformedSTL
        }
        let value = SIMD3<Float>(x, y, z) * scale
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else {
            throw DicomSTLContentError.nonFiniteValue
        }
        return value
    }

    private static func crossProduct(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
        .init(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }

    private static func length(_ v: SIMD3<Float>) -> Float { (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot() }

    public static func parse(_ data: Data, measurementUnits: DicomCodedConcept?) -> DicomDocumentContentResult<DicomSTLMesh> {
        let limitations = ["ASCII and binary STL geometry only; no topology, watertightness or manufacturing validation.",
                           "ASCII STL is not the binary STL stream required by PS3.3 A.85.1."]
        guard measurementUnits != nil else {
            return .init(value: nil, diagnostics: [.init(code: "missingScale", reason: "Model scale is absent.")], limitations: limitations)
        }
        guard let scale = DicomManufacturing3DModel(measurementUnits: measurementUnits).millimetersPerUnit else {
            return .init(value: nil, diagnostics: [.init(code: "unsupportedScale", reason: "Explicit supported UCUM length units required.")], limitations: limitations)
        }
        do { return .init(value: try parseMesh(Data(data), millimetersPerUnit: scale), limitations: limitations) }
        catch { return .init(value: nil, diagnostics: [.init(code: String(describing: error), reason: error.localizedDescription)], limitations: limitations) }
    }

    public static func parse(_ document: DicomEncapsulatedDocument) -> DicomDocumentContentResult<DicomSTLMesh> {
        parse(document.documentData, measurementUnits: document.manufacturing3DModel?.measurementUnits ?? document.measurementUnits)
    }

    private static func uint32(in data: Data, at offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) { value, byte in
            value | (UInt32(byte.element) << UInt32(byte.offset * 8))
        }
    }
}
