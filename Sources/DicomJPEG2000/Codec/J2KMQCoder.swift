//
// J2KMQCoder.swift
// J2KSwift
//
/// # MQ-Coder
///
/// Implementation of the MQ arithmetic coder used in JPEG 2000 entropy coding.
///
/// The MQ-coder is a context-adaptive binary arithmetic coder used in JPEG 2000's
/// EBCOT (Embedded Block Coding with Optimised Truncation) algorithm. It provides
/// efficient compression by adapting probability estimates based on context.

import Foundation

// MARK: - Termination Mode

/// Termination modes for MQ-coder encoding.
///
/// The JPEG 2000 standard defines different termination modes that control
/// how the arithmetic coder terminates its output. Different modes offer
/// trade-offs between compression efficiency and decoder complexity.
enum TerminationMode: Sendable, Equatable, Hashable {
    /// Default termination mode.
    ///
    /// Uses the standard JPEG 2000 termination sequence. This mode is most
    /// common and provides a good balance between compression and simplicity.
    case `default`

    /// Predictable termination mode.
    ///
    /// Also known as "termination on each coding pass" or RESET mode.
    /// Each coding pass produces a valid codestream segment that can be
    /// independently decoded. This mode enables error resilience and
    /// parallel decoding but reduces compression efficiency.
    ///
    /// When enabled, the encoder resets after each coding pass, and the
    /// output can be truncated at any coding pass boundary.
    case predictable

    /// Near-optimal termination mode.
    ///
    /// Uses a tighter termination sequence that minimises wasted bits,
    /// producing better compression efficiency. The decoder must support
    /// this mode to properly handle the shorter termination sequence.
    ///
    /// This mode writes only the minimum number of bytes needed to
    /// ensure correct decoding.
    case nearOptimal
}

// MARK: - MQ State Table

/// Represents a single entry in the MQ-coder probability estimation table.
struct MQState: Sendable, Equatable {
    /// The probability estimate for the less probable symbol (Qe value).
    let qe: UInt32

    /// The next state index after encoding/decoding the most probable symbol (MPS).
    let nextMPS: Int

    /// The next state index after encoding/decoding the least probable symbol (LPS).
    let nextLPS: Int

    /// Whether to switch the MPS sense after an LPS event.
    let switchMPS: Bool
}

/// The MQ-coder probability estimation state table (47 states).
///
/// This table defines the finite state machine (FSM) for adaptive binary arithmetic coding
/// in JPEG 2000. Each state represents a probability estimate for the Less Probable Symbol (LPS)
/// and specifies transitions to other states based on whether an MPS or LPS is coded.
///
/// The table is defined by the JPEG 2000 standard (ISO/IEC 15444-1, Annex D.3.5) and must
/// be used exactly as specified for standards compliance.
///
/// Each `MQState` entry contains:
/// - `qe`: Probability estimate for the LPS (Q_e value)
/// - `nextMPS`: Next state index if an MPS is coded
/// - `nextLPS`: Next state index if an LPS is coded
/// - `switchMPS`: Whether to invert the MPS sense after an LPS
///
/// Usage:
/// ```swift
/// let state = mqStateTable[contextIndex]
/// let probability = state.qe
/// ```
let mqStateTable: [MQState] = [
    MQState(qe: 0x5601, nextMPS: 1, nextLPS: 1, switchMPS: true),
    MQState(qe: 0x3401, nextMPS: 2, nextLPS: 6, switchMPS: false),
    MQState(qe: 0x1801, nextMPS: 3, nextLPS: 9, switchMPS: false),
    MQState(qe: 0x0AC1, nextMPS: 4, nextLPS: 12, switchMPS: false),
    MQState(qe: 0x0521, nextMPS: 5, nextLPS: 29, switchMPS: false),
    MQState(qe: 0x0221, nextMPS: 38, nextLPS: 33, switchMPS: false),
    MQState(qe: 0x5601, nextMPS: 7, nextLPS: 6, switchMPS: true),
    MQState(qe: 0x5401, nextMPS: 8, nextLPS: 14, switchMPS: false),
    MQState(qe: 0x4801, nextMPS: 9, nextLPS: 14, switchMPS: false),
    MQState(qe: 0x3801, nextMPS: 10, nextLPS: 14, switchMPS: false),
    MQState(qe: 0x3001, nextMPS: 11, nextLPS: 17, switchMPS: false),
    MQState(qe: 0x2401, nextMPS: 12, nextLPS: 18, switchMPS: false),
    MQState(qe: 0x1C01, nextMPS: 13, nextLPS: 20, switchMPS: false),
    MQState(qe: 0x1601, nextMPS: 29, nextLPS: 21, switchMPS: false),
    MQState(qe: 0x5601, nextMPS: 15, nextLPS: 14, switchMPS: true),
    MQState(qe: 0x5401, nextMPS: 16, nextLPS: 14, switchMPS: false),
    MQState(qe: 0x5101, nextMPS: 17, nextLPS: 15, switchMPS: false),
    MQState(qe: 0x4801, nextMPS: 18, nextLPS: 16, switchMPS: false),
    MQState(qe: 0x3801, nextMPS: 19, nextLPS: 17, switchMPS: false),
    MQState(qe: 0x3401, nextMPS: 20, nextLPS: 18, switchMPS: false),
    MQState(qe: 0x3001, nextMPS: 21, nextLPS: 19, switchMPS: false),
    MQState(qe: 0x2801, nextMPS: 22, nextLPS: 19, switchMPS: false),
    MQState(qe: 0x2401, nextMPS: 23, nextLPS: 20, switchMPS: false),
    MQState(qe: 0x2201, nextMPS: 24, nextLPS: 21, switchMPS: false),
    MQState(qe: 0x1C01, nextMPS: 25, nextLPS: 22, switchMPS: false),
    MQState(qe: 0x1801, nextMPS: 26, nextLPS: 23, switchMPS: false),
    MQState(qe: 0x1601, nextMPS: 27, nextLPS: 24, switchMPS: false),
    MQState(qe: 0x1401, nextMPS: 28, nextLPS: 25, switchMPS: false),
    MQState(qe: 0x1201, nextMPS: 29, nextLPS: 26, switchMPS: false),
    MQState(qe: 0x1101, nextMPS: 30, nextLPS: 27, switchMPS: false),
    MQState(qe: 0x0AC1, nextMPS: 31, nextLPS: 28, switchMPS: false),
    MQState(qe: 0x09C1, nextMPS: 32, nextLPS: 29, switchMPS: false),
    MQState(qe: 0x08A1, nextMPS: 33, nextLPS: 30, switchMPS: false),
    MQState(qe: 0x0521, nextMPS: 34, nextLPS: 31, switchMPS: false),
    MQState(qe: 0x0441, nextMPS: 35, nextLPS: 32, switchMPS: false),
    MQState(qe: 0x02A1, nextMPS: 36, nextLPS: 33, switchMPS: false),
    MQState(qe: 0x0221, nextMPS: 37, nextLPS: 34, switchMPS: false),
    MQState(qe: 0x0141, nextMPS: 38, nextLPS: 35, switchMPS: false),
    MQState(qe: 0x0111, nextMPS: 39, nextLPS: 36, switchMPS: false),
    MQState(qe: 0x0085, nextMPS: 40, nextLPS: 37, switchMPS: false),
    MQState(qe: 0x0049, nextMPS: 41, nextLPS: 38, switchMPS: false),
    MQState(qe: 0x0025, nextMPS: 42, nextLPS: 39, switchMPS: false),
    MQState(qe: 0x0015, nextMPS: 43, nextLPS: 40, switchMPS: false),
    MQState(qe: 0x0009, nextMPS: 44, nextLPS: 41, switchMPS: false),
    MQState(qe: 0x0005, nextMPS: 45, nextLPS: 42, switchMPS: false),
    MQState(qe: 0x0001, nextMPS: 45, nextLPS: 43, switchMPS: false),
    MQState(qe: 0x5601, nextMPS: 46, nextLPS: 46, switchMPS: false)
]

