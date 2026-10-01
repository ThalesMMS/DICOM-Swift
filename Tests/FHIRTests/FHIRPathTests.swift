import Foundation
import XCTest
@testable import FHIR

final class FHIRPathTests: XCTestCase {
    private let evaluator = FHIRPathEvaluator()

    func test_requiredFunctionArguments_throwOnMissingInput() throws {
        let patient = try FHIRFixtures.resource("patient-example")
        for base in ["name", "{}"] {
            for function in ["all", "where", "select", "repeat"] {
                XCTAssertThrowsError(try evaluator.evaluate("\(base).\(function)()", on: patient)) {
                    XCTAssertEqual($0 as? FHIRPathError, .syntax("missing argument for \(function)"))
                }
            }
        }
    }

    private func strings(_ expression: String, on resource: FHIRResource) throws -> [String] {
        try evaluator.evaluate(expression, on: resource).compactMap(\.stringValue)
    }
    private func bool(_ expression: String, on resource: FHIRResource) throws -> Bool? {
        let result = try evaluator.evaluate(expression, on: resource)
        guard result.count == 1, case .boolean(let flag) = result[0].primitive else { return nil }
        return flag
    }

    func test_navigation_indexingChoicesAndTypes() throws {
        let patient = try FHIRFixtures.resource("patient-example")
        XCTAssertEqual(try strings("Patient.name.given", on: patient), ["Peter", "James", "Jim", "Peter", "James"])
        XCTAssertEqual(try strings("name[0].family", on: patient), ["Chalmers"])
        XCTAssertEqual(try strings("name.where(use = 'official').family", on: patient), ["Chalmers"])
        XCTAssertEqual(try strings("name.where(use = 'maiden').given.first()", on: patient), ["Peter"])
        XCTAssertEqual(try bool("deceased is Boolean", on: patient), true)
        XCTAssertEqual(try bool("deceased.exists() and deceased = false", on: patient), true)
        XCTAssertEqual(try strings("birthDate.extension('http://hl7.org/fhir/StructureDefinition/patient-birthTime').value", on: patient), ["1974-12-25T14:35:45-05:00"])
        XCTAssertEqual(try strings("telecom.where(system = 'phone' and use = 'work').value", on: patient), ["(03) 5555 6473"])
        let observation = try FHIRFixtures.resource("observation-example")
        XCTAssertEqual(try strings("value.value", on: observation), ["185"])
        XCTAssertEqual(try bool("value is Quantity", on: observation), true)
        XCTAssertEqual(try bool("value.ofType(Quantity).exists()", on: observation), true)
        XCTAssertEqual(try strings("value.as(Quantity).unit", on: observation), ["lbs"])
        XCTAssertEqual(try bool("effective is dateTime", on: observation), true)
        XCTAssertEqual(try strings("code.coding.where(system = 'http://loinc.org').code", on: observation), ["29463-7", "3141-9"])
        XCTAssertEqual(try strings("code.coding.select(system & '|' & code).first()", on: observation), ["http://loinc.org|29463-7"])
        XCTAssertEqual(try evaluator.evaluate("%resource.id", on: observation).first?.stringValue, "example")
        XCTAssertEqual(try evaluator.evaluate("$this.id", on: observation).first?.stringValue, "example")
    }

