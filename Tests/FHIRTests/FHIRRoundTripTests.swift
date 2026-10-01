import Foundation
import HL7v3CDA
import XCTest
@testable import FHIR

final class FHIRRoundTripTests: XCTestCase {
    func test_officialJSON_parseWriteParseIsLossless() throws {
        for name in FHIRFixtures.official {
            let data = try FHIRFixtures.data(name)
            let resource = try FHIRResource(jsonData: data)
            let rewritten = try FHIRResource(jsonData: resource.jsonData())
            XCTAssertEqual(rewritten.json, resource.json, name)
            XCTAssertEqual(rewritten.json.keys, resource.json.keys, name + " key order")
            let pretty = try FHIRResource(jsonData: resource.jsonData(pretty: true))
            XCTAssertEqual(pretty.json, resource.json, name)
            XCTAssertFalse(resource.resourceType.isEmpty)
        }
    }

    func test_officialXML_convertsToTheSameTreeAsJSON() throws {
        for name in FHIRFixtures.official {
            let fromJSON = try FHIRFixtures.resource(name)
            let fromXML = try FHIRResource(xmlData: try FHIRFixtures.data(name, "xml"))
            try FHIRFixtures.assertEquivalent(.object(fromXML.json), .object(fromJSON.json), name + " xml->json")
        }
    }

    func test_officialJSON_toXMLAndBackIsEquivalent() throws {
        for name in FHIRFixtures.official {
            let resource = try FHIRFixtures.resource(name)
            let xml = try resource.xmlData()
            let back = try FHIRResource(xmlData: xml)
            try FHIRFixtures.assertEquivalent(.object(back.json), .object(resource.json), name + " json->xml->json")
            let text = String(decoding: xml, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("<" + resource.resourceType + " xmlns=\"http://hl7.org/fhir\""), name)
        }
    }

    func test_ownFixtures_primitiveExtensionsChoicesContainedRoundTrip() throws {
        for name in ["primitive-extensions", "choice-and-decimals", "contained-and-references"] {
            let resource = try FHIRFixtures.own(name)
            let viaXML = try FHIRResource(xmlData: try resource.xmlData(indentation: 2))
            try FHIRFixtures.assertEquivalent(.object(viaXML.json), .object(resource.json), name)
            XCTAssertEqual(try FHIRResource(jsonData: viaXML.jsonData()).json, viaXML.json, name)
        }
        let patient = try XCTUnwrap(FHIRFixtures.own("primitive-extensions").as(FHIRPatient.self))
        let name = try XCTUnwrap(patient.names.first)
        XCTAssertEqual(name.given, ["Alpha", "Beta"])
        XCTAssertEqual(name.primitiveExtension("family")?["id"]?.string, "fam1")
        XCTAssertEqual(name.json["_given"]?[0]?.isNull, true)
        XCTAssertEqual(name.json["_given"]?[1]?["id"]?.string, "g2")
        XCTAssertEqual(patient.primitiveExtension("gender")?["extension"]?[0]?["valueCode"]?.string, "asked-unknown")
        XCTAssertEqual(patient.multipleBirth?.typeName, "integer")
        XCTAssertEqual(patient.multipleBirth?.number?.intValue, 2)
        let xml = String(decoding: try patient.resource.xmlData(), as: UTF8.self)
        XCTAssertTrue(xml.contains("<family id=\"fam1\" value=\"Synthetic\"><extension url=\"http://hl7.org/fhir/StructureDefinition/humanname-own-name\"><valueString value=\"Synthetic\"/></extension></family>"), xml)
        XCTAssertTrue(xml.contains("<given value=\"Alpha\"/><given id=\"g2\" value=\"Beta\">"), xml)
        XCTAssertTrue(xml.contains("<multipleBirthInteger value=\"2\"/>"), xml)
    }

    func test_decimalsAndChoices_surviveXML() throws {
        let observation = try XCTUnwrap(FHIRFixtures.own("choice-and-decimals").as(FHIRObservation.self))
        XCTAssertEqual(observation.valueQuantity?.value?.lexical, "70.10")
        XCTAssertEqual(observation.components[0].valueQuantity?.value?.lexical, "1.0E-3")
        XCTAssertEqual(observation.components[1].value?.typeName, "integer")
        XCTAssertEqual(observation.components[2].value?.bool, false)
        XCTAssertEqual(observation.effective?.typeName, "dateTime")
        XCTAssertEqual(observation.effective.flatMap { $0.string }.flatMap(FHIRDateTime.init)?.time?.fraction, "250")
        let xml = String(decoding: try observation.resource.xmlData(), as: UTF8.self)
        XCTAssertTrue(xml.contains("<value value=\"70.10\"/>"))
        XCTAssertTrue(xml.contains("<valueInteger value=\"12\"/>"))
        XCTAssertTrue(xml.contains("<valueBoolean value=\"false\"/>"))
        let back = try XCTUnwrap(FHIRResource(xmlData: Data(xml.utf8)).as(FHIRObservation.self))
        XCTAssertEqual(back.valueQuantity?.value?.lexical, "70.10")
        XCTAssertEqual(back.components[1].json["valueInteger"]?.number?.lexical, "12")
        XCTAssertEqual(back.components[2].json["valueBoolean"]?.bool, false)
    }

