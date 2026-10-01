// MDChannelDecoder — decodes one Modular channel with an MA tree and the
// entropy-coded residual stream (ISO/IEC 18181-1 C.7), reproducing the
// pixel-level semantics of the reference decoder
// (`DecodeModularChannelMAANS` in libjxl `modular/encoding/encoding.cc`):
// property vector layout (static properties, position, neighbours, the
// local-gradient quirk of property 8, FFV1 differences, the weighted
// predictor property and the per-channel reference properties), tree
// lookup, `UnpackSigned(token) * multiplier + offset + prediction` with
// 32-bit wrapping, and the weighted predictor state updates. Issue #2332.

import Foundation

enum MDChannelDecoderError: Error, Sendable, CustomStringConvertible {
    case token(x: Int, y: Int, channel: Int, inner: TokenStreamReaderError)
    case tree(String)

    var description: String {
        switch self {
        case .token(let x, let y, let channel, let inner):
            return "token at (\(x),\(y)) of channel \(channel): \(inner)"
        case .tree(let s): return "tree: \(s)"
        }
    }
}

/// Number of properties before the per-channel reference properties:
/// 2 static + y + x + 11 neighbour properties + 1 weighted property.
let mdNumNonRefProperties = 16
let mdExtraPropertiesPerChannel = 4

/// A flattened MA tree for pointer-based lookup.
struct MDFlatTree {
    struct Node {
        var property: Int32      // -1 for leaves
        var splitValue: Int32
        var left: Int32          // leaf: context (leaf id)
        var right: Int32
        var predictor: UInt32
        var multiplier: Int64
        var offset: Int64
    }

    let nodes: [Node]
    let usesWeighted: Bool
    let numProperties: Int
    let singleLeaf: Node?

    init(tree: ModularTree) throws {
        var maxProperty = -1
        var wp = false
        var flat: [Node] = []
        flat.reserveCapacity(tree.nodes.count)
        for node in tree.nodes {
            if node.isLeaf {
                if node.rawPredictor == 6 { wp = true }
                flat.append(Node(property: -1, splitValue: 0, left: Int32(node.leafId), right: 0,
                                 predictor: node.rawPredictor, multiplier: Int64(node.multiplier), offset: node.predictorOffset))
            } else {
                guard node.leftChild < tree.nodes.count, node.rightChild < tree.nodes.count else {
                    throw MDChannelDecoderError.tree("child index out of range")
                }
                maxProperty = max(maxProperty, Int(node.property))
                if node.property == 15 { wp = true }
                flat.append(Node(property: node.property, splitValue: node.splitVal, left: Int32(node.leftChild),
                                 right: Int32(node.rightChild), predictor: 0, multiplier: 1, offset: 0))
            }
        }
        nodes = flat
        usesWeighted = wp
        numProperties = max(mdNumNonRefProperties, maxProperty + 1)
        singleLeaf = (flat.count == 1 && flat[0].property < 0) ? flat[0] : nil
    }
}

