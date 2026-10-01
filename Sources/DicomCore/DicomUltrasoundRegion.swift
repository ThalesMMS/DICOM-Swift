//
//  DicomUltrasoundRegion.swift
//  DicomCore
//
//  Parses calibrated regions from Sequence of Ultrasound Regions (0018,6011).
//

import Foundation

public enum DicomUltrasoundPhysicalUnit: Equatable, Sendable {
    case none
    case percent
    case decibels
    case centimeters
    case seconds
    case hertz
    case decibelsPerSecond
    case centimetersPerSecond
    case squareCentimeters
    case squareCentimetersPerSecond
    case cubicCentimeters
    case cubicCentimetersPerSecond
    case degrees
    case other(Int)

    public init(code: Int) {
        switch code {
        case 0: self = .none
        case 1: self = .percent
        case 2: self = .decibels
        case 3: self = .centimeters
        case 4: self = .seconds
        case 5: self = .hertz
        case 6: self = .decibelsPerSecond
        case 7: self = .centimetersPerSecond
        case 8: self = .squareCentimeters
        case 9: self = .squareCentimetersPerSecond
        case 10: self = .cubicCentimeters
        case 11: self = .cubicCentimetersPerSecond
        case 12: self = .degrees
        default: self = .other(code)
        }
    }

    public var code: Int {
        switch self {
        case .none: 0
        case .percent: 1
        case .decibels: 2
        case .centimeters: 3
        case .seconds: 4
        case .hertz: 5
        case .decibelsPerSecond: 6
        case .centimetersPerSecond: 7
        case .squareCentimeters: 8
        case .squareCentimetersPerSecond: 9
        case .cubicCentimeters: 10
        case .cubicCentimetersPerSecond: 11
        case .degrees: 12
        case .other(let code): code
        }
    }
}

public struct DicomUltrasoundRegion: Equatable, Sendable {
    public let minX0: Int
    public let minY0: Int
    public let maxX1: Int
    public let maxY1: Int
    public let spatialFormat: Int
    public let dataType: Int
    public let physicalUnitX: DicomUltrasoundPhysicalUnit
    public let physicalUnitY: DicomUltrasoundPhysicalUnit
    public let physicalDeltaX: Double?
    public let physicalDeltaY: Double?
    public let regionFlags: UInt32
    public let referencePixelX0: Int
    public let referencePixelY0: Int
    public let referencePixelPhysicalValueX: Double
    public let referencePixelPhysicalValueY: Double

    public init(
        minX0: Int,
        minY0: Int,
        maxX1: Int,
        maxY1: Int,
        spatialFormat: Int,
        dataType: Int,
        physicalUnitX: DicomUltrasoundPhysicalUnit,
        physicalUnitY: DicomUltrasoundPhysicalUnit,
        physicalDeltaX: Double?,
        physicalDeltaY: Double?,
        regionFlags: UInt32 = 0,
        referencePixelX0: Int = 0,
        referencePixelY0: Int = 0,
        referencePixelPhysicalValueX: Double = 0,
        referencePixelPhysicalValueY: Double = 0
    ) {
        self.minX0 = minX0
        self.minY0 = minY0
        self.maxX1 = maxX1
        self.maxY1 = maxY1
        self.spatialFormat = spatialFormat
        self.dataType = dataType
        self.physicalUnitX = physicalUnitX
        self.physicalUnitY = physicalUnitY
        self.physicalDeltaX = physicalDeltaX
        self.physicalDeltaY = physicalDeltaY
        self.regionFlags = regionFlags
        self.referencePixelX0 = referencePixelX0
        self.referencePixelY0 = referencePixelY0
        self.referencePixelPhysicalValueX = referencePixelPhysicalValueX
        self.referencePixelPhysicalValueY = referencePixelPhysicalValueY
    }
}

public extension DCMDecoder {
    /// Returns valid entries from Sequence of Ultrasound Regions (0018,6011).
    func ultrasoundRegions() -> [DicomUltrasoundRegion] {
        Self.ultrasoundRegions(in: dataSet)
    }

    /// Resolves frame-scoped regions without leaking metadata from a sibling frame.
    func ultrasoundRegions(forFrame frameIndex: Int) -> [DicomUltrasoundRegion] {
        guard frameIndex >= 0 else { return [] }
        let perFrameItems = dataSet.sequenceItems(for: .perFrameFunctionalGroupsSequence)
        if perFrameItems.indices.contains(frameIndex) {
            let regions = Self.findUltrasoundRegions(in: perFrameItems[frameIndex].dataSet)
            if !regions.isEmpty { return regions }
        }
        if let shared = dataSet.sequenceItems(for: .sharedFunctionalGroupsSequence).first {
            let regions = Self.findUltrasoundRegions(in: shared.dataSet)
            if !regions.isEmpty { return regions }
        }
        return ultrasoundRegions()
    }
}

extension DCMDecoder {
    private static func ultrasoundRegions(in dataSet: DicomDataSet) -> [DicomUltrasoundRegion] {
        dataSet.sequenceItems(for: 0x00186011).compactMap { item in
            ultrasoundRegion(from: item.dataSet)
        }
    }

    private static func findUltrasoundRegions(in dataSet: DicomDataSet, depth: Int = 0) -> [DicomUltrasoundRegion] {
        let direct = ultrasoundRegions(in: dataSet)
        guard direct.isEmpty, depth < 4 else { return direct }
        for element in dataSet.elements {
            for item in element.sequenceItems {
                let nested = findUltrasoundRegions(in: item.dataSet, depth: depth + 1)
                if !nested.isEmpty { return nested }
            }
        }
        return []
    }

    /// Shared with the original-byte IOD validator; rendering and qualification use the same region bounds.
    static func ultrasoundRegion(from dataSet: DicomDataSet) -> DicomUltrasoundRegion? {
        guard let minX0 = dataSet.int(for: 0x00186018),
              let minY0 = dataSet.int(for: 0x0018601A),
              let maxX1 = dataSet.int(for: 0x0018601C),
              let maxY1 = dataSet.int(for: 0x0018601E),
              minX0 >= 0,
              minY0 >= 0,
              maxX1 >= minX0,
              maxY1 >= minY0 else {
            return nil
        }

        return DicomUltrasoundRegion(
            minX0: minX0,
            minY0: minY0,
            maxX1: maxX1,
            maxY1: maxY1,
            spatialFormat: dataSet.int(for: 0x00186012) ?? 0,
            dataType: dataSet.int(for: 0x00186014) ?? 0,
            physicalUnitX: DicomUltrasoundPhysicalUnit(code: dataSet.int(for: 0x00186024) ?? 0),
            physicalUnitY: DicomUltrasoundPhysicalUnit(code: dataSet.int(for: 0x00186026) ?? 0),
            physicalDeltaX: dataSet.float(for: 0x0018602C),
            physicalDeltaY: dataSet.float(for: 0x0018602E),
            regionFlags: UInt32(clamping: dataSet.int(for: 0x00186016) ?? 0),
            referencePixelX0: dataSet.int(for: 0x00186020) ?? 0,
            referencePixelY0: dataSet.int(for: 0x00186022) ?? 0,
            referencePixelPhysicalValueX: dataSet.float(for: 0x00186028) ?? 0,
            referencePixelPhysicalValueY: dataSet.float(for: 0x0018602A) ?? 0
        )
    }
}
