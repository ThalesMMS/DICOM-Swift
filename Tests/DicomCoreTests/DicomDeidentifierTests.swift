import DicomCore
@testable import DicomData
import Foundation
import XCTest

/// PS3.15 Annex E de-identification with the versioned table (#2324). Sentinel identifiers are placed in
/// patient/study attributes, dates, private tags, sequences, structured content, an encapsulated document
/// and an overlay; every profile is checked for absence/retention and UID coherence across a cohort.
final class DicomDeidentifierTests: XCTestCase {
    static let sentinels = ["SENTINEL^PATIENT", "SENT-ID-77", "SENTINEL HOSPITAL", "SERIAL-SENT-1", "SENTINEL STUDY DESC", "SENTINEL-PRIVATE",
                            "SENTINEL TEXT ITEM", "SENTINEL^OBSERVER", "SENTINEL OVERLAY", "%PDF-SENTINEL", "SENTINEL REQUEST"]

    private func str(_ tag: Int, _ vr: DicomVR, _ values: [String]) -> DicomDataElement { DicomDataElement(tag: tag, vr: vr, value: .strings(values)) }
    private func num(_ tag: Int, _ value: UInt) -> DicomDataElement { DicomDataElement(tag: tag, vr: .US, value: .unsignedIntegers([value])) }
    private func item(_ elements: [DicomDataElement]) -> DicomSequenceItem { DicomSequenceItem(dataSet: DicomDataSet(elements: elements)) }

    /// One SC instance of the cohort; `references` names another instance's SOP Instance UID.
    func instance(uid: String, references: String? = nil, burnedIn: String? = "NO", withDocument: Bool = false, withContent: Bool = false) throws -> Data {
        var elements: [DicomDataElement] = [
            str(0x00080005, .CS, ["ISO_IR 100"]),
            str(0x00080016, .UI, ["1.2.840.10008.5.1.4.1.1.7"]), str(0x00080018, .UI, [uid]),
            str(0x0020000D, .UI, ["2.25.23349001"]), str(0x0020000E, .UI, ["2.25.23349002"]), str(0x00200052, .UI, ["2.25.23349003"]),
            str(0x00100010, .PN, ["SENTINEL^PATIENT"]), str(0x00100020, .LO, ["SENT-ID-77"]), str(0x00100030, .DA, ["19700215"]),
            str(0x00100040, .CS, ["M"]), str(0x00101010, .AS, ["054Y"]),
            str(0x00080020, .DA, ["20240115"]), str(0x00080030, .TM, ["101530.250000"]), str(0x00080021, .DA, ["202401"]),
            str(0x0008002A, .DT, ["20240115101530+0100"]), str(0x00080023, .DA, ["20240115"]), str(0x00080033, .TM, ["101600"]),
            str(0x00181012, .DA, ["2024"]), str(0x00080090, .PN, ["SENTINEL^REFERRER"]), str(0x00080080, .LO, ["SENTINEL HOSPITAL"]),
            str(0x00181000, .LO, ["SERIAL-SENT-1"]), str(0x00081030, .LO, ["SENTINEL STUDY DESC"]), str(0x00080060, .CS, ["OT"]),
            str(0x00080064, .CS, ["WSD"]), str(0x00200010, .SH, ["ST-1"]), str(0x00200011, .IS, ["1"]), str(0x00200013, .IS, ["1"]),
            str(0x00080050, .SH, ["ACC-SENT"]), str(0x00080070, .LO, ["Vendor"]),
            DicomDataElement(tag: 0x00400275, vr: .SQ, value: .sequence([item([str(0x00321060, .LO, ["SENTINEL REQUEST"]), str(0x00400009, .SH, ["SPS-1"])])])),
            // Private block 0x10 (unlisted creator) and block 0x11 (safe: Philips PET Private Group, (7053,xx00) SUV factor).
            str(0x00091010, .LO, ["SENTINEL CREATOR"]), str(0x00091001, .LO, ["SENTINEL-PRIVATE"]),
            str(0x70530010, .LO, ["Philips PET Private Group"]), str(0x70531000, .DS, ["1.5"]), str(0x70531099, .LO, ["SENTINEL-PRIVATE"]),
            // Overlay plane 6000.
            num(0x60000010, 2), num(0x60000011, 2), str(0x60000040, .CS, ["G"]), str(0x60004000, .LT, ["SENTINEL OVERLAY"]),
            DicomDataElement(tag: 0x60003000, vr: .OW, value: .bytes(Data([0xFF, 0x00]))),
            num(0x00280002, 1), str(0x00280004, .CS, ["MONOCHROME2"]), num(0x00280010, 2), num(0x00280011, 2), num(0x00280100, 8), num(0x00280101, 8),
            num(0x00280102, 7), num(0x00280103, 0), DicomDataElement(tag: 0x7FE00010, vr: .OB, value: .bytes(Data([1, 2, 3, 4])))
        ]
        if let burnedIn { elements.append(str(0x00280301, .CS, [burnedIn])) }
        if let references {
            elements.append(DicomDataElement(tag: 0x00081140, vr: .SQ, value: .sequence([item([str(0x00081150, .UI, ["1.2.840.10008.5.1.4.1.1.7"]), str(0x00081155, .UI, [references])])])))
        }
        if withDocument { elements.append(DicomDataElement(tag: 0x00420011, vr: .OB, value: .bytes(Data("%PDF-SENTINEL".utf8)))) }
        if withContent {
            elements.append(DicomDataElement(tag: 0x0040A730, vr: .SQ, value: .sequence([
                item([str(0x0040A010, .CS, ["CONTAINS"]), str(0x0040A040, .CS, ["TEXT"]), str(0x0040A160, .UT, ["SENTINEL TEXT ITEM"])]),
                item([str(0x0040A010, .CS, ["CONTAINS"]), str(0x0040A040, .CS, ["PNAME"]), str(0x0040A123, .PN, ["SENTINEL^OBSERVER"])]),
                item([str(0x0040A010, .CS, ["CONTAINS"]), str(0x0040A040, .CS, ["DATE"]), str(0x0040A121, .DA, ["20240115"])]),
                item([str(0x0040A010, .CS, ["CONTAINS"]), str(0x0040A040, .CS, ["CODE"]),
                      DicomDataElement(tag: 0x0040A168, vr: .SQ, value: .sequence([item([str(0x00080100, .SH, ["121071"]), str(0x00080102, .SH, ["DCM"]), str(0x00080104, .LO, ["Finding"])])]))]),
                item([str(0x0040A010, .CS, ["CONTAINS"]), str(0x0040A040, .CS, ["IMAGE"]),
                      DicomDataElement(tag: 0x00081199, vr: .SQ, value: .sequence([item([str(0x00081150, .UI, ["1.2.840.10008.5.1.4.1.1.7"]), str(0x00081155, .UI, [references ?? uid])])]))])
            ])))
        }
        return try DicomDataSetWriter.part10Data(from: DicomDataSet(elements: elements))
    }

