import Foundation

public enum DicomSRMeasurementReportBuilder {
    public static func build(_ report: DicomSRMeasurementReport) throws -> DicomSRDocument {
        let state = BuildState(report: report)
        appendContext(state)
        try appendMeasurements(state)
        try appendDerived(state)
        appendQualitative(state)
        makeRoot(state)
        let document = try makeDocument(state)
        for item in document.root.flattened {
            if let value = item.numericValue, let floatingPoint = item.floatingPointValue, value != floatingPoint {
                throw DicomSRMeasurementReportBuilderError.conflictingNumericRepresentations
            }
        }
        let validation = DicomSRTemplateValidator.validate(document)
        guard validation.errors.isEmpty else { throw DicomSRMeasurementReportBuilderError.invalidTemplate(validation.errors) }
        return document
    }

    private final class BuildState {
        let report: DicomSRMeasurementReport
        var children: [DicomSRContentItem] = []
        var root = DicomSRContentItem(valueType: "CONTAINER")
        var groupContainerIndex = 0

        init(report: DicomSRMeasurementReport) { self.report = report }
    }

    @inline(never)
    private static func appendContext(_ state: BuildState) {
        if let language = state.report.language { state.children.append(languageItem(language)) }
        state.children += observerItems(state.report.observers)
        if let uid = state.report.procedureStudyInstanceUID {
            state.children.append(item("UIDREF", "121018", "Procedure Study Instance UID", rel: "HAS OBS CONTEXT", uid: uid))
        }
        appendSubject(state)
        state.children += state.report.proceduresReported.map { item("CODE", "121058", "Procedure reported", rel: "HAS CONCEPT MOD", value: $0) }
        if !state.report.imageLibrary.isEmpty {
            state.children.append(container("111028", "Image Library", children: [
                container("126200", "Image Library Group", children: state.report.imageLibrary.map(imageLibraryItem))
            ]))
        }
    }

    @inline(never)
    private static func appendSubject(_ state: BuildState) {
        if let subject = state.report.subject {
            if let name = subject.name {
                state.children.append(DicomSRContentItem(relationshipType: "HAS OBS CONTEXT", valueType: "PNAME",
                    conceptName: code("121029", "Subject Name"), personNameValue: DicomPersonName(name)))
            }
            if let id = subject.id { state.children.append(item("CODE", "121030", "Subject ID", rel: "HAS OBS CONTEXT", value: id)) }
            if let date = subject.birthDate {
                state.children.append(DicomSRContentItem(relationshipType: "HAS OBS CONTEXT", valueType: "DATE",
                    conceptName: code("121031", "Subject Birth Date"), dateValue: date))
            }
            if let sex = subject.sex { state.children.append(item("CODE", "121032", "Subject Sex", rel: "HAS OBS CONTEXT", value: sex)) }
        }
    }

    @inline(never)
    private static func appendMeasurements(_ state: BuildState) throws {
        state.groupContainerIndex = state.children.count
        let groups = try state.report.measurementGroups.map(groupItem)
        if !groups.isEmpty || (state.report.derivedMeasurements.isEmpty && state.report.qualitativeEvaluations.isEmpty) {
            state.children.append(container("126010", "Imaging Measurements", children: groups))
        }
    }

    @inline(never)
    private static func appendDerived(_ state: BuildState) throws {
        if !state.report.derivedMeasurements.isEmpty {
            var values: [DicomSRContentItem] = []
            for derived in state.report.derivedMeasurements {
                var references: [DicomSRContentItem] = []
                var kinds = Set<String>()
                for reference in derived.groups {
                    let index: Int?
                    switch reference {
                    case .index(let value): index = state.report.measurementGroups.indices.contains(value) ? value : nil
                    case .trackingUID(let uid):
                        let matches = state.report.measurementGroups.indices.filter { state.report.measurementGroups[$0].trackingUID == uid }
                        index = matches.count == 1 ? matches.first : nil
                    }
                    guard let index, state.report.measurementGroups[index].kind != .generic else {
                        throw DicomSRMeasurementReportBuilderError.invalidGroupReference
                    }
                    kinds.insert(state.report.measurementGroups[index].kind.rawValue)
                    references.append(DicomSRContentItem(relationshipType: "INFERRED FROM", valueType: "",
                        referencedContentItemIdentifier: [1, state.groupContainerIndex + 1, index + 1]))
                }
                guard !references.isEmpty, kinds.count == 1 else {
                    throw DicomSRMeasurementReportBuilderError.invalidGroupReference
                }
                values.append(measurementItem(derived.measurement, extraChildren: references))
            }
            state.children.append(container("126011", "Derived Imaging Measurements", children: values))
        }
    }

