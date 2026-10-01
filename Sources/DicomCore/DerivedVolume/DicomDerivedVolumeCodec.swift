import CryptoKit
import DicomJPEG2000
import Foundation
import zlib

/// Shape of a derived volume: little-endian 16-bit single-component voxels in slice-major order.
public struct DicomDerivedVolumeDescriptor: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let depth: Int
    /// Stored precision (1...16); the container always carries 16-bit samples.
    public let bitsStored: Int
    public let isSigned: Bool

    public init(width: Int, height: Int, depth: Int, bitsStored: Int = 16, isSigned: Bool) {
        self.width = width
        self.height = height
        self.depth = depth
        self.bitsStored = bitsStored
        self.isSigned = isSigned
    }

    public var voxelCount: Int { width * height * depth }
    public var sliceByteCount: Int { width * height * 2 }
    public var byteCount: Int { voxelCount * 2 }
}

/// Inter-slice prediction policy: a slice may be coded as the signed residual against the previous slice
/// when every residual fits the 16-bit signed range and the residual codestream is smaller.
public enum DicomDerivedVolumeZDeltaMode: UInt8, Sendable, CaseIterable {
    case never = 0
    case auto = 1
    case always = 2
}

public struct DicomDerivedVolumeEncodingOptions: Sendable {
    public var zDelta: DicomDerivedVolumeZDeltaMode
    /// Reversible 5/3 decomposition levels per slice; nil derives them from the slice size (at most 5).
    public var decompositionLevels: Int?
    /// Slices encoded concurrently; 0 uses the active processor count.
    public var maximumConcurrency: Int

    public init(zDelta: DicomDerivedVolumeZDeltaMode = .auto, decompositionLevels: Int? = nil, maximumConcurrency: Int = 0) {
        self.zDelta = zDelta
        self.decompositionLevels = decompositionLevels
        self.maximumConcurrency = maximumConcurrency
    }
}

/// What a container declares about itself, read without decoding any slice.
public struct DicomDerivedVolumeContainerInfo: Equatable, Sendable {
    public let containerVersion: UInt16
    public let codecIdentifier: String
    public let algorithm: String
    public let descriptor: DicomDerivedVolumeDescriptor
    public let zDelta: DicomDerivedVolumeZDeltaMode
    public let decompositionLevels: Int
    /// Opaque fingerprint of the sources and transformations the caller derived the voxels from.
    public let sourceFingerprint: Data
    /// SHA-256 of the canonical voxel bytes the container reproduces.
    public let contentDigest: Data
    public let sliceCount: Int
    public let residualSliceCount: Int
    public let payloadByteCount: Int
}

public struct DicomDerivedVolumeEncodeResult: Sendable {
    public let data: Data
    public let info: DicomDerivedVolumeContainerInfo
    /// Stable description of the algorithm and parameters, for manifests.
    public let encoderConfiguration: String
}

public enum DicomDerivedVolumeError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVolume(String)
    case malformedContainer(String)
    /// A checksum or digest does not match: the bytes are not the ones that were written.
    case integrityFailure(String)
    case incompatibleContainerVersion(UInt16)
    case fingerprintMismatch
    case descriptorMismatch(String)
    case codecFailure(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVolume(let reason): return "unsupported derived volume: \(reason)"
        case .malformedContainer(let reason): return "malformed derived volume container: \(reason)"
        case .integrityFailure(let reason): return "derived volume integrity failure: \(reason)"
        case .incompatibleContainerVersion(let version): return "derived volume container version \(version) is not readable"
        case .fingerprintMismatch: return "the derived volume was built from other sources or transformations"
        case .descriptorMismatch(let reason): return "the derived volume does not describe the expected volume: \(reason)"
        case .codecFailure(let reason): return "derived volume codec failure: \(reason)"
        }
    }
}

