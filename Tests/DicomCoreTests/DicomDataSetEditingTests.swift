import DicomCore
import Foundation
import XCTest

/// Tag paths, recursive diff and identity-aware edits (#2323).
final class DicomDataSetEditingTests: XCTestCase {
    private func element(_ tag: Int, _ vr: DicomVR, _ values: [String]) -> DicomDataElement {
        DicomDataElement(tag: tag, vr: vr, value: .strings(values))
    }

    private func item(_ elements: [DicomDataElement]) -> DicomSequenceItem { DicomSequenceItem(dataSet: DicomDataSet(elements: elements)) }

    /// A data set whose Frame of Reference UID is also referenced inside two nested sequences.
    private func nested() -> DicomDataSet {
        DicomDataSet(elements: [
            element(0x00080016, .UI, ["1.2.840.10008.5.1.4.1.1.7"]),
            element(0x00080018, .UI, ["2.25.100"]),
            element(0x00100010, .PN, ["Edit^Case"]),
            element(0x0020000D, .UI, ["2.25.200"]),
            element(0x0020000E, .UI, ["2.25.300"]),
            element(0x00200052, .UI, ["2.25.400"]),
            DicomDataElement(tag: 0x00081115, vr: .SQ, value: .sequence([
                item([element(0x0020000E, .UI, ["2.25.300"]),
                      DicomDataElement(tag: 0x0008114A, vr: .SQ, value: .sequence([
                          item([element(0x00081150, .UI, ["1.2.840.10008.5.1.4.1.1.7"]), element(0x00081155, .UI, ["2.25.100"])]),
                          item([element(0x00081150, .UI, ["1.2.840.10008.5.1.4.1.1.7"]), element(0x00081155, .UI, ["2.25.101"])])
                      ]))]),
                item([element(0x0020000E, .UI, ["2.25.301"])])
            ])),
            DicomDataElement(tag: 0x30060010, vr: .SQ, value: .sequence([item([element(0x00200052, .UI, ["2.25.400"])])]))
        ])
    }

    // MARK: - Paths

    func test_tagPath_parsesFormatsAndRejectsMalformedText() throws {
        let path = try DicomTagPath(parsing: "(0008,1115)[0]/0008114A[*]/(0008,1155)")
        XCTAssertEqual(path.components, [.init(tag: 0x00081115, item: .index(0)), .init(tag: 0x0008114A, item: .all), .init(tag: 0x00081155)])
        XCTAssertEqual(path.description, "(0008,1115)[0]/(0008,114A)[*]/(0008,1155)")
        XCTAssertEqual(try DicomTagPath(parsing: "00100010"), DicomTagPath(.patientName))
        XCTAssertThrowsError(try DicomTagPath(parsing: "00081115/00081155")) { XCTAssertEqual($0 as? DicomTagPath.ParseError, .missingItemIndex("00081115")) }
        XCTAssertThrowsError(try DicomTagPath(parsing: "0010,0010")) { XCTAssertEqual($0 as? DicomTagPath.ParseError, .malformedComponent("0010,0010")) }
        XCTAssertThrowsError(try DicomTagPath(parsing: "00081115[-1]/00081155"))
        XCTAssertThrowsError(try DicomTagPath(parsing: ""))
    }