    func test_collectionsStringsAndArithmetic() throws {
        let patient = try FHIRFixtures.resource("patient-example")
        XCTAssertEqual(try evaluator.evaluate("name.count()", on: patient).first?.primitive, .integer(3))
        XCTAssertEqual(try evaluator.evaluate("name.given.distinct().count()", on: patient).first?.primitive, .integer(3))
        XCTAssertEqual(try bool("name.given.isDistinct()", on: patient), false)
        XCTAssertEqual(try bool("name.exists(use = 'usual')", on: patient), true)
        XCTAssertEqual(try bool("name.all(family.exists())", on: patient), false, "the usual name has no family")
        XCTAssertEqual(try bool("name.all(given.exists())", on: patient), true)
        XCTAssertEqual(try strings("name.given.skip(1).take(2)", on: patient), ["James", "Jim"])
        XCTAssertEqual(try strings("name.given.tail().last()", on: patient), ["James"])
        XCTAssertEqual(try bool("('Peter' | 'James').subsetOf(name.given)", on: patient), true)
        XCTAssertEqual(try bool("name.given.supersetOf('Jim')", on: patient), true)
        XCTAssertEqual(try bool("'Jim' in name.given", on: patient), true)
        XCTAssertEqual(try bool("name.given contains 'Zed'", on: patient), false)
        XCTAssertEqual(try strings("name.family.first().substring(0, 4).upper()", on: patient), ["CHAL"])
        XCTAssertEqual(try bool("name.family.first().startsWith('Cha') and name.family.first().endsWith('ers')", on: patient), true)
        XCTAssertEqual(try bool("id.matches('^[a-z]+$')", on: patient), true)
        XCTAssertEqual(try strings("name.given.first().replace('e', 'E')", on: patient), ["PEtEr"])
        XCTAssertEqual(try evaluator.evaluate("name.family.first().length()", on: patient).first?.primitive, .integer(8))
        XCTAssertEqual(try evaluator.evaluate("(1 + 2) * 3 - 4 / 2", on: patient).first?.decimalValue, Decimal(7))
        XCTAssertEqual(try evaluator.evaluate("7 div 2", on: patient).first?.primitive, .integer(3))
        XCTAssertEqual(try evaluator.evaluate("7 mod 2", on: patient).first?.primitive, .integer(1))
        XCTAssertEqual(try evaluator.evaluate("(-3.5).abs()", on: patient).first?.decimalValue, Decimal(string: "3.5"))
        XCTAssertEqual(try evaluator.evaluate("-3.5.abs()", on: patient).first?.decimalValue, Decimal(string: "-3.5"), "invocation binds tighter than unary minus")
        XCTAssertEqual(try evaluator.evaluate("2.5.round()", on: patient).first?.decimalValue, Decimal(3))
        XCTAssertEqual(try evaluator.evaluate("'12'.toInteger() + 1", on: patient).first?.primitive, .integer(13))
        XCTAssertEqual(try bool("'abc' ~ 'ABC '", on: patient), true)
        XCTAssertEqual(try bool("iif(name.exists(), 'yes', 'no') = 'yes'", on: patient), true)
        XCTAssertEqual(try strings("name.given.join(',')", on: patient), ["Peter,James,Jim,Peter,James"])
        XCTAssertEqual(try bool("{}.empty()", on: patient), true)
        XCTAssertEqual(try bool("1 < 2 and 2 <= 2 and 3 > 2 and 3 >= 3 and 1 != 2", on: patient), true)
        XCTAssertEqual(try bool("true xor false", on: patient), true)
        XCTAssertEqual(try bool("false implies true", on: patient), true)
        XCTAssertEqual(try evaluator.evaluate("descendants().count() > 20", on: patient).first?.primitive, .boolean(true))
        let expectedChildren = patient.json.pairs.filter { $0.key != "resourceType" && !$0.key.hasPrefix("_") }.reduce(0) { $0 + ($1.value.array?.count ?? 1) }
        XCTAssertEqual(try evaluator.evaluate("children().count()", on: patient).first?.primitive, .integer(expectedChildren))
    }

    func test_dateComparisonAndEmptyPropagation() throws {
        let patient = try FHIRFixtures.resource("patient-example")
        XCTAssertEqual(try bool("birthDate < @2000-01-01", on: patient), true)
        XCTAssertEqual(try bool("birthDate = @1974-12-25", on: patient), true)
        XCTAssertNil(try bool("birthDate = @1974-12", on: patient), "different precision is indeterminate")
        XCTAssertEqual(try bool("@2020-01-01T10:00:00Z = @2020-01-01T12:00:00+02:00", on: patient), true)
        XCTAssertEqual(try bool("@T10:00:00 < @T11:00:00", on: patient), true)
        XCTAssertEqual(try bool("5 'mg' = 5 'mg'", on: patient), true)
        XCTAssertNil(try bool("5 'mg' = 5 'g'", on: patient), "different units are not comparable")
        XCTAssertTrue(try evaluator.evaluate("nothing.here", on: patient).isEmpty)
        XCTAssertTrue(try evaluator.evaluate("nothing.here = 1", on: patient).isEmpty)
        XCTAssertEqual(try bool("nothing.here.exists() or true", on: patient), true)
        XCTAssertTrue(try evaluator.evaluate("nothing.here and true", on: patient).isEmpty)
        XCTAssertEqual(try bool("nothing.here and false", on: patient), false)
        XCTAssertEqual(try bool("nothing.here.empty()", on: patient), true)
        XCTAssertEqual(try bool("name.given.hasValue()", on: patient), false, "collections have no single value")
        XCTAssertEqual(try bool("name[0].hasValue()", on: patient), false, "objects have no value")
        XCTAssertEqual(try bool("id.hasValue()", on: patient), true)
    }