// MARK: - Flat MQ State Arrays (Performance)

/// Flat parallel arrays for the MQ state table.
///
/// These avoid struct copies in the critical encode/decode hot paths.
/// Each array is indexed by state index (0-46). Using `UInt16` for Qe
/// (upper 16 bits of the 32-bit value are zero) and `UInt8` for indices
/// maximises L1 cache utilisation.
///
/// Kept for callers outside the per-symbol hot path (initialisation,
/// debug trace). Inside `MQDecoder.decode` / `MQEncoder.encode` we use
/// `mqStatePacked` below — one load per symbol instead of three or four.
let mqQe: [UInt32] = mqStateTable.map { $0.qe }
let mqNextMPS: [UInt8] = mqStateTable.map { UInt8($0.nextMPS) }
let mqNextLPS: [UInt8] = mqStateTable.map { UInt8($0.nextLPS) }
let mqSwitchMPS: [UInt8] = mqStateTable.map { $0.switchMPS ? 1 : 0 }

/// Packed MQ state lookup. One `UInt32` per state index encodes:
///
/// - bits  0–15: `qe` (16-bit probability estimate)
/// - bits 16–21: `nextMPS` (state to transition to after MPS coding)
/// - bits 22–27: `nextLPS` (state to transition to after LPS coding)
/// - bit  28   : `switchMPS` (toggle context.mps after LPS)
/// - bits 29–31: unused / reserved (zero)
///
/// In the per-symbol hot path the previous design did up to 4 separate
/// table loads (`mqQe[si]`, `mqNextMPS[si]`, `mqNextLPS[si]`,
/// `mqSwitchMPS[si]`) — each potentially crossing a different cache
/// line. With 47 states packed into 188 contiguous bytes (3 cache
/// lines), one `mqStatePacked[si]` load gives us everything any branch
/// of `decode` / `encode` needs and lets the Swift optimiser keep the
/// extracted fields in registers.
@usableFromInline let mqStatePacked: [UInt32] = mqStateTable.map { s in
    let qe = s.qe & 0xFFFF
    let nMPS = UInt32(s.nextMPS) & 0x3F
    let nLPS = UInt32(s.nextLPS) & 0x3F
    let sw   = s.switchMPS ? UInt32(1) : 0
    return qe | (nMPS << 16) | (nLPS << 22) | (sw << 28)
}

/// Bit positions inside `mqStatePacked` entries (kept as constants so
/// the decoder/encoder hot paths read clearly without literal noise).
@usableFromInline let mqQeMask: UInt32      = 0xFFFF
@usableFromInline let mqNextMPSShift: Int   = 16
@usableFromInline let mqNextLPSShift: Int   = 22
@usableFromInline let mqStateMask: UInt32   = 0x3F
@usableFromInline let mqSwitchMPSBit: UInt32 = 1 << 28

// MARK: - MQ Context

