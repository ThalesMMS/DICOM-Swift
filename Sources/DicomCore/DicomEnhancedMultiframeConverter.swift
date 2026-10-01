import Foundation
import simd

/// Converts the qualified Enhanced CT/MR single-stack profile into classic
/// CT/MR Image Storage instances without writing files or mutating a catalog.
public struct DicomEnhancedMultiframeConverter: Sendable {
    /// Caller-supplied identifiers for deterministic conversion output.
    public struct Identifiers: Equatable, Sendable {
        /// Series Instance UID assigned to every derived classic instance.
        public let seriesInstanceUID: String
        /// SOP Instance UIDs assigned in spatial output order.
        public let sopInstanceUIDs: [String]

        /// Creates the identifiers for one converted series.
        public init(seriesInstanceUID: String, sopInstanceUIDs: [String]) {
            self.seriesInstanceUID = seriesInstanceUID
            self.sopInstanceUIDs = sopInstanceUIDs
        }
    }

    /// One validated classic Part 10 instance produced from a source frame.
    public struct Instance: Equatable, Sendable {
        /// One-based frame number in the source Enhanced object.
        public let sourceFrameNumber: Int
        /// One-based instance number in spatial output order.
        public let instanceNumber: Int
        /// SOP Instance UID assigned to the derived instance.
        public let sopInstanceUID: String
        /// Reopened and validated Explicit VR Little Endian Part 10 bytes.
        public let part10Data: Data

        /// Creates a converted instance result.
        public init(
            sourceFrameNumber: Int,
            instanceNumber: Int,
            sopInstanceUID: String,
            part10Data: Data
        ) {
            self.sourceFrameNumber = sourceFrameNumber
            self.instanceNumber = instanceNumber
            self.sopInstanceUID = sopInstanceUID
            self.part10Data = part10Data
        }
    }

    /// Catalog-ready metadata collected while validating one derived instance.
    public struct InstanceMetadata: Equatable, Sendable {
        public let sopClassUID: String
        public let rows: Int
        public let columns: Int
        public let pixelSpacing: [Double]
        public let sliceThickness: Double
        public let imagePositionPatient: [Double]
        public let imageOrientationPatient: [Double]
        public let rescaleIntercept: Float
        public let rescaleSlope: Float
        public let windowCenters: [Float]
        public let windowWidths: [Float]
        public let bitsStored: Int
        public let photometricInterpretation: String
        public let pixelRepresentation: Int
        public let samplesPerPixel: Int
        public let smallestImagePixelValue: Int?
        public let largestImagePixelValue: Int?
        public let frameOfReferenceUID: String?
    }

    /// One incrementally emitted instance and metadata from its validation decoder.
    public struct ValidatedInstance: Equatable, Sendable {
        public let instance: Instance
        public let metadata: InstanceMetadata
    }

    /// Source and output identity produced before derived instances are retained by a caller.
    public struct ConversionSummary: Equatable, Sendable {
        public let sourceSOPClassUID: String
        public let sourceSOPInstanceUID: String
        public let sourceSeriesInstanceUID: String
        public let studyInstanceUID: String
        public let frameOfReferenceUID: String
        public let modality: String
        public let seriesDescription: String?
        public let seriesInstanceUID: String
    }

    /// Identity and instances produced by a complete in-memory conversion.
    public struct Result: Equatable, Sendable {
        /// Enhanced source SOP Class UID.
        public let sourceSOPClassUID: String
        /// Enhanced source SOP Instance UID.
        public let sourceSOPInstanceUID: String
        /// Enhanced source Series Instance UID.
        public let sourceSeriesInstanceUID: String
        /// New Series Instance UID shared by the derived instances.
        public let seriesInstanceUID: String
        /// Derived classic instances in spatial order.
        public let instances: [Instance]

        /// Creates a complete conversion result.
        public init(
            sourceSOPClassUID: String,
            sourceSOPInstanceUID: String,
            sourceSeriesInstanceUID: String,
            seriesInstanceUID: String,
            instances: [Instance]
        ) {
            self.sourceSOPClassUID = sourceSOPClassUID
            self.sourceSOPInstanceUID = sourceSOPInstanceUID
            self.sourceSeriesInstanceUID = sourceSeriesInstanceUID
            self.seriesInstanceUID = seriesInstanceUID
            self.instances = instances
        }
    }

    /// A typed reason why the source cannot be safely converted.
    public enum ConversionError: Error, Equatable, LocalizedError, Sendable {
        case unsupportedSOPClassUID(String)
        case invalidFrameCount(Int)
        case unsupportedTransferSyntax(String)
        case unsupportedPixelFormat(String)
        case missingFunctionalGroups
        case incompleteFunctionalGroups(expected: Int, actual: Int)
        case unsupportedDimensionOrganization
        case unresolvedSelection
        case incompleteGeometry(frameNumber: Int)
        case inconsistentOrientation(frameNumber: Int)
        case duplicateSlicePosition
        case invalidIdentifiers(expectedSOPInstanceUIDs: Int, actual: Int)
        case invalidIdentifier(String)
        case missingRequiredUID(String)
        case decodeFailed(frameNumber: Int, reason: String)
        case validationFailed(frameNumber: Int, reason: String)

