import Foundation

public struct DicomWholeSlideMicroscopyMetadata: Sendable, Equatable {
    public typealias OpticalPath = DicomWholeSlideOpticalPath

    public struct Tile: Sendable, Equatable {
        public let frameIndex: Int
        public let column: Int
        public let row: Int
        public let width: Int
        public let height: Int
        public let opticalPathIdentifier: String
        public let focalPlaneIndex: Int
        public let xOffsetMillimeters: Double?
        public let yOffsetMillimeters: Double?
        public let zOffsetMillimeters: Double

        public init(
            frameIndex: Int,
            column: Int,
            row: Int,
            width: Int,
            height: Int,
            opticalPathIdentifier: String,
            focalPlaneIndex: Int,
            zOffsetMillimeters: Double,
            xOffsetMillimeters: Double? = nil,
            yOffsetMillimeters: Double? = nil
        ) {
            self.frameIndex = frameIndex
            self.column = column
            self.row = row
            self.width = width
            self.height = height
            self.opticalPathIdentifier = opticalPathIdentifier
            self.focalPlaneIndex = focalPlaneIndex
            self.zOffsetMillimeters = zOffsetMillimeters
            self.xOffsetMillimeters = xOffsetMillimeters
            self.yOffsetMillimeters = yOffsetMillimeters
        }
    }

    public let dimensionOrganizationType: DicomDimensionOrganizationType
    public let imageType: DicomWholeSlideImageType
    public let pyramidUID: String?
    public let sopClassUID: String
    public let seriesUID: String
    public let frameOfReferenceUID: String?
    public let totalPixelMatrixOrigin: DicomSlideOrigin?
    public let imageOrientationSlide: [Double]
    public let imagedVolume: DicomWholeSlideImagedVolume?
    public let totalPixelMatrixFocalPlanes: Int?
    public let extendedDepthOfField: String?
    public let numberOfFocalPlanes: Int?
    public let distanceBetweenFocalPlanesMicrometers: Double?
    public let focusMethod: String?
    public let tilesOverlap: String?
    public let recommendedAbsentPixelCIELab: [Int]
    public let lossyImageCompression: String?
    public let lossyImageCompressionRatios: [Double]
    public let lossyImageCompressionMethods: [String]
    public let specimenLabelInImage: String?
    public let burnedInAnnotation: String?
    public let volumetricProperties: String?
    public let photometricInterpretation: String?
    public let samplesPerPixel: Int?
    public let bitsAllocated: Int?
    public let planarConfiguration: Int?
    public let sliceThickness: Double?
    public let specimen: DicomWholeSlideSpecimen?
    public let frameType: DicomWholeSlideImageType?
    public let slideLabel: DicomWholeSlideLabel?
    public let concatenation: DicomWholeSlideConcatenation?
    public let diagnostics: [DicomWholeSlideDiagnostic]
    public let unpositionedFrameIndices: [Int]
    public let tilesOverlapObserved: Bool

    public let sopInstanceUID: String
    public let matrixWidth: Int
    public let matrixHeight: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let frameCount: Int
    public let pixelSpacingXMillimeters: Double?
    public let pixelSpacingYMillimeters: Double?
    public let opticalPaths: [OpticalPath]
    public let focalPlaneOffsetsMillimeters: [Double]
    public let tiles: [Tile]
    public let specimenIdentifier: String?
    public let containerIdentifier: String?

