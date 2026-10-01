import Foundation

public enum HL7Optionality: String, Codable, Sendable { case R, O, C, B, X }

public struct HL7FieldCondition: Codable, Equatable, Sendable {
    public var field: Int
    public var values: [String]
    public init(field: Int, values: [String]) { self.field = field; self.values = values }
}

public struct HL7FieldDefinition: Codable, Equatable, Sendable {
    public var index: Int
    public var name: String
    public var dataType: HL7DataTypeName
    public var optionality: HL7Optionality
    public var repeatable: Bool
    public var maxRepetitions: Int?
    public var length: Int?
    public var valueSetID: String?
    /// For variable fields such as OBX-5, the type is supplied by this field.
    public var dataTypeField: Int?
    public var condition: HL7FieldCondition?
    public var introducedIn: String?
    public var deprecatedIn: String?

    public init(index: Int, name: String, dataType: HL7DataTypeName, optionality: HL7Optionality = .O,
                repeatable: Bool = false, maxRepetitions: Int? = nil, length: Int? = nil,
                valueSetID: String? = nil, dataTypeField: Int? = nil, condition: HL7FieldCondition? = nil,
                introducedIn: String? = nil, deprecatedIn: String? = nil) {
        self.index = index; self.name = name; self.dataType = dataType; self.optionality = optionality
        self.repeatable = repeatable; self.maxRepetitions = maxRepetitions; self.length = length
        self.valueSetID = valueSetID; self.dataTypeField = dataTypeField; self.condition = condition
        self.introducedIn = introducedIn; self.deprecatedIn = deprecatedIn
    }
}

public struct HL7SegmentDefinition: Codable, Equatable, Sendable {
    public var name: String
    public var fields: [HL7FieldDefinition]
    public init(name: String, fields: [HL7FieldDefinition]) { self.name = name; self.fields = fields }
    public subscript(index: Int) -> HL7FieldDefinition? { fields.first { $0.index == index } }
}
