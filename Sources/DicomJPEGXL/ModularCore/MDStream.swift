// MDStream — one Modular sub-bitstream (ISO/IEC 18181-1 C.4): group
// header, transform meta-application, MA tree selection (global or
// local), channel loop and the final ANS state check, with the channel
// ordering rules of the reference decoder (`ModularDecode` /
// `ModularGenericDecompress` in libjxl `modular/encoding/encoding.cc`).
// Issue #2332.

import Foundation

/// The global MA tree and its residual code, shared by sections that set
/// `use_global_tree`.
struct MDGlobalCode {
    let tree: ModularTree
    let flat: MDFlatTree
    let header: EntropySectionHeader
    let codebook: MultiClusterCodebook
}

/// `ModularOptions` of the reference decoder.
struct MDOptions {
    var maxChanSize: Int = 0xFF_FFFF
    var groupDim: Int = 0x1FFF_FFFF
}

enum MDStreamError: Error, Sendable, CustomStringConvertible {
    case groupHeader(String)
    case transform(MDTransformError)
    case tree(String)
    case entropy(String)
    case channelDimensions(String)
    case noGlobalTree
    case ansFinalState
    case channel(MDChannelDecoderError)

    var description: String {
        switch self {
        case .groupHeader(let s): return "group header: \(s)"
        case .transform(let e): return "transform: \(e)"
        case .tree(let s): return "MA tree: \(s)"
        case .entropy(let s): return "entropy code: \(s)"
        case .channelDimensions(let s): return "inconsistent channel dimensions: \(s)"
        case .noGlobalTree: return "section requests the global tree but none was coded"
        case .ansFinalState: return "ANS final state check failed"
        case .channel(let e): return "channel: \(e)"
        }
    }
}

/// `ValidateTree` of the reference decoder: bounded height and
/// consistent split ranges per property.
func mdValidateTree(_ tree: ModularTree) throws {
    let nodes = tree.nodes
    var numProperties = 0
    for node in nodes where !node.isLeaf {
        numProperties = max(numProperties, Int(node.property) + 1)
    }
    let rangeCount = max(1, numProperties).multipliedReportingOverflow(by: nodes.count)
    // Bound the validation scratch space independently of the coded tree size.
    guard !rangeCount.overflow, rangeCount.partialValue <= (64 << 20) / MemoryLayout<(Int32, Int32)>.stride else {
        throw MDStreamError.tree("split-range validation exceeds the 64 MiB limit")
    }
    var height = [Int](repeating: 0, count: nodes.count)
    var ranges = [(Int32, Int32)](repeating: (Int32.min, Int32.max), count: rangeCount.partialValue)
    for i in 0..<nodes.count {
        if height[i] > 2048 { throw MDStreamError.tree("tree too tall") }
        let node = nodes[i]
        if node.isLeaf { continue }
        let l = node.leftChild
        let r = node.rightChild
        guard l < nodes.count, r < nodes.count else { throw MDStreamError.tree("child index out of range") }
        height[l] = height[i] + 1
        height[r] = height[i] + 1
        for p in 0..<numProperties {
            if p == Int(node.property) {
                let (lo, hi) = ranges[i * numProperties + p]
                let val = node.splitVal
                if lo > val || hi <= val { throw MDStreamError.tree("invalid split range") }
                ranges[l * numProperties + p] = (val &+ 1, hi)
                ranges[r * numProperties + p] = (lo, val)
            } else {
                ranges[l * numProperties + p] = ranges[i * numProperties + p]
                ranges[r * numProperties + p] = ranges[i * numProperties + p]
            }
        }
    }
}

/// Decodes an MA tree and the residual code that follows it
/// (`DecodeTree` + `DecodeHistograms((tree.size() + 1) / 2)`).
func mdDecodeTreeAndCode(reader: inout BitReader, sizeLimit: Int) throws -> MDGlobalCode {
    let treeHeader: EntropySectionHeader
    let treeCodebook: MultiClusterCodebook
    do {
        treeHeader = try EntropySectionHeader.read(from: &reader, numContexts: 6)
        treeCodebook = try MultiClusterCodebook.read(from: &reader, header: treeHeader)
    } catch {
        throw MDStreamError.entropy("tree code: \(error)")
    }
    var treeStream = TokenStreamReader(header: treeHeader, codebook: treeCodebook)
    try treeStream.primeANSState(from: &reader)
    let tree: ModularTree
    do {
        tree = try ModularTree.decode(from: &reader, stream: &treeStream, treeSizeLimit: min(sizeLimit, 1 << 22))
    } catch {
        throw MDStreamError.tree("\(error)")
    }
    guard treeStream.ansFinalStateValid else { throw MDStreamError.ansFinalState }
    try mdValidateTree(tree)
    let postHeader: EntropySectionHeader
    let postCodebook: MultiClusterCodebook
    do {
        postHeader = try EntropySectionHeader.read(from: &reader, numContexts: (tree.nodes.count + 1) / 2)
        postCodebook = try MultiClusterCodebook.read(from: &reader, header: postHeader)
    } catch {
        throw MDStreamError.entropy("residual code: \(error)")
    }
    let flat: MDFlatTree
    do { flat = try MDFlatTree(tree: tree) } catch { throw MDStreamError.tree("\(error)") }
    return MDGlobalCode(tree: tree, flat: flat, header: postHeader, codebook: postCodebook)
}

