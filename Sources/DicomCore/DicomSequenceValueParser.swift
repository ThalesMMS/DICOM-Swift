import Foundation

public enum DicomDataSetParser {
    /// Parses metadata elements from an encoded dataset.
    ///
    /// Pixel Data is intentionally omitted because the value-type dataset does not preserve
    /// encapsulated fragment boundaries. The parser still skips the encoded pixel payload and
    /// continues parsing any following metadata elements. Callers that need pixels must retain
    /// and consume the original encoded dataset bytes.
    public static func dataSet(from data: Data,
                               transferSyntax: DicomTransferSyntax = .explicitVRLittleEndian) throws -> DicomDataSet {
        let payload = transferSyntax.usesDataSetDeflate
            ? try DicomDeflatedDataSetCodec.inflate(data)
            : data
        var offset = 0
        return try DicomSequenceValueParser.parseDataSet(
            in: payload,
            offset: &offset,
            end: payload.count,
            littleEndian: !transferSyntax.isBigEndian,
            explicitVR: transferSyntax.isExplicitVR
        )
    }
}

enum DicomSequenceValueParser {
    private static let itemTag = 0xFFFEE000
    private static let itemDelimiterTag = 0xFFFEE00D
    private static let sequenceDelimiterTag = 0xFFFEE0DD
    private static let undefinedLength = UInt32.max

    static func undefinedLengthSequenceBounds(
        in data: Data,
        valueOffset: Int,
        end: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        characterSet: DicomSpecificCharacterSet = .defaultCharacterSet
    ) throws -> (valueLength: Int, endOffset: Int) {
        var offset = valueOffset
        let result = try parseSequenceItemsResult(
            in: data,
            offset: &offset,
            end: end,
            littleEndian: littleEndian,
            explicitVR: explicitVR,
            characterSet: characterSet,
            requiresSequenceDelimiter: true
        )
        guard let delimiterOffset = result.delimiterOffset else {
            throw DicomSequenceValueParserError.missingSequenceDelimiter
        }
        return (delimiterOffset - valueOffset, offset)
    }

    static func parseItems(
        in data: Data,
        valueOffset: Int,
        valueLength: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        characterSet: DicomSpecificCharacterSet = .defaultCharacterSet
    ) throws -> [DicomSequenceItem] {
        guard valueOffset >= 0,
              valueLength >= 0,
              valueOffset + valueLength <= data.count else {
            throw DicomSequenceValueParserError.invalidBounds
        }

        var offset = valueOffset
        return try parseSequenceItemsResult(
            in: data,
            offset: &offset,
            end: valueOffset + valueLength,
            littleEndian: littleEndian,
            explicitVR: explicitVR,
            characterSet: characterSet,
            requiresSequenceDelimiter: false
        ).items
    }

    static func parseDataSet(
        in data: Data,
        offset: inout Int,
        end: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        characterSet: DicomSpecificCharacterSet = .defaultCharacterSet
    ) throws -> DicomDataSet {
        try parseDataSet(
            in: data,
            offset: &offset,
            end: end,
            littleEndian: littleEndian,
            explicitVR: explicitVR,
            inheritedCharacterSet: characterSet,
            requiresItemDelimiter: false
        )
    }

