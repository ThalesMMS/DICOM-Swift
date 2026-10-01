import Foundation

public struct DicomDeformableSpatialRegistrationItem: Equatable, Sendable {
    public let sourceFrameOfReferenceUID: String
    public let referencedImages: [DicomSourceImageReference]
    public let transformationComment: String?
    public let registrationTypeCode: DicomCodedConcept?
    public let preMatrix: DicomSpatialRegistrationMatrix?
    public let postMatrix: DicomSpatialRegistrationMatrix?
    public let grid: DicomDeformableRegistrationGrid?
    public let usedFiducials: [DicomRegistrationUsedFiducial]

    public init(sourceFrameOfReferenceUID: String, referencedImages: [DicomSourceImageReference] = [],
                transformationComment: String? = nil, registrationTypeCode: DicomCodedConcept? = nil,
                preMatrix: DicomSpatialRegistrationMatrix? = nil, postMatrix: DicomSpatialRegistrationMatrix? = nil,
                grid: DicomDeformableRegistrationGrid? = nil, usedFiducials: [DicomRegistrationUsedFiducial] = []) {
        self.sourceFrameOfReferenceUID = sourceFrameOfReferenceUID
        self.referencedImages = referencedImages
        self.transformationComment = transformationComment
        self.registrationTypeCode = registrationTypeCode
        self.preMatrix = preMatrix
        self.postMatrix = postMatrix
        self.grid = grid
        self.usedFiducials = usedFiducials
    }

    /// Registered RCS → Source RCS: M_post · (M_pre · P + Δ(P)), PS3.3 C.20.3.1.1.
    /// The displacement is sampled at the original registered point. No inverse is provided.
    public func sourcePoint(forRegisteredPoint point: SIMD3<Double>) -> SIMD3<Double>? {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        var result = point
        if let preMatrix { guard let mapped = preMatrix.mappedPoint(result) else { return nil }; result = mapped }
        if let grid { guard let displacement = grid.displacement(atRegisteredPoint: point) else { return nil }; result += displacement }
        if let postMatrix { return postMatrix.mappedPoint(result) }
        return result
    }
}

public struct DicomDeformableSpatialRegistrationDocument: Equatable, Sendable {
    public static let storageSOPClassUID = "1.2.840.10008.5.1.4.1.1.66.3"
    public let sopInstanceUID: String?
    public let registeredFrameOfReferenceUID: String
    public let contentDate: String?
    public let contentTime: String?
    public let instanceNumber: Int
    public let contentLabel: String
    public let contentDescription: String?
    public let contentCreatorName: String?
    public let registrations: [DicomDeformableSpatialRegistrationItem]

    public init(sopInstanceUID: String?, registeredFrameOfReferenceUID: String,
                contentDate: String?, contentTime: String?, registrations: [DicomDeformableSpatialRegistrationItem],
                instanceNumber: Int = 1, contentLabel: String = "REG", contentDescription: String? = nil,
                contentCreatorName: String? = nil) {
        self.sopInstanceUID = sopInstanceUID
        self.registeredFrameOfReferenceUID = registeredFrameOfReferenceUID
        self.contentDate = contentDate
        self.contentTime = contentTime
        self.registrations = registrations
        self.instanceNumber = instanceNumber
        self.contentLabel = contentLabel
        self.contentDescription = contentDescription
        self.contentCreatorName = contentCreatorName
    }
}

extension DCMDecoder {
    public var spatialRegistrationDiagnostics: [DicomSpatialRegistrationDiagnostic] {
        synchronized { DicomSpatialRegistrationParser.diagnostics(dataSet: dataSet) }
    }
}

public enum DicomDeformableSpatialRegistrationParser {
    public struct Result: Sendable {
        public let document: DicomDeformableSpatialRegistrationDocument?
        public let diagnostics: [DicomSpatialRegistrationDiagnostic]
    }

    /// Parse a native Part 10 registration without using the legacy image decoder's admission list.
    public static func parse(part10Data: Data) throws -> Result {
        let meta = try DicomPart10FileMetaParser.parse(part10Data)
        guard let uid = meta.transferSyntaxUID, let syntax = DicomTransferSyntax(uid: uid), !syntax.usesDataSetDeflate else {
            return .init(document: nil, diagnostics: [.init(code: .missingRequiredAttribute)])
        }
        let body = Data(part10Data[(part10Data.startIndex + meta.dataSetOffset)...])
        let parsed = try DicomEncodedDataSetValidator.validate(body, transferSyntax: syntax)
        guard let data = parsed.dataSet else {
            return .init(document: nil, diagnostics: [.init(code: .missingRequiredAttribute)])
        }
        return parse(dataSet: data)
    }

