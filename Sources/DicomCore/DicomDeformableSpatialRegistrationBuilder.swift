import Foundation

public enum DicomDeformableSpatialRegistrationBuilder {
    public static func dataSet(from document: DicomDeformableSpatialRegistrationDocument,
                               studyInstanceUID: String, seriesInstanceUID: String,
                               options: DicomRegistrationBuildOptions = .init()) throws -> DicomDataSet {
        let c = DicomRegistrationCoding.self
        var data = try c.common(sopClass: DicomDeformableSpatialRegistrationDocument.storageSOPClassUID,
            sop: document.sopInstanceUID, frame: document.registeredFrameOfReferenceUID,
            date: document.contentDate, time: document.contentTime, number: document.instanceNumber,
            label: document.contentLabel, description: document.contentDescription, creator: document.contentCreatorName,
            study: studyInstanceUID, series: seriesInstanceUID, options: options)
        for (tag, value) in [(0x00080070, options.manufacturer), (0x00081090, options.manufacturerModelName),
                             (0x00181000, options.deviceSerialNumber), (0x00181020, options.softwareVersions)] {
            guard !value.isEmpty else { throw DicomSpatialRegistrationBuilder.BuildError.invalidDocument }
            data = data.setting(c.text(tag, .LO, value))
        }
        var references: [DicomSOPReference] = []
        let items = try document.registrations.map { item -> DicomDataSet in
            var data = DicomDataSet(elements: [c.text(0x00640003, .UI, item.sourceFrameOfReferenceUID),
                c.sequence(0x0070030D, item.registrationTypeCode.map { [c.code($0)] } ?? [])])
            if let value = item.transformationComment { data = data.setting(c.text(0x300600C8, .LO, value)) }
            if let matrix = item.preMatrix { data = data.setting(c.sequence(0x0064000F, [c.matrix(matrix)])) }
            if let matrix = item.postMatrix { data = data.setting(c.sequence(0x00640010, [c.matrix(matrix)])) }
            if let grid = item.grid {
                guard grid.isValid, [grid.dimensions.x, grid.dimensions.y, grid.dimensions.z].allSatisfy({ UInt32(exactly: $0) != nil })
                else { throw DicomSpatialRegistrationBuilder.BuildError.invalidDocument }
                data = data.setting(c.sequence(0x00640005, [c.gridData(grid)]))
            }
            if !item.referencedImages.isEmpty { data = data.setting(c.sequence(0x00081140, item.referencedImages.map(c.imageData))) }
            if !item.usedFiducials.isEmpty { data = data.setting(c.sequence(0x00700314, item.usedFiducials.map(c.fiducialData))) }
            references += item.referencedImages.map { .init(sopClassUID: $0.referencedSOPClassUID ?? "", sopInstanceUID: $0.referencedSOPInstanceUID ?? "") }
            references += item.usedFiducials.map(\.reference)
            return data
        }
        data = data.setting(c.sequence(0x00640002, items))
        guard DicomDeformableSpatialRegistrationParser.parse(dataSet: data).document != nil
        else { throw DicomSpatialRegistrationBuilder.BuildError.invalidDocument }
        return try c.hierarchy(data, references: references, study: studyInstanceUID, options: options)
    }
}

extension DicomRegistrationCoding {
    static func vectors(_ data: DicomDataSet) -> [Float] {
        guard let bytes = data[0x00640009]?.bytesValue else { return data.floats(for: 0x00640009).map(Float.init) }
        return stride(from: 0, to: bytes.count - bytes.count % 4, by: 4).map { offset in
            let index = bytes.startIndex + offset
            let word = UInt32(bytes[index]) | UInt32(bytes[index+1]) << 8 | UInt32(bytes[index+2]) << 16 | UInt32(bytes[index+3]) << 24
            return Float(bitPattern: word)
        }
    }

    static func gridData(_ grid: DicomDeformableRegistrationGrid) -> DicomDataSet {
        var bytes = Data()
        for value in grid.vectorGridData {
            for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value.bitPattern >> shift)) }
        }
        let p = grid.imagePositionPatient, d = grid.dimensions, r = grid.resolution
        return .init(elements: [decimals(0x00200037, grid.imageOrientationPatient), decimals(0x00200032, [p.x, p.y, p.z]),
            .init(tag: 0x00640007, vr: .UL, value: .unsignedIntegers([UInt(d.x), UInt(d.y), UInt(d.z)])),
            .init(tag: 0x00640008, vr: .FD, value: .floats([r.x, r.y, r.z])),
            .init(tag: 0x00640009, vr: .OF, value: .bytes(bytes))])
    }
}