/// Represents a context used by the MQ-coder.
///
/// Stored as 2 bytes (UInt8 stateIndex + Bool mps) so that ContextStateArray's
/// 19-element inline tuple fits in 38 bytes — one cache line — eliminating the
/// heap allocation and pointer-chasing cost of the former [MQContext] array.
struct MQContext: Sendable {
    /// The current index into the state table (0–46).
    var stateIndex: UInt8

    /// The current most probable symbol (0 or 1).
    var mps: Bool

    init(stateIndex: UInt8 = 0, mps: Bool = false) {
        self.stateIndex = stateIndex
        self.mps = mps
    }

    /// Int overload retained for call sites that pass integer literals.
    init(stateIndex: Int, mps: Bool = false) {
        self.stateIndex = UInt8(stateIndex)
        self.mps = mps
    }

    var state: MQState { mqStateTable[Int(stateIndex)] }
    var qe: UInt32 { state.qe }
}

// MARK: - Fast Output Buffer

/// ARC-managed byte buffer for MQ encoder output.
///
/// Eliminates per-append CoW uniqueness checks by using a raw pointer
/// with manual count tracking. The `final class` ensures ARC-based
/// deallocation and allows `@inline(__always)` on methods (no vtable).
///
/// Benchmarks show ~15-20% improvement in MQ encoding throughput
/// over `[UInt8].append()` due to eliminating the per-byte CoW check.
final class MQOutputBuffer {
    private var storage: UnsafeMutablePointer<UInt8>
    private(set) var count: Int = 0
    private var capacity: Int

    init(capacity: Int = 1024) {
        self.capacity = capacity
        self.storage = .allocate(capacity: capacity)
    }

    deinit {
        storage.deallocate()
    }

    @inline(__always)
    func append(_ byte: UInt8) {
        if count >= capacity {
            grow()
        }
        storage[count] = byte
        count &+= 1
    }

    @inline(never)
    private func grow() {
        let newCapacity = capacity &* 2
        let newStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        newStorage.update(from: storage, count: count)
        storage.deallocate()
        storage = newStorage
        capacity = newCapacity
    }

    /// Copies current buffer contents into a new [UInt8] array.
    func toArray() -> [UInt8] {
        Array(UnsafeBufferPointer(start: storage, count: count))
    }

    /// Creates Data from the current buffer contents (zero-copy when possible).
    func toData() -> Data {
        Data(UnsafeBufferPointer(start: storage, count: count))
    }

    /// Copies the first `n` bytes into a new [UInt8] array.
    func prefix(_ n: Int) -> [UInt8] {
        let len = min(n, count)
        return Array(UnsafeBufferPointer(start: storage, count: len))
    }

    /// Removes trailing bytes matching `byte`.
    func removeTrailing(_ byte: UInt8) {
        while count > 0 && storage[count &- 1] == byte {
            count &-= 1
        }
    }

    /// Subscript access for reading.
    @inline(__always)
    subscript(index: Int) -> UInt8 {
        storage[index]
    }

    /// Resets count without deallocating.
    func reset() {
        count = 0
    }
}

// MARK: - MQ Encoder

/// Encodes binary symbols using the MQ arithmetic coding algorithm.
struct MQEncoder {
    // MARK: - Constants

    /// Initial counter value for the MQ-coder (number of bits before first byte output).
    /// This is defined by the JPEG 2000 standard (ISO/IEC 15444-1 Annex C).
    private static let initialCounterBits = 12

    /// Stuffing byte used after 0xFF to avoid marker conflicts in JPEG 2000.
    /// A 0x7F ensures that the next byte doesn't start with 0x90 or higher.
    private static let stuffingByte: UInt8 = 0x7F

    // MARK: - State

    private var c: UInt32 = 0
    private var a: UInt32 = 0x8000
    private var ct: Int = initialCounterBits
    private var buffer: Int = -1

    /// Pre-allocated output buffer using ARC-managed raw pointer.
    /// Eliminates per-byte CoW uniqueness checks in the hot emitByte path.
    private let output: MQOutputBuffer

    /// Debug access to internal state for trace verification
    var debugA: UInt32 { a }
    var debugC: UInt32 { c }
    var debugCT: Int { ct }
    var debugBuffer: Int { buffer }
    var debugOutputCount: Int { output.count }

    /// The current number of output bytes flushed so far (approximate byte position).
    ///
    /// This is used by rate control to estimate per-pass byte boundaries
    /// without requiring full MQ termination after each pass.
    var currentByteCount: Int { output.count + (buffer >= 0 ? 1 : 0) }

    /// The raw output bytes emitted so far (before termination).
    ///
    /// Returns a copy of the internal output array. Bytes in this array
    /// are finalized — subsequent encoding never modifies them (carries
    /// only propagate into the ``buffer`` register).
    var currentOutput: [UInt8] {
        output.toArray()
    }

    // MARK: - Lightweight Checkpoints

    /// A lightweight snapshot of the MQ encoder state at a coding pass boundary.
    ///
    /// Copies of an encoder share its mutable output buffer;
    /// a checkpoint stores only the 5 scalar state values needed to reconstruct
    /// the terminated byte stream later. The `output` array is shared — bytes
    /// already emitted to `output` are never modified by future encoding
    /// (carries only propagate into `buffer`, not into `output`).
    struct Checkpoint: Sendable {
        let outputCount: Int
        let a: UInt32
        let c: UInt32
        let ct: Int
        let buffer: Int
    }

