import Foundation
import XCTest
@testable import DicomCore

final class DicomStructuredReportBenchmarkTests: XCTestCase {
    func test_releaseWideReferenceTraversal_completesWithinBudget() throws {
        try requireBenchmark()
        #if DEBUG
        XCTFail("The SR traversal benchmark must run with -c release.")
        #else
        let width = 5_000
        let iterations = benchmarkIterations
        let children = (0..<width).map { index in
            DicomSRContentItem(
                valueType: "IMAGE",
                referencedSOPs: [sourceReference(index: index)]
            )
        }
        let root = DicomSRContentItem(valueType: "CONTAINER", children: children)
        let expected = legacyReferences(in: root)
        let actual = root.allSourceImageReferences
        XCTAssertEqual(actual, expected)
        let expectedChecksum = checksum(references: expected)
        XCTAssertEqual(checksum(references: actual), expectedChecksum)

        let samples = benchmark(
            iterations: iterations,
            expectedChecksum: expectedChecksum,
            checksum: { self.checksum(references: $0) },
            legacy: { self.legacyReferences(in: root) },
            production: { root.allSourceImageReferences }
        )
        printReport(
            mode: "wide-references",
            sizeName: "width",
            size: width,
            iterations: iterations,
            checksum: expectedChecksum,
            samples: samples
        )
        #endif
    }

    func test_releaseNestedNumericExtraction() throws {
        try requireBenchmark()
        #if DEBUG
        XCTFail("The SR traversal benchmark must run with -c release.")
        #else
        let depth = 8
        let iterations = benchmarkIterations
        let root = nestedNumericRoot(depth: depth)
        let expected = legacyMeasurements(in: root)
        let actual = DicomSRDocument(root: root).measurements
        XCTAssertEqual(actual, expected)
        let expectedChecksum = checksum(measurements: expected)
        XCTAssertEqual(checksum(measurements: actual), expectedChecksum)

        let samples = benchmark(
            iterations: iterations,
            expectedChecksum: expectedChecksum,
            checksum: { self.checksum(measurements: $0) },
            legacy: { self.legacyMeasurements(in: root) },
            production: { DicomSRDocument(root: root).measurements }
        )
        printReport(
            mode: "num-extraction",
            sizeName: "depth",
            size: depth,
            iterations: iterations,
            checksum: expectedChecksum,
            samples: samples
        )
        #endif
    }

    func test_releaseNestedCADExtraction() throws {
        try requireBenchmark()
        #if DEBUG
        XCTFail("The SR traversal benchmark must run with -c release.")
        #else
        let depth = 128
        let iterations = benchmarkIterations
        let root = nestedCADRoot(depth: depth)
        let expected = legacyCADFindings(in: root)
        let actual = DicomSRDocument(root: root).cadFindings
        XCTAssertEqual(actual, expected)
        let expectedChecksum = checksum(findings: expected)
        XCTAssertEqual(checksum(findings: actual), expectedChecksum)

        let samples = benchmark(
            iterations: iterations,
            expectedChecksum: expectedChecksum,
            checksum: { self.checksum(findings: $0) },
            legacy: { self.legacyCADFindings(in: root) },
            production: { DicomSRDocument(root: root).cadFindings }
        )
        printReport(
            mode: "cad-extraction",
            sizeName: "depth",
            size: depth,
            iterations: iterations,
            checksum: expectedChecksum,
            samples: samples
        )
        #endif
    }