        /// Human-readable conversion failure details.
        public var errorDescription: String? {
            switch self {
            case .unsupportedSOPClassUID(let uid):
                return "SOP Class \(uid) is not Enhanced CT or Enhanced MR Image Storage."
            case .invalidFrameCount(let count):
                return "Enhanced conversion requires more than one frame; the object declares \(count)."
            case .unsupportedTransferSyntax(let uid):
                return "Transfer Syntax \(uid) is outside the qualified native/RLE conversion profile."
            case .unsupportedPixelFormat(let reason):
                return "The Enhanced pixel format is unsupported: \(reason)"
            case .missingFunctionalGroups:
                return "Shared/Per-Frame Functional Groups are missing."
            case .incompleteFunctionalGroups(let expected, let actual):
                return "Per-Frame Functional Groups cover \(actual) of \(expected) frames."
            case .unsupportedDimensionOrganization:
                return "Only one Stack ID plus In-Stack Position Number dimension is supported."
            case .unresolvedSelection:
                return "The requested dimension selection is missing or has duplicate frame coordinates."
            case .incompleteGeometry(let frameNumber):
                return "Frame \(frameNumber) has incomplete plane geometry or Pixel Measures."
            case .inconsistentOrientation(let frameNumber):
                return "Frame \(frameNumber) has an orientation inconsistent with the source stack."
            case .duplicateSlicePosition:
                return "The Enhanced object contains duplicate slice positions."
            case .invalidIdentifiers(let expected, let actual):
                return "Conversion requires \(expected) SOP Instance UIDs, but received \(actual)."
            case .invalidIdentifier(let reason):
                return "Conversion output identifiers are invalid: \(reason)"
            case .missingRequiredUID(let name):
                return "The source object is missing \(name)."
            case .decodeFailed(let frameNumber, let reason):
                return "Frame \(frameNumber) could not be decoded: \(reason)"
            case .validationFailed(let frameNumber, let reason):
                return "Derived frame \(frameNumber) failed Part 10 validation: \(reason)"
            }
        }
    }

    private static let enhancedCTSOPClassUID = "1.2.840.10008.5.1.4.1.1.2.1"
    private static let enhancedMRSOPClassUID = "1.2.840.10008.5.1.4.1.1.4.1"
    private static let legacyConvertedCTSOPClassUID = "1.2.840.10008.5.1.4.1.1.2.2"
    private static let legacyConvertedMRSOPClassUID = "1.2.840.10008.5.1.4.1.1.4.4"
    /// Unassigned Shared / Per-Frame Converted Attributes (PS3.3 C.7.6.16.2.24/25): classic attributes a legacy
    /// conversion could not place, restored to the derived classic instance.
    private static let unassignedSharedConvertedAttributesSequence = 0x0020_9170
    private static let unassignedPerFrameConvertedAttributesSequence = 0x0020_9171
    private static let ctImageStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.2"
    private static let mrImageStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.4"

    /// Creates an Enhanced CT/MR converter.
    public init() {}

    /// Converts an Enhanced Part 10 file using generated or supplied output identifiers.
    public func convert(
        contentsOf url: URL, identifiers: Identifiers? = nil,
        selection: DicomEnhancedFramePartition.Selection? = nil
    ) throws -> Result {
        try retainedResult(decoder: DCMDecoder(contentsOf: url), identifiers: identifiers, selection: selection)
    }

    /// Converts Enhanced Part 10 bytes using generated or supplied output identifiers.
    public func convert(
        _ part10Data: Data, identifiers: Identifiers? = nil,
        selection: DicomEnhancedFramePartition.Selection? = nil
    ) throws -> Result {
        try retainedResult(decoder: DCMDecoder(data: part10Data), identifiers: identifiers, selection: selection)
    }

    /// Converts a file incrementally, emitting each validated instance before the next frame is processed.
    public func convert(
        contentsOf url: URL,
        identifiers: Identifiers? = nil,
        selection: DicomEnhancedFramePartition.Selection? = nil,
        instanceHandler: (ValidatedInstance) throws -> Void
    ) throws -> ConversionSummary {
        try convert(
            decoder: DCMDecoder(contentsOf: url),
            identifiers: identifiers,
            selection: selection,
            instanceHandler: instanceHandler
        )
    }

    /// Returns true when any nested sequence explicitly references the SOP
    /// Instance UID. Catalog orchestration uses this during preflight before
    /// replacing the source object.
    public func containsReference(contentsOf url: URL, toSOPInstanceUID uid: String) throws -> Bool {
        containsReference(in: try DCMDecoder(contentsOf: url).dataSet, toSOPInstanceUID: uid)
    }

    /// Returns true when nested sequence content in Part 10 bytes references the SOP Instance UID.
    public func containsReference(_ part10Data: Data, toSOPInstanceUID uid: String) throws -> Bool {
        containsReference(in: try DCMDecoder(data: part10Data).dataSet, toSOPInstanceUID: uid)
    }

    private func retainedResult(
        decoder: DCMDecoder, identifiers: Identifiers?, selection: DicomEnhancedFramePartition.Selection?
    ) throws -> Result {
        var instances: [Instance] = []
        let summary = try convert(decoder: decoder, identifiers: identifiers, selection: selection) { validated in
            instances.append(validated.instance)
        }
        return Result(
            sourceSOPClassUID: summary.sourceSOPClassUID,
            sourceSOPInstanceUID: summary.sourceSOPInstanceUID,
            sourceSeriesInstanceUID: summary.sourceSeriesInstanceUID,
            seriesInstanceUID: summary.seriesInstanceUID,
            instances: instances
        )
    }