    /// Creates a lightweight checkpoint of the current encoder state.
    ///
    /// The checkpoint captures the encoder's register state and the current
    /// output position. Combined with the final `output` array (shared across
    /// all checkpoints for a block), this is sufficient to reconstruct the
    /// exact terminated byte stream at this pass boundary.
    ///
    /// This stores only scalar registers and the output count, without retaining the encoder buffer.
    func checkpoint() -> Checkpoint {
        Checkpoint(outputCount: output.count, a: a, c: c, ct: ct, buffer: buffer)
    }

    /// Reconstructs the terminated byte stream at a checkpoint boundary.
    ///
    /// Takes the output bytes up to `checkpoint.outputCount` from the shared
    /// output array, then applies the MQ termination procedure using the
    /// saved register state.
    ///
    /// - Parameters:
    ///   - checkpoint: The checkpoint captured at the desired pass boundary.
    ///   - mode: The termination mode to use.
    /// - Returns: The exact terminated byte stream at the checkpoint boundary.
    func finishFromCheckpoint(_ checkpoint: Checkpoint, mode: TerminationMode) -> Data {
        // Start with the output bytes that were finalized at checkpoint time
        var prefixOutput = output.prefix(checkpoint.outputCount)

        // Create a minimal encoder with checkpoint state and apply termination
        var tempC = checkpoint.c
        let tempA = checkpoint.a
        var tempCT = checkpoint.ct
        var tempBuffer = checkpoint.buffer

        // SETBITS procedure (same as finishDefault)
        let tempCPlusA = tempC &+ UInt32(tempA)
        tempC = tempC | 0x0000FFFF
        if tempC >= tempCPlusA {
            tempC -= 0x8000
        }

        // BYTEOUT twice
        tempC <<= tempCT
        Self.emitByteStatic(c: &tempC, ct: &tempCT, buffer: &tempBuffer, output: &prefixOutput)
        tempC <<= tempCT
        Self.emitByteStatic(c: &tempC, ct: &tempCT, buffer: &tempBuffer, output: &prefixOutput)

        // Emit final buffer byte
        if tempBuffer >= 0 && tempBuffer != 0xFF {
            prefixOutput.append(UInt8(tempBuffer & 0xFF))
        }

        // Drop trailing 0xFF
        while let last = prefixOutput.last, last == 0xFF {
            prefixOutput.removeLast()
        }

        return Data(prefixOutput)
    }

    /// Reconstructs terminated MQ data from a checkpoint and raw output.
    ///
    /// This is the cross-module entry point used by the encoder pipeline
    /// during PCRD truncation. It takes ``MQCheckpointData`` (from J2KCore)
    /// and the raw MQ output array, and applies the default termination
    /// procedure to produce the exact byte stream at the checkpoint boundary.
    ///
    /// - Parameters:
    ///   - checkpoint: The checkpoint data from the code block.
    ///   - rawOutput: The raw MQ output bytes (shared across all checkpoints).
    /// - Returns: The terminated MQ byte stream at the checkpoint boundary.
    static func reconstructFromCheckpoint(
        _ checkpoint: MQCheckpointData,
        rawOutput: [UInt8]
    ) -> Data {
        let count = min(checkpoint.outputCount, rawOutput.count)
        var prefixOutput = Array(rawOutput.prefix(count))

        var tempC = checkpoint.c
        let tempA = checkpoint.a
        var tempCT = checkpoint.ct
        var tempBuffer = checkpoint.buffer

        // SETBITS
        let tempCPlusA = tempC &+ UInt32(tempA)
        tempC = tempC | 0x0000FFFF
        if tempC >= tempCPlusA {
            tempC -= 0x8000
        }

        // BYTEOUT twice
        tempC <<= tempCT
        emitByteStatic(c: &tempC, ct: &tempCT, buffer: &tempBuffer, output: &prefixOutput)
        tempC <<= tempCT
        emitByteStatic(c: &tempC, ct: &tempCT, buffer: &tempBuffer, output: &prefixOutput)

        if tempBuffer >= 0 && tempBuffer != 0xFF {
            prefixOutput.append(UInt8(tempBuffer & 0xFF))
        }

        while let last = prefixOutput.last, last == 0xFF {
            prefixOutput.removeLast()
        }

        return Data(prefixOutput)
    }

    /// Static version of emitByte for checkpoint reconstruction.
    private static func emitByteStatic(
        c: inout UInt32, ct: inout Int, buffer: inout Int, output: inout [UInt8]
    ) {
        if buffer >= 0 {
            if buffer == 0xFF {
                output.append(0xFF)
                buffer = Int((c >> 20) & 0xFF)
                c &= 0x000FFFFF
                ct = 7
            } else {
                buffer += Int(c >> 27)
                c &= 0x07FFFFFF
                output.append(UInt8(buffer & 0xFF))
                if buffer == 0xFF {
                    buffer = Int((c >> 20) & 0xFF)
                    c &= 0x000FFFFF
                    ct = 7
                } else {
                    buffer = Int((c >> 19) & 0xFF)
                    c &= 0x0007FFFF
                    ct = 8
                }
            }
        } else {
            c &= 0x07FFFFFF
            buffer = Int((c >> 19) & 0xFF)
            c &= 0x0007FFFF
            ct = 8
        }
    }

    /// Debug operation counter
    var operationCount: Int = 0

    /// Creates a new MQ encoder.
    init() {
        output = MQOutputBuffer(capacity: 1024)
    }

