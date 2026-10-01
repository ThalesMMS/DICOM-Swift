import Foundation

/// PS3.3 C.35.1. Units are explicit; absent or unknown units never imply millimeters.
public struct DicomManufacturing3DModel: Equatable, Sendable {
    public var measurementUnits: DicomCodedConcept?
    public var modelModification: String?
    public var modelMirroring: String?
    public var usageCode: DicomCodedConcept?
    public var contentDescription: String?
    public var derivationAlgorithm: DicomAlgorithmIdentification?
    public var modelGroupUID: String?
    public var recommendedDisplayCIELabValue: [UInt16]
    public var recommendedPresentationOpacity: Double?

    public init(measurementUnits: DicomCodedConcept? = nil, modelModification: String? = nil,
                modelMirroring: String? = nil, usageCode: DicomCodedConcept? = nil,
                contentDescription: String? = nil, derivationAlgorithm: DicomAlgorithmIdentification? = nil,
                modelGroupUID: String? = nil, recommendedDisplayCIELabValue: [UInt16] = [],
                recommendedPresentationOpacity: Double? = nil) {
        self.measurementUnits = measurementUnits
        self.modelModification = modelModification
        self.modelMirroring = modelMirroring
        self.usageCode = usageCode
        self.contentDescription = contentDescription
        self.derivationAlgorithm = derivationAlgorithm
        self.modelGroupUID = modelGroupUID
        self.recommendedDisplayCIELabValue = recommendedDisplayCIELabValue
        self.recommendedPresentationOpacity = recommendedPresentationOpacity
    }

    public var millimetersPerUnit: Float? {
        guard measurementUnits?.codingSchemeDesignator == "UCUM" else { return nil }
        switch measurementUnits?.codeValue {
        case "mm": return 1
        case "cm": return 10
        case "m": return 1000
        case "um": return 0.001
        case "[in_i]": return 25.4
        default: return nil
        }
    }

    init?(dataSet ds: DicomDataSet) {
        guard [0x004008EA, 0x00687001, 0x00687002, 0x00687003, 0x00700081, 0x00221612,
               0x00687004, 0x0062000D, 0x0066000C].contains(where: ds.contains) else { return nil }
        self.init(measurementUnits: ds[0x004008EA]?.sequenceItems.first.flatMap { EncDocFields.parseCode($0.dataSet) },
                  modelModification: ds[0x00687001]?.stringValue, modelMirroring: ds[0x00687002]?.stringValue,
                  usageCode: ds[0x00687003]?.sequenceItems.first.flatMap { EncDocFields.parseCode($0.dataSet) },
                  contentDescription: ds[0x00700081]?.stringValue, modelGroupUID: ds[0x00687004]?.stringValue,
                  recommendedDisplayCIELabValue: (ds[0x0062000D]?.intValues ?? []).map { UInt16(clamping: $0) },
                  recommendedPresentationOpacity: ds[0x0066000C]?.floatValue)
        if let algorithm = ds[0x00221612]?.sequenceItems.first?.dataSet,
           let name = algorithm[0x00660036]?.stringValue, let version = algorithm[0x00660031]?.stringValue,
           let family = algorithm[0x0066002F]?.sequenceItems.first.flatMap({ EncDocFields.parseCode($0.dataSet) }) {
            derivationAlgorithm = .init(name: name, version: version, family: family,
                                        parameters: algorithm[0x00660032]?.stringValue)
        }
    }

    var optionalElements: [DicomDataElement] {
        var result: [DicomDataElement] = []
        for (tag, vr, value) in [(0x00687001, DicomVR.CS, modelModification), (0x00687002, .CS, modelMirroring),
                                 (0x00700081, .LO, contentDescription), (0x00687004, .UI, modelGroupUID)] {
            if let value { result.append(EncDocFields.text(tag, vr, value)) }
        }
        if let usageCode { result.append(EncDocFields.sequence(0x00687003, [EncDocFields.code(usageCode)])) }
        if let a = derivationAlgorithm {
            var fields = [EncDocFields.text(0x00660036, .LO, a.name), EncDocFields.text(0x00660031, .LO, a.version),
                          EncDocFields.sequence(0x0066002F, [EncDocFields.code(a.family)])]
            if let parameters = a.parameters { fields.append(EncDocFields.text(0x00660032, .LT, parameters)) }
            result.append(EncDocFields.sequence(0x00221612, [.init(elements: fields)]))
        }
        if !recommendedDisplayCIELabValue.isEmpty {
            result.append(.init(tag: 0x0062000D, vr: .US,
                                value: .unsignedIntegers(recommendedDisplayCIELabValue.map(UInt.init))))
        }
        if let opacity = recommendedPresentationOpacity {
            result.append(.init(tag: 0x0066000C, vr: .FL, value: .floats([opacity])))
        }
        return result
    }
}