    /// Every string value and binary byte of the output, for sentinel scans.
    static func flatten(_ dataSet: DicomDataSet) -> String {
        var text = ""
        for element in dataSet.elements {
            switch element.value {
            case .strings(let values): text += values.joined(separator: "|") + "\n"
            case .bytes(let data): text += String(decoding: data, as: UTF8.self) + "\n"
            case .sequence(let items): items.forEach { text += flatten($0.dataSet) }
            default: break
            }
        }
        return text
    }

    private func reopen(_ data: Data) throws -> DicomDataSet { try DicomPart10PixelDataPreserver.dataSet(from: DCMDecoder(data: data)) }

    // MARK: - Table

    func test_emptyUnavailableTable_isRejected() throws {
        let table = DicomDeidentificationTable(standard: "PS3.15", version: "", sourceSHA256: "",
                                              entries: [], safePrivateEntries: [], privateEntry: nil)
        XCTAssertThrowsError(try DicomDeidentifier(profile: .init(), session: .init(), table: table)) { error in
            guard case DicomDeidentificationError.tableUnavailable = error else { return XCTFail("\(error)") }
        }
    }

    func test_table_isVersionedAndAnswersTagsPatternsAndSafePrivate() throws {
        let table = DicomDeidentificationTable.standard
        XCTAssertEqual(table.version, "2026c")
        XCTAssertEqual(table.entries.count, 655, "656 rows less the private-attributes row")
        XCTAssertEqual(table.safePrivateEntries.count, 479)
        XCTAssertEqual(table.privateEntry?.basic, .remove)
        XCTAssertEqual(table.entry(forTag: 0x00100010)?.basic, .zero)
        XCTAssertEqual(table.entry(forTag: 0x60023000)?.tagPattern, "60xx3000")
        XCTAssertEqual(table.entry(forTag: 0x50020010)?.tagPattern, "50xxxxxx")
        XCTAssertNil(table.entry(forTag: 0x00280010))
        let study = try XCTUnwrap(table.entry(forTag: 0x00080020))
        XCTAssertEqual(study.action(with: []), .zero)
        XCTAssertEqual(study.action(with: [.retainLongitudinalModifiedDates]), .clean)
        XCTAssertEqual(study.action(with: [.retainLongitudinalFullDates, .retainLongitudinalModifiedDates]), .keep, "keep wins over clean")
        XCTAssertTrue(table.isSafePrivate(tag: 0x70531000, creator: "Philips PET Private Group"))
        XCTAssertTrue(table.isSafePrivate(tag: 0x70532A00, creator: " philips pet private group "))
        XCTAssertFalse(table.isSafePrivate(tag: 0x70531000, creator: "Other"))
        XCTAssertFalse(table.isSafePrivate(tag: 0x70531099, creator: "Philips PET Private Group"))
        XCTAssertFalse(table.sourceSHA256.isEmpty)
    }

