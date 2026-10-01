import Foundation

public enum DicomRTStructureSetBuilder {
    public static func dataSet(
        from structureSet: DicomRTStructureSet,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String? = nil,
        options: DicomRTStructureSetBuildOptions = .init()
    ) -> DicomDataSet {
        var elements = [
            text(0x00080016, .UI, DicomRTStructureSet.storageSOPClassUID),
            text(0x00080018, .UI, sopInstanceUID ?? structureSet.sopInstanceUID ?? DicomDataSetWriter.makeUID()),
            text(0x0020000D, .UI, studyInstanceUID), text(0x0020000E, .UI, seriesInstanceUID),
            text(0x00100010, .PN, options.patientName), text(0x00100020, .LO, options.patientID),
            text(0x00100030, .DA, options.patientBirthDate), text(0x00100040, .CS, options.patientSex),
            text(0x00080020, .DA, options.studyDate), text(0x00080030, .TM, options.studyTime),
            text(0x00080090, .PN, options.referringPhysicianName), text(0x00200010, .SH, options.studyID),
            text(0x00080050, .SH, options.accessionNumber), text(0x00080060, .CS, "RTSTRUCT"),
            text(0x00200011, .IS, String(options.seriesNumber)),
            text(0x00200013, .IS, String(options.instanceNumber)),
            text(0x00080070, .LO, options.manufacturer), text(0x00081070, .PN, options.operatorsName),
            text(0x00081090, .LO, options.manufacturerModelName),
            text(0x00181000, .LO, options.deviceSerialNumber), text(0x00181020, .LO, options.softwareVersions),
            text(0x30060002, .SH, structureSet.label ?? "RTSTRUCT"),
            text(0x30060008, .DA, structureSet.structureSetDate ?? ""),
            text(0x30060009, .TM, structureSet.structureSetTime ?? "")
        ]
        if let name = structureSet.name { elements.append(text(0x30060004, .LO, name)) }
        if let description = structureSet.description { elements.append(text(0x30060006, .ST, description)) }
        if !structureSet.referencedFramesOfReference.isEmpty {
            elements.append(sequence(0x30060010, structureSet.referencedFramesOfReference.map { frame in
                var item = [text(0x00200052, .UI, frame.frameOfReferenceUID)]
                if !frame.studies.isEmpty {
                    item.append(sequence(0x30060012, frame.studies.map { study in
                        DicomDataSet(elements: [
                            text(0x00081150, .UI, study.referencedSOPClassUID ?? ""),
                            text(0x00081155, .UI, study.referencedSOPInstanceUID ?? ""),
                            sequence(0x30060014, study.series.map { series in
                                DicomDataSet(elements: [text(0x0020000E, .UI, series.seriesInstanceUID),
                                    sequence(0x30060016, series.instances.map(reference))])
                            })
                        ])
                    }))
                }
                return DicomDataSet(elements: item)
            }))
        }
        if !structureSet.rois.isEmpty {
            elements.append(sequence(0x30060020, structureSet.rois.map { roi in
                var item = [text(0x30060022, .IS, String(roi.number)), text(0x30060026, .LO, roi.name),
                    text(0x30060024, .UI, roi.referencedFrameOfReferenceUID ?? ""),
                    text(0x30060036, .CS, roi.generationAlgorithm ?? "")]
                if let value = roi.description { item.append(text(0x30060028, .ST, value)) }
                if let value = roi.generationDescription { item.append(text(0x30060038, .LO, value)) }
                if let value = roi.derivationCode { item.append(sequence(0x00089215, [codeDataSet(value)])) }
                return DicomDataSet(elements: item)
            }))
        }
        if !structureSet.roiContours.isEmpty {
            elements.append(sequence(0x30060039, structureSet.roiContours.map { roi in
                var item = [text(0x30060084, .IS, String(roi.referencedROINumber))]
                if !roi.displayColor.isEmpty {
                    item.append(strings(0x3006002A, .IS, roi.displayColor.map(String.init)))
                }
                if let planes = roi.sourcePixelPlanes {
                    item.append(sequence(0x3006004A, [pixelPlanesDataSet(planes)]))
                }
                if !roi.contours.isEmpty {
                    item.append(sequence(0x30060040, roi.contours.map { contour in
                        var data = [text(0x30060042, .CS, contour.geometricType),
                            text(0x30060046, .IS, String(contour.points.count)),
                            decimals(0x30060050, contour.points.flatMap { [$0.x, $0.y, $0.z] })]
                        if let number = contour.number { data.append(text(0x30060048, .IS, String(number))) }
                        if !contour.sourceImageReferences.isEmpty {
                            data.append(sequence(0x30060016, contour.sourceImageReferences.map(reference)))
                        }
                        return DicomDataSet(elements: data)
                    }))
                }
                return DicomDataSet(elements: item)
            }))
        }
        if !structureSet.observations.isEmpty {
            elements.append(sequence(0x30060080, structureSet.observations.map { observation in
                var item = [text(0x30060082, .IS, String(observation.number)),
                    text(0x30060084, .IS, String(observation.referencedROINumber)),
                    text(0x300600A4, .CS, observation.interpretedType ?? ""),
                    text(0x300600A6, .PN, observation.interpreter ?? "")]
                if let label = observation.label { item.append(text(0x30060085, .SH, label)) }
                if let code = observation.identificationCode { item.append(sequence(0x30060086, [codeDataSet(code)])) }
                if let code = observation.therapeuticRoleTypeCode {
                    item.append(sequence(0x30100065, [codeDataSet(code)]))
                }
                if !observation.physicalProperties.isEmpty {
                    item.append(sequence(0x300600B0, observation.physicalProperties.map {
                        DicomDataSet(elements: [text(0x300600B2, .CS, $0.name), decimals(0x300600B4, [$0.value])])
                    }))
                }
                return DicomDataSet(elements: item)
            }))
        }
        return DicomDataSet(elements: elements)
    }

