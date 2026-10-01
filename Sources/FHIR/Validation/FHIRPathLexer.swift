import Foundation

/// Token kinds of the FHIRPath subset grammar.
enum FHIRPathToken: Equatable {
    case identifier(String)
    case string(String)
    case number(String)
    case dateTime(String)   // @2020-01-01T00:00:00Z / @2020 / @T10:00
    case boolean(Bool)
    case symbol(String)     // ( ) [ ] . , | & + - * / = != ~ !~ < <= > >= { }
    case variable(String)   // %resource, %context
    case end
}

public enum FHIRPathError: Error, Equatable, Sendable {
    case syntax(String)
    case unsupportedFunction(String)
    case unsupportedOperator(String)
    case typeMismatch(String)
    case singletonRequired(String)
    case limitExceeded
}

struct FHIRPathLexer {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) { scalars = Array(text.unicodeScalars) }

    mutating func tokenize() throws -> [FHIRPathToken] {
        var tokens: [FHIRPathToken] = []
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { index += 1; continue }
            if scalar == "'" { tokens.append(.string(try string())); continue }
            if scalar == "`" { tokens.append(.identifier(try quotedIdentifier())); continue }
            if scalar == "@" { tokens.append(.dateTime(dateTimeLiteral())); continue }
            if scalar == "%" { index += 1; tokens.append(.variable(identifier())); continue }
            if scalar.properties.numericType != nil && scalar.value < 128 { tokens.append(.number(number())); continue }
            if scalar == "_" || scalar == "$" || (scalar.value < 128 && Character(scalar).isLetter) {
                let word = identifier()
                switch word {
                case "true": tokens.append(.boolean(true))
                case "false": tokens.append(.boolean(false))
                default: tokens.append(.identifier(word))
                }
                continue
            }
            let two = index + 1 < scalars.count ? String(scalar) + String(scalars[index + 1]) : ""
            if ["<=", ">=", "!=", "!~"].contains(two) { tokens.append(.symbol(two)); index += 2; continue }
            if "()[].,|&+-*/=~<>{}".unicodeScalars.contains(scalar) { tokens.append(.symbol(String(scalar))); index += 1; continue }
            throw FHIRPathError.syntax("unexpected character at \(index)")
        }
        tokens.append(.end)
        return tokens
    }

    private mutating func string() throws -> String {
        index += 1
        var output = ""
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar == "'" { return output }
            if scalar == "\\" {
                guard index < scalars.count else { break }
                let escaped = scalars[index]
                index += 1
                switch escaped {
                case "n": output += "\n"
                case "t": output += "\t"
                case "r": output += "\r"
                case "'": output += "'"
                case "\"": output += "\""
                case "`": output += "`"
                case "\\": output += "\\"
                case "/": output += "/"
                case "f": output += "\u{0C}"
                case "u":
                    let hex = String(String.UnicodeScalarView(scalars[index..<min(index + 4, scalars.count)]))
                    guard hex.count == 4, let value = UInt32(hex, radix: 16), let unicode = Unicode.Scalar(value) else {
                        throw FHIRPathError.syntax("bad unicode escape")
                    }
                    index += 4
                    output.unicodeScalars.append(unicode)
                default: throw FHIRPathError.syntax("bad escape")
                }
                continue
            }
            output.unicodeScalars.append(scalar)
        }
        throw FHIRPathError.syntax("unterminated string")
    }

    private mutating func quotedIdentifier() throws -> String {
        index += 1
        var output = ""
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar == "`" { return output }
            output.unicodeScalars.append(scalar)
        }
        throw FHIRPathError.syntax("unterminated identifier")
    }

    private mutating func identifier() -> String {
        var output = ""
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "_" || (scalar == "$" && output.isEmpty) || (scalar.value < 128 && (Character(scalar).isLetter || Character(scalar).isNumber)) else { break }
            output.unicodeScalars.append(scalar)
            index += 1
        }
        return output
    }

    private mutating func number() -> String {
        var output = ""
        while index < scalars.count {
            let scalar = scalars[index]
            guard (scalar.value < 128 && Character(scalar).isNumber) || (scalar == "." && index + 1 < scalars.count && scalars[index + 1].value < 128 && Character(scalars[index + 1]).isNumber && !output.contains(".")) else { break }
            output.unicodeScalars.append(scalar)
            index += 1
        }
        return output
    }

    private mutating func dateTimeLiteral() -> String {
        index += 1
        var output = ""
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "-" || scalar == ":" || scalar == "T" || scalar == "Z" || scalar == "+" || scalar == "." ||
                (scalar.value < 128 && Character(scalar).isNumber) else { break }
            output.unicodeScalars.append(scalar)
            index += 1
        }
        return output
    }
}