    private static func parseDataSet(
        in data: Data,
        offset: inout Int,
        end: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        inheritedCharacterSet: DicomSpecificCharacterSet,
        requiresItemDelimiter: Bool
    ) throws -> DicomDataSet {
        var elements: [DicomDataElement] = []
        var characterSet = inheritedCharacterSet

        while offset < end {
            guard offset + 8 <= end else {
                throw requiresItemDelimiter
                    ? DicomSequenceValueParserError.missingItemDelimiter
                    : DicomSequenceValueParserError.unexpectedEnd
            }

            let tag = try readTag(data, offset: &offset, littleEndian: littleEndian)
            if tag == itemDelimiterTag || tag == sequenceDelimiterTag {
                let delimiterLength = try readUInt32(data, offset: &offset, littleEndian: littleEndian)
                try validateDelimiterLength(delimiterLength, tag: tag)
                if tag == itemDelimiterTag, requiresItemDelimiter {
                    return DicomDataSet(elements: elements)
                }
                throw tag == itemDelimiterTag
                    ? DicomSequenceValueParserError.unexpectedItemDelimiter
                    : DicomSequenceValueParserError.unexpectedSequenceDelimiter
            }
            let elementHeader = try readElementHeader(
                data,
                offset: &offset,
                tag: tag,
                littleEndian: littleEndian,
                explicitVR: explicitVR
            )

            if tag == DicomTag.pixelData.rawValue {
                try skipPixelData(
                    in: data,
                    offset: &offset,
                    end: end,
                    length: elementHeader.length,
                    littleEndian: littleEndian
                )
                continue
            }

            if elementHeader.vr == .SQ {
                let items: [DicomSequenceItem]
                if elementHeader.length == undefinedLength {
                    items = try parseSequenceItemsResult(
                        in: data,
                        offset: &offset,
                        end: end,
                        littleEndian: littleEndian,
                        explicitVR: explicitVR,
                        characterSet: characterSet,
                        requiresSequenceDelimiter: true
                    ).items
                } else {
                    let sequenceEnd = offset + Int(elementHeader.length)
                    guard sequenceEnd <= end else {
                        throw DicomSequenceValueParserError.elementExceedsBounds(tag)
                    }
                    items = try parseSequenceItemsResult(
                        in: data,
                        offset: &offset,
                        end: sequenceEnd,
                        littleEndian: littleEndian,
                        explicitVR: explicitVR,
                        characterSet: characterSet,
                        requiresSequenceDelimiter: false
                    ).items
                    offset = sequenceEnd
                }
                elements.append(DicomDataElement(tag: tag, vr: .SQ, value: .sequence(items)))
            } else {
                if elementHeader.vr == .UN && elementHeader.length == undefinedLength {
                    let items = try parseSequenceItemsResult(
                        in: data,
                        offset: &offset,
                        end: end,
                        littleEndian: littleEndian,
                        explicitVR: false,
                        characterSet: characterSet,
                        requiresSequenceDelimiter: true
                    ).items
                    elements.append(DicomDataElement(tag: tag, vr: .SQ, value: .sequence(items)))
                    continue
                }
                guard elementHeader.length != undefinedLength else {
                    throw DicomSequenceValueParserError.unsupportedUndefinedLengthElement(tag)
                }
                let valueEnd = offset + Int(elementHeader.length)
                guard valueEnd <= end else {
                    throw DicomSequenceValueParserError.elementExceedsBounds(tag)
                }
                let valueData = Data(data[offset..<valueEnd])
                offset = valueEnd
                let decodedValue = value(
                    for: elementHeader.vr,
                    data: valueData,
                    littleEndian: littleEndian,
                    characterSet: characterSet
                )
                elements.append(DicomDataElement(
                    tag: tag,
                    vr: elementHeader.vr,
                    value: decodedValue
                ))
                if tag == DicomTag.specificCharacterSet.rawValue,
                   case .strings(let terms) = decodedValue {
                    characterSet = DicomSpecificCharacterSet(terms.joined(separator: "\\"))
                }
            }
        }

        if requiresItemDelimiter {
            throw DicomSequenceValueParserError.missingItemDelimiter
        }
        return DicomDataSet(elements: elements)
    }

    private struct SequenceParseResult {
        let items: [DicomSequenceItem]
        let delimiterOffset: Int?
    }