    /// Creates a new MQ encoder with the specified capacity hint.
    ///
    /// Use this initializer when you have an estimate of the output size
    /// to avoid memory reallocations during encoding.
    ///
    /// - Parameter estimatedSize: Estimated output size in bytes.
    init(estimatedSize: Int) {
        output = MQOutputBuffer(capacity: max(estimatedSize, 256))
    }

    /// Encodes a binary symbol using the specified context.
    ///
    /// Implements ISO 15444-1 C.2.4 (CODEMPS) and C.2.6 (CODELPS).
    /// Uses flat state arrays to avoid struct copies in the critical path.
    @inline(__always)
    mutating func encode(symbol: Bool, context: inout MQContext) {
        #if EBCOT_DEBUG_TRACE
        do {
            operationCount += 1
            let preA = a
            let preC = c
            let preCtxState = Int(context.stateIndex)
            if EBCOTDebugTrace.shared.enabled {
                EBCOTDebugTrace.shared.encoderSymbols.append(
                    (operationCount, preCtxState, symbol, preA, UInt32(EBCOTDebugTrace.shared.currentContextLabel), preC)
                )
            }
        }
        #endif
        let si = Int(context.stateIndex)
        // Same single-load packed lookup as MQDecoder.decode — see
        // `mqStatePacked` for the bit layout.
        let entry = mqStatePacked[si]
        let qe = entry & mqQeMask

        a -= qe

        if symbol == context.mps {
            // CODEMPS (ISO 15444-1 C.2.4)
            if (a & 0x8000) == 0 {
                if a < qe {
                    // Conditional exchange
                    a = qe
                } else {
                    c += qe
                }
                context.stateIndex = UInt8((entry >> mqNextMPSShift) & mqStateMask)
                renormalize()
            } else {
                c += qe
            }
        } else {
            // CODELPS (ISO 15444-1 C.2.6)
            if a < qe {
                // Conditional exchange
                c += qe
            } else {
                a = qe
            }
            if (entry & mqSwitchMPSBit) != 0 {
                context.mps.toggle()
            }
            context.stateIndex = UInt8((entry >> mqNextLPSShift) & mqStateMask)
            renormalize()
        }
    }

    /// Prepares the encoder for bypass mode.
    ///
    /// This method ensures a clean transition from MQ coding to raw bypass coding.
    /// The interval register is set to the full interval and remaining bits are flushed.
    @inline(__always)
    mutating func prepareForBypass() {
        a = 0x8000
    }

    /// Encodes a symbol using uniform (bypass) coding.
    ///
    /// In bypass mode, raw bits are packed using the MQ coder's byte output mechanism.
    @inline(__always)
    mutating func encodeBypass(symbol: Bool) {
        c <<= 1
        if symbol {
            c += 0x8000
        }
        ct -= 1
        if ct == 0 {
            emitByte()
        }
    }

    /// Renormalizes the encoder state.
    @inline(__always)
    private mutating func renormalize() {
        guard a < 0x8000 else { return }
        let shifts = a.leadingZeroBitCount - 16  // exact left-shifts to reach a >= 0x8000
        if ct >= shifts {
            a <<= shifts; c <<= shifts; ct -= shifts
            if ct == 0 { emitByte() }
        } else {
            while a < 0x8000 {
                a <<= 1; c <<= 1; ct -= 1
                if ct == 0 { emitByte() }
            }
        }
    }

    /// Emits a byte to the output.
    ///
    /// Implements the BYTEOUT procedure per ISO/IEC 15444-1 Annex C.2.8.
    /// Uses ARC-managed MQOutputBuffer for zero-CoW-overhead writes.
    private mutating func emitByte() {
        if buffer >= 0 {
            if buffer == 0xFF {
                // Buffer was already 0xFF — emit it and enter 7-bit mode.
                output.append(0xFF)
                buffer = Int((c >> 20) & 0xFF)
                c &= 0x000FFFFF
                ct = 7
            } else {
                // Add carry bit to buffer
                buffer += Int(c >> 27)
                c &= 0x07FFFFFF
                // Emit the buffer byte
                output.append(UInt8(buffer & 0xFF))
                // Per ISO 15444-1 C.2.8: if carry made buffer 0xFF,
                // enter 7-bit mode for the next byte.
                if buffer == 0xFF {
                    buffer = Int((c >> 20) & 0xFF)
                    c &= 0x000FFFFF
                    ct = 7
                } else {
                    buffer = Int((c >> 19) & 0xFF)
                    c &= 0x0007FFFF
                    ct = 8
                }
            }
        } else {
            // First byte — no previous byte to carry into.
            // Clear carry (equivalent to OpenJPEG's dummy byte absorbing it).
            c &= 0x07FFFFFF
            buffer = Int((c >> 19) & 0xFF)
            c &= 0x0007FFFF
            ct = 8
        }
    }

    /// Finishes encoding and returns the compressed data.
    mutating func finish() -> Data {
        finish(mode: .default)
    }

    /// Finishes encoding with the specified termination mode.
    ///
    /// - Parameter mode: The termination mode to use.
    /// - Returns: The encoded data.
    mutating func finish(mode: TerminationMode) -> Data {
        switch mode {
        case .default:
            return finishDefault()
        case .predictable:
            return finishPredictable()
        case .nearOptimal:
            return finishNearOptimal()
        }
    }

