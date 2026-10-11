import Foundation

/// The value of a TABLE content item: the Tabulated Values Sequence (0040,A801) of the Table Content Macro
/// (PS3.3 C.18.10). Rows and columns are numbered from 1, and a sparse table leaves cells out.
public struct DicomSRTable: Equatable, Sendable {
    /// A Table Row or Column Definition Sequence item: the concept of one row or column, or of all of them when
    /// `number` is nil.
    public struct AxisDefinition: Equatable, Sendable {
        public let number: Int?
        public let conceptName: DicomCodedConcept?
        public let measurementUnits: DicomCodedConcept?

        public init(number: Int?, conceptName: DicomCodedConcept?, measurementUnits: DicomCodedConcept? = nil) {
            self.number = number
            self.conceptName = conceptName
            self.measurementUnits = measurementUnits
        }
    }

    public enum CellValue: Equatable, Sendable {
        case text(String)
        case numeric(Double)
        case dateTime(String)
        case code(DicomCodedConcept)
        /// The cell is another content item (C.18.10.1.3).
        case reference([Int])
        /// A numeric cell without a value, and why (Numeric Value Qualifier Code Sequence).
        case unavailable(DicomCodedConcept)
    }

    public struct Cell: Equatable, Sendable {
        public let row: Int
        public let column: Int
        public let value: CellValue
        /// The cell's own Measurement Units Code Sequence; `units(row:column:)` falls back to the definitions.
        public let measurementUnits: DicomCodedConcept?

        public init(row: Int, column: Int, value: CellValue, measurementUnits: DicomCodedConcept? = nil) {
            self.row = row
            self.column = column
            self.value = value
            self.measurementUnits = measurementUnits
        }
    }

    public let rowCount: Int
    public let columnCount: Int
    public let rowDefinitions: [AxisDefinition]
    public let columnDefinitions: [AxisDefinition]
    public let cells: [Cell]

    public init(rowCount: Int, columnCount: Int, rowDefinitions: [AxisDefinition] = [],
                columnDefinitions: [AxisDefinition] = [], cells: [Cell]) {
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.rowDefinitions = rowDefinitions
        self.columnDefinitions = columnDefinitions
        self.cells = cells
    }

    /// Reads the single item of a content item's Tabulated Values Sequence; nil when it has none.
    public init?(contentItem dataSet: DicomDataSet) {
        guard let table = dataSet.sequenceItems(for: 0x0040A801).first?.dataSet,
              let rowCount = Self.count(table, 0x0040A802), let columnCount = Self.count(table, 0x0040A803) else {
            return nil
        }
        self.rowCount = rowCount
        self.columnCount = columnCount
        rowDefinitions = Self.definitions(table.sequenceItems(for: 0x0040A806), numberTag: 0x0040A804)
        columnDefinitions = Self.definitions(table.sequenceItems(for: 0x0040A807), numberTag: 0x0040A805)
        cells = table.sequenceItems(for: 0x0040A808).flatMap { Self.cells(in: $0.dataSet) }
            .filter { (1...rowCount).contains($0.row) && (1...columnCount).contains($0.column) }
    }

    public func cell(row: Int, column: Int) -> Cell? {
        cells.first { $0.row == row && $0.column == column }
    }

    public func rowDefinition(_ row: Int) -> AxisDefinition? {
        Self.definition(rowDefinitions, row)
    }

    public func columnDefinition(_ column: Int) -> AxisDefinition? {
        Self.definition(columnDefinitions, column)
    }

    /// The units of a numeric cell: its own, else its column's, else its row's.
    public func units(row: Int, column: Int) -> DicomCodedConcept? {
        cell(row: row, column: column)?.measurementUnits ?? columnDefinition(column)?.measurementUnits
            ?? rowDefinition(row)?.measurementUnits
    }

    private static func definition(_ definitions: [AxisDefinition], _ number: Int) -> AxisDefinition? {
        definitions.first { $0.number == number } ?? (definitions.count == 1 && definitions[0].number == nil
            ? definitions[0] : nil)
    }

    private static func count(_ dataSet: DicomDataSet, _ tag: Int) -> Int? {
        guard let value = dataSet.int(for: tag), value > 0 else { return nil }
        return value
    }

    private static func definitions(_ items: [DicomSequenceItem], numberTag: Int) -> [AxisDefinition] {
        items.map { item in
            AxisDefinition(number: item.dataSet.int(for: numberTag),
                           conceptName: code(item.dataSet, 0x0040A043),
                           measurementUnits: code(item.dataSet, 0x004008EA))
        }
    }

    private static func code(_ dataSet: DicomDataSet, _ tag: Int) -> DicomCodedConcept? {
        dataSet.sequenceItems(for: tag).first.flatMap { DicomCodedConcept(dataSet: $0.dataSet) }
    }

    /// One Cell Values Sequence item: a single cell when it names both row and column, else the multi-valued cells
    /// of the row (or column) it names, in column (or row) order (C.18.10.1.2).
    private static func cells(in item: DicomDataSet) -> [Cell] {
        let row = item.int(for: 0x0040A804), column = item.int(for: 0x0040A805)
        let units = code(item, 0x004008EA)
        let values: [CellValue]
        if let reference = item.element(for: 0x0040DB73) {
            values = [.reference(numbers(reference.value).map { Int($0) })]
        } else if let qualifier = code(item, 0x0040A301) {
            values = [.unavailable(qualifier)]
        } else {
            values = cellValues(in: item)
        }
        return values.enumerated().compactMap { index, value in
            switch (row, column) {
            case let (row?, column?): index == 0 ? Cell(row: row, column: column, value: value, measurementUnits: units) : nil
            case let (row?, nil): Cell(row: row, column: index + 1, value: value, measurementUnits: units)
            case let (nil, column?): Cell(row: index + 1, column: column, value: value, measurementUnits: units)
            case (nil, nil): nil
            }
        }
    }

    private static func cellValues(in item: DicomDataSet) -> [CellValue] {
        guard let vr = item.string(for: 0x00720050)?.trimmingCharacters(in: .whitespaces).uppercased() else { return [] }
        let numericTags = ["DS": 0x00720072, "FD": 0x00720074, "FL": 0x00720076, "IS": 0x00720064, "SL": 0x0072007C,
                           "SS": 0x0072007E, "SV": 0x00720082, "UL": 0x00720078, "US": 0x0072007A, "UV": 0x00720083]
        switch vr {
        case "UC":
            return item.strings(for: 0x0072006F).map(CellValue.text)
        case "DT":
            return item.strings(for: 0x00720063).map(CellValue.dateTime)
        case "SQ":
            return item.sequenceItems(for: 0x0040A168).compactMap { DicomCodedConcept(dataSet: $0.dataSet).map(CellValue.code) }
        default:
            guard let tag = numericTags[vr], let element = item.element(for: tag) else { return [] }
            return numbers(element.value).map(CellValue.numeric)
        }
    }

    private static func numbers(_ value: DicomDataValue) -> [Double] {
        switch value {
        case .floats(let values): values
        case .signedIntegers(let values): values.map(Double.init)
        case .unsignedIntegers(let values): values.map(Double.init)
        case .strings(let values): values.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        case .empty, .bytes, .sequence: []
        }
    }
}