    static func frames(from dataSet: DicomDataSet) -> [DicomRTReferencedFrameOfReference] {
        dataSet.sequenceItems(for: 0x30060010).compactMap { frame in
            guard let uid = frame.dataSet.string(for: 0x00200052) else { return nil }
            return DicomRTReferencedFrameOfReference(frameOfReferenceUID: uid,
                studies: frame.dataSet.sequenceItems(for: 0x30060012).map { study in
                    DicomRTReferencedStudy(
                        referencedSOPClassUID: study.dataSet.string(for: 0x00081150),
                        referencedSOPInstanceUID: study.dataSet.string(for: 0x00081155),
                        series: study.dataSet.sequenceItems(for: 0x30060014).compactMap { series in
                            guard let uid = series.dataSet.string(for: 0x0020000E) else { return nil }
                            return DicomRTReferencedSeries(seriesInstanceUID: uid,
                                instances: series.dataSet.sequenceItems(for: 0x30060016).map { readReference($0.dataSet) })
                        })
                })
        }
    }

    static func pixelPlanes(from dataSet: DicomDataSet) -> DicomRTSourcePixelPlanes? {
        guard let item = dataSet.sequenceItems(for: 0x3006004A).first?.dataSet else { return nil }
        let orientation = item.decimalStrings(for: 0x00200037)
        let position = item.decimalStrings(for: 0x00200032)
        let spacing = item.decimalStrings(for: 0x00280030)
        guard orientation.count == 6, position.count == 3, spacing.count == 2,
              let rows = item.int(for: 0x00280010), let columns = item.int(for: 0x00280011),
              let frames = item.int(for: 0x00280008), let slices = item.decimalString(for: 0x00180088) else { return nil }
        return DicomRTSourcePixelPlanes(position: .init(position[0], position[1], position[2]),
            orientation: .init(row: .init(orientation[0], orientation[1], orientation[2]),
                               column: .init(orientation[3], orientation[4], orientation[5])),
            spacing: .init(spacing[0], spacing[1]), rows: rows, columns: columns,
            spacingBetweenSlices: slices, numberOfFrames: frames, sliceThickness: item.decimalString(for: 0x00180050))
    }

