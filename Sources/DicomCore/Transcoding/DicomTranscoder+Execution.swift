//
//  DicomTranscoder+Execution.swift
//
//  Plan first, then execute with a bounded working set: the dataset header is written once, frames follow
//  one at a time (decoded, encoded or copied), offset tables are patched, and the artifact is published only
//  when complete. Routes the streaming writer cannot express fall back to the in-memory engine.
//

import Foundation

public extension DicomTranscoder {
    enum ExecutionError: Error, Equatable, Sendable, CustomStringConvertible {
        case codestreamContainerNotAllowed(frameIndex: Int, detail: String)
        case rewrapNotAllowed(sourceUID: String, destinationUID: String)
        case assemblyMismatch(String)
        case sourcePlanMismatch
        case writeFailed(String)

        public var description: String {
            switch self {
            case .codestreamContainerNotAllowed(let index, let detail): return "frame \(index) carries a file container instead of a codestream: \(detail)"
            case .rewrapNotAllowed(let source, let destination): return "codestreams of \(source) cannot be carried into \(destination) without re-encoding"
            case .assemblyMismatch(let reason): return "encoded frames do not fit the requested container: \(reason)"
            case .sourcePlanMismatch: return "source transfer syntax, frame count or pixel format differs from the execution plan"
            case .writeFailed(let reason): return "artifact could not be written: \(reason)"
            }
        }
    }

    // MARK: - Planning

    /// Qualifies the route and predicts the work without decoding a frame.
    func plan(
        _ data: Data,
        to destination: DicomTransferSyntax,
        intent: DicomEncodingIntent = .reversible,
        jpeg2000Options: DicomJPEG2000EncodingOptions? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DicomTranscodeExecutionPlan {
        try plan(decoder: try DCMDecoder(data: data), inputBytes: data.count, to: destination, intent: intent, environment: environment, jpeg2000Options: jpeg2000Options)
    }

    func plan(contentsOf url: URL, to destination: DicomTransferSyntax, intent: DicomEncodingIntent = .reversible,
              jpeg2000Options: DicomJPEG2000EncodingOptions? = nil,
              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> DicomTranscodeExecutionPlan {
        try plan(try Data(contentsOf: url, options: .mappedIfSafe), to: destination, intent: intent, jpeg2000Options: jpeg2000Options, environment: environment)
    }

    internal func plan(decoder: DCMDecoder, inputBytes: Int, to destination: DicomTransferSyntax, intent: DicomEncodingIntent,
                       environment: [String: String], jpeg2000Options: DicomJPEG2000EncodingOptions? = nil) throws -> DicomTranscodeExecutionPlan {
        let source = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID)) ?? .explicitVRLittleEndian
        let registryPlan = Self.executionPlan(from: source, to: destination, intent: intent, jpeg2000Options: jpeg2000Options)
        var diagnostics = registryPlan.diagnostics.map(\.message)
        let hasPixelData = decoder.dataSet.contains(.pixelData)
        let frameCount = hasPixelData ? max(1, decoder.nImages) : 0
        let format = hasPixelData ? Self.frameFormat(decoder: decoder, syntax: source) : nil
        let decodedFrameBytes = format.map { $0.rows * $0.columns * $0.samplesPerPixel * max(1, $0.bitsAllocated / 8) } ?? 0
        let sourceFrameBytes = Self.sourceFrameByteCounts(decoder: decoder, frameCount: frameCount, decodedFrameBytes: decodedFrameBytes)
        let rewrap = jpeg2000Options == nil && hasPixelData && source != destination && source.registryEntry.isCompressed && destination.registryEntry.isCompressed
            && Self.rewrapAllowed(from: source, to: destination) && !intent.isLossy
        let route: DicomTranscodeExecutionRoute
        if rewrap {
            route = .carryDataset(Self.compressedFrameDescriptor(decoder: decoder, syntax: destination))
        } else {
            route = try resolveExecutionRoute(decoder: decoder, source: source, destination: destination, intent: intent, environment: environment, jpeg2000Options: jpeg2000Options)
        }
        // JPEG 2000/HTJ2K frames inside a JP2/JPX/JPH wrapper are separated from the container without re-encoding
        // when the codestream itself is carried unchanged (same syntax or a superset syntax).
        // Part 2 groups frames into collection fragments, which do not use a per-frame fragment map.
        let unwrapContainers = try jpeg2000Options == nil && hasPixelData && source.registryEntry.isCompressed && (source == destination || rewrap)
            && [DicomCodecFamily.jpeg2000, .htj2k].contains(DicomCodecFamily.family(for: source))
            && !DicomJ2KPart2Profile.isPart2(source.rawValue)
            && Self.sourceFramesCarryContainers(decoder: decoder)
        if jpeg2000Options == nil, hasPixelData, source.registryEntry.isCompressed, source == destination || rewrap,
           let violation = Self.sourceCodestreamViolation(decoder: decoder, syntax: source) {
            diagnostics.append(unwrapContainers ? "\(violation); the frames are unwrapped to their raw codestreams without re-encoding" : violation)
            if rewrap, !unwrapContainers { throw ExecutionError.codestreamContainerNotAllowed(frameIndex: 0, detail: violation) }
        }
        let kind: DicomTranscodeExecutionPlan.Kind
        var steps: [DicomTranscodeExecutionPlan.Step] = []
        let lossy = intent.isLossy && hasPixelData
        switch route {
        case .carryDataset:
            if unwrapContainers {
                kind = .rewrap
                steps = [.carryDataset, .unwrapContainers(frames: frameCount), .encapsulate(offsetTables: .basic)]
            } else if source == destination {
                kind = .passThrough
                steps = [.carryDataset] + (hasPixelData && source.registryEntry.isCompressed ? [.copyEncapsulatedRegion(frames: frameCount)] : [])
            } else if rewrap {
                kind = .rewrap
                steps = [.carryDataset, .copyEncapsulatedRegion(frames: frameCount)]
            } else {
                kind = .rewriteDataset
                steps = [.carryDataset] + (destination.writeSupport.status == .deflatedDataset ? [.deflateDataset] : [])
            }
        case .decompress:
            kind = .decode
            steps = [.carryDataset, .decodeFrames(frames: frameCount, codec: Self.codecName(source)), .writeNativePixels(frames: frameCount)]
            if destination.writeSupport.status == .deflatedDataset { steps.append(.deflateDataset) }
        case .jpegRecompression, .jpegReconstruction:
            kind = .recompress
            steps = [.carryDataset, .copyEncapsulatedRegion(frames: frameCount), .encapsulate(offsetTables: .basic)]
        case .jpeg2000Part2:
            kind = source.registryEntry.isCompressed ? .transcode : .encode
            steps = [.carryDataset]
            if source.registryEntry.isCompressed { steps.append(.decodeFrames(frames: frameCount, codec: Self.codecName(source))) }
            // PS3.5 8.2.4: the frames are coded as components of collection codestreams, one fragment per collection.
            steps.append(.encodeFrames(frames: frameCount, codec: Self.codecName(destination)))
            steps.append(.encapsulate(offsetTables: .emptyBasic))
        case .jpegLS, .jpeg2000, .jpegXL, .rle, .deflatedFrames, .jpeg:
            kind = source.registryEntry.isCompressed ? .transcode : .encode
            steps = [.carryDataset]
            if source.registryEntry.isCompressed { steps.append(.decodeFrames(frames: frameCount, codec: Self.codecName(source))) }
            steps.append(.encodeFrames(frames: frameCount, codec: Self.codecName(destination)))
            steps.append(.encapsulate(offsetTables: Self.needsExtendedOffsets(inputBytes: inputBytes, decodedFrameBytes: decodedFrameBytes, frameCount: frameCount) ? .extended : .basic))
        }
        if lossy {
            steps.append(.assignNewSOPInstanceUID)
            steps.append(.recordLossHistory(method: Self.lossyMethod(destination)))
        }
        let streamable = Self.isStreamable(kind: kind, destination: destination, decoder: decoder)
        let workingSet: Int
        switch kind {
        case .passThrough, .rewrap, .rewriteDataset, .recompress: workingSet = streamable ? Self.streamChunkBytes : inputBytes
        case .decode: workingSet = decodedFrameBytes * 2
        case .encode, .transcode: workingSet = decodedFrameBytes * 2 + (sourceFrameBytes.max() ?? 0)
        }
        return DicomTranscodeExecutionPlan(
            source: source, destination: destination, intent: intent,
            jpeg2000Options: try jpeg2000Options?.resolved(descriptor: Self.compressedFrameDescriptor(decoder: decoder, syntax: destination), intent: intent),
            kind: kind, steps: steps, frameFormat: format,
            cost: .init(inputBytes: inputBytes, frameCount: frameCount, decodedFrameBytes: decodedFrameBytes,
                        sourceFrameByteCounts: sourceFrameBytes, workingSetBytes: workingSet),
            assignsNewSOPInstanceUID: lossy, isStreamable: streamable, diagnostics: diagnostics
        )
    }

