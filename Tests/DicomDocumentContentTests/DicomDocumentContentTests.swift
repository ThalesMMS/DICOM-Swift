import Foundation
import XCTest
import DicomCore
@testable import DicomDocumentContent

final class DicomDocumentContentTests: XCTestCase {
    private let mm = DicomCodedConcept(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter")
    private let ascii = """
    solid triangle
    facet normal 0 0 0
    outer loop
    vertex 0 0 0
    vertex 2 0 0
    vertex 0 3 0
    endloop
    endfacet
    endsolid triangle
    """

    func test_stlBinaryAndASCII_preserveGeometryAndApplyUnits() throws {
        let cm = DicomCodedConcept(codeValue: "cm", codingSchemeDesignator: "UCUM", codeMeaning: "centimeter")
        for bytes in [binaryTriangle(), Data(ascii.utf8)] {
            let result = DicomSTLContentParser.parse(bytes, measurementUnits: cm)
            let mesh = try XCTUnwrap(result.value)
            XCTAssertTrue(result.diagnostics.isEmpty)
            XCTAssertFalse(result.limitations.isEmpty)
            XCTAssertEqual(mesh.verticesMillimeters, [.init(0, 0, 0), .init(20, 0, 0), .init(0, 30, 0)])
            XCTAssertEqual(mesh.normals, Array(repeating: .init(0, 0, 1), count: 3))
            XCTAssertEqual(mesh.indices, [0, 1, 2])
        }
    }

    func test_invalidSTLFacetsAndBudgets_returnDiagnostics() {
        var nonFinite = binaryTriangle()
        replace(Float.nan.bitPattern, in: &nonFinite, at: 96)
        var excessive = Data(repeating: 0, count: 84)
        replace(UInt32(DicomSTLContentParser.maximumFacetCount + 1), in: &excessive, at: 80)
        let degenerate = ascii.replacingOccurrences(of: "vertex 2 0 0", with: "vertex 0 0 0")
        for (bytes, code) in [(nonFinite, "nonFiniteValue"), (excessive, "tooManyFacets"),
                              (Data(degenerate.utf8), "degenerateFacet"), (Data(binaryTriangle().dropLast()), "malformedSTL"),
                              (Data(repeating: 0, count: DicomSTLContentParser.maximumDocumentBytes + 1), "documentTooLarge")] {
            let result = DicomSTLContentParser.parse(bytes, measurementUnits: mm)
            XCTAssertNil(result.value)
            XCTAssertEqual(result.diagnostics.first?.code, code)
        }
        XCTAssertEqual(DicomSTLContentParser.parse(binaryTriangle(), measurementUnits: nil).diagnostics.first?.code, "missingScale")
        XCTAssertEqual(DicomSTLContentParser.parse(binaryTriangle(), measurementUnits:
            .init(codeValue: "kg", codingSchemeDesignator: "UCUM")).diagnostics.first?.code, "unsupportedScale")
    }

    func test_objQuadWithGroupsAndMaterials_triangulatesAndResolvesNegativeIndices() throws {
        let obj = """
        mtllib bone.mtl
        o Bone
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        vn 0 0 1
        vt 0 0
        g front bone
        usemtl white
        f -4/1/1 -3/1/1 -2/1/1 -1/1/1
        """
        let result = DicomOBJContentParser.parse(Data(obj.utf8))
        let mesh = try XCTUnwrap(result.value)
        XCTAssertEqual(mesh.triangles.map { $0.corners.map(\.vertex) }, [[0, 1, 2], [0, 2, 3]])
        XCTAssertEqual(mesh.triangles[0].groups, ["front", "bone"])
        XCTAssertEqual(mesh.triangles[0].material, "white")
        XCTAssertEqual(mesh.materialLibraries, ["bone.mtl"])
        XCTAssertEqual(mesh.triangles[0].corners[0].normal, 0)
        XCTAssertEqual(mesh.triangles[0].corners[0].textureCoordinate, 0)
        XCTAssertNil(DicomOBJContentParser.parse(Data((obj + "\nf 0 1 2").utf8)).value)
        XCTAssertNil(DicomOBJContentParser.parse(Data(repeating: 0, count: DicomOBJContentParser.maximumDocumentBytes + 1)).value)
    }

    func test_mtl_parsesColorTransparencyAndMapNames() throws {
        let result = DicomMTLContentParser.parse(Data("newmtl bone\nKa 0.1 0.2 0.3\nKd 1 1 1\nKs 0 0 0\nd 0.8\nTr 0.25\nmap_Kd bone.png\n".utf8))
        let material = try XCTUnwrap(result.value?.first)
        XCTAssertEqual(material.name, "bone")
        XCTAssertEqual(material.ambient, .init(0.1, 0.2, 0.3))
        XCTAssertEqual(material.diffuse, .init(1, 1, 1))
        XCTAssertEqual(material.specular, .zero)
        XCTAssertEqual(material.opacity, 0.75)
        XCTAssertEqual(material.maps["map_Kd"], "bone.png")
        XCTAssertNil(DicomMTLContentParser.parse(Data("newmtl bad\nd nan".utf8)).value)
        XCTAssertNil(DicomMTLContentParser.parse(Data(repeating: 0, count: DicomMTLContentParser.maximumDocumentBytes + 1)).value)
    }

    func test_cdaNarrative_extractsTitleSectionsAndRefusesExternalEntities() throws {
        let xml = """
        <?xml version="1.0"?><ClinicalDocument xmlns="urn:hl7-org:v3"><title>Report title</title>
        <component><structuredBody><component><section><title>Findings</title><text>
        <paragraph>First <content>finding</content>.</paragraph><paragraph>Second finding.</paragraph>
        <script>hidden</script></text></section></component></structuredBody></component></ClinicalDocument>
        """
        let result = DicomCDANarrativeExtractor.parse(Data(xml.utf8))
        let narrative = try XCTUnwrap(result.value)
        XCTAssertEqual(narrative.title, "Report title")
        XCTAssertTrue(narrative.hasStructuredBody)
        XCTAssertEqual(narrative.sections.first?.title, "Findings")
        XCTAssertEqual(narrative.sections.first?.text, "First finding.\nSecond finding.")
        XCTAssertTrue(result.limitations.contains { $0.contains("not CDA R2") })
        let entity = "<!DOCTYPE ClinicalDocument [<!ENTITY xxe SYSTEM 'file:///does-not-exist'>]><ClinicalDocument><title>&xxe;</title></ClinicalDocument>"
        XCTAssertEqual(DicomCDANarrativeExtractor.parse(Data(entity.utf8)).diagnostics.first?.code, "unsafeXML")
        XCTAssertNil(DicomCDANarrativeExtractor.parse(Data("<notCDA/>".utf8)).value)
        XCTAssertNil(DicomCDANarrativeExtractor.parse(Data(repeating: 0, count: DicomCDANarrativeExtractor.maximumDocumentBytes + 1)).value)
    }

    func test_pdfInspector_reportsHeaderObjectsAndGarbage() throws {
        let bytes = Data("%PDF-1.4\n1 0 obj << /Type /Pages /Count 1 >> endobj\n2 0 obj << /Type /Page /Parent 1 0 R >> endobj\nxref\n0 1\n0000000000 65535 f\ntrailer << /Root 1 0 R >>\nstartxref\n0\n%%EOF".utf8)
        let result = DicomPDFEnvelopeInspector.inspect(bytes)
        let pdf = try XCTUnwrap(result.value)
        XCTAssertEqual(pdf.headerVersion, "1.4")
        XCTAssertTrue(pdf.hasXref)
        XCTAssertTrue(pdf.hasTrailer)
        XCTAssertEqual(pdf.pageCountHeuristic, 1)
        XCTAssertTrue(result.diagnostics.isEmpty)
        XCTAssertEqual(DicomPDFEnvelopeInspector.inspect(Data("garbage".utf8)).diagnostics.first?.code, "missingHeader")
        XCTAssertNil(DicomPDFEnvelopeInspector.inspect(Data(repeating: 0, count: DicomPDFEnvelopeInspector.maximumDocumentBytes + 1)).value)
    }

    func test_pdfWithoutObjectTerminators_boundsInspectionWork() throws {
        let text = "%PDF-1.4\n" + String(repeating: "1 0 obj << /Type /Pages\n", count: 6_000)
            + "endobj\n2 0 obj << /Type /Page >> endobj\n/Type /Page\nxref\ntrailer"
        let start = ProcessInfo.processInfo.systemUptime
        let result = DicomPDFEnvelopeInspector.inspect(Data(text.utf8))
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(try XCTUnwrap(result.value).pageCountHeuristic, 1)
        XCTAssertLessThan(elapsed, 2, "A small malformed PDF must not repeatedly scan the remaining payload")
    }

    private func binaryTriangle() -> Data {
        var bytes = Data(repeating: 0, count: 80)
        bytes.append(contentsOf: [1, 0, 0, 0])
        for value: Float in [0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3, 0] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        bytes.append(contentsOf: [0, 0])
        return bytes
    }

    private func replace(_ value: UInt32, in data: inout Data, at offset: Int) {
        var bits = value.littleEndian
        withUnsafeBytes(of: &bits) { data.replaceSubrange(offset..<(offset + 4), with: $0) }
    }
}