    /// Default termination - standard JPEG 2000 termination sequence.
    ///
    /// Implements the FLUSH procedure from ISO/IEC 15444-1 Annex C.2.9.
    /// Uses SETBITS to properly position C within the current interval
    /// before flushing bytes.
    private mutating func finishDefault() -> Data {
        // SETBITS procedure (ISO/IEC 15444-1 C.2.9, Figure C.11):
        let tempC = c + a
        c = c | 0x0000FFFF
        if c >= tempC {
            c -= 0x8000
        }

        // BYTEOUT twice to flush the C register
        c <<= ct
        emitByte()
        c <<= ct
        emitByte()

        // Emit the final buffer byte only if it's not 0xFF.
        if buffer >= 0 && buffer != 0xFF {
            output.append(UInt8(buffer & 0xFF))
        }

        // Drop any trailing 0xFF from the output (per FLUSH procedure)
        output.removeTrailing(0xFF)

        return output.toData()
    }

    /// Predictable termination - ensures clean code-stream boundaries.
    ///
    /// This mode produces a termination sequence that allows each coding pass
    /// to be independently truncated and decoded. It follows the ERTERM
    /// (error resilience termination) approach from ISO/IEC 15444-1 Annex D.
    ///
    /// The ERTERM termination uses the same FLUSH procedure as default termination
    /// (SETBITS + BYTEOUT), which ensures the decoder can correctly recover
    /// all encoded symbols when each pass is decoded independently.
    private mutating func finishPredictable() -> Data {
        // Use the same FLUSH procedure as default termination.
        // The "predictable" aspect comes from resetting the MQ coder
        // between passes (handled by the caller), not from a different
        // termination sequence. The FLUSH procedure guarantees that all
        // encoded symbols are recoverable from the output bytes.
        return finishDefault()
    }

    /// Near-optimal termination - minimises wasted bits.
    ///
    /// This mode uses a termination sequence that minimises wasted bits while
    /// still ensuring correct decoding. It follows the approach described in
    /// the JPEG 2000 standard for rate-optimal termination.
    ///
    /// - Note: This implementation currently uses the same termination as default mode.
    ///   True near-optimal termination requires analysis of the decoder state
    ///   to determine the minimum number of bytes needed.
    ///
    /// - TODO (v1.1 Phase 4): Implement true near-optimal termination by analysing the interval (A)
    ///   and code register (C) to determine if fewer termination bytes are sufficient.
    ///   This could save 1-2 bytes per code-block termination.
    private mutating func finishNearOptimal() -> Data {
        // For now, use the default termination which is safe and correct.
        // A true near-optimal termination would analyse the interval (A)
        // and code register (C) to determine if fewer bytes are sufficient.
        //
        // TODO (v1.1 Phase 4): Implement proper near-optimal termination algorithm per JPEG 2000 standard
        // The default termination always produces a valid output,
        // while near-optimal would potentially save 1-2 bytes in some cases.
        finishDefault()
    }

    /// Resets the encoder to its initial state.
    mutating func reset() {
        c = 0
        a = 0x8000
        ct = Self.initialCounterBits
        buffer = -1
        operationCount = 0
        output.reset()
    }

    /// Returns the current size of the encoded data.
    var encodedSize: Int {
        output.count + (buffer >= 0 ? 1 : 0)
    }
}

// MARK: - MQ Decoder

/// Decodes binary symbols using the MQ arithmetic coding algorithm.
///
/// Marked `@unchecked Sendable` because it stores a raw pointer into `dataStorage`.
/// Safety: `dataStorage` is a `let` (immutable) field, so its backing buffer is never
/// reallocated or freed while `self` is alive. The pointer therefore remains valid
/// for the entire lifetime of the struct. MQDecoder instances are never shared between
/// tasks — each pass owns its own instance.
struct MQDecoder: @unchecked Sendable {
    private var c: UInt32 = 0
    private var a: UInt32 = 0x8000
    private var ct: Int = 0
    private let dataStorage: [UInt8]   // Keeps backing buffer alive
    private let dataPtr: UnsafePointer<UInt8>  // Stable pointer into dataStorage
    private let dataCount: Int
    private var position: Int = 0
    private var buffer: UInt8 = 0
    private var nextBuffer: UInt8 = 0

    /// Debug access to internal state for trace verification
    var debugA: UInt32 { a }
    var debugC: UInt32 { c }
    var debugCT: Int { ct }
    var debugPosition: Int { position }

    /// Bytes of the segment this decoder was given.
    var segmentBytes: Int { dataCount }

    /// Bytes of the segment the decoder has read.
    var consumedBytes: Int { position }

    /// Reads past the end of the segment. Annex C feeds 0xFF there, and a clean block over-reads a few bytes on
    /// its flush tail; a large count means the decoder lost synchronisation (#2899).
    private(set) var overReadCount = 0

    /// Debug operation counter
    var operationCount: Int = 0

    /// Creates a new MQ decoder with the specified compressed data (convenience, copies Data).
    init(data: Data) {
        let bytes = [UInt8](data)
        self.dataStorage = bytes
        self.dataCount = bytes.count
        // Extract stable pointer. dataStorage is 'let' so its heap buffer won't be
        // reallocated; the pointer is valid for the entire lifetime of this struct.
        self.dataPtr = dataStorage.withUnsafeBufferPointer { $0.baseAddress ?? UnsafePointer(bitPattern: 1)! }
        initializeDecoder()
    }

