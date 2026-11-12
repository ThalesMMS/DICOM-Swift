//
//  GenerateSampleReports.swift
//  DicomCoreTests
//
//  Demonstration script to generate sample benchmark reports. Run this to see example JSON and
//  Markdown output from BenchmarkReporter.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation
@testable import DicomCore

/// Generate and display sample benchmark reports
func generateSampleReports() {
    print("Generating Sample Benchmark Reports\n")
    print("=" + String(repeating: "=", count: 70))

    // Create sample configuration
    let config = BenchmarkConfig(
        warmupIterations: 20,
        benchmarkIterations: 100,
        imageWidth: 1024,
        imageHeight: 1024,
        windowCenter: 2048.0,
        windowWidth: 4096.0
    )

    // Create sample timings (simulating real benchmark results)
    let lockTimings = (0..<100).map { _ in 0.000001 + Double.random(in: -0.0000002...0.0000002) }
    let initTimings = (0..<100).map { _ in 0.0001 + Double.random(in: -0.00002...0.00002) }
    let validationTimings = (0..<100).map { _ in 0.00005 + Double.random(in: -0.00001...0.00001) }
    let metadataTimings = (0..<100).map { _ in 0.000002 + Double.random(in: -0.0000004...0.0000004) }
    let vdspTimings = (0..<100).map { _ in 0.00867 + Double.random(in: -0.0005...0.0005) }
    let metalTimings = (0..<100).map { _ in 0.00220 + Double.random(in: -0.0002...0.0002) }

    // Build results dictionary
    var results: [BenchmarkType: BenchmarkResult] = [:]

    do {
        results[.lockOverhead] = try BenchmarkResult(timings: lockTimings)
        results[.decoderInit] = try BenchmarkResult(timings: initTimings)
        results[.decoderValidation] = try BenchmarkResult(timings: validationTimings)
        results[.metadataAccess] = try BenchmarkResult(timings: metadataTimings)
        results[.windowingVDSP] = try BenchmarkResult(timings: vdspTimings)
        results[.windowingMetal] = try BenchmarkResult(timings: metalTimings)

        let suiteResult = BenchmarkSuiteResult(results: results, config: config)
        let reporter = BenchmarkReporter(suiteResult: suiteResult)

        // Generate Markdown Report
        print("\n\nMARKDOWN REPORT")
        print(String(repeating: "=", count: 72))
        let markdown = reporter.generateMarkdown()
        print(markdown)

        // Generate JSON Report (compact version for display)
        print("\n\nJSON REPORT (Compact)")
        print(String(repeating: "=", count: 72))
        let compactJSON = try reporter.generateJSON(prettyPrinted: false)
        // Show first 500 characters for brevity
        let preview = String(compactJSON.prefix(500))
        print(preview)
        if compactJSON.count > 500 {
            print("... (\(compactJSON.count - 500) more characters)")
        }

        // Generate JSON Report (pretty printed snippet)
        print("\n\nJSON REPORT (Pretty Printed Snippet)")
        print(String(repeating: "=", count: 72))
        let prettyJSON = try reporter.generateJSON(prettyPrinted: true)
        let prettyLines = prettyJSON.components(separatedBy: "\n")
        let snippet = prettyLines.prefix(30).joined(separator: "\n")
        print(snippet)
        if prettyLines.count > 30 {
            print("... (\(prettyLines.count - 30) more lines)")
        }

        print("\n" + String(repeating: "=", count: 72))
        print("✅ Sample reports generated successfully!")

    } catch {
        print("❌ Error generating sample reports: \(error)")
    }
}

// Uncomment to run as standalone script:
// generateSampleReports()