    func test_releaseDeepTreeOperations() throws {
        try requireBenchmark()
        #if DEBUG
        XCTFail("The SR traversal benchmark must run with -c release.")
        #else
        let depth = 1_000
        let iterations = benchmarkIterations
        let root = deepOperationsRoot(depth: depth)
        let document = DicomSRDocument(
            sopClassUID: DicomSRDocument.comprehensiveSRStorageSOPClassUID,
            templateIdentifier: "1500",
            root: root
        )
        let dataSet = DicomStructuredReportBuilder.contentItemDataSet(root)
        let parsed = try XCTUnwrap(DicomSRParser.contentItem(from: dataSet))
        XCTAssertEqual(parsed, root)
        XCTAssertTrue(DicomSRSemanticValidator.validate(document).isValid)
        XCTAssertTrue(root == parsed)

        let parserChecksum = checksum(contentItem: root)
        let builderChecksum = checksum(dataSet: dataSet)
        let validatorChecksum = checksum(validation: DicomSRSemanticValidator.validate(document))
        let equalityChecksum = checksum(equality: true)
        _ = DicomSRParser.contentItem(from: dataSet)
        _ = DicomStructuredReportBuilder.contentItemDataSet(root)
        _ = DicomSRSemanticValidator.validate(document)
        _ = root == parsed

        var parserSamples: [Double] = []
        var builderSamples: [Double] = []
        var validatorSamples: [Double] = []
        var equalitySamples: [Double] = []
        for _ in 0..<iterations {
            let parserSample = measureMilliseconds(
                { DicomSRParser.contentItem(from: dataSet) },
                checksum: { item in item.map { self.checksum(contentItem: $0) } ?? 0 }
            )
            XCTAssertEqual(parserSample.checksum, parserChecksum)
            parserSamples.append(parserSample.milliseconds)

            let builderSample = measureMilliseconds(
                { DicomStructuredReportBuilder.contentItemDataSet(root) },
                checksum: { self.checksum(dataSet: $0) }
            )
            XCTAssertEqual(builderSample.checksum, builderChecksum)
            builderSamples.append(builderSample.milliseconds)

            let validatorSample = measureMilliseconds(
                { DicomSRSemanticValidator.validate(document) },
                checksum: { self.checksum(validation: $0) }
            )
            XCTAssertEqual(validatorSample.checksum, validatorChecksum)
            validatorSamples.append(validatorSample.milliseconds)

            let equalitySample = measureMilliseconds(
                { root == parsed },
                checksum: { self.checksum(equality: $0) }
            )
            XCTAssertEqual(equalitySample.checksum, equalityChecksum)
            equalitySamples.append(equalitySample.milliseconds)
        }

        var combinedChecksum = StableChecksum()
        combinedChecksum.combine(parserChecksum)
        combinedChecksum.combine(builderChecksum)
        combinedChecksum.combine(validatorChecksum)
        combinedChecksum.combine(equalityChecksum)
        printDeepOperationsReport(
            depth: depth,
            iterations: iterations,
            checksum: combinedChecksum.value,
            parser: parserSamples,
            builder: builderSamples,
            validator: validatorSamples,
            equality: equalitySamples
        )
        #endif
    }

    private var benchmarkIterations: Int {
        max(
            Int(ProcessInfo.processInfo.environment["DICOM_SR_TRAVERSAL_BENCHMARK_ITERATIONS"] ?? "") ?? 7,
            1
        )
    }

    private func requireBenchmark() throws {
        guard ProcessInfo.processInfo.environment["DICOM_SR_TRAVERSAL_BENCHMARK"] == "1" else {
            throw XCTSkip("Set DICOM_SR_TRAVERSAL_BENCHMARK=1 to run the SR traversal benchmark.")
        }
    }

    private func nestedNumericRoot(depth: Int) -> DicomSRContentItem {
        precondition(depth > 0)
        let reference = sourceReference(index: 1)
        var item = DicomSRContentItem(
            relationshipType: "INFERRED FROM",
            valueType: "SCOORD",
            graphicType: "POINT",
            graphicData: [16, 24],
            children: [
                DicomSRContentItem(
                    relationshipType: "SELECTED FROM",
                    valueType: "IMAGE",
                    referencedSOPs: [reference]
                )
            ]
        )
        for index in (0..<depth).reversed() {
            item = DicomSRContentItem(
                relationshipType: "CONTAINS",
                valueType: "NUM",
                numericValue: Double(index),
                trackingID: "synthetic-num-\(index)",
                children: [item]
            )
        }
        return DicomSRContentItem(valueType: "CONTAINER", children: [item])
    }