    public init(
        sopInstanceUID: String,
        matrixWidth: Int,
        matrixHeight: Int,
        tileWidth: Int,
        tileHeight: Int,
        frameCount: Int,
        pixelSpacingXMillimeters: Double? = nil,
        pixelSpacingYMillimeters: Double? = nil,
        opticalPaths: [OpticalPath],
        focalPlaneOffsetsMillimeters: [Double],
        tiles: [Tile],
        specimenIdentifier: String? = nil,
        containerIdentifier: String? = nil,
        dimensionOrganizationType: DicomDimensionOrganizationType = .absent,
        imageType: DicomWholeSlideImageType = .init(),
        pyramidUID: String? = nil,
        sopClassUID: String = "",
        seriesUID: String = "",
        frameOfReferenceUID: String? = nil,
        totalPixelMatrixOrigin: DicomSlideOrigin? = nil,
        imageOrientationSlide: [Double] = [],
        imagedVolume: DicomWholeSlideImagedVolume? = nil,
        totalPixelMatrixFocalPlanes: Int? = nil,
        extendedDepthOfField: String? = nil,
        numberOfFocalPlanes: Int? = nil,
        distanceBetweenFocalPlanesMicrometers: Double? = nil,
        focusMethod: String? = nil,
        tilesOverlap: String? = nil,
        recommendedAbsentPixelCIELab: [Int] = [],
        lossyImageCompression: String? = nil,
        lossyImageCompressionRatios: [Double] = [],
        lossyImageCompressionMethods: [String] = [],
        specimenLabelInImage: String? = nil,
        burnedInAnnotation: String? = nil,
        volumetricProperties: String? = nil,
        photometricInterpretation: String? = nil,
        samplesPerPixel: Int? = nil,
        bitsAllocated: Int? = nil,
        planarConfiguration: Int? = nil,
        sliceThickness: Double? = nil,
        specimen: DicomWholeSlideSpecimen? = nil,
        frameType: DicomWholeSlideImageType? = nil,
        slideLabel: DicomWholeSlideLabel? = nil,
        concatenation: DicomWholeSlideConcatenation? = nil,
        diagnostics: [DicomWholeSlideDiagnostic] = [],
        unpositionedFrameIndices: [Int] = [],
        tilesOverlapObserved: Bool = false
    ) {
        self.sopInstanceUID = sopInstanceUID
        self.matrixWidth = matrixWidth
        self.matrixHeight = matrixHeight
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.frameCount = frameCount
        self.pixelSpacingXMillimeters = pixelSpacingXMillimeters
        self.pixelSpacingYMillimeters = pixelSpacingYMillimeters
        self.opticalPaths = opticalPaths
        self.focalPlaneOffsetsMillimeters = focalPlaneOffsetsMillimeters
        self.tiles = tiles
        self.specimenIdentifier = specimenIdentifier
        self.containerIdentifier = containerIdentifier
        self.dimensionOrganizationType = dimensionOrganizationType
        self.imageType = imageType
        self.pyramidUID = pyramidUID
        self.sopClassUID = sopClassUID
        self.seriesUID = seriesUID
        self.frameOfReferenceUID = frameOfReferenceUID
        self.totalPixelMatrixOrigin = totalPixelMatrixOrigin
        self.imageOrientationSlide = imageOrientationSlide
        self.imagedVolume = imagedVolume
        self.totalPixelMatrixFocalPlanes = totalPixelMatrixFocalPlanes
        self.extendedDepthOfField = extendedDepthOfField
        self.numberOfFocalPlanes = numberOfFocalPlanes
        self.distanceBetweenFocalPlanesMicrometers = distanceBetweenFocalPlanesMicrometers
        self.focusMethod = focusMethod
        self.tilesOverlap = tilesOverlap
        self.recommendedAbsentPixelCIELab = recommendedAbsentPixelCIELab
        self.lossyImageCompression = lossyImageCompression
        self.lossyImageCompressionRatios = lossyImageCompressionRatios
        self.lossyImageCompressionMethods = lossyImageCompressionMethods
        self.specimenLabelInImage = specimenLabelInImage
        self.burnedInAnnotation = burnedInAnnotation
        self.volumetricProperties = volumetricProperties
        self.photometricInterpretation = photometricInterpretation
        self.samplesPerPixel = samplesPerPixel
        self.bitsAllocated = bitsAllocated
        self.planarConfiguration = planarConfiguration
        self.sliceThickness = sliceThickness
        self.specimen = specimen
        self.frameType = frameType
        self.slideLabel = slideLabel
        self.concatenation = concatenation
        self.diagnostics = diagnostics
        self.unpositionedFrameIndices = unpositionedFrameIndices
        self.tilesOverlapObserved = tilesOverlapObserved

    }
}

public extension DCMDecoder {
    static let wholeSlideMicroscopyImageStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.77.1.6"
    static let confocalMicroscopyTiledPyramidalImageStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.77.1.9"