    func test_dataSet_selectsSetsAndRemovesByPath() throws {
        let dataSet = nested()
        let matches = try dataSet.elements(matching: try DicomTagPath(parsing: "00081115[*]/0008114A[*]/00081155"))
        XCTAssertEqual(matches.map(\.element.stringValue), ["2.25.100", "2.25.101"])
        XCTAssertEqual(matches.map(\.path.description), ["(0008,1115)[0]/(0008,114A)[0]/(0008,1155)", "(0008,1115)[0]/(0008,114A)[1]/(0008,1155)"])
        XCTAssertEqual(try dataSet.element(at: try DicomTagPath(parsing: "00081115[1]/0020000E"))?.stringValue, "2.25.301")
        XCTAssertNil(try dataSet.element(at: try DicomTagPath(parsing: "00081115[1]/00081155")))
        XCTAssertThrowsError(try dataSet.element(at: try DicomTagPath(parsing: "00100010[0]/00081155"))) {
            XCTAssertEqual($0 as? DicomTagPathError, .notASequence(DicomTagPath(components: [.init(tag: 0x00100010, item: .index(0))])))
        }
        XCTAssertThrowsError(try dataSet.element(at: try DicomTagPath(parsing: "00081115[5]/00081155"))) {
            XCTAssertEqual($0 as? DicomTagPathError, .itemOutOfRange(DicomTagPath(components: [.init(tag: 0x00081115, item: .index(5))]), count: 2))
        }
        // Set deep inside an existing item, VR preserved, other items untouched.
        let edited = try dataSet.setting(element(0, .UI, ["2.25.999"]), at: try DicomTagPath(parsing: "00081115[0]/0008114A[1]/00081155"))
        XCTAssertEqual(try edited.elements(matching: try DicomTagPath(parsing: "00081115[*]/0008114A[*]/00081155")).map(\.element.stringValue), ["2.25.100", "2.25.999"])
        XCTAssertEqual(edited[0x00081115]?.sequenceItems[1], dataSet[0x00081115]?.sequenceItems[1])
        // Creating the next item on demand, refusing a gap.
        let grown = try dataSet.setting(element(0, .LO, ["new"]), at: try DicomTagPath(parsing: "00081115[2]/00080060"), creatingItems: true)
        XCTAssertEqual(grown[0x00081115]?.sequenceItems.count, 3)
        XCTAssertEqual(grown[0x00081115]?.sequenceItems[2][0x00080060]?.stringValue, "new")
        XCTAssertThrowsError(try dataSet.setting(element(0, .LO, ["new"]), at: try DicomTagPath(parsing: "00081115[4]/00080060"), creatingItems: true))
        XCTAssertThrowsError(try dataSet.setting(element(0, .LO, ["new"]), at: try DicomTagPath(parsing: "00081115[2]/00080060")))
        let created = try DicomDataSet().setting(element(0, .LO, ["x"]), at: try DicomTagPath(parsing: "00081115[0]/00080060"), creatingItems: true)
        XCTAssertEqual(created[0x00081115]?.vr, .SQ)
        // Remove an element, then a whole item; wildcards are refused for mutations.
        let removed = try dataSet.removing(at: try DicomTagPath(parsing: "00081115[0]/0008114A[0]/00081155"))
        XCTAssertNil(removed[0x00081115]?.sequenceItems[0][0x0008114A]?.sequenceItems[0][0x00081155])
        let dropped = try dataSet.removing(at: try DicomTagPath(parsing: "00081115[0]"))
        XCTAssertEqual(dropped[0x00081115]?.sequenceItems.map { $0[0x0020000E]?.stringValue }, ["2.25.301"])
        XCTAssertEqual(try dataSet.removing(at: try DicomTagPath(parsing: "00081115[0]/0008114A[0]")).removing(at: try DicomTagPath(parsing: "00081115[0]/0008114A[0]"))[0x00081115]?.sequenceItems[0][0x0008114A]?.value, .empty)
        XCTAssertThrowsError(try dataSet.removing(at: try DicomTagPath(parsing: "00081115[*]/0020000E")))
        XCTAssertEqual(try dataSet.removing(at: DicomTagPath(0x00990010)), dataSet)
    }

    // MARK: - Diff

    func test_attributeTagStrings_compareAsHexadecimalWhileOtherIntegersStayDecimal() {
        let tags = DicomDataSet(elements: [.init(tag: 0x00280009, vr: .AT, value: .strings(["00100010", "001800A0"]))])
        let numbers = DicomDataSet(elements: [.init(tag: 0x00280009, vr: .AT, value: .unsignedIntegers([0x00100010, 0x001800A0]))])
        XCTAssertTrue(DicomDataSetDiff.compare(tags, numbers).isEmpty)
        let decimal = DicomDataSet(elements: [.init(tag: 0x00200013, vr: .IS, value: .strings(["10"]))])
        let ten = DicomDataSet(elements: [.init(tag: 0x00200013, vr: .IS, value: .signedIntegers([10]))])
        XCTAssertTrue(DicomDataSetDiff.compare(decimal, ten).isEmpty)
    }



    func test_missingIntermediateItemSelector_isRejected() throws {
        let path = DicomTagPath(components: [.init(tag: 0x00081115), .init(tag: 0x0020000E)])
        XCTAssertThrowsError(try nested().element(at: path)) {
            XCTAssertEqual($0 as? DicomTagPathError, .missingItemIndex(DicomTagPath(0x00081115)))
        }
    }