    private static func parseSequenceItemsResult(
        in data: Data,
        offset: inout Int,
        end: Int,
        littleEndian: Bool,
        explicitVR: Bool,
        characterSet: DicomSpecificCharacterSet,
        requiresSequenceDelimiter: Bool
    ) throws -> SequenceParseResult {
        var items: [DicomSequenceItem] = []

        while offset < end {
            guard offset + 8 <= end else {
                throw requiresSequenceDelimiter
                    ? DicomSequenceValueParserError.missingSequenceDelimiter
                    : DicomSequenceValueParserError.unexpectedEnd
            }

            let tagOffset = offset
            let tag = try readTag(data, offset: &offset, littleEndian: littleEndian)
            let length = try readUInt32(data, offset: &offset, littleEndian: littleEndian)

            if tag == sequenceDelimiterTag {
                try validateDelimiterLength(length, tag: tag)
                guard requiresSequenceDelimiter else {
                    throw DicomSequenceValueParserError.unexpectedSequenceDelimiter
                }
                return SequenceParseResult(items: items, delimiterOffset: tagOffset)
            }

            if tag == itemDelimiterTag {
                try validateDelimiterLength(length, tag: tag)
                throw DicomSequenceValueParserError.unexpectedItemDelimiter
            }

            guard tag == itemTag else {
                throw DicomSequenceValueParserError.expectedItem(tag)
            }

            if length == undefinedLength {
                let dataSet = try parseDataSet(
                    in: data,
                    offset: &offset,
                    end: end,
                    littleEndian: littleEndian,
                    explicitVR: explicitVR,
                    inheritedCharacterSet: characterSet,
                    requiresItemDelimiter: true
                )
                items.append(DicomSequenceItem(dataSet: dataSet))
            } else {
                let itemEnd = offset + Int(length)
                guard itemEnd <= end else {
                    throw DicomSequenceValueParserError.itemExceedsBounds
                }
                let dataSet = try parseDataSet(
                    in: data,
                    offset: &offset,
                    end: itemEnd,
                    littleEndian: littleEndian,
                    explicitVR: explicitVR,
                    inheritedCharacterSet: characterSet,
                    requiresItemDelimiter: false
                )
                items.append(DicomSequenceItem(dataSet: dataSet))
                offset = itemEnd
            }
        }

        if requiresSequenceDelimiter {
            throw DicomSequenceValueParserError.missingSequenceDelimiter
        }
        return SequenceParseResult(items: items, delimiterOffset: nil)
    }

    private static func validateDelimiterLength(_ length: UInt32, tag: Int) throws {
        guard length == 0 else {
            throw DicomSequenceValueParserError.invalidDelimiterLength(tag: tag, length: length)
        }
    }

    private static func readElementHeader(
        _ data: Data,
        offset: inout Int,
        tag: Int,
        littleEndian: Bool,
        explicitVR: Bool
    ) throws -> (vr: DicomVR, length: UInt32) {
        if explicitVR {
            let vrCode = try readASCII(data, offset: &offset, length: 2)
            guard let vr = DicomVR(code: vrCode) else {
                throw DicomSequenceValueParserError.unsupportedVR(vrCode)
            }
            if vr.uses32BitLength {
                guard offset + 2 <= data.count else {
                    throw DicomSequenceValueParserError.unexpectedEnd
                }
                offset += 2
                return (vr, try readUInt32(data, offset: &offset, littleEndian: littleEndian))
            }
            return (vr, UInt32(try readUInt16(data, offset: &offset, littleEndian: littleEndian)))
        }

        let vr = implicitVR(for: tag)
        return (vr, try readUInt32(data, offset: &offset, littleEndian: littleEndian))
    }