    var wholeSlideMicroscopyMetadata: DicomWholeSlideMicroscopyMetadata? {
        let dataSet = dataSet
        let sopClassUID = dataSet.stringValue(for: Tags.sopClassUID)
        guard sopClassUID == Self.wholeSlideMicroscopyImageStorageSOPClassUID ||
                sopClassUID == Self.confocalMicroscopyTiledPyramidalImageStorageSOPClassUID else {
            return nil
        }
        let matrixWidth = dataSet.integerValue(for: Tags.totalPixelMatrixColumns)
        let matrixHeight = dataSet.integerValue(for: Tags.totalPixelMatrixRows)
        let tileWidth = dataSet.integerValue(for: Tags.columns)
        let tileHeight = dataSet.integerValue(for: Tags.rows)
        let frameCount = max(1, dataSet.integerValue(for: Tags.numberOfFrames))
        guard matrixWidth > 0, matrixHeight > 0, tileWidth > 0, tileHeight > 0,
              frameCount <= 100_000_000 else { return nil }

        let paths = Self.opticalPaths(in: dataSet)
        let organization = DicomDimensionOrganizationType(rawValue: dataSet.stringValue(for: 0x0020_9311))
        let imageType = DicomWholeSlideImageType(rawValues: dataSet.strings(for: 0x0008_0008))
        let originData = dataSet.sequenceItems(for: Tags.totalPixelMatrixOriginSequence).first?.dataSet
        let origin: DicomSlideOrigin? = originData.flatMap {
            guard let x = $0.doubleValue(for: Tags.xOffsetSlide),
                  let y = $0.doubleValue(for: Tags.yOffsetSlide) else { return nil }
            return .init(xMillimeters: x, yMillimeters: y,
                         zMicrometers: $0.doubleValue(for: Tags.zOffsetSlide) ?? 0)
        }
        let orientation = dataSet.doubleValues(for: 0x0048_0102)
        let shared = dataSet.sequenceItems(for: Tags.sharedFunctionalGroupsSequence).first?.dataSet
        let measures = shared?.sequenceItems(for: Tags.pixelMeasuresSequence).first?.dataSet
        let spacing = Self.pixelSpacing(in: dataSet, matrixWidth: matrixWidth, matrixHeight: matrixHeight)
        let transform = DicomSlideCoordinateTransform(
            origin: origin, orientation: orientation, pixelSpacingXMillimeters: spacing?.x,
            pixelSpacingYMillimeters: spacing?.y, matrixColumns: matrixWidth, matrixRows: matrixHeight
        )
        let concatenation: DicomWholeSlideConcatenation? = [0x0020_9161, 0x0020_9162, 0x0020_9163, 0x0020_9228]
            .contains(where: { dataSet.element(for: $0) != nil }) ? .init(
                uid: dataSet.stringValue(for: 0x0020_9161), number: dataSet.int(for: 0x0020_9162),
                totalNumber: dataSet.int(for: 0x0020_9163), frameOffsetNumber: dataSet.int(for: 0x0020_9228)
            ) : nil
        let focalCount = dataSet.int(for: Tags.totalPixelMatrixFocalPlanes)
        let originZ = (originData?.doubleValue(for: Tags.zOffsetSlide) ?? 0) / 1000
        let sliceSpacing = measures?.doubleValue(for: 0x0018_0088)
        var focalOffsets: [Double] = []
        if organization == .tiledFull, let count = focalCount, count > 0, count <= 100_000,
           count == 1 || (sliceSpacing?.isFinite == true && sliceSpacing! >= 0) {
            focalOffsets = (0..<count).map { originZ + Double($0) * (sliceSpacing ?? 0) }
        } else if organization != .tiledFull {
            let frames = dataSet.sequenceItems(for: Tags.perFrameFunctionalGroupsSequence)
            focalOffsets = Array(Set(frames.compactMap {
                $0.dataSet.sequenceItems(for: Tags.planePositionSlideSequence).first?.dataSet
                    .doubleValue(for: Tags.zOffsetSlide).map { $0 / 1000 }
            }.filter(\.isFinite))).sorted()
        }
        var result = Self.positionTiles(
            in: dataSet, matrixWidth: matrixWidth, matrixHeight: matrixHeight,
            tileWidth: tileWidth, tileHeight: tileHeight, frameCount: frameCount,
            paths: paths, focalOffsets: focalOffsets, organization: organization,
            imageType: imageType, concatenation: concatenation, transform: transform
        )
        if !orientation.isEmpty && !DicomSlideCoordinateTransform.isOrthonormal(orientation) {
            result.diagnostics.append(.init(code: .invalidOrientation))
        }
        let volume: DicomWholeSlideImagedVolume? = {
            guard let width = dataSet.doubleValue(for: 0x0048_0001),
                  let height = dataSet.doubleValue(for: 0x0048_0002),
                  let depth = dataSet.doubleValue(for: 0x0048_0003) else { return nil }
            return .init(widthMillimeters: width, heightMillimeters: height, depthMicrometers: depth)
        }()
        let specimen = Self.specimen(in: dataSet)
        return DicomWholeSlideMicroscopyMetadata(
            sopInstanceUID: dataSet.stringValue(for: Tags.sopInstanceUID) ?? "",
            matrixWidth: matrixWidth, matrixHeight: matrixHeight,
            tileWidth: tileWidth, tileHeight: tileHeight, frameCount: frameCount,
            pixelSpacingXMillimeters: spacing?.x, pixelSpacingYMillimeters: spacing?.y,
            opticalPaths: paths, focalPlaneOffsetsMillimeters: focalOffsets, tiles: result.tiles,
            specimenIdentifier: specimen?.specimens.first?.identifier ?? dataSet.stringValue(for: Tags.specimenIdentifier),
            containerIdentifier: dataSet.stringValue(for: Tags.containerIdentifier),
            dimensionOrganizationType: organization, imageType: imageType,
            pyramidUID: dataSet.stringValue(for: 0x0008_0019), sopClassUID: sopClassUID ?? "",
            seriesUID: dataSet.stringValue(for: 0x0020_000E) ?? "",
            frameOfReferenceUID: dataSet.stringValue(for: 0x0020_0052),
            totalPixelMatrixOrigin: origin, imageOrientationSlide: orientation, imagedVolume: volume,
            totalPixelMatrixFocalPlanes: focalCount,
            extendedDepthOfField: dataSet.stringValue(for: 0x0048_0012),
            numberOfFocalPlanes: dataSet.int(for: Tags.numberOfFocalPlanes),
            distanceBetweenFocalPlanesMicrometers: dataSet.doubleValue(for: Tags.distanceBetweenFocalPlanes),
            focusMethod: dataSet.stringValue(for: 0x0048_0011), tilesOverlap: dataSet.stringValue(for: 0x0048_0304),
            recommendedAbsentPixelCIELab: dataSet.ints(for: 0x0048_0015),
            lossyImageCompression: dataSet.stringValue(for: 0x0028_2110),
            lossyImageCompressionRatios: dataSet.doubleValues(for: 0x0028_2112),
            lossyImageCompressionMethods: dataSet.strings(for: 0x0028_2114),
            specimenLabelInImage: dataSet.stringValue(for: 0x0048_0010),
            burnedInAnnotation: dataSet.stringValue(for: 0x0028_0301),
            volumetricProperties: dataSet.stringValue(for: 0x0008_9206),
            photometricInterpretation: dataSet.stringValue(for: 0x0028_0004),
            samplesPerPixel: dataSet.int(for: 0x0028_0002), bitsAllocated: dataSet.int(for: 0x0028_0100),
            planarConfiguration: dataSet.int(for: 0x0028_0006), sliceThickness: measures?.doubleValue(for: 0x0018_0050),
            specimen: specimen,
            frameType: shared?.sequenceItems(for: 0x0040_0710).first.map {
                .init(rawValues: $0.dataSet.strings(for: 0x0008_9007))
            },
            slideLabel: dataSet.element(for: 0x2200_0005) != nil || dataSet.element(for: 0x2200_0002) != nil
                ? .init(barcodeValue: dataSet.stringValue(for: 0x2200_0005), labelText: dataSet.stringValue(for: 0x2200_0002)) : nil,
            concatenation: concatenation, diagnostics: result.diagnostics,
            unpositionedFrameIndices: result.unpositioned, tilesOverlapObserved: result.overlap
        )
    }
}