    func test_diff_handlesUnsignedValuesBeyondIntMax() {
        let before = DicomDataSet(elements: [.init(tag: 0x00091004, vr: .UV, value: .unsignedIntegers([UInt.max]))])
        let after = DicomDataSet(elements: [.init(tag: 0x00091004, vr: .UV, value: .unsignedIntegers([UInt.max - 1]))])
        XCTAssertTrue(DicomDataSetDiff.compare(before, before).isEmpty)
        let text = DicomDataSet(elements: [.init(tag: 0x00091004, vr: .UV, value: .strings([String(UInt.max)]))])
        XCTAssertTrue(DicomDataSetDiff.compare(before, text).isEmpty)
        XCTAssertTrue(DicomDataSetDiff.compare(text, before).isEmpty)
        XCTAssertEqual(DicomDataSetDiff.compare(before, after).changes.count, 1)
        let small = DicomDataSet(elements: [.init(tag: 0x00091004, vr: .UV, value: .unsignedIntegers([42]))])
        let signed = DicomDataSet(elements: [.init(tag: 0x00091004, vr: .UV, value: .signedIntegers([42]))])
        XCTAssertTrue(DicomDataSetDiff.compare(small, signed).isEmpty)
    }

    func test_diff_unsignedTextDoesNotFallBackToSignedParsing() {
        for vr in [DicomVR.US, .UL, .UV] {
            let text = DicomDataSet(elements: [.init(tag: 0x00091004, vr: vr, value: .strings(["-1"]))])
            let signed = DicomDataSet(elements: [.init(tag: 0x00091004, vr: vr, value: .signedIntegers([-1]))])
            XCTAssertFalse(DicomDataSetDiff.compare(text, signed).isEmpty)
        }
    }

    func test_uidReplacement_rejectsNonASCIIDigitsAndPreviouslyReplacedKeys() throws {
        for uid in ["2.25.١", "2.25.１", "2.25.²", "2..3", "2.01"] {
            XCTAssertFalse(DicomDataSetEditor.isValidUID(uid), uid)
        }
        XCTAssertTrue(DicomDataSetEditor.isValidUID("2.25.0"))
        let plan = DicomDataSetEdit(operations: [
            .replaceUID(old: "2.25.100", new: "2.25.110"),
            .replaceUID(old: "2.25.200", new: "2.25.100")
        ])
        XCTAssertThrowsError(try DicomDataSetEditor.apply(plan, to: nested())) {
            XCTAssertEqual($0 as? DicomDataSetEditError, .invalidReplacementUID("2.25.100"))
        }
    }

    func test_diff_reportsNestedChangesAndHonoursOptions() throws {
        let before = nested()
        var after = try before.setting(element(0, .UI, ["2.25.999"]), at: try DicomTagPath(parsing: "00081115[0]/0008114A[1]/00081155"))
        after = try after.removing(at: try DicomTagPath(parsing: "00081115[1]"))
        after.set(element(0x00100010, .PN, ["Edit^Case "]))
        after.set(element(0x00100020, .LO, ["ID"]))
        after.set(DicomDataElement(tag: 0x00200052, vr: .LO, value: .strings(["2.25.400"])))
        after.set(element(0x00020010, .UI, ["1.2.840.10008.1.2"]))
        after.remove(0x30060010)
        let diff = DicomDataSetDiff.compare(before, after)
        XCTAssertEqual(diff.changes.map { "\($0.kind.rawValue) \($0.path)" }, [
            "itemCountChanged (0008,1115)",
            "valueChanged (0008,1115)[0]/(0008,114A)[1]/(0008,1155)",
            "added (0010,0020)",
            "vrChanged (0020,0052)",
            "removed (3006,0010)"
        ])
        XCTAssertEqual(diff.changes[1].description, "~ (0008,1115)[0]/(0008,114A)[1]/(0008,1155) UI 2.25.101 -> 2.25.999")
        // Padding is a representation detail unless normalisation is off; file meta is ignored unless asked.
        XCTAssertTrue(DicomDataSetDiff.compare(before, after, options: .init(normalizesText: false)).changes.contains { $0.path == DicomTagPath(.patientName) })
        XCTAssertTrue(DicomDataSetDiff.compare(before, after, options: .init(ignoresFileMeta: false)).changes.contains { $0.path == DicomTagPath(0x00020010) })
        let noUIDs = DicomDataSetDiff.compare(before, after, options: .init(ignoresUIDs: true))
        XCTAssertFalse(noUIDs.changes.contains { $0.kind == .valueChanged })
        XCTAssertTrue(DicomDataSetDiff.compare(before, before).isEmpty)
        XCTAssertTrue(DicomDataSetDiff.compare(DicomDataSet(elements: [DicomDataElement(tag: 0x00081115, vr: .SQ, value: .sequence([]))]),
                                               DicomDataSet(elements: [DicomDataElement(tag: 0x00081115, vr: .SQ, value: .empty)])).isEmpty)
    }