    private func convert(
        decoder: DCMDecoder,
        identifiers: Identifiers?,
        selection: DicomEnhancedFramePartition.Selection?,
        instanceHandler: (ValidatedInstance) throws -> Void
    ) throws -> ConversionSummary {
        let sourceSOPClassUID = try requiredUID(decoder.info(for: .sopClassUID), name: "SOP Class UID")
        let classicSOPClassUID: String
        switch sourceSOPClassUID {
        case Self.enhancedCTSOPClassUID, Self.legacyConvertedCTSOPClassUID:
            classicSOPClassUID = Self.ctImageStorageSOPClassUID
        case Self.enhancedMRSOPClassUID, Self.legacyConvertedMRSOPClassUID:
            classicSOPClassUID = Self.mrImageStorageSOPClassUID
        default:
            throw ConversionError.unsupportedSOPClassUID(sourceSOPClassUID)
        }

        let frameReader = DicomDecodedFrameReader(decoder: decoder)
        let frameCount = frameReader.frameCount
        guard frameCount > 1 else { throw ConversionError.invalidFrameCount(frameCount) }
        try validateTransferSyntax(decoder.transferSyntaxUID)
        let photometricInterpretation = decoder.photometricInterpretation.uppercased()
        try validatePixelFormat(decoder, photometricInterpretation: photometricInterpretation)

        guard let groups = decoder.enhancedMultiframeFunctionalGroups else {
            throw ConversionError.missingFunctionalGroups
        }
        guard groups.perFrame.count == frameCount, groups.frameCount == frameCount else {
            throw ConversionError.incompleteFunctionalGroups(
                expected: frameCount,
                actual: groups.perFrame.count
            )
        }
        let orderedFrames = try validatedFrames(groups, selection: selection)

        let sourceSOPInstanceUID = try requiredUID(
            decoder.info(for: .sopInstanceUID),
            name: "SOP Instance UID"
        )
        let sourceSeriesInstanceUID = try requiredUID(
            decoder.info(for: .seriesInstanceUID),
            name: "Series Instance UID"
        )
        let studyInstanceUID = try requiredUID(
            decoder.info(for: .studyInstanceUID),
            name: "Study Instance UID"
        )
        let frameOfReferenceUID = try requiredUID(
            decoder.info(for: .frameOfReferenceUID),
            name: "Frame of Reference UID"
        )
        let modality = decoder.info(for: .modality)
        let seriesDescription = nonEmpty(decoder.info(for: .seriesDescription))
        let requestedIdentifiers = identifiers ?? Identifiers(
            seriesInstanceUID: DicomDataSetWriter.makeUID(),
            sopInstanceUIDs: orderedFrames.map { _ in DicomDataSetWriter.makeUID() }
        )
        let outputIdentifiers = try validatedIdentifiers(
            requestedIdentifiers,
            frameCount: orderedFrames.count,
            sourceSOPInstanceUID: sourceSOPInstanceUID,
            sourceSeriesInstanceUID: sourceSeriesInstanceUID
        )

        for (spatialIndex, frame) in orderedFrames.enumerated() {
            try Task.checkCancellation()
            let sourceFrameNumber = frame.index + 1
            let sopInstanceUID = outputIdentifiers.sopInstanceUIDs[spatialIndex]
            let decodedFrame: DicomDecodedFrame
            do {
                decodedFrame = try frameReader.frame(at: frame.index)
            } catch {
                throw ConversionError.decodeFailed(
                    frameNumber: sourceFrameNumber,
                    reason: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                )
            }

            var dataSet = decoder.dataSet
            stripMultiframeAttributes(from: &dataSet)
            dataSet.set(element(.sopClassUID, .UI, [classicSOPClassUID]))
            dataSet.set(element(.sopInstanceUID, .UI, [sopInstanceUID]))
            dataSet.set(element(.seriesInstanceUID, .UI, [outputIdentifiers.seriesInstanceUID]))
            dataSet.set(element(.instanceNumber, .IS, [String(spatialIndex + 1)]))
            dataSet.set(element(.imageType, .CS, ["DERIVED", "SECONDARY"]))
            dataSet.set(element(.photometricInterpretation, .CS, [photometricInterpretation]))
            flatten(frame.functionalGroups, into: &dataSet)
            restoreUnassignedConvertedAttributes(from: decoder.dataSet, frameIndex: frame.index, into: &dataSet)
            if classicSOPClassUID == Self.ctImageStorageSOPClassUID, !dataSet.contains(0x00180060) {
                let shared = decoder.dataSet[.sharedFunctionalGroupsSequence]?.sequenceItems.first
                let perFrame = decoder.dataSet[.perFrameFunctionalGroupsSequence]?.sequenceItems ?? []
                let frameDetails = perFrame.indices.contains(frame.index) ? perFrame[frame.index][0x00189325] : nil
                let details = (frameDetails ?? shared?[0x00189325])?.sequenceItems ?? []
                let voltages = details.compactMap { $0[0x00180060] }
                if let voltage = voltages.first, voltages.count == details.count,
                   voltages.allSatisfy({ $0.value == voltage.value }) {
                    dataSet.set(voltage)
                } else {
                    // Classic CT requires Type 2 KVP presence even when the source cannot supply a single value.
                    dataSet.set(.init(tag: 0x00180060, vr: .DS, value: .empty))
                }
            }
            dataSet.set(sourceImageSequence(
                sopClassUID: sourceSOPClassUID,
                sopInstanceUID: sourceSOPInstanceUID,
                frameNumber: sourceFrameNumber
            ))
            dataSet.set(DicomDataElement(
                tag: DicomTag.pixelData.rawValue,
                vr: decoder.bitDepth > 8 ? .OW : .OB,
                value: .bytes(try storedBytes(
                    from: decodedFrame,
                    decoder: decoder,
                    photometricInterpretation: photometricInterpretation
                ))
            ))

            let part10Data = try DicomDataSetWriter.part10Data(
                from: dataSet,
                options: DicomPart10WriterOptions(
                    transferSyntax: .explicitVRLittleEndian,
                    mediaStorageSOPClassUID: classicSOPClassUID,
                    mediaStorageSOPInstanceUID: sopInstanceUID
                )
            )
            let metadata = try validate(
                part10Data,
                expectedFrame: decodedFrame,
                frameNumber: sourceFrameNumber,
                classicSOPClassUID: classicSOPClassUID,
                seriesInstanceUID: outputIdentifiers.seriesInstanceUID,
                sopInstanceUID: sopInstanceUID,
                sourceSOPClassUID: sourceSOPClassUID,
                sourceSOPInstanceUID: sourceSOPInstanceUID,
                functionalGroups: frame.functionalGroups
            )
            try Task.checkCancellation()
            try instanceHandler(ValidatedInstance(
                instance: Instance(
                    sourceFrameNumber: sourceFrameNumber,
                    instanceNumber: spatialIndex + 1,
                    sopInstanceUID: sopInstanceUID,
                    part10Data: part10Data
                ),
                metadata: metadata
            ))
        }

        return ConversionSummary(
            sourceSOPClassUID: sourceSOPClassUID,
            sourceSOPInstanceUID: sourceSOPInstanceUID,
            sourceSeriesInstanceUID: sourceSeriesInstanceUID,
            studyInstanceUID: studyInstanceUID,
            frameOfReferenceUID: frameOfReferenceUID,
            modality: modality,
            seriesDescription: seriesDescription,
            seriesInstanceUID: outputIdentifiers.seriesInstanceUID
        )
    }

