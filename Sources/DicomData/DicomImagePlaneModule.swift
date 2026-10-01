import Foundation

/// C.7.6.2 for classic CT/MR and SC with declared patient position/orientation.
/// Exact encoded bases can pass; unqualified rounding of non-unit vectors remains incomplete.
public enum DicomImagePlaneModule {
    public static func applies(to dataSet: DicomDataSet, kind: DicomCompositeImageModules.Kind) -> Bool {
        // The multi-frame SC IODs do not include Image Plane; classic SC includes it when declared.
        kind == .ct || kind == .mr || kind == .rtDose || (kind == .secondaryCapture && (dataSet.contains(0x00200032) || dataSet.contains(0x00200037)))
    }

    public static var rules: [DicomAttributeRule] {
        [0x00280030, 0x00200037, 0x00200032].map { .init(tag: $0, requirement: .type1) } + [
            .init(tag: 0x00180050, requirement: .type2),
            .init(tag: 0x00180088, requirement: .type3),
            .init(tag: 0x00201041, requirement: .type3)
        ]
    }

    public static func validate(_ dataSet: DicomDataSet,
                                limits: DicomAttributeValidator.Limits = .init()) -> DicomValidationReport {
        let attributes = DicomAttributeValidator.evaluate(dataSet, rules: rules, limits: limits)
        var state = State(limits: limits, work: attributes.evaluations, diagnostics: attributes.report.diagnostics)
        if attributes.report.diagnostics.contains(where: { $0.code == .evaluationLimitReached }) {
            state.diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation, layer: .pixelsAndGeometry))
        } else {
            state.validate(dataSet)
        }
        return .init(evaluatedLayers: [.attributes, .pixelsAndGeometry], diagnostics: state.diagnostics)
    }

    /// Geometry checks of the frame-level Pixel Measures, Plane Position and Plane Orientation values,
    /// sharing the caller's work budget. Missing values are frame limitations, not errors.
    static func geometry(_ dataSet: DicomDataSet,
                         limits: DicomAttributeValidator.Limits) -> (diagnostics: [DicomValidationReport.Diagnostic], work: Int) {
        var state = State(limits: limits, work: 0, diagnostics: [])
        state.validate(dataSet)
        return (state.diagnostics, state.work)
    }

    private struct State {
        let limits: DicomAttributeValidator.Limits
        var work: Int
        var diagnostics: [DicomValidationReport.Diagnostic]
        var stopped = false

        mutating func spend(_ count: Int, tag: Int) -> Bool {
            guard !stopped else { return false }
            guard count <= limits.maximumRuleEvaluations - work, diagnostics.count < limits.maximumDiagnostics else {
                diagnostics.append(.init(code: .evaluationLimitReached, severity: .limitation,
                                         layer: .pixelsAndGeometry, path: [.tag(tag)]))
                stopped = true
                return false
            }
            work += count
            return true
        }

        mutating func record(_ code: DicomValidationReport.Code, tag: Int,
                             severity: DicomValidationReport.Severity = .error) {
            guard spend(1, tag: tag) else { return }
            let requirement: DicomAttributeRule.Requirement = [0x00280030, 0x00200037, 0x00200032].contains(tag) ? .type1 :
                tag == 0x00180050 ? .type2 : .type3
            diagnostics.append(.init(code: code, severity: severity, layer: .pixelsAndGeometry,
                                     path: [.tag(tag)], requirement: requirement))
        }

        mutating func values(_ dataSet: DicomDataSet, tag: Int, count: Int, optional: Bool = false) -> [Decimal]? {
            guard spend(1, tag: tag) else { return nil }
            guard let element = dataSet[tag] else {
                if !optional { record(.valueUnavailable, tag: tag, severity: .limitation) }
                return optional ? [] : nil
            }
            guard element.vr == .DS else { record(.valueUnavailable, tag: tag, severity: .limitation); return nil }
            if case .empty = element.value {
                if !optional { record(.valueUnavailable, tag: tag, severity: .limitation) }
                return optional ? [] : nil
            }
            guard case .strings(let strings) = element.value else { record(.valueUnavailable, tag: tag, severity: .limitation); return nil }
            guard spend(strings.count, tag: tag) else { return nil }
            if strings.allSatisfy({ $0.trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty }) {
                if !optional { record(.valueUnavailable, tag: tag, severity: .limitation) }
                return optional ? [] : nil
            }
            guard strings.count == count else { record(.invalidMultiplicity, tag: tag); return nil }
            do { return try strings.map { try DicomDecimalString.parse($0) } }
            catch DicomDecimalString.Failure.invalid { record(.spatialGeometryInvalid, tag: tag); return nil }
            catch { record(.spatialGeometryPrecisionUnavailable, tag: tag, severity: .limitation); return nil }
        }

        mutating func validate(_ dataSet: DicomDataSet) {
            if let spacing = values(dataSet, tag: 0x00280030, count: 2) {
                for (index, dimensionTag) in [0x00280010, 0x00280011].enumerated() {
                    if spacing[index] < 0 { record(.spatialGeometryInvalid, tag: 0x00280030) }
                    if spacing[index] == 0 {
                        guard let dimension = dataSet[dimensionTag], dimension.vr == .US, dimension.vm.count == 1,
                              let size = dimension.intValue, (1...65535).contains(size) else {
                            record(.valueUnavailable, tag: 0x00280030, severity: .limitation)
                            continue
                        }
                        if size != 1 { record(.spatialGeometryInvalid, tag: 0x00280030) }
                    }
                }
            }
            _ = values(dataSet, tag: 0x00200032, count: 3)
            _ = values(dataSet, tag: 0x00180050, count: 1, optional: true)
            _ = values(dataSet, tag: 0x00201041, count: 1, optional: true)
            if let spacing = values(dataSet, tag: 0x00180088, count: 1, optional: true), let value = spacing.first, value < 0 {
                record(.spatialGeometryInvalid, tag: 0x00180088)
            }
            guard let orientation = values(dataSet, tag: 0x00200037, count: 6), spend(64, tag: 0x00200037) else { return }
            guard orientation.allSatisfy({ $0 >= -1 && $0 <= 1 }) else { record(.spatialGeometryInvalid, tag: 0x00200037); return }
            let row = Array(orientation.prefix(3))
            let column = Array(orientation.suffix(3))
            guard let rowLength = dot(row, row), let columnLength = dot(column, column), let product = dot(row, column) else {
                record(.spatialGeometryPrecisionUnavailable, tag: 0x00200037, severity: .limitation)
                return
            }
            if rowLength == 0 || columnLength == 0 {
                record(.spatialGeometryInvalid, tag: 0x00200037)
            } else {
                let cross = [(1, 2), (2, 0), (0, 1)].compactMap {
                    dot([row[$0.0], -row[$0.1], 0], [column[$0.1], column[$0.0], 0])
                }
                if cross.count != 3 {
                    record(.spatialGeometryPrecisionUnavailable, tag: 0x00200037, severity: .limitation)
                } else if cross.allSatisfy({ $0 == 0 }) {
                    record(.spatialGeometryInvalid, tag: 0x00200037)
                } else if rowLength == 1 && columnLength == 1 {
                    if product != 0 { record(.spatialGeometryInvalid, tag: 0x00200037, severity: severity(rowLength, columnLength, product)) }
                } else if let halves = halfUnits(dataSet, tag: 0x00200037), halves.count == 6 {
                    // The encoded decimal digits bound the rounding of each cosine; a basis is accepted only
                    // when unit length and orthogonality hold within the error that rounding can introduce.
                    let rowHalves = Array(halves.prefix(3)), columnHalves = Array(halves.suffix(3))
                    if magnitude(rowLength - 1) > unitBound(row, rowHalves) || magnitude(columnLength - 1) > unitBound(column, columnHalves)
                        || magnitude(product) > dotBound(row, column, rowHalves, columnHalves) {
                        record(.spatialGeometryInvalid, tag: 0x00200037, severity: severity(rowLength, columnLength, product))
                    }
                } else {
                    record(.spatialGeometryPrecisionUnavailable, tag: 0x00200037, severity: .limitation)
                }
            }
        }

        func magnitude(_ value: Decimal) -> Decimal { value < 0 ? -value : value }

        /// A basis outside its own rounding bound is a contradiction. Scanners write cosines truncated to a
        /// few significant digits whose unit length and orthogonality miss by up to 1e-3 (a Siemens MR in the
        /// pydicom test data misses by 4e-5); every consumer normalises them, so that band is a warning and
        /// only a larger departure stays an error (issue #2487). `rowLength`/`columnLength` are squared norms.
        func severity(_ rowLength: Decimal, _ columnLength: Decimal, _ product: Decimal) -> DicomValidationReport.Severity {
            let tolerance = Decimal(string: "0.001")!
            let usable = magnitude(rowLength - 1) <= 2 * tolerance && magnitude(columnLength - 1) <= 2 * tolerance
                && magnitude(product) <= tolerance
            return usable ? .warning : .error
        }

        func unitBound(_ vector: [Decimal], _ halves: [Decimal]) -> Decimal {
            zip(vector, halves).reduce(Decimal()) { $0 + 2 * magnitude($1.0) * $1.1 + $1.1 * $1.1 }
        }

        func dotBound(_ lhs: [Decimal], _ rhs: [Decimal], _ lhsHalves: [Decimal], _ rhsHalves: [Decimal]) -> Decimal {
            (0..<3).reduce(Decimal()) { $0 + magnitude(lhs[$1]) * rhsHalves[$1] + magnitude(rhs[$1]) * lhsHalves[$1] + lhsHalves[$1] * rhsHalves[$1] }
        }

        /// Half of the last encoded decimal place of each DS component, from the original string.
        func halfUnits(_ dataSet: DicomDataSet, tag: Int) -> [Decimal]? {
            guard let element = dataSet[tag], case .strings(let strings) = element.value else { return nil }
            var halves: [Decimal] = []
            for string in strings {
                let trimmed = string.trimmingCharacters(in: CharacterSet(charactersIn: " ")).uppercased()
                let parts = trimmed.split(separator: "E", maxSplits: 1).map(String.init)
                guard let mantissa = parts.first, let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return nil }
                let pieces = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
                let fraction = pieces.count == 2 ? pieces[1].count : 0
                // A cosine encoded without fraction digits is 0 or ±1 exactly; only fractional encodings carry rounding.
                if fraction == 0 && exponent >= 0 { halves.append(Decimal()); continue }
                guard let half = Decimal(string: "5E\(exponent - fraction - 1)") else { return nil }
                halves.append(half)
            }
            return halves
        }

        func dot(_ lhs: [Decimal], _ rhs: [Decimal]) -> Decimal? {
            var sum = Decimal()
            for index in 0..<3 {
                var a = lhs[index]
                var b = rhs[index]
                var product = Decimal()
                var next = Decimal()
                guard NSDecimalMultiply(&product, &a, &b, .plain) == .noError,
                      NSDecimalAdd(&next, &sum, &product, .plain) == .noError else { return nil }
                sum = next
            }
            return sum
        }
    }
}