/// Decodes channel `channelIndex` of `image` in place.
func mdDecodeChannel(
    image: inout ModularImage, channelIndex: Int, groupId: Int,
    tree: MDFlatTree,
    stream: inout TokenStreamReader, reader: inout BitReader,
    wpHeader: WeightedPredictorHeader
) throws {
    let width = image.channels[channelIndex].width
    let height = image.channels[channelIndex].height
    if width == 0 || height == 0 { return }

    // References (previous channels with the same geometry) feed the extra
    // properties; the reference decoder computes them per row.
    let numExtra = tree.numProperties - mdNumNonRefProperties
    var referenceChannels: [Int] = []
    if numExtra > 0 {
        let me = image.channels[channelIndex]
        var j = channelIndex - 1
        while j >= 0 && referenceChannels.count * mdExtraPropertiesPerChannel < numExtra {
            let other = image.channels[j]
            if other.width == me.width && other.height == me.height
                && other.hshift == me.hshift && other.vshift == me.vshift {
                referenceChannels.append(j)
            }
            j -= 1
        }
    }
    let refStride = max(numExtra, referenceChannels.count * mdExtraPropertiesPerChannel)
    var refs = [Int32](repeating: 0, count: refStride > 0 ? refStride * width : 0)

    var pixels = image.channels[channelIndex].pixels

    // Fast tracks of the reference decoder (identical results, fewer
    // property computations).
    if let leaf = tree.singleLeaf {
        let context = Int(leaf.left)
        if leaf.predictor == 0 {
            try pixels.withUnsafeMutableBufferPointer { buf in
                for i in 0..<(width * height) {
                    let token = try mdReadToken(&stream, context, &reader, i % width, i / width, channelIndex)
                    buf[i] = Int32(truncatingIfNeeded: mdUnpackSigned(token) &* leaf.multiplier &+ leaf.offset)
                }
            }
            image.channels[channelIndex].pixels = pixels
            return
        }
        if leaf.predictor == 5 && leaf.offset == 0 && leaf.multiplier == 1 {
            try pixels.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                for y in 0..<height {
                    let row = base + y * width
                    let prev = y > 0 ? UnsafePointer(base + (y - 1) * width) : nil
                    for x in 0..<width {
                        let left: Int64 = x > 0 ? Int64(row[x - 1]) : (prev.map { Int64($0[x]) } ?? 0)
                        let top: Int64 = prev.map { Int64($0[x]) } ?? left
                        let topLeft: Int64 = (x > 0 && prev != nil) ? Int64(prev![x - 1]) : left
                        let guess = mdClampedGradient(top, left, topLeft)
                        let token = try mdReadToken(&stream, context, &reader, x, y, channelIndex)
                        row[x] = Int32(truncatingIfNeeded: mdUnpackSigned(token) &+ guess)
                    }
                }
            }
            image.channels[channelIndex].pixels = pixels
            return
        }
    }

    // General path.
    let referenceSnapshots = referenceChannels.map { image.channels[$0].pixels }
    var props = [Int32](repeating: 0, count: tree.numProperties)
    props[0] = Int32(truncatingIfNeeded: channelIndex)
    props[1] = Int32(truncatingIfNeeded: groupId)
    var wp = tree.usesWeighted ? MDWeightedPredictor(header: wpHeader, xsize: width) : nil
    let usesWeighted = tree.usesWeighted
    try tree.nodes.withUnsafeBufferPointer { nodes in
        try props.withUnsafeMutableBufferPointer { p in
            try pixels.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                for y in 0..<height {
                    if !referenceChannels.isEmpty {
                        mdPrecomputeReferences(into: &refs, stride: refStride, width: width, y: y, snapshots: referenceSnapshots)
                    }
                    p[2] = Int32(truncatingIfNeeded: y)
                    p[9] = 0
                    let row = base + y * width
                    let prev = y > 0 ? UnsafePointer(base + (y - 1) * width) : nil
                    let prev2 = y > 1 ? UnsafePointer(base + (y - 2) * width) : nil
                    for x in 0..<width {
                        let n = MDNeighbourhood(x: x, y: y, width: width, row: UnsafePointer(row), prevRow: prev, prevPrevRow: prev2)
                        p[3] = Int32(truncatingIfNeeded: x)
                        p[4] = Int32(truncatingIfNeeded: n.top > 0 ? n.top : -n.top)
                        p[5] = Int32(truncatingIfNeeded: n.left > 0 ? n.left : -n.left)
                        p[6] = Int32(truncatingIfNeeded: n.top)
                        p[7] = Int32(truncatingIfNeeded: n.left)
                        p[8] = Int32(truncatingIfNeeded: n.left &- Int64(p[9]))
                        p[9] = Int32(truncatingIfNeeded: n.left &+ n.top &- n.topLeft)
                        p[10] = Int32(truncatingIfNeeded: n.left &- n.topLeft)
                        p[11] = Int32(truncatingIfNeeded: n.topLeft &- n.top)
                        p[12] = Int32(truncatingIfNeeded: n.top &- n.topRight)
                        p[13] = Int32(truncatingIfNeeded: n.top &- n.topTop)
                        p[14] = Int32(truncatingIfNeeded: n.left &- n.leftLeft)
                        var weighted: Int64 = 0
                        if usesWeighted {
                            var p15: Int32 = 0
                            weighted = wp!.predict(x: x, y: y, n: n.top, w: n.left, ne: n.topRight, nw: n.topLeft, nn: n.topTop, property15: &p15)
                            p[15] = p15
                        }
                        if numExtra > 0 {
                            let rb = x * refStride
                            for i in 0..<numExtra { p[16 + i] = refs[rb + i] }
                        }
                        var index = 0
                        while true {
                            let node = nodes[index]
                            if node.property < 0 { break }
                            index = p[Int(node.property)] > node.splitValue ? Int(node.left) : Int(node.right)
                        }
                        let leaf = nodes[index]
                        let token = try mdReadToken(&stream, Int(leaf.left), &reader, x, y, channelIndex)
                        let guess = leaf.offset &+ mdPredictOne(leaf.predictor, n, weighted: weighted)
                        let value = Int32(truncatingIfNeeded: mdUnpackSigned(token) &* leaf.multiplier &+ guess)
                        row[x] = value
                        if usesWeighted {
                            wp!.updateErrors(actual: Int64(value), x: x, y: y)
                        }
                    }
                }
            }
        }
    }
    image.channels[channelIndex].pixels = pixels
}

@inline(__always)
private func mdReadToken(
    _ stream: inout TokenStreamReader, _ context: Int, _ reader: inout BitReader,
    _ x: Int, _ y: Int, _ channel: Int
) throws -> UInt32 {
    do {
        return try stream.readToken(context: context, from: &reader)
    } catch let e as TokenStreamReaderError {
        throw MDChannelDecoderError.token(x: x, y: y, channel: channel, inner: e)
    }
}

/// `PrecomputeReferences`: for every reference channel, per column, the
/// magnitude and value of its sample and the magnitude and value of its
/// clamped-gradient residual.
private func mdPrecomputeReferences(
    into refs: inout [Int32], stride: Int, width: Int, y: Int, snapshots: [[Int32]]
) {
    for i in refs.indices { refs[i] = 0 }
    var offset = 0
    for snapshot in snapshots {
        snapshot.withUnsafeBufferPointer { s in
            let rpp = s.baseAddress! + y * width
            let rpprev = s.baseAddress! + (y > 0 ? y - 1 : 0) * width
            for x in 0..<width {
                let v = Int64(rpp[x])
                let vleft: Int64 = x > 0 ? Int64(rpp[x - 1]) : 0
                let vtop: Int64 = y > 0 ? Int64(rpprev[x]) : vleft
                let vtopleft: Int64 = (x > 0 && y > 0) ? Int64(rpprev[x - 1]) : vleft
                let predicted = mdClampedGradient(vleft, vtop, vtopleft)
                let rb = x * stride + offset
                refs[rb] = Int32(truncatingIfNeeded: abs(v))
                refs[rb + 1] = Int32(truncatingIfNeeded: v)
                refs[rb + 2] = Int32(truncatingIfNeeded: abs(v &- predicted))
                refs[rb + 3] = Int32(truncatingIfNeeded: v &- predicted)
            }
        }
        offset += mdExtraPropertiesPerChannel
    }
}