    private func validatedIdentifiers(
        _ identifiers: Identifiers,
        frameCount: Int,
        sourceSOPInstanceUID: String,
        sourceSeriesInstanceUID: String
    ) throws -> Identifiers {
        guard identifiers.sopInstanceUIDs.count == frameCount else {
            throw ConversionError.invalidIdentifiers(
                expectedSOPInstanceUIDs: frameCount,
                actual: identifiers.sopInstanceUIDs.count
            )
        }
        guard let seriesInstanceUID = normalizedUID(identifiers.seriesInstanceUID) else {
            throw ConversionError.invalidIdentifier("the Series Instance UID is malformed")
        }
        let sopInstanceUIDs = try identifiers.sopInstanceUIDs.map { value in
            guard let uid = normalizedUID(value) else {
                throw ConversionError.invalidIdentifier("a SOP Instance UID is malformed")
            }
            return uid
        }
        let outputUIDs = [seriesInstanceUID] + sopInstanceUIDs
        let sourceUIDs = Set([sourceSOPInstanceUID, sourceSeriesInstanceUID])
        guard Set(outputUIDs).count == outputUIDs.count else {
            throw ConversionError.invalidIdentifier("output UIDs must be unique")
        }
        guard sourceUIDs.isDisjoint(with: outputUIDs) else {
            throw ConversionError.invalidIdentifier("output UIDs must differ from the source identities")
        }
        return Identifiers(
            seriesInstanceUID: seriesInstanceUID,
            sopInstanceUIDs: sopInstanceUIDs
        )
    }

    private func validateTransferSyntax(_ uid: String) throws {
        guard let syntax = DicomTransferSyntax(uid: uid),
              syntax == .implicitVRLittleEndian
                || syntax == .explicitVRLittleEndian
                || syntax == .explicitVRBigEndian
                || syntax == .rleLossless else {
            throw ConversionError.unsupportedTransferSyntax(uid)
        }
    }

    private func validatePixelFormat(
        _ decoder: DCMDecoder,
        photometricInterpretation: String
    ) throws {
        guard decoder.samplesPerPixel == 1,
              photometricInterpretation == "MONOCHROME1"
                || photometricInterpretation == "MONOCHROME2" else {
            throw ConversionError.unsupportedPixelFormat(
                "requires one MONOCHROME1/MONOCHROME2 sample per pixel"
            )
        }
        let bitsStored = decoder.intValue(for: .bitsStored) ?? decoder.bitDepth
        let highBit = decoder.intValue(for: .highBit) ?? max(0, bitsStored - 1)
        guard decoder.bitDepth == 8 || decoder.bitDepth == 16,
              bitsStored > 0,
              bitsStored <= decoder.bitDepth,
              highBit == bitsStored - 1 else {
            throw ConversionError.unsupportedPixelFormat(
                "requires aligned 8/16-bit integer samples"
            )
        }
    }