    // MARK: - Basic profile and cohort coherence

    func test_basicProfile_removesEverySentinelAndKeepsCohortReferencesCoherent() throws {
        let a = try instance(uid: "2.25.23349011", references: "2.25.23349012", withContent: true)
        let b = try instance(uid: "2.25.23349012", references: "2.25.23349011")
        let session = DicomDeidentificationSession(dateShiftDays: -100)
        let deidentifier = try DicomDeidentifier(profile: .basic, session: session)
        let (outA, reportA) = try deidentifier.apply(a)
        let (outB, reportB) = try deidentifier.apply(b)
        let dsA = try reopen(outA), dsB = try reopen(outB)
        for sentinel in Self.sentinels {
            XCTAssertFalse(Self.flatten(dsA).contains(sentinel), sentinel)
            XCTAssertFalse(Self.flatten(dsB).contains(sentinel), sentinel)
        }
        XCTAssertFalse(String(decoding: outA, as: UTF8.self).contains("SENT-ID-77"))
        // Actions per code: Z empties, X removes, U remaps, D dummies, X/Z/D dummies (conformance kept).
        XCTAssertEqual(dsA[0x00100010]?.value, .empty)
        XCTAssertEqual(dsA[0x00100020]?.stringValue, "REMOVED", "Patient ID is Z/D in 2026c; the dummy keeps Type 1 uses conformant")
        XCTAssertEqual(dsA[0x00100030]?.value, .empty)
        XCTAssertNil(dsA[0x00101010], "Patient's Age is X without Retain Patient Characteristics")
        XCTAssertNil(dsA[0x00081030])
        XCTAssertEqual(dsA[0x00080080]?.stringValue, "REMOVED")
        XCTAssertEqual(dsA[0x00080023]?.stringValue, "19000101", "Z/D takes the dummy")
        XCTAssertEqual(dsA[0x00080020]?.value, .empty)
        XCTAssertNil(dsA[0x00181012], "unlisted DA removed")
        XCTAssertNil(dsA[0x00091001]); XCTAssertNil(dsA[0x00091010]); XCTAssertNil(dsA[0x70531000]); XCTAssertNil(dsA[0x70530010])
        XCTAssertNil(dsA[0x60003000]); XCTAssertNil(dsA[0x60004000])
        XCTAssertEqual(dsA[0x0040A730]?.sequenceItems.isEmpty, true, "structured content D without Clean Structured Content")
        XCTAssertNil(dsA[0x00400275])
        XCTAssertEqual(dsA[0x7FE00010]?.bytesValue, Data([1, 2, 3, 4]))
        XCTAssertEqual(dsA[0x00280301]?.stringValue, "NO")
        // Identity: fresh UIDs, consistent across the cohort and inside references.
        let newA = try XCTUnwrap(dsA.string(for: .sopInstanceUID)), newB = try XCTUnwrap(dsB.string(for: .sopInstanceUID))
        XCTAssertNotEqual(newA, "2.25.23349011"); XCTAssertNotEqual(newB, "2.25.23349012"); XCTAssertNotEqual(newA, newB)
        XCTAssertEqual(dsA.string(for: .studyInstanceUID), dsB.string(for: .studyInstanceUID))
        XCTAssertNotEqual(dsA.string(for: .studyInstanceUID), "2.25.23349001")
        XCTAssertEqual(dsA[0x00081140]?.sequenceItems.first?[0x00081155]?.stringValue, newB, "A's reference to B follows B's new identity")
        XCTAssertEqual(dsB[0x00081140]?.sequenceItems.first?[0x00081155]?.stringValue, newA)
        XCTAssertEqual(dsA[0x00081140]?.sequenceItems.first?[0x00081150]?.stringValue, "1.2.840.10008.5.1.4.1.1.7", "SOP Class UIDs are never remapped")
        XCTAssertEqual(try DCMDecoder(data: outA).info(for: 0x00020003), newA)
        XCTAssertEqual(session.replacement(for: "2.25.23349011"), newA)
        XCTAssertEqual(session.replacement(for: "2.25.23349012"), newB)
        XCTAssertEqual(session.mappingCount, 5, "study, series, frame of reference, two instances")
        // Markers.
        XCTAssertEqual(dsA[0x00120062]?.stringValue, "YES")
        XCTAssertEqual(dsA[0x00120063]?.stringValues.first?.contains("2026c"), true)
        XCTAssertEqual(dsA[0x00120064]?.sequenceItems.map { $0[0x00080100]?.stringValue }, ["113100"])
        XCTAssertEqual(dsA[0x00280303]?.stringValue, "REMOVED")
        XCTAssertEqual(reportA.classification, .incomplete, "structured content replaced is reported")
        XCTAssertEqual(reportA.findings.map(\.kind), [.structuredContentReplaced])
        XCTAssertEqual(reportB.classification, .deidentifiedPerProfile)
        XCTAssertFalse(reportA.actions.contains { ($0.note ?? "").contains("SENTINEL") }, "reports never carry values")
        XCTAssertEqual(reportA.uidReplacements["2.25.23349011"], newA)
        XCTAssertTrue(reportA.actions.contains { $0.tag == 0x00091001 && $0.disposition == .removed })
    }