private extension DCMDecoder {
    enum Tags {
        static let sopClassUID = 0x0008_0016
        static let sopInstanceUID = 0x0008_0018
        static let numberOfFrames = 0x0028_0008
        static let rows = 0x0028_0010
        static let columns = 0x0028_0011
        static let pixelSpacing = 0x0028_0030
        static let pixelMeasuresSequence = 0x0028_9110
        static let sharedFunctionalGroupsSequence = 0x5200_9229
        static let perFrameFunctionalGroupsSequence = 0x5200_9230
        static let imagedVolumeWidth = 0x0048_0001
        static let imagedVolumeHeight = 0x0048_0002
        static let totalPixelMatrixColumns = 0x0048_0006
        static let totalPixelMatrixRows = 0x0048_0007
        static let totalPixelMatrixOriginSequence = 0x0048_0008
        static let numberOfFocalPlanes = 0x0048_0013
        static let distanceBetweenFocalPlanes = 0x0048_0014
        static let opticalPathSequence = 0x0048_0105
        static let opticalPathIdentifier = 0x0048_0106
        static let opticalPathDescription = 0x0048_0107
        static let opticalPathIdentificationSequence = 0x0048_0207
        static let planePositionSlideSequence = 0x0048_021A
        static let columnPositionTotalPixelMatrix = 0x0048_021E
        static let rowPositionTotalPixelMatrix = 0x0048_021F
        static let totalPixelMatrixFocalPlanes = 0x0048_0303
        static let xOffsetSlide = 0x0040_072A
        static let yOffsetSlide = 0x0040_073A
        static let zOffsetSlide = 0x0040_074A
        static let containerIdentifier = 0x0040_0512
        static let specimenIdentifier = 0x0040_0551
    }