    private func validatedFrames(
        _ groups: DicomEnhancedMultiframeFunctionalGroups,
        selection: DicomEnhancedFramePartition.Selection?
    ) throws -> [DicomEnhancedFrame] {
        let frames: [DicomEnhancedFrame]
        if let selection {
            guard let partition = try DicomEnhancedFramePartition.resolve(groups).first(where: {
                $0.selection == selection
            }), !partition.hasDuplicateCoordinates else {
                throw ConversionError.unresolvedSelection
            }
            let indices = Set(partition.frameIndices)
            frames = groups.framesInSpatialOrder.filter { indices.contains($0.index) }
        } else {
            frames = groups.framesInSpatialOrder
        }
        if let organization = groups.dimensionOrganization {
            let frameContentPointer = DicomTag.frameContentSequence.rawValue
            guard organization.organizationUIDs.count == 1,
                  let organizationUID = nonEmpty(organization.organizationUIDs[0]),
                  organization.indexes.count == 2,
                  organization.indexes.allSatisfy({
                      $0.organizationUID == organizationUID
                          && $0.functionalGroupPointer == frameContentPointer
                  }),
                  let stackIndex = organization.indexes.firstIndex(where: {
                      $0.dimensionIndexPointer == DicomTag.stackID.rawValue
                  }),
                  let positionIndex = organization.indexes.firstIndex(where: {
                      $0.dimensionIndexPointer == DicomTag.inStackPositionNumber.rawValue
                  }),
                  stackIndex != positionIndex else {
                throw ConversionError.unsupportedDimensionOrganization
            }

            var stacks = Set<String>()
            var positions = Set<String>()
            for frame in frames {
                guard let content = frame.functionalGroups.frameContent,
                      let stackID = nonEmpty(content.stackID ?? ""),
                      let inStackPosition = content.inStackPositionNumber,
                      content.temporalPositionIndex == nil,
                      content.frameAcquisitionNumber == nil,
                      content.dimensionIndexValues.count == 2,
                      content.dimensionIndexValues.allSatisfy({ $0 > 0 }),
                      inStackPosition > 0 else {
                    throw ConversionError.unsupportedDimensionOrganization
                }
                let stack = "\(content.dimensionIndexValues[stackIndex])|\(stackID)"
                stacks.insert(stack)
                guard positions.insert("\(stack)|\(content.dimensionIndexValues[positionIndex])").inserted else {
                    throw ConversionError.unsupportedDimensionOrganization
                }
            }
            guard stacks.count == 1 else {
                throw ConversionError.unsupportedDimensionOrganization
            }
        } else if frames.contains(where: { frame in
            guard let content = frame.functionalGroups.frameContent else { return false }
            return nonEmpty(content.stackID ?? "") != nil
                || content.inStackPositionNumber != nil
                || content.temporalPositionIndex != nil
                || content.frameAcquisitionNumber != nil
                || !content.dimensionIndexValues.isEmpty
        }) {
            throw ConversionError.unsupportedDimensionOrganization
        }

        let ordered = frames
        var referenceOrientation: DicomPlaneOrientation?
        var previousPosition: Double?
        for frame in ordered {
            let number = frame.index + 1
            guard let orientation = frame.functionalGroups.planeOrientation,
                  let position = frame.functionalGroups.planePosition,
                  let measures = frame.functionalGroups.pixelMeasures,
                  let spacing = measures.pixelSpacing,
                  isFinite(orientation.row),
                  isFinite(orientation.column),
                  abs(simd_length(orientation.row) - 1) < 1e-4,
                  abs(simd_length(orientation.column) - 1) < 1e-4,
                  abs(simd_dot(orientation.row, orientation.column)) < 1e-4,
                  spacing.x.isFinite,
                  spacing.y.isFinite,
                  spacing.x > 0,
                  spacing.y > 0 else {
                throw ConversionError.incompleteGeometry(frameNumber: number)
            }
            if let referenceOrientation,
               simd_length(referenceOrientation.row - orientation.row) >= 1e-4
                || simd_length(referenceOrientation.column - orientation.column) >= 1e-4 {
                throw ConversionError.inconsistentOrientation(frameNumber: number)
            }
            referenceOrientation = referenceOrientation ?? orientation
            let projected = simd_dot(position.imagePositionPatient, orientation.normal)
            guard projected.isFinite else {
                throw ConversionError.incompleteGeometry(frameNumber: number)
            }
            if let previousPosition, projected - previousPosition <= 1e-9 {
                throw ConversionError.duplicateSlicePosition
            }
            previousPosition = projected
        }
        return ordered
    }