    func test_unsupportedConstructs_throwInsteadOfSilentEmpty() throws {
        let patient = try FHIRFixtures.resource("patient-example")
        XCTAssertThrowsError(try evaluator.evaluate("managingOrganization.resolve()", on: patient)) { XCTAssertEqual($0 as? FHIRPathError, .unsupportedFunction("resolve")) }
        XCTAssertThrowsError(try evaluator.evaluate("gender.memberOf('http://x')", on: patient)) { XCTAssertEqual($0 as? FHIRPathError, .unsupportedFunction("memberOf")) }
        XCTAssertThrowsError(try evaluator.evaluate("name.given = ", on: patient))
        XCTAssertThrowsError(try evaluator.evaluate("name.given[", on: patient))
        XCTAssertThrowsError(try evaluator.evaluate("name.family + name.given", on: patient)) { XCTAssertEqual($0 as? FHIRPathError, .singletonRequired("+")) }
        XCTAssertThrowsError(try evaluator.evaluate("%unknownVariable", on: patient))
        let bounded = FHIRPathEvaluator(maxEvaluationSteps: 20)
        XCTAssertThrowsError(try bounded.evaluate("descendants().descendants().count()", on: patient)) { XCTAssertEqual($0 as? FHIRPathError, .limitExceeded) }
        XCTAssertTrue(FHIRPathEvaluator.supportedFunctions.contains("where"))
        XCTAssertTrue(FHIRPathEvaluator.unsupportedFunctions.contains("memberOf"))
    }
}

/// Agreement with fhirpathpy on the official corpus for the supported subset.
final class FHIRPathOracleTests: XCTestCase {
    static let expressions = [
        "id", "name.given", "name.where(use = 'official').family", "name.count()", "telecom.count()", "birthDate",
        "identifier.system", "active", "gender = 'male'", "name.exists(use = 'nickname')", "name.given.distinct()",
        "deceased.exists()", "name.given.first() & ' ' & name.family.first()", "contact.name.family", "meta.versionId",
        "code.coding.code", "code.coding.where(system = 'http://loinc.org').display", "value.unit", "status = 'final'",
        "component.count()", "component.value.value", "effective.exists()", "subject.reference", "text.status",
        "series.count()", "series.instance.uid", "numberOfInstances >= 1", "entry.count()", "entry.resource.id", "type",
        "entry.request.method", "total", "identifier.value.first().length()", "(1 + 1) = 2", "'a' < 'b'"
    ]

    func test_expressions_matchFhirpathpyOnCorpus() throws {
        let interpreter = try FHIROracleServer.interpreter()
        let documents = try FHIRFixtures.official.map { ["id": $0, "base64": try FHIRFixtures.data($0).base64EncodedString()] }
        let request = try JSONSerialization.data(withJSONObject: ["role": "fhirpath", "documents": documents, "expressions": Self.expressions])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: interpreter)
        process.arguments = [FHIROracleServer.script().path]
        let data = try FHIROracleExecution.run(process, request: request)
        let oracle = try FHIRJSONParser().parseObject(data)
        guard oracle["ready"]?.bool == true else { throw XCTSkip("fhirpathpy unavailable") }
        let evaluator = FHIRPathEvaluator()
        var compared = 0
        for document in oracle["documents"]?.array ?? [] {
            guard let object = document.object, let name = object["id"]?.string, let results = object["results"]?.object else { continue }
            let resource = try FHIRFixtures.resource(name)
            for expression in Self.expressions {
                guard let verdict = results[expression]?.object else { continue }
                if verdict["error"] != nil { continue }
                let expected = FHIRFixtures.canonical(verdict["value"] ?? .array([]))
                let ours = try evaluator.evaluate(expression, on: resource).map(\.json)
                let normalized = FHIRFixtures.canonical(.array(ours.map(Self.normalizeNumber)))
                let expectedNormalized = FHIRFixtures.canonical(.array((expected.array ?? []).map(Self.normalizeNumber)))
                XCTAssertEqual(normalized, expectedNormalized, name + " :: " + expression)
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 300)
    }

    /// fhirpathpy returns floats for integers in some paths; compare numerically.
    static func normalizeNumber(_ value: FHIRJSON) -> FHIRJSON {
        switch value {
        case .number(let number):
            if let decimal = number.decimalValue { return .string("n:" + "\(decimal)") }
            return value
        case .object(let object):
            var result = FHIRJSONObject()
            for (key, item) in object.pairs { result[key] = normalizeNumber(item) }
            return .object(result)
        case .array(let items): return .array(items.map(normalizeNumber))
        default: return value
        }
    }
}
