import Foundation

/// A FHIRPath item: element trees keep their JSON and a type hint from the element table.
public indirect enum FHIRPathValue: Equatable, Sendable {
    case empty
    case boolean(Bool)
    case string(String)
    case integer(Int)
    case decimal(String)
    case date(String)
    case dateTime(String)
    case time(String)
    case quantity(String, String)
    /// A JSON element (object or primitive) with its FHIR type name when known and, for primitives,
    /// the `_name` companion carrying id/extensions.
    case element(FHIRJSON, type: String?, companion: FHIRJSONObject? = nil)

    var isEmpty: Bool { if case .empty = self { return true } else { return false } }

    /// Primitive view of element values (`"x"` -> string, number -> integer/decimal).
    var primitive: FHIRPathValue {
        guard case .element(let json, let type, _) = self else { return self }
        switch json {
        case .string(let text):
            switch type {
            case "date": return .date(text)
            case "dateTime", "instant": return .dateTime(text)
            case "time": return .time(text)
            default: return .string(text)
            }
        case .number(let number): return number.isInteger && type != "decimal" ? .integer(number.intValue ?? 0) : .decimal(number.lexical)
        case .bool(let flag): return .boolean(flag)
        case .object(let object):
            if let value = object["value"]?.number, type == "Quantity" || object["unit"] != nil || object["code"] != nil {
                return .quantity(value.lexical, object["code"]?.string ?? object["unit"]?.string ?? "")
            }
            return self
        default: return self
        }
    }

    var decimalValue: Decimal? {
        switch primitive {
        case .integer(let value): return Decimal(value)
        case .decimal(let text), .quantity(let text, _): return Decimal(string: text, locale: nil)
        default: return nil
        }
    }

    var stringValue: String? {
        switch primitive {
        case .string(let text), .date(let text), .dateTime(let text), .time(let text): return text
        case .integer(let value): return String(value)
        case .decimal(let text): return text
        case .boolean(let flag): return flag ? "true" : "false"
        case .quantity(let value, let unit): return value + " '" + unit + "'"
        default: return nil
        }
    }

    var typeName: String {
        switch primitive {
        case .empty: return "empty"
        case .boolean: return "Boolean"
        case .string: return "String"
        case .integer: return "Integer"
        case .decimal: return "Decimal"
        case .date: return "Date"
        case .dateTime: return "DateTime"
        case .time: return "Time"
        case .quantity: return "Quantity"
        case .element(let json, let type, _):
            if let type { return type }
            if case .object(let object) = json, let resourceType = object["resourceType"]?.string { return resourceType }
            return "Element"
        }
    }

    /// JSON representation used by tests and the CLI (primitives become JSON primitives).
    public var json: FHIRJSON {
        switch self {
        case .empty: return .null
        case .boolean(let flag): return .bool(flag)
        case .string(let text), .date(let text), .dateTime(let text), .time(let text): return .string(text)
        case .integer(let value): return .number(FHIRNumber(value))
        case .decimal(let text): return .number(FHIRNumber(lexical: text))
        case .quantity(let value, let unit): return ["value": .number(FHIRNumber(lexical: value)), "unit": .string(unit)]
        case .element(let json, _, _): return json
        }
    }
}

/// FHIRPath evaluator over the lossless JSON tree. Supported (see the QA document for the
/// exhaustive list): path navigation with choice resolution, indexers, `$this`, `%resource`,
/// `%context`, boolean/comparison/arithmetic/string operators with precision-aware date
/// comparison, `is`/`as`/`ofType`, and the collection/string/conversion functions listed in
/// `supportedFunctions`. Unsupported constructs throw explicitly instead of returning empty.
public struct FHIRPathEvaluator: Sendable {
    public static let supportedFunctions: [String] = [
        "empty", "exists", "all", "allTrue", "anyTrue", "allFalse", "anyFalse", "count", "first", "last", "tail", "skip", "take",
        "single", "where", "select", "distinct", "isDistinct", "union", "combine", "intersect", "exclude", "subsetOf", "supersetOf",
        "not", "iif", "hasValue", "ofType", "as", "is", "extension", "children", "descendants", "repeat", "trace",
        "startsWith", "endsWith", "contains", "matches", "replace", "replaceMatches", "length", "upper", "lower", "indexOf",
        "substring", "split", "join", "toString", "toInteger", "toDecimal", "toBoolean", "toQuantity", "toDateTime", "toDate",
        "convertsToInteger", "convertsToDecimal", "convertsToBoolean", "convertsToString", "convertsToDateTime", "convertsToDate",
        "today", "now", "abs", "ceiling", "floor", "round", "sqrt", "truncate"
    ]
    public static let unsupportedFunctions: [String] = ["memberOf", "conformsTo", "aggregate", "encode", "decode", "escape", "unescape", "htmlChecks", "resolve"]