    func test_safePrivateCreators_areScopedToTheirOwnDataset() throws {
        let source = try reopen(instance(uid: "2.25.2406.101"))
        let safe = item([
            str(0x70530010, .LO, ["Philips PET Private Group"]), str(0x70531000, .DS, ["1.5"])
        ])
        let unsafe = item([
            str(0x70530010, .LO, ["SYNTHETIC-SIBLING-CREATOR"]), str(0x70531099, .LO, ["SYNTHETIC-PRIVATE"])
        ])
        for safeFirst in [true, false] {
            var input = DicomDataSet(elements: source.elements.filter { $0.group.isMultiple(of: 2) })
            input.set(str(0x70530010, .LO, ["SYNTHETIC-ROOT-CREATOR"]))
            input.set(DicomDataElement(tag: 0x00081140, vr: .SQ,
                                       value: .sequence(safeFirst ? [safe, unsafe] : [unsafe, safe])))
            let deidentifier = try DicomDeidentifier(profile: .init(options: [.retainSafePrivate]),
                                                    session: DicomDeidentificationSession())
            let (data, report) = try deidentifier.apply(DicomDataSetWriter.part10Data(from: input))
            let output = try reopen(data)
            XCTAssertNil(output[0x70530010], "A nested retained block cannot retain the root creator")
            let items = output.sequenceItems(for: .referencedImageSequence)
            XCTAssertEqual(items.count, 2)
            guard items.count == 2 else { continue }
            let retained = items[safeFirst ? 0 : 1]
            let removed = items[safeFirst ? 1 : 0]
            XCTAssertEqual(retained[0x70530010]?.stringValue, "Philips PET Private Group")
            XCTAssertEqual(retained[0x70531000]?.stringValue, "1.5")
            XCTAssertNil(removed[0x70530010], "A sibling cannot borrow another dataset's retained block")
            XCTAssertNil(removed[0x70531099])
            XCTAssertEqual(report.classification, .deidentifiedPerProfile)
        }
    }

    // MARK: - Options