    private func deepOperationsRoot(depth: Int) -> DicomSRContentItem {
        precondition(depth >= 2)
        let observationConcept = DicomCodedConcept(
            codeValue: "121071",
            codingSchemeDesignator: "DCM",
            codeMeaning: "Finding"
        )
        var item = DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "TEXT",
            conceptName: observationConcept,
            textValue: "synthetic-deep-leaf"
        )
        for _ in 0..<(depth - 2) {
            item = DicomSRContentItem(
                relationshipType: "CONTAINS",
                valueType: "CONTAINER",
                conceptName: observationConcept,
                children: [item]
            )
        }
        return DicomSRContentItem(
            valueType: "CONTAINER",
            conceptName: DicomCodedConcept(
                codeValue: "126000",
                codingSchemeDesignator: "DCM",
                codeMeaning: "Imaging Measurement Report"
            ),
            children: [item]
        )
    }

    private func nestedCADRoot(depth: Int) -> DicomSRContentItem {
        precondition(depth > 0)
        let reference = sourceReference(index: 2)
        let region = DicomSRContentItem(
            relationshipType: "INFERRED FROM",
            valueType: "SCOORD",
            graphicType: "POINT",
            graphicData: [32, 48],
            children: [
                DicomSRContentItem(
                    relationshipType: "SELECTED FROM",
                    valueType: "IMAGE",
                    referencedSOPs: [reference]
                )
            ]
        )
        var item = DicomSRContentItem(
            relationshipType: "CONTAINS",
            valueType: "NUM",
            numericValue: 42,
            trackingID: "synthetic-cad-measurement",
            children: [region]
        )
        let findingConcept = DicomCodedConcept(
            codeValue: "111001",
            codingSchemeDesignator: "DCM",
            codeMeaning: "CAD Finding"
        )
        for index in (0..<depth).reversed() {
            item = DicomSRContentItem(
                relationshipType: "CONTAINS",
                valueType: "CONTAINER",
                conceptName: findingConcept,
                trackingID: "synthetic-cad-\(index)",
                children: [item]
            )
        }
        return DicomSRContentItem(valueType: "CONTAINER", children: [item])
    }

    private func sourceReference(index: Int) -> DicomSourceImageReference {
        DicomSourceImageReference(
            referencedSOPClassUID: "1.2.840.10008.5.1.4.1.1.2",
            referencedSOPInstanceUID: "2.25.synthetic-benchmark-\(index)",
            referencedFrameNumbers: [index + 1]
        )
    }

    private func legacyMeasurements(in item: DicomSRContentItem) -> [DicomSRMeasurement] {
        var result: [DicomSRMeasurement] = []
        if item.valueType == "NUM", let value = item.numericValue {
            result.append(DicomSRMeasurement(
                name: item.conceptName,
                value: value,
                units: item.measurementUnits,
                trackingID: item.trackingID,
                trackingUID: item.trackingUID,
                sourceImageReferences: legacyReferences(in: item),
                roi: legacyFirstGraphicRegion(in: item)
            ))
        }
        result.append(contentsOf: item.children.flatMap(legacyMeasurements))
        return result
    }

    private func legacyCADFindings(in item: DicomSRContentItem) -> [DicomSRCADFinding] {
        var result: [DicomSRCADFinding] = []
        if item.valueType == "CONTAINER", legacyIsCADFinding(item) {
            result.append(DicomSRCADFinding(
                title: item.conceptName,
                trackingID: item.trackingID,
                trackingUID: item.trackingUID,
                sourceImageReferences: legacyReferences(in: item),
                measurements: legacyMeasurements(in: item),
                contentItem: item
            ))
        }
        result.append(contentsOf: item.children.flatMap(legacyCADFindings))
        return result
    }

    private func legacyFirstGraphicRegion(in item: DicomSRContentItem) -> DicomSRGraphicRegion? {
        if item.valueType == "SCOORD", let graphicType = item.graphicType, !item.graphicData.isEmpty {
            return DicomSRGraphicRegion(
                graphicType: graphicType,
                graphicData: item.graphicData,
                sourceImageReferences: legacyReferences(in: item)
            )
        }
        return item.children.lazy.compactMap(legacyFirstGraphicRegion).first
    }

    private func legacyIsCADFinding(_ item: DicomSRContentItem) -> Bool {
        let haystack = [
            item.conceptName?.codeMeaning,
            item.conceptName?.codeValue,
            item.trackingID
        ].compactMap { $0?.uppercased() }.joined(separator: " ")
        return haystack.contains("CAD") || haystack.contains("FINDING")
    }

    private func legacyReferences(in item: DicomSRContentItem) -> [DicomSourceImageReference] {
        let references = item.referencedSOPs + item.children.flatMap(legacyReferences)
        var result: [DicomSourceImageReference] = []
        for reference in references where !result.contains(reference) {
            result.append(reference)
        }
        return result
    }

    private func benchmark<Output>(
        iterations: Int,
        expectedChecksum: UInt64,
        checksum: (Output) -> UInt64,
        legacy: () -> Output,
        production: () -> Output
    ) -> BenchmarkSamples {
        XCTAssertEqual(checksum(legacy()), expectedChecksum)
        XCTAssertEqual(checksum(production()), expectedChecksum)
        var legacySamples: [Double] = []
        var productionSamples: [Double] = []
        legacySamples.reserveCapacity(iterations)
        productionSamples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let legacySample = measureMilliseconds(legacy, checksum: checksum)
            XCTAssertEqual(legacySample.checksum, expectedChecksum)
            legacySamples.append(legacySample.milliseconds)
            let productionSample = measureMilliseconds(production, checksum: checksum)
            XCTAssertEqual(productionSample.checksum, expectedChecksum)
            productionSamples.append(productionSample.milliseconds)
        }
        return BenchmarkSamples(legacy: legacySamples, production: productionSamples)
    }

    private func printReport(
        mode: String,
        sizeName: String,
        size: Int,
        iterations: Int,
        checksum: UInt64,
        samples: BenchmarkSamples
    ) {
        let legacyP50 = percentile(samples.legacy, fraction: 0.50)
        let legacyP95 = percentile(samples.legacy, fraction: 0.95)
        let productionP50 = percentile(samples.production, fraction: 0.50)
        let productionP95 = percentile(samples.production, fraction: 0.95)
        print(
            "DICOM_SR_TRAVERSAL_BENCHMARK mode=\(mode) \(sizeName)=\(size) iterations=\(iterations) " +
                String(
                    format: "legacy_p50_ms=%.3f legacy_p95_ms=%.3f " +
                        "production_p50_ms=%.3f production_p95_ms=%.3f speedup=%.2fx ",
                    legacyP50,
                    legacyP95,
                    productionP50,
                    productionP95,
                    legacyP50 / productionP50
                ) + "checksum=\(String(checksum, radix: 16))"
        )
    }

    private func printDeepOperationsReport(
        depth: Int,
        iterations: Int,
        checksum: UInt64,
        parser: [Double],
        builder: [Double],
        validator: [Double],
        equality: [Double]
    ) {
        let metrics = [
            formattedMetrics(name: "parser", samples: parser),
            formattedMetrics(name: "builder", samples: builder),
            formattedMetrics(name: "validator", samples: validator),
            formattedMetrics(name: "equality", samples: equality)
        ].joined(separator: " ")
        print(
            "DICOM_SR_TRAVERSAL_BENCHMARK mode=deep-tree-operations depth=\(depth) " +
                "iterations=\(iterations) \(metrics) checksum=\(String(checksum, radix: 16))"
        )
    }

    private func formattedMetrics(name: String, samples: [Double]) -> String {
        String(
            format: "\(name)_p50_ms=%.3f \(name)_p95_ms=%.3f",
            percentile(samples, fraction: 0.50),
            percentile(samples, fraction: 0.95)
        )
    }

    private func measureMilliseconds<Output>(
        _ operation: () -> Output,
        checksum: (Output) -> UInt64
    ) -> TimedChecksum {
        let start = DispatchTime.now().uptimeNanoseconds
        let output = operation()
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return TimedChecksum(
            milliseconds: Double(elapsed) / 1_000_000,
            checksum: checksum(output)
        )
    }

    private func percentile(_ samples: [Double], fraction: Double) -> Double {
        let ordered = samples.sorted()
        let index = min(Int((Double(ordered.count - 1) * fraction).rounded(.up)), ordered.count - 1)
        return ordered[index]
    }

    private func checksum(references: [DicomSourceImageReference]) -> UInt64 {
        var checksum = StableChecksum()
        checksum.combine(references.count)
        for reference in references {
            combine(reference, into: &checksum)
        }
        return checksum.value
    }

    private func checksum(contentItem root: DicomSRContentItem) -> UInt64 {
        var checksum = StableChecksum()
        var pending = [root]
        while let item = pending.popLast() {
            checksum.combine(item.relationshipType)
            checksum.combine(item.valueType)
            combine(item.conceptName, into: &checksum)
            checksum.combine(item.continuityOfContent)
            checksum.combine(item.textValue)
            combine(item.codeValue, into: &checksum)
            checksum.combine(item.numericValue?.bitPattern ?? UInt64.max)
            combine(item.measurementUnits, into: &checksum)
            checksum.combine(item.dateTimeValue?.rawValue)
            checksum.combine(item.dateValue?.rawValue)
            checksum.combine(item.timeValue?.rawValue)
            checksum.combine(item.personNameValue?.rawValue)
            checksum.combine(item.uidValue)
            checksum.combine(item.referencedSOPs.count)
            for reference in item.referencedSOPs {
                combine(reference, into: &checksum)
            }
            checksum.combine(item.graphicType)
            for coordinate in item.graphicData {
                checksum.combine(coordinate.bitPattern)
            }
            checksum.combine(item.trackingID)
            checksum.combine(item.trackingUID)
            checksum.combine(item.children.count)
            pending.append(contentsOf: item.children.reversed())
        }
        return checksum.value
    }

    private func checksum(dataSet root: DicomDataSet) -> UInt64 {
        var checksum = StableChecksum()
        var pending = [root]
        while let dataSet = pending.popLast() {
            let elements = dataSet.elements
            checksum.combine(elements.count)
            for element in elements {
                checksum.combine(element.tag)
                checksum.combine(element.vr.rawValue)
                checksum.combine(element.name)
                switch element.value {
                case .empty:
                    checksum.combine(0)
                case .strings(let values):
                    checksum.combine(1)
                    checksum.combine(values.count)
                    for value in values {
                        checksum.combine(value)
                    }
                case .signedIntegers(let values):
                    checksum.combine(2)
                    checksum.combine(values.count)
                    for value in values {
                        checksum.combine(value)
                    }
                case .unsignedIntegers(let values):
                    checksum.combine(3)
                    checksum.combine(values.count)
                    for value in values {
                        checksum.combine(UInt64(value))
                    }
                case .floats(let values):
                    checksum.combine(4)
                    checksum.combine(values.count)
                    for value in values {
                        checksum.combine(value.bitPattern)
                    }
                case .bytes(let data):
                    checksum.combine(5)
                    checksum.combine(data.count)
                    for byte in data {
                        checksum.combine(UInt64(byte))
                    }
                case .sequence(let items):
                    checksum.combine(6)
                    checksum.combine(items.count)
                    pending.append(contentsOf: items.map(\.dataSet).reversed())
                }
            }
        }
        return checksum.value
    }

    private func checksum(validation: DicomSRSemanticValidationResult) -> UInt64 {
        var checksum = StableChecksum()
        checksum.combine(validation.isValid ? 1 : 0)
        checksum.combine(validation.errors.count)
        for error in validation.errors {
            checksum.combine(error.errorDescription)
        }
        return checksum.value
    }

    private func checksum(equality: Bool) -> UInt64 {
        var checksum = StableChecksum()
        checksum.combine(equality ? 1 : 0)
        return checksum.value
    }

    private func checksum(measurements: [DicomSRMeasurement]) -> UInt64 {
        var checksum = StableChecksum()
        checksum.combine(measurements.count)
        for measurement in measurements {
            checksum.combine(measurement.name?.codeValue)
            checksum.combine(measurement.value.bitPattern)
            checksum.combine(measurement.units?.codeValue)
            checksum.combine(measurement.trackingID)
            checksum.combine(measurement.trackingUID)
            checksum.combine(measurement.sourceImageReferences.count)
            for reference in measurement.sourceImageReferences {
                combine(reference, into: &checksum)
            }
            checksum.combine(measurement.roi?.graphicType)
            for coordinate in measurement.roi?.graphicData ?? [] {
                checksum.combine(coordinate.bitPattern)
            }
            for reference in measurement.roi?.sourceImageReferences ?? [] {
                combine(reference, into: &checksum)
            }
        }
        return checksum.value
    }

    private func checksum(findings: [DicomSRCADFinding]) -> UInt64 {
        var accumulator = StableChecksum()
        accumulator.combine(findings.count)
        for finding in findings {
            accumulator.combine(finding.title?.codeValue)
            accumulator.combine(finding.trackingID)
            accumulator.combine(finding.trackingUID)
            accumulator.combine(finding.sourceImageReferences.count)
            for reference in finding.sourceImageReferences {
                combine(reference, into: &accumulator)
            }
            accumulator.combine(checksum(measurements: finding.measurements))
        }
        return accumulator.value
    }

    private func combine(_ reference: DicomSourceImageReference, into checksum: inout StableChecksum) {
        checksum.combine(reference.referencedSOPClassUID)
        checksum.combine(reference.referencedSOPInstanceUID)
        checksum.combine(reference.referencedFrameNumbers.count)
        for frame in reference.referencedFrameNumbers {
            checksum.combine(UInt64(bitPattern: Int64(frame)))
        }
    }

    private func combine(_ concept: DicomCodedConcept?, into checksum: inout StableChecksum) {
        checksum.combine(concept?.codeValue)
        checksum.combine(concept?.codingSchemeDesignator)
        checksum.combine(concept?.codeMeaning)
    }
}

private struct BenchmarkSamples {
    let legacy: [Double]
    let production: [Double]
}

private struct TimedChecksum {
    let milliseconds: Double
    let checksum: UInt64
}

private struct StableChecksum {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ integer: Int) {
        combine(UInt64(bitPattern: Int64(integer)))
    }

    mutating func combine(_ integer: UInt64) {
        value ^= integer
        value &*= 0x0000_0100_0000_01b3
    }

    mutating func combine(_ string: String?) {
        guard let string else {
            combine(UInt64.max)
            return
        }
        combine(string.utf8.count)
        for byte in string.utf8 {
            combine(UInt64(byte))
        }
    }
}