    // MARK: - Execution

    /// Executes a plan. With `destinationURL` the artifact is staged next to it and renamed into place only when
    /// complete; without it the artifact is returned in memory. `retainEncodedFrames` keeps the codestreams of an
    /// encode so `assemble` can wrap them again without re-encoding.
    func execute(
        _ plan: DicomTranscodeExecutionPlan,
        source data: Data,
        destinationURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        retainEncodedFrames: Bool = false,
        progress: (@Sendable (DicomTranscodeProgress) -> Void)? = nil
    ) async throws -> DicomTranscodeExecutionResult {
        let started = Date()
        let decoder = try DCMDecoder(data: data)
        let source = DicomTransferSyntax(uid: decoder.info(for: .transferSyntaxUID)) ?? .explicitVRLittleEndian
        let hasPixelData = decoder.dataSet.contains(.pixelData)
        let frameCount = hasPixelData ? max(1, decoder.nImages) : 0
        let format = hasPixelData ? Self.frameFormat(decoder: decoder, syntax: source) : nil
        guard source == plan.source, frameCount == plan.cost.frameCount, format == plan.frameFormat else {
            throw ExecutionError.sourcePlanMismatch
        }
        var frames: [DicomTranscodeExecutionResult.FrameOutcome] = []
        var peak = 0
        var encoded: DicomEncodedFrameSet?
        let output: Data?
        let outputURL: URL?
        if plan.isStreamable, plan.kind != .recompress,
           !(plan.kind == .decode && plan.source == .deflatedImageFrameCompression && decoder.bitDepth == 1) {
            let sink = try StreamSink(destinationURL: destinationURL)
            do {
                try await stream(plan, decoder: decoder, data: data, sink: sink, environment: environment, retainEncodedFrames: retainEncodedFrames,
                                 progress: progress, frames: &frames, peak: &peak, encoded: &encoded)
                (output, outputURL) = try sink.finish()
            } catch {
                sink.abandon()
                throw error
            }
        } else {
            let bytes = try await transcode(decoder: decoder, to: plan.destination, intent: plan.intent, jpeg2000Options: plan.jpeg2000Options, environment: environment)
            peak = data.count + bytes.count
            frames = (0..<plan.cost.frameCount).map { .init(index: $0, inputBytes: plan.cost.sourceFrameByteCounts.indices.contains($0) ? plan.cost.sourceFrameByteCounts[$0] : 0, outputBytes: 0) }
            if let destinationURL {
                try Self.publish(bytes, to: destinationURL)
                output = nil; outputURL = destinationURL
            } else {
                output = bytes; outputURL = nil
            }
            progress?(.init(framesCompleted: plan.cost.frameCount, frameCount: plan.cost.frameCount, bytesWritten: bytes.count))
        }
        let outputBytes = output?.count ?? outputURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
        let sopInstanceUID: String
        if let output { sopInstanceUID = (try? DicomPart10FileMetaParser.parse(output).mediaStorageSOPInstanceUID) ?? "" }
        else if let outputURL { sopInstanceUID = (try? DicomPart10FileMetaParser.parse(try Data(contentsOf: outputURL, options: .mappedIfSafe)).mediaStorageSOPInstanceUID) ?? "" }
        else { sopInstanceUID = "" }
        return DicomTranscodeExecutionResult(
            data: output, outputURL: outputURL, sopInstanceUID: sopInstanceUID, frames: frames,
            observed: .init(outputBytes: outputBytes, peakWorkingSetBytes: peak, elapsed: Date().timeIntervalSince(started)),
            encodedFrames: encoded
        )
    }