    func test_options_retainAndCleanAsTheTableSays() throws {
        let source = try instance(uid: "2.25.23349021", references: "2.25.23349022", withContent: true)
        func run(_ options: Set<DicomDeidentificationTable.Option>, shift: Int = -40) throws -> (DicomDataSet, DicomDeidentificationReport) {
            let (data, report) = try DicomDeidentifier(profile: .init(options: options), session: DicomDeidentificationSession(dateShiftDays: shift)).apply(source)
            return (try reopen(data), report)
        }
        let (uids, _) = try run([.retainUIDs])
        XCTAssertEqual(uids.string(for: .sopInstanceUID), "2.25.23349021")
        XCTAssertEqual(uids[0x00081140]?.sequenceItems.first?[0x00081155]?.stringValue, "2.25.23349022")
        XCTAssertEqual(uids[0x00120064]?.sequenceItems.map { $0[0x00080100]?.stringValue }, ["113100", "113110"])

        let (dates, datesReport) = try run([.retainLongitudinalModifiedDates], shift: -40)
        XCTAssertEqual(dates[0x00080020]?.stringValue, "20231206", "Study Date shifted by -40 days")
        XCTAssertEqual(dates[0x00080030]?.stringValue, "101530.250000", "times keep their value")
        XCTAssertEqual(dates[0x00080021]?.stringValue, "202311", "month precision kept (anchored at the first day)")
        XCTAssertEqual(dates[0x0008002A]?.stringValue, "20231206101530+0100", "DT keeps time and zone")
        XCTAssertEqual(dates[0x00181012]?.stringValue, "2023", "unlisted DA shifted, year precision kept")
        XCTAssertEqual(dates[0x00100030]?.value, .empty, "birth date is Z regardless of the dates option")
        XCTAssertEqual(dates[0x00280303]?.stringValue, "MODIFIED")
        XCTAssertEqual(datesReport.dateShiftDays, -40)

        let (full, _) = try run([.retainLongitudinalFullDates])
        XCTAssertEqual(full[0x00080020]?.stringValue, "20240115")
        XCTAssertEqual(full[0x00181012]?.stringValue, "2024")
        XCTAssertEqual(full[0x00280303]?.stringValue, "UNMODIFIED")

        let (safe, safeReport) = try run([.retainSafePrivate])
        XCTAssertEqual(safe[0x70531000]?.stringValue, "1.5")
        XCTAssertEqual(safe[0x70530010]?.stringValue, "Philips PET Private Group", "creator kept for the retained element")
        XCTAssertNil(safe[0x70531099]); XCTAssertNil(safe[0x00091001]); XCTAssertNil(safe[0x00091010])
        XCTAssertEqual(safeReport.classification, .incomplete, "structured content finding only")

        let (characteristics, _) = try run([.retainPatientCharacteristics, .retainDeviceIdentity, .retainInstitutionIdentity])
        XCTAssertEqual(characteristics[0x00101010]?.stringValue, "054Y")
        XCTAssertEqual(characteristics[0x00100040]?.stringValue, "M")
        XCTAssertEqual(characteristics[0x00181000]?.stringValue, "SERIAL-SENT-1")
        XCTAssertEqual(characteristics[0x00080080]?.stringValue, "SENTINEL HOSPITAL")
        XCTAssertEqual(characteristics[0x00100010]?.value, .empty)

        let (descriptors, descriptorReport) = try run([.cleanDescriptors])
        XCTAssertEqual(descriptors[0x00081030]?.stringValue, "SENTINEL STUDY DESC", "retained for review, never claimed clean")
        XCTAssertEqual(descriptors[0x00400275]?.sequenceItems.first?[0x00321060]?.stringValue, "SENTINEL REQUEST")
        XCTAssertTrue(descriptorReport.findings.contains { $0.kind == .descriptorRetained && $0.path == "(0008,1030)" })
        XCTAssertEqual(descriptorReport.classification, .incomplete)

        let (content, contentReport) = try run([.cleanStructuredContent])
        let items = try XCTUnwrap(content[0x0040A730]?.sequenceItems)
        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(items[0][0x0040A160]?.stringValue, "REMOVED")
        XCTAssertEqual(items[1][0x0040A123]?.stringValue, "ANONYMOUS")
        XCTAssertEqual(items[2][0x0040A121]?.stringValue, "19000101")
        XCTAssertEqual(items[3][0x0040A168]?.sequenceItems.first?[0x00080100]?.stringValue, "121071", "codes stay")
        let referenced = items[4][0x00081199]?.sequenceItems.first?[0x00081155]?.stringValue
        XCTAssertEqual(referenced, content[0x00081140]?.sequenceItems.first?[0x00081155]?.stringValue, "evidence reference follows the same mapping")
        XCTAssertFalse(contentReport.findings.contains { $0.kind == .structuredContentReplaced })
        XCTAssertEqual(contentReport.classification, .deidentifiedPerProfile)

        let (graphics, graphicsReport) = try run([.cleanGraphics])
        XCTAssertNil(graphics[0x60003000])
        XCTAssertTrue(graphicsReport.findings.contains { $0.kind == .graphicsRemoved })

        XCTAssertThrowsError(try DicomDeidentifier(profile: .init(options: [.retainLongitudinalFullDates, .retainLongitudinalModifiedDates]), session: .init())) {
            XCTAssertEqual($0 as? DicomDeidentificationError, .conflictingOptions([.retainLongitudinalFullDates, .retainLongitudinalModifiedDates]))
        }
        XCTAssertThrowsError(try DicomDeidentifier(profile: .init(overrides: [0x00280010: .remove]), session: .init())) {
            XCTAssertEqual($0 as? DicomDeidentificationError, .overrideNotAllowed(tag: 0x00280010))
        }
    }