    static func opticalPaths(in dataSet: DicomDataSet) -> [DicomWholeSlideOpticalPath] {
        dataSet.sequenceItems(for: Tags.opticalPathSequence).compactMap { item in
            let path = item.dataSet
            guard let identifier = path.stringValue(for: Tags.opticalPathIdentifier),
                  !identifier.isEmpty else { return nil }
            return .init(
                identifier: identifier, description: path.stringValue(for: Tags.opticalPathDescription),
                illuminationTypeCodes: codes(in: path, tag: 0x0022_0016),
                illuminationColorCode: codes(in: path, tag: 0x0048_0108).first,
                illuminationWavelengthNanometers: path.doubleValue(for: 0x0022_0055),
                lightPathFilterTypeStackCodes: codes(in: path, tag: 0x0022_0017),
                imagePathFilterTypeStackCodes: codes(in: path, tag: 0x0022_0018),
                objectiveLensPower: path.doubleValue(for: 0x0048_0112),
                objectiveLensNumericalAperture: path.doubleValue(for: 0x0048_0113),
                iccProfile: path.element(for: 0x0028_2000)?.bytesValue,
                colorSpace: path.stringValue(for: 0x0028_2002),
                palettePresent: path.element(for: 0x0048_0120) != nil
            )
        }
    }

    static func codes(in dataSet: DicomDataSet, tag: Int) -> [DicomCodedConcept] {
        dataSet.sequenceItems(for: tag).compactMap { item in
            let code = item.dataSet
            guard let value = code.stringValue(for: 0x0008_0100) ?? code.stringValue(for: 0x0008_0119)
                    ?? code.stringValue(for: 0x0008_0120) else { return nil }
            return .init(codeValue: value, codingSchemeDesignator: code.stringValue(for: 0x0008_0102) ?? "",
                         codeMeaning: code.stringValue(for: 0x0008_0104),
                         codingSchemeVersion: code.stringValue(for: 0x0008_0103))
        }
    }

    static func issuer(in dataSet: DicomDataSet, tag: Int) -> DicomSpecimenIssuer? {
        dataSet.sequenceItems(for: tag).first.map {
            .init(localNamespaceEntityID: $0.dataSet.stringValue(for: 0x0040_0031),
                  universalEntityID: $0.dataSet.stringValue(for: 0x0040_0032),
                  universalEntityIDType: $0.dataSet.stringValue(for: 0x0040_0033))
        }
    }