    @inline(never)
    private static func appendQualitative(_ state: BuildState) {
        if !state.report.qualitativeEvaluations.isEmpty {
            state.children.append(DicomSRContentItem(relationshipType: "CONTAINS", valueType: "CONTAINER",
                conceptName: code("C0034375", "Qualitative Evaluations", scheme: "UMLS"), continuityOfContent: "SEPARATE",
                children: state.report.qualitativeEvaluations.map(qualitativeItem)))
        }
    }

    @inline(never)
    private static func makeRoot(_ state: BuildState) {
        state.root = DicomSRContentItem(valueType: "CONTAINER", conceptName: code("126000", "Imaging Measurement Report"),
            continuityOfContent: "SEPARATE", children: state.children,
            contentTemplate: .init(mappingResource: "DCMR", templateIdentifier: "1500"))
    }

    @inline(never)
    private static func makeDocument(_ state: BuildState) throws -> DicomSRDocument {
        let has3D = state.root.flattened.contains { $0.valueType == "SCOORD3D" }
        if has3D, let pinned = state.report.sopClassUID, pinned != DicomSRDocument.comprehensive3DSRStorageSOPClassUID {
            throw DicomSRMeasurementReportBuilderError.scoord3DRequiresComprehensive3D
        }
        let sop = state.report.sopClassUID ?? (has3D ? DicomSRDocument.comprehensive3DSRStorageSOPClassUID
            : state.report.derivedMeasurements.isEmpty ? DicomSRDocument.enhancedSRStorageSOPClassUID
            : DicomSRDocument.comprehensiveSRStorageSOPClassUID)
        if !state.report.derivedMeasurements.isEmpty && ![DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            DicomSRDocument.comprehensive3DSRStorageSOPClassUID].contains(sop) {
            throw DicomSRMeasurementReportBuilderError.byReferenceRequiresComprehensive
        }
        guard [DicomSRDocument.enhancedSRStorageSOPClassUID, DicomSRDocument.comprehensiveSRStorageSOPClassUID,
               DicomSRDocument.comprehensive3DSRStorageSOPClassUID].contains(sop) else {
            throw DicomSRMeasurementReportBuilderError.unsupportedSOPClass
        }
        return DicomSRDocument(sopClassUID: sop, sopInstanceUID: state.report.sopInstanceUID,
            completionFlag: "COMPLETE", verificationFlag: "UNVERIFIED", templateIdentifier: "1500", root: state.root)
    }


    static func code(_ value: String, _ meaning: String, scheme: String = "DCM") -> DicomCodedConcept {
        .init(codeValue: value, codingSchemeDesignator: scheme, codeMeaning: meaning)
    }

    static func item(_ type: String, _ concept: String, _ meaning: String, rel: String = "CONTAINS",
                     text: String? = nil, value: DicomCodedConcept? = nil, uid: String? = nil,
                     children: [DicomSRContentItem] = []) -> DicomSRContentItem {
        .init(relationshipType: rel, valueType: type, conceptName: code(concept, meaning), textValue: text,
              codeValue: value, uidValue: uid, children: children)
    }

    static func container(_ concept: String, _ meaning: String, children: [DicomSRContentItem]) -> DicomSRContentItem {
        .init(relationshipType: "CONTAINS", valueType: "CONTAINER", conceptName: code(concept, meaning),
              continuityOfContent: "SEPARATE", children: children)
    }

    static func languageItem(_ language: DicomSRLanguage) -> DicomSRContentItem {
        item("CODE", "121049", "Language of Content Item and Descendants", rel: "HAS CONCEPT MOD", value: language.code,
             children: language.country.map { [item("CODE", "121046", "Country of Language", rel: "HAS CONCEPT MOD", value: $0)] } ?? [])
    }

