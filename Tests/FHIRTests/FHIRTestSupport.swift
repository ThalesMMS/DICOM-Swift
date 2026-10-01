import Foundation
import HL7v3CDA
import XCTest
@testable import FHIR

enum FHIRFixtures {
    static let official = ["patient-example", "observation-example", "observation-example-bloodpressure", "diagnosticreport-example",
                           "imagingstudy-example", "documentreference-example", "bundle-example", "bundle-transaction",
                           "bundle-response", "operationoutcome-example", "patient-example-f001-pieter",
                           "observation-example-f001-glucose", "practitioner-example", "organization-example",
                           "encounter-example", "media-example", "endpoint-example"]

    static func url(_ name: String, _ ext: String, subdirectory: String = "Fixtures/official") throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: subdirectory), name + "." + ext)
    }
    static func data(_ name: String, _ ext: String = "json", subdirectory: String = "Fixtures/official") throws -> Data {
        try Data(contentsOf: url(name, ext, subdirectory: subdirectory))
    }
    static func resource(_ name: String, subdirectory: String = "Fixtures/official") throws -> FHIRResource {
        try FHIRResource(jsonData: data(name, subdirectory: subdirectory))
    }
    static func own(_ name: String) throws -> FHIRResource { try resource(name, subdirectory: "Fixtures/own") }

    /// Key-order-insensitive structural equality for trees.
    static func canonical(_ value: FHIRJSON) -> FHIRJSON {
        switch value {
        case .object(let object):
            var sorted = FHIRJSONObject()
            for key in object.keys.sorted() { sorted[key] = canonical(object[key]!) }
            return .object(sorted)
        case .array(let items): return .array(items.map(canonical))
        default: return value
        }
    }

    /// Replaces every `div` string by a parsed XHTML tree comparison surrogate (serialized canonically).
    static func normalizingNarrative(_ value: FHIRJSON) throws -> FHIRJSON {
        switch value {
        case .object(let object):
            var result = FHIRJSONObject()
            for (key, item) in object.pairs {
                if key == "div", let text = item.string {
                    let node = try SafeXMLParser().parse(Data(text.utf8))
                    result[key] = .string(String(decoding: try XMLSerializer().serialize(node), as: UTF8.self))
                } else {
                    result[key] = try normalizingNarrative(item)
                }
            }
            return .object(result)
        case .array(let items): return .array(try items.map(normalizingNarrative))
        default: return value
        }
    }

    static func assertEquivalent(_ lhs: FHIRJSON, _ rhs: FHIRJSON, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let left = canonical(try normalizingNarrative(lhs))
        let right = canonical(try normalizingNarrative(rhs))
        if left != right {
            let leftText = String(decoding: FHIRJSONWriter(pretty: true).write(left), as: UTF8.self)
            let rightText = String(decoding: FHIRJSONWriter(pretty: true).write(right), as: UTF8.self)
            let difference = zip(leftText.split(separator: "\n"), rightText.split(separator: "\n")).first { $0 != $1 }
            XCTFail(message + " differs at: " + (difference.map { "\($0.0) | \($0.1)" } ?? "length"), file: file, line: line)
        }
    }
}
