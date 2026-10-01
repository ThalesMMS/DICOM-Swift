import Foundation

/// Authors one resolution layer; never decodes or recompresses pixel frames.
public enum DicomWholeSlideMicroscopyBuilder {
    public static let sopClassUID = "1.2.840.10008.5.1.4.1.1.77.1.6"
    public enum BuildError: Error, Equatable, Sendable {
        case invalidInput, invalidSource, unsupportedPixelLayout, incompleteRegion, pixelBytesChanged
    }
    private typealias C = DicomRegistrationCoding
    private typealias Options = DicomWholeSlideMicroscopyBuildOptions

    public static func dataSet(from o: DicomWholeSlideMicroscopyBuildOptions) throws -> DicomDataSet {
        let full = o.organization == .tiledFull
        guard full || o.organization == .tiledSparse,
              o.matrixColumns > 0, o.matrixRows > 0, o.tileColumns > 0, o.tileRows > 0,
              o.tileColumns <= 65535, o.tileRows <= 65535, o.focalPlanes > 0,
              [8, 16].contains(o.bitsAllocated), !o.frames.isEmpty, !o.opticalPaths.isEmpty,
              !o.sopInstanceUID.isEmpty, !o.studyInstanceUID.isEmpty, !o.seriesInstanceUID.isEmpty,
              !o.acquisitionDateTime.isEmpty, !o.contentDate.isEmpty, !o.contentTime.isEmpty,
              let transform = DicomSlideCoordinateTransform(origin: o.origin, orientation: o.orientation,
                  pixelSpacingXMillimeters: o.pixelSpacingXMillimeters, pixelSpacingYMillimeters: o.pixelSpacingYMillimeters,
                  matrixColumns: o.matrixColumns, matrixRows: o.matrixRows),
              o.sliceThicknessMillimeters.isFinite, o.sliceThicknessMillimeters > 0,
              o.spacingBetweenSlicesMillimeters.isFinite, o.spacingBetweenSlicesMillimeters > 0,
              Set(o.opticalPaths.map(\.identifier)).count == o.opticalPaths.count,
              o.opticalPaths.allSatisfy({ !$0.identifier.isEmpty && !$0.illuminationTypeCodes.isEmpty && !$0.palettePresent }),
              o.specimen.specimens.count == 1, o.specimen.containerIdentifier?.isEmpty == false,
              o.specimen.specimens.allSatisfy({ $0.identifier?.isEmpty == false && $0.uid?.isEmpty == false })
        else { throw BuildError.invalidInput }
        if full {
            let count = try product([(o.matrixColumns - 1) / o.tileColumns + 1, (o.matrixRows - 1) / o.tileRows + 1,
                                     o.focalPlanes, o.opticalPaths.count])
            guard o.positions == nil, o.frames.count == (o.flavor == .volume ? count : 1) else { throw BuildError.invalidInput }
        } else {
            guard let positions = o.positions, positions.count == o.frames.count,
                  positions.allSatisfy({ position in position.column > 0 && position.column <= o.matrixColumns && position.row > 0 && position.row <= o.matrixRows &&
                      position.plane >= 0 && position.plane < o.focalPlanes && o.opticalPaths.contains(where: { $0.identifier == position.opticalPathIdentifier }) })
            else { throw BuildError.invalidInput }
        }
        if o.flavor != .volume && o.frames.count != 1 { throw BuildError.invalidInput }
        if [.volume, .thumbnail].contains(o.flavor), o.frameOfReferenceUID?.isEmpty != false { throw BuildError.invalidInput }
        if o.pyramidUID != nil && ![.volume, .thumbnail].contains(o.flavor) { throw BuildError.invalidInput }
        if o.extendedDepthOfField && (o.acquisitionFocalPlanes ?? 0 <= 0 || o.distanceBetweenFocalPlanesMicrometers ?? 0 <= 0) {
            throw BuildError.invalidInput
        }
        let type = [o.derivation == nil ? "ORIGINAL" : "DERIVED", "PRIMARY", o.flavor.rawValue,
                    o.derivation?.resampled == true ? "RESAMPLED" : "NONE"]
        let mono = o.photometricInterpretation == "MONOCHROME2"
        var elements: [DicomDataElement] = [
            C.text(0x00080016, .UI, sopClassUID), C.text(0x00080018, .UI, o.sopInstanceUID),
            C.text(0x0020000D, .UI, o.studyInstanceUID), C.text(0x0020000E, .UI, o.seriesInstanceUID),
            C.text(0x00080060, .CS, "SM"), C.text(0x00080005, .CS, "ISO_IR 192"),
            C.text(0x00100010, .PN, o.patientName), C.text(0x00100020, .LO, o.patientID),
            C.text(0x00100030, .DA, o.patientBirthDate), C.text(0x00100040, .CS, o.patientSex),
            C.text(0x00080020, .DA, o.studyDate), C.text(0x00080030, .TM, o.studyTime),
            C.text(0x00080090, .PN, o.referringPhysicianName), C.text(0x00200010, .SH, o.studyID),
            C.text(0x00080050, .SH, o.accessionNumber), C.text(0x00200011, .IS, String(o.seriesNumber)),
            C.text(0x00080070, .LO, o.manufacturer), C.text(0x00081090, .LO, o.manufacturerModelName),
            C.text(0x00181000, .LO, o.deviceSerialNumber), C.text(0x00181020, .LO, o.softwareVersions),
            C.text(0x00080023, .DA, o.contentDate), C.text(0x00080033, .TM, o.contentTime),
            C.text(0x0008002A, .DT, o.acquisitionDateTime), C.text(0x00200013, .IS, String(o.instanceNumber)),
            .init(tag: 0x00080008, vr: .CS, value: .strings(type)), C.text(0x00280008, .IS, String(o.frames.count)),
            uint(0x00280010, .US, o.tileRows), uint(0x00280011, .US, o.tileColumns),
            uint(0x00280002, .US, mono ? 1 : 3), C.text(0x00280004, .CS, o.photometricInterpretation),
            uint(0x00280100, .US, o.bitsAllocated), uint(0x00280101, .US, o.bitsAllocated),
            uint(0x00280102, .US, o.bitsAllocated - 1), uint(0x00280103, .US, 0),
            uint(0x00480006, .UL, o.matrixColumns), uint(0x00480007, .UL, o.matrixRows),
            uint(0x00480303, .UL, o.focalPlanes), uint(0x00480302, .UL, o.opticalPaths.count),
            C.sequence(0x00480008, [originData(o.origin)]), C.decimals(0x00480102, o.orientation),
            float(0x00480001, Double(o.matrixColumns) * o.pixelSpacingXMillimeters),
            float(0x00480002, Double(o.matrixRows) * o.pixelSpacingYMillimeters),
            float(0x00480003, 1000 * (o.sliceThicknessMillimeters + Double(o.focalPlanes - 1) * o.spacingBetweenSlicesMillimeters)),
            C.text(0x00089206, .CS, "VOLUME"), C.text(0x00480010, .CS, [.label, .overview].contains(o.flavor) ? "YES" : "NO"),
            C.text(0x00280301, .CS, o.burnedInAnnotation ? "YES" : "NO"), C.text(0x00480011, .CS, o.focusMethod),
            C.text(0x00480012, .CS, o.extendedDepthOfField ? "YES" : "NO"),
            C.text(0x00209311, .CS, full ? "TILED_FULL" : "TILED_SPARSE"),
            C.text(0x00282110, .CS, o.lossyImageCompression ? "01" : "00"), C.sequence(0x00400555, []),
            C.sequence(0x00480105, o.opticalPaths.map(opticalPath)),
            C.sequence(0x00209221, [.init(elements: [C.text(0x00209164, .UI, o.sopInstanceUID)])])
        ]
        if !mono { elements.append(uint(0x00280006, .US, 0)) }
        else { elements += [C.text(0x20500020, .CS, "IDENTITY"), C.decimals(0x00281052, [0]), C.decimals(0x00281053, [1])] }
        if let frame = o.frameOfReferenceUID { elements += [C.text(0x00200052, .UI, frame), C.text(0x00201040, .LO, "")] }
        if let pyramid = o.pyramidUID { elements.append(C.text(0x00080019, .UI, pyramid)) }
        if o.extendedDepthOfField {
            elements += [uint(0x00480013, .US, o.acquisitionFocalPlanes!), float(0x00480014, o.distanceBetweenFocalPlanesMicrometers!)]
        }
        if o.lossyImageCompression {
            guard !o.lossyRatios.isEmpty, !o.lossyMethods.isEmpty else { throw BuildError.invalidInput }
            elements += [C.decimals(0x00282112, o.lossyRatios), .init(tag: 0x00282114, vr: .CS, value: .strings(o.lossyMethods))]
        }
        if o.flavor == .label || o.label != nil {
            elements += [C.text(0x22000005, .LT, o.label?.barcodeValue ?? ""), C.text(0x22000002, .UT, o.label?.labelText ?? "")]
        }
        elements += specimen(o.specimen)
        var measures = DicomDataSet(elements: [C.decimals(0x00280030, [o.pixelSpacingYMillimeters, o.pixelSpacingXMillimeters]),
            C.decimals(0x00180050, [o.sliceThicknessMillimeters])])
        if o.focalPlanes > 1 { measures = measures.setting(C.decimals(0x00180088, [o.spacingBetweenSlicesMillimeters])) }
        var shared = DicomDataSet(elements: [C.sequence(0x00289110, [measures]),
            C.sequence(0x00400710, [.init(elements: [.init(tag: 0x00089007, vr: .CS, value: .strings(type))])])])
        if let derivation = o.derivation { shared = shared.setting(try derivationElement(derivation)) }
        elements.append(C.sequence(0x52009229, [shared]))
        if let positions = o.positions {
            elements.append(C.sequence(0x00209222, [dimension(o.sopInstanceUID, tag: 0x0048021E, group: 0x0048021A),
                dimension(o.sopInstanceUID, tag: 0x0048021F, group: 0x0048021A),
                dimension(o.sopInstanceUID, tag: 0x00480106, group: 0x00480207)]))
            elements.append(C.sequence(0x52009230, positions.map { p in
                let point = transform.slidePoint(forMatrixColumn: Double(p.column), row: Double(p.row))
                let origin = DicomSlideOrigin(xMillimeters: point.xMillimeters, yMillimeters: point.yMillimeters,
                    zMicrometers: point.zMicrometers + Double(p.plane) * o.spacingBetweenSlicesMillimeters * 1000)
                let pos = originData(origin).setting(.init(tag: 0x0048021E, vr: .SL, value: .signedIntegers([p.column])))
                    .setting(.init(tag: 0x0048021F, vr: .SL, value: .signedIntegers([p.row])))
                return .init(elements: [C.sequence(0x0048021A, [pos]),
                    C.sequence(0x00480207, [.init(elements: [C.text(0x00480106, .SH, p.opticalPathIdentifier)])])])
            }))
        }
        var data = DicomDataSet(elements: elements)
        if let derivation = o.derivation { data = hierarchy(data, derivation) }
        return try pixels(data, frames: o.frames, syntax: o.transferSyntax, extended: o.extendedOffsetTable)
    }