    public var schema: FHIRSchema
    public var maxEvaluationSteps: Int

    public init(schema: FHIRSchema = .r4, maxEvaluationSteps: Int = 200_000) {
        self.schema = schema
        self.maxEvaluationSteps = maxEvaluationSteps
    }

    public func evaluate(_ expression: String, on resource: FHIRResource) throws -> [FHIRPathValue] {
        let root = FHIRPathValue.element(.object(resource.json), type: resource.resourceType)
        return try evaluate(expression, context: [root], resource: root)
    }

    public func evaluate(_ expression: String, context: [FHIRPathValue], resource: FHIRPathValue) throws -> [FHIRPathValue] {
        let node = try FHIRPathParser.parse(expression)
        let state = State(resource: resource, budget: maxEvaluationSteps)
        return try eval(node, context: context, state: state)
    }

    /// Boolean outcome as invariants use it: empty is treated as true only when `emptyIsTrue`.
    public func evaluateBoolean(_ expression: String, on resource: FHIRResource, emptyIsTrue: Bool = true) throws -> Bool {
        let result = try evaluate(expression, on: resource)
        guard !result.isEmpty else { return emptyIsTrue }
        if result.count == 1, case .boolean(let flag) = result[0].primitive { return flag }
        return true
    }

    final class State {
        let resource: FHIRPathValue
        var budget: Int
        init(resource: FHIRPathValue, budget: Int) {
            self.resource = resource
            self.budget = budget
        }
        func step() throws {
            budget -= 1
            if budget < 0 { throw FHIRPathError.limitExceeded }
        }
    }

    // MARK: evaluation

    private func eval(_ node: FHIRPathNode, context: [FHIRPathValue], state: State) throws -> [FHIRPathValue] {
        try state.step()
        switch node {
        case .literal(let value): return value.isEmpty ? [] : [value]
        case .this: return context
        case .variable(let name):
            switch name {
            case "resource", "rootResource": return [state.resource]
            case "context": return context
            default: throw FHIRPathError.unsupportedOperator("%" + name)
            }
        case .member(let target, let name):
            let base = try target.map { try eval($0, context: context, state: state) } ?? context
            if target == nil, let first = base.first, first.typeName == name, base.count == 1 { return base }
            return try base.flatMap { try children(of: $0, named: name) }
        case .index(let target, let indexNode):
            let base = try eval(target, context: context, state: state)
            let index = try eval(indexNode, context: context, state: state)
            guard index.count == 1, case .integer(let position) = index[0].primitive else { return [] }
            return base.indices.contains(position) ? [base[position]] : []
        case .unary(let op, let operand):
            let values = try eval(operand, context: context, state: state)
            guard values.count == 1, op == "-" else { throw FHIRPathError.unsupportedOperator(op) }
            switch values[0].primitive {
            case .integer(let value): return [.integer(-value)]
            case .decimal(let text): return [.decimal(text.hasPrefix("-") ? String(text.dropFirst()) : "-" + text)]
            case .quantity(let value, let unit): return [.quantity(value.hasPrefix("-") ? String(value.dropFirst()) : "-" + value, unit)]
            default: throw FHIRPathError.typeMismatch("unary minus")
            }
        case .binary(let op, let left, let right):
            return try binary(op, left, right, context: context, state: state)
        case .typeOperation(let op, let target, let type):
            let values = try eval(target, context: context, state: state)
            if op == "is" {
                guard values.count <= 1 else { throw FHIRPathError.singletonRequired("is") }
                return values.isEmpty ? [] : [.boolean(matchesType(values[0], type))]
            }
            return values.filter { matchesType($0, type) }
        case .function(let target, let name, let arguments):
            let base = try target.map { try eval($0, context: context, state: state) } ?? context
            return try function(name, base: base, arguments: arguments, context: context, state: state)
        }
    }