    // MARK: - Editor

    func test_editor_replacesIdentityEverywhereAndRefusesUnsafeEdits() throws {
        let source = nested()
        var counter = 0
        let result = try DicomDataSetEditor.apply(.init(operations: [
            .regenerateUID(.frameOfReference),
            .replaceUID(old: "2.25.100", new: "2.25.110"),
            .set(DicomTagPath(.patientName), element(0, .PN, ["Renamed^Case"])),
            .set(try DicomTagPath(parsing: "00081115[1]/00080060"), element(0, .CS, ["OT"])),
            .remove(try DicomTagPath(parsing: "00081115[0]/0008114A[1]"))
        ]), to: source, makeUID: { counter += 1; return "2.25.5000\(counter)" })
        XCTAssertEqual(result.uidReplacements, ["2.25.400": "2.25.50001", "2.25.100": "2.25.110"])
        XCTAssertEqual(result.dataSet.string(for: .frameOfReferenceUID), "2.25.50001")
        XCTAssertEqual(result.dataSet[0x30060010]?.sequenceItems[0][0x00200052]?.stringValue, "2.25.50001")
        XCTAssertEqual(result.dataSet.string(for: .sopInstanceUID), "2.25.110")
        XCTAssertEqual(try result.dataSet.elements(matching: try DicomTagPath(parsing: "00081115[*]/0008114A[*]/00081155")).map(\.element.stringValue), ["2.25.110"])
        XCTAssertEqual(DicomDataSetEditor.uidValues(in: result.dataSet).contains("2.25.400"), false)
        XCTAssertEqual(result.diff.changes.count, 7, "\(result.diff.changes)")
        // Chained replacement maps the original to the final value.
        let chained = try DicomDataSetEditor.apply(.init(operations: [.replaceUID(old: "2.25.300", new: "2.25.310"), .replaceUID(old: "2.25.310", new: "2.25.320")]), to: source)
        XCTAssertEqual(chained.uidReplacements, ["2.25.300": "2.25.320"])
        XCTAssertEqual(chained.dataSet[0x00081115]?.sequenceItems[0][0x0020000E]?.stringValue, "2.25.320")

        func failure(_ operation: DicomDataSetEdit.Operation) -> DicomDataSetEditError? {
            do { _ = try DicomDataSetEditor.apply(.init(operations: [operation]), to: source); return nil } catch { return error as? DicomDataSetEditError }
        }
        XCTAssertEqual(failure(.set(DicomTagPath(.sopInstanceUID), element(0, .UI, ["2.25.1"]))), .identityRequiresReplacement(DicomTagPath(.sopInstanceUID)))
        for tag in [DicomTag.sopInstanceUID, .studyInstanceUID, .seriesInstanceUID, .frameOfReferenceUID] {
            let path = DicomTagPath(tag)
            XCTAssertEqual(failure(.set(path, element(0, .LO, ["2.25.1"]))), .identityRequiresReplacement(path))
        }
        XCTAssertEqual(failure(.remove(DicomTagPath(.studyInstanceUID))), .identityRequiresReplacement(DicomTagPath(.studyInstanceUID)))
        XCTAssertEqual(failure(.set(DicomTagPath(.rows), DicomDataElement(tag: 0, vr: .US, value: .unsignedIntegers([1])))), .protectedElement(DicomTagPath(.rows)))
        XCTAssertEqual(failure(.remove(DicomTagPath(0x00020010))), .protectedElement(DicomTagPath(0x00020010)))
        XCTAssertEqual(failure(.replaceUID(old: "2.25.7", new: "2.25.8")), .uidNotPresent("2.25.7"))
        XCTAssertEqual(failure(.replaceUID(old: "2.25.100", new: "2.25.200")), .invalidReplacementUID("2.25.200"))
        XCTAssertEqual(failure(.replaceUID(old: "2.25.100", new: "not a uid")), .invalidReplacementUID("not a uid"))
        XCTAssertEqual(failure(.regenerateUID(.instance)), nil)
        XCTAssertEqual(failure(.set(DicomTagPath(.patientName), element(0, .PN, ["Ünïcode^Case"]))), .unrepresentableText(DicomTagPath(.patientName)))
        XCTAssertEqual(failure(.set(try DicomTagPath(parsing: "00100010[0]/00080060"), element(0, .CS, ["OT"]))),
                       .path(.notASequence(DicomTagPath(components: [.init(tag: 0x00100010, item: .index(0))]))))
        var utf8 = source
        utf8.set(element(0x00080005, .CS, ["ISO_IR 192"]))
        XCTAssertNoThrow(try DicomDataSetEditor.apply(.init(operations: [.set(DicomTagPath(.patientName), element(0, .PN, ["Ünïcode^Case"]))]), to: utf8))
        XCTAssertEqual(failure(.regenerateUID(.instance)), nil)
        XCTAssertEqual((try? DicomDataSetEditor.apply(.init(operations: [.regenerateUID(.frameOfReference)]), to: DicomDataSet(elements: [element(0x00080018, .UI, ["2.25.1"])])))?.dataSet, nil)
    }