/// Abstract syntax of the subset.
indirect enum FHIRPathNode: Equatable {
    case literal(FHIRPathValue)
    case this
    case variable(String)
    case member(FHIRPathNode?, String)              // expr.name (nil = context)
    case function(FHIRPathNode?, String, [FHIRPathNode])
    case index(FHIRPathNode, FHIRPathNode)
    case unary(String, FHIRPathNode)
    case binary(String, FHIRPathNode, FHIRPathNode)
    case typeOperation(String, FHIRPathNode, String) // is / as
}

/// Recursive-descent parser following the FHIRPath precedence table.
struct FHIRPathParser {
    private var tokens: [FHIRPathToken]
    private var position = 0

    init(_ expression: String) throws {
        var lexer = FHIRPathLexer(expression)
        tokens = try lexer.tokenize()
    }

    static func parse(_ expression: String) throws -> FHIRPathNode {
        var parser = try FHIRPathParser(expression)
        let node = try parser.expression()
        guard parser.peek == .end else { throw FHIRPathError.syntax("trailing tokens") }
        return node
    }

    private var peek: FHIRPathToken { tokens[position] }
    private mutating func advance() -> FHIRPathToken { defer { position += 1 }; return tokens[position] }
    private mutating func expect(_ symbol: String) throws {
        guard case .symbol(symbol) = advance() else { throw FHIRPathError.syntax("expected \(symbol)") }
    }
    private func isSymbol(_ symbol: String) -> Bool { if case .symbol(symbol) = peek { return true } else { return false } }
    private func isIdentifier(_ word: String) -> Bool { if case .identifier(word) = peek { return true } else { return false } }

    // implies < or/xor < and < in/contains < equality < comparison < union | < additive < multiplicative < unary < type < path
    mutating func expression() throws -> FHIRPathNode { try implies() }