    private func flatten(_ groups: DicomFrameFunctionalGroups, into dataSet: inout DicomDataSet) {
        if let position = groups.planePosition?.imagePositionPatient {
            dataSet.set(element(.imagePositionPatient, .DS, [position.x, position.y, position.z].map(decimal)))
        }
        if let orientation = groups.planeOrientation {
            dataSet.set(element(
                .imageOrientationPatient,
                .DS,
                [orientation.row.x, orientation.row.y, orientation.row.z,
                 orientation.column.x, orientation.column.y, orientation.column.z].map(decimal)
            ))
        }
        if let measures = groups.pixelMeasures {
            if let spacing = measures.pixelSpacing {
                dataSet.set(element(.pixelSpacing, .DS, [spacing.x, spacing.y].map(decimal)))
            }
            if let thickness = measures.sliceThickness {
                dataSet.set(element(.sliceThickness, .DS, [decimal(thickness)]))
            }
            if let spacing = measures.spacingBetweenSlices {
                dataSet.set(element(.sliceSpacing, .DS, [decimal(spacing)]))
            }
        }
        if let transformation = groups.pixelValueTransformation {
            dataSet.set(element(.rescaleIntercept, .DS, [decimal(transformation.rescaleIntercept)]))
            dataSet.set(element(.rescaleSlope, .DS, [decimal(transformation.rescaleSlope)]))
        }
        if let frameVOI = groups.frameVOI {
            dataSet.set(element(.windowCenter, .DS, frameVOI.windows.map { decimal($0.center) }))
            dataSet.set(element(.windowWidth, .DS, frameVOI.windows.map { decimal($0.width) }))
            let explanations = frameVOI.windows.compactMap(\.explanation)
            if explanations.count == frameVOI.windows.count {
                dataSet.set(element(.windowCenterWidthExplanation, .LO, explanations))
            } else {
                dataSet.remove(.windowCenterWidthExplanation)
            }
            if let function = frameVOI.lutFunction {
                dataSet.set(element(.voiLUTFunction, .CS, [function]))
            } else {
                dataSet.remove(.voiLUTFunction)
            }
        }
    }

    /// Elements of the Unassigned Shared/Per-Frame Converted Attributes functional groups become classic top-level
    /// attributes again; identity, pixel-structure and multi-frame elements are never taken from them.
    private func restoreUnassignedConvertedAttributes(from source: DicomDataSet, frameIndex: Int, into dataSet: inout DicomDataSet) {
        let shared = source[.sharedFunctionalGroupsSequence]?.sequenceItems.first?[Self.unassignedSharedConvertedAttributesSequence]?.sequenceItems.first?.dataSet.elements ?? []
        let perFrameItems = source[.perFrameFunctionalGroupsSequence]?.sequenceItems ?? []
        let perFrame = perFrameItems.indices.contains(frameIndex)
            ? perFrameItems[frameIndex][Self.unassignedPerFrameConvertedAttributesSequence]?.sequenceItems.first?.dataSet.elements ?? []
            : []
        let protected: Set<Int> = [
            DicomTag.sopClassUID.rawValue, DicomTag.sopInstanceUID.rawValue, DicomTag.seriesInstanceUID.rawValue, DicomTag.studyInstanceUID.rawValue,
            DicomTag.frameOfReferenceUID.rawValue, DicomTag.instanceNumber.rawValue, DicomTag.imageType.rawValue, DicomTag.pixelData.rawValue,
            DicomTag.numberOfFrames.rawValue, DicomTag.rows.rawValue, DicomTag.columns.rawValue, DicomTag.bitsAllocated.rawValue,
            DicomTag.bitsStored.rawValue, DicomTag.highBit.rawValue, DicomTag.pixelRepresentation.rawValue, DicomTag.samplesPerPixel.rawValue,
            DicomTag.photometricInterpretation.rawValue, DicomTag.sharedFunctionalGroupsSequence.rawValue, DicomTag.perFrameFunctionalGroupsSequence.rawValue,
            DicomTag.sourceImageSequence.rawValue
        ]
        for element in shared + perFrame where !protected.contains(element.tag) && element.group != 0x0002 && element.element != 0 {
            dataSet.set(element)
        }
        // Rescale Type travels with the Pixel Value Transformation group but has no typed field in the flattened form.
        let sharedTransformation = source[.sharedFunctionalGroupsSequence]?.sequenceItems.first?[.pixelValueTransformationSequence]?.sequenceItems.first
        let frameTransformation = perFrameItems.indices.contains(frameIndex) ? perFrameItems[frameIndex][.pixelValueTransformationSequence]?.sequenceItems.first : nil
        if let rescaleType = (frameTransformation ?? sharedTransformation)?[.rescaleType] {
            dataSet.set(rescaleType)
        }
    }

    private func stripMultiframeAttributes(from dataSet: inout DicomDataSet) {
        [
            DicomTag.numberOfFrames.rawValue,
            DicomTag.frameIncrementPointer.rawValue,
            DicomTag.sharedFunctionalGroupsSequence.rawValue,
            DicomTag.perFrameFunctionalGroupsSequence.rawValue,
            DicomTag.dimensionOrganizationSequence.rawValue,
            DicomTag.dimensionIndexSequence.rawValue,
            DicomTag.extendedOffsetTable.rawValue,
            DicomTag.extendedOffsetTableLengths.rawValue,
            DicomTag.pixelData.rawValue,
            0x0020_9161, // Concatenation UID
            0x0020_9162, // In-concatenation Number
            0x0020_9163, // In-concatenation Total Number
            0x0028_6010, // Representative Frame Number
            0x0018_1063, // Frame Time
            0x0018_1065  // Frame Time Vector
        ].forEach { dataSet.remove($0) }
    }

    private func sourceImageSequence(
        sopClassUID: String,
        sopInstanceUID: String,
        frameNumber: Int
    ) -> DicomDataElement {
        DicomDataElement(
            tag: DicomTag.sourceImageSequence.rawValue,
            vr: .SQ,
            value: .sequence([
                DicomSequenceItem(dataSet: DicomDataSet(elements: [
                    element(.referencedSOPClassUID, .UI, [sopClassUID]),
                    element(.referencedSOPInstanceUID, .UI, [sopInstanceUID]),
                    element(.referencedFrameNumber, .IS, [String(frameNumber)])
                ]))
            ])
        )
    }

