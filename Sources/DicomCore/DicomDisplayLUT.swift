//
//  DicomDisplayLUT.swift
//  DicomCore
//
//  A cached presentation lookup table (issue #1906).
//
//  The monochrome render path walks every pixel through
//  `DicomDisplayTransformProfile.displayValue` — masking, Modality LUT or
//  rescale, VOI, presentation inversion and the UInt8 rounding — for stored
//  values that repeat constantly. A frame has millions of pixels but at most
//  2^BitsStored distinct stored values, so the whole presentation decision
//  fits in one table computed once.
//
//  The table is DERIVED from `displayValue`, entry by entry, over every
//  representable stored value — not a reimplementation of the formula. That
//  is what makes the exhaustive parity tests trivial truths instead of
//  hopeful approximations, and it is why CPU and Metal can produce identical
//  bytes: both index the same table.
//

import Foundation

/// One immutable presentation table: stored pixel value → display byte.
public struct DicomDisplayLUT: Sendable, Equatable {
    /// The smallest representable stored value (0 unsigned,
    /// -2^(BitsStored-1) signed).
    public let minimumStoredValue: Int
    /// `entries[storedValue - minimumStoredValue]`; -1 encodes the values the
    /// scalar path answers `nil` for, so the table preserves even the
    /// failure behavior of the formula it was built from.
    let entries: [Int16]

    /// The number of representable stored values.
    public var count: Int { entries.count }

    /// The display byte for a stored value, exactly as
    /// `DicomDisplayTransformProfile.displayValue` would answer — including
    /// `nil` for values the profile refuses and for values outside the
    /// representable range.
    public func displayValue(forStoredPixelValue storedValue: Int) -> UInt8? {
        let index = storedValue - minimumStoredValue
        guard index >= 0, index < entries.count else { return nil }
        let entry = entries[index]
        return entry < 0 ? nil : UInt8(truncatingIfNeeded: entry)
    }

    /// The table as raw bytes for a GPU consumer. `nil` entries become 0 —
    /// callers that can meet a `nil` must check `hasUnmappedEntries` first
    /// and stay on the scalar path, where the failure is still reported.
    public var tableBytes: [UInt8] {
        entries.map { $0 < 0 ? 0 : UInt8(truncatingIfNeeded: $0) }
    }

    public var hasUnmappedEntries: Bool {
        entries.contains { $0 < 0 }
    }

    /// Builds the table by evaluating the profile over every representable
    /// stored value of the given bit configuration.
    ///
    /// - Returns: `nil` for configurations no table can represent
    ///   (BitsStored outside 1…16).
    public init?(profile: DicomDisplayTransformProfile,
                 selection: DicomDisplaySelection?,
                 bitsStored: Int,
                 isSigned: Bool) {
        guard bitsStored >= 1, bitsStored <= 16 else { return nil }
        let count = 1 << bitsStored
        let minimum = isSigned ? -(1 << (bitsStored - 1)) : 0
        var entries = [Int16](repeating: -1, count: count)
        for offset in 0..<count {
            let storedValue = minimum + offset
            if let value = profile.displayValue(forStoredPixelValue: Double(storedValue),
                                                selection: selection) {
                entries[offset] = Int16(value)
            }
        }
        self.minimumStoredValue = minimum
        self.entries = entries
    }
}

// MARK: - Cache

/// The properties that change what a presentation table holds — and nothing
/// else. Window `explanation` strings, image dimensions, frame counts and
/// rescale type labels deliberately do not appear: two frames that present
/// identically share one table.
public struct DicomDisplayLUTKey: Equatable, Sendable {
    let bitsStored: Int
    let isSigned: Bool
    let rescale: RescaleParameters
    let modalityLUTSignature: Int?
    let selectionSignature: SelectionSignature?
    let isMonochrome1: Bool
    let presentationLUTSignature: Int?
    let presentationLUTShape: DicomPresentationLUTShape?

    /// The presentation-relevant identity of the active selection: the
    /// resolved values, not the index or the label they came with.
    enum SelectionSignature: Equatable, Sendable {
        case window(center: Double, width: Double)
        case voiLUT(signature: Int)
        case preset(MedicalPreset)
    }

    public init(profile: DicomDisplayTransformProfile,
                selection: DicomDisplaySelection?,
                bitsStored: Int,
                isSigned: Bool) {
        self.bitsStored = bitsStored
        self.isSigned = isSigned
        self.rescale = profile.rescaleParameters
        self.modalityLUTSignature = profile.modalityLUTs.first.map(Self.signature(of:))
        self.isMonochrome1 = profile.isMonochrome1
        self.presentationLUTSignature = profile.presentationLUT.map(Self.signature(of:))
        self.presentationLUTShape = profile.presentationLUT == nil ? profile.presentationLUTShape : nil
        switch selection ?? profile.defaultSelection {
        case .window(let index):
            self.selectionSignature = profile.windows.indices.contains(index)
                ? .window(center: profile.windows[index].settings.center,
                          width: profile.windows[index].settings.width)
                : nil
        case .voiLUT(let index):
            self.selectionSignature = profile.voiLUTs.indices.contains(index)
                ? .voiLUT(signature: Self.signature(of: profile.voiLUTs[index]))
                : nil
        case .preset(let preset):
            self.selectionSignature = .preset(preset)
        case .customWindow(let settings):
            self.selectionSignature = .window(center: settings.center, width: settings.width)
        case nil:
            self.selectionSignature = nil
        }
    }

    /// The LUT's presentation identity: descriptor and data, never its
    /// `explanation` label.
    private static func signature(of lut: DicomLookupTable) -> Int {
        var hasher = Hasher()
        hasher.combine(lut.descriptor.storedEntryCount)
        hasher.combine(lut.descriptor.firstMappedValue)
        hasher.combine(lut.descriptor.bitsPerEntry)
        hasher.combine(lut.data)
        return hasher.finalize()
    }
}

/// A small, deterministic cache of presentation tables.
///
/// Capacity-limited FIFO: when full, the oldest entry leaves — no clocks, no
/// randomness, so eviction is reproducible in tests. Thread-safe.
public final class DicomDisplayLUTCache: @unchecked Sendable {
    public static let shared = DicomDisplayLUTCache()

    private let capacity: Int
    private let lock = NSLock()
    private var keys: [DicomDisplayLUTKey] = []
    private var tables: [DicomDisplayLUT] = []
    private(set) var buildCount = 0

    public init(capacity: Int = 8) {
        self.capacity = max(1, capacity)
    }

    /// The table for this presentation, built on first use.
    public func table(profile: DicomDisplayTransformProfile,
                      selection: DicomDisplaySelection?,
                      bitsStored: Int,
                      isSigned: Bool) -> DicomDisplayLUT? {
        let key = DicomDisplayLUTKey(profile: profile,
                                     selection: selection,
                                     bitsStored: bitsStored,
                                     isSigned: isSigned)
        lock.lock()
        defer { lock.unlock() }
        if let index = keys.firstIndex(of: key) {
            return tables[index]
        }
        guard let table = DicomDisplayLUT(profile: profile,
                                          selection: selection,
                                          bitsStored: bitsStored,
                                          isSigned: isSigned) else {
            return nil
        }
        buildCount += 1
        keys.append(key)
        tables.append(table)
        if keys.count > capacity {
            keys.removeFirst()
            tables.removeFirst()
        }
        return table
    }

    /// Test seam: how many distinct tables were built.
    public var debugBuildCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return buildCount
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        keys.removeAll()
        tables.removeAll()
        buildCount = 0
    }
}
