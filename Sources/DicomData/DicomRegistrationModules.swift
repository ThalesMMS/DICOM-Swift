import Foundation

/// C.20.2/C.20.3 numerical rules supplementing the generated registration IOD tables.
enum DicomRegistrationModules {
    static func validate(_ data: DicomDataSet, deformable: Bool, state: inout DicomEnhancedImageModules.State) {
        state.evaluate([.init(tag: 0x00080060, requirement: .type1, constraints: [.strings(["REG"])]),
            .init(tag: 0x00200052, requirement: .type1), .init(tag: 0x00201040, requirement: .type2)], on: data, path: [])
        let tag = deformable ? 0x00640002 : 0x00700308
        let items = data.sequenceItems(for: tag)
        if deformable && !items.contains(where: { !$0.dataSet.sequenceItems(for: 0x00640005).isEmpty }) {
            state.record(.attributeValueContradiction, path: [.tag(tag)])
        }
        for (index, item) in items.enumerated() {
            guard !state.stopped else { return }
            let path: [DicomValidationReport.PathComponent] = [.tag(tag), .item(index)]
            let data = item.dataSet
            if deformable {
                for matrixTag in [0x0064000F, 0x00640010] {
                    for (matrixIndex, matrix) in data.sequenceItems(for: matrixTag).enumerated() {
                        validateMatrix(matrix.dataSet, path: path + [.tag(matrixTag), .item(matrixIndex)], state: &state)
                    }
                }
                for (gridIndex, grid) in data.sequenceItems(for: 0x00640005).enumerated() {
                    validateGrid(grid.dataSet, path: path + [.tag(0x00640005), .item(gridIndex)], state: &state)
                }
            } else {
                for (registrationIndex, registration) in data.sequenceItems(for: 0x00700309).enumerated() {
                    for (matrixIndex, matrix) in registration.dataSet.sequenceItems(for: 0x0070030A).enumerated() {
                        validateMatrix(matrix.dataSet, path: path + [.tag(0x00700309), .item(registrationIndex), .tag(0x0070030A), .item(matrixIndex)], state: &state)
                    }
                }
                for (segmentIndex, segment) in data.sequenceItems(for: 0x00620012).enumerated() where segment.dataSet.ints(for: 0x0062000B).count != 1 {
                    state.record(.attributeValueContradiction, path: path + [.tag(0x00620012), .item(segmentIndex), .tag(0x0062000B)])
                }
            }
        }
    }

    private static func validateMatrix(_ data: DicomDataSet, path: [DicomValidationReport.PathComponent],
                                       state: inout DicomEnhancedImageModules.State) {
        let values = data.decimalStrings(for: 0x300600C6)
        if values.count != 16 || !values.allSatisfy(\.isFinite) || Array(values.suffix(4)) != [0, 0, 0, 1] {
            state.record(.attributeValueContradiction, path: path + [.tag(0x300600C6)])
        }
        state.evaluate([.init(tag: 0x0070030C, requirement: .type1, constraints: [.strings(["RIGID", "RIGID_SCALE", "AFFINE"])])], on: data, path: path)
    }

    private static func validateGrid(_ data: DicomDataSet, path: [DicomValidationReport.PathComponent],
                                     state: inout DicomEnhancedImageModules.State) {
        let dimensions = data.ints(for: 0x00640007)
        var expected: Int? = dimensions.count == 3 ? 12 : nil
        for dimension in dimensions {
            if let current = expected {
                let (next, overflow) = current.multipliedReportingOverflow(by: dimension)
                expected = dimension > 0 && !overflow ? next : nil
            }
        }
        if expected == nil { state.record(.attributeValueContradiction, path: path + [.tag(0x00640007)]) }
        let resolution = data.floats(for: 0x00640008)
        if resolution.count != 3 || !resolution.allSatisfy({ $0.isFinite && $0 > 0 }) {
            state.record(.attributeValueContradiction, path: path + [.tag(0x00640008)])
        }
        let orientation = data.decimalStrings(for: 0x00200037)
        var orthonormal = false
        if orientation.count == 6, orientation.allSatisfy(\.isFinite) {
            let a = Array(orientation.prefix(3)), b = Array(orientation.suffix(3))
            let dot = zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
            orthonormal = abs(dot) <= 1e-6 && abs(a.reduce(0) { $0 + $1*$1 } - 1) <= 1e-6 && abs(b.reduce(0) { $0 + $1*$1 } - 1) <= 1e-6
        }
        if !orthonormal { state.record(.attributeValueContradiction, path: path + [.tag(0x00200037)]) }
        let position = data.decimalStrings(for: 0x00200032)
        if position.count != 3 || !position.allSatisfy(\.isFinite) { state.record(.attributeValueContradiction, path: path + [.tag(0x00200032)]) }
        let bytes = data[0x00640009]?.bytesValue
        let values: [Double]
        if let bytes {
            values = stride(from: 0, to: bytes.count - bytes.count % 4, by: 4).map { offset in
                let index = bytes.startIndex + offset
                let word = UInt32(bytes[index]) | UInt32(bytes[index+1]) << 8 | UInt32(bytes[index+2]) << 16 | UInt32(bytes[index+3]) << 24
                return Double(Float(bitPattern: word))
            }
        } else { values = data.floats(for: 0x00640009) }
        if expected == nil || expected != (bytes?.count ?? values.count * 4) {
            state.record(.attributeValueContradiction, path: path + [.tag(0x00640009)])
        }
        for index in stride(from: 0, to: values.count - values.count % 3, by: 3) {
            let triple = Array(values[index..<index+3])
            if !triple.allSatisfy(\.isFinite) && !triple.allSatisfy(\.isNaN) {
                state.record(.attributeValueContradiction, path: path + [.tag(0x00640009)]); break
            }
        }
    }
}