    static func specimen(in dataSet: DicomDataSet) -> DicomWholeSlideSpecimen? {
        guard dataSet.element(for: Tags.containerIdentifier) != nil || dataSet.element(for: 0x0040_0560) != nil else {
            return nil
        }
        return .init(
            containerIdentifier: dataSet.stringValue(for: Tags.containerIdentifier),
            issuer: issuer(in: dataSet, tag: 0x0040_0513), containerTypeCode: codes(in: dataSet, tag: 0x0040_0518).first,
            specimens: dataSet.sequenceItems(for: 0x0040_0560).map { item in
                let specimen = item.dataSet
                return .init(
                    identifier: specimen.stringValue(for: Tags.specimenIdentifier),
                    uid: specimen.stringValue(for: 0x0040_0554), issuer: issuer(in: specimen, tag: 0x0040_0562),
                    shortDescription: specimen.stringValue(for: 0x0040_0600),
                    detailedDescription: specimen.stringValue(for: 0x0040_0602),
                    preparationSteps: specimen.sequenceItems(for: 0x0040_0610).map { step in
                        step.dataSet.sequenceItems(for: 0x0040_0612).map { item in
                            .init(valueType: item.dataSet.stringValue(for: 0x0040_A040),
                                  conceptName: codes(in: item.dataSet, tag: 0x0040_A043).first,
                                  codedValue: codes(in: item.dataSet, tag: 0x0040_A168).first,
                                  textValue: item.dataSet.stringValue(for: 0x0040_A160))
                        }
                    }
                )
            }
        )
    }

    static func pixelSpacing(
        in dataSet: DicomDataSet,
        matrixWidth: Int,
        matrixHeight: Int
    ) -> (x: Double, y: Double)? {
        let shared = dataSet.sequenceItems(for: Tags.sharedFunctionalGroupsSequence).first?.dataSet
        let measures = shared.flatMap { nestedDataSet(in: $0, sequenceTag: Tags.pixelMeasuresSequence) }
        let spacing = (measures?.doubleValues(for: Tags.pixelSpacing) ?? []) +
            dataSet.doubleValues(for: Tags.pixelSpacing)
        if spacing.count >= 2, spacing[0] > 0, spacing[1] > 0 {
            return (spacing[1], spacing[0])
        }
        return nil
    }