    func test_editor_appliesToPart10ThroughTheValidatedRewriter() throws {
        let pixels = Data((0..<12).map { UInt8($0) })
        var dataSet = DicomSecondaryCaptureBuilder.dataSet(
            pixelData: try .rgb8(columns: 2, rows: 2, data: pixels),
            options: .init(sopInstanceUID: "2.25.23249901", studyInstanceUID: "2.25.23249902", seriesInstanceUID: "2.25.23249903",
                           patientName: "Edit^Case", patientID: "E-1", seriesNumber: 1, instanceNumber: 1),
            requiredType2Attributes: .init())
        dataSet.set(DicomDataElement(tag: 0x00082112, vr: .SQ, value: .sequence([item([element(0x00081150, .UI, ["1.2.840.10008.5.1.4.1.1.7"]), element(0x00081155, .UI, ["2.25.23249901"])])])))
        dataSet.set(element(0x00081030, .LO, ["Study"]))
        let part10 = try DicomDataSetWriter.part10Data(from: dataSet)
        var counter = 0
        let (result, edit) = try DicomDataSetEditor.apply(.init(operations: [
            .regenerateUID(.instance),
            .set(DicomTagPath(.patientName), element(0, .PN, ["Edited^Case"])),
            .set(try DicomTagPath(parsing: "00082112[0]/00081160"), DicomDataElement(tag: 0, vr: .IS, value: .strings(["1"]))),
            .remove(DicomTagPath(0x00081030))
        ]), toPart10: part10, makeUID: { counter += 1; return "2.25.9900\(counter)" })
        XCTAssertEqual(edit.uidReplacements, ["2.25.23249901": "2.25.99001"])
        let reopened = try DCMDecoder(data: result.fileData)
        XCTAssertEqual(reopened.info(for: 0x00020003), "2.25.99001")
        XCTAssertEqual(reopened.info(for: .sopInstanceUID), "2.25.99001")
        XCTAssertEqual(reopened.info(for: .patientName), "Edited^Case")
        XCTAssertEqual(reopened.dataSet[0x00082112]?.sequenceItems[0][0x00081155]?.stringValue, "2.25.99001")
        XCTAssertEqual(reopened.dataSet[0x00082112]?.sequenceItems[0][0x00081160]?.stringValue, "1")
        XCTAssertFalse(reopened.dataSet.contains(0x00081030))
        XCTAssertEqual(try DicomPart10PixelDataPreserver.dataSet(from: reopened).element(for: .pixelData)?.bytesValue, pixels)
        XCTAssertEqual(reopened.info(for: .transferSyntaxUID), "1.2.840.10008.1.2.1")
        // The rewriter refuses to drop an identity UID or a pixel-structure element even when asked directly.
        XCTAssertThrowsError(try DicomPart10Rewriter().rewrite(part10, removing: [DicomTag.sopInstanceUID.rawValue]))
        XCTAssertThrowsError(try DicomPart10Rewriter().rewrite(part10, removing: [DicomTag.rows.rawValue]))
        XCTAssertFalse(try DicomPart10Rewriter().rewrite(part10, removing: [0x00081030]).dataSet.contains(0x00081030))
        // Unchanged plan: byte-identical data set on reopen, no replacements.
        let untouched = try DicomDataSetEditor.apply(.init(), toPart10: part10)
        XCTAssertTrue(untouched.edit.uidReplacements.isEmpty)
        let reread = try DicomPart10PixelDataPreserver.dataSet(from: try DCMDecoder(data: untouched.result.fileData))
        XCTAssertTrue(DicomDataSetDiff.compare(dataSet, reread).isEmpty, "\(DicomDataSetDiff.compare(dataSet, reread).changes) \(String(describing: dataSet[0x00280002]?.value)) vs \(String(describing: reread[0x00280002]?.value))")
        XCTAssertFalse(DicomDataSetEditor.isValidUID("1.2.03"))
        XCTAssertTrue(DicomDataSetEditor.isValidUID("1.2.0.3"))
    }
}