    static func pixelPlanesDataSet(_ planes: DicomRTSourcePixelPlanes) -> DicomDataSet {
        let row = planes.orientation.row, column = planes.orientation.column, position = planes.position
        var elements = [decimals(0x00200037, [row.x, row.y, row.z, column.x, column.y, column.z]),
            decimals(0x00200032, [position.x, position.y, position.z]),
            decimals(0x00280030, [planes.spacing.x, planes.spacing.y]),
            decimals(0x00180088, [planes.spacingBetweenSlices]),
            text(0x00280008, .IS, String(planes.numberOfFrames)),
            DicomDataElement(tag: 0x00280010, vr: .US, value: .unsignedIntegers([UInt(planes.rows)])),
            DicomDataElement(tag: 0x00280011, vr: .US, value: .unsignedIntegers([UInt(planes.columns)]))]
        if let thickness = planes.sliceThickness { elements.append(decimals(0x00180050, [thickness])) }
        return DicomDataSet(elements: elements)
    }

    static func readReference(_ data: DicomDataSet) -> DicomSourceImageReference {
        DicomSourceImageReference(referencedSOPClassUID: data.string(for: 0x00081150),
            referencedSOPInstanceUID: data.string(for: 0x00081155), referencedFrameNumbers: data.ints(for: 0x00081160))
    }

    static func reference(_ reference: DicomSourceImageReference) -> DicomDataSet {
        var elements = [text(0x00081150, .UI, reference.referencedSOPClassUID ?? ""),
                        text(0x00081155, .UI, reference.referencedSOPInstanceUID ?? "")]
        if !reference.referencedFrameNumbers.isEmpty {
            elements.append(strings(0x00081160, .IS, reference.referencedFrameNumbers.map(String.init)))
        }
        return DicomDataSet(elements: elements)
    }

    static func code(in data: DicomDataSet, tag: Int) -> DicomCodedConcept? {
        guard let item = data.sequenceItems(for: tag).first?.dataSet,
              let value = item.string(for: 0x00080100), let scheme = item.string(for: 0x00080102) else { return nil }
        return DicomCodedConcept(codeValue: value, codingSchemeDesignator: scheme,
            codeMeaning: item.string(for: 0x00080104), codingSchemeVersion: item.string(for: 0x00080103))
    }

    static func codeDataSet(_ code: DicomCodedConcept) -> DicomDataSet {
        var elements = [text(0x00080100, .SH, code.codeValue), text(0x00080102, .SH, code.codingSchemeDesignator)]
        if let meaning = code.codeMeaning { elements.append(text(0x00080104, .LO, meaning)) }
        if let version = code.codingSchemeVersion { elements.append(text(0x00080103, .SH, version)) }
        return DicomDataSet(elements: elements)
    }

    static func text(_ tag: Int, _ vr: DicomVR, _ value: String) -> DicomDataElement {
        strings(tag, vr, [value])
    }

    static func strings(_ tag: Int, _ vr: DicomVR, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings(values))
    }

    static func decimals(_ tag: Int, _ values: [Double]) -> DicomDataElement {
        strings(tag, .DS, values.map { value in
            let shortest = String(value)
            if shortest.utf8.count <= 16 { return shortest }
            for precision in stride(from: 15, through: 1, by: -1) {
                let text = String(format: "%.*g", locale: Locale(identifier: "en_US_POSIX"), precision, value)
                if text.utf8.count <= 16 { return text }
            }
            return shortest
        })
    }

    static func sequence(_ tag: Int, _ items: [DicomDataSet]) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: .SQ, value: .sequence(items.map { DicomSequenceItem(dataSet: $0) }))
    }
}