    private mutating func implies() throws -> FHIRPathNode {
        var left = try orExpression()
        while isIdentifier("implies") { _ = advance(); left = .binary("implies", left, try orExpression()) }
        return left
    }
    private mutating func orExpression() throws -> FHIRPathNode {
        var left = try andExpression()
        while isIdentifier("or") || isIdentifier("xor") {
            guard case .identifier(let op) = advance() else { break }
            left = .binary(op, left, try andExpression())
        }
        return left
    }
    private mutating func andExpression() throws -> FHIRPathNode {
        var left = try membership()
        while isIdentifier("and") { _ = advance(); left = .binary("and", left, try membership()) }
        return left
    }
    private mutating func membership() throws -> FHIRPathNode {
        var left = try equality()
        while isIdentifier("in") || isIdentifier("contains") {
            guard case .identifier(let op) = advance() else { break }
            left = .binary(op, left, try equality())
        }
        return left
    }
    private mutating func equality() throws -> FHIRPathNode {
        var left = try comparison()
        while isSymbol("=") || isSymbol("!=") || isSymbol("~") || isSymbol("!~") {
            guard case .symbol(let op) = advance() else { break }
            left = .binary(op, left, try comparison())
        }
        return left
    }
    private mutating func comparison() throws -> FHIRPathNode {
        var left = try union()
        while isSymbol("<") || isSymbol("<=") || isSymbol(">") || isSymbol(">=") {
            guard case .symbol(let op) = advance() else { break }
            left = .binary(op, left, try union())
        }
        return left
    }
    private mutating func union() throws -> FHIRPathNode {
        var left = try additive()
        while isSymbol("|") { _ = advance(); left = .binary("|", left, try additive()) }
        return left
    }
    private mutating func additive() throws -> FHIRPathNode {
        var left = try multiplicative()
        while isSymbol("+") || isSymbol("-") || isSymbol("&") {
            guard case .symbol(let op) = advance() else { break }
            left = .binary(op, left, try multiplicative())
        }
        return left
    }
    private mutating func multiplicative() throws -> FHIRPathNode {
        var left = try unary()
        while isSymbol("*") || isSymbol("/") || isIdentifier("div") || isIdentifier("mod") {
            let op: String
            switch advance() {
            case .symbol(let symbol): op = symbol
            case .identifier(let word): op = word
            default: throw FHIRPathError.syntax("operator")
            }
            left = .binary(op, left, try unary())
        }
        return left
    }
    private mutating func unary() throws -> FHIRPathNode {
        if isSymbol("-") { _ = advance(); return .unary("-", try unary()) }
        if isSymbol("+") { _ = advance(); return try unary() }
        return try typeExpression()
    }
    private mutating func typeExpression() throws -> FHIRPathNode {
        var left = try invocation()
        while isIdentifier("is") || isIdentifier("as") {
            guard case .identifier(let op) = advance(), case .identifier(let type) = advance() else { throw FHIRPathError.syntax("type name") }
            var qualified = type
            if isSymbol(".") { _ = advance(); guard case .identifier(let name) = advance() else { throw FHIRPathError.syntax("type name") }; qualified = name }
            left = .typeOperation(op, left, qualified)
        }
        return left
    }
    private mutating func invocation() throws -> FHIRPathNode {
        var node = try term()
        while true {
            if isSymbol(".") {
                _ = advance()
                node = try memberOrFunction(on: node)
            } else if isSymbol("[") {
                _ = advance()
                let index = try expression()
                try expect("]")
                node = .index(node, index)
            } else { break }
        }
        return node
    }
    private mutating func memberOrFunction(on target: FHIRPathNode?) throws -> FHIRPathNode {
        guard case .identifier(let name) = advance() else { throw FHIRPathError.syntax("member name") }
        if isSymbol("(") {
            _ = advance()
            var arguments: [FHIRPathNode] = []
            if !isSymbol(")") {
                arguments.append(try expression())
                while isSymbol(",") { _ = advance(); arguments.append(try expression()) }
            }
            try expect(")")
            return .function(target, name, arguments)
        }
        return .member(target, name)
    }
    private mutating func term() throws -> FHIRPathNode {
        switch peek {
        case .string(let text): _ = advance(); return .literal(.string(text))
        case .number(let text):
            _ = advance()
            if case .string(let unit) = peek { _ = advance(); return .literal(.quantity(text, unit)) }
            if case .identifier(let word) = peek, ["year", "years", "month", "months", "day", "days", "hour", "hours", "minute", "minutes", "second", "seconds", "millisecond", "milliseconds"].contains(word) {
                _ = advance(); return .literal(.quantity(text, word))
            }
            return .literal(text.contains(".") ? .decimal(text) : .integer(Int(text) ?? 0))
        case .boolean(let flag): _ = advance(); return .literal(.boolean(flag))
        case .dateTime(let text): _ = advance(); return .literal(text.hasPrefix("T") ? .time(String(text.dropFirst())) : .dateTime(text))
        case .variable(let name): _ = advance(); return .variable(name)
        case .symbol("("):
            _ = advance()
            let inner = try expression()
            try expect(")")
            return inner
        case .symbol("{"):
            _ = advance(); try expect("}")
            return .literal(.empty)
        case .identifier("$this"), .identifier("$"):
            _ = advance(); return .this
        case .identifier:
            return try memberOrFunction(on: nil)
        default: throw FHIRPathError.syntax("unexpected token")
        }
    }
}
