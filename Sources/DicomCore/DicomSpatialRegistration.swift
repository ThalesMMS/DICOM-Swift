import Foundation

public enum DicomFrameOfReferenceTransformationMatrixType: Equatable, Sendable {
    case rigid, rigidScale, affine, other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "RIGID": self = .rigid
        case "RIGID_SCALE": self = .rigidScale
        case "AFFINE": self = .affine
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .rigid: return "RIGID"
        case .rigidScale: return "RIGID_SCALE"
        case .affine: return "AFFINE"
        case .other(let value): return value
        }
    }
}

public struct DicomRegistrationUsedFiducial: Equatable, Sendable {
    public let reference: DicomSOPReference
    public let fiducialUID: String
    public init(reference: DicomSOPReference, fiducialUID: String) {
        self.reference = reference
        self.fiducialUID = fiducialUID
    }
}

public struct DicomRegistrationUsedSegment: Equatable, Sendable {
    public let reference: DicomSOPReference
    /// C.20.2 permits one segment number per sequence item.
    public let segmentNumber: Int
    public init(reference: DicomSOPReference, segmentNumber: Int) {
        self.reference = reference
        self.segmentNumber = segmentNumber
    }
}

public struct DicomRegistrationUsedROI: Equatable, Sendable {
    public let reference: DicomSOPReference
    public let roiNumber: Int
    public init(reference: DicomSOPReference, roiNumber: Int) {
        self.reference = reference
        self.roiNumber = roiNumber
    }
}

/// One transform matrix declared by a DICOM Spatial Registration object.
public struct DicomSpatialRegistrationMatrix: Equatable, Sendable {
    public var matrixType: DicomFrameOfReferenceTransformationMatrixType { .init(rawValue: type) }
    public let type: String
    public let rowMajorValues: [Double]

    public init(type: String, rowMajorValues: [Double]) {
        self.type = type
        self.rowMajorValues = rowMajorValues
    }
}

extension DicomSpatialRegistrationMatrix {
    public init(matrixType: DicomFrameOfReferenceTransformationMatrixType, rowMajorValues: [Double]) {
        self.init(type: matrixType.rawValue, rowMajorValues: rowMajorValues)
    }

    public func mappedPoint(_ point: SIMD3<Double>) -> SIMD3<Double>? {
        guard rowMajorValues.count == 16, rowMajorValues.allSatisfy(\.isFinite),
              Array(rowMajorValues[12...15]) == [0, 0, 0, 1],
              point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        let m = rowMajorValues
        let result = SIMD3(m[0]*point.x + m[1]*point.y + m[2]*point.z + m[3],
                           m[4]*point.x + m[5]*point.y + m[6]*point.z + m[7],
                           m[8]*point.x + m[9]*point.y + m[10]*point.z + m[11])
        return result.x.isFinite && result.y.isFinite && result.z.isFinite ? result : nil
    }
}

/// Registration of one source coordinate system into the document's registered coordinate system.
public struct DicomSpatialRegistrationItem: Equatable, Sendable {
    public let sourceFrameOfReferenceUID: String?
    public let referencedSOPInstanceUIDs: [String]
    public let matrices: [DicomSpatialRegistrationMatrix]
    public let referencedImages: [DicomSourceImageReference]
    public let transformationComment: String?
    public let registrationTypeCode: DicomCodedConcept?
    public let usedFiducials: [DicomRegistrationUsedFiducial]
    public let usedSegments: [DicomRegistrationUsedSegment]
    public let usedROIs: [DicomRegistrationUsedROI]

    /// Source RCS to Registered RCS, applying M1 first, then M2, then M3.
    public func registeredPoint(forSourcePoint point: SIMD3<Double>) -> SIMD3<Double>? {
        matrices.reduce(Optional(point)) { value, matrix in value.flatMap(matrix.mappedPoint) }
    }

