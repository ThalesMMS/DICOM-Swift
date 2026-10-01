import Foundation

/// Cross-module US relationships that reuse the region parser and segmented palette decoder.
enum DicomUltrasoundValidation {
    static func validate(_ dataSet: DicomDataSet, littleEndian: Bool,
                         limits: DicomAttributeValidator.Limits) -> DicomValidationReport {
        var report = DicomValidationReport(evaluatedLayers: [.attributes])
        var budget = limits.maximumRuleEvaluations
        func record(_ code: DicomValidationReport.Code, _ path: [DicomValidationReport.PathComponent],
                    severity: DicomValidationReport.Severity = .error) {
            report = report.merging(.init(diagnostics: [.init(code: code, severity: severity, layer: .attributes, path: path)]))
        }
        for (index, item) in (dataSet[0x00186011]?.sequenceItems ?? []).enumerated() {
            let path: [DicomValidationReport.PathComponent] = [.tag(0x00186011), .item(index)]
            guard budget > 0, report.diagnostics.count < limits.maximumDiagnostics else {
                record(.evaluationLimitReached, path, severity: .limitation); return report
            }
            budget -= 1
            let attributes = item.dataSet
            guard let region = DCMDecoder.ultrasoundRegion(from: attributes) else {
                if [0x00186018, 0x0018601A, 0x0018601C, 0x0018601E].allSatisfy({ attributes.int(for: $0) != nil }) {
                    record(.attributeValueContradiction, path)
                }
                continue
            }
            if let columns = dataSet.int(for: 0x00280011), region.maxX1 >= columns {
                record(.attributeValueContradiction, path + [.tag(0x0018601C)])
            }
            if let rows = dataSet.int(for: 0x00280010), region.maxY1 >= rows {
                record(.attributeValueContradiction, path + [.tag(0x0018601E)])
            }
            if let group = attributes.int(for: 0x00186070) {
                guard (0x6000...0x601E).contains(group), group.isMultiple(of: 2) else {
                    record(.attributeValueNotAllowed, path + [.tag(0x00186070)]); continue
                }
                let base = group << 16
                let rules: [DicomAttributeRule] = [
                    .init(tag: base + 0x0010, requirement: .type1, constraints: [.integers([region.maxY1 - region.minY0 + 1])]),
                    .init(tag: base + 0x0011, requirement: .type1, constraints: [.integers([region.maxX1 - region.minX0 + 1])]),
                    .init(tag: base + 0x0040, requirement: .type1, constraints: [.strings(["R"])]),
                    .init(tag: base + 0x0045, requirement: .type1C, condition: .known(.satisfied),
                        constraints: [.strings(["ACTIVE 2D/BMODE IMAGE AREA", "ACTIVE VOLUME FLOW IMAGE AREA"])]),
                    .init(tag: base + 0x0050, requirement: .type1, constraints: [.valueCount(2...2)])
                ]
                let checked = DicomAttributeValidator.evaluate(dataSet, rules: rules,
                    limits: .init(maximumRuleEvaluations: budget, maximumDiagnostics: max(1, limits.maximumDiagnostics - report.diagnostics.count)))
                budget -= checked.evaluations
                report = report.merging(checked.report)
                if case .signedIntegers(let origin) = dataSet[base + 0x0050]?.value,
                   origin != [region.minY0 + 1, region.minX0 + 1] {
                    record(.attributeValueContradiction, [.tag(base + 0x0050)])
                }
            }
        }
        if dataSet.string(for: 0x00280004) == "PALETTE COLOR" {
            var previous: [UInt]?
            for channel in 1...3 {
                let tag = 0x00281100 + channel
                guard case .unsignedIntegers(let descriptor) = dataSet[tag]?.value, descriptor.count == 3 else { continue }
                guard [8, 16].contains(descriptor[2]) else { record(.attributeValueNotAllowed, [.tag(tag)]); continue }
                if let previous, descriptor != previous { record(.attributeValueContradiction, [.tag(tag)]) }
                previous = descriptor
                let count = descriptor[0] == 0 ? 65536 : Int(descriptor[0])
                let segmented = dataSet.contains(0x00281220 + channel)
                let dataTag = (segmented ? 0x00281220 : 0x00281200) + channel
                guard case .bytes(let bytes) = dataSet[dataTag]?.value else { continue }
                guard bytes.count <= budget, count <= 65536, report.diagnostics.count < limits.maximumDiagnostics else {
                    record(.evaluationLimitReached, [.tag(dataTag)], severity: .limitation); return report
                }
                budget -= bytes.count
                if segmented {
                    guard bytes.count.isMultiple(of: 2) else { record(.invalidValueLength, [.tag(dataTag)]); continue }
                    let words = stride(from: 0, to: bytes.count, by: 2).map { offset in
                        let first = UInt16(bytes[bytes.startIndex + offset]), second = UInt16(bytes[bytes.startIndex + offset + 1])
                        return littleEndian ? first | second << 8 : first << 8 | second
                    }
                    do { _ = try DicomSegmentedPaletteExpander.expand(words: words, entryCount: count) }
                    catch { record(.attributeValueContradiction, [.tag(dataTag)]) }
                } else {
                    let expected = count * Int(descriptor[2]) / 8
                    if bytes.count != expected + expected % 2 { record(.pixelDataLengthMismatch, [.tag(dataTag)]) }
                }
            }
        }
        return report
    }
}