    func test_overridesDocumentsPixelsAndClassification() throws {
        let session = DicomDeidentificationSession()
        let overridden = try DicomDeidentifier(profile: .init(overrides: [0x00100010: .replace("Case^Study"), 0x00100020: .keep, 0x00080070: .remove], methodDescription: "unit test"), session: session)
        let (data, report) = try overridden.apply(try instance(uid: "2.25.23349031"))
        let dataSet = try reopen(data)
        XCTAssertEqual(dataSet[0x00100010]?.stringValue, "Case^Study")
        XCTAssertEqual(dataSet[0x00100020]?.stringValue, "SENT-ID-77", "caller override keeps the value on purpose")
        XCTAssertNil(dataSet[0x00080070])
        XCTAssertEqual(dataSet[0x00120063]?.stringValues.last, "unit test")
        XCTAssertEqual(report.classification, .incomplete)
        XCTAssertEqual(dataSet[0x00120062]?.stringValue, "NO")
        XCTAssertNil(dataSet[0x00120064], "retained identifiers cannot claim the Basic Profile")
        XCTAssertTrue(report.findings.contains { $0.kind == .profileActionOverridden && $0.path == "(0010,0020)" })
        // Encapsulated documents are not cleaned: dummy payload and an explicit finding.
        let (withDocument, documentReport) = try DicomDeidentifier(profile: .basic, session: session).apply(try instance(uid: "2.25.23349032", withDocument: true))
        XCTAssertEqual(try reopen(withDocument)[0x00420011]?.bytesValue, Data([0, 0]))
        XCTAssertEqual(documentReport.classification, .incomplete)
        XCTAssertTrue(documentReport.findings.contains { $0.kind == .encapsulatedDocumentReplaced })
        // Burned-in pixels: reject by default, flag or accept by policy; unknown flagged by default.
        let burned = try instance(uid: "2.25.23349033", burnedIn: "YES")
        XCTAssertThrowsError(try DicomDeidentifier(profile: .basic, session: session).apply(burned)) { XCTAssertEqual($0 as? DicomDeidentificationError, .rejected(.burnedInAnnotation)) }
        XCTAssertEqual(try DicomDeidentifier(profile: .basic, session: session).plan(burned).classification, .rejected)
        XCTAssertEqual(try DicomDeidentifier(profile: .init(burnedInAnnotationPolicy: .flag), session: session).apply(burned).report.classification, .incomplete)
        XCTAssertEqual(try DicomDeidentifier(profile: .init(burnedInAnnotationPolicy: .accept), session: session).apply(burned).report.classification, .deidentifiedPerProfile)
        let unknown = try instance(uid: "2.25.23349034", burnedIn: nil)
        XCTAssertEqual(try DicomDeidentifier(profile: .basic, session: session).apply(unknown).report.findings.map(\.kind), [.unknownBurnedInAnnotation])
        XCTAssertThrowsError(try DicomDeidentifier(profile: .init(unknownBurnedInPolicy: .reject), session: session).apply(unknown))
        XCTAssertThrowsError(try DicomDeidentifier(profile: .basic, session: session).apply(Data([1, 2, 3]))) { XCTAssertEqual($0 as? DicomDeidentificationError, .notPart10) }
    }

    // MARK: - Session semantics

