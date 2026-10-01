import Foundation

/// Shares one revision-bound index and in-flight raw or decoded frame results. Completed pixels
/// are owned by consumers, never accumulated in a session-wide all-frame cache.
public actor DicomSourceFrameSession {
    public struct Limits: Sendable {
        public let maximumFrameBytes: Int
        public let maximumInFlightBytes: Int
        public let maximumInFlightFrames: Int
        public let maximumConsumers: Int

        /// The in-flight budget admits one frame at `maximumFrameBytes`
        /// with the conservative decoded reservation (input ×4, decoded ×8,
        /// metadata copies): 256 MiB refused every 16-bit frame above about
        /// 28 MiB (a 3328 × 4096 mammogram, a 4096² CR) although the
        /// per-frame limit accepted it (issue #2338).
        public init(maximumFrameBytes: Int = 64 * 1024 * 1024,
                    maximumInFlightBytes: Int = 1024 * 1024 * 1024,
                    maximumInFlightFrames: Int = 4, maximumConsumers: Int = 256) {
            self.maximumFrameBytes = max(0, maximumFrameBytes)
            self.maximumInFlightBytes = max(0, maximumInFlightBytes)
            self.maximumInFlightFrames = max(0, maximumInFlightFrames)
            self.maximumConsumers = max(0, maximumConsumers)
        }
    }

    public struct Metrics: Sendable {
        public let source: DicomByteSource.Metrics
        public let materializedBytes: Int
        public let inFlightReservedBytes: Int
        public let inFlightFrames: Int
        public let waitingConsumers: Int
        public let sharedRequests: Int
        /// No completed-frame cache; consumer-owned results are outside session ownership.
        public let retainedCompletedBytes = 0
    }

    private enum Representation: Hashable {
        case raw, part10, decoded, arrayDecoded, capabilities, qualityIndexedCapabilities
        case partial(DicomPartialFrameDecodeRequest)

        var decodesPixels: Bool {
            switch self {
            case .decoded, .arrayDecoded, .partial: true
            case .raw, .part10, .capabilities, .qualityIndexedCapabilities: false
            }
        }
    }

    private struct Key: Hashable {
        let frame: Int
        let representation: Representation
    }

    private enum Output: Sendable {
        case bytes(Data)
        case decoded(DicomDataBackedDecodedFrame)
        case arrayDecoded(DicomDecodedFrame)
        case partial(DicomPartialFrameDecodeResult)
        case capabilities(DicomPartialFrameDecodeCapabilities)
        case qualityIndexedCapabilities(DicomPartialFrameDecodeCapabilities)

        var byteCount: Int {
            switch self {
            case .bytes(let data): data.count
            case .decoded(let frame): frame.pixels.data.count
            case .capabilities, .qualityIndexedCapabilities: 0
            case .partial(let result): Self.arrayByteCount(result.frame)
            case .arrayDecoded(let frame): Self.arrayByteCount(frame)
            }
        }

        private static func arrayByteCount(_ frame: DicomDecodedFrame) -> Int {
            switch frame.pixels {
            case .gray8(let pixels): pixels.count
            case .gray16(let pixels): pixels.count * 2
            case .rgb8(let pixels): pixels.count
            }
        }

        func retaining(_ owner: any DicomFrameMemoryOwner) -> Output {
            switch self {
            case .decoded(let frame):
                return .decoded(DicomDataBackedDecodedFrame(index: frame.index, pixels: frame.pixels,
                                                           metadata: frame.metadata, memoryOwner: owner))
            case .arrayDecoded(let frame):
                return .arrayDecoded(DicomDecodedFrame(index: frame.index, pixels: frame.pixels,
                                                       metadata: frame.metadata, memoryOwner: owner))
            case .partial(let result):
                let frame = DicomDecodedFrame(index: result.frame.index, pixels: result.frame.pixels,
                                              metadata: result.frame.metadata, memoryOwner: owner)
                return .partial(DicomPartialFrameDecodeResult(
                    frame: frame, decodedSourceRegion: result.decodedSourceRegion,
                    coordinateTransform: result.coordinateTransform, deliveredQualityLayer: result.deliveredQualityLayer,
                    qualityState: result.qualityState, execution: result.execution,
                    codecBytesAvoided: result.codecBytesAvoided
                ))
            case .bytes, .capabilities, .qualityIndexedCapabilities: return self
            }
        }
    }

    private struct Job {
        let task: Task<Void, Never>
        let reservedBytes: Int
        var waiters: [UUID: CheckedContinuation<Output, Error>]
    }

    public nonisolated let index: DicomSourceFrameIndex
    public nonisolated let limits: Limits
    private let source: DicomByteSource
    private let memoryAdmission: DicomFrameMemoryAdmission?
    private let shadowSession = DicomShadowSession()
    private var jobs: [Key: Job] = [:]
    private var reservedBytes = 0
    private var materializedBytes = 0
    private var sharedRequests = 0
    private var closed = false

    deinit {
        let session = shadowSession
        session.close()
        Task { await DicomShadowExecutor.shared.cancel(session: session) }
    }

    public init(source: DicomByteSource, index: DicomSourceFrameIndex, limits: Limits = Limits(),
                memoryAdmission: DicomFrameMemoryAdmission? = nil) throws {
        guard source.revision == index.metadata.sourceRevision else { throw DicomByteSource.Failure.changed }
        self.source = source
        self.index = index
        self.limits = limits
        self.memoryAdmission = memoryAdmission
    }

    public static func open(source: DicomByteSource, limits: Limits = Limits(),
                            maximumIndexBytes: Int = 32 * 1024 * 1024,
                            maximumBoundaryScanBytes: Int = 64 * 1024 * 1024,
                            memoryAdmission: DicomFrameMemoryAdmission? = nil) async throws -> DicomSourceFrameSession {
        let metadata = try await DicomSourceMetadata.readPart10(from: source)
        let index = try await DicomSourceFrameIndex.build(from: source, metadata: metadata,
                                                         maximumIndexBytes: maximumIndexBytes,
                                                         maximumBoundaryScanBytes: maximumBoundaryScanBytes)
        return try DicomSourceFrameSession(source: source, index: index, limits: limits, memoryAdmission: memoryAdmission)
    }

    public var metrics: Metrics {
        get async {
            let sourceMetrics = await source.metrics
            return Metrics(source: sourceMetrics, materializedBytes: materializedBytes,
                           inFlightReservedBytes: reservedBytes, inFlightFrames: jobs.count,
                           waitingConsumers: consumerCount, sharedRequests: sharedRequests)
        }
    }

    private var consumerCount: Int { jobs.values.reduce(0) { $0 + $1.waiters.count } }

    public func frameData(at frame: Int) async throws -> Data {
        guard case .bytes(let data) = try await request(Key(frame: frame, representation: .raw)) else {
            throw DicomSourceFrameIndex.Failure.invalidLayout
        }
        return data
    }

    /// A single-frame Part 10 compatibility artifact for existing import/export APIs.
    /// It preserves stored pixels; original source identity/count remain on `index`.
    /// This internal-consumption artifact retains the source SOP UID. Publishing a
    /// derived clinical instance requires separate SOP identity and provenance handling.
    public func part10Data(at frame: Int) async throws -> Data {
        guard case .bytes(let data) = try await request(Key(frame: frame, representation: .part10)) else {
            throw DicomSourceFrameIndex.Failure.invalidLayout
        }
        return data
    }

    public func dataBackedFrame(at frame: Int) async throws -> DicomDataBackedDecodedFrame {
        guard case .decoded(let frame) = try await request(Key(frame: frame, representation: .decoded)) else {
            throw DicomSourceFrameIndex.Failure.invalidLayout
        }
        return frame
    }

    public func frame(at frame: Int) async throws -> DicomDecodedFrame {
        guard case .arrayDecoded(let frame) = try await request(Key(frame: frame, representation: .arrayDecoded)) else {
            throw DicomSourceFrameIndex.Failure.invalidLayout
        }
        return frame
    }

    public func partialDecodeCapabilities(at frame: Int) async throws -> DicomPartialFrameDecodeCapabilities {
        try Task.checkCancellation()
        guard !closed else { throw DicomByteSource.Failure.closed }
        _ = try index.ranges(forFrame: frame)
        guard DicomJ2KSwiftBackend.qualifiedTransferSyntaxes.contains(index.metadata.transferSyntax.rawValue),
              DicomJ2KSwiftRolloutMode() != .disabled else { return .unavailable }
        guard case .capabilities(let value) = try await request(Key(frame: frame, representation: .capabilities)) else {
            throw DicomSourceFrameIndex.Failure.invalidLayout
        }
        return value
    }

    /// Capabilities plus the tier-2 packet index (bytes per quality layer, issue #2382) of one frame.
    public func partialDecodeCapabilitiesWithQualityIndex(at frame: Int) async throws -> DicomPartialFrameDecodeCapabilities {
        try Task.checkCancellation()
        guard !closed else { throw DicomByteSource.Failure.closed }
        _ = try index.ranges(forFrame: frame)
        guard DicomJ2KSwiftBackend.qualifiedTransferSyntaxes.contains(index.metadata.transferSyntax.rawValue),
              DicomJ2KSwiftRolloutMode() != .disabled else { return .unavailable }
        guard case .qualityIndexedCapabilities(let value) = try await request(Key(frame: frame, representation: .qualityIndexedCapabilities)) else {
            throw DicomSourceFrameIndex.Failure.invalidLayout
        }
        return value
    }

    public func frame(at frame: Int, partial request: DicomPartialFrameDecodeRequest) async throws -> DicomPartialFrameDecodeResult {
        try Task.checkCancellation()
        guard !closed else { throw DicomByteSource.Failure.closed }
        _ = try index.ranges(forFrame: frame)
        guard DicomJ2KSwiftBackend.qualifiedTransferSyntaxes.contains(index.metadata.transferSyntax.rawValue) else {
            throw DicomPartialFrameDecodeError.unsupportedTransferSyntax(index.metadata.transferSyntax.rawValue)
        }
        guard case .partial(let result) = try await self.request(Key(frame: frame, representation: .partial(request))) else {
            throw DicomSourceFrameIndex.Failure.invalidLayout
        }
        return result
    }

    private func request(_ key: Key) async throws -> Output {
        let frame = key.frame
        try Task.checkCancellation()
        guard !closed else { throw DicomByteSource.Failure.closed }
        guard consumerCount < limits.maximumConsumers else { throw DicomByteSource.Failure.concurrentReadLimit }
        let ranges = try index.ranges(forFrame: frame)
        var bytes = 0
        for range in ranges {
            guard range.count <= limits.maximumFrameBytes - bytes else { throw DicomSourceFrameIndex.Failure.frameLimit }
            bytes += range.count
        }
        let reservation: Int
        let decoded = key.representation.decodesPixels ? try index.decodedByteCount() : 0
        if key.representation == .raw {
            guard bytes <= limits.maximumInFlightBytes / 2 else { throw DicomSourceFrameIndex.Failure.frameLimit }
            reservation = bytes * 2
        } else {
            guard decoded <= limits.maximumFrameBytes else { throw DicomSourceFrameIndex.Failure.frameLimit }
            // Conservative reservations for owned input, assembly/writer buffers, decoded
            // output and codec scratch. Codec-specific limits remain enforced by the reader.
            var remaining = limits.maximumInFlightBytes
            for (size, factor) in [(bytes, 4), (index.metadata.metadataCopiedBytes, 4), (decoded, 8), (8192, 1)] {
                guard size <= remaining / factor else { throw DicomSourceFrameIndex.Failure.frameLimit }
                remaining -= size * factor
            }
            reservation = limits.maximumInFlightBytes - remaining
        }
        if let job = jobs[key] {
            guard !job.task.isCancelled else { throw DicomByteSource.Failure.concurrentReadLimit }
        } else {
            guard jobs.count < limits.maximumInFlightFrames,
                  reservation <= limits.maximumInFlightBytes - reservedBytes else {
                throw DicomByteSource.Failure.concurrentReadLimit
            }
        }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            let result: Output = try await withCheckedThrowingContinuation { continuation in
                if var job = jobs[key] {
                    job.waiters[waiter] = continuation
                    jobs[key] = job
                    sharedRequests += 1
                } else {
                    let index = self.index
                    let source = self.source
                    let maximumFrameBytes = limits.maximumFrameBytes
                    let admission = memoryAdmission
                    let compressedCapacity = bytes * (key.representation == .raw ? 2 : 4)
                    let memoryRequest = DicomFrameMemoryAdmission.Request(
                        compressedCapacity: compressedCapacity, pixelCapacity: decoded,
                        scratchCapacity: reservation - compressedCapacity - decoded
                    )
                    let task = Task {
                        var result: Result<Output, Error>
                        do {
                            let memory = try await admission?.reserve(memoryRequest)
                            let context = DicomDecodeWorkContext(memory: memory, shadowSession: shadowSession)
                            result = await DicomDecodeWorkContext.$current.withValue(context) {
                                var result: Result<Output, Error>
                                do {
                                    try Task.checkCancellation()
                                    let raw = try await index.frameData(at: frame, from: source, maximumFrameBytes: maximumFrameBytes)
                                    if key.representation == .raw {
                                        if let layout = index.nativeLayout, layout.eightBitSamplesAreWordSwapped {
                                            var ordered = raw
                                            for offset in stride(from: 0, to: ordered.count - 1, by: 2) {
                                                ordered.swapAt(offset, offset + 1)
                                            }
                                            let leading = try index.wordSwapLeadingBytes(forFrame: frame)
                                            result = .success(.bytes(Data(ordered.dropFirst(leading).prefix(layout.bitsPerFrame / 8))))
                                        } else {
                                            result = .success(.bytes(raw))
                                        }
                                    } else {
                                        let part10 = try index.part10Data(frame: frame, rawFrame: raw)
                                        await source.recordCompatibilityCopy(part10.count)
                                        if key.representation == .decoded {
                                            let decoded = try await index.decode(frame: frame, part10: part10)
                                            guard decoded.pixels.data.count <= maximumFrameBytes else { throw DicomSourceFrameIndex.Failure.frameLimit }
                                            result = .success(.decoded(decoded))
                                        } else if key.representation == .arrayDecoded {
                                            result = .success(.arrayDecoded(try await index.decodeArray(frame: frame, part10: part10)))
                                        } else if case .partial(let request) = key.representation {
                                            result = .success(.partial(try await index.decodePartial(frame: frame, part10: part10, request: request)))
                                        } else if key.representation == .capabilities {
                                            let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: part10))
                                            result = .success(.capabilities(try await reader.partialDecodeCapabilities(at: 0)))
                                        } else if key.representation == .qualityIndexedCapabilities {
                                            let reader = try DicomDecodedFrameReader(decoder: DCMDecoder(data: part10))
                                            result = .success(.qualityIndexedCapabilities(try await reader.partialDecodeCapabilitiesWithQualityIndex(at: 0)))
                                        } else { result = .success(.bytes(part10)) }
                                    }
                                    if key.representation.decodesPixels, let memory, case .success(let output) = result {
                                        let owner = try memory.retainOutput(byteCount: output.byteCount)
                                        context.retainOutput(owner)
                                        result = .success(output.retaining(owner))
                                    }
                                    try await source.checkOpen()
                                } catch { result = .failure(error) }
                                await context.waitForWorkers()
                                memory?.finishOperation()
                                return result
                            }
                        } catch { result = .failure(error) }
                        complete(key: key, result: result)
                    }
                    jobs[key] = Job(task: task, reservedBytes: reservation, waiters: [waiter: continuation])
                    reservedBytes += reservation
                }
            }
            try Task.checkCancellation()
            guard !closed else { throw DicomByteSource.Failure.closed }
            return result
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
    }

    private func cancel(key: Key, waiter: UUID) {
        guard var job = jobs[key], let continuation = job.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty { job.task.cancel() }
        // Keep the reservation until the worker actually finishes, even when its
        // transport delays cancellation. New requests cannot overbook those bytes.
        jobs[key] = job
    }

    private func complete(key: Key, result: Result<Output, Error>) {
        guard let job = jobs.removeValue(forKey: key) else { return }
        reservedBytes -= job.reservedBytes
        if case .success(let data) = result {
            let total = materializedBytes.addingReportingOverflow(data.byteCount)
            materializedBytes = total.overflow ? Int.max : total.partialValue
        }
        for waiter in job.waiters.values {
            if closed { waiter.resume(throwing: DicomByteSource.Failure.closed) }
            else { waiter.resume(with: result) }
        }
    }

    public nonisolated func frames(in range: Range<Int>? = nil) throws -> DicomSourceFrameSequence {
        let selection = range ?? 0..<index.frameCount
        guard selection.lowerBound >= 0, selection.upperBound <= index.frameCount else {
            throw DicomSourceFrameIndex.Failure.invalidLayout
        }
        return DicomSourceFrameSequence(session: self, range: selection)
    }

    public func close() async {
        closed = true
        shadowSession.close()
        for (key, var job) in jobs {
            job.task.cancel()
            for waiter in job.waiters.values { waiter.resume(throwing: DicomByteSource.Failure.closed) }
            job.waiters.removeAll()
            jobs[key] = job
        }
        await DicomShadowExecutor.shared.cancel(session: shadowSession)
        await source.close()
    }
}
