// J2KTagTree.swift
// J2KCodec
//
// Tag tree coder for JPEG 2000 packet headers.
// ISO/IEC 15444-1:2019 Annex B.10.2


/// Tag tree coder for hierarchical encoding of code-block inclusion
/// and zero bit-plane information in JPEG 2000 packet headers.
///
/// Per ISO/IEC 15444-1 Annex B.10.2, a tag tree is a quad-tree where
/// each parent node stores the minimum value of its children. Encoding
/// proceeds from root to leaf, emitting:
/// - "0" bit: value at this node is greater than current low
/// - "1" bit: value at this node is at or below current low (value known)
///
/// The tree maintains state across calls for different leaves, allowing
/// efficient encoding when many leaves share the same parent path.
struct J2KTagTree: Sendable {
    private struct Node: Sendable {
        var value: Int32 = 999
        var low: Int32 = 0
        var known: Bool = false
        var parentIndex: Int = -1  // -1 = root (no parent)
    }

    private var nodes: [Node]
    private let leafWidth: Int
    private let leafHeight: Int

    /// Reusable scratch buffer for the root-to-leaf path traversed
    /// per `encode` / `decode` call. Tree depth is bounded by
    /// `ceil(log2(numLeaves))` (≤ ~12 for any practical precinct);
    /// pre-reserving avoids the per-call `[Int]` allocation that
    /// `rootToLeafPath` previously incurred. Capacity grows once on
    /// the first call and is held across all subsequent calls on
    /// this tree (one tree per band per packet → many encode calls
    /// per tree on production fixtures).
    private var pathScratch: [Int] = []

    /// Creates a tag tree for a grid of code blocks.
    ///
    /// - Parameters:
    ///   - width: Number of code blocks horizontally in the precinct.
    ///   - height: Number of code blocks vertically in the precinct.
    init(width: Int, height: Int) {
        leafWidth = width
        leafHeight = height

        guard width > 0 && height > 0 else {
            nodes = []
            return
        }

        // Calculate tree levels: each level halves dimensions until 1×1
        var levelWidths: [Int] = []
        var levelHeights: [Int] = []
        var w = width, h = height

        repeat {
            levelWidths.append(w)
            levelHeights.append(h)
            w = (w + 1) / 2
            h = (h + 1) / 2
        } while levelWidths.last! * levelHeights.last! > 1

        let numLevels = levelWidths.count

        // Calculate level offsets in the node array
        var levelOffsets: [Int] = [0]
        for i in 0..<numLevels {
            levelOffsets.append(levelOffsets[i] + levelWidths[i] * levelHeights[i])
        }
        let totalNodes = levelOffsets.last!

        // Initialize all nodes
        nodes = Array(repeating: Node(), count: totalNodes)

        // Set parent pointers: each 2×2 block of children maps to one parent
        for level in 0..<(numLevels - 1) {
            let childOffset = levelOffsets[level]
            let parentOffset = levelOffsets[level + 1]
            let cw = levelWidths[level]
            let ch = levelHeights[level]
            let pw = levelWidths[level + 1]

            for cy in 0..<ch {
                for cx in 0..<cw {
                    let childIdx = childOffset + cy * cw + cx
                    let parentIdx = parentOffset + (cy / 2) * pw + (cx / 2)
                    nodes[childIdx].parentIndex = parentIdx
                }
            }
        }
        // Root node keeps parentIndex = -1
    }

    /// Resets all node values to initial state (value=999, low=0, known=false).
    mutating func reset() {
        for i in nodes.indices {
            nodes[i].value = 999
            nodes[i].low = 0
            nodes[i].known = false
        }
    }