    func test_overrides_retainedIdentifiersAreIncompleteButPermittedRetentionKeepsMarkers() throws {
        let source = try instance(uid: "2.25.23349050")
        for tag in [0x00100020, 0x00100030, 0x00080050] {
            let deidentifier = try DicomDeidentifier(profile: .init(overrides: [tag: .keep]), session: .init())
            XCTAssertEqual(try deidentifier.plan(source).classification, .incomplete)
            let (data, report) = try deidentifier.apply(source)
            XCTAssertEqual(report.classification, .incomplete)
            XCTAssertEqual(try reopen(data)[tag]?.value, try reopen(source)[tag]?.value)
            XCTAssertEqual(try reopen(data)[0x00120062]?.stringValue, "NO")
            XCTAssertNil(try reopen(data)[0x00120064])
        }
        let permitted = try DicomDeidentifier(profile: .init(overrides: [0x00080060: .keep]), session: .init())
        let (data, report) = try permitted.apply(source)
        XCTAssertEqual(report.classification, .deidentifiedPerProfile)
        XCTAssertEqual(try reopen(data)[0x00120062]?.stringValue, "YES")
        XCTAssertEqual(try reopen(data)[0x00120064]?.sequenceItems.first?[0x00080100]?.stringValue, "113100")
    }