    private static func implicitVR(for tag: Int) -> DicomVR {
        switch tag {
        case DicomTag.sharedFunctionalGroupsSequence.rawValue,
             DicomTag.perFrameFunctionalGroupsSequence.rawValue,
             DicomTag.frameContentSequence.rawValue,
             DicomTag.planePositionSequence.rawValue,
             DicomTag.planeOrientationSequence.rawValue,
             DicomTag.pixelMeasuresSequence.rawValue,
             DicomTag.derivationImageSequence.rawValue,
             DicomTag.sourceImageSequence.rawValue,
             DicomTag.referencedSOPSequence.rawValue,
             DicomTag.referencedSeriesSequence.rawValue,
             DicomTag.segmentSequence.rawValue,
             DicomTag.segmentedPropertyCategoryCodeSequence.rawValue,
             DicomTag.segmentedPropertyTypeCodeSequence.rawValue,
             DicomTag.segmentIdentificationSequence.rawValue,
             DicomTag.referencedFrameOfReferenceSequence.rawValue,
             DicomTag.rtReferencedStudySequence.rawValue,
             DicomTag.rtReferencedSeriesSequence.rawValue,
             DicomTag.contourImageSequence.rawValue,
             DicomTag.structureSetROISequence.rawValue,
             DicomTag.rtROIObservationsSequence.rawValue,
             DicomTag.roiContourSequence.rawValue,
             DicomTag.contourSequence.rawValue,
             DicomTag.beamSequence.rawValue,
             DicomTag.controlPointSequence.rawValue,
             DicomTag.modalityLUTSequence.rawValue,
             DicomTag.voiLUTSequence.rawValue,
             DicomTag.presentationLUTSequence.rawValue,
             DicomTag.realWorldValueMappingSequence.rawValue,
             DicomTag.quantityDefinitionSequence.rawValue,
             DicomTag.measurementUnitsCodeSequence.rawValue,
             DicomTag.conceptNameCodeSequence.rawValue,
             DicomTag.conceptCodeSequence.rawValue,
             DicomTag.measuredValueSequence.rawValue,
             DicomTag.currentRequestedProcedureEvidenceSequence.rawValue,
             DicomTag.pertinentOtherEvidenceSequence.rawValue,
             DicomTag.contentTemplateSequence.rawValue,
             DicomTag.contentSequence.rawValue,
             DicomTag.sourceInstanceSequence.rawValue,
             DicomTag.waveformSequence.rawValue,
             DicomTag.channelDefinitionSequence.rawValue,
             DicomTag.channelSourceSequence.rawValue,
             DicomTag.channelSourceModifiersSequence.rawValue,
             DicomTag.sourceWaveformSequence.rawValue,
             DicomTag.channelSensitivityUnitsSequence.rawValue,
             DicomTag.waveformPresentationGroupSequence.rawValue,
             DicomTag.referencedImageSequence.rawValue,
             DicomTag.graphicAnnotationSequence.rawValue,
             DicomTag.textObjectSequence.rawValue,
             DicomTag.graphicObjectSequence.rawValue,
             DicomTag.graphicLayerSequence.rawValue,
             DicomTag.displayedAreaSelectionSequence.rawValue,
             DicomTag.radiopharmaceuticalInformationSequence.rawValue:
            return .SQ
        case DicomTag.dimensionIndexValues.rawValue,
             DicomTag.temporalPositionIndex.rawValue,
             DicomTag.frameAcquisitionNumber.rawValue,
             DicomTag.inStackPositionNumber.rawValue,
             DicomTag.numberOfWaveformSamples.rawValue,
             DicomTag.triggerSamplePosition.rawValue:
            return .UL
        case DicomTag.lutDescriptor.rawValue,
             DicomTag.lutData.rawValue,
             DicomTag.realWorldValueFirstValueMapped.rawValue,
             DicomTag.realWorldValueLastValueMapped.rawValue,
             DicomTag.segmentNumber.rawValue,
             DicomTag.referencedSegmentNumber.rawValue,
             DicomTag.recommendedDisplayCIELabValue.rawValue,
             DicomTag.maximumFractionalValue.rawValue,
             DicomTag.numberOfWaveformChannels.rawValue,
             DicomTag.waveformBitsStored.rawValue,
             DicomTag.waveformBitsAllocated.rawValue,
             DicomTag.referencedWaveformChannels.rawValue,
             DicomTag.graphicLayerRecommendedDisplayGrayscaleValue.rawValue,
             DicomTag.graphicLayerRecommendedDisplayCIELabValue.rawValue,
             DicomTag.graphicDimensions.rawValue,
             DicomTag.numberOfGraphicPoints.rawValue,
             DicomTag.graphicLayerOrder.rawValue,
             DicomTag.imageRotation.rawValue:
            return .US
        case DicomTag.roiNumber.rawValue,
             DicomTag.roiDisplayColor.rawValue,
             DicomTag.numberOfContourPoints.rawValue,
             DicomTag.contourNumber.rawValue,
             DicomTag.observationNumber.rawValue,
             DicomTag.referencedROINumber.rawValue,
             DicomTag.beamNumber.rawValue,
             DicomTag.numberOfControlPoints.rawValue,
             DicomTag.controlPointIndex.rawValue,
             DicomTag.waveformChannelNumber.rawValue,
             DicomTag.shutterLeftVerticalEdge.rawValue,
             DicomTag.shutterRightVerticalEdge.rawValue,
             DicomTag.shutterUpperHorizontalEdge.rawValue,
             DicomTag.shutterLowerHorizontalEdge.rawValue,
             DicomTag.centerOfCircularShutter.rawValue,
             DicomTag.radiusOfCircularShutter.rawValue,
             DicomTag.verticesOfPolygonalShutter.rawValue:
            return .IS
        case DicomTag.realWorldValueSlope.rawValue,
             DicomTag.realWorldValueIntercept.rawValue,
             DicomTag.realWorldValueLUTData.rawValue,
             DicomTag.doubleFloatRealWorldValueFirstValueMapped.rawValue,
             DicomTag.doubleFloatRealWorldValueLastValueMapped.rawValue,
             DicomTag.floatingPointValue.rawValue:
            return .FD
        case DicomTag.referencedFrameNumber.rawValue,
             DicomTag.seriesNumber.rawValue,
             DicomTag.instanceNumber.rawValue:
            return .IS
        case DicomTag.displayedAreaTopLeftHandCorner.rawValue,
             DicomTag.displayedAreaBottomRightHandCorner.rawValue:
            return .SL
        case DicomTag.pixelSpacing.rawValue,
             DicomTag.imagePositionPatient.rawValue,
             DicomTag.imageOrientationPatient.rawValue,
             DicomTag.sliceThickness.rawValue,
             DicomTag.sliceSpacing.rawValue,
             DicomTag.gridFrameOffsetVector.rawValue,
             DicomTag.doseGridScaling.rawValue,
             DicomTag.contourData.rawValue,
             DicomTag.sourceAxisDistance.rawValue,
             DicomTag.nominalBeamEnergy.rawValue,
             DicomTag.gantryAngle.rawValue,
             DicomTag.beamLimitingDeviceAngle.rawValue,
             DicomTag.patientSupportAngle.rawValue,
             DicomTag.tableTopEccentricAngle.rawValue,
             DicomTag.isocenterPosition.rawValue,
             DicomTag.cumulativeMetersetWeight.rawValue,
             DicomTag.windowCenter.rawValue,
             DicomTag.windowWidth.rawValue,
             DicomTag.rescaleIntercept.rawValue,
             DicomTag.rescaleSlope.rawValue,
             DicomTag.patientSize.rawValue,
             DicomTag.patientWeight.rawValue,
             DicomTag.radionuclideTotalDose.rawValue,
             DicomTag.radionuclideHalfLife.rawValue,
             DicomTag.decayFactor.rawValue,
             DicomTag.numericValue.rawValue,
             DicomTag.multiplexGroupTimeOffset.rawValue,
             DicomTag.triggerTimeOffset.rawValue,
             DicomTag.samplingFrequency.rawValue,
             DicomTag.channelSensitivity.rawValue,
             DicomTag.channelSensitivityCorrectionFactor.rawValue,
             DicomTag.channelBaseline.rawValue,
             DicomTag.channelTimeSkew.rawValue,
             DicomTag.channelSampleSkew.rawValue,
             DicomTag.channelOffset.rawValue,
             DicomTag.filterLowFrequency.rawValue,
             DicomTag.filterHighFrequency.rawValue,
             DicomTag.notchFilterFrequency.rawValue:
            return .DS
        case DicomTag.stackID.rawValue,
             DicomTag.codeValue.rawValue,
             DicomTag.codingSchemeDesignator.rawValue,
             DicomTag.mappingResource.rawValue,
             DicomTag.templateIdentifier.rawValue,
             DicomTag.realWorldValueLUTLabel.rawValue,
             DicomTag.multiplexGroupLabel.rawValue,
             DicomTag.channelLabel.rawValue:
            return .SH
        case DicomTag.referencedSOPClassUID.rawValue,
             DicomTag.referencedSOPInstanceUID.rawValue,
             DicomTag.sopClassUID.rawValue,
             DicomTag.sopInstanceUID.rawValue,
             DicomTag.referencedFrameOfReferenceUID.rawValue,
             DicomTag.trackingUID.rawValue,
             DicomTag.uid.rawValue:
            return .UI
        case DicomTag.photometricInterpretation.rawValue,
             DicomTag.imageType.rawValue,
             DicomTag.conversionType.rawValue,
             DicomTag.presentationLUTShape.rawValue,
             DicomTag.valueType.rawValue,
             DicomTag.relationshipType.rawValue,
             DicomTag.continuityOfContent.rawValue,
             DicomTag.graphicType.rawValue,
             DicomTag.graphicAnnotationUnits.rawValue,
             DicomTag.graphicFilled.rawValue,
             DicomTag.presentationSizeMode.rawValue,
             DicomTag.imageHorizontalFlip.rawValue,
             DicomTag.shutterShape.rawValue,
             DicomTag.completionFlag.rawValue,
             DicomTag.verificationFlag.rawValue,
             DicomTag.segmentationType.rawValue,
             DicomTag.segmentAlgorithmType.rawValue,
             DicomTag.segmentationFractionalType.rawValue,
             DicomTag.doseUnits.rawValue,
             DicomTag.doseType.rawValue,
             DicomTag.doseSummationType.rawValue,
             DicomTag.contourGeometricType.rawValue,
             DicomTag.roiGenerationAlgorithm.rawValue,
             DicomTag.rtROIInterpretedType.rawValue,
             DicomTag.rtPlanGeometry.rawValue,
             DicomTag.beamType.rawValue,
             DicomTag.radiationType.rawValue,
             DicomTag.primaryDosimeterUnit.rawValue:
            return .CS
        case DicomTag.units.rawValue,
             DicomTag.suvType.rawValue,
             DicomTag.decayCorrection.rawValue,
             DicomTag.correctedImage.rawValue,
             DicomTag.patientSex.rawValue,
             DicomTag.waveformOriginality.rawValue,
             DicomTag.channelStatus.rawValue,
             DicomTag.waveformSampleInterpretation.rawValue:
            return .CS
        case DicomTag.windowCenterWidthExplanation.rawValue,
             DicomTag.rescaleType.rawValue,
             DicomTag.lutExplanation.rawValue,
             DicomTag.modalityLUTType.rawValue,
             DicomTag.codeMeaning.rawValue,
             DicomTag.segmentLabel.rawValue,
             DicomTag.segmentAlgorithmName.rawValue,
             DicomTag.trackingID.rawValue,
             DicomTag.contentLabel.rawValue,
             DicomTag.graphicLayer.rawValue,
             DicomTag.structureSetName.rawValue,
             DicomTag.roiName.rawValue,
             DicomTag.roiObservationLabel.rawValue,
             DicomTag.rtPlanName.rawValue,
             DicomTag.beamName.rawValue,
             DicomTag.beamDescription.rawValue,
             DicomTag.treatmentMachineName.rawValue,
             DicomTag.secondaryCaptureDeviceID.rawValue,
             DicomTag.secondaryCaptureDeviceManufacturer.rawValue,
             DicomTag.secondaryCaptureDeviceManufacturerModelName.rawValue,
             DicomTag.secondaryCaptureDeviceSoftwareVersions.rawValue,
             DicomTag.channelDerivationDescription.rawValue:
            return .LO
        case DicomTag.segmentDescription.rawValue,
             DicomTag.contentDescription.rawValue,
             DicomTag.unformattedTextValue.rawValue,
             DicomTag.graphicLayerDescription.rawValue,
             DicomTag.structureSetDescription.rawValue,
             DicomTag.roiDescription.rawValue,
             DicomTag.rtPlanDescription.rawValue,
             DicomTag.derivationDescription.rawValue:
            return .ST
        case DicomTag.textValue.rawValue:
            return .UT
        case DicomTag.rationalNumeratorValue.rawValue:
            return .SL
        case DicomTag.rationalDenominatorValue.rawValue,
             DicomTag.encapsulatedDocumentLength.rawValue:
            return .UL
        case DicomTag.encapsulatedDocument.rawValue:
            return .OB
        case DicomTag.waveformData.rawValue,
             DicomTag.waveformPaddingValue.rawValue:
            return .OW
        case DicomTag.contentCreatorName.rawValue,
             DicomTag.roiInterpreter.rawValue,
             DicomTag.personName.rawValue:
            return .PN
        case DicomTag.radiopharmaceuticalStartTime.rawValue,
             DicomTag.acquisitionTime.rawValue,
             DicomTag.instanceCreationTime.rawValue,
             DicomTag.contentTime.rawValue,
             DicomTag.presentationCreationTime.rawValue,
             DicomTag.timeOfSecondaryCapture.rawValue,
             DicomTag.seriesTime.rawValue,
             DicomTag.time.rawValue:
            return .TM
        case DicomTag.radiopharmaceuticalStartDateTime.rawValue,
             DicomTag.dateTime.rawValue:
            return .DT
        case DicomTag.date.rawValue,
             DicomTag.instanceCreationDate.rawValue,
             DicomTag.contentDate.rawValue,
             DicomTag.presentationCreationDate.rawValue,
             DicomTag.dateOfSecondaryCapture.rawValue:
            return .DA
        case DicomTag.graphicData.rawValue,
             DicomTag.boundingBoxTopLeftHandCorner.rawValue,
             DicomTag.boundingBoxBottomRightHandCorner.rawValue,
             DicomTag.anchorPoint.rawValue,
             DicomTag.waveformDataDisplayScale.rawValue:
            return .FL
        case DicomTag.documentTitle.rawValue:
            return .ST
        case DicomTag.mimeTypeOfEncapsulatedDocument.rawValue,
             DicomTag.listOfMIMETypes.rawValue:
            return .LO
        default:
            return .UN
        }
    }