    static func observerItems(_ observers: [DicomSRObserver]) -> [DicomSRContentItem] {
        observers.flatMap { observer -> [DicomSRContentItem] in
            var items = [item("CODE", "121005", "Observer Type", rel: "HAS OBS CONTEXT",
                value: code(observer.kind == .person ? "121006" : "121007", observer.kind == .person ? "Person" : "Device"))]
            if observer.kind == .person {
                if let name = observer.name {
                    items.append(.init(relationshipType: "HAS OBS CONTEXT", valueType: "PNAME",
                        conceptName: code("121008", "Person Observer Name"), personNameValue: DicomPersonName(name)))
                }
                if let organisation = observer.organisation {
                    items.append(item("TEXT", "121009", "Person Observer's Organization Name", rel: "HAS OBS CONTEXT", text: organisation))
                }
                if let role = observer.role { items.append(item("CODE", "121010", "Person Observer's Role in the Organization", rel: "HAS OBS CONTEXT", value: role)) }
                if let role = observer.procedureRole { items.append(item("CODE", "121011", "Person Observer's Role in this Procedure", rel: "HAS OBS CONTEXT", value: role)) }
            } else {
                if let uid = observer.deviceUID { items.append(item("UIDREF", "121012", "Device Observer UID", rel: "HAS OBS CONTEXT", uid: uid)) }
                for (value, concept, meaning) in [(observer.name, "121013", "Device Observer Name"),
                    (observer.manufacturer, "121014", "Device Observer Manufacturer"),
                    (observer.model, "121015", "Device Observer Model Name"),
                    (observer.serial, "121016", "Device Observer Serial Number")] {
                    if let value { items.append(item("TEXT", concept, meaning, rel: "HAS OBS CONTEXT", text: value)) }
                }
            }
            return items
        }
    }

    static func siteItem(_ site: DicomSRFindingSite) -> DicomSRContentItem {
        var children: [DicomSRContentItem] = []
        if let laterality = site.laterality {
            children.append(.init(relationshipType: "HAS CONCEPT MOD", valueType: "CODE",
                conceptName: code("272741003", "Laterality", scheme: "SCT"), codeValue: laterality))
        }
        if let modifier = site.modifier {
            children.append(.init(relationshipType: "HAS CONCEPT MOD", valueType: "CODE",
                conceptName: code("106233006", "Topographical modifier", scheme: "SCT"), codeValue: modifier))
        }
        return .init(relationshipType: "HAS CONCEPT MOD", valueType: "CODE",
            conceptName: code("363698007", "Finding Site", scheme: "SCT"), codeValue: site.site, children: children)
    }

    static func methodItem(_ method: DicomCodedConcept) -> DicomSRContentItem {
        .init(relationshipType: "HAS CONCEPT MOD", valueType: "CODE",
              conceptName: code("370129005", "Measurement Method", scheme: "SCT"), codeValue: method)
    }

    static func measurementItem(_ value: DicomSRMeasurementValue,
                                extraChildren: [DicomSRContentItem] = []) -> DicomSRContentItem {
        var children: [DicomSRContentItem] = []
        if let method = value.method { children.append(methodItem(method)) }
        if let derivation = value.derivation { children.append(item("CODE", "121401", "Derivation", rel: "HAS CONCEPT MOD", value: derivation)) }
        if let site = value.findingSite { children.append(siteItem(site)) }
        children += value.inferredFrom.map { source in
            switch source {
            case .image(let image):
                return .init(relationshipType: "INFERRED FROM", valueType: "IMAGE", conceptName: code("121112", "Source of Measurement"), referencedSOPs: [image])
            case .scoord(let region): return regionItem(region, relationship: "INFERRED FROM")
            case .scoord3D(let surface): return surfaceItem(surface, relationship: "INFERRED FROM")
            }
        }
        children += extraChildren
        return .init(relationshipType: "CONTAINS", valueType: "NUM", conceptName: value.concept,
            numericValue: value.value, measurementUnits: value.units, children: children,
            numericValueQualifier: value.qualifier, floatingPointValue: value.floatingPointValue)
    }

    static func regionItem(_ region: DicomSRImageRegion, relationship: String = "CONTAINS") -> DicomSRContentItem {
        .init(relationshipType: relationship, valueType: "SCOORD", conceptName: code("111030", "Image Region"),
            graphicType: region.graphicType, graphicData: region.data, children: [
                .init(relationshipType: "SELECTED FROM", valueType: "IMAGE", conceptName: code("121112", "Source of Measurement"), referencedSOPs: [region.image])
            ])
    }

    static func surfaceItem(_ surface: DicomSRVolumeSurface, relationship: String = "CONTAINS") -> DicomSRContentItem {
        .init(relationshipType: relationship, valueType: "SCOORD3D", conceptName: code("121231", "Volume Surface"),
              graphicType: surface.graphicType, graphicData: surface.data, frameOfReferenceUID: surface.frameOfReferenceUID)
    }

    static func qualitativeItem(_ evaluation: DicomSRQualitativeEvaluation) -> DicomSRContentItem {
        switch evaluation {
        case .code(let concept, let value):
            return .init(relationshipType: "CONTAINS", valueType: "CODE", conceptName: concept, codeValue: value)
        case .text(let concept, let text):
            return .init(relationshipType: "CONTAINS", valueType: "TEXT", conceptName: concept, textValue: text)
        }
    }

