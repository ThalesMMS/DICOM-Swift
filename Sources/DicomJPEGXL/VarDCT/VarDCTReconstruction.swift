import Foundation

/// Small reconstruction kernels keep bounds/ownership work outside the coefficient and pixel loops.
package enum VarDCTReconstruction {
    static func dequantizeAC(
        x: [Int32], y: [Int32], b: [Int32], weights: [Float], scale: Float,
        xScale: Float, bScale: Float, xFromY: Float, bFromY: Float,
        columns: Int, llfRows: Int, llfColumns: Int,
        outputX: inout [Float], outputY: inout [Float], outputB: inout [Float]
    ) {
        let count = outputX.count
        precondition(x.count >= count && y.count >= count && b.count >= count && weights.count >= count * 3)
        precondition(outputY.count == count && outputB.count == count && columns > 0 && count % columns == 0)
        x.withUnsafeBufferPointer { qx in
            y.withUnsafeBufferPointer { qy in
                b.withUnsafeBufferPointer { qb in
                    weights.withUnsafeBufferPointer { w in
                        outputX.withUnsafeMutableBufferPointer { ox in
                            outputY.withUnsafeMutableBufferPointer { oy in
                                outputB.withUnsafeMutableBufferPointer { ob in
                                    for row in stride(from: 0, to: count, by: columns) {
                                        let first = row < llfRows * columns ? llfColumns : 0
                                        for i in (row + first)..<(row + columns) {
                                            let dy = AdjustQuantBias.adjust(channel: 1, quant: qy[i]) / w[count + i] * scale
                                            let dx = AdjustQuantBias.adjust(channel: 0, quant: qx[i]) / w[i] * scale * xScale
                                            let db = AdjustQuantBias.adjust(channel: 2, quant: qb[i]) / w[2 * count + i] * scale * bScale
                                            oy[i] = dy
                                            ox[i] = dx + xFromY * dy
                                            ob[i] = db + bFromY * dy
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    static func writeBlock(
        _ block: [Float], to plane: inout [Float], width: Int, height: Int, sourceStride: Int,
        outputStride: Int, x: Int, y: Int, transposed: Bool = false
    ) {
        precondition(block.count >= (transposed ? width : height) * sourceStride)
        precondition(x >= 0 && y >= 0 && x + width <= outputStride && (y + height) * outputStride <= plane.count)
        plane.withUnsafeMutableBufferPointer { destination in
            block.withUnsafeBufferPointer { source in
                for row in 0..<height {
                    let offset = (y + row) * outputStride + x
                    if transposed {
                        for column in 0..<width { destination[offset + column] = source[column * sourceStride + row] }
                    } else {
                        destination.baseAddress!.advanced(by: offset).update(
                            from: source.baseAddress!.advanced(by: row * sourceStride), count: width)
                    }
                }
            }
        }
    }
}
