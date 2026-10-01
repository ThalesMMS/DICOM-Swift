import HL7v2

extension MLLPFrame {
    public func decodeHL7(options: HL7ParserOptions = .init()) throws -> HL7Message {
        try HL7Parser(options: options).parse(payload)
    }
}