    func test_session_concurrentAppliesPreserveCohortReferences() async throws {
        let session = DicomDeidentificationSession(dateShiftDays: -7)
        let deidentifier = try DicomDeidentifier(profile: .basic, session: session)
        let originals = ["2.25.23349051", "2.25.23349052"]
        let inputs = try [
            instance(uid: originals[0], references: originals[1]),
            instance(uid: originals[1], references: originals[0])
        ]
        let outputs = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for index in 0..<32 {
                group.addTask { (index % 2, try deidentifier.apply(inputs[index % 2]).fileData) }
            }
            var outputs: [(Int, Data)] = []
            for try await output in group { outputs.append(output) }
            return outputs
        }
        for (index, output) in outputs {
            let dataSet = try reopen(output)
            XCTAssertEqual(dataSet.string(for: .sopInstanceUID), session.replacement(for: originals[index]))
            XCTAssertEqual(dataSet.string(for: .studyInstanceUID), session.replacement(for: "2.25.23349001"))
            XCTAssertEqual(dataSet.string(for: .seriesInstanceUID), session.replacement(for: "2.25.23349002"))
            XCTAssertEqual(dataSet[0x00081140]?.sequenceItems.first?[0x00081155]?.stringValue,
                           session.replacement(for: originals[1 - index]))
        }
        XCTAssertEqual(session.mappingCount, 5)
    }

    func test_audit_reusedMappingsRemainCompleteWithoutIdentifiersInNotes() throws {
        let source = try instance(uid: "2.25.23349041", references: "2.25.23349042")
        let deidentifier = try DicomDeidentifier(profile: .basic, session: .init())
        let first = try deidentifier.apply(source).report
        let reused = try deidentifier.apply(source).report
        XCTAssertEqual(first.uidReplacements.count, 5)
        XCTAssertEqual(reused.uidReplacements, first.uidReplacements)
        for report in [first, reused] {
            for original in report.uidReplacements.keys {
                XCTAssertFalse(report.actions.contains { ($0.note ?? "").contains(original) })
            }
        }
    }

    func test_verification_retainedPreviouslyMappedUIDFailsWithoutCommitting() throws {
        let original = "2.25.23349043"
        let session = DicomDeidentificationSession()
        session.seed([original: "2.25.900"])
        let deidentifier = try DicomDeidentifier(profile: .init(overrides: [0x00081155: .keep]), session: session)
        XCTAssertThrowsError(try deidentifier.apply(instance(uid: original, references: original))) {
            guard case .writeFailed = $0 as? DicomDeidentificationError else {
                return XCTFail("expected verification failure, received \($0)")
            }
        }
        XCTAssertEqual(session.mappingCount, 1)
        XCTAssertEqual(session.replacement(for: original), "2.25.900")
    }

    func test_session_malformedUIDRootsAreRejected() throws {
        for root in ["", ".1", "1.", "1..2", "abc", "1. 2", "1.٢", "1.02"] {
            XCTAssertThrowsError(try DicomDeidentificationSession(uidRoot: root).makeUID(), root) {
                XCTAssertEqual($0 as? DicomDeidentificationError, .invalidUIDRoot)
            }
        }
        for root in ["2.25", "1.2.826.0.1.3680043.9", "1.0"] {
            XCTAssertTrue(try DicomDeidentificationSession(uidRoot: root).makeUID().hasPrefix(root + "."))
        }
    }

    func test_modifiedDates_unshiftableValuesAreReplacedAndReportedIncomplete() throws {
        for (tag, vr, value) in [(0x00080020, DicomVR.DA, "2024XX01"),
                                 (0x00080020, .DA, "20240230"),
                                 (0x0008002A, .DT, "20240115101530+9999"),
                                 (0x0008002A, .DT, "INVALID-DATE")] {
            var source = try reopen(instance(uid: "2.25.23349061"))
            source.set(str(tag, vr, [value]))
            let data = try DicomDataSetWriter.part10Data(from: source)
            let (output, report) = try DicomDeidentifier(
                profile: .init(options: [.retainLongitudinalModifiedDates]),
                session: DicomDeidentificationSession(dateShiftDays: -10)
            ).apply(data)
            XCTAssertEqual(try reopen(output)[tag]?.stringValue, vr == .DA ? "19000101" : "19000101000000")
            XCTAssertEqual(report.classification, .incomplete)
            XCTAssertTrue(report.findings.contains { $0.detail.contains("could not be shifted") })
            XCTAssertFalse(report.findings.contains { $0.detail.contains(value) })
            XCTAssertFalse(report.actions.contains { $0.tag == tag && $0.note == "C: date shifted" })
        }
    }

    func test_session_UIDRootLengthIsBoundedBeforeGeneratingAReplacement() throws {
        let maximumRoot = "1." + String(repeating: "2", count: DicomRewritePolicy.maximumUIDRootLength - 2)
        let uid = try DicomDeidentificationSession(uidRoot: maximumRoot).makeUID()
        XCTAssertTrue(uid.hasPrefix(maximumRoot + "."))
        XCTAssertLessThanOrEqual(uid.count, 64)
        let tooLong = maximumRoot + "2"
        XCTAssertThrowsError(try DicomDeidentificationSession(uidRoot: tooLong).makeUID()) {
            XCTAssertEqual($0 as? DicomRewritePolicyError,
                           .uidRootTooLong(root: tooLong, maximumLength: DicomRewritePolicy.maximumUIDRootLength))
        }
    }

    func test_session_dryRunFailureCancellationAndReversalKey() async throws {
        let session = DicomDeidentificationSession(dateShiftDays: -7)
        let deidentifier = try DicomDeidentifier(profile: .basic, session: session)
        let source = try instance(uid: "2.25.23349041")
        _ = try deidentifier.plan(source)
        XCTAssertEqual(session.mappingCount, 0, "dry run commits nothing")
        XCTAssertThrowsError(try deidentifier.apply(try instance(uid: "2.25.23349042", burnedIn: "YES")))
        XCTAssertEqual(session.mappingCount, 0, "a rejected instance leaves no mapping")
        // Cancellation before the rewrite starts leaves the session untouched.
        let task = Task { () -> Bool in
            try? await Task.sleep(nanoseconds: 50_000_000)
            do { _ = try deidentifier.apply(source); return false } catch is CancellationError { return true } catch { return false }
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertTrue(cancelled)
        XCTAssertEqual(session.mappingCount, 0)
        // Apply commits; the reversal key restores the same mapping in a new session and never reaches the output.
        let (data, _) = try deidentifier.apply(source)
        XCTAssertEqual(session.mappingCount, 4)
        let key = session.reversalKey()
        XCTAssertEqual(key.dateShiftDays, -7)
        XCTAssertEqual(key.uidMap["2.25.23349041"], try reopen(data).string(for: .sopInstanceUID))
        let resumed = DicomDeidentificationSession(reversalKey: key)
        let (again, _) = try DicomDeidentifier(profile: .basic, session: resumed).apply(source)
        XCTAssertEqual(try reopen(again).string(for: .sopInstanceUID), try reopen(data).string(for: .sopInstanceUID))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("2.25.23349041"))
        let encoded = try JSONEncoder().encode(key)
        XCTAssertEqual(try JSONDecoder().decode(DicomDeidentificationSession.ReversalKey.self, from: encoded), key)
        // Seeded identities win over generated ones.
        let seeded = DicomDeidentificationSession()
        seeded.seed(["2.25.23349041": "2.25.900"])
        XCTAssertEqual(try reopen(try DicomDeidentifier(profile: .basic, session: seeded).apply(source).fileData).string(for: .sopInstanceUID), "2.25.900")
        XCTAssertTrue(try DicomDeidentificationSession(uidRoot: "1.2.826.0.1.3680043.9").makeUID().hasPrefix("1.2.826.0.1.3680043.9."))
    }
}
