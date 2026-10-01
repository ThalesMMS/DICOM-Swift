import Foundation
import DicomCore

/// Part 10 CDA integration.  The envelope is built by the existing
/// `DicomEncapsulatedDocumentBuilder`; this type only supplies CDA-derived
/// metadata and performs the identity/envelope checks at the seam.
public enum CDAEncapsulation {
    public struct PatientModule: Equatable, Sendable, Codable {
        public var patientName: String?
        public var patientID: String?
        public var issuer: String?
        public var birthDate: String?
        public var sex: String?

        public init(patientName: String? = nil, patientID: String? = nil, issuer: String? = nil,
                    birthDate: String? = nil, sex: String? = nil) {
            self.patientName = patientName
            self.patientID = patientID
            self.issuer = issuer
            self.birthDate = birthDate
            self.sex = sex
        }

        public init(name: String?, id: String?, issuer: String? = nil,
                    birthDate: String? = nil, sex: String? = nil) {
            self.init(patientName: name, patientID: id, issuer: issuer, birthDate: birthDate, sex: sex)
        }

        public var name: String? {
            get { patientName }
            set { patientName = newValue }
        }
        public var id: String? {
            get { patientID }
            set { patientID = newValue }
        }
    }

    public struct SeriesModule: Equatable, Sendable, Codable {
        public var studyInstanceUID: String?
        public var seriesInstanceUID: String?
        public var studyID: String?
        public var seriesNumber: Int?
        public var instanceNumber: Int?
        public var studyDate: String?
        public var studyTime: String?
        public var seriesDate: String?
        public var seriesTime: String?

        public init(studyInstanceUID: String? = nil, seriesInstanceUID: String? = nil,
                    studyID: String? = nil, seriesNumber: Int? = nil, instanceNumber: Int? = nil,
                    studyDate: String? = nil, studyTime: String? = nil,
                    seriesDate: String? = nil, seriesTime: String? = nil) {
            self.studyInstanceUID = studyInstanceUID
            self.seriesInstanceUID = seriesInstanceUID
            self.studyID = studyID
            self.seriesNumber = seriesNumber
            self.instanceNumber = instanceNumber
            self.studyDate = studyDate
            self.studyTime = studyTime
            self.seriesDate = seriesDate
            self.seriesTime = seriesTime
        }
    }

    public enum Identity: String, Codable, Sendable {
        case explicit
        case fromDocument
    }

    public struct Options: Equatable, Sendable {
        public var identity: Identity
        public var allowMismatch: Bool
        public var dicom: DicomEncapsulatedDocumentBuildOptions?

        public init(identity: Identity = .explicit, allowMismatch: Bool = false,
                    dicom: DicomEncapsulatedDocumentBuildOptions? = nil) {
            self.identity = identity
            self.allowMismatch = allowMismatch
            self.dicom = dicom
        }
    }

    public struct EnvelopeInfo: Equatable, Sendable {
        public let sopClassUID: String
        public let sopInstanceUID: String?
        public let patientName: String?
        public let patientID: String?
        public let documentTitle: String?
        public let conceptName: DicomCodedConcept?
        public let mimeType: String
        public let validation: DicomEncapsulatedDocumentEnvelopeValidator.Result

        public init(sopClassUID: String, sopInstanceUID: String?, patientName: String?, patientID: String?,
                    documentTitle: String?, conceptName: DicomCodedConcept?, mimeType: String,
                    validation: DicomEncapsulatedDocumentEnvelopeValidator.Result) {
            self.sopClassUID = sopClassUID
            self.sopInstanceUID = sopInstanceUID
            self.patientName = patientName
            self.patientID = patientID
            self.documentTitle = documentTitle
            self.conceptName = conceptName
            self.mimeType = mimeType
            self.validation = validation
        }

        public init(document: DicomEncapsulatedDocument,
                    validation: DicomEncapsulatedDocumentEnvelopeValidator.Result) {
            self.init(sopClassUID: document.sopClassUID, sopInstanceUID: document.sopInstanceUID,
                      patientName: document.patientName?.rawValue, patientID: document.patientID,
                      documentTitle: document.documentTitle, conceptName: document.conceptName,
                      mimeType: document.mimeType, validation: validation)
        }
    }

    public typealias CDAEnvelopeInfo = EnvelopeInfo

    public enum Error: Swift.Error, Equatable, Sendable, LocalizedError {
        case patientModuleRequired
        case patientIdentityMismatch
        case missingDocumentIdentifier
        case invalidEnvelope([DicomEncapsulatedDocumentDiagnostic])
        case notCDA
        case invalidPart10(String)
        case invalidCDA(String)

        public var errorDescription: String? {
            switch self {
            case .patientModuleRequired: return "An explicit patient module is required for CDA encapsulation."
            case .patientIdentityMismatch: return "The supplied patient module does not match the CDA recordTarget."
            case .missingDocumentIdentifier: return "CDA document id is required for an Encapsulated CDA envelope."
            case .invalidEnvelope: return "The Encapsulated CDA envelope is invalid."
            case .notCDA: return "The DICOM payload is not an Encapsulated CDA document."
            case .invalidPart10: return "The DICOM Part 10 payload is invalid."
            case .invalidCDA: return "The encapsulated payload is not a CDA ClinicalDocument."
            }
        }
    }