    /// Creates a new MQ decoder directly from a pre-built byte array (no copy).
    ///
    /// - Parameters:
    ///   - bytes: The owner array.  Must outlive (or equal) `self`.
    ///   - offset: Byte offset within `bytes` where this segment starts.
    ///   - count:  Number of bytes in this segment.
    init(bytes: [UInt8], offset: Int, count: Int) {
        self.dataStorage = bytes
        self.dataCount = count
        let base = dataStorage.withUnsafeBufferPointer { $0.baseAddress ?? UnsafePointer(bitPattern: 1)! }
        self.dataPtr = base + offset
        initializeDecoder()
    }

    /// Creates a new MQ decoder using a raw pointer — no copy, no array ownership.
    /// Caller must guarantee the pointed-to buffer outlives this instance.
    ///
    /// - Parameters:
    ///   - unsafePtr: Base pointer of the byte buffer.
    ///   - offset: Byte offset within the buffer where this segment starts.
    ///   - count: Number of bytes in this segment.
    init(unsafePtr: UnsafePointer<UInt8>, offset: Int, count: Int) {
        self.dataStorage = []   // unused — caller owns the buffer
        self.dataCount = count
        self.dataPtr = unsafePtr + offset
        initializeDecoder()
    }

    /// Initializes the decoder state.
    private mutating func initializeDecoder() {
        buffer = readByte()
        c = UInt32(buffer) << 16
        fillC()
        c <<= 7
        ct -= 7
        a = 0x8000
    }

    /// Reads a byte from the input.
    ///
    /// Uses a stored raw pointer for direct array access with no per-call closure overhead.
    @inline(__always)
    private mutating func readByte() -> UInt8 {
        if position < dataCount {
            let b = dataPtr[position]
            position &+= 1
            return b
        }
        overReadCount &+= 1
        return 0xFF
    }

    /// Fills the C register with more data.
    @inline(__always)
    private mutating func fillC() {
        if buffer == 0xFF {
            let prevPosition = position
            nextBuffer = readByte()
            if nextBuffer > 0x8F {
                // Marker - don't advance, stuff zeros
                // Only decrement if we actually advanced (read from data, not EOF)
                if position > prevPosition {
                    position -= 1
                }
                c += 0xFF00
                ct = 8
            } else {
                c += UInt32(nextBuffer) << 9
                buffer = nextBuffer
                ct = 7
            }
        } else {
            buffer = readByte()
            c += UInt32(buffer) << 8
            ct = 8
        }
    }

    /// Decodes a binary symbol using the specified context.
    ///
    /// Implements ISO 15444-1 C.3.2 (DECODE).
    /// Uses flat state arrays to avoid struct copies in the critical path.
    @inline(__always)
    mutating func decode(context: inout MQContext) -> Bool {
        let si = Int(context.stateIndex)
        // Single packed table lookup — qe + nextMPS + nextLPS + switchMPS
        // co-resident in the same UInt32. Replaces 3-4 separate
        // `mq*[si]` array loads (each potentially a different cache
        // line) on the hottest method in the EBCOT decoder.
        let entry = mqStatePacked[si]
        let qe = entry & mqQeMask

        a -= qe

        let mps = context.mps
        let symbol: Bool

        if (c >> 16) < qe {
            // LPS region (ISO 15444-1 C.3.2)
            if a < qe {
                // Conditional exchange — return MPS
                a = qe
                symbol = mps
                context.stateIndex = UInt8((entry >> mqNextMPSShift) & mqStateMask)
            } else {
                // Normal LPS
                a = qe
                symbol = !mps
                if (entry & mqSwitchMPSBit) != 0 {
                    context.mps.toggle()
                }
                context.stateIndex = UInt8((entry >> mqNextLPSShift) & mqStateMask)
            }
            renormalizeDecoder()
        } else {
            // MPS region (ISO 15444-1 C.3.2)
            c -= qe << 16
            if (a & 0x8000) == 0 {
                if a < qe {
                    // Conditional exchange — return LPS
                    symbol = !mps
                    if (entry & mqSwitchMPSBit) != 0 {
                        context.mps.toggle()
                    }
                    context.stateIndex = UInt8((entry >> mqNextLPSShift) & mqStateMask)
                } else {
                    // Normal MPS
                    symbol = mps
                    context.stateIndex = UInt8((entry >> mqNextMPSShift) & mqStateMask)
                }
                renormalizeDecoder()
            } else {
                symbol = mps
            }
        }

        #if EBCOT_DEBUG_TRACE
        if EBCOTDebugTrace.shared.enabled {
            operationCount += 1
            EBCOTDebugTrace.shared.decoderSymbols.append(
                (operationCount, 0, symbol, 0, UInt32(EBCOTDebugTrace.shared.currentContextLabel), 0)
            )
        }
        #endif

        return symbol
    }

    /// Prepares the decoder for bypass mode.
    ///
    /// This method ensures a clean transition from MQ decoding to raw bypass decoding.
    /// The interval register is set to the full interval.
    @inline(__always)
    mutating func prepareForBypass() {
        a = 0x8000
    }

    /// Decodes a symbol using uniform (bypass) coding.
    ///
    /// In bypass mode, raw bits are read using the MQ coder's byte input mechanism.
    @inline(__always)
    mutating func decodeBypass() -> Bool {
        if ct == 0 {
            fillC()
        }
        ct -= 1
        c <<= 1

        if (c >> 16) >= 0x8000 {
            c -= 0x8000 << 16
            return true
        }
        return false
    }