    private static func value(
        for vr: DicomVR,
        data: Data,
        littleEndian: Bool,
        characterSet: DicomSpecificCharacterSet
    ) -> DicomDataValue {
        if let value = DicomDataValueDecoder.binaryValue(for: vr, data: data, littleEndian: littleEndian) {
            return value
        }
        let text = characterSet.decode(data)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        let values = text.split(separator: "\\", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        }
        return values.isEmpty || (values.count == 1 && values[0].isEmpty) ? .empty : .strings(values)
    }

    private static func skipPixelData(
        in data: Data,
        offset: inout Int,
        end: Int,
        length: UInt32,
        littleEndian: Bool
    ) throws {
        if length != undefinedLength {
            let valueEnd = offset + Int(length)
            guard valueEnd <= end else {
                throw DicomSequenceValueParserError.elementExceedsBounds(DicomTag.pixelData.rawValue)
            }
            offset = valueEnd
            return
        }

        while offset < end {
            guard offset + 8 <= end else {
                throw DicomSequenceValueParserError.unexpectedEnd
            }
            let tag = try readTag(data, offset: &offset, littleEndian: littleEndian)
            let itemLength = try readUInt32(data, offset: &offset, littleEndian: littleEndian)
            if tag == sequenceDelimiterTag {
                try validateDelimiterLength(itemLength, tag: tag)
                return
            }
            guard tag == itemTag else {
                throw DicomSequenceValueParserError.expectedItem(tag)
            }
            guard itemLength != undefinedLength else {
                throw DicomSequenceValueParserError.unsupportedUndefinedLengthElement(tag)
            }
            let itemEnd = offset + Int(itemLength)
            guard itemEnd <= end else {
                throw DicomSequenceValueParserError.elementExceedsBounds(tag)
            }
            offset = itemEnd
        }
        throw DicomSequenceValueParserError.missingSequenceDelimiter
    }