/// Own derived-volume codec (issue #2337): a versioned private container (`ISVS`) holding one JPEG 2000
/// Part 1 reversible 5/3 codestream per slice, produced and read by the vendored `DicomJPEG2000` core.
/// Slices may be coded as signed residuals against the previous slice (Z-delta) when that is smaller;
/// every slice keeps a CRC-32, the container keeps the SHA-256 of the canonical voxels, of the sources
/// fingerprint the caller provides, and a trailing SHA-256 over the whole container.
///
/// This is neither ISO/IEC 15444-10 (JP3D) nor DICOM JPEG 2000 Part 2 multi-component (.92/.93): no
/// transfer syntax UID names it and it never leaves the derived-artifact cache.
public enum DicomDerivedVolumeCodec {
    public static let codecIdentifier = "dicom-swift.j2k-slice-stack"
    public static let containerVersion: UInt16 = 1
    static let magic: [UInt8] = [0x49, 0x53, 0x56, 0x53] // "ISVS"
    /// Bytes of slice payload kept in flight per decoding window, bounding memory beyond the output buffer.
    static let decodeWindowBytes = 64 * 1024 * 1024
    private static let sliceFlagResidual: UInt8 = 0x01
    private static let maximumSourceFingerprintBytes = 4096

    // MARK: - Encode