    /// Renormalizes the decoder state.
    @inline(__always)
    private mutating func renormalizeDecoder() {
        guard a < 0x8000 else { return }
        let shifts = Int(a.leadingZeroBitCount) - 16   // bits needed to reach a >= 0x8000
        if shifts > 0 && ct >= shifts {
            // All required bits are buffered — bulk shift without fillC overhead
            a <<= shifts
            c <<= shifts
            ct -= shifts
        } else {
            // Need byte refill mid-shift — use per-step loop
            repeat {
                if ct == 0 { fillC() }
                a <<= 1; c <<= 1; ct -= 1
            } while a < 0x8000
        }
    }

    /// Resets the decoder.
    mutating func reset() {
        position = 0
        c = 0
        a = 0x8000
        ct = 0
        buffer = 0
        initializeDecoder()
    }

    /// Returns true if at end of data.
    var isAtEnd: Bool {
        position >= dataCount && ct == 0
    }

    /// Returns the current position.
    var currentPosition: Int {
        position
    }
}

// MARK: - Raw Bypass Encoder

/// Encodes raw bits for JPEG 2000 bypass mode.
///
/// This encoder is used for magnitude refinement passes that bypass the MQ
/// arithmetic coder. It packs bits MSB-first into bytes, with 0xFF byte
/// stuffing to avoid JPEG 2000 marker conflicts.
///
/// This is separate from the MQ coder to avoid bit-positioning issues
/// that arise from mixing MQ state with raw bit packing.
struct RawBypassEncoder: Sendable {
    /// Byte accumulator for collecting bits.
    private var c: UInt32 = 0
    /// Number of remaining bits in the current byte.
    private var ct: Int = 0
    /// Output buffer.
    private var output: [UInt8] = []

    /// Creates a new raw bypass encoder.
    init() {}

    /// Encodes a single raw bit.
    ///
    /// Bits are packed MSB-first. After writing a 0xFF byte, only 7 bits
    /// are used in the next byte to avoid JPEG 2000 marker conflicts.
    @inline(__always)
    mutating func encode(symbol: Bool) {
        if ct == 0 {
            ct = 8
        }
        ct -= 1
        if symbol {
            c += (1 << ct)
        }
        if ct == 0 {
            output.append(UInt8(c & 0xFF))
            // After 0xFF, use only 7 bits
            if UInt8(c & 0xFF) == 0xFF {
                ct = 7
            } else {
                ct = 8
            }
            c = 0
        }
    }

    /// Flushes any remaining partial byte and returns the encoded data.
    ///
    /// Remaining bits are filled with an alternating 0,1 pattern per the
    /// JPEG 2000 standard.
    mutating func finish() -> Data {
        // Flush partial byte if any
        if ct > 0 && ct < 8 {
            // Fill remaining bits with alternating pattern
            var bitValue: UInt32 = 0
            var remaining = ct
            while remaining > 0 {
                remaining -= 1
                c += bitValue << remaining
                bitValue = 1 - bitValue
            }
            output.append(UInt8(c & 0xFF))
        }
        return Data(output)
    }

    /// Resets the encoder.
    mutating func reset() {
        c = 0
        ct = 0
        output.removeAll(keepingCapacity: true)
    }
}

// MARK: - Raw Bypass Decoder

/// Decodes raw bits for JPEG 2000 bypass mode.
///
/// This decoder reads raw bits packed MSB-first from bytes, with 0xFF byte
/// stuffing handling. It is separate from the MQ decoder to avoid
/// bit-positioning issues.
struct RawBypassDecoder: @unchecked Sendable {
    /// Current byte value.
    private var c: UInt32 = 0
    /// Number of remaining bits in the current byte.
    private var ct: Int = 0
    /// Owner array — retains the buffer so the pointer stays valid.
    private let owner: [UInt8]
    /// Raw pointer into owner at the segment start offset.
    private let dataPtr: UnsafePointer<UInt8>
    /// Number of bytes in this segment.
    private let dataCount: Int
    /// Current read position within the segment.
    private var position: Int = 0

    /// Creates a bypass decoder that borrows a slice of an existing byte array.
    /// No copy is made — `bytes` must outlive `self`.
    init(bytes: [UInt8], offset: Int, count: Int) {
        self.owner     = bytes
        self.dataCount = count
        self.dataPtr   = owner.withUnsafeBufferPointer { $0.baseAddress! + offset }
    }

    /// Creates a bypass decoder using a caller-owned raw byte buffer.
    /// Skips the per-block `Array(...)` copy and the per-decoder
    /// `withUnsafeBufferPointer` closure invocation that the
    /// `[UInt8]` overload pays. The caller must guarantee
    /// `unsafePtr[offset ..< offset+count]` stays valid for the
    /// decoder's lifetime — typically by keeping the decoder inside
    /// the same `Data.withUnsafeBytes { … }` scope as the source.
    init(unsafePtr: UnsafePointer<UInt8>, offset: Int, count: Int) {
        self.owner     = []   // unused — caller owns the buffer
        self.dataCount = count
        self.dataPtr   = unsafePtr + offset
    }

    /// Bytes of the segment this decoder was given.
    var segmentBytes: Int { dataCount }

    /// Bytes of the segment the decoder has read.
    var consumedBytes: Int { position }

    /// Decodes a single raw bit (MSB-first, 0xFF stuffing as per JPEG 2000).
    @inline(__always)
    mutating func decode() -> Bool {
        if ct == 0 {
            if position < dataCount {
                let prevByte = c
                c = UInt32(dataPtr[position])
                position &+= 1
                ct = prevByte == 0xFF ? 7 : 8
            } else {
                c = 0xFF
                ct = 8
            }
        }
        ct &-= 1
        return ((c >> ct) & 0x01) != 0
    }
}