    private static func readTag(_ data: Data, offset: inout Int, littleEndian: Bool) throws -> Int {
        let group = try readUInt16(data, offset: &offset, littleEndian: littleEndian)
        let element = try readUInt16(data, offset: &offset, littleEndian: littleEndian)
        return Int(group) << 16 | Int(element)
    }

    private static func readASCII(_ data: Data, offset: inout Int, length: Int) throws -> String {
        guard offset + length <= data.count else {
            throw DicomSequenceValueParserError.unexpectedEnd
        }
        let value = String(data: data[offset..<(offset + length)], encoding: .ascii) ?? ""
        offset += length
        return value
    }

    private static func readUInt16(_ data: Data, offset: inout Int, littleEndian: Bool) throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw DicomSequenceValueParserError.unexpectedEnd
        }
        let value = data.dicomInteger(at: offset, as: UInt16.self, littleEndian: littleEndian)
        offset += 2
        return value
    }

    private static func readUInt32(_ data: Data, offset: inout Int, littleEndian: Bool) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw DicomSequenceValueParserError.unexpectedEnd
        }
        let value = data.dicomInteger(at: offset, as: UInt32.self, littleEndian: littleEndian)
        offset += 4
        return value
    }
}

enum DicomSequenceValueParserError: Error, Equatable {
    case invalidBounds
    case unexpectedEnd
    case unsupportedVR(String)
    case expectedItem(Int)
    case itemExceedsBounds
    case elementExceedsBounds(Int)
    case unsupportedUndefinedLengthElement(Int)
    case missingItemDelimiter
    case missingSequenceDelimiter
    case unexpectedItemDelimiter
    case unexpectedSequenceDelimiter
    case invalidDelimiterLength(tag: Int, length: UInt32)
}
