//
//  main.swift
//  MetalBenchmark
//
//  CLI entry point for DICOM windowing performance benchmarking. Compares Metal GPU vs vDSP CPU
//  performance with configurable parameters.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import Foundation

// MARK: - Argument Parsing

/// Print usage information
func printUsage() {
    print("""
    MetalBenchmark - DICOM Windowing Performance Tool

    USAGE:
        MetalBenchmark [OPTIONS]

    OPTIONS:
        --iterations, -n <count>    Number of benchmark iterations (default: 100)
        --size <pixels>             Image size (width x height) (default: 512)
        --verbose, -v               Enable verbose per-iteration output
        --help, -h                  Show this help message

    EXAMPLES:
        MetalBenchmark
        MetalBenchmark --iterations 200 --size 1024
        MetalBenchmark -n 100 -v

    DESCRIPTION:
        Benchmarks Metal GPU windowing performance against vDSP CPU baseline.
        Uses realistic DICOM-like test data to measure performance across
        multiple iterations, reporting mean time, standard deviation, and
        speedup ratio.

        The tool validates that Metal GPU achieves ≥3.00x speedup compared
        to the vDSP ARM NEON assembly baseline.

    """)
}

/// Parse command-line arguments into benchmark configuration
func parseArguments() -> BenchmarkConfig? {
    var config = BenchmarkConfig()
    let args = CommandLine.arguments

    var i = 1
    while i < args.count {
        let arg = args[i]

        switch arg {
        case "--help", "-h":
            printUsage()
            return nil

        case "--iterations", "-n":
            guard i + 1 < args.count else {
                print("Error: --iterations requires a value")
                printUsage()
                return nil
            }
            i += 1
            guard let iterations = Int(args[i]), iterations > 0 else {
                print("Error: --iterations must be a positive integer")
                return nil
            }
            config.benchmarkIterations = iterations

        case "--size":
            guard i + 1 < args.count else {
                print("Error: --size requires a value")
                printUsage()
                return nil
            }
            i += 1
            guard let size = Int(args[i]), size > 0 else {
                print("Error: --size must be a positive integer")
                return nil
            }
            config.imageWidth = size
            config.imageHeight = size

        case "--verbose", "-v":
            config.verbose = true

        default:
            print("Error: Unknown option '\(arg)'")
            printUsage()
            return nil
        }

        i += 1
    }

    return config
}

// MARK: - Main Execution

/// Main entry point
func main() {
    print("╔══════════════════════════════════════════════════════════════════╗")
    print("║     MetalBenchmark - DICOM Windowing Performance Tool           ║")
    print("╚══════════════════════════════════════════════════════════════════╝")
    print()

    // Parse arguments
    guard let config = parseArguments() else {
        // Help was shown or error occurred
        exit(args.contains("--help") || args.contains("-h") ? 0 : 1)
    }

    // Create and run benchmark
    let runner = BenchmarkRunner(config: config)
    let (metalResult, vdspResult) = runner.runFullBenchmark()

    // Determine exit code based on results
    if let metalResult = metalResult {
        let speedup = vdspResult.meanTime / metalResult.meanTime
        if speedup >= 3.0 {
            print("\n✓ SUCCESS: Metal achieves ≥3.00x speedup target")
            exit(0)
        } else {
            print("\n✗ FAILURE: Metal speedup below 3.00x target")
            exit(1)
        }
    } else {
        print("\n⚠ WARNING: Metal not available, cannot validate speedup target")
        print("vDSP benchmark completed successfully")
        exit(2)
    }
}

// Run main
let args = CommandLine.arguments
main()
