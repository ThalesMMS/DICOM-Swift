import Foundation

/// Typed attributes from PS3.3 2026c; omitted optional values remain absent.
public struct DicomRTDVHReferencedROI: Equatable, Sendable {
    public var number: Int
    public var contributionType: String

    public init(
        number: Int,
        contributionType: String
    ) {
        self.number = number
        self.contributionType = contributionType
    }

    init?(data: DicomDataSet) {
        guard let number = data.int(for: 0x30060084) else { return nil }
        guard let contributionType = data.string(for: 0x30040062) else { return nil }
        self.init(
            number: number,
            contributionType: contributionType
        )
    }

    var dataSet: DicomDataSet {
        var elements: [DicomDataElement] = []
        elements.append(DicomRTValueCoding.text(0x30060084, .IS, String(number)))
        elements.append(DicomRTValueCoding.text(0x30040062, .CS, contributionType))
        return DicomDataSet(elements: elements)
    }
}

/// Stored histogram bins, not recomputed from dose or ROI geometry.
public struct DicomRTDVH: Equatable, Sendable {
    public var referencedROIs: [DicomRTDVHReferencedROI]
    public var type: String
    public var doseUnits: String
    public var doseType: String
    public var doseScaling: Double
    public var volumeUnits: String
    public var numberOfBins: Int
    public var bins: [(doseBinWidth: Double, volume: Double)]
    public var minimumDose: Double?
    public var maximumDose: Double?
    public var meanDose: Double?

    public init(referencedROIs: [DicomRTDVHReferencedROI], type: String, doseUnits: String, doseType: String,
                doseScaling: Double, volumeUnits: String, numberOfBins: Int? = nil,
                bins: [(doseBinWidth: Double, volume: Double)], minimumDose: Double? = nil,
                maximumDose: Double? = nil, meanDose: Double? = nil) {
        self.referencedROIs = referencedROIs
        self.type = type
        self.doseUnits = doseUnits
        self.doseType = doseType
        self.doseScaling = doseScaling
        self.volumeUnits = volumeUnits
        self.numberOfBins = numberOfBins ?? bins.count
        self.bins = bins
        self.minimumDose = minimumDose
        self.maximumDose = maximumDose
        self.meanDose = meanDose
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.referencedROIs == rhs.referencedROIs && lhs.type == rhs.type && lhs.doseUnits == rhs.doseUnits &&
            lhs.doseType == rhs.doseType && lhs.doseScaling == rhs.doseScaling && lhs.volumeUnits == rhs.volumeUnits &&
            lhs.numberOfBins == rhs.numberOfBins && lhs.bins.elementsEqual(rhs.bins, by: { $0 == $1 }) &&
            lhs.minimumDose == rhs.minimumDose && lhs.maximumDose == rhs.maximumDose && lhs.meanDose == rhs.meanDose
    }

    static func parse(_ data: DicomDataSet, index: Int, diagnostics: inout [DicomRTDoseDiagnostic]) -> Self? {
        let values = data.decimalStrings(for: 0x30040058)
        guard let count = data.int(for: 0x30040056), count > 0,
              values.count.isMultiple(of: 2), count == values.count / 2 else {
            diagnostics.append(.init(code: .dvhDataCountMismatch, dvhIndex: index))
            return nil
        }
        guard let type = data.string(for: 0x30040001), let units = data.string(for: 0x30040002),
              let doseType = data.string(for: 0x30040004), let scaling = data.decimalString(for: 0x30040052),
              let volumeUnits = data.string(for: 0x30040054) else { return nil }
        let roiItems = data.sequenceItems(for: 0x30040060)
        let rois = roiItems.compactMap { DicomRTDVHReferencedROI(data: $0.dataSet) }
        guard !rois.isEmpty, rois.count == roiItems.count else {
            diagnostics.append(.init(code: .dvhReferencedROIInvalid, dvhIndex: index))
            return nil
        }
        return Self(referencedROIs: rois,
            type: type, doseUnits: units, doseType: doseType, doseScaling: scaling, volumeUnits: volumeUnits,
            numberOfBins: count, bins: stride(from: 0, to: values.count, by: 2).map { (values[$0], values[$0 + 1]) },
            minimumDose: data.decimalString(for: 0x30040070), maximumDose: data.decimalString(for: 0x30040072),
            meanDose: data.decimalString(for: 0x30040074))
    }

    var dataSet: DicomDataSet {
        var elements = [DicomRTValueCoding.sequence(0x30040060, referencedROIs.map { $0.dataSet }),
            DicomRTValueCoding.text(0x30040001, .CS, type), DicomRTValueCoding.text(0x30040002, .CS, doseUnits),
            DicomRTValueCoding.text(0x30040004, .CS, doseType), DicomRTValueCoding.decimals(0x30040052, [doseScaling]),
            DicomRTValueCoding.text(0x30040054, .CS, volumeUnits),
            DicomRTValueCoding.text(0x30040056, .IS, String(numberOfBins)),
            DicomRTValueCoding.decimals(0x30040058, bins.flatMap { [$0.doseBinWidth, $0.volume] })]
        for (tag, value) in [(0x30040070, minimumDose), (0x30040072, maximumDose), (0x30040074, meanDose)] {
            if let value { elements.append(DicomRTValueCoding.decimals(tag, [value])) }
        }
        return DicomDataSet(elements: elements)
    }
}

public struct DicomRTRecommendedIsodoseLevel: Equatable, Sendable {
    public var doseValue: Double
    public var cielab: SIMD3<UInt16>

    public init(doseValue: Double, cielab: SIMD3<UInt16>) {
        self.doseValue = doseValue
        self.cielab = cielab
    }

    init?(data: DicomDataSet) {
        let color = data.ints(for: 0x0062000D)
        guard let dose = data.decimalString(for: 0x30040012), color.count == 3,
              color.allSatisfy({ UInt16(exactly: $0) != nil }) else { return nil }
        self.init(doseValue: dose, cielab: SIMD3(UInt16(color[0]), UInt16(color[1]), UInt16(color[2])))
    }

    var dataSet: DicomDataSet {
        DicomDataSet(elements: [DicomRTValueCoding.decimals(0x30040012, [doseValue]),
            DicomDataElement(tag: 0x0062000D, vr: .US, value: .unsignedIntegers([UInt(cielab.x), UInt(cielab.y), UInt(cielab.z)]))])
    }
}