    public init(
        sourceFrameOfReferenceUID: String?,
        referencedSOPInstanceUIDs: [String],
        matrices: [DicomSpatialRegistrationMatrix],
        referencedImages: [DicomSourceImageReference] = [],
        transformationComment: String? = nil,
        registrationTypeCode: DicomCodedConcept? = nil,
        usedFiducials: [DicomRegistrationUsedFiducial] = [],
        usedSegments: [DicomRegistrationUsedSegment] = [],
        usedROIs: [DicomRegistrationUsedROI] = []
    ) {
        self.sourceFrameOfReferenceUID = sourceFrameOfReferenceUID
        self.referencedSOPInstanceUIDs = referencedSOPInstanceUIDs
        self.matrices = matrices
        self.referencedImages = referencedImages
        self.transformationComment = transformationComment
        self.registrationTypeCode = registrationTypeCode
        self.usedFiducials = usedFiducials
        self.usedSegments = usedSegments
        self.usedROIs = usedROIs
    }
}

/// Parsed Spatial Registration Storage document before clinical transform validation.
public struct DicomSpatialRegistrationDocument: Equatable, Sendable {
    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.66.1"

    public let sopInstanceUID: String?
    public let registeredFrameOfReferenceUID: String
    public let registrations: [DicomSpatialRegistrationItem]
    public let contentDate: String?
    public let contentTime: String?
    public let instanceNumber: Int
    public let contentLabel: String
    public let contentDescription: String?
    public let contentCreatorName: String?

    public init(
        sopInstanceUID: String?,
        registeredFrameOfReferenceUID: String,
        registrations: [DicomSpatialRegistrationItem],
        contentDate: String? = nil, contentTime: String? = nil,
        instanceNumber: Int = 1, contentLabel: String = "REG",
        contentDescription: String? = nil, contentCreatorName: String? = nil
    ) {
        self.sopInstanceUID = sopInstanceUID
        self.registeredFrameOfReferenceUID = registeredFrameOfReferenceUID
        self.registrations = registrations
        self.contentDate = contentDate
        self.contentTime = contentTime
        self.instanceNumber = instanceNumber
        self.contentLabel = contentLabel
        self.contentDescription = contentDescription
        self.contentCreatorName = contentCreatorName
    }
}

extension DCMDecoder {
    public var spatialRegistration: DicomSpatialRegistrationDocument? {
        synchronized {
            DicomSpatialRegistrationParser.parse(dataSet: dataSet)
        }
    }
}

public enum DicomSpatialRegistrationParser {
    public static func parse(dataSet: DicomDataSet) -> DicomSpatialRegistrationDocument? {
        guard dataSet.string(for: .sopClassUID)?.dicomSpatialRegistrationValue ==
                DicomSpatialRegistrationDocument.storageSOPClassUID,
              let registeredFrame = dataSet.string(for: .frameOfReferenceUID)?.dicomSpatialRegistrationValue
        else {
            return nil
        }

        let registrationItems = dataSet.sequenceItems(for: .registrationSequence)
        guard !registrationItems.isEmpty else { return nil }

        var registrations: [DicomSpatialRegistrationItem] = []
        registrations.reserveCapacity(registrationItems.count)
        for registrationItem in registrationItems {
            guard let registration = parseRegistration(dataSet: registrationItem.dataSet) else { return nil }
            registrations.append(registration)
        }

        return DicomSpatialRegistrationDocument(
            sopInstanceUID: dataSet.string(for: .sopInstanceUID)?.dicomSpatialRegistrationValue,
            registeredFrameOfReferenceUID: registeredFrame,
            registrations: registrations,
            contentDate: dataSet.string(for: 0x00080023), contentTime: dataSet.string(for: 0x00080033),
            instanceNumber: dataSet.int(for: 0x00200013) ?? 1,
            contentLabel: dataSet.string(for: 0x00700080) ?? "REG",
            contentDescription: dataSet.string(for: 0x00700081)?.dicomSpatialRegistrationValue,
            contentCreatorName: dataSet.string(for: 0x00700084)?.dicomSpatialRegistrationValue
        )
    }