    static func positionTiles(
        in dataSet: DicomDataSet, matrixWidth: Int, matrixHeight: Int,
        tileWidth: Int, tileHeight: Int, frameCount: Int,
        paths: [DicomWholeSlideOpticalPath], focalOffsets: [Double],
        organization: DicomDimensionOrganizationType, imageType: DicomWholeSlideImageType,
        concatenation: DicomWholeSlideConcatenation?, transform: DicomSlideCoordinateTransform?
    ) -> (tiles: [DicomWholeSlideMicroscopyMetadata.Tile], diagnostics: [DicomWholeSlideDiagnostic],
          unpositioned: [Int], overlap: Bool) {
        var tiles: [DicomWholeSlideMicroscopyMetadata.Tile] = []
        var diagnostics: [DicomWholeSlideDiagnostic] = []
        var unpositioned: [Int] = []
        let perFrame = dataSet.sequenceItems(for: Tags.perFrameFunctionalGroupsSequence)
        let across = matrixWidth / tileWidth + (matrixWidth % tileWidth == 0 ? 0 : 1)
        let down = matrixHeight / tileHeight + (matrixHeight % tileHeight == 0 ? 0 : 1)
        let isAuxiliary = imageType.flavor.map { $0 != .volume } ?? false
        let full = organization == .tiledFull
        let expected = checkedProduct([across, down, focalOffsets.count, paths.count])
        let offset = concatenation?.frameOffsetNumber ?? 0
        if full {
            if focalOffsets.isEmpty { diagnostics.append(.init(code: .focalPlaneGeometryMissing)) }
            let rangeValid = expected.map { offset >= 0 && offset <= $0 && frameCount <= $0 - offset } ?? false
            let valid: Bool
            if isAuxiliary {
                valid = frameCount == 1 && !paths.isEmpty && offset == 0
            } else if concatenation != nil {
                valid = concatenation?.uid?.isEmpty == false && concatenation?.frameOffsetNumber != nil && rangeValid
                if valid { diagnostics.append(.init(code: .concatenationCoverageUnverified)) }
            } else {
                valid = expected == frameCount
            }
            guard valid else {
                diagnostics.append(.init(code: .frameCountMismatch))
                return ([], diagnostics, [], false)
            }
        } else if perFrame.count != frameCount {
            diagnostics.append(.init(code: .frameCountMismatch))
            return ([], diagnostics, [], false)
        }
        for index in 0..<frameCount {
            let frame = index < perFrame.count ? perFrame[index].dataSet : DicomDataSet()
            let position = frame.sequenceItems(for: Tags.planePositionSlideSequence).first?.dataSet
            let pathData = frame.sequenceItems(for: Tags.opticalPathIdentificationSequence).first?.dataSet
            let explicitPath = pathData?.stringValue(for: Tags.opticalPathIdentifier)
            let column: Int
            let row: Int
            let plane: Int
            let path: String
            let z: Double
            var x: Double?
            var y: Double?
            if let position {
                let c = position.integerValue(for: Tags.columnPositionTotalPixelMatrix)
                let r = position.integerValue(for: Tags.rowPositionTotalPixelMatrix)
                if c <= 0 || r <= 0 || c > matrixWidth || r > matrixHeight {
                    diagnostics.append(.init(code: .positionOutsideMatrix, frameIndex: index))
                    if !full { unpositioned.append(index); continue }
                }
            }
            if let explicitPath, !paths.contains(where: { $0.identifier == explicitPath }) {
                diagnostics.append(.init(code: .opticalPathMismatch, frameIndex: index))
                if !full { unpositioned.append(index); continue }
            }
            if full {
                let global = index + offset
                let spatial = isAuxiliary ? 0 : global % (across * down)
                column = spatial % across * tileWidth
                row = spatial / across * tileHeight
                plane = isAuxiliary ? 0 : global / (across * down) % focalOffsets.count
                path = paths[isAuxiliary ? 0 : global / (across * down * focalOffsets.count)].identifier
                z = focalOffsets.isEmpty ? (transform?.origin.zMicrometers ?? 0) / 1000 : focalOffsets[plane]
                let point = transform?.slidePoint(forMatrixColumn: Double(column + 1), row: Double(row + 1))
                x = point?.xMillimeters
                y = point?.yMillimeters
            } else {
                var missing = false
                if position == nil || position?.int(for: Tags.columnPositionTotalPixelMatrix) == nil ||
                    position?.int(for: Tags.rowPositionTotalPixelMatrix) == nil ||
                    position?.doubleValue(for: Tags.xOffsetSlide)?.isFinite != true ||
                    position?.doubleValue(for: Tags.yOffsetSlide)?.isFinite != true ||
                    position?.doubleValue(for: Tags.zOffsetSlide)?.isFinite != true {
                    diagnostics.append(.init(code: .framePositionMissing, frameIndex: index))
                    missing = true
                }
                if explicitPath == nil || explicitPath?.isEmpty == true {
                    diagnostics.append(.init(code: .opticalPathIdentificationMissing, frameIndex: index))
                    missing = true
                }
                guard !missing, let position, let explicitPath,
                      let rawZ = position.doubleValue(for: Tags.zOffsetSlide),
                      let focalIndex = focalOffsets.firstIndex(of: rawZ / 1000) else {
                    unpositioned.append(index); continue
                }
                column = position.integerValue(for: Tags.columnPositionTotalPixelMatrix) - 1
                row = position.integerValue(for: Tags.rowPositionTotalPixelMatrix) - 1
                plane = focalIndex
                z = rawZ / 1000
                path = explicitPath
                x = position.doubleValue(for: Tags.xOffsetSlide)
                y = position.doubleValue(for: Tags.yOffsetSlide)
            }
            tiles.append(.init(
                frameIndex: index, column: column, row: row,
                width: min(tileWidth, matrixWidth - column), height: min(tileHeight, matrixHeight - row),
                opticalPathIdentifier: path, focalPlaneIndex: plane, zOffsetMillimeters: z,
                xOffsetMillimeters: x, yOffsetMillimeters: y
            ))
        }
        // Sweep within each optical path and physical plane; coincident different paths are not overlap.
        let ordered = tiles.sorted {
            if $0.opticalPathIdentifier != $1.opticalPathIdentifier { return $0.opticalPathIdentifier < $1.opticalPathIdentifier }
            if $0.zOffsetMillimeters != $1.zOffsetMillimeters { return $0.zOffsetMillimeters < $1.zOffsetMillimeters }
            return $0.row < $1.row
        }
        var active: [DicomWholeSlideMicroscopyMetadata.Tile] = []
        var overlap = false
        if !full {
            for tile in ordered {
                active.removeAll {
                    $0.opticalPathIdentifier != tile.opticalPathIdentifier || $0.zOffsetMillimeters != tile.zOffsetMillimeters ||
                        $0.row + $0.height <= tile.row
                }
                if active.contains(where: { $0.column < tile.column + tile.width && tile.column < $0.column + $0.width }) {
                    overlap = true
                    break
                }
                active.append(tile)
            }
        }
        if overlap { diagnostics.append(.init(code: .tilesOverlapObserved)) }
        return (tiles, diagnostics, unpositioned, overlap)
    }