    private func children(of value: FHIRPathValue, named name: String) throws -> [FHIRPathValue] {
        guard case .element(let json, let type, let companion) = value else { return [] }
        guard case .object(let object) = json else {
            // Primitive with a companion: `id` and `extension` live in `_name`.
            guard let companion else { return [] }
            if name == "id", let id = companion["id"] { return [.element(id, type: "string")] }
            if name == "extension", let extensions = companion["extension"]?.array { return extensions.map { .element($0, type: "Extension") } }
            return []
        }
        let typeName = type ?? object["resourceType"]?.string
        let info = typeName.flatMap { schema.type($0) }
        func wrap(_ items: [FHIRJSON], elementType: String?, key: String) -> [FHIRPathValue] {
            let companions = object["_" + key]
            return items.enumerated().map { index, item in
                let companion = (companions?.array.map { $0.indices.contains(index) ? $0[index] : .null } ?? companions)?.object
                return .element(item, type: elementType, companion: companion)
            }
        }
        if let element = info?.element(named: name), let raw = object[name] {
            return wrap(raw.array ?? [raw], elementType: element.type, key: name)
        }
        if let raw = object[name] {
            return wrap(raw.array ?? [raw], elementType: nil, key: name)
        }
        // Choice element: `value` resolves valueQuantity / valueString ...
        let candidates = info?.elements.filter { $0.choiceGroup == name } ?? []
        for candidate in candidates { if let raw = object[candidate.name] { return wrap(raw.array ?? [raw], elementType: candidate.type, key: candidate.name) } }
        if candidates.isEmpty {
            for key in object.keys where key.hasPrefix(name) && key.count > name.count && key.dropFirst(name.count).first?.isUppercase == true {
                let suffix = String(key.dropFirst(name.count))
                let lower = suffix.prefix(1).lowercased() + suffix.dropFirst()
                let elementType = FHIRPrimitiveType(rawValue: lower) != nil ? lower : suffix
                return wrap(object[key]!.array ?? [object[key]!], elementType: elementType, key: key)
            }
        }
        return []
    }

    func matchesType(_ value: FHIRPathValue, _ type: String) -> Bool {
        let name = value.typeName
        if name == type { return true }
        let lower = type.prefix(1).lowercased() + type.dropFirst()
        if name.lowercased() == lower.lowercased() { return true }
        switch (value.primitive, type) {
        case (.integer, "Decimal"), (.integer, "decimal"): return true
        case (.element(let json, let elementType, _), _):
            if case .object(let object) = json {
                if let resourceType = object["resourceType"]?.string, resourceType == type { return true }
                if type == "Resource" || type == "DomainResource" { return object["resourceType"] != nil }
                if type == "Element" || type == "BackboneElement" { return true }
            }
            return elementType.map { $0 == type || $0.lowercased() == lower.lowercased() } ?? false
        default: return false
        }
    }

    // MARK: operators