    public static func part10Data(from options: DicomWholeSlideMicroscopyBuildOptions) throws -> Data {
        try DicomDataSetWriter.part10Data(from: dataSet(from: options), options: .init(transferSyntax: options.transferSyntax))
    }

    /// Re-emits the same frames with a new SOP Instance UID and optional non-pixel changes.
    /// The closure may not alter the tile organization or pixel interpretation.
    public static func rewrappedContainer(from source: Data, changes: (inout DicomDataSet) throws -> Void) throws -> Data {
        let decoder = try DCMDecoder(data: source)
        guard decoder.wholeSlideMicroscopyMetadata != nil, let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) else { throw BuildError.invalidSource }
        var data = decoder.dataSet
        let original = data
        try changes(&data)
        let protected = [0x00080016, 0x00080008, 0x00280002, 0x00280004, 0x00280006, 0x00280008, 0x00280010, 0x00280011,
            0x00280100, 0x00280101, 0x00280102, 0x00280103, 0x00480006, 0x00480007, 0x00480008, 0x00480102,
            0x00480302, 0x00480303, 0x00480105, 0x00209311, 0x52009229, 0x52009230, 0x00282110, 0x00282112, 0x00282114,
            0x7FE00010, 0x7FE00001, 0x7FE00002]
        guard protected.allSatisfy({ data[$0] == original[$0] }),
              data.string(for: 0x00080018) != original.string(for: 0x00080018) else { throw BuildError.invalidInput }
        let frames = try frameBytes(decoder)
        data = try pixels(data, frames: frames, syntax: syntax, extended: original.contains(0x7FE00001))
        let output = try DicomDataSetWriter.part10Data(from: data, options: .init(transferSyntax: syntax))
        guard try frameBytes(DCMDecoder(data: output)) == frames else { throw BuildError.pixelBytesChanged }
        return output
    }

    /// Expands a zero-based half-open pixel rectangle outward to tiles, clipped at the matrix edge.
    /// A complete, unconcatenated TILED_FULL source is required; all paths and planes are copied.
    public static func tileAlignedRegion(from source: Data, columns: Range<Int>, rows: Range<Int>,
                                         sopInstanceUID: String, seriesInstanceUID: String) throws -> Data {
        let decoder = try DCMDecoder(data: source)
        guard let model = decoder.wholeSlideMicroscopyMetadata, model.dimensionOrganizationType == .tiledFull,
              model.imageType.flavor == .volume, model.concatenation == nil,
              let transform = model.slideCoordinateTransform, !columns.isEmpty, !rows.isEmpty,
              columns.lowerBound >= 0, rows.lowerBound >= 0, columns.upperBound <= model.matrixWidth,
              rows.upperBound <= model.matrixHeight, sopInstanceUID != model.sopInstanceUID,
              let syntax = DicomTransferSyntax(uid: decoder.transferSyntaxUID) else { throw BuildError.invalidSource }
        let left = columns.lowerBound / model.tileWidth * model.tileWidth
        let top = rows.lowerBound / model.tileHeight * model.tileHeight
        let right = min(model.matrixWidth, ((columns.upperBound - 1) / model.tileWidth + 1) * model.tileWidth)
        let bottom = min(model.matrixHeight, ((rows.upperBound - 1) / model.tileHeight + 1) * model.tileHeight)
        let selected = model.tiles.filter { $0.column >= left && $0.column < right && $0.row >= top && $0.row < bottom }
        let expected = try product([(right - left - 1) / model.tileWidth + 1, (bottom - top - 1) / model.tileHeight + 1,
                                    model.totalPixelMatrixFocalPlanes ?? 1, model.opticalPaths.count])
        guard selected.count == expected else { throw BuildError.incompleteRegion }
        let sourceFrames = try frameBytes(decoder)
        let copied = selected.map { sourceFrames[$0.frameIndex] }
        var data = decoder.dataSet
        let point = transform.slidePoint(forMatrixColumn: Double(left + 1), row: Double(top + 1))
        let type = ["DERIVED", "PRIMARY", "VOLUME", "NONE"]
        data = data.setting(C.text(0x00080018, .UI, sopInstanceUID)).setting(C.text(0x0020000E, .UI, seriesInstanceUID))
            .setting(.init(tag: 0x00080008, vr: .CS, value: .strings(type)))
            .setting(uint(0x00480006, .UL, right - left)).setting(uint(0x00480007, .UL, bottom - top))
            .setting(C.sequence(0x00480008, [originData(point)]))
            .setting(float(0x00480001, Double(right - left) * transform.pixelSpacingXMillimeters))
            .setting(float(0x00480002, Double(bottom - top) * transform.pixelSpacingYMillimeters))
            .setting(C.text(0x00280008, .IS, String(copied.count)))
            .removing(0x52009230).removing(0x00209222).removing(0x00080019)
        let derivation = Options.Derivation(sourceSOPInstanceUID: model.sopInstanceUID,
            sourceStudyInstanceUID: decoder.dataSet.string(for: 0x0020000D) ?? "", sourceSeriesInstanceUID: model.seriesUID,
            sourceFrames: selected.map { $0.frameIndex + 1 },
            code: .init(codeValue: "113085", codingSchemeDesignator: "DCM", codeMeaning: "Spatial resampling"))
        // CID 7203 permits the standard spatial resampling code for an extracted spatial region;
        // NONE in Image Type states that the copied pixels themselves were not downsampled.
        let regionDerivation = derivation
        guard var shared = data.sequenceItems(for: 0x52009229).first?.dataSet else { throw BuildError.invalidSource }
        shared = shared.setting(C.sequence(0x00400710, [.init(elements: [.init(tag: 0x00089007, vr: .CS, value: .strings(type))])]))
            .setting(try derivationElement(regionDerivation))
        data = hierarchy(data.setting(C.sequence(0x52009229, [shared])), regionDerivation)
        data = try pixels(data, frames: copied, syntax: syntax, extended: decoder.dataSet.contains(0x7FE00001))
        let output = try DicomDataSetWriter.part10Data(from: data, options: .init(transferSyntax: syntax))
        guard try frameBytes(DCMDecoder(data: output)) == copied else { throw BuildError.pixelBytesChanged }
        return output
    }

    static func frameBytes(_ decoder: DCMDecoder) throws -> [Data] {
        guard let model = decoder.wholeSlideMicroscopyMetadata else { throw BuildError.invalidSource }
        if decoder.encapsulatedPixelDataDescriptor != nil {
            let reader = try decoder.makeEncapsulatedPixelFrameReader()
            try reader.validateDeclaredFrameCount()
            return try (0..<model.frameCount).map { try reader.frameData(at: $0) }
        }
        return try (0..<model.frameCount).map {
            guard let frame = decoder.getFrame($0) else { throw BuildError.invalidSource }; return frame.data
        }
    }

    static func pixels(_ data: DicomDataSet, frames: [Data], syntax: DicomTransferSyntax, extended: Bool) throws -> DicomDataSet {
        guard !frames.isEmpty else { throw BuildError.invalidInput }
        var result = data.removing(0x7FE00001).removing(0x7FE00002).removing(0x7FE00010)
        let bytes: Data
        if syntax == .explicitVRLittleEndian {
            let size = try product([data.int(for: 0x00280010) ?? 0, data.int(for: 0x00280011) ?? 0,
                                    data.int(for: 0x00280002) ?? 0, (data.int(for: 0x00280100) ?? 0) / 8])
            guard frames.allSatisfy({ $0.count == size }) else { throw BuildError.invalidInput }
            bytes = frames.reduce(into: Data()) { $0.append($1) }
        } else {
            guard syntax.writeSupport.status == .encapsulatedPassThrough,
                  frames.allSatisfy({ !$0.isEmpty && $0.count.isMultiple(of: 2) && $0.count <= Int(UInt32.max) })
            else { throw BuildError.unsupportedPixelLayout }
            var offsets: [UInt64] = [], offset: UInt64 = 0
            for frame in frames { offsets.append(offset); offset += UInt64(frame.count) + 8 }
            let useExtended = extended || offset > UInt64(UInt32.max)
            var payload = Data()
            appendItem(useExtended ? Data() : offsets.reduce(into: Data()) { appendLE(UInt32($1), to: &$0) }, to: &payload)
            for frame in frames { appendItem(frame, to: &payload) }
            payload.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
            if useExtended {
                result = result.setting(.init(tag: 0x7FE00001, vr: .OV, value: .bytes(offsets.reduce(into: Data()) { appendLE($1, to: &$0) })))
                    .setting(.init(tag: 0x7FE00002, vr: .OV, value: .bytes(frames.reduce(into: Data()) { appendLE(UInt64($1.count), to: &$0) })))
            }
            bytes = payload
        }
        // DicomDataSetWriter dispatches this item stream to appendEncapsulatedPixelDataElement.
        return result.setting(.init(tag: 0x7FE00010, vr: syntax == .explicitVRLittleEndian && data.int(for: 0x00280100) == 16 ? .OW : .OB, value: .bytes(bytes)))
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    private static func appendItem(_ value: Data, to data: inout Data) {
        data.append(contentsOf: [0xFE, 0xFF, 0x00, 0xE0]); appendLE(UInt32(value.count), to: &data); data.append(value)
    }
    private static func product(_ values: [Int]) throws -> Int {
        var result = 1
        for value in values {
            let next = result.multipliedReportingOverflow(by: value)
            guard value > 0, !next.overflow else { throw BuildError.invalidInput }; result = next.partialValue
        }
        return result
    }
    private static func uint(_ tag: Int, _ vr: DicomVR, _ value: Int) -> DicomDataElement {
        .init(tag: tag, vr: vr, value: .unsignedIntegers([UInt(value)]))
    }
    private static func float(_ tag: Int, _ value: Double) -> DicomDataElement {
        .init(tag: tag, vr: .FL, value: .floats([value]))
    }
    private static func originData(_ value: DicomSlideOrigin) -> DicomDataSet {
        .init(elements: [C.decimals(0x0040072A, [value.xMillimeters]), C.decimals(0x0040073A, [value.yMillimeters]),
                         C.decimals(0x0040074A, [value.zMicrometers])])
    }
    private static func dimension(_ uid: String, tag: Int, group: Int) -> DicomDataSet {
        .init(elements: [C.text(0x00209164, .UI, uid), uint(0x00209165, .AT, tag), uint(0x00209167, .AT, group)])
    }
    private static func opticalPath(_ value: DicomWholeSlideOpticalPath) -> DicomDataSet {
        var data = DicomDataSet(elements: [C.text(0x00480106, .SH, value.identifier),
            C.sequence(0x00220016, value.illuminationTypeCodes.map(C.code))])
        for (tag, codes) in [(0x00220017, value.lightPathFilterTypeStackCodes), (0x00220018, value.imagePathFilterTypeStackCodes)] where !codes.isEmpty {
            data = data.setting(C.sequence(tag, codes.map(C.code)))
        }
        if let color = value.illuminationColorCode { data = data.setting(C.sequence(0x00480108, [C.code(color)])) }
        if let wave = value.illuminationWavelengthNanometers { data = data.setting(float(0x00220055, wave)) }
        if let power = value.objectiveLensPower { data = data.setting(float(0x00480112, power)) }
        if let aperture = value.objectiveLensNumericalAperture { data = data.setting(float(0x00480113, aperture)) }
        if let profile = value.iccProfile { data = data.setting(.init(tag: 0x00282000, vr: .OB, value: .bytes(profile))) }
        if let space = value.colorSpace { data = data.setting(C.text(0x00282002, .CS, space)) }
        if let description = value.description { data = data.setting(C.text(0x00480107, .ST, description)) }
        return data
    }
    private static func issuer(_ value: DicomSpecimenIssuer?) -> [DicomDataSet] {
        guard let value else { return [] }
        var elements: [DicomDataElement] = []
        if let local = value.localNamespaceEntityID { elements.append(C.text(0x00400031, .UT, local)) }
        if let universal = value.universalEntityID { elements.append(C.text(0x00400032, .UT, universal)) }
        if let type = value.universalEntityIDType { elements.append(C.text(0x00400033, .CS, type)) }
        return [.init(elements: elements)]
    }
    private static func specimen(_ value: DicomWholeSlideSpecimen) -> [DicomDataElement] {
        [C.text(0x00400512, .LO, value.containerIdentifier ?? ""), C.sequence(0x00400513, issuer(value.issuer)),
         C.sequence(0x00400518, value.containerTypeCode.map { [C.code($0)] } ?? []),
         C.sequence(0x00400560, value.specimens.map { specimen in
            var data = DicomDataSet(elements: [C.text(0x00400551, .LO, specimen.identifier ?? ""),
                C.text(0x00400554, .UI, specimen.uid ?? ""), C.sequence(0x00400562, issuer(specimen.issuer)),
                C.sequence(0x00400610, specimen.preparationSteps.map { step in
                    .init(elements: [C.sequence(0x00400612, step.map { item in
                        var elements = [C.text(0x0040A040, .CS, item.valueType ?? ""),
                            C.sequence(0x0040A043, item.conceptName.map { [C.code($0)] } ?? [])]
                        if let code = item.codedValue { elements.append(C.sequence(0x0040A168, [C.code(code)])) }
                        if let text = item.textValue { elements.append(C.text(0x0040A160, .UT, text)) }
                        return .init(elements: elements)
                    })])
                })])
            if let text = specimen.shortDescription { data = data.setting(C.text(0x00400600, .LO, text)) }
            if let text = specimen.detailedDescription { data = data.setting(C.text(0x00400602, .UT, text)) }
            return data
         })]
    }
    private static func derivationElement(_ value: Options.Derivation) throws -> DicomDataElement {
        guard !value.sourceSOPInstanceUID.isEmpty, !value.sourceFrames.isEmpty, value.sourceFrames.allSatisfy({ $0 > 0 })
        else { throw BuildError.invalidInput }
        let ref = C.reference(.init(sopClassUID: sopClassUID, sopInstanceUID: value.sourceSOPInstanceUID))
            .setting(.init(tag: 0x00081160, vr: .IS, value: .strings(value.sourceFrames.map(String.init))))
            .setting(C.sequence(0x0040A170, [C.code(.init(codeValue: "121322", codingSchemeDesignator: "DCM", codeMeaning: "Source image for image processing operation"))]))
            .setting(C.text(0x0028135A, .CS, "YES"))
        return C.sequence(0x00089124, [.init(elements: [C.sequence(0x00089215, [C.code(value.code)]), C.sequence(0x00082112, [ref])])])
    }
    private static func hierarchy(_ data: DicomDataSet, _ value: Options.Derivation) -> DicomDataSet {
        let series = DicomDataSet(elements: [C.text(0x0020000E, .UI, value.sourceSeriesInstanceUID),
            C.sequence(0x0008114A, [C.reference(.init(sopClassUID: sopClassUID, sopInstanceUID: value.sourceSOPInstanceUID))])])
        if value.sourceStudyInstanceUID == data.string(for: 0x0020000D) { return data.setting(C.sequence(0x00081115, [series])).removing(0x00081200) }
        return data.setting(C.sequence(0x00081200, [.init(elements: [C.text(0x0020000D, .UI, value.sourceStudyInstanceUID),
            C.sequence(0x00081115, [series])])])).removing(0x00081115)
    }
}