    private func storedBytes(
        from frame: DicomDecodedFrame,
        decoder: DCMDecoder,
        photometricInterpretation: String
    ) throws -> Data {
        let inverted = photometricInterpretation == "MONOCHROME1"
        let signed = decoder.pixelRepresentationTagValue == 1
        switch frame.pixels {
        case .gray16(let pixels):
            var data = Data(capacity: pixels.count * 2)
            for value in pixels {
                let unInverted = inverted ? UInt16.max - value : value
                let pattern = signed
                    ? UInt16(bitPattern: Int16(truncatingIfNeeded: Int32(unInverted) + Int32(Int16.min)))
                    : unInverted
                data.append(UInt8(pattern & 0xFF))
                data.append(UInt8(pattern >> 8))
            }
            return data
        case .gray8(let pixels):
            return Data(pixels.map { value in
                let unInverted = inverted ? UInt8.max - value : value
                return signed
                    ? UInt8(bitPattern: Int8(truncatingIfNeeded: Int(unInverted) - 128))
                    : unInverted
            })
        case .rgb8:
            throw ConversionError.unsupportedPixelFormat(
                "requires one MONOCHROME1/MONOCHROME2 sample per pixel"
            )
        }
    }

    private func validate(
        _ data: Data,
        expectedFrame: DicomDecodedFrame,
        frameNumber: Int,
        classicSOPClassUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String,
        sourceSOPClassUID: String,
        sourceSOPInstanceUID: String,
        functionalGroups: DicomFrameFunctionalGroups
    ) throws -> InstanceMetadata {
        do {
            let decoder = try DCMDecoder(data: data)
            guard decoder.info(for: .sopClassUID) == classicSOPClassUID,
                  decoder.info(for: .sopInstanceUID) == sopInstanceUID,
                  decoder.info(for: .seriesInstanceUID) == seriesInstanceUID,
                  decoder.nImages == 1,
                  !decoder.dataSet.contains(.numberOfFrames),
                  !decoder.dataSet.contains(.sharedFunctionalGroupsSequence),
                  !decoder.dataSet.contains(.perFrameFunctionalGroupsSequence),
                  !decoder.dataSet.contains(.dimensionOrganizationSequence),
                  !decoder.dataSet.contains(.dimensionIndexSequence),
                  !decoder.dataSet.contains(.extendedOffsetTable),
                  !decoder.dataSet.contains(.extendedOffsetTableLengths),
                  decoder.transferSyntaxUID == DicomTransferSyntax.explicitVRLittleEndian.rawValue,
                  decoder.dataSet.strings(for: .imageType).prefix(2) == ["DERIVED", "SECONDARY"] else {
                throw ConversionError.validationFailed(
                    frameNumber: frameNumber,
                    reason: "identity or multiframe attributes did not round-trip"
                )
            }
            try validateFlattenedAttributes(
                decoder.dataSet,
                functionalGroups: functionalGroups,
                sourceSOPClassUID: sourceSOPClassUID,
                sourceSOPInstanceUID: sourceSOPInstanceUID,
                sourceFrameNumber: frameNumber
            )
            let reopened = try DicomDecodedFrameReader(decoder: decoder).frame(at: 0)
            guard reopened.pixels == expectedFrame.pixels else {
                throw ConversionError.validationFailed(
                    frameNumber: frameNumber,
                    reason: "stored pixel values changed during round-trip"
                )
            }
            let dataSet = decoder.dataSet
            return InstanceMetadata(
                sopClassUID: decoder.info(for: .sopClassUID),
                rows: dataSet.int(for: .rows) ?? decoder.height,
                columns: dataSet.int(for: .columns) ?? decoder.width,
                pixelSpacing: dataSet.decimalStrings(for: .pixelSpacing),
                sliceThickness: dataSet.decimalString(for: .sliceThickness) ?? 0,
                imagePositionPatient: dataSet.decimalStrings(for: .imagePositionPatient),
                imageOrientationPatient: dataSet.decimalStrings(for: .imageOrientationPatient),
                rescaleIntercept: Float(dataSet.decimalString(for: .rescaleIntercept) ?? 0),
                rescaleSlope: Float(dataSet.decimalString(for: .rescaleSlope) ?? 1),
                windowCenters: dataSet.decimalStrings(for: .windowCenter).map(Float.init),
                windowWidths: dataSet.decimalStrings(for: .windowWidth).map(Float.init),
                bitsStored: dataSet.int(for: .bitsStored) ?? decoder.bitDepth,
                photometricInterpretation: decoder.photometricInterpretation,
                pixelRepresentation: decoder.pixelRepresentationTagValue,
                samplesPerPixel: decoder.samplesPerPixel,
                smallestImagePixelValue: dataSet.int(for: .smallestImagePixelValue),
                largestImagePixelValue: dataSet.int(for: .largestImagePixelValue),
                frameOfReferenceUID: nonEmpty(decoder.info(for: .frameOfReferenceUID))
            )
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError.validationFailed(
                frameNumber: frameNumber,
                reason: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            )
        }
    }