    func test_extensionOnlyPrimitives_preserveCompanionsAndArrayPositions() throws {
        let json = #"{"resourceType":"Patient","_birthDate":{"extension":[{"url":"http://hl7.org/fhir/StructureDefinition/data-absent-reason","valueCode":"unknown"}]},"name":[{"given":["Ana",null,"Maria"],"_given":[null,{"extension":[{"url":"urn:test:missing","valueBoolean":true}]},null]}]}"#
        let resource = try FHIRResource(jsonData: Data(json.utf8))
        let xml = #"<Patient xmlns="http://hl7.org/fhir"><name><given value="Ana"/><given><extension url="urn:test:missing"><valueBoolean value="true"/></extension></given><given value="Maria"/></name><birthDate><extension url="http://hl7.org/fhir/StructureDefinition/data-absent-reason"><valueCode value="unknown"/></extension></birthDate></Patient>"#
        let parsed = try FHIRResource(xmlData: Data(xml.utf8))
        XCTAssertNil(parsed.json["birthDate"])
        XCTAssertEqual(parsed.json["_birthDate"], resource.json["_birthDate"])
        XCTAssertEqual(parsed.json["name"], resource.json["name"])
        let roundTrip = try FHIRResource(xmlData: resource.xmlData())
        XCTAssertEqual(roundTrip.json["_birthDate"], resource.json["_birthDate"])
        XCTAssertEqual(roundTrip.json["name"], resource.json["name"])

        let companionOnly = try FHIRResource(jsonData: Data(#"{"resourceType":"Patient","name":[{"_given":[{"id":"g1","extension":[{"url":"urn:test:missing","valueBoolean":true}]}]}]}"#.utf8))
        let arrayRoundTrip = try FHIRResource(xmlData: companionOnly.xmlData())
        XCTAssertEqual(arrayRoundTrip.json["name"]?[0]?["_given"], companionOnly.json["name"]?[0]?["_given"])
        XCTAssertEqual(arrayRoundTrip.json["name"]?[0]?["given"]?[0]?.isNull, true)
    }

    func test_malformedBooleanAndNumericXML_primitivesAreRejected() throws {
        for element in [#"<active value="TRUE"/>"#, #"<active value="yes"/>"#,
                        #"<multipleBirthInteger value="1.5"/>"#, #"<multipleBirthInteger value="NaN"/>"#,
                        #"<multipleBirthInteger value="2147483648"/>"#] {
            let xml = "<Patient xmlns=\"http://hl7.org/fhir\">" + element + "</Patient>"
            XCTAssertThrowsError(try FHIRResource(xmlData: Data(xml.utf8)), element) {
                guard case FHIRXMLError.malformed = $0 else { return XCTFail("\($0)") }
            }
        }
        let valid = try FHIRResource(xmlData: Data(#"<Patient xmlns="http://hl7.org/fhir"><active value="false"/><multipleBirthInteger value="2"/></Patient>"#.utf8))
        XCTAssertEqual(valid.json["active"]?.bool, false)
        XCTAssertEqual(valid.json["multipleBirthInteger"]?.number?.intValue, 2)
    }

    func test_narrativeDiv_isCarriedAsXHTML() throws {
        let patient = try FHIRFixtures.resource("patient-example")
        let xml = String(decoding: try patient.xmlData(), as: UTF8.self)
        XCTAssertTrue(xml.contains("<div xmlns=\"http://www.w3.org/1999/xhtml\">"))
        XCTAssertFalse(xml.contains("<div value="))
        let back = try FHIRResource(xmlData: Data(xml.utf8))
        let original = try SafeXMLParser().parse(Data(try XCTUnwrap(patient.text?.div).utf8))
        let roundTripped = try SafeXMLParser().parse(Data(try XCTUnwrap(back.text?.div).utf8))
        XCTAssertEqual(original, roundTripped)
        var broken = patient
        broken.text = FHIRNarrative(status: "generated", div: "<p>not a div</p>")
        XCTAssertThrowsError(try broken.xmlData()) { XCTAssertEqual($0 as? FHIRXMLError, .invalidNarrative) }
    }

    func test_maliciousXML_isRefusedBeforeExpansion() throws {
        for name in ["entity-expansion", "external-entity"] {
            XCTAssertThrowsError(try FHIRResource(xmlData: try FHIRFixtures.data(name, "xml", subdirectory: "Fixtures/malicious")), name) {
                XCTAssertEqual($0 as? CDAError, .forbiddenDTD, name)
            }
        }
        XCTAssertThrowsError(try FHIRResource(xmlData: Data("<patient xmlns=\"http://hl7.org/fhir\"/>".utf8))) {
            XCTAssertEqual($0 as? FHIRXMLError, .notAResource)
        }
        XCTAssertThrowsError(try FHIRResource(xmlData: Data("<Patient/>".utf8))) { XCTAssertEqual($0 as? FHIRXMLError, .notAResource) }
        var limits = FHIRLimits(); limits.maxDepth = 3
        XCTAssertThrowsError(try FHIRResource(xmlData: Data("<Patient xmlns=\"http://hl7.org/fhir\"><name><period><start value=\"2020\"/></period></name></Patient>".utf8), limits: limits))
        XCTAssertThrowsError(try FHIRXMLConverter(allowUnknownElements: false).resource(fromXML: Data("<Patient xmlns=\"http://hl7.org/fhir\"><bogus value=\"1\"/></Patient>".utf8))) {
            XCTAssertEqual($0 as? FHIRXMLError, .unrepresentable(path: "Patient.bogus"))
        }
        let lenient = try FHIRXMLConverter().resource(fromXML: Data("<Patient xmlns=\"http://hl7.org/fhir\"><bogus value=\"1\"/><bogus value=\"2\"/></Patient>".utf8))
        XCTAssertEqual(lenient["bogus"]?.array?.count, 2, "unknown repeated elements stay arrays of strings")
    }
}