    private func binary(_ op: String, _ leftNode: FHIRPathNode, _ rightNode: FHIRPathNode, context: [FHIRPathValue], state: State) throws -> [FHIRPathValue] {
        if op == "and" || op == "or" || op == "xor" || op == "implies" {
            let left = try boolean(try eval(leftNode, context: context, state: state))
            let right = try boolean(try eval(rightNode, context: context, state: state))
            switch op {
            case "and":
                if left == false || right == false { return [.boolean(false)] }
                if left == true && right == true { return [.boolean(true)] }
                return []
            case "or":
                if left == true || right == true { return [.boolean(true)] }
                if left == false && right == false { return [.boolean(false)] }
                return []
            case "xor":
                guard let left, let right else { return [] }
                return [.boolean(left != right)]
            default:
                if left == false { return [.boolean(true)] }
                if left == true { return right.map { [.boolean($0)] } ?? [] }
                return right == true ? [.boolean(true)] : []
            }
        }
        let left = try eval(leftNode, context: context, state: state)
        let right = try eval(rightNode, context: context, state: state)
        switch op {
        case "|": return left + right.filter { item in !left.contains { equal($0, item) == true } }
        case "in":
            guard left.count <= 1 else { throw FHIRPathError.singletonRequired("in") }
            guard let item = left.first else { return [] }
            return [.boolean(right.contains { equal($0, item) == true })]
        case "contains":
            guard right.count <= 1 else { throw FHIRPathError.singletonRequired("contains") }
            guard let item = right.first else { return [] }
            return [.boolean(left.contains { equal($0, item) == true })]
        case "=", "!=":
            guard !left.isEmpty, !right.isEmpty else { return [] }
            guard left.count == right.count else { return [.boolean(op == "!=")] }
            var result = true
            for (a, b) in zip(left, right) {
                guard let same = equal(a, b) else { return [] }
                if !same { result = false; break }
            }
            return [.boolean(op == "=" ? result : !result)]
        case "~", "!~":
            guard !left.isEmpty, !right.isEmpty else { return [] }
            let same = left.count == right.count && zip(left, right).allSatisfy { equivalent($0, $1) }
            return [.boolean(op == "~" ? same : !same)]
        case "<", "<=", ">", ">=":
            guard left.count <= 1, right.count <= 1 else { throw FHIRPathError.singletonRequired(op) }
            guard let a = left.first, let b = right.first, let comparison = compare(a, b) else { return [] }
            switch (op, comparison) {
            case ("<", .less), ("<=", .less), ("<=", .equal), (">", .greater), (">=", .greater), (">=", .equal): return [.boolean(true)]
            case (_, .indeterminate): return []
            default: return [.boolean(false)]
            }
        case "+", "-", "*", "/", "div", "mod", "&":
            guard left.count <= 1, right.count <= 1 else { throw FHIRPathError.singletonRequired(op) }
            if op == "&" { return [.string((left.first?.stringValue ?? "") + (right.first?.stringValue ?? ""))] }
            guard let a = left.first, let b = right.first else { return [] }
            if op == "+", case .string(let x) = a.primitive, case .string(let y) = b.primitive { return [.string(x + y)] }
            guard let x = a.decimalValue, let y = b.decimalValue else { throw FHIRPathError.typeMismatch(op) }
            let integers: Bool = { if case .integer = a.primitive, case .integer = b.primitive { return true } else { return false } }()
            let result: Decimal
            switch op {
            case "+": result = x + y
            case "-": result = x - y
            case "*": result = x * y
            case "/":
                guard y != 0 else { return [] }
                result = x / y
            case "div":
                guard y != 0 else { return [] }
                var quotient = x / y
                var rounded = Decimal()
                NSDecimalRound(&rounded, &quotient, 0, quotient < 0 ? .up : .down)
                return [.integer(NSDecimalNumber(decimal: rounded).intValue)]
            default:
                guard y != 0 else { return [] }
                var quotient = x / y
                var rounded = Decimal()
                NSDecimalRound(&rounded, &quotient, 0, quotient < 0 ? .up : .down)
                result = x - rounded * y
            }
            if integers, op != "/" { return [.integer(NSDecimalNumber(decimal: result).intValue)] }
            return [.decimal("\(result)")]
        default: throw FHIRPathError.unsupportedOperator(op)
        }
    }

    private func boolean(_ values: [FHIRPathValue]) throws -> Bool? {
        guard !values.isEmpty else { return nil }
        guard values.count == 1 else { throw FHIRPathError.singletonRequired("boolean") }
        if case .boolean(let flag) = values[0].primitive { return flag }
        return true
    }