    public static func parse(dataSet: DicomDataSet) -> Result {
        guard dataSet.string(for: 0x00080016) == DicomDeformableSpatialRegistrationDocument.storageSOPClassUID else {
            return .init(document: nil, diagnostics: [])
        }
        var diagnostics: [DicomSpatialRegistrationDiagnostic] = []
        func record(_ code: DicomSpatialRegistrationDiagnostic.Code, _ index: Int? = nil) {
            diagnostics.append(.init(code: code, itemIndex: index))
        }
        let frame = dataSet.string(for: 0x00200052) ?? ""
        if frame.isEmpty { record(.missingRequiredAttribute) }
        var registrations: [DicomDeformableSpatialRegistrationItem] = []
        for (index, item) in dataSet.sequenceItems(for: 0x00640002).enumerated() {
            let data = item.dataSet
            let source = data.string(for: 0x00640003) ?? ""
            if source.isEmpty { record(.missingRequiredAttribute, index) }
            for tag in [0x0064000F, 0x00640010, 0x00640005] where data.contains(tag) {
                if data.sequenceItems(for: tag).count != 1 { record(.invalidSequenceCardinality, index) }
            }
            func matrix(_ tag: Int) -> DicomSpatialRegistrationMatrix? {
                guard let data = data.sequenceItems(for: tag).first?.dataSet else { return nil }
                diagnostics += DicomRegistrationCoding.matrixDiagnostics(data, item: index)
                return DicomRegistrationCoding.readMatrix(data)
            }
            var grid: DicomDeformableRegistrationGrid?
            if let gridData = data.sequenceItems(for: 0x00640005).first?.dataSet {
                let dims = gridData.ints(for: 0x00640007)
                let resolution = gridData.floats(for: 0x00640008)
                let orientation = gridData.decimalStrings(for: 0x00200037)
                let position = gridData.decimalStrings(for: 0x00200032)
                let dimensions = dims.count == 3 ? SIMD3(dims[0], dims[1], dims[2]) : .zero
                let count = DicomDeformableRegistrationGrid.valueCount(dimensions)
                if count == nil { record(.invalidGridDimensions, index) }
                if resolution.count != 3 || !resolution.allSatisfy({ $0.isFinite && $0 > 0 }) { record(.invalidGridResolution, index) }
                if !DicomDeformableRegistrationGrid.validOrientation(orientation) { record(.invalidGridOrientation, index) }
                if position.count != 3 || !position.allSatisfy(\.isFinite) { record(.invalidGridPosition, index) }
                let vectors = DicomRegistrationCoding.vectors(gridData)
                let byteCount = gridData[0x00640009]?.bytesValue?.count ?? vectors.count * 4
                if count == nil || count != vectors.count || byteCount % 4 != 0 || byteCount / 4 != count {
                    record(.vectorGridLengthMismatch, index)
                }
                if dims.count == 3, resolution.count == 3, position.count == 3 {
                    grid = .init(imageOrientationPatient: orientation, imagePositionPatient: SIMD3(position[0], position[1], position[2]),
                        dimensions: dimensions, resolution: SIMD3(resolution[0], resolution[1], resolution[2]), vectorGridData: vectors)
                    for offset in stride(from: 0, to: vectors.count - vectors.count % 3, by: 3) {
                        let triple = Array(vectors[offset..<offset + 3])
                        if !triple.allSatisfy(\.isFinite) && !triple.allSatisfy(\.isNaN) { record(.invalidVector, index); break }
                    }
                }
            }
            registrations.append(.init(sourceFrameOfReferenceUID: source,
                referencedImages: data.sequenceItems(for: 0x00081140).map { DicomRegistrationCoding.image($0.dataSet) },
                transformationComment: data.string(for: 0x300600C8),
                registrationTypeCode: data.sequenceItems(for: 0x0070030D).first.flatMap { DicomCodedConcept(dataSet: $0.dataSet) },
                preMatrix: matrix(0x0064000F), postMatrix: matrix(0x00640010), grid: grid,
                usedFiducials: DicomRegistrationCoding.fiducials(data)))
        }
        if !registrations.contains(where: { $0.grid != nil }) { record(.noGrid) }
        guard diagnostics.isEmpty else { return .init(document: nil, diagnostics: diagnostics) }
        return .init(document: .init(sopInstanceUID: dataSet.string(for: 0x00080018), registeredFrameOfReferenceUID: frame,
            contentDate: dataSet.string(for: 0x00080023), contentTime: dataSet.string(for: 0x00080033), registrations: registrations,
            instanceNumber: dataSet.int(for: 0x00200013) ?? 1, contentLabel: dataSet.string(for: 0x00700080) ?? "REG",
            contentDescription: nonEmpty(dataSet.string(for: 0x00700081)), contentCreatorName: nonEmpty(dataSet.string(for: 0x00700084))), diagnostics: [])
    }

    private static func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
}

extension DCMDecoder {
    /// Typed Deformable Spatial Registration document with its diagnostics; `document` is nil when the
    /// data set is not a `.66.3` instance or fails a Type 1 requirement.
    public var deformableSpatialRegistration: DicomDeformableSpatialRegistrationParser.Result {
        synchronized { DicomDeformableSpatialRegistrationParser.parse(dataSet: dataSet) }
    }
}