    static func checkedProduct(_ values: [Int]) -> Int? {
        var product = 1
        for value in values {
            let result = product.multipliedReportingOverflow(by: value)
            guard !result.overflow, result.partialValue > 0 else { return nil }
            product = result.partialValue
        }
        return product
    }

    static func nestedDataSet(in dataSet: DicomDataSet, sequenceTag: Int, depth: Int = 0) -> DicomDataSet? {
        guard depth <= 5 else { return nil }
        if let first = dataSet.sequenceItems(for: sequenceTag).first?.dataSet { return first }
        for element in dataSet.elements {
            for item in element.sequenceItems {
                if let found = nestedDataSet(in: item.dataSet, sequenceTag: sequenceTag, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }
}

private extension DicomDataSet {
    func stringValue(for tag: Int) -> String? {
        string(for: tag)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\0")))
    }

    func integerValue(for tag: Int) -> Int {
        int(for: tag) ?? integerString(for: tag) ?? Int(stringValue(for: tag) ?? "") ?? 0
    }

    func doubleValue(for tag: Int) -> Double? {
        float(for: tag) ?? decimalString(for: tag) ?? Double(stringValue(for: tag) ?? "")
    }

    func doubleValues(for tag: Int) -> [Double] {
        let binaryValues = floats(for: tag)
        let values = binaryValues.isEmpty ? decimalStrings(for: tag) : binaryValues
        if !values.isEmpty { return values }
        return strings(for: tag).flatMap { value in
            value.split(separator: "\\").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        }
    }
}

public struct DicomSlideOrigin: Sendable, Equatable {
    public let xMillimeters: Double
    public let yMillimeters: Double
    public let zMicrometers: Double

    public init(
        xMillimeters: Double,
        yMillimeters: Double,
        zMicrometers: Double = 0
    ) {
        self.xMillimeters = xMillimeters
        self.yMillimeters = yMillimeters
        self.zMicrometers = zMicrometers
    }
}

public struct DicomWholeSlideImagedVolume: Sendable, Equatable {
    public let widthMillimeters: Double
    public let heightMillimeters: Double
    public let depthMicrometers: Double

    public init(
        widthMillimeters: Double,
        heightMillimeters: Double,
        depthMicrometers: Double
    ) {
        self.widthMillimeters = widthMillimeters
        self.heightMillimeters = heightMillimeters
        self.depthMicrometers = depthMicrometers
    }
}

public struct DicomWholeSlideLabel: Sendable, Equatable {
    public let barcodeValue: String?
    public let labelText: String?

    public init(
        barcodeValue: String? = nil,
        labelText: String? = nil
    ) {
        self.barcodeValue = barcodeValue
        self.labelText = labelText
    }
}

public struct DicomWholeSlideConcatenation: Sendable, Equatable {
    public let uid: String?
    public let number: Int?
    public let totalNumber: Int?
    public let frameOffsetNumber: Int?

    public init(
        uid: String? = nil,
        number: Int? = nil,
        totalNumber: Int? = nil,
        frameOffsetNumber: Int? = nil
    ) {
        self.uid = uid
        self.number = number
        self.totalNumber = totalNumber
        self.frameOffsetNumber = frameOffsetNumber
    }
}

public struct DicomWholeSlideImageType: Sendable, Equatable {
    public enum Flavor: String, Sendable { case volume = "VOLUME", label = "LABEL", overview = "OVERVIEW", thumbnail = "THUMBNAIL" }
    public enum DerivedPixels: String, Sendable { case none = "NONE", resampled = "RESAMPLED" }
    public let rawValues: [String]
    public var flavor: Flavor? { rawValues.count > 2 ? Flavor(rawValue: rawValues[2]) : nil }
    public var derivedPixels: DerivedPixels? { rawValues.count > 3 ? DerivedPixels(rawValue: rawValues[3]) : nil }
    public init(rawValues: [String] = []) { self.rawValues = rawValues }
}