    func equal(_ a: FHIRPathValue, _ b: FHIRPathValue) -> Bool? {
        switch (a.primitive, b.primitive) {
        case (.element(let x, _, _), .element(let y, _, _)): return canonical(x) == canonical(y)
        case (.date(let x), .date(let y)), (.dateTime(let x), .dateTime(let y)), (.date(let x), .dateTime(let y)), (.dateTime(let x), .date(let y)):
            guard let left = FHIRDateTime(x), let right = FHIRDateTime(y) else { return x == y }
            switch left.compare(right) {
            case .equal: return true
            case .indeterminate: return nil
            default: return false
            }
        case (.time(let x), .time(let y)): return x == y
        case (.quantity(let v1, let u1), .quantity(let v2, let u2)):
            guard u1 == u2 else { return nil }
            return Decimal(string: v1) == Decimal(string: v2)
        case (.boolean(let x), .boolean(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        default:
            if let x = a.decimalValue, let y = b.decimalValue, a.stringValue != nil, b.stringValue != nil,
               [a.typeName, b.typeName].allSatisfy({ $0 == "Integer" || $0 == "Decimal" }) { return x == y }
            return a.primitive == b.primitive
        }
    }

    private func equivalent(_ a: FHIRPathValue, _ b: FHIRPathValue) -> Bool {
        switch (a.primitive, b.primitive) {
        case (.string(let x), .string(let y)):
            let normalize: (String) -> String = { $0.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
            return normalize(x) == normalize(y)
        default: return equal(a, b) ?? false
        }
    }

    private func compare(_ a: FHIRPathValue, _ b: FHIRPathValue) -> FHIRComparison? {
        switch (a.primitive, b.primitive) {
        case (.string(let x), .string(let y)): return x == y ? .equal : (x < y ? .less : .greater)
        case (.date(let x), .date(let y)), (.dateTime(let x), .dateTime(let y)), (.date(let x), .dateTime(let y)), (.dateTime(let x), .date(let y)):
            guard let left = FHIRDateTime(x), let right = FHIRDateTime(y) else { return nil }
            return left.compare(right)
        case (.time(let x), .time(let y)): return x == y ? .equal : (x < y ? .less : .greater)
        case (.quantity(_, let u1), .quantity(_, let u2)) where u1 != u2: return .indeterminate
        default:
            guard let x = a.decimalValue, let y = b.decimalValue else { return nil }
            return x == y ? .equal : (x < y ? .less : .greater)
        }
    }

    private func canonical(_ value: FHIRJSON) -> FHIRJSON {
        switch value {
        case .object(let object):
            var sorted = FHIRJSONObject()
            for key in object.keys.sorted() { sorted[key] = canonical(object[key]!) }
            return .object(sorted)
        case .array(let items): return .array(items.map(canonical))
        default: return value
        }
    }

    // MARK: functions

    private func function(_ name: String, base: [FHIRPathValue], arguments: [FHIRPathNode], context: [FHIRPathValue], state: State) throws -> [FHIRPathValue] {
        func argument(_ index: Int, in evaluationContext: [FHIRPathValue]? = nil) throws -> [FHIRPathValue] {
            guard arguments.indices.contains(index) else { throw FHIRPathError.syntax("missing argument for \(name)") }
            return try eval(arguments[index], context: evaluationContext ?? context, state: state)
        }
        func singleString(_ index: Int) throws -> String? { try argument(index).first?.stringValue }
        func singleInteger(_ index: Int) throws -> Int? {
            guard case .integer(let value)? = try argument(index).first?.primitive else { return nil }
            return value
        }
        func criteria(_ item: FHIRPathValue, _ index: Int) throws -> Bool {
            let result = try argument(index, in: [item])
            return try boolean(result) == true
        }
        if arguments.isEmpty && ["all", "where", "select", "repeat"].contains(name) { _ = try argument(0) }
        switch name {
        case "empty": return [.boolean(base.isEmpty)]
        case "exists":
            if arguments.isEmpty { return [.boolean(!base.isEmpty)] }
            return [.boolean(try base.contains { try criteria($0, 0) })]
        case "all": return [.boolean(try base.allSatisfy { try criteria($0, 0) })]
        case "allTrue": return [.boolean(base.allSatisfy { $0.primitive == .boolean(true) })]
        case "anyTrue": return [.boolean(base.contains { $0.primitive == .boolean(true) })]
        case "allFalse": return [.boolean(base.allSatisfy { $0.primitive == .boolean(false) })]
        case "anyFalse": return [.boolean(base.contains { $0.primitive == .boolean(false) })]
        case "count": return [.integer(base.count)]
        case "first": return base.first.map { [$0] } ?? []
        case "last": return base.last.map { [$0] } ?? []
        case "tail": return Array(base.dropFirst())
        case "skip": return Array(base.dropFirst(max(0, try singleInteger(0) ?? 0)))
        case "take": return Array(base.prefix(max(0, try singleInteger(0) ?? 0)))
        case "single":
            guard base.count <= 1 else { throw FHIRPathError.singletonRequired("single") }
            return base
        case "where": return try base.filter { try criteria($0, 0) }
        case "select": return try base.flatMap { try argument(0, in: [$0]) }
        case "repeat":
            var results: [FHIRPathValue] = []
            var frontier = base
            while !frontier.isEmpty {
                try state.step()
                let next = try frontier.flatMap { try argument(0, in: [$0]) }
                    .filter { item in !results.contains { equal($0, item) == true } }
                results += next
                frontier = next
            }
            return results
        case "distinct":
            var result: [FHIRPathValue] = []
            for item in base where !result.contains(where: { equal($0, item) == true }) { result.append(item) }
            return result
        case "isDistinct":
            var seen: [FHIRPathValue] = []
            for item in base {
                if seen.contains(where: { equal($0, item) == true }) { return [.boolean(false)] }
                seen.append(item)
            }
            return [.boolean(true)]
        case "union": return unionValues(base, try argument(0))
        case "combine": return base + (try argument(0))
        case "intersect": let other = try argument(0); return base.filter { item in other.contains { equal($0, item) == true } }
        case "exclude": let other = try argument(0); return base.filter { item in !other.contains { equal($0, item) == true } }
        case "subsetOf": let other = try argument(0); return [.boolean(base.allSatisfy { item in other.contains { equal($0, item) == true } })]
        case "supersetOf": let other = try argument(0); return [.boolean(other.allSatisfy { item in base.contains { equal($0, item) == true } })]
        case "not":
            guard let flag = try boolean(base) else { return [] }
            return [.boolean(!flag)]
        case "iif":
            let condition = try boolean(try argument(0))
            if condition == true { return try argument(1) }
            return arguments.count > 2 ? try argument(2) : []
        case "hasValue":
            guard base.count == 1 else { return [.boolean(false)] }
            if case .element(let json, _, _) = base[0], case .object = json { return [.boolean(false)] }
            return [.boolean(!base[0].isEmpty)]
        case "ofType":
            guard case .member(nil, let type) = arguments.first ?? .this else { throw FHIRPathError.syntax("ofType needs a type") }
            return base.filter { matchesType($0, type) }
        case "as":
            guard case .member(nil, let type) = arguments.first ?? .this else { throw FHIRPathError.syntax("as needs a type") }
            return base.filter { matchesType($0, type) }
        case "is":
            guard case .member(nil, let type) = arguments.first ?? .this, base.count <= 1 else { throw FHIRPathError.syntax("is needs a type") }
            return base.isEmpty ? [] : [.boolean(matchesType(base[0], type))]
        case "extension":
            let url = try singleString(0)
            return try base.flatMap { try children(of: $0, named: "extension") }.filter { item in
                guard case .element(let json, _, _) = item else { return false }
                return json["url"]?.string == url
            }
        case "children": return base.flatMap(childrenOf)
        case "descendants":
            var results: [FHIRPathValue] = []
            var frontier = base.flatMap(childrenOf)
            while !frontier.isEmpty {
                for _ in frontier { try state.step() }
                results += frontier
                frontier = frontier.flatMap(childrenOf)
            }
            return results
        case "trace": return base
        case "startsWith", "endsWith", "contains", "matches", "indexOf":
            guard base.count <= 1 else { throw FHIRPathError.singletonRequired(name) }
            guard let text = base.first?.stringValue, let parameter = try singleString(0) else { return [] }
            switch name {
            case "startsWith": return [.boolean(text.hasPrefix(parameter))]
            case "endsWith": return [.boolean(text.hasSuffix(parameter))]
            case "contains": return [.boolean(parameter.isEmpty || text.contains(parameter))]
            case "indexOf": return [.integer(text.range(of: parameter).map { text.distance(from: text.startIndex, to: $0.lowerBound) } ?? -1)]
            default:
                guard let regex = try? NSRegularExpression(pattern: parameter) else { throw FHIRPathError.syntax("regex") }
                return [.boolean(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil)]
            }
        case "replace":
            guard let text = base.first?.stringValue, let pattern = try singleString(0), let replacement = try singleString(1) else { return [] }
            return [.string(text.replacingOccurrences(of: pattern, with: replacement))]
        case "replaceMatches":
            guard let text = base.first?.stringValue, let pattern = try singleString(0), let replacement = try singleString(1),
                  let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            return [.string(regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement))]
        case "length": return base.first?.stringValue.map { [.integer($0.count)] } ?? []
        case "upper": return base.first?.stringValue.map { [.string($0.uppercased())] } ?? []
        case "lower": return base.first?.stringValue.map { [.string($0.lowercased())] } ?? []
        case "substring":
            guard let text = base.first?.stringValue, let start = try singleInteger(0), start >= 0, start < text.count else { return [] }
            let length = arguments.count > 1 ? (try singleInteger(1) ?? text.count) : text.count
            let from = text.index(text.startIndex, offsetBy: start)
            let to = text.index(from, offsetBy: min(max(0, length), text.count - start))
            return [.string(String(text[from..<to]))]
        case "split":
            guard let text = base.first?.stringValue, let separator = try singleString(0) else { return [] }
            return text.components(separatedBy: separator).map { .string($0) }
        case "join":
            let separator = arguments.isEmpty ? "" : (try singleString(0) ?? "")
            return [.string(base.compactMap(\.stringValue).joined(separator: separator))]
        case "toString": return base.first?.stringValue.map { [.string($0)] } ?? []
        case "toInteger":
            guard let first = base.first else { return [] }
            if case .integer = first.primitive { return [first.primitive] }
            if let text = first.stringValue, let value = Int(text) { return [.integer(value)] }
            if case .boolean(let flag) = first.primitive { return [.integer(flag ? 1 : 0)] }
            return []
        case "toDecimal": return base.first?.decimalValue.map { [.decimal("\($0)")] } ?? []
        case "toBoolean":
            guard let first = base.first else { return [] }
            if case .boolean = first.primitive { return [first.primitive] }
            switch first.stringValue?.lowercased() {
            case "true", "t", "yes", "y", "1", "1.0": return [.boolean(true)]
            case "false", "f", "no", "n", "0", "0.0": return [.boolean(false)]
            default: return []
            }
        case "toQuantity":
            guard let first = base.first else { return [] }
            if case .quantity = first.primitive { return [first.primitive] }
            return first.decimalValue.map { [.quantity("\($0)", "1")] } ?? []
        case "toDateTime": return base.first?.stringValue.flatMap { FHIRDateTime($0) != nil ? [.dateTime($0)] : nil } ?? []
        case "toDate": return base.first?.stringValue.flatMap { FHIRDate($0) != nil ? [.date($0)] : nil } ?? []
        case "convertsToInteger": return [.boolean(base.first.flatMap { $0.stringValue }.flatMap(Int.init) != nil)]
        case "convertsToDecimal": return [.boolean(base.first?.decimalValue != nil)]
        case "convertsToBoolean": return [.boolean(!(try function("toBoolean", base: base, arguments: [], context: context, state: state)).isEmpty)]
        case "convertsToString": return [.boolean(base.first?.stringValue != nil)]
        case "convertsToDateTime": return [.boolean(base.first?.stringValue.flatMap(FHIRDateTime.init) != nil)]
        case "convertsToDate": return [.boolean(base.first?.stringValue.flatMap(FHIRDate.init) != nil)]
        case "today":
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate]
            return [.date(formatter.string(from: Date()))]
        case "now":
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime]
            return [.dateTime(formatter.string(from: Date()))]
        case "abs", "ceiling", "floor", "round", "sqrt", "truncate":
            guard base.count == 1, let value = base[0].decimalValue else { return [] }
            let double = NSDecimalNumber(decimal: value).doubleValue
            switch name {
            case "abs": return [.decimal("\(abs(value))")]
            case "ceiling": return [.integer(Int(ceil(double)))]
            case "floor": return [.integer(Int(floor(double)))]
            case "truncate": return [.integer(Int(double.rounded(.towardZero)))]
            case "sqrt": return double < 0 ? [] : [.decimal("\(Decimal(sqrt(double)))")]
            default:
                let precision = arguments.isEmpty ? 0 : (try singleInteger(0) ?? 0)
                var rounded = Decimal()
                var source = value
                NSDecimalRound(&rounded, &source, precision, .plain)
                return [.decimal("\(rounded)")]
            }
        case "resolve": throw FHIRPathError.unsupportedFunction("resolve")
        default:
            throw FHIRPathError.unsupportedFunction(name)
        }
    }

    private func unionValues(_ a: [FHIRPathValue], _ b: [FHIRPathValue]) -> [FHIRPathValue] {
        var result: [FHIRPathValue] = []
        for item in a + b where !result.contains(where: { equal($0, item) == true }) { result.append(item) }
        return result
    }

    private func childrenOf(_ value: FHIRPathValue) -> [FHIRPathValue] {
        guard case .element(let json, let type, _) = value, case .object(let object) = json else { return [] }
        let info = (type ?? object["resourceType"]?.string).flatMap { schema.type($0) }
        return object.pairs.filter { $0.key != "resourceType" && !$0.key.hasPrefix("_") }.flatMap { pair -> [FHIRPathValue] in
            let elementType = info?.element(named: pair.key)?.type
            return (pair.value.array ?? [pair.value]).map { .element($0, type: elementType) }
        }
    }
}