    private func validateFlattenedAttributes(
        _ dataSet: DicomDataSet,
        functionalGroups: DicomFrameFunctionalGroups,
        sourceSOPClassUID: String,
        sourceSOPInstanceUID: String,
        sourceFrameNumber: Int
    ) throws {
        guard let position = functionalGroups.planePosition?.imagePositionPatient,
              let orientation = functionalGroups.planeOrientation,
              let spacing = functionalGroups.pixelMeasures?.pixelSpacing,
              approximatelyEqual(
                  dataSet.decimalStrings(for: .imagePositionPatient),
                  [position.x, position.y, position.z]
              ),
              approximatelyEqual(
                  dataSet.decimalStrings(for: .imageOrientationPatient),
                  [orientation.row.x, orientation.row.y, orientation.row.z,
                   orientation.column.x, orientation.column.y, orientation.column.z]
              ),
              approximatelyEqual(dataSet.decimalStrings(for: .pixelSpacing), [spacing.x, spacing.y]) else {
            throw ConversionError.validationFailed(
                frameNumber: sourceFrameNumber,
                reason: "flattened plane geometry or Pixel Measures changed"
            )
        }
        if let measures = functionalGroups.pixelMeasures {
            guard optionalApproximatelyEqual(dataSet.decimalString(for: .sliceThickness), measures.sliceThickness),
                  optionalApproximatelyEqual(dataSet.decimalString(for: .sliceSpacing), measures.spacingBetweenSlices) else {
                throw ConversionError.validationFailed(
                    frameNumber: sourceFrameNumber,
                    reason: "flattened slice measures changed"
                )
            }
        }
        if let transformation = functionalGroups.pixelValueTransformation {
            guard optionalApproximatelyEqual(
                dataSet.decimalString(for: .rescaleIntercept),
                transformation.rescaleIntercept
            ), optionalApproximatelyEqual(
                dataSet.decimalString(for: .rescaleSlope),
                transformation.rescaleSlope
            ) else {
                throw ConversionError.validationFailed(
                    frameNumber: sourceFrameNumber,
                    reason: "flattened rescale values changed"
                )
            }
        }
        if let voi = functionalGroups.frameVOI {
            let explanations = voi.windows.compactMap(\.explanation)
            let expectedExplanations = explanations.count == voi.windows.count ? explanations : []
            guard approximatelyEqual(
                dataSet.decimalStrings(for: .windowCenter),
                voi.windows.map(\.center)
            ), approximatelyEqual(
                dataSet.decimalStrings(for: .windowWidth),
                voi.windows.map(\.width)
            ), dataSet.strings(for: .windowCenterWidthExplanation) == expectedExplanations,
               dataSet.string(for: .voiLUTFunction) == voi.lutFunction else {
                throw ConversionError.validationFailed(
                    frameNumber: sourceFrameNumber,
                    reason: "flattened Frame VOI values changed"
                )
            }
        }

        guard let source = dataSet.sequenceItems(for: .sourceImageSequence).first?.dataSet,
              source.string(for: .referencedSOPClassUID) == sourceSOPClassUID,
              source.string(for: .referencedSOPInstanceUID) == sourceSOPInstanceUID,
              source.int(for: .referencedFrameNumber) == sourceFrameNumber else {
            throw ConversionError.validationFailed(
                frameNumber: sourceFrameNumber,
                reason: "source SOP/frame reference changed"
            )
        }
    }

    private func approximatelyEqual(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 1e-9 }
    }

    private func optionalApproximatelyEqual(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none): true
        case (.some(let lhs), .some(let rhs)): abs(lhs - rhs) <= 1e-9
        default: false
        }
    }

    private func containsReference(in dataSet: DicomDataSet, toSOPInstanceUID uid: String) -> Bool {
        for element in dataSet.elements {
            if element.tag == DicomTag.referencedSOPInstanceUID.rawValue,
               element.stringValues.contains(uid) {
                return true
            }
            for item in element.sequenceItems where containsReference(in: item.dataSet, toSOPInstanceUID: uid) {
                return true
            }
        }
        return false
    }

    private func requiredUID(_ value: String, name: String) throws -> String {
        guard let value = nonEmpty(value) else {
            throw ConversionError.missingRequiredUID(name)
        }
        return value
    }

    private func normalizedUID(_ value: String) -> String? {
        let uid = value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))
        )
        let components = uid.split(separator: ".", omittingEmptySubsequences: false)
        guard !uid.isEmpty,
              uid.count <= 64,
              uid.utf8.allSatisfy({ $0 == 0x2E || (0x30...0x39).contains($0) }),
              components.allSatisfy({ component in
                  !component.isEmpty && (component.count == 1 || component.first != "0")
              }) else {
            return nil
        }
        return uid
    }

    private func isFinite(_ vector: SIMD3<Double>) -> Bool {
        vector.x.isFinite && vector.y.isFinite && vector.z.isFinite
    }

    private func element(_ tag: DicomTag, _ vr: DicomVR, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings(values))
    }

    private func decimal(_ value: Double) -> String {
        let locale = Locale(identifier: "en_US_POSIX")
        for precision in stride(from: 15, through: 1, by: -1) {
            let result = String(format: "%.*g", locale: locale, precision, value)
            if result.utf8.count <= 16 {
                return result
            }
        }
        return String(format: "%.1g", locale: locale, value)
    }

    private func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        return trimmed.isEmpty ? nil : trimmed
    }
}