    public static func export(document: ClinicalDocument,
                              patientModule: PatientModule? = nil,
                              seriesModule: SeriesModule = .init(),
                              options: Options = .init()) throws -> Data {
        let documentIdentity = patientIdentity(from: document)
        let selectedPatient: PatientModule
        switch options.identity {
        case .fromDocument:
            selectedPatient = documentIdentity ?? PatientModule()
        case .explicit:
            guard let patientModule else { throw Error.patientModuleRequired }
            selectedPatient = patientModule
            if let documentIdentity, !matches(patientModule, documentIdentity), !options.allowMismatch {
                throw Error.patientIdentityMismatch
            }
        }
        guard let identifier = document.id?.root.map({ root in
            root + (document.id?.extension.map { "^\($0)" } ?? "")
        }), !identifier.isEmpty else { throw Error.missingDocumentIdentifier }
        let payload = try CDADocumentSerializer().serialize(document)
        var build = options.dicom ?? DicomEncapsulatedDocumentBuildOptions(kind: .cda)
        build.kind = .cda
        build.mimeType = "text/xml"
        build.documentTitle = document.title?.text
        build.conceptName = concept(from: document.code)
        build.hl7InstanceIdentifier = identifier
        build.patientName = selectedPatient.patientName
        build.patientID = selectedPatient.patientID
        build.patientBirthDate = selectedPatient.birthDate
        build.patientSex = selectedPatient.sex
        build.studyInstanceUID = seriesModule.studyInstanceUID ?? build.studyInstanceUID
        build.seriesInstanceUID = seriesModule.seriesInstanceUID ?? build.seriesInstanceUID
        build.studyID = seriesModule.studyID ?? build.studyID
        build.seriesNumber = seriesModule.seriesNumber ?? build.seriesNumber
        build.instanceNumber = seriesModule.instanceNumber ?? build.instanceNumber
        build.studyDate = seriesModule.studyDate ?? build.studyDate
        build.studyTime = seriesModule.studyTime ?? build.studyTime
        build.seriesDate = seriesModule.seriesDate ?? build.seriesDate
        build.seriesTime = seriesModule.seriesTime ?? build.seriesTime
        return try DicomEncapsulatedDocumentBuilder.part10Data(documentData: payload, options: build)
    }

    public static func export(document: ClinicalDocument,
                              patientModule: PatientModule,
                              seriesModule: SeriesModule = .init(),
                              options: DicomEncapsulatedDocumentBuildOptions) throws -> Data {
        let wrapper = Options(identity: .explicit, allowMismatch: false, dicom: options)
        return try export(document: document, patientModule: patientModule, seriesModule: seriesModule, options: wrapper)
    }

    public static func `import`(part10: Data) throws -> (ClinicalDocument, EnvelopeInfo) {
        let decoder: DCMDecoder
        do { decoder = try DCMDecoder(data: part10) }
        catch { throw Error.invalidPart10("DICOM Part 10 decode failed") }
        guard let encapsulated = decoder.encapsulatedDocument, encapsulated.kind == .cda,
              encapsulated.mimeType.lowercased() == "text/xml" else { throw Error.notCDA }
        let validation = DicomEncapsulatedDocumentEnvelopeValidator.validate(encapsulated)
        guard validation.isValid else { throw Error.invalidEnvelope(validation.diagnostics) }
        do {
            let document = try CDADocumentParser().parse(encapsulated.documentData)
            return (document, EnvelopeInfo(document: encapsulated, validation: validation))
        } catch {
            throw Error.invalidCDA("payload is not a CDA ClinicalDocument")
        }
    }

    public static func importDocument(part10: Data) throws -> (ClinicalDocument, EnvelopeInfo) {
        try `import`(part10: part10)
    }

    private static func patientIdentity(from document: ClinicalDocument) -> PatientModule? {
        guard let role = document.recordTargets.first?.patientRole else { return nil }
        let patient = role.patient
        let name = patient?.names.first.flatMap { name -> String? in
            let parts = name.node.children.reduce(into: [String]()) { result, node in
                if ["family", "given", "additional", "prefix", "suffix"].contains(node.name.localName), !node.textContent.isEmpty { result.append(node.textContent) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "^")
        }
        let id = role.ids.first?.extension
        let issuer = role.ids.first?.assigningAuthorityName
        let birth = patient?.birthTime?.value
        let sex = patient?.administrativeGenderCode?.code
        guard name != nil || id != nil || birth != nil || sex != nil else { return nil }
        return .init(patientName: name, patientID: id, issuer: issuer, birthDate: birth, sex: sex)
    }

    private static func matches(_ supplied: PatientModule, _ document: PatientModule) -> Bool {
        func equal(_ left: String?, _ right: String?) -> Bool {
            guard let left, let right else { return true }
            return left.trimmingCharacters(in: .whitespacesAndNewlines) == right.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return equal(supplied.patientID, document.patientID) && equal(supplied.patientName, document.patientName) &&
            equal(supplied.issuer, document.issuer) && equal(supplied.birthDate, document.birthDate) && equal(supplied.sex, document.sex)
    }

    private static func concept(from code: CD?) -> DicomCodedConcept? {
        guard let code, let value = code.code else { return nil }
        let scheme: String
        if let codeSystem = code.codeSystem, codeSystem.count <= 16 { scheme = codeSystem } else { scheme = "99CDA" }
        return DicomCodedConcept(codeValue: value, codingSchemeDesignator: scheme, codeMeaning: code.displayName)
    }
}

public typealias CDAEncapsulationOptions = CDAEncapsulation.Options
public typealias CDAEnvelopeInfo = CDAEncapsulation.EnvelopeInfo
public typealias CDAPatientModule = CDAEncapsulation.PatientModule
public typealias CDASeriesModule = CDAEncapsulation.SeriesModule