/// `ValidateChannelDimensions` of the reference decoder.
func mdValidateChannelDimensions(_ image: ModularImage, options: MDOptions) throws {
    let n = image.channels.count
    for isDC in [true, false] {
        let groupDim = isDC ? options.groupDim &* 8 : options.groupDim
        var c = image.nbMetaChannels
        while c < n {
            let ch = image.channels[c]
            if ch.width > options.groupDim || ch.height > options.groupDim { break }
            c += 1
        }
        while c < n {
            let ch = image.channels[c]
            c += 1
            if ch.width == 0 || ch.height == 0 { continue }
            let isDCChannel = min(ch.hshift, ch.vshift) >= 3
            if isDCChannel != isDC { continue }
            let shift = max(ch.hshift, ch.vshift)
            let tileDim = shift >= 63 ? 0 : (groupDim >> shift)
            if tileDim == 0 {
                throw MDStreamError.channelDimensions("channel \(c - 1) shift \(shift) exceeds the group size")
            }
        }
    }
}

/// `ModularGenericDecompress`: decodes every channel of `image` that fits
/// the section (meta channels always, others up to `maxChanSize`), then
/// optionally undoes the section's transforms. Returns the group header
/// and the resolved transform list.
@discardableResult
func mdModularDecode(
    reader: inout BitReader, image: inout ModularImage, groupId: Int, options: MDOptions,
    global: MDGlobalCode?, bitDepth: Int, undoTransforms: Bool
) throws -> (header: GroupHeader, transforms: [ModularTransform]) {
    if image.channels.isEmpty { return (GroupHeader.default, []) }
    let header: GroupHeader
    do { header = try GroupHeader.read(from: &reader) } catch {
        throw MDStreamError.groupHeader("\(error)")
    }
    let transforms: [ModularTransform]
    do { transforms = try mdMetaApply(header.transforms, image: &image) } catch let e as MDTransformError {
        throw MDStreamError.transform(e)
    }
    try mdValidateChannelDimensions(image, options: options)

    let n = image.channels.count
    var numChans = 0
    var distanceMultiplier = 0
    var pixelBudget = 0
    for i in 0..<n {
        let ch = image.channels[i]
        if ch.width == 0 || ch.height == 0 { continue }
        if i >= image.nbMetaChannels && (ch.width > options.maxChanSize || ch.height > options.maxChanSize) { break }
        distanceMultiplier = max(distanceMultiplier, ch.width)
        pixelBudget += ch.width * ch.height
        numChans += 1
    }
    if numChans > 0 {
        let code: MDGlobalCode
        if header.useGlobalTree {
            guard let g = global, !g.tree.nodes.isEmpty else { throw MDStreamError.noGlobalTree }
            code = g
        } else {
            code = try mdDecodeTreeAndCode(reader: &reader, sizeLimit: min(1 << 20, 1024 + pixelBudget))
        }
        var stream = TokenStreamReader(header: code.header, codebook: code.codebook, distanceMultiplier: distanceMultiplier)
        try stream.primeANSState(from: &reader)
        for i in 0..<n {
            let ch = image.channels[i]
            if ch.width == 0 || ch.height == 0 { continue }
            if i >= image.nbMetaChannels && (ch.width > options.maxChanSize || ch.height > options.maxChanSize) { break }
            do {
                try mdDecodeChannel(
                    image: &image, channelIndex: i, groupId: groupId, tree: code.flat,
                    stream: &stream, reader: &reader, wpHeader: header.wpHeader
                )
            } catch let e as MDChannelDecoderError {
                throw MDStreamError.channel(e)
            }
        }
        guard stream.ansFinalStateValid else { throw MDStreamError.ansFinalState }
    }
    if undoTransforms {
        do {
            try mdUndoTransforms(transforms, image: &image, wpHeader: header.wpHeader, bitDepth: bitDepth)
        } catch let e as MDTransformError {
            throw MDStreamError.transform(e)
        }
    }
    return (header, transforms)
}
