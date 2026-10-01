import Foundation
import XCTest
@testable import HL7v2

func hl7Header(charset: String = "ASCII", version: String = "2.5.1") -> String {
    "MSH|" + ["^~\\&", "APP", "FAC", "RCV", "FAC", "20260911", "", "ADT^A01^ADT_A01", "CTRL", "P",
               version, "", "", "", "", "", charset].joined(separator: "|") + "\r"
}
func hl7Fixture(_ path: String) throws -> Data {
    try Data(contentsOf: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + path))
}
func hl7Fixtures(_ folder: String) -> [URL] {
    let root = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + folder)
    return (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects as! [URL])
        .filter { $0.pathExtension == "hl7" }.sorted { $0.path < $1.path }
}
func hl7LenientParser() -> HL7Parser {
    var options = HL7ParserOptions()
    options.lenientTerminators = true
    return HL7Parser(options: options)
}