    static func groupItem(_ group: DicomSRMeasurementGroup) throws -> DicomSRContentItem {
        guard let uid = group.trackingUID, !uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DicomSRMeasurementReportBuilderError.missingTrackingUID
        }
        var children: [DicomSRContentItem] = []
        if let activity = group.activitySession {
            children.append(.init(relationshipType: "HAS OBS CONTEXT", valueType: "TEXT",
                conceptName: code("C67447", "Activity Session", scheme: "NCIt"), textValue: activity))
        }
        if let id = group.trackingIdentifier { children.append(item("TEXT", "112039", "Tracking Identifier", rel: "HAS OBS CONTEXT", text: id)) }
        children.append(item("UIDREF", "112040", "Tracking Unique Identifier", rel: "HAS OBS CONTEXT", uid: uid))
        if let category = group.findingCategory {
            children.append(.init(relationshipType: "CONTAINS", valueType: "CODE",
                conceptName: code("276214006", "Finding category", scheme: "SCT"), codeValue: category))
        }
        if let finding = group.finding { children.append(item("CODE", "121071", "Finding", value: finding)) }
        if let timePoint = group.timePoint { children += timePointItems(timePoint) }
        if let method = group.method { children.append(methodItem(method)) }
        children += group.findingSites.map(siteItem)
        var sources = group.sourceImages
        var series = group.sourceSeriesUID
        switch group.region {
        case .none: break
        case .imageRegion(let region): children.append(regionItem(region))
        case .imageRegions(let regions): children += regions.map { regionItem($0) }
        case .volumeSurface(let surfaces): children += surfaces.map { surfaceItem($0) }
        case .referencedSegmentationFrame(let reference, let sourceImages):
            children.append(.init(relationshipType: "CONTAINS", valueType: "IMAGE",
                conceptName: code("121214", "Referenced Segmentation Frame"), referencedSOPs: [reference]))
            sources += sourceImages
        case .referencedSegment(let reference, let sourceImages, let sourceSeries):
            children.append(.init(relationshipType: "CONTAINS", valueType: "IMAGE",
                conceptName: code("121191", "Referenced Segment"), referencedSOPs: [reference]))
            sources += sourceImages
            series = sourceSeries ?? series
        }
        children += sources.map { .init(relationshipType: "CONTAINS", valueType: "IMAGE",
            conceptName: code("121233", "Source image for segmentation"), referencedSOPs: [$0]) }
        if sources.isEmpty, let series {
            children.append(item("UIDREF", "121232", "Source series for segmentation", uid: series))
        }
        children += group.measurements.map { measurementItem($0) }
        children += group.qualitativeEvaluations.map(qualitativeItem)
        return .init(relationshipType: "CONTAINS", valueType: "CONTAINER", conceptName: code("125007", "Measurement Group"),
            continuityOfContent: "SEPARATE", children: children,
            contentTemplate: .init(mappingResource: "DCMR", templateIdentifier: group.kind.rawValue))
    }

    static func timePointItems(_ point: DicomSRTimePoint) -> [DicomSRContentItem] {
        var children: [DicomSRContentItem] = []
        if let subject = point.subjectIdentifier { children.append(item("TEXT", "126070", "Subject Time Point Identifier", rel: "HAS OBS CONTEXT", text: subject)) }
        if let identifier = point.protocolIdentifier { children.append(item("TEXT", "126071", "Protocol Time Point Identifier", rel: "HAS OBS CONTEXT", text: identifier)) }
        children.append(.init(relationshipType: "HAS OBS CONTEXT", valueType: "TEXT",
            conceptName: code("C2348792", "Time Point", scheme: "UMLS"), textValue: point.timePoint))
        children += point.types.map { item("CODE", "126072", "Time Point Type", rel: "HAS OBS CONTEXT", value: $0) }
        if let order = point.order { children.append(.init(relationshipType: "HAS OBS CONTEXT", valueType: "NUM",
            conceptName: code("126073", "Time Point Order"), numericValue: order, measurementUnits: code("1", "no units", scheme: "UCUM"))) }
        if let offset = point.temporalOffset {
            children.append(.init(relationshipType: "HAS OBS CONTEXT", valueType: "NUM",
                conceptName: code("128740", "Longitudinal Temporal Offset from Event"), numericValue: offset,
                measurementUnits: code("d", "days", scheme: "UCUM"), children: point.temporalEvent.map {
                    [item("CODE", "128741", "Longitudinal Temporal Event Type", rel: "HAS CONCEPT MOD", value: $0)]
                } ?? []))
        }
        return children
    }
}
