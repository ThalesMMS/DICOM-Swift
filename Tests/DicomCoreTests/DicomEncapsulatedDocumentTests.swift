import XCTest
@testable import DicomCore

final class DicomEncapsulatedDocumentTests: XCTestCase {
    func testEncapsulatedPDFRoundTripsMetadataPayloadAndSourceReferences() throws {
        let payload = Data("%PDF-1.4\n".utf8)
        let concept = DicomCodedConcept(
            codeValue: "18748-4",
            codingSchemeDesignator: "LN",
            codeMeaning: "Diagnostic Imaging Report"
        )
        let source = DicomEncapsulatedDocumentSourceInstance(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.9203"
        )
        let options = DicomEncapsulatedDocumentBuildOptions(
            kind: .pdf,
            sopInstanceUID: "2.25.9200",
            studyInstanceUID: "2.25.9201",
            seriesInstanceUID: "2.25.9202",
            patientName: "Document^Patient",
            patientID: "DOC-1",
            studyID: "DOC-STUDY",
            studyDate: "20260528",
            studyTime: "140000",
            seriesNumber: 9,
            instanceNumber: 4,
            seriesDate: "20260528",
            seriesTime: "140100",
            contentDate: "20260528",
            contentTime: "140200",
            documentTitle: "Consult Report",
            conceptName: concept,
            sourceInstances: [source]
        )

        let decoder = try open(documentData: payload, options: options)
        let document = try XCTUnwrap(decoder.encapsulatedDocument)

        XCTAssertEqual(document.kind, .pdf)
        XCTAssertEqual(document.sopClassUID, DicomEncapsulatedDocument.encapsulatedPDFStorageSOPClassUID)
        XCTAssertEqual(document.sopInstanceUID, "2.25.9200")
        XCTAssertEqual(document.studyInstanceUID, "2.25.9201")
        XCTAssertEqual(document.seriesInstanceUID, "2.25.9202")
        XCTAssertEqual(document.modality, "DOC")
        XCTAssertEqual(document.patientName?.familyName, "Document")
        XCTAssertEqual(document.patientName?.givenName, "Patient")
        XCTAssertEqual(document.patientID, "DOC-1")
        XCTAssertEqual(document.documentTitle, "Consult Report")
        XCTAssertEqual(document.conceptName, concept)
        XCTAssertEqual(document.mimeType, "application/pdf")
        XCTAssertEqual(document.documentData, payload)
        XCTAssertEqual(document.encapsulatedDocumentLength, payload.count)
        XCTAssertEqual(document.sourceInstances, [source])
        XCTAssertEqual(document.preferredFileExtension, "pdf")

        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("encapsulated_pdf_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        try document.writeDocument(to: exportURL)
        XCTAssertEqual(try Data(contentsOf: exportURL), payload)
    }

    func testCDAAndSTLKindsRoundTripWithDefaultMIMEAndExtension() throws {
        let cases: [(DicomEncapsulatedDocumentKind, Data, String, String)] = [
            (.cda, Data("<ClinicalDocument/>".utf8), "text/xml", "xml"),
            (.stl, Data("solid mesh\nendsolid mesh\n".utf8), "model/stl", "stl")
        ]

        for (kind, payload, mimeType, fileExtension) in cases {
            let decoder = try open(
                documentData: payload,
                options: DicomEncapsulatedDocumentBuildOptions(
                    kind: kind,
                    sopInstanceUID: "2.25.\(90000 + payload.count)",
                    studyInstanceUID: "2.25.9211",
                    seriesInstanceUID: "2.25.9212",
                    documentTitle: "\(kind) document"
                )
            )
            let document = try XCTUnwrap(decoder.encapsulatedDocument)

            XCTAssertEqual(document.kind, kind)
            XCTAssertEqual(document.mimeType, mimeType)
            XCTAssertEqual(document.documentData, payload)
            XCTAssertEqual(document.preferredFileExtension, fileExtension)
            XCTAssertEqual(document.modality, kind == .stl ? "M3D" : "DOC")
        }
    }

    func testSTLRoundTripsFrameOfReferenceAndScaleUnits() throws {
        let units = DicomCodedConcept(
            codeValue: "mm",
            codingSchemeDesignator: "UCUM",
            codeMeaning: "mm"
        )
        let decoder = try open(
            documentData: Data(repeating: 0, count: 84),
            options: DicomEncapsulatedDocumentBuildOptions(
                kind: .stl,
                sopInstanceUID: "2.25.92130",
                frameOfReferenceUID: "2.25.92131",
                measurementUnits: units
            )
        )

        let document = try XCTUnwrap(decoder.encapsulatedDocument)
        XCTAssertEqual(document.frameOfReferenceUID, "2.25.92131")
        XCTAssertEqual(document.measurementUnits, units)
        XCTAssertEqual(document.modality, "M3D")
    }

    func testBuilderCanPreserveSourceDecoderClinicalContext() throws {
        let sourceDecoder = try open(dataSet: sourceImageDataSet())
        let options = DicomEncapsulatedDocumentBuildOptions.preservingClinicalContext(
            from: sourceDecoder,
            kind: .pdf,
            documentTitle: "Attached PDF",
            sopInstanceUID: "2.25.9300"
        )

        let decoder = try open(documentData: Data("%PDF context".utf8), options: options)
        let document = try XCTUnwrap(decoder.encapsulatedDocument)

        XCTAssertEqual(document.sopInstanceUID, "2.25.9300")
        XCTAssertEqual(document.studyInstanceUID, "2.25.9301")
        XCTAssertEqual(document.seriesInstanceUID, "2.25.9302")
        XCTAssertEqual(document.patientName?.familyName, "Source")
        XCTAssertEqual(document.patientID, "SRC-DOC")
        XCTAssertEqual(document.sourceInstances, [
            DicomEncapsulatedDocumentSourceInstance(
                referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
                referencedSOPInstanceUID: "2.25.9303"
            )
        ])
    }

    func testSeriesLoaderSkipsEncapsulatedDocumentAsNonImageVolumeInput() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("encapsulated_document_series_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("document.dcm")
        try DicomEncapsulatedDocumentBuilder.write(
            documentData: Data("%PDF".utf8),
            to: url,
            options: DicomEncapsulatedDocumentBuildOptions(documentTitle: "Not a volume")
        )

        XCTAssertThrowsError(try DicomSeriesLoader().loadSeries(in: directory)) { error in
            guard case DicomSeriesLoaderError.noDicomFiles = error else {
                return XCTFail("Expected noDicomFiles after skipping Encapsulated Document, got \(error)")
            }
        }
    }

    func test_fullEnvelope_roundTripsEveryAddedFieldAndPayloadHash() throws {
        let code = DicomCodedConcept(codeValue: "mm", codingSchemeDesignator: "UCUM", codeMeaning: "millimeter")
        let reference = DicomEncapsulatedDocumentSourceInstance(referencedSOPClassUID: DicomEncapsulatedDocument.encapsulatedMTLStorageSOPClassUID,
            referencedSOPInstanceUID: "2.25.23491", purposeCodes: [code], relativeURIReference: "materials/bone.mtl")
        for kind: DicomEncapsulatedDocumentKind in [.pdf, .cda, .stl, .obj, .mtl] {
            var options = DicomEncapsulatedDocumentBuildOptions(kind: kind, instanceNumber: 7,
                contentDate: "20260910", contentTime: "123456", documentTitle: "Title", conceptName: code,
                frameOfReferenceUID: "2.25.23492", sourceInstances: [reference], acquisitionDateTime: "20260910120000",
                burnedInAnnotation: "NO", manufacturer: "Manufacturer", manufacturerModelName: "Model",
                deviceSerialNumber: "Serial", softwareVersions: "1.2", hl7InstanceIdentifier: "2.25.23493^CDA")
            options.imageLaterality = "B"
            options.recognizableVisualFeatures = "YES"
            options.verificationFlag = "VERIFIED"
            options.listOfMIMETypes = ["image/jpeg", "application/pdf"]
            options.documentClassCodes = [code]
            options.referencedImages = [reference]
            options.referencedInstances = [reference]
            options.predecessorDocuments = [.init(studyInstanceUID: "2.25.23494", seriesInstanceUID: "2.25.23495", instances: [reference]),
                .init(studyInstanceUID: "2.25.23494", seriesInstanceUID: "2.25.23496", instances: [reference])]
            options.identicalDocuments = options.predecessorDocuments
            options.positionReferenceIndicator = "TABLE"
            options.manufacturing3DModel = .init(measurementUnits: code, modelModification: "YES", modelMirroring: "NO",
                usageCode: code, contentDescription: "Mesh", derivationAlgorithm: .init(name: "Synthetic", version: "1", family: code, parameters: "none"),
                modelGroupUID: "2.25.23497", recommendedDisplayCIELabValue: [1, 32768, 65535], recommendedPresentationOpacity: 0.5)
            let payload = Data([0x25, 0x50, 0x44, 0x46, 0, 0, 0])
            let document = try XCTUnwrap(open(documentData: payload, options: options).encapsulatedDocument)
            XCTAssertEqual(document.kind, kind)
            XCTAssertEqual(document.preferredFileExtension, kind.preferredFileExtension)
            XCTAssertEqual(document.mimeType, kind.defaultMIMEType)
            XCTAssertEqual(document.instanceNumber, 7)
            XCTAssertEqual(document.contentDate, options.contentDate)
            XCTAssertEqual(document.contentTime, options.contentTime)
            XCTAssertEqual(document.acquisitionDateTime, options.acquisitionDateTime)
            XCTAssertEqual(document.imageLaterality, options.imageLaterality)
            XCTAssertEqual(document.burnedInAnnotation, options.burnedInAnnotation)
            XCTAssertEqual(document.recognizableVisualFeatures, options.recognizableVisualFeatures)
            XCTAssertEqual(document.documentTitle, options.documentTitle)
            XCTAssertEqual(document.conceptName, options.conceptName)
            XCTAssertEqual(document.documentClassCodes, options.documentClassCodes)
            XCTAssertEqual(document.verificationFlag, options.verificationFlag)
            XCTAssertEqual(document.hl7InstanceIdentifier, kind == .cda ? options.hl7InstanceIdentifier : nil)
            XCTAssertEqual(document.sourceInstances, options.sourceInstances)
            XCTAssertEqual(document.referencedImages, options.referencedImages)
            XCTAssertEqual(document.referencedInstances, options.referencedInstances)
            XCTAssertEqual(document.predecessorDocuments, options.predecessorDocuments)
            XCTAssertEqual(document.identicalDocuments, options.identicalDocuments)
            XCTAssertEqual(document.listOfMIMETypes, options.listOfMIMETypes)
            XCTAssertEqual(document.manufacturing3DModel, options.manufacturing3DModel)
            XCTAssertEqual(document.frameOfReferenceUID, options.frameOfReferenceUID)
            if kind == .stl || kind == .obj {
                XCTAssertEqual(document.positionReferenceIndicator, options.positionReferenceIndicator)
            }
            if kind == .stl || kind == .obj || kind == .mtl {
                XCTAssertEqual(document.manufacturer, options.manufacturer)
                XCTAssertEqual(document.manufacturerModelName, options.manufacturerModelName)
                XCTAssertEqual(document.deviceSerialNumber, options.deviceSerialNumber)
                XCTAssertEqual(document.softwareVersions, options.softwareVersions)
            }
            XCTAssertEqual(document.declaredDocumentLength, 7)
            XCTAssertEqual(document.encodedValueLength, 8)
            XCTAssertEqual(document.documentData, payload)
            XCTAssertTrue(document.diagnostics.isEmpty)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: url) }
            try document.writeDocument(to: url)
            XCTAssertEqual(try Data(contentsOf: url), payload)
        }
    }

    func test_lengthMismatch_preservesEncodedBytesAndDiagnosesInsteadOfTruncating() throws {
        let payload = Data([1, 2, 3, 4, 0, 0])
        let base = try DicomEncapsulatedDocumentBuilder.dataSet(documentData: payload)
        for length in [0, 2, 4, 7, 100] {
            let ds = base.setting(.init(tag: 0x00420015, vr: .UL, value: .unsignedIntegers([UInt(length)])))
            let document = try XCTUnwrap(open(dataSet: ds).encapsulatedDocument)
            XCTAssertEqual(document.documentData, payload)
            XCTAssertEqual(document.diagnostics.map(\.code), [.lengthMismatch])
            XCTAssertFalse(DicomEncapsulatedDocumentEnvelopeValidator.validate(document).isValid)
        }
        let unknown = try XCTUnwrap(open(dataSet: base.removing(0x00420015)).encapsulatedDocument)
        XCTAssertEqual(unknown.documentData, payload)
        XCTAssertNil(unknown.declaredDocumentLength)
    }

    func test_declaredLengthOption_preservesMismatchAndRejectsUnencodableLength() throws {
        var options = DicomEncapsulatedDocumentBuildOptions()
        options.declaredDocumentLength = 3
        let bytes = Data([1, 2, 3, 4])
        let document = try XCTUnwrap(open(documentData: bytes, options: options).encapsulatedDocument)
        XCTAssertEqual(document.declaredDocumentLength, 3)
        XCTAssertEqual(document.documentData, bytes)
        XCTAssertEqual(document.diagnostics.map(\.code), [.lengthMismatch])
        options.declaredDocumentLength = -1
        XCTAssertThrowsError(try DicomEncapsulatedDocumentBuilder.dataSet(documentData: bytes, options: options))
    }

    func test_envelopeAndPlausibility_areSeparateOutcomes() throws {
        let garbage = try XCTUnwrap(open(documentData: Data("garbage".utf8), options: .init()).encapsulatedDocument)
        let valid = DicomEncapsulatedDocumentEnvelopeValidator.validate(garbage)
        XCTAssertTrue(valid.isValid)
        XCTAssertEqual(valid.contentPlausibility.verdict, .implausible)
        XCTAssertEqual(DicomEncapsulatedDocumentEnvelopeValidator.validate(garbage, checkContent: false).contentPlausibility.verdict, .notChecked)
        let pdf = try XCTUnwrap(open(documentData: Data("%PDF-1.4".utf8), options: .init(mimeType: "model/stl")).encapsulatedDocument)
        XCTAssertEqual(DicomEncapsulatedDocumentEnvelopeValidator.validate(pdf).diagnostics.map(\.code), [.mimeMismatch])
        let cda = try XCTUnwrap(open(documentData: Data("<ClinicalDocument/>".utf8), options: .init(kind: .cda)).encapsulatedDocument)
        XCTAssertEqual(DicomEncapsulatedDocumentEnvelopeValidator.validate(cda).diagnostics.map(\.code), [.missingHL7Identifier])
        XCTAssertEqual(DicomEncapsulatedDocumentEnvelopeValidator.validate(garbage, embeddedMIMETypes: ["image/jpeg"]).diagnostics.map(\.code), [.missingMIMEList])
        for uri in ["materials/bone.mtl", "./materials/bone.mtl"] { XCTAssertTrue(DicomEncapsulatedDocumentEnvelopeValidator.validRelativeURI(uri)) }
        for uri in ["../x", "/x", "file:///x", "a b", "a\\b", "x.exe", "%2e%2e/x"] { XCTAssertFalse(DicomEncapsulatedDocumentEnvelopeValidator.validRelativeURI(uri), uri) }
    }

    private func open(
        documentData: Data,
        options: DicomEncapsulatedDocumentBuildOptions
    ) throws -> DCMDecoder {
        let data = try DicomEncapsulatedDocumentBuilder.part10Data(documentData: documentData, options: options)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("encapsulated_document_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func open(dataSet: DicomDataSet) throws -> DCMDecoder {
        let data = try DicomDataSetWriter.part10Data(
            from: dataSet,
            options: DicomPart10WriterOptions(
                mediaStorageSOPClassUID: dataSet.string(for: .sopClassUID),
                mediaStorageSOPInstanceUID: dataSet.string(for: .sopInstanceUID)
            )
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("encapsulated_document_source_\(UUID().uuidString).dcm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try DCMDecoder(contentsOf: url)
    }

    private func sourceImageDataSet() -> DicomDataSet {
        DicomDataSet(elements: [
            string(.sopClassUID, vr: .UI, "1.2.840.10008.5.1.4.1.1.2"),
            string(.sopInstanceUID, vr: .UI, "2.25.9303"),
            string(.studyInstanceUID, vr: .UI, "2.25.9301"),
            string(.seriesInstanceUID, vr: .UI, "2.25.9302"),
            string(.patientName, vr: .PN, "Source^Document"),
            string(.patientID, vr: .LO, "SRC-DOC"),
            string(.studyID, vr: .SH, "SOURCE-DOC-STUDY"),
            string(.studyDate, vr: .DA, "20260528"),
            string(.studyTime, vr: .TM, "150000"),
            string(.seriesDate, vr: .DA, "20260528"),
            string(.seriesTime, vr: .TM, "150100"),
            string(.modality, vr: .CS, "CT"),
            us(.samplesPerPixel, 1),
            string(.photometricInterpretation, vr: .CS, "MONOCHROME2"),
            us(.rows, 1),
            us(.columns, 1),
            us(.bitsAllocated, 16),
            us(.bitsStored, 16),
            us(.highBit, 15),
            us(.pixelRepresentation, 0),
            DicomDataElement(tag: DicomTag.pixelData.rawValue, vr: .OW, value: .bytes(Data([0x2A, 0x00])))
        ])
    }

    private func string(_ tag: DicomTag, vr: DicomVR, _ value: String) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: vr, value: .strings([value]))
    }

    private func us(_ tag: DicomTag, _ value: Int) -> DicomDataElement {
        DicomDataElement(tag: tag.rawValue, vr: .US, value: .unsignedIntegers([UInt(clamping: value)]))
    }
}