    /// Sets the value of a leaf node and propagates the minimum up the tree.
    ///
    /// - Parameters:
    ///   - leafIndex: Index of the leaf node (0..<width*height).
    ///   - value: The value to set (e.g., inclusion layer or IMSB count).
    mutating func setValue(leafIndex: Int, value: Int32) {
        guard leafIndex >= 0 && leafIndex < leafWidth * leafHeight else { return }
        var idx = leafIndex
        while idx >= 0 && nodes[idx].value > value {
            nodes[idx].value = value
            idx = nodes[idx].parentIndex
        }
    }

    /// Encodes a tag tree value for the given leaf node.
    ///
    /// Traverses from root to leaf, emitting bits at each node per
    /// ISO/IEC 15444-1 B.10.2 and OpenJPEG's `opj_tgt_encode()`:
    /// - "0" bits while the current low has not reached the node's value
    /// - "1" bit when the node's value is reached (first time only via `known` flag)
    ///
    /// The decoder mirrors this: at each node it reads bits until either
    /// the threshold is reached (giving up) or a "1" is read (value discovered).
    ///
    /// - Parameters:
    ///   - writer: Bit writer to emit bits to.
    ///   - leafIndex: Index of the leaf node.
    ///   - threshold: Maximum value to encode up to.
    mutating func encode(writer: inout J2KBitWriter, leafIndex: Int, threshold: Int32) {
        guard leafIndex >= 0 && leafIndex < leafWidth * leafHeight,
              !nodes.isEmpty else { return }

        // Build root-to-leaf path into the reusable scratch buffer.
        // Equivalent to `let path = rootToLeafPath(leafIndex)` but
        // without the per-call `[Int]` allocation.
        pathScratch.removeAll(keepingCapacity: true)
        var pIdx = leafIndex
        while pIdx >= 0 {
            pathScratch.append(pIdx)
            pIdx = nodes[pIdx].parentIndex
        }
        pathScratch.reverse()
        var low: Int32 = 0

        for nodeIdx in pathScratch {
            if low > nodes[nodeIdx].low {
                nodes[nodeIdx].low = low
            } else {
                low = nodes[nodeIdx].low
            }

            while low < threshold {
                if low >= nodes[nodeIdx].value {
                    // Value reached — output "1" if first time at this node
                    if !nodes[nodeIdx].known {
                        writer.writeBit(true)
                        nodes[nodeIdx].known = true
                    }
                    break
                }
                // Value not yet reached — output "0"
                writer.writeBit(false)
                low += 1
            }

            nodes[nodeIdx].low = low
        }
    }

    /// Decodes a tag tree value for the given leaf node.
    ///
    /// Traverses from root to leaf, reading bits at each node to discover
    /// whether the leaf value is less than the threshold.
    ///
    /// - Parameters:
    ///   - reader: Bit reader to read bits from.
    ///   - leafIndex: Index of the leaf node.
    ///   - threshold: The threshold to test against.
    /// - Returns: `true` if the leaf value is less than threshold.
    mutating func decode(reader: inout J2KBitReader, leafIndex: Int, threshold: Int32) throws -> Bool {
        guard leafIndex >= 0 && leafIndex < leafWidth * leafHeight,
              !nodes.isEmpty else { return false }

        // Build root-to-leaf path into the reusable scratch buffer
        // (same allocation-free pattern as `encode`).
        pathScratch.removeAll(keepingCapacity: true)
        var pIdx = leafIndex
        while pIdx >= 0 {
            pathScratch.append(pIdx)
            pIdx = nodes[pIdx].parentIndex
        }
        pathScratch.reverse()

        var low: Int32 = 0

        for nodeIdx in pathScratch {
            if low > nodes[nodeIdx].low {
                nodes[nodeIdx].low = low
            } else {
                low = nodes[nodeIdx].low
            }

            while low < threshold && low < nodes[nodeIdx].value {
                if try reader.readBit() {
                    nodes[nodeIdx].value = low
                } else {
                    low += 1
                }
            }

            nodes[nodeIdx].low = low
        }

        return nodes[pathScratch.last!].value < threshold
    }
}
