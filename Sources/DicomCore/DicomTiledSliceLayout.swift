//
//  DicomTiledSliceLayout.swift
//  DicomCore
//
//  An image whose pixel grid tiles the slices of a volume (issue #2827): a Siemens MOSAIC (fMRI, DTI, perfusion) or
//  a United Imaging grid. Detection and geometry follow GDCM's SplitMosaicFilter and SplitGridFilter
//  (Copyright (c) 2006-2011 Mathieu Malaterre, BSD 3-Clause License), formulas ported, no code copied.
//

import DicomData
import Foundation
import simd

public struct DicomTiledSliceLayout: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// ImageType ends in MOSAIC; the count is the CSA `NumberOfImagesInMosaic` or (0019,xx0A).
        case siemensMosaic
        /// The "Image Private Header" creator of group 0065: the count (xx50) and one IPP per tile (xx51).
        case unitedImagingGrid
    }

    public let kind: Kind
    /// Tiles per row of the grid; tile `t` sits at column `t % tilesPerRow`, row `t / tilesPerRow`.
    public let tilesPerRow: Int
    public let tileColumns: Int
    public let tileRows: Int
    /// Image Position (Patient) of the first voxel of each tile, in tile order.
    public let tilePositions: [SIMD3<Double>]
    /// Row and column direction cosines of every tile (the image's own).
    public let rowDirection: SIMD3<Double>
    public let columnDirection: SIMD3<Double>

    public var sliceCount: Int { tilePositions.count }

    /// Tile indices from the lowest to the highest position along row × column, the order of a volume whose slice
    /// axis is that normal.
    public var tilesInVolumeOrder: [Int] {
        let normal = simd_normalize(simd_cross(rowDirection, columnDirection))
        return tilePositions.indices.sorted { simd_dot(tilePositions[$0], normal) < simd_dot(tilePositions[$1], normal) }
    }

    /// The distance between consecutive slices in volume order, along the normal.
    public var sliceSpacing: Double {
        let order = tilesInVolumeOrder
        guard order.count > 1 else { return 0 }
        let normal = simd_normalize(simd_cross(rowDirection, columnDirection))
        let span = simd_dot(tilePositions[order[order.count - 1]] - tilePositions[order[0]], normal)
        return span / Double(order.count - 1)
    }

    public init(kind: Kind, tilesPerRow: Int, tileColumns: Int, tileRows: Int, tilePositions: [SIMD3<Double>],
                rowDirection: SIMD3<Double>, columnDirection: SIMD3<Double>) {
        self.kind = kind
        self.tilesPerRow = tilesPerRow
        self.tileColumns = tileColumns
        self.tileRows = tileRows
        self.tilePositions = tilePositions
        self.rowDirection = rowDirection
        self.columnDirection = columnDirection
    }

    /// The layout of `dataSet`, or nil when it is not a tiled image or its geometry is incomplete.
    public static func detect(in dataSet: DicomDataSet) -> DicomTiledSliceLayout? {
        let columns = dataSet.int(for: 0x0028_0011) ?? 0, rows = dataSet.int(for: 0x0028_0010) ?? 0
        let orientation = dataSet.decimalStrings(for: 0x0020_0037)
        let position = dataSet.decimalStrings(for: 0x0020_0032)
        let spacing = dataSet.decimalStrings(for: 0x0028_0030)
        guard columns > 0, rows > 0, orientation.count == 6, position.count == 3, spacing.count == 2,
              spacing.allSatisfy({ $0 > 0 }) else { return nil }
        let x = simd_normalize(SIMD3(orientation[0], orientation[1], orientation[2]))
        let y = simd_normalize(SIMD3(orientation[3], orientation[4], orientation[5]))
        guard x.x.isFinite, y.x.isFinite else { return nil }
        let ipp = SIMD3(position[0], position[1], position[2])
        // Pixel Spacing is row spacing (along the column direction) \ column spacing (along the row direction).
        let columnSpacing = spacing[1], rowSpacing = spacing[0]
        if let mosaic = siemensMosaic(dataSet, columns: columns, rows: rows, x: x, y: y, ipp: ipp,
                                      columnSpacing: columnSpacing, rowSpacing: rowSpacing) {
            return mosaic
        }
        return unitedImagingGrid(dataSet, columns: columns, rows: rows, x: x, y: y)
    }

    /// The tiles as slices, in volume order: samples of `bytesPerSample` bytes, rows of `columns` samples.
    public func slices(fromImage pixels: Data, columns: Int, bytesPerSample: Int) -> Data? {
        guard tilesPerRow > 0, tileColumns > 0, tileRows > 0, bytesPerSample > 0, sliceCount > 0,
              columns > 0, tilesPerRow <= columns / tileColumns else { return nil }
        let tileBytes = tileColumns.multipliedReportingOverflow(by: bytesPerSample)
        let rowBytes = columns.multipliedReportingOverflow(by: bytesPerSample)
        let requiredRows = ((sliceCount - 1) / tilesPerRow + 1).multipliedReportingOverflow(by: tileRows)
        let requiredBytes = requiredRows.partialValue.multipliedReportingOverflow(by: rowBytes.partialValue)
        let outputRows = sliceCount.multipliedReportingOverflow(by: tileRows)
        let outputBytes = outputRows.partialValue.multipliedReportingOverflow(by: tileBytes.partialValue)
        guard !tileBytes.overflow, !rowBytes.overflow, !requiredRows.overflow, !requiredBytes.overflow,
              !outputRows.overflow, !outputBytes.overflow, pixels.count >= requiredBytes.partialValue else { return nil }
        let tileRowBytes = tileBytes.partialValue, imageRowBytes = rowBytes.partialValue
        var output = Data(count: outputBytes.partialValue)
        output.withUnsafeMutableBytes { target in
            pixels.withUnsafeBytes { source in
                for (slice, tile) in tilesInVolumeOrder.enumerated() {
                    let left = (tile % tilesPerRow) * tileRowBytes, top = (tile / tilesPerRow) * tileRows
                    for row in 0 ..< tileRows {
                        target.baseAddress!.advanced(by: (slice * tileRows + row) * tileRowBytes).copyMemory(
                            from: source.baseAddress!.advanced(by: (top + row) * imageRowBytes + left),
                            byteCount: tileRowBytes)
                    }
                }
            }
        }
        return output
    }

    // MARK: - Siemens MOSAIC

    private static func siemensMosaic(_ dataSet: DicomDataSet, columns: Int, rows: Int, x: SIMD3<Double>,
                                      y: SIMD3<Double>, ipp: SIMD3<Double>, columnSpacing: Double,
                                      rowSpacing: Double) -> DicomTiledSliceLayout? {
        guard dataSet.strings(for: 0x0008_0008).last?.trimmingCharacters(in: .whitespaces).uppercased() == "MOSAIC"
        else { return nil }
        let csa = dataSet.siemensCSAHeader(for: 0x0029_1010)
        var count = csa?.numericValues(named: "NumberOfImagesInMosaic")?.first.flatMap { Int(exactly: $0) } ?? 0
        if count == 0, let element = dataSet.privateElement(group: 0x0019, creator: "SIEMENS MR HEADER",
                                                            privateElement: 0x0A) {
            // An anonymizer may leave the element while dropping the CSA header; implicit VR reads it as bytes.
            count = element.intValue ?? element.bytesValue.flatMap { data in
                data.count >= 2 ? Int(UInt16(data[data.startIndex]) | UInt16(data[data.startIndex + 1]) << 8) : nil
            } ?? 0
        }
        let capacity = columns.multipliedReportingOverflow(by: rows)
        guard !capacity.overflow, count > 1, count <= capacity.partialValue else { return nil }
        let tilesPerRow = Int(Double(count).squareRoot().rounded(.up))
        let tileColumns = columns / tilesPerRow, tileRows = rows / tilesPerRow
        guard tileColumns > 0, tileRows > 0 else { return nil }
        let normal = simd_normalize(simd_cross(x, y))
        // The CSA slice normal gives the order of the tiles: along the image normal or against it.
        var sliceNormal = normal
        if let vector = csa?.numericValues(named: "SliceNormalVector"), vector.count >= 3 {
            let dot = simd_dot(simd_normalize(SIMD3(vector[0], vector[1], vector[2])), normal)
            guard abs(abs(dot) - 1) < 1e-6 else { return nil }
            sliceNormal = dot < 0 ? -normal : normal
        }
        guard let sliceSpacing = [dataSet.decimalString(for: 0x0018_0088), dataSet.decimalString(for: 0x0018_0050)]
            .compactMap({ $0 }).first(where: { $0 > 0 }) else { return nil }
        // The image position is the corner of the whole mosaic; the first tile is centred in it (nibabel's and
        // GDCM's correction). Each further tile is one slice along the slice normal.
        let first = ipp + Double(columns - tileColumns) / 2 * columnSpacing * x
            + Double(rows - tileRows) / 2 * rowSpacing * y
        let positions = (0 ..< count).map { first + Double($0) * sliceSpacing * sliceNormal }
        return DicomTiledSliceLayout(kind: .siemensMosaic, tilesPerRow: tilesPerRow, tileColumns: tileColumns,
                                     tileRows: tileRows, tilePositions: positions, rowDirection: x, columnDirection: y)
    }

    // MARK: - United Imaging grid

    private static let unitedImagingCreator = "Image Private Header"

    private static func unitedImagingGrid(_ dataSet: DicomDataSet, columns: Int, rows: Int, x: SIMD3<Double>,
                                          y: SIMD3<Double>) -> DicomTiledSliceLayout? {
        let capacity = columns.multipliedReportingOverflow(by: rows)
        guard !capacity.overflow, let countElement = dataSet.privateElement(group: 0x0065, creator: unitedImagingCreator,
                                                        privateElement: 0x50),
              let count = (countElement.decimalStringValue ?? decimalString(countElement.bytesValue)).flatMap({ Int(exactly: $0) }),
              count > 1, count <= capacity.partialValue,
              let sequence = dataSet.privateElement(group: 0x0065, creator: unitedImagingCreator,
                                                    privateElement: 0x51)?.sequenceItems,
              sequence.count == count else { return nil }
        let positions = sequence.compactMap { item -> SIMD3<Double>? in
            let values = item.dataSet.decimalStrings(for: 0x0020_0032)
            return values.count == 3 ? SIMD3(values[0], values[1], values[2]) : nil
        }
        guard positions.count == count else { return nil }
        let tilesPerRow = Int(Double(count).squareRoot().rounded(.up))
        let tilesPerColumn = (count + tilesPerRow - 1) / tilesPerRow
        let tileColumns = columns / tilesPerRow, tileRows = rows / tilesPerColumn
        guard tileColumns > 0, tileRows > 0 else { return nil }
        return DicomTiledSliceLayout(kind: .unitedImagingGrid, tilesPerRow: tilesPerRow, tileColumns: tileColumns,
                                     tileRows: tileRows, tilePositions: positions, rowDirection: x, columnDirection: y)
    }

    private static func decimalString(_ data: Data?) -> Double? {
        data.flatMap { String(data: $0, encoding: .ascii) }
            .flatMap { Double($0.trimmingCharacters(in: CharacterSet(charactersIn: " \0"))) }
    }
}