    /// Wraps codestreams from an earlier execution into another container that accepts them unchanged.
    func assemble(_ frames: DicomEncodedFrameSet, from source: Data, as destination: DicomTransferSyntax, destinationURL: URL? = nil) throws -> Data? {
        guard frames.transferSyntax == destination || Self.rewrapAllowed(from: frames.transferSyntax, to: destination) else {
            throw ExecutionError.rewrapNotAllowed(sourceUID: frames.transferSyntax.rawValue, destinationUID: destination.rawValue)
        }
        let decoder = try DCMDecoder(data: source)
        guard decoder.nImages <= 1 ? frames.codestreams.count == 1 : frames.codestreams.count == decoder.nImages else {
            throw ExecutionError.assemblyMismatch("\(frames.codestreams.count) codestreams for \(max(1, decoder.nImages)) frames")
        }
        var dataSet = decoder.dataSet
        Self.replaceEncapsulatedPixelData(in: &dataSet, with: try Self.encapsulate(fragments: frames.codestreams))
        Self.applyDestinationPixelMetadata(to: &dataSet, destination: destination, descriptor: frames.descriptor, intent: .reversible)
        let bytes = try write(dataSet, decoder: decoder, transferSyntax: destination)
        if let destinationURL { try Self.publish(bytes, to: destinationURL); return nil }
        return bytes
    }

    // MARK: - Streaming