    public static func encode(
        voxels: Data,
        descriptor: DicomDerivedVolumeDescriptor,
        sourceFingerprint: Data = Data(),
        options: DicomDerivedVolumeEncodingOptions = .init()
    ) async throws -> DicomDerivedVolumeEncodeResult {
        try Task.checkCancellation()
        try validate(descriptor)
        let voxels = Data(voxels)
        guard voxels.count == descriptor.byteCount else {
            throw DicomDerivedVolumeError.unsupportedVolume("\(voxels.count) voxel bytes for a \(descriptor.byteCount)-byte volume")
        }
        guard sourceFingerprint.count <= maximumSourceFingerprintBytes else {
            throw DicomDerivedVolumeError.unsupportedVolume("source fingerprint longer than \(maximumSourceFingerprintBytes) bytes")
        }
        let levels = options.decompositionLevels ?? defaultDecompositionLevels(width: descriptor.width, height: descriptor.height)
        guard (0...5).contains(levels) else { throw DicomDerivedVolumeError.unsupportedVolume("decomposition levels must be 0...5") }
        let concurrency = options.maximumConcurrency > 0 ? options.maximumConcurrency : max(1, ProcessInfo.processInfo.activeProcessorCount)
        let configuration = encodingConfiguration(levels: levels, threads: concurrency > 1 ? 1 : 0)
        let sliceVoxels = descriptor.width * descriptor.height
        let zDeltaCandidate: Bool
        switch options.zDelta {
        case .never: zDeltaCandidate = false
        case .always: zDeltaCandidate = descriptor.depth > 1
        case .auto: zDeltaCandidate = descriptor.depth > 1 && sliceVoxels >= 50_000
        }

        // The first two slices settle the residual policy of the volume (as the reference encoder does):
        // residual coding that saves at least 20% becomes the rule, below 3% it is abandoned, otherwise both
        // codings are tried per slice.
        var policy: ResidualPolicy = zDeltaCandidate ? .tryBoth : .rawOnly
        var slices: [SliceRecord?] = Array(repeating: nil, count: descriptor.depth)
        let sequentialPrefix = min(2, descriptor.depth)
        for z in 0..<sequentialPrefix {
            try Task.checkCancellation()
            let record = try await encodeSlice(z: z, voxels: voxels, descriptor: descriptor, policy: policy, configuration: configuration)
            slices[z] = record.record
            if z == 1, policy == .tryBoth {
                if record.savings >= 0.20 { policy = .residualPreferred } else if record.savings < 0.03 { policy = .rawOnly }
            }
        }
        if descriptor.depth > sequentialPrefix {
            let fixedPolicy = policy
            try await withThrowingTaskGroup(of: (Int, SliceRecord).self) { group in
                var next = sequentialPrefix
                var inFlight = 0
                func enqueue() {
                    let z = next
                    next += 1
                    inFlight += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let record = try await encodeSlice(z: z, voxels: voxels, descriptor: descriptor, policy: fixedPolicy,
                                                           configuration: configuration)
                        return (z, record.record)
                    }
                }
                while next < descriptor.depth, inFlight < concurrency { enqueue() }
                for try await (z, record) in group {
                    inFlight -= 1
                    slices[z] = record
                    if next < descriptor.depth { enqueue() }
                }
            }
        }
        try Task.checkCancellation()
        let records = slices.compactMap { $0 }
        guard records.count == descriptor.depth else { throw DicomDerivedVolumeError.codecFailure("a slice produced no codestream") }
        let contentDigest = Data(SHA256.hash(data: voxels))
        let algorithm = "jpeg2000-part1-reversible-5/3;levels=\(levels);layers=1;progression=lrcp;zdelta=\(zDeltaName(options.zDelta))"
        let container = assemble(records: records, descriptor: descriptor, levels: levels, zDelta: options.zDelta,
                                 sourceFingerprint: sourceFingerprint, contentDigest: contentDigest, algorithm: algorithm)
        let info = DicomDerivedVolumeContainerInfo(
            containerVersion: containerVersion, codecIdentifier: codecIdentifier, algorithm: algorithm, descriptor: descriptor,
            zDelta: options.zDelta, decompositionLevels: levels, sourceFingerprint: sourceFingerprint, contentDigest: contentDigest,
            sliceCount: descriptor.depth, residualSliceCount: records.filter(\.isResidual).count,
            payloadByteCount: records.reduce(0) { $0 + $1.codestream.count }
        )
        return DicomDerivedVolumeEncodeResult(
            data: container, info: info,
            encoderConfiguration: "\(codecIdentifier);container=\(containerVersion);\(algorithm);signed=\(descriptor.isSigned);"
                + "residual-slices=\(info.residualSliceCount)/\(descriptor.depth)"
        )
    }

    // MARK: - Inspect

    /// Reads and checks the container structure and its trailing digest; nothing is decoded.
    public static func inspect(_ container: Data) throws -> DicomDerivedVolumeContainerInfo {
        try parse(container).info
    }

    /// The per-slice codestreams (raw or residual), for independent decoders.
    public static func sliceCodestreams(_ container: Data) throws -> [(isResidual: Bool, codestream: Data)] {
        let parsed = try parse(container)
        return parsed.slices.map { ($0.isResidual, parsed.bytes.subdata(in: $0.range)) }
    }

    // MARK: - Decode

    /// Reconstructs the canonical voxels. Every layer is verified before bytes are returned: container
    /// digest, declared shape against `descriptor`, source fingerprint when given, per-slice CRC-32, the
    /// decoded shape of every slice and the SHA-256 of the reconstructed voxels.
    public static func decode(
        _ container: Data,
        expecting descriptor: DicomDerivedVolumeDescriptor,
        sourceFingerprint: Data? = nil,
        maximumConcurrency: Int = 0
    ) async throws -> Data {
        try Task.checkCancellation()
        try validate(descriptor)
        let parsed = try parse(container)
        let declared = parsed.info.descriptor
        guard declared == descriptor else {
            throw DicomDerivedVolumeError.descriptorMismatch(
                "container \(declared.width)x\(declared.height)x\(declared.depth) \(declared.bitsStored)-bit signed=\(declared.isSigned), "
                    + "expected \(descriptor.width)x\(descriptor.height)x\(descriptor.depth) \(descriptor.bitsStored)-bit signed=\(descriptor.isSigned)")
        }
        if let sourceFingerprint, sourceFingerprint != parsed.info.sourceFingerprint {
            throw DicomDerivedVolumeError.fingerprintMismatch
        }
        for (index, slice) in parsed.slices.enumerated() {
            let crc = parsed.bytes.subdata(in: slice.range).withUnsafeBytes { buffer -> UInt32 in
                UInt32(zlib.crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
            }
            guard crc == slice.crc32 else { throw DicomDerivedVolumeError.integrityFailure("slice \(index) CRC-32 mismatch") }
        }
        let sliceBytes = descriptor.sliceByteCount
        let windowSlices = decodeWindowSliceCount(sliceByteCount: sliceBytes, depth: descriptor.depth)
        let concurrency = min(windowSlices, maximumConcurrency > 0 ? maximumConcurrency : max(1, ProcessInfo.processInfo.activeProcessorCount))
        var output = Data(count: descriptor.byteCount)
        var previous: [Int32]? = nil
        var z = 0
        while z < descriptor.depth {
            try Task.checkCancellation()
            let end = z + min(descriptor.depth - z, windowSlices)
            var decoded: [Data?] = Array(repeating: nil, count: end - z)
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                var next = z
                var inFlight = 0
                func enqueue() {
                    let index = next
                    next += 1
                    inFlight += 1
                    let slice = parsed.slices[index]
                    let codestream = parsed.bytes.subdata(in: slice.range)
                    group.addTask {
                        try Task.checkCancellation()
                        return (index, try await decodeSlice(codestream, width: descriptor.width, height: descriptor.height,
                                                             signed: slice.isResidual || descriptor.isSigned, index: index))
                    }
                }
                while next < end, inFlight < concurrency { enqueue() }
                for try await (index, data) in group {
                    inFlight -= 1
                    decoded[index - z] = data
                    if next < end { enqueue() }
                }
            }
            for index in z..<end {
                guard let data = decoded[index - z] else { throw DicomDerivedVolumeError.codecFailure("slice \(index) missing") }
                let samples = data.withUnsafeBytes { buffer -> [Int32] in
                    let words = buffer.bindMemory(to: UInt16.self)
                    return (0..<words.count).map { Int32(Int16(bitPattern: UInt16(littleEndian: words[$0]))) }
                }
                let reconstructed: [Int32]
                if parsed.slices[index].isResidual {
                    guard let previous else { throw DicomDerivedVolumeError.malformedContainer("slice \(index) is a residual without a base slice") }
                    reconstructed = zip(previous, samples).map { $0 + $1 }
                } else if descriptor.isSigned {
                    reconstructed = samples
                } else {
                    reconstructed = data.withUnsafeBytes { buffer -> [Int32] in
                        let words = buffer.bindMemory(to: UInt16.self)
                        return (0..<words.count).map { Int32(UInt16(littleEndian: words[$0])) }
                    }
                }
                let offset = index * sliceBytes
                output.withUnsafeMutableBytes { buffer in
                    let bytes = buffer.bindMemory(to: UInt8.self)
                    for (voxel, value) in reconstructed.enumerated() {
                        let pattern = UInt16(truncatingIfNeeded: value)
                        bytes[offset + voxel * 2] = UInt8(pattern & 0xFF)
                        bytes[offset + voxel * 2 + 1] = UInt8(pattern >> 8)
                    }
                }
                previous = reconstructed
            }
            z = end
        }
        try Task.checkCancellation()
        guard Data(SHA256.hash(data: output)) == parsed.info.contentDigest else {
            throw DicomDerivedVolumeError.integrityFailure("reconstructed voxels do not match the container's content digest")
        }
        return output
    }

    static func decodeWindowSliceCount(sliceByteCount: Int, depth: Int) -> Int {
        min(depth, max(1, decodeWindowBytes / max(1, sliceByteCount)))
    }

    // MARK: - Slice coding

    private enum ResidualPolicy: Equatable { case rawOnly, tryBoth, residualPreferred }

    struct SliceRecord: Sendable {
        let isResidual: Bool
        let codestream: Data
    }

    private static func encodeSlice(
        z: Int, voxels: Data, descriptor: DicomDerivedVolumeDescriptor, policy: ResidualPolicy, configuration: J2KEncodingConfiguration
    ) async throws -> (record: SliceRecord, savings: Double) {
        let sliceBytes = descriptor.sliceByteCount
        let current = voxels.subdata(in: (z * sliceBytes)..<((z + 1) * sliceBytes))
        var residual: Data?
        if z > 0, policy != .rawOnly {
            let previous = voxels.subdata(in: ((z - 1) * sliceBytes)..<(z * sliceBytes))
            residual = residualSlice(current: current, previous: previous, signed: descriptor.isSigned)
        }
        let raw: Data?
        if policy == .residualPreferred, residual != nil {
            raw = nil
        } else {
            raw = try await encodeCodestream(current, width: descriptor.width, height: descriptor.height, signed: descriptor.isSigned,
                                             configuration: configuration, index: z)
        }
        if let residual {
            let residualCodestream = try await encodeCodestream(residual, width: descriptor.width, height: descriptor.height, signed: true,
                                                                configuration: configuration, index: z)
            guard let raw else { return (SliceRecord(isResidual: true, codestream: residualCodestream), 1) }
            let savings = 1 - Double(residualCodestream.count) / Double(max(1, raw.count))
            if residualCodestream.count < raw.count {
                return (SliceRecord(isResidual: true, codestream: residualCodestream), savings)
            }
            return (SliceRecord(isResidual: false, codestream: raw), savings)
        }
        guard let raw else { throw DicomDerivedVolumeError.codecFailure("slice \(z) has neither raw nor residual coding") }
        return (SliceRecord(isResidual: false, codestream: raw), 0)
    }

    /// `current - previous` as little-endian Int16 samples, or nil when a difference does not fit.
    static func residualSlice(current: Data, previous: Data, signed: Bool) -> Data? {
        var residual = Data(count: current.count)
        let representable: Bool = current.withUnsafeBytes { currentBuffer in
            previous.withUnsafeBytes { previousBuffer in
                residual.withUnsafeMutableBytes { residualBuffer -> Bool in
                    let a = currentBuffer.bindMemory(to: UInt16.self), b = previousBuffer.bindMemory(to: UInt16.self)
                    let out = residualBuffer.bindMemory(to: UInt16.self)
                    for index in 0..<a.count {
                        let x = UInt16(littleEndian: a[index]), y = UInt16(littleEndian: b[index])
                        let difference = signed
                            ? Int32(Int16(bitPattern: x)) - Int32(Int16(bitPattern: y))
                            : Int32(x) - Int32(y)
                        guard difference >= Int32(Int16.min), difference <= Int32(Int16.max) else { return false }
                        out[index] = UInt16(bitPattern: Int16(difference)).littleEndian
                    }
                    return true
                }
            }
        }
        return representable ? residual : nil
    }

    private static func encodeCodestream(
        _ samples: Data, width: Int, height: Int, signed: Bool, configuration: J2KEncodingConfiguration, index: Int
    ) async throws -> Data {
        let component = J2KComponent(index: 0, bitDepth: 16, signed: signed, width: width, height: height, data: samples,
                                     sampleByteOrder: .littleEndian)
        let image = J2KImage(width: width, height: height, components: [component], colorSpace: .grayscale)
        do {
            return try await J2KEncoder(encodingConfiguration: configuration).encode(image)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DicomDerivedVolumeError.codecFailure("slice \(index) could not be encoded: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
    }

    private static func decodeSlice(_ codestream: Data, width: Int, height: Int, signed: Bool, index: Int) async throws -> Data {
        let image: J2KImage
        do {
            image = try await J2KDecoder(sampleByteOrder: .littleEndian).decode(codestream)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DicomDerivedVolumeError.codecFailure("slice \(index) could not be decoded: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        guard image.width == width, image.height == height, image.components.count == 1,
              let component = image.components.first, component.bitDepth == 16, component.signed == signed,
              component.subsamplingX == 1, component.subsamplingY == 1 else {
            throw DicomDerivedVolumeError.descriptorMismatch("slice \(index) decoded to another shape than the container declares")
        }
        guard component.data.count == width * height * 2 else {
            throw DicomDerivedVolumeError.codecFailure("slice \(index) decoded to \(component.data.count) bytes")
        }
        guard let order = component.sampleByteOrder else { throw DicomDerivedVolumeError.codecFailure("slice \(index) has no sample byte order") }
        if case .littleEndian = order { return component.data }
        var swapped = Data(count: component.data.count)
        for voxel in 0..<(width * height) {
            swapped[voxel * 2] = component.data[voxel * 2 + 1]
            swapped[voxel * 2 + 1] = component.data[voxel * 2]
        }
        return swapped
    }

    private static func encodingConfiguration(levels: Int, threads: Int) -> J2KEncodingConfiguration {
        J2KEncodingConfiguration(
            quality: 1, lossless: true, decompositionLevels: levels, qualityLayers: 1, progressionOrder: .lrcp,
            tileSize: (0, 0), bitrateMode: .lossless, maxThreads: threads, useHTJ2K: false, useReversibleFilter: true
        )
    }

    static func defaultDecompositionLevels(width: Int, height: Int) -> Int {
        max(0, min(5, Int(log2(Double(max(1, min(width, height))))) - 2))
    }

    private static func validate(_ descriptor: DicomDerivedVolumeDescriptor) throws {
        guard descriptor.width > 0, descriptor.height > 0, descriptor.depth > 0 else {
            throw DicomDerivedVolumeError.unsupportedVolume("all dimensions must be positive")
        }
        guard (1...16).contains(descriptor.bitsStored) else { throw DicomDerivedVolumeError.unsupportedVolume("bits stored must be 1...16") }
        let area = descriptor.width.multipliedReportingOverflow(by: descriptor.height)
        let voxels = area.partialValue.multipliedReportingOverflow(by: descriptor.depth)
        let bytes = voxels.partialValue.multipliedReportingOverflow(by: 2)
        guard !area.overflow, !voxels.overflow, !bytes.overflow, bytes.partialValue <= 1 << 31 else {
            throw DicomDerivedVolumeError.unsupportedVolume("the volume exceeds the 2 GiB codec limit")
        }
    }

    private static func zDeltaName(_ mode: DicomDerivedVolumeZDeltaMode) -> String {
        switch mode {
        case .never: return "never"
        case .auto: return "auto"
        case .always: return "always"
        }
    }

    // MARK: - Container

    struct ParsedSlice: Sendable {
        let isResidual: Bool
        let range: Range<Int>
        let crc32: UInt32
    }

    struct ParsedContainer: Sendable {
        let bytes: Data
        let info: DicomDerivedVolumeContainerInfo
        let slices: [ParsedSlice]
    }

    private static func assemble(records: [SliceRecord], descriptor: DicomDerivedVolumeDescriptor, levels: Int,
                                 zDelta: DicomDerivedVolumeZDeltaMode, sourceFingerprint: Data, contentDigest: Data, algorithm: String) -> Data {
        var header = Data()
        header.append(contentsOf: magic)
        header.append(le16(containerVersion))
        header.append(le32(0)) // header length, patched below
        var flags: UInt32 = 0
        if descriptor.isSigned { flags |= 0x1 }
        if records.contains(where: \.isResidual) { flags |= 0x2 }
        header.append(le32(flags))
        header.append(le32(UInt32(descriptor.width)))
        header.append(le32(UInt32(descriptor.height)))
        header.append(le32(UInt32(descriptor.depth)))
        header.append(contentsOf: [16, UInt8(descriptor.bitsStored), 1, 0, UInt8(levels), zDelta.rawValue, 0, 0])
        header.append(le16(UInt16(sourceFingerprint.count)))
        header.append(sourceFingerprint)
        header.append(contentDigest)
        for text in [codecIdentifier, algorithm] {
            let utf8 = Data(text.utf8)
            header.append(le16(UInt16(utf8.count)))
            header.append(utf8)
        }
        header.append(le32(UInt32(records.count)))
        for record in records {
            header.append(record.isResidual ? sliceFlagResidual : 0)
            header.append(le32(UInt32(record.codestream.count)))
            let crc = record.codestream.withUnsafeBytes { buffer -> UInt32 in
                UInt32(zlib.crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(buffer.count)))
            }
            header.append(le32(crc))
        }
        header.replaceSubrange(6..<10, with: le32(UInt32(header.count)))
        var container = header
        for record in records { container.append(record.codestream) }
        container.append(Data(SHA256.hash(data: container)))
        return container
    }

    static func parse(_ container: Data) throws -> ParsedContainer {
        let data = container.startIndex == 0 ? container : Data(container)
        guard data.count >= 32 + 32 else { throw DicomDerivedVolumeError.malformedContainer("shorter than a header and trailer") }
        guard Array(data[0..<4]) == magic else { throw DicomDerivedVolumeError.malformedContainer("missing ISVS magic") }
        let version = UInt16(data[4]) | UInt16(data[5]) << 8
        guard version == containerVersion else { throw DicomDerivedVolumeError.incompatibleContainerVersion(version) }
        // Trailer first: nothing else is trusted before the container digest matches.
        let body = data.subdata(in: 0..<(data.count - 32))
        guard Data(SHA256.hash(data: body)) == data.subdata(in: (data.count - 32)..<data.count) else {
            throw DicomDerivedVolumeError.integrityFailure("container digest mismatch")
        }
        var cursor = 6
        func u8() throws -> UInt8 {
            guard cursor < body.count else { throw DicomDerivedVolumeError.malformedContainer("truncated header") }
            defer { cursor += 1 }
            return body[cursor]
        }
        func u16() throws -> Int { let low = try u8(), high = try u8(); return Int(low) | Int(high) << 8 }
        func u32() throws -> Int {
            let b0 = try u8(), b1 = try u8(), b2 = try u8(), b3 = try u8()
            return Int(b0) | Int(b1) << 8 | Int(b2) << 16 | Int(b3) << 24
        }
        func bytes(_ count: Int) throws -> Data {
            guard count >= 0, cursor + count <= body.count else { throw DicomDerivedVolumeError.malformedContainer("truncated header") }
            defer { cursor += count }
            return body.subdata(in: cursor..<(cursor + count))
        }
        let headerLength = try u32()
        let flags = try u32()
        let width = try u32(), height = try u32(), depth = try u32()
        let bitsAllocated = try u8(), bitsStored = try u8(), components = try u8(), byteOrder = try u8()
        let levels = try u8(), zDeltaRaw = try u8()
        _ = try u16()
        guard bitsAllocated == 16, components == 1, byteOrder == 0, (1...16).contains(Int(bitsStored)),
              let zDelta = DicomDerivedVolumeZDeltaMode(rawValue: zDeltaRaw) else {
            throw DicomDerivedVolumeError.malformedContainer("unsupported sample layout")
        }
        let fingerprintLength = try u16()
        guard fingerprintLength <= maximumSourceFingerprintBytes else { throw DicomDerivedVolumeError.malformedContainer("fingerprint too long") }
        let fingerprint = try bytes(fingerprintLength)
        let contentDigest = try bytes(32)
        let identifierLength = try u16()
        let identifier = String(decoding: try bytes(identifierLength), as: UTF8.self)
        let algorithmLength = try u16()
        let algorithm = String(decoding: try bytes(algorithmLength), as: UTF8.self)
        guard identifier == codecIdentifier else { throw DicomDerivedVolumeError.malformedContainer("container written by \(identifier)") }
        let sliceCount = try u32()
        guard sliceCount == depth, depth > 0, width > 0, height > 0 else {
            throw DicomDerivedVolumeError.malformedContainer("slice count \(sliceCount) does not match depth \(depth)")
        }
        let area = width.multipliedReportingOverflow(by: height)
        let voxels = area.partialValue.multipliedReportingOverflow(by: depth)
        let byteCount = voxels.partialValue.multipliedReportingOverflow(by: 2)
        guard !area.overflow, !voxels.overflow, !byteCount.overflow else {
            throw DicomDerivedVolumeError.malformedContainer("volume dimensions exceed the addressable byte count")
        }
        guard headerLength >= cursor, headerLength <= body.count,
              sliceCount <= (headerLength - cursor) / 9 else {
            throw DicomDerivedVolumeError.malformedContainer("slice table exceeds the declared header")
        }
        var slices: [ParsedSlice] = []
        slices.reserveCapacity(sliceCount)
        var lengths: [(flags: UInt8, length: Int, crc: UInt32)] = []
        for _ in 0..<sliceCount {
            let sliceFlags = try u8()
            let length = try u32()
            let crc = UInt32(try u32())
            guard sliceFlags & ~sliceFlagResidual == 0, length > 0 else { throw DicomDerivedVolumeError.malformedContainer("invalid slice entry") }
            lengths.append((sliceFlags, length, crc))
        }
        guard cursor == headerLength else { throw DicomDerivedVolumeError.malformedContainer("header length \(headerLength) does not match \(cursor)") }
        guard lengths.first?.flags == 0 else { throw DicomDerivedVolumeError.malformedContainer("the first slice cannot be a residual") }
        var payloadCursor = headerLength
        for entry in lengths {
            guard payloadCursor + entry.length <= body.count else { throw DicomDerivedVolumeError.malformedContainer("truncated slice payload") }
            slices.append(ParsedSlice(isResidual: entry.flags & sliceFlagResidual != 0, range: payloadCursor..<(payloadCursor + entry.length), crc32: entry.crc))
            payloadCursor += entry.length
        }
        guard payloadCursor == body.count else { throw DicomDerivedVolumeError.malformedContainer("\(body.count - payloadCursor) unexpected trailing bytes") }
        let descriptor = DicomDerivedVolumeDescriptor(width: width, height: height, depth: depth, bitsStored: Int(bitsStored), isSigned: flags & 0x1 != 0)
        let info = DicomDerivedVolumeContainerInfo(
            containerVersion: version, codecIdentifier: identifier, algorithm: algorithm, descriptor: descriptor, zDelta: zDelta,
            decompositionLevels: Int(levels), sourceFingerprint: fingerprint, contentDigest: contentDigest, sliceCount: sliceCount,
            residualSliceCount: slices.filter(\.isResidual).count, payloadByteCount: payloadCursor - headerLength
        )
        return ParsedContainer(bytes: body, info: info, slices: slices)
    }

    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)])
    }
}