    /// Structural findings are separate from the legacy optional read model, preserving decoder behavior.
    public static func diagnostics(dataSet: DicomDataSet) -> [DicomSpatialRegistrationDiagnostic] {
        var result: [DicomSpatialRegistrationDiagnostic] = []
        for (index, item) in dataSet.sequenceItems(for: 0x00700308).enumerated() {
            let data = item.dataSet
            if data.string(for: 0x00200052)?.dicomSpatialRegistrationValue == nil && data.sequenceItems(for: 0x00081140).isEmpty {
                result.append(.init(code: .missingFrameAndReferences, itemIndex: index))
            }
            let registrations = data.sequenceItems(for: 0x00700309)
            if registrations.count != 1 { result.append(.init(code: .matrixRegistrationItemCount, itemIndex: index)) }
            for registration in registrations {
                for (matrixIndex, matrix) in registration.dataSet.sequenceItems(for: 0x0070030A).enumerated() {
                    result += DicomRegistrationCoding.matrixDiagnostics(matrix.dataSet, item: index, matrix: matrixIndex)
                }
            }
        }
        return result
    }

    private static func parseRegistration(dataSet: DicomDataSet) -> DicomSpatialRegistrationItem? {
        let sourceFrame = dataSet.string(for: .frameOfReferenceUID)?.dicomSpatialRegistrationValue
        let referencedImages = dataSet.sequenceItems(for: .referencedImageSequence)
        let referencedSOPs = referencedImages.compactMap {
            $0.dataSet.string(for: .referencedSOPInstanceUID)?.dicomSpatialRegistrationValue
        }
        guard referencedSOPs.count == referencedImages.count else { return nil }
        guard sourceFrame != nil || !referencedSOPs.isEmpty else { return nil }

        let matrixRegistrations = dataSet.sequenceItems(for: .matrixRegistrationSequence)
        guard matrixRegistrations.count == 1 else { return nil }
        let matrixItems = matrixRegistrations[0].dataSet.sequenceItems(for: .matrixSequence)
        guard !matrixItems.isEmpty else { return nil }

        var matrices: [DicomSpatialRegistrationMatrix] = []
        matrices.reserveCapacity(matrixItems.count)
        for matrixItem in matrixItems {
            let matrixDataSet = matrixItem.dataSet
            guard let type = matrixDataSet.string(for: .frameOfReferenceTransformationMatrixType)?
                    .dicomSpatialRegistrationValue,
                  matrixDataSet.element(for: .frameOfReferenceTransformationMatrix) != nil
            else {
                return nil
            }
            let values = matrixDataSet.decimalStrings(for: .frameOfReferenceTransformationMatrix)
            guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
            matrices.append(DicomSpatialRegistrationMatrix(type: type, rowMajorValues: values))
        }

        return DicomSpatialRegistrationItem(
            sourceFrameOfReferenceUID: sourceFrame,
            referencedSOPInstanceUIDs: Array(Set(referencedSOPs)).sorted(),
            matrices: matrices,
            referencedImages: referencedImages.map { DicomRegistrationCoding.image($0.dataSet) },
            transformationComment: matrixRegistrations[0].dataSet.string(for: 0x300600C8),
            registrationTypeCode: matrixRegistrations[0].dataSet.sequenceItems(for: 0x0070030D).first
                .flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
            usedFiducials: DicomRegistrationCoding.fiducials(dataSet),
            usedSegments: dataSet.sequenceItems(for: 0x00620012).compactMap {
                guard let ref = DicomSOPReference(data: $0.dataSet), let number = $0.dataSet.int(for: 0x0062000B) else { return nil }
                return .init(reference: ref, segmentNumber: number)
            },
            usedROIs: dataSet.sequenceItems(for: 0x00700315).compactMap {
                guard let ref = DicomSOPReference(data: $0.dataSet), let number = $0.dataSet.int(for: 0x30060084) else { return nil }
                return .init(reference: ref, roiNumber: number)
            }
        )
    }
}

private extension String {
    var dicomSpatialRegistrationValue: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return value.isEmpty ? nil : value
    }
}