    private func stream(
        _ plan: DicomTranscodeExecutionPlan, decoder: DCMDecoder, data: Data, sink: StreamSink, environment: [String: String],
        retainEncodedFrames: Bool, progress: (@Sendable (DicomTranscodeProgress) -> Void)?,
        frames: inout [DicomTranscodeExecutionResult.FrameOutcome], peak: inout Int, encoded: inout DicomEncodedFrameSet?
    ) async throws {
        let frameCount = plan.cost.frameCount
        var dataSet = try Self.headerDataSet(decoder: decoder, plan: plan)
        let descriptor = Self.compressedFrameDescriptor(decoder: decoder, syntax: plan.destination)
        var outputSOPInstanceUID: String?
        var lossHistory: (uncompressed: Int, encoded: Int)?
        var appendedRatioByteOffset = 0
        switch plan.kind {
        case .passThrough, .rewrap:
            if let unwrapStep = plan.steps.first(where: { if case .unwrapContainers = $0 { return true }; return false }),
               case .unwrapContainers(let wrappedFrames) = unwrapStep {
                guard let encapsulated = decoder.encapsulatedPixelDataDescriptor else {
                    throw TranscodeError.unsupportedPixelShape(reason: "encapsulated Pixel Data region could not be located")
                }
                let reader = try DicomEncapsulatedPixelFrameReader(descriptor: encapsulated, fileData: decoder.dicomDataSnapshot())
                var fragments: [Data] = []
                var inputBytes = 0
                for index in 0..<max(wrappedFrames, reader.frameCount) where index < reader.frameCount {
                    try Task.checkCancellation()
                    let wrapped = try reader.frame(at: index).data
                    inputBytes += wrapped.count
                    do {
                        fragments.append(try DicomJ2KCodestreamInspector.unwrap(wrapped).codestream)
                    } catch {
                        throw ExecutionError.codestreamContainerNotAllowed(frameIndex: index, detail: "the JP2/JPX/JPH wrapper is malformed")
                    }
                }
                let encapsulation = try Self.encapsulate(fragments: fragments)
                try sink.write(try Self.headerBytes(dataSet, decoder: decoder, destination: plan.destination, pixelVR: .OB, nativeLength: nil))
                try sink.write(encapsulation.pixelData)
                frames = fragments.enumerated().map { .init(index: $0.offset, inputBytes: inputBytes / max(1, fragments.count), outputBytes: $0.element.count) }
                peak = encapsulation.pixelData.count
                progress?(.init(framesCompleted: frameCount, frameCount: frameCount, bytesWritten: sink.bytesWritten))
                break
            }
            guard let region = DicomPart10PixelDataPreserver.rawEncapsulatedPixelDataRegion(from: decoder) else {
                if decoder.dataSet.contains(.pixelData) { throw TranscodeError.unsupportedPixelShape(reason: "encapsulated Pixel Data region could not be located") }
                try sink.write(try write(decoder.dataSet, decoder: decoder, transferSyntax: plan.destination))
                return
            }
            try sink.write(try Self.headerBytes(dataSet, decoder: decoder, destination: plan.destination, pixelVR: .OB, nativeLength: nil))
            try Self.copy(region, to: sink, chunk: Self.streamChunkBytes)
            frames = [.init(index: 0, inputBytes: region.count, outputBytes: region.count)]
            peak = Self.streamChunkBytes
            progress?(.init(framesCompleted: frameCount, frameCount: frameCount, bytesWritten: sink.bytesWritten))
        case .rewriteDataset:
            try sink.write(try writeCarryingDataset(decoder: decoder, destination: plan.destination))
            peak = data.count
            progress?(.init(framesCompleted: frameCount, frameCount: frameCount, bytesWritten: sink.bytesWritten))
        case .decode:
            if plan.source == .deflatedImageFrameCompression {
                // The fragments are the native frame bytes: inflate each one to its exact length and stream it as is.
                let frameBytes = try Self.deflatedFrameByteCount(decoder: decoder)
                let total = frameBytes * frameCount
                try sink.write(try Self.headerBytes(dataSet, decoder: decoder, destination: plan.destination,
                                                    pixelVR: decoder.bitDepth > 8 ? .OW : .OB, nativeLength: total + (total.isMultiple(of: 2) ? 0 : 1)))
                let fragments = try Self.deflatedFrameReader(decoder: decoder)
                for index in 0..<frameCount {
                    try Task.checkCancellation()
                    let native = try Self.inflateNativeFrame(fragments, frameIndex: index, expectedByteCount: frameBytes)
                    try sink.write(native)
                    frames.append(.init(index: index, inputBytes: plan.cost.sourceFrameByteCounts.indices.contains(index) ? plan.cost.sourceFrameByteCounts[index] : 0, outputBytes: native.count))
                    peak = max(peak, native.count * 2)
                    progress?(.init(framesCompleted: index + 1, frameCount: frameCount, bytesWritten: sink.bytesWritten))
                }
                if !total.isMultiple(of: 2) { try sink.write(Data([0])) }
                break
            }
            let frameReader = DicomDecodedFrameReader(decoder: decoder)
            let samplesPerPixel = decoder.samplesPerPixel
            let frameBytes = plan.cost.decodedFrameBytes
            let total = frameBytes * frameCount
            if samplesPerPixel == 3 {
                dataSet.set(DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings(["RGB"])))
                dataSet.set(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0])))
            }
            try sink.write(try Self.headerBytes(dataSet, decoder: decoder, destination: plan.destination,
                                                pixelVR: decoder.bitDepth > 8 ? .OW : .OB, nativeLength: total + (total.isMultiple(of: 2) ? 0 : 1)))
            for index in 0..<frameCount {
                try Task.checkCancellation()
                let stored = try await storedFrameBytes(frameReader: frameReader, decoder: decoder, frameIndex: index, source: plan.source, environment: environment)
                guard stored.count == frameBytes else {
                    throw TranscodeError.unsupportedPixelShape(reason: "frame \(index) decoded to \(stored.count) bytes, expected \(frameBytes)")
                }
                try sink.write(stored)
                frames.append(.init(index: index, inputBytes: plan.cost.sourceFrameByteCounts.indices.contains(index) ? plan.cost.sourceFrameByteCounts[index] : 0, outputBytes: stored.count))
                peak = max(peak, stored.count * 2)
                progress?(.init(framesCompleted: index + 1, frameCount: frameCount, bytesWritten: sink.bytesWritten))
            }
            if !total.isMultiple(of: 2) { try sink.write(Data([0])) }
        case .encode, .transcode:
            let frameReader = DicomDecodedFrameReader(decoder: decoder)
            let extended = plan.steps.contains(.encapsulate(offsetTables: .extended))
            // A native source deflates its own frame bytes, so its Image Pixel attributes stay untouched.
            let rawNativeFrames = plan.destination == .deflatedImageFrameCompression && Self.deflatesNativeFrames(decoder: decoder)
            if !rawNativeFrames {
                Self.applyDestinationPixelMetadata(to: &dataSet, destination: plan.destination, descriptor: descriptor, intent: plan.intent)
            }
            if plan.assignsNewSOPInstanceUID {
                let uid = DicomDataSetWriter.makeUID()
                outputSOPInstanceUID = uid
                dataSet.set(DicomDataElement(tag: DicomTag.sopInstanceUID.rawValue, vr: .UI, value: .strings([uid])))
                // Loss history needs the byte counts: written after the frames through a reserved, patched header.
                let priorRatios = dataSet.strings(for: .lossyImageCompressionRatio)
                appendedRatioByteOffset = priorRatios.reduce(0) { $0 + $1.utf8.count + 1 }
                Self.applyLossyMetadata(to: &dataSet, destination: plan.destination, uncompressedByteCount: 0, encodedByteCount: 0,
                                        sourceSOPClassUID: decoder.info(for: .sopClassUID), sourceSOPInstanceUID: decoder.info(for: .sopInstanceUID))
            }
            if extended {
                dataSet.set(DicomDataElement(tag: DicomTag.extendedOffsetTable.rawValue, vr: .OV, value: .bytes(Data(count: 8 * frameCount))))
                dataSet.set(DicomDataElement(tag: DicomTag.extendedOffsetTableLengths.rawValue, vr: .OV, value: .bytes(Data(count: 8 * frameCount))))
            }
            let encoder = try Self.frameEncoder(
                for: plan.destination, intent: plan.intent, environment: environment,
                iccProfile: Self.iccProfileBytes(in: decoder.dataSet), jpeg2000Options: plan.jpeg2000Options
            )
            var codestreams: [Data] = []
            var offsets: [UInt64] = []
            var lengths: [UInt64] = []
            var uncompressed = 0
            var encodedTotal = 0
            var running: UInt64 = 0
            let header = try Self.headerBytes(dataSet, decoder: decoder, destination: plan.destination, pixelVR: .OB, nativeLength: nil,
                                              sopInstanceUID: outputSOPInstanceUID)
            try sink.write(header)
            let basicTableOffset = sink.bytesWritten + 8
            try sink.write(Self.item(Data(count: extended ? 0 : 4 * frameCount)))
            for index in 0..<frameCount {
                try Task.checkCancellation()
                let stored = rawNativeFrames
                    ? try Self.nativeFrameBytes(decoder: decoder, frameIndex: index)
                    : try await storedFrameBytes(frameReader: frameReader, decoder: decoder, frameIndex: index, source: plan.source, environment: environment)
                uncompressed += stored.count
                var codestream: Data
                do { codestream = try await encoder(stored, descriptor, index) } catch is CancellationError { throw CancellationError() } catch let error as TranscodeError { throw error } catch {
                    throw TranscodeError.encodeFailed(destinationUID: plan.destination.rawValue, frameIndex: index, reason: (error as? LocalizedError)?.errorDescription ?? "\(error)")
                }
                if let violation = Self.codestreamViolation(codestream, syntax: plan.destination) {
                    throw ExecutionError.codestreamContainerNotAllowed(frameIndex: index, detail: violation)
                }
                let encodedBytes = codestream.count
                if retainEncodedFrames { codestreams.append(codestream) }
                encodedTotal += encodedBytes
                lengths.append(UInt64(codestream.count))
                offsets.append(running)
                if !codestream.count.isMultiple(of: 2) { codestream.append(0) }
                running += UInt64(codestream.count) + 8
                try sink.write(Self.item(codestream))
                frames.append(.init(index: index, inputBytes: stored.count, outputBytes: encodedBytes))
                peak = max(peak, stored.count + codestream.count)
                progress?(.init(framesCompleted: index + 1, frameCount: frameCount, bytesWritten: sink.bytesWritten))
            }
            try sink.write(Data([0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0]))
            if extended {
                guard let eot = Self.locate(tag: 0x7FE00001, vr: "OV", length: 8 * frameCount, in: header),
                      let eotl = Self.locate(tag: 0x7FE00002, vr: "OV", length: 8 * frameCount, in: header) else {
                    throw ExecutionError.writeFailed("extended offset tables could not be located in the header")
                }
                try sink.patch(at: eot, with: Self.littleEndian(offsets))
                try sink.patch(at: eotl, with: Self.littleEndian(lengths))
            } else {
                guard !offsets.contains(where: { $0 > UInt64(UInt32.max) }) else { throw ExecutionError.writeFailed("frame offsets exceed the basic offset table range") }
                try sink.patch(at: basicTableOffset, with: Self.littleEndian(offsets.map { UInt32($0) }))
            }
            if plan.assignsNewSOPInstanceUID { lossHistory = (uncompressed, encodedTotal) }
            if retainEncodedFrames {
                encoded = DicomEncodedFrameSet(transferSyntax: plan.destination, descriptor: descriptor, codestreams: codestreams, decodedByteCount: uncompressed)
            }
        case .recompress:
            throw ExecutionError.writeFailed("recompression is not streamed")
        }
        if let lossHistory, let ratioOffset = try sink.locateInHeader(tag: DicomTag.lossyImageCompressionRatio.rawValue) {
            // Skip the prior values and their separators to patch only this step's fixed-width placeholder.
            let ratio = lossHistory.encoded > 0 ? Double(lossHistory.uncompressed) / Double(lossHistory.encoded) : 0
            try sink.patchRatio(at: ratioOffset + appendedRatioByteOffset, value: ratio)
        }
    }

    // MARK: - Header and pixel element

    /// The dataset that precedes the pixel payload: everything but Pixel Data and the offset tables.
    private static func headerDataSet(decoder: DCMDecoder, plan: DicomTranscodeExecutionPlan) throws -> DicomDataSet {
        var dataSet = decoder.dataSet
        dataSet.remove(.pixelData)
        dataSet.remove(.extendedOffsetTable)
        dataSet.remove(.extendedOffsetTableLengths)
        return dataSet
    }

    /// Part 10 bytes for the header with the Pixel Data element header appended: undefined length for
    /// encapsulated destinations, the exact length for native ones.
    private static func headerBytes(_ dataSet: DicomDataSet, decoder: DCMDecoder, destination: DicomTransferSyntax, pixelVR: DicomVR,
                                    nativeLength: Int?, sopInstanceUID: String? = nil) throws -> Data {
        var placeholder = dataSet
        let encapsulated = nativeLength == nil
        placeholder.set(DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: pixelVR,
                                         value: .bytes(encapsulated ? Data([0xFE, 0xFF, 0x00, 0xE0, 0, 0, 0, 0, 0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0]) : Data())))
        let sopClassUID = decoder.info(for: .sopClassUID)
        let sourceSOPInstanceUID = decoder.info(for: .sopInstanceUID)
        var bytes = try DicomDataSetWriter.part10Data(from: placeholder, options: DicomPart10WriterOptions(
            transferSyntax: destination, mediaStorageSOPClassUID: sopClassUID.isEmpty ? nil : sopClassUID,
            mediaStorageSOPInstanceUID: sopInstanceUID ?? (sourceSOPInstanceUID.isEmpty ? nil : sourceSOPInstanceUID)))
        let explicitVR = destination.isExplicitVR
        if encapsulated {
            // Strip the placeholder items (16 bytes); the undefined-length element header stays.
            guard bytes.count >= 16, bytes.suffix(16) == Data([0xFE, 0xFF, 0x00, 0xE0, 0, 0, 0, 0, 0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0]) else {
                throw ExecutionError.writeFailed("the writer did not place Pixel Data last")
            }
            bytes.removeLast(16)
        } else {
            let headerLength = explicitVR ? 12 : 8
            guard bytes.count >= headerLength, bytes.suffix(headerLength).prefix(4) == Data([0xE0, 0x7F, 0x10, 0x00]) else {
                throw ExecutionError.writeFailed("the writer did not place Pixel Data last")
            }
            bytes.removeLast(4)
            withUnsafeBytes(of: UInt32(nativeLength!).littleEndian) { bytes.append(contentsOf: $0) }
        }
        return bytes
    }

    static func item(_ payload: Data) -> Data {
        var data = Data([0xFE, 0xFF, 0x00, 0xE0])
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    private static func littleEndian<T: FixedWidthInteger>(_ values: [T]) -> Data {
        var data = Data(capacity: values.count * MemoryLayout<T>.size)
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    /// Byte offset of the value of an explicit-VR OV element with the given length in the header.
    private static func locate(tag: Int, vr: String, length: Int, in header: Data) -> Int? {
        var pattern = Data([UInt8(tag >> 16 & 0xFF), UInt8(tag >> 24 & 0xFF), UInt8(tag & 0xFF), UInt8(tag >> 8 & 0xFF)])
        pattern.append(contentsOf: vr.utf8)
        pattern.append(contentsOf: [0, 0])
        withUnsafeBytes(of: UInt32(length).littleEndian) { pattern.append(contentsOf: $0) }
        guard let range = header.range(of: pattern) else { return nil }
        return range.upperBound - header.startIndex
    }

    private static func copy(_ region: Data, to sink: StreamSink, chunk: Int) throws {
        var offset = region.startIndex
        while offset < region.endIndex {
            let end = min(offset + chunk, region.endIndex)
            try sink.write(region[offset..<end])
            offset = end
        }
    }

    static let streamChunkBytes = 4 * 1024 * 1024

    // MARK: - Frame encoders

    private typealias FrameEncoder = @Sendable (Data, DicomCompressedFrameDescriptor, Int) async throws -> Data

    private static func frameEncoder(
        for destination: DicomTransferSyntax, intent: DicomEncodingIntent, environment: [String: String],
        iccProfile: Data? = nil, jpeg2000Options: DicomJPEG2000EncodingOptions? = nil
    ) throws -> FrameEncoder {
        if destination == .rleLossless {
            return { stored, descriptor, _ in try encodeRLEFrame(stored, descriptor: descriptor) }
        }
        if destination == .deflatedImageFrameCompression {
            return { stored, _, _ in try DicomDeflatedFrameCodec.encodeFrame(stored) }
        }
        let backend: any DicomFrameCodecBackend
        switch DicomCodecFamily.family(for: destination) {
        case .jpegLS: backend = DicomJLSwiftBackend()
        case .jpeg2000, .htj2k: backend = DicomJ2KSwiftBackend()
        case .jpegXL: backend = DicomJXLSwiftBackend()
        case .jpeg: backend = DicomJPEGSwiftBackend()
        default:
            throw TranscodeError.routeUnsupported(sourceUID: "", destinationUID: destination.rawValue, diagnostics: ["No encoder is executable for \(destination.rawValue)."])
        }
        // The ICC Profile (0028,2000) rides inside JPEG XL codestreams (a passthrough); other backends ignore it.
        return { stored, descriptor, _ in
            try await backend.encode(DicomFrameEncodeRequest(
                frame: DicomCodecDecodedFrame(buffer: .owned(stored), width: descriptor.columns, height: descriptor.rows,
                                              bitsPerSample: descriptor.bitsStored, componentCount: descriptor.samplesPerPixel),
                descriptor: descriptor, targetTransferSyntaxUID: destination.rawValue, intent: intent,
                iccProfile: iccProfile, jpeg2000Options: jpeg2000Options))
        }
    }

    /// Photometric/planar attributes the destination codec implies for colour frames.
    static func applyDestinationPixelMetadata(to dataSet: inout DicomDataSet, destination: DicomTransferSyntax,
                                              descriptor: DicomCompressedFrameDescriptor, intent: DicomEncodingIntent) {
        guard descriptor.samplesPerPixel == 3 else { return }
        let photometric: String
        switch DicomCodecFamily.family(for: destination) {
        case .jpeg2000, .htj2k: photometric = intent.isLossy ? "YBR_ICT" : "YBR_RCT"
        // DCT JPEG carries YCbCr at full chroma resolution; lossless JPEG carries RGB without a transform.
        case .jpeg: photometric = DicomJPEGSwiftBackend.losslessTransferSyntaxes.contains(destination.rawValue) ? "RGB" : "YBR_FULL"
        default: photometric = "RGB"
        }
        dataSet.set(DicomDataElement(tag: DicomTag.photometricInterpretation.rawValue, vr: .CS, value: .strings([photometric])))
        dataSet.set(DicomDataElement(tag: DicomTag.planarConfiguration.rawValue, vr: .US, value: .unsignedIntegers([0])))
    }

    // MARK: - Codestream and container rules

    /// Transfer syntaxes whose codestreams another syntax accepts unchanged (superset relationships only).
    static func rewrapAllowed(from source: DicomTransferSyntax, to destination: DicomTransferSyntax) -> Bool {
        switch (source, destination) {
        case (.jpeg2000Part2MulticomponentLossless, .jpeg2000Part2Multicomponent),
             (.jpeg2000Lossless, .jpeg2000), (.htj2kLossless, .htj2k), (.htj2kLosslessRPCL, .htj2k),
             (.jpegLosslessFirstOrder, .jpegLossless):
            return true
        default:
            return false
        }
    }

    /// A codestream family's start marker; file containers (JP2/JPH/JXL boxes) are never Pixel Data.
    static func codestreamViolation(_ data: Data, syntax: DicomTransferSyntax) -> String? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return "codestream shorter than a marker" }
        let jp2 = bytes.count >= 12 && Array(bytes[4..<12]) == [0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
        let jxlBox = bytes.count >= 12 && Array(bytes[4..<12]) == [0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
        switch DicomCodecFamily.family(for: syntax) {
        case .jpeg2000, .htj2k:
            if jp2 { return "JP2/JPH box container" }
            return bytes[0] == 0xFF && bytes[1] == 0x4F && bytes[2] == 0xFF && bytes[3] == 0x51 ? nil : "missing SOC/SIZ markers"
        case .jpeg, .jpegLS:
            return bytes[0] == 0xFF && bytes[1] == 0xD8 ? nil : "missing SOI marker"
        case .jpegXL:
            if jxlBox { return "JXL box container" }
            return bytes[0] == 0xFF && bytes[1] == 0x0A ? nil : "missing JXL codestream signature"
        case .rle:
            return data.count >= 64 ? nil : "RLE header shorter than 64 bytes"
        default:
            return nil
        }
    }

    /// Whether any frame is wrapped, rejecting malformed containers before selecting a carry route.
    static func sourceFramesCarryContainers(decoder: DCMDecoder) throws -> Bool {
        guard let descriptor = decoder.encapsulatedPixelDataDescriptor else { return false }
        let reader = try DicomEncapsulatedPixelFrameReader(descriptor: descriptor, fileData: decoder.dicomDataSnapshot())
        var carriesContainers = false
        for index in 0..<reader.frameCount {
            do {
                let frame = try reader.frame(at: index).data
                let unwrapped = try DicomJ2KCodestreamInspector.unwrap(frame)
                if unwrapped.container != nil { carriesContainers = true }
            } catch {
                throw ExecutionError.codestreamContainerNotAllowed(frameIndex: index, detail: "frame could not be read or unwrapped: \(error)")
            }
        }
        return carriesContainers
    }

    static func sourceCodestreamViolation(decoder: DCMDecoder, syntax: DicomTransferSyntax) -> String? {
        guard let descriptor = decoder.encapsulatedPixelDataDescriptor,
              let reader = try? DicomEncapsulatedPixelFrameReader(descriptor: descriptor, fileData: decoder.dicomDataSnapshot()),
              reader.frameCount > 0, let first = try? reader.frame(at: 0).data else { return nil }
        return codestreamViolation(first, syntax: syntax).map { "source frame 1: \($0)" }
    }

    // MARK: - Plan helpers

    private static func frameFormat(decoder: DCMDecoder, syntax: DicomTransferSyntax) -> DicomTranscodeExecutionPlan.FrameFormat {
        let descriptor = compressedFrameDescriptor(decoder: decoder, syntax: syntax)
        return .init(transferSyntaxUID: syntax.rawValue, rows: descriptor.rows, columns: descriptor.columns, bitsAllocated: descriptor.bitsAllocated,
                     bitsStored: descriptor.bitsStored, samplesPerPixel: descriptor.samplesPerPixel,
                     photometricInterpretation: descriptor.photometricInterpretation, isEncapsulated: syntax.registryEntry.isCompressed)
    }

    private static func sourceFrameByteCounts(decoder: DCMDecoder, frameCount: Int, decodedFrameBytes: Int) -> [Int] {
        guard frameCount > 0 else { return [] }
        if decoder.compressedImage, let descriptor = decoder.encapsulatedPixelDataDescriptor,
           let reader = try? DicomEncapsulatedPixelFrameReader(descriptor: descriptor, fileData: decoder.dicomDataSnapshot()),
           let frames = try? reader.frames(), frames.count == frameCount {
            return frames.map { $0.fragments.reduce(0) { $0 + ($1.valueRange.count) } }
        }
        return Array(repeating: decodedFrameBytes, count: frameCount)
    }

    private static func needsExtendedOffsets(inputBytes: Int, decodedFrameBytes: Int, frameCount: Int) -> Bool {
        max(inputBytes, decodedFrameBytes * frameCount) > Int(UInt32.max)
    }

    private static func isStreamable(kind: DicomTranscodeExecutionPlan.Kind, destination: DicomTransferSyntax, decoder: DCMDecoder) -> Bool {
        if destination.writeSupport.status == .deflatedDataset || destination == .explicitVRBigEndian { return false }
        if kind == .recompress || kind == .rewriteDataset { return false }
        // JPEG 2000 Part 2 codes groups of frames into one collection codestream, so the object is written whole.
        if DicomJ2KPart2Profile.isPart2(destination.rawValue) { return false }
        // A native passthrough has no encapsulated region to copy; the carrying writer handles it in memory.
        if kind == .passThrough, !decoder.compressedImage { return false }
        // Elements sorted after Pixel Data would have to follow the streamed payload.
        if let last = decoder.dataSet.elements.last, last.tag > DicomTag.pixelData.rawValue { return false }
        return true
    }

    static func codecName(_ syntax: DicomTransferSyntax) -> String {
        if DicomJ2KPart2Profile.isPart2(syntax.rawValue) { return "jpeg-2000-part2" }
        return DicomCodecFamily.family(for: syntax)?.rawValue ?? syntax.registryEntry.codec.rawValue
    }

    static func lossyMethod(_ destination: DicomTransferSyntax) -> String {
        switch destination {
        case .jpegLSNearLossless: return "ISO_14495_1"
        case .jpegXL: return "ISO_18181_1"
        case .htj2k: return "ISO_15444_15"
        case .jpegBaseline, .jpegExtended, .jpegLossless, .jpegLosslessFirstOrder: return "ISO_10918_1"
        default: return "ISO_15444_1"
        }
    }

    static func publish(_ bytes: Data, to destinationURL: URL) throws {
        let temporary = destinationURL.deletingLastPathComponent().appendingPathComponent(".\(destinationURL.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            try bytes.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destinationURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw ExecutionError.writeFailed(error.localizedDescription)
        }
    }
}

/// Where streamed bytes go: a staged file next to the destination, or memory.
final class StreamSink {
    private let handle: FileHandle?
    private let temporary: URL?
    private let destination: URL?
    private var buffer = Data()
    private(set) var bytesWritten = 0
    private var header: Data?

    init(destinationURL: URL?) throws {
        destination = destinationURL
        if let destinationURL {
            let staged = destinationURL.deletingLastPathComponent().appendingPathComponent(".\(destinationURL.lastPathComponent).partial-\(UUID().uuidString)")
            guard FileManager.default.createFile(atPath: staged.path, contents: nil) else {
                throw DicomTranscoder.ExecutionError.writeFailed("could not create \(staged.lastPathComponent)")
            }
            do { handle = try FileHandle(forUpdating: staged) } catch {
                try? FileManager.default.removeItem(at: staged)
                throw DicomTranscoder.ExecutionError.writeFailed(error.localizedDescription)
            }
            temporary = staged
        } else {
            handle = nil
            temporary = nil
        }
    }

    func write(_ data: Data) throws {
        if header == nil { header = data }
        if let handle {
            do { try handle.write(contentsOf: data) } catch { throw DicomTranscoder.ExecutionError.writeFailed(error.localizedDescription) }
        } else {
            buffer.append(data)
        }
        bytesWritten += data.count
    }

    func patch(at offset: Int, with data: Data) throws {
        if let handle {
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
                try handle.seekToEnd()
            } catch { throw DicomTranscoder.ExecutionError.writeFailed(error.localizedDescription) }
        } else {
            buffer.replaceSubrange(offset..<offset + data.count, with: data)
        }
    }

    /// Offset of the DS value of a header element (explicit VR, 2-byte length), if it was written.
    func locateInHeader(tag: Int) throws -> Int? {
        guard let header else { return nil }
        let pattern = Data([UInt8(tag >> 16 & 0xFF), UInt8(tag >> 24 & 0xFF), UInt8(tag & 0xFF), UInt8(tag >> 8 & 0xFF), 0x44, 0x53])
        guard let range = header.range(of: pattern) else { return nil }
        return range.upperBound - header.startIndex + 2
    }

    func patchRatio(at offset: Int, value: Double) throws {
        var text = String(format: "%.6g", value)
        // The placeholder ratio is written as "0" padded to 16 characters by applyLossyMetadata's stream form.
        text = String(text.prefix(DicomTranscoder.ratioPlaceholderWidth))
        while text.count < DicomTranscoder.ratioPlaceholderWidth { text += " " }
        try patch(at: offset, with: Data(text.utf8))
    }

    func finish() throws -> (Data?, URL?) {
        if let handle, let temporary, let destination {
            do {
                try handle.close()
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw DicomTranscoder.ExecutionError.writeFailed(error.localizedDescription)
            }
            return (nil, destination)
        }
        return (buffer, nil)
    }

    func abandon() {
        try? handle?.close()
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }
}
