//
// J2KHTConformanceAPI.swift
// J2KSwift
//
// HTJ2K conformance and interoperability validation API.
//
// Extracted from J2KConformanceTesting.swift in v11.0.0: the
// ISO test-suite loader, platform-info reporter, and test-vector
// parser were removed as dead scaffolding; the externally-consumed
// validation surface (error metrics, test vectors, the conformance
// validator, the HTJ2K test-vector generator, the HTJ2K conformance
// test harness, and the HT interoperability validator) stays public
// and unchanged — DICOMKit's dicom-j2k / dicom-validate executables
// consume it.
//

import Foundation

// MARK: - Error Metrics

/// Calculates error metrics for comparing decoded images.
///
/// Implements standard image quality metrics used in JPEG 2000 conformance testing.
public struct J2KErrorMetrics: Sendable {
    /// Calculates Mean Squared Error (MSE) between two images.
    ///
    /// MSE is the average of the squared differences between corresponding pixels.
    ///
    /// - Parameters:
    ///   - reference: The reference image data.
    ///   - test: The test image data to compare.
    /// - Returns: The MSE value, or `nil` if images have different sizes.
    public static func meanSquaredError(
        reference: [Int32],
        test: [Int32]
    ) -> Double? {
        guard reference.count == test.count else {
            return nil
        }

        guard !reference.isEmpty else {
            return 0.0
        }

        var sum: Double = 0.0
        for i in 0..<reference.count {
            let diff = Double(reference[i] - test[i])
            sum += diff * diff
        }

        return sum / Double(reference.count)
    }

    /// Calculates Peak Signal-to-Noise Ratio (PSNR) between two images.
    ///
    /// PSNR is expressed in decibels (dB) and measures the ratio between
    /// the maximum possible signal power and the power of corrupting noise.
    ///
    /// - Parameters:
    ///   - reference: The reference image data.
    ///   - test: The test image data to compare.
    ///   - bitDepth: The bit depth of the image (default: 8).
    /// - Returns: The PSNR value in dB, or `nil` if calculation fails.
    public static func peakSignalToNoiseRatio(
        reference: [Int32],
        test: [Int32],
        bitDepth: Int = 8
    ) -> Double? {
        guard let mse = meanSquaredError(reference: reference, test: test) else {
            return nil
        }

        // If MSE is 0, images are identical (infinite PSNR)
        guard mse > 0 else {
            return Double.infinity
        }

        let maxValue = Double((1 << bitDepth) - 1)
        return 10.0 * log10((maxValue * maxValue) / mse)
    }

    /// Calculates Maximum Absolute Error (MAE) between two images.
    ///
    /// MAE is the maximum absolute difference between any two corresponding pixels.
    ///
    /// - Parameters:
    ///   - reference: The reference image data.
    ///   - test: The test image data to compare.
    /// - Returns: The MAE value, or `nil` if images have different sizes.
    public static func maximumAbsoluteError(
        reference: [Int32],
        test: [Int32]
    ) -> Int32? {
        guard reference.count == test.count else {
            return nil
        }

        guard !reference.isEmpty else {
            return 0
        }

        var maxError: Int32 = 0
        for i in 0..<reference.count {
            let error = abs(reference[i] - test[i])
            if error > maxError {
                maxError = error
            }
        }

        return maxError
    }

    /// Checks if two images are within an acceptable error tolerance.
    ///
    /// - Parameters:
    ///   - reference: The reference image data.
    ///   - test: The test image data to compare.
    ///   - maxError: Maximum allowable absolute error per pixel.
    /// - Returns: `true` if all pixels are within tolerance, `false` otherwise.
    public static func withinTolerance(
        reference: [Int32],
        test: [Int32],
        maxError: Int32
    ) -> Bool {
        guard let mae = maximumAbsoluteError(reference: reference, test: test) else {
            return false
        }
        return mae <= maxError
    }
}

// MARK: - Test Vector

/// Represents a JPEG 2000 test vector for conformance testing.
///
/// Test vectors consist of encoded codestreams and corresponding reference
/// decoded images, along with metadata about expected behavior.
public struct J2KTestVector: Sendable {
    /// The name of the test vector.
    public let name: String

    /// Description of what this test vector validates.
    public let description: String

    /// The encoded JPEG 2000 codestream.
    public let codestream: Data

    /// The expected decoded image data (if available).
    public let referenceImage: [Int32]?

    /// Expected image dimensions.
    public let width: Int
    public let height: Int

    /// Expected number of components.
    public let components: Int

    /// Expected bit depth per component.
    public let bitDepth: Int

    /// Maximum allowable error for conformance.
    ///
    /// Different conformance classes allow different error tolerances.
    /// - Lossless: 0
    /// - Lossy: typically 1-2 for near-lossless
    public let maxAllowableError: Int32

    /// Whether this test should decode successfully.
    ///
    /// Some test vectors are designed to test error handling for
    /// malformed or unsupported codestreams.
    public let shouldSucceed: Bool

    /// Creates a new test vector.
    public init(
        name: String,
        description: String,
        codestream: Data,
        referenceImage: [Int32]? = nil,
        width: Int,
        height: Int,
        components: Int,
        bitDepth: Int,
        maxAllowableError: Int32 = 0,
        shouldSucceed: Bool = true
    ) {
        self.name = name
        self.description = description
        self.codestream = codestream
        self.referenceImage = referenceImage
        self.width = width
        self.height = height
        self.components = components
        self.bitDepth = bitDepth
        self.maxAllowableError = maxAllowableError
        self.shouldSucceed = shouldSucceed
    }
}

// MARK: - Conformance Validator

/// Validates JPEG 2000 implementations against conformance requirements.
///
/// This validator checks that encoded/decoded images meet the error tolerances
/// specified in ISO/IEC 15444-4.
public struct J2KConformanceValidator: Sendable {
    /// Results from a conformance test.
    public struct TestResult: Sendable {
        /// The test vector that was run.
        public let vector: J2KTestVector

        /// Whether the test passed.
        public let passed: Bool

        /// Error message if the test failed.
        public let errorMessage: String?

        /// Calculated MSE (if applicable).
        public let mse: Double?

        /// Calculated PSNR (if applicable).
        public let psnr: Double?

        /// Calculated MAE (if applicable).
        public let mae: Int32?
    }

    /// Validates a decoded image against a test vector.
    ///
    /// - Parameters:
    ///   - decoded: The decoded image data.
    ///   - vector: The test vector with reference data.
    /// - Returns: The test result.
    public static func validate(
        decoded: [Int32],
        against vector: J2KTestVector
    ) -> TestResult {
        guard let referenceImage = vector.referenceImage else {
            return TestResult(
                vector: vector,
                passed: false,
                errorMessage: "No reference image available for validation",
                mse: nil,
                psnr: nil,
                mae: nil
            )
        }

        // Check size
        let expectedSize = vector.width * vector.height * vector.components
        guard decoded.count == expectedSize else {
            return TestResult(
                vector: vector,
                passed: false,
                errorMessage: "Size mismatch: expected \(expectedSize), got \(decoded.count)",
                mse: nil,
                psnr: nil,
                mae: nil
            )
        }

        // Calculate error metrics
        let mse = J2KErrorMetrics.meanSquaredError(reference: referenceImage, test: decoded)
        let psnr = J2KErrorMetrics.peakSignalToNoiseRatio(
            reference: referenceImage,
            test: decoded,
            bitDepth: vector.bitDepth
        )
        let mae = J2KErrorMetrics.maximumAbsoluteError(reference: referenceImage, test: decoded)

        guard let mae = mae else {
            return TestResult(
                vector: vector,
                passed: false,
                errorMessage: "Failed to calculate error metrics",
                mse: mse,
                psnr: psnr,
                mae: nil
            )
        }

        // Check against tolerance
        let passed = mae <= vector.maxAllowableError
        let errorMessage = passed ? nil : "MAE (\(mae)) exceeds maximum allowable error (\(vector.maxAllowableError))"

        return TestResult(
            vector: vector,
            passed: passed,
            errorMessage: errorMessage,
            mse: mse,
            psnr: psnr,
            mae: mae
        )
    }

    /// Runs a suite of conformance tests.
    ///
    /// - Parameter vectors: The test vectors to run.
    /// - Returns: Array of test results.
    public static func runTestSuite(
        vectors: [J2KTestVector],
        decoder: (Data) throws -> [Int32]
    ) -> [TestResult] {
        var results: [TestResult] = []

        for vector in vectors {
            do {
                let decoded = try decoder(vector.codestream)
                let result = validate(decoded: decoded, against: vector)
                results.append(result)
            } catch {
                results.append(TestResult(
                    vector: vector,
                    passed: !vector.shouldSucceed,
                    errorMessage: vector.shouldSucceed ? "Decoding failed: \(error)" : nil,
                    mse: nil,
                    psnr: nil,
                    mae: nil
                ))
            }
        }

        return results
    }

    /// Generates a conformance report.
    ///
    /// - Parameter results: The test results.
    /// - Returns: A formatted string report.
    public static func generateReport(results: [TestResult]) -> String {
        var report = "JPEG 2000 Conformance Test Report\n"
        report += String(repeating: "=", count: 50) + "\n\n"

        let passed = results.filter { $0.passed }.count
        let total = results.count
        let percentage = total > 0 ? Double(passed) / Double(total) * 100.0 : 0.0

        report += "Summary: \(passed)/\(total) tests passed (\(String(format: "%.1f", percentage))%)\n\n"

        // Failed tests
        let failures = results.filter { !$0.passed }
        if !failures.isEmpty {
            report += "Failed Tests:\n"
            report += String(repeating: "-", count: 50) + "\n"
            for result in failures {
                report += "  \(result.vector.name): \(result.errorMessage ?? "Unknown error")\n"
                if let mae = result.mae {
                    report += "    MAE: \(mae) (max allowed: \(result.vector.maxAllowableError))\n"
                }
                if let psnr = result.psnr {
                    report += "    PSNR: \(String(format: "%.2f", psnr)) dB\n"
                }
            }
            report += "\n"
        }

        return report
    }
}


// MARK: - HTJ2K Test Vector Generator

/// Generates synthetic test vectors for HTJ2K conformance testing.
///
/// This generator creates test codestreams and reference images for validating
/// HTJ2K encoders and decoders. Test vectors include various patterns and edge
/// cases to ensure comprehensive coverage.
public struct HTJ2KTestVectorGenerator: Sendable {
    /// Types of test patterns that can be generated.
    public enum TestPattern: Sendable {
        /// Solid colour pattern (all pixels same value).
        case solid(value: Int32)

        /// Gradient pattern (linear ramp from 0 to max value).
        case gradient

        /// Checkerboard pattern (alternating black and white squares).
        case checkerboard(squareSize: Int)

        /// Random noise pattern.
        case randomNoise(seed: UInt64)

        /// Frequency sweep pattern (sinusoidal with increasing frequency).
        case frequencySweep

        /// Edge pattern (sharp transitions to test high-frequency coding).
        case edges
    }

    /// Configuration for test vector generation.
    public struct Configuration: Sendable {
        /// Image width in pixels.
        public let width: Int

        /// Image height in pixels.
        public let height: Int

        /// Number of components (1 for grayscale, 3 for RGB).
        public let components: Int

        /// Bit depth per component.
        public let bitDepth: Int

        /// Test pattern to generate.
        public let pattern: TestPattern

        /// Whether to use lossless compression.
        public let lossless: Bool

        /// Quality factor for lossy compression (0.0-1.0).
        public let quality: Double

        /// Whether to use HTJ2K or legacy coding.
        public let useHTJ2K: Bool

        /// Creates a new test vector configuration.
        public init(
            width: Int,
            height: Int,
            components: Int,
            bitDepth: Int,
            pattern: TestPattern,
            lossless: Bool = true,
            quality: Double = 1.0,
            useHTJ2K: Bool = true
        ) {
            self.width = width
            self.height = height
            self.components = components
            self.bitDepth = bitDepth
            self.pattern = pattern
            self.lossless = lossless
            self.quality = quality
            self.useHTJ2K = useHTJ2K
        }
    }

    /// Generates a test image based on the specified pattern.
    ///
    /// - Parameters:
    ///   - config: Configuration specifying the test pattern and image parameters.
    /// - Returns: Array of pixel values for the test image.
    public static func generateImage(config: Configuration) -> [Int32] {
        let pixelCount = config.width * config.height * config.components
        var pixels = [Int32](repeating: 0, count: pixelCount)
        let maxValue = Int32((1 << config.bitDepth) - 1)

        switch config.pattern {
        case .solid(let value):
            pixels = [Int32](repeating: min(value, maxValue), count: pixelCount)

        case .gradient:
            for y in 0..<config.height {
                for x in 0..<config.width {
                    let value = Int32((Double(x + y) / Double(config.width + config.height)) * Double(maxValue))
                    for c in 0..<config.components {
                        let index = (y * config.width + x) * config.components + c
                        pixels[index] = value
                    }
                }
            }

        case .checkerboard(let squareSize):
            for y in 0..<config.height {
                for x in 0..<config.width {
                    let checkX = (x / squareSize) % 2
                    let checkY = (y / squareSize) % 2
                    let value: Int32 = (checkX + checkY).isMultiple(of: 2) ? 0 : maxValue
                    for c in 0..<config.components {
                        let index = (y * config.width + x) * config.components + c
                        pixels[index] = value
                    }
                }
            }

        case .randomNoise(let seed):
            var rng = SeededRandomNumberGenerator(seed: seed)
            for i in 0..<pixelCount {
                pixels[i] = Int32.random(in: 0...maxValue, using: &rng)
            }

        case .frequencySweep:
            for y in 0..<config.height {
                for x in 0..<config.width {
                    let freq = Double(x) / Double(config.width) * 10.0
                    let phase = Double(y) / Double(config.height) * 2.0 * .pi
                    let sine = sin(freq * phase)
                    let value = Int32((sine + 1.0) / 2.0 * Double(maxValue))
                    for c in 0..<config.components {
                        let index = (y * config.width + x) * config.components + c
                        pixels[index] = value
                    }
                }
            }

        case .edges:
            for y in 0..<config.height {
                for x in 0..<config.width {
                    let isEdge = (x.isMultiple(of: 8)) || (y.isMultiple(of: 8))
                    let value: Int32 = isEdge ? maxValue : 0
                    for c in 0..<config.components {
                        let index = (y * config.width + x) * config.components + c
                        pixels[index] = value
                    }
                }
            }
        }

        return pixels
    }

    /// Creates a test vector with the specified configuration.
    ///
    /// - Parameters:
    ///   - name: Name of the test vector.
    ///   - description: Description of what the test validates.
    ///   - config: Configuration for the test vector.
    /// - Returns: A complete test vector with reference image.
    public static func createTestVector(
        name: String,
        description: String,
        config: Configuration
    ) -> J2KTestVector {
        let referenceImage = generateImage(config: config)

        return J2KTestVector(
            name: name,
            description: description,
            codestream: Data(), // Codestream should be generated by encoding the reference image
            referenceImage: referenceImage,
            width: config.width,
            height: config.height,
            components: config.components,
            bitDepth: config.bitDepth,
            maxAllowableError: config.lossless ? 0 : 2,
            shouldSucceed: true
        )
    }
}

// MARK: - Seeded Random Number Generator

/// A simple seeded random number generator for reproducible test data.
private struct SeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        // Linear congruential generator
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// MARK: - HTJ2K Conformance Test Harness

/// Comprehensive test harness for validating HTJ2K implementations.
///
/// This harness extends the basic conformance validator with HTJ2K-specific
/// validation rules and test scenarios as specified in ISO/IEC 15444-15.
public struct HTJ2KConformanceTestHarness: Sendable {
    /// HTJ2K-specific validation rules.
    public struct ValidationRules: Sendable {
        /// Whether to validate CAP marker presence.
        public let requireCAPMarker: Bool

        /// Whether to validate CPF marker presence.
        public let requireCPFMarker: Bool

        /// Whether to validate HT set parameters in COD/COC markers.
        public let validateHTSetParameters: Bool

        /// Whether to validate mixed-mode codestreams (HT + legacy blocks).
        public let allowMixedMode: Bool

        /// Maximum allowable encoding/decoding time in seconds.
        public let maxProcessingTime: Double?

        /// Creates new validation rules.
        public init(
            requireCAPMarker: Bool = true,
            requireCPFMarker: Bool = true,
            validateHTSetParameters: Bool = true,
            allowMixedMode: Bool = false,
            maxProcessingTime: Double? = nil
        ) {
            self.requireCAPMarker = requireCAPMarker
            self.requireCPFMarker = requireCPFMarker
            self.validateHTSetParameters = validateHTSetParameters
            self.allowMixedMode = allowMixedMode
            self.maxProcessingTime = maxProcessingTime
        }
    }

    /// Result of HTJ2K-specific validation.
    public struct HTValidationResult: Sendable {
        /// Basic conformance test result.
        public let conformanceResult: J2KConformanceValidator.TestResult

        /// Whether CAP marker was found (if required).
        public let hasCAPMarker: Bool?

        /// Whether CPF marker was found (if required).
        public let hasCPFMarker: Bool?

        /// Whether HT set parameters were valid (if validated).
        public let validHTSetParameters: Bool?

        /// Whether mixed-mode coding was detected.
        public let isMixedMode: Bool?

        /// Processing time in seconds.
        public let processingTime: Double?

        /// Additional validation errors specific to HTJ2K.
        public let htValidationErrors: [String]

        /// Overall pass/fail status.
        public var passed: Bool {
            conformanceResult.passed && htValidationErrors.isEmpty
        }
    }

    /// The validation rules to apply.
    public let rules: ValidationRules

    /// Creates a new HTJ2K conformance test harness.
    ///
    /// - Parameter rules: Validation rules to apply.
    public init(rules: ValidationRules = ValidationRules()) {
        self.rules = rules
    }

    /// Validates HTJ2K codestream structure.
    ///
    /// This performs basic marker validation without full decoding.
    ///
    /// - Parameter codestream: The HTJ2K codestream data.
    /// - Returns: Validation errors, if any.
    public func validateCodestreamStructure(_ codestream: Data) -> [String] {
        var errors: [String] = []

        // Check minimum size
        guard codestream.count >= 2 else {
            errors.append("Codestream too short")
            return errors
        }

        // Check for JPEG 2000 SOC marker (0xFF4F)
        if codestream.count >= 2 {
            let soc = (UInt16(codestream[0]) << 8) | UInt16(codestream[1])
            if soc != 0xFF4F {
                errors.append("Missing or invalid SOC marker")
            }
        }

        // Scan for required markers
        var hasCAP = false
        var hasCPF = false
        var hasCOD = false

        var offset = 2  // Skip SOC
        while offset + 2 <= codestream.count {
            let marker = (UInt16(codestream[offset]) << 8) | UInt16(codestream[offset + 1])
            offset += 2

            // Check marker length
            guard offset + 2 <= codestream.count else { break }
            let length = (Int(codestream[offset]) << 8) | Int(codestream[offset + 1])

            switch marker {
            case 0xFF50:  // CAP
                hasCAP = true
            case 0xFF59:  // CPF
                hasCPF = true
            case 0xFF52:  // COD
                hasCOD = true
            case 0xFF93:  // SOD (start of data)
                // Stop scanning at SOD
                offset = codestream.count
            default:
                break
            }

            offset += length
        }

        if rules.requireCAPMarker && !hasCAP {
            errors.append("Missing required CAP marker for HTJ2K")
        }

        if rules.requireCPFMarker && !hasCPF {
            errors.append("Missing required CPF marker for HTJ2K")
        }

        if !hasCOD {
            errors.append("Missing required COD marker")
        }

        return errors
    }

    /// Validates a decoded image with HTJ2K-specific checks.
    ///
    /// - Parameters:
    ///   - decoded: The decoded image data.
    ///   - vector: The test vector with reference data.
    ///   - codestream: The encoded codestream (for marker validation).
    ///   - processingTime: Time taken to encode/decode (optional).
    /// - Returns: HTJ2K validation result.
    public func validate(
        decoded: [Int32],
        against vector: J2KTestVector,
        codestream: Data,
        processingTime: Double? = nil
    ) -> HTValidationResult {
        // First, perform standard conformance validation
        let conformanceResult = J2KConformanceValidator.validate(
            decoded: decoded,
            against: vector
        )

        // Then perform HTJ2K-specific validation
        let structureErrors = validateCodestreamStructure(codestream)

        // Check processing time if specified
        var timeErrors: [String] = []
        if let maxTime = rules.maxProcessingTime,
           let actualTime = processingTime,
           actualTime > maxTime {
            timeErrors.append("Processing time \(actualTime)s exceeds maximum \(maxTime)s")
        }

        // For now, we'll set these to nil since we need actual marker parsing
        // A full implementation would parse the codestream to extract these
        let hasCAPMarker: Bool? = nil
        let hasCPFMarker: Bool? = nil
        let validHTSetParameters: Bool? = nil
        let isMixedMode: Bool? = nil

        return HTValidationResult(
            conformanceResult: conformanceResult,
            hasCAPMarker: hasCAPMarker,
            hasCPFMarker: hasCPFMarker,
            validHTSetParameters: validHTSetParameters,
            isMixedMode: isMixedMode,
            processingTime: processingTime,
            htValidationErrors: structureErrors + timeErrors
        )
    }

    /// Generates a comprehensive report for multiple HTJ2K validation results.
    ///
    /// - Parameter results: Array of validation results.
    /// - Returns: Formatted report string.
    public static func generateReport(results: [HTValidationResult]) -> String {
        var report = "HTJ2K Conformance Test Report\n"
        report += "==============================\n\n"

        let passCount = results.filter { $0.passed }.count
        let totalCount = results.count
        let passRate = totalCount > 0 ? Double(passCount) / Double(totalCount) * 100.0 : 0.0

        report += "Summary: \(passCount)/\(totalCount) tests passed (\(String(format: "%.1f", passRate))%)\n\n"

        // Detailed results
        for (index, result) in results.enumerated() {
            let status = result.passed ? "✓ PASS" : "✗ FAIL"
            report += "Test \(index + 1): \(status)\n"
            report += "  Name: \(result.conformanceResult.vector.name)\n"

            if let mae = result.conformanceResult.mae {
                report += "  MAE: \(mae)\n"
            }
            if let psnr = result.conformanceResult.psnr {
                report += "  PSNR: \(String(format: "%.2f", psnr)) dB\n"
            }
            if let time = result.processingTime {
                report += "  Processing Time: \(String(format: "%.3f", time))s\n"
            }

            if !result.htValidationErrors.isEmpty {
                report += "  HTJ2K Validation Errors:\n"
                for error in result.htValidationErrors {
                    report += "    - \(error)\n"
                }
            }

            if let errorMsg = result.conformanceResult.errorMessage {
                report += "  Error: \(errorMsg)\n"
            }

            report += "\n"
        }

        return report
    }

    /// Creates a standard set of HTJ2K test vectors for basic conformance testing.
    ///
    /// - Returns: Array of test vectors covering common scenarios.
    public static func createStandardTestVectors() -> [J2KTestVector] {
        var vectors: [J2KTestVector] = []

        // 1. Lossless grayscale
        let losslessGrayConfig = HTJ2KTestVectorGenerator.Configuration(
            width: 64,
            height: 64,
            components: 1,
            bitDepth: 8,
            pattern: .checkerboard(squareSize: 8),
            lossless: true,
            useHTJ2K: true
        )
        vectors.append(HTJ2KTestVectorGenerator.createTestVector(
            name: "htj2k_lossless_gray_64x64",
            description: "Lossless HTJ2K encoding of 64×64 grayscale checkerboard",
            config: losslessGrayConfig
        ))

        // 2. Lossy RGB
        let lossyRGBConfig = HTJ2KTestVectorGenerator.Configuration(
            width: 128,
            height: 128,
            components: 3,
            bitDepth: 8,
            pattern: .gradient,
            lossless: false,
            quality: 0.9,
            useHTJ2K: true
        )
        vectors.append(HTJ2KTestVectorGenerator.createTestVector(
            name: "htj2k_lossy_rgb_128x128",
            description: "Lossy HTJ2K encoding of 128×128 RGB gradient",
            config: lossyRGBConfig
        ))

        // 3. High-frequency edges
        let edgesConfig = HTJ2KTestVectorGenerator.Configuration(
            width: 32,
            height: 32,
            components: 1,
            bitDepth: 8,
            pattern: .edges,
            lossless: true,
            useHTJ2K: true
        )
        vectors.append(HTJ2KTestVectorGenerator.createTestVector(
            name: "htj2k_edges_32x32",
            description: "HTJ2K encoding of high-frequency edge pattern",
            config: edgesConfig
        ))

        // 4. Random noise
        let noiseConfig = HTJ2KTestVectorGenerator.Configuration(
            width: 64,
            height: 64,
            components: 1,
            bitDepth: 8,
            pattern: .randomNoise(seed: 42),
            lossless: false,
            quality: 0.8,
            useHTJ2K: true
        )
        vectors.append(HTJ2KTestVectorGenerator.createTestVector(
            name: "htj2k_noise_64x64",
            description: "HTJ2K encoding of random noise pattern",
            config: noiseConfig
        ))

        // 5. Solid colour (trivial case)
        let solidConfig = HTJ2KTestVectorGenerator.Configuration(
            width: 16,
            height: 16,
            components: 1,
            bitDepth: 8,
            pattern: .solid(value: 128),
            lossless: true,
            useHTJ2K: true
        )
        vectors.append(HTJ2KTestVectorGenerator.createTestVector(
            name: "htj2k_solid_16x16",
            description: "HTJ2K encoding of solid gray pattern",
            config: solidConfig
        ))

        return vectors
    }
}


// MARK: - HTJ2K Interoperability Validator

/// Validates HTJ2K codestream interoperability with other JPEG 2000 implementations.
///
/// This validator checks that J2KSwift-generated codestreams conform to the
/// ISO/IEC 15444-15 standard in ways that ensure cross-implementation compatibility.
/// It verifies marker segment ordering, format correctness, capability signaling,
/// and codestream structure as required for interoperability with external
/// implementations such as OpenJPEG HTJ2K, kakadu, and others.
///
/// ## Validation Areas
///
/// - **Marker ordering**: SOC, SIZ, CAP, COD, QCD must appear in the correct order
/// - **Segment lengths**: All marker segment lengths must be valid
/// - **Capability signaling**: CAP and CPF markers must correctly signal HTJ2K support
/// - **Codestream structure**: Overall structure must be parseable by any conformant decoder
/// - **Cross-format compatibility**: HTJ2K and legacy codestreams must coexist properly
///
/// ## Topics
///
/// ### Validation
/// - ``validateInteroperability(codestream:)``
/// - ``validateMarkerOrdering(codestream:)``
/// - ``validateSegmentLengths(codestream:)``
/// - ``validateCapabilitySignaling(codestream:)``
///
/// ### Results
/// - ``InteroperabilityResult``
/// - ``MarkerInfo``
public struct J2KHTInteroperabilityValidator: Sendable {
    /// Well-known JPEG 2000 marker codes.
    public enum MarkerCode: UInt16, Sendable, CaseIterable {
        /// Start of Codestream.
        case soc = 0xFF4F
        /// Image and tile size.
        case siz = 0xFF51
        /// Coding style default.
        case cod = 0xFF52
        /// Coding style component.
        case coc = 0xFF53
        /// Quantization default.
        case qcd = 0xFF5C
        /// Quantization component.
        case qcc = 0xFF5D
        /// Region of interest.
        case rgn = 0xFF5E
        /// Progression order change.
        case poc = 0xFF5F
        /// Comment.
        case com = 0xFF64
        /// Tile-part header.
        case sot = 0xFF90
        /// Start of data.
        case sod = 0xFF93
        /// End of codestream.
        case eoc = 0xFFD9
        /// Capabilities (HTJ2K).
        case cap = 0xFF50
        /// Codestream profile (HTJ2K).
        case cpf = 0xFF59

        /// Human-readable name.
        public var name: String {
            switch self {
            case .soc: return "SOC"
            case .siz: return "SIZ"
            case .cod: return "COD"
            case .coc: return "COC"
            case .qcd: return "QCD"
            case .qcc: return "QCC"
            case .rgn: return "RGN"
            case .poc: return "POC"
            case .com: return "COM"
            case .sot: return "SOT"
            case .sod: return "SOD"
            case .eoc: return "EOC"
            case .cap: return "CAP"
            case .cpf: return "CPF"
            }
        }
    }

    /// Information about a marker found in the codestream.
    public struct MarkerInfo: Sendable {
        /// The marker code.
        public let code: UInt16

        /// Byte offset in the codestream.
        public let offset: Int

        /// Length of the marker segment (excluding the marker itself).
        /// `nil` for markers without a length field (SOC, SOD, EOC).
        public let segmentLength: Int?

        /// Human-readable marker name.
        public var name: String {
            MarkerCode(rawValue: code)?.name ?? String(format: "0x%04X", code)
        }
    }

    /// Result of interoperability validation.
    public struct InteroperabilityResult: Sendable {
        /// Whether the codestream passes all interoperability checks.
        public let passed: Bool

        /// Markers found in the codestream, in order.
        public let markers: [MarkerInfo]

        /// Validation errors found.
        public let errors: [String]

        /// Validation warnings (non-fatal).
        public let warnings: [String]

        /// Whether the codestream signals HTJ2K capability.
        public let isHTJ2K: Bool

        /// Whether the codestream uses mixed-mode coding.
        public let isMixedMode: Bool

        /// Summary string.
        public var summary: String {
            let status = passed ? "PASS" : "FAIL"
            var text = "Interoperability Check: \(status)\n"
            text += "  Markers found: \(markers.count)\n"
            text += "  HTJ2K: \(isHTJ2K)\n"
            text += "  Mixed mode: \(isMixedMode)\n"
            if !errors.isEmpty {
                text += "  Errors:\n"
                for error in errors {
                    text += "    - \(error)\n"
                }
            }
            if !warnings.isEmpty {
                text += "  Warnings:\n"
                for warning in warnings {
                    text += "    - \(warning)\n"
                }
            }
            return text
        }
    }

    /// Creates a new interoperability validator.
    public init() {}

    /// Performs comprehensive interoperability validation on a codestream.
    ///
    /// This checks marker ordering, segment lengths, capability signaling, and
    /// overall codestream structure to ensure compatibility with other
    /// JPEG 2000 implementations.
    ///
    /// - Parameter codestream: The JPEG 2000 codestream data.
    /// - Returns: The interoperability validation result.
    public func validateInteroperability(codestream: Data) -> InteroperabilityResult {
        var errors: [String] = []
        var warnings: [String] = []

        // Parse markers
        let markers = parseMarkers(from: codestream)
        if markers.isEmpty {
            errors.append("No markers found in codestream")
            return InteroperabilityResult(
                passed: false, markers: [], errors: errors,
                warnings: warnings, isHTJ2K: false, isMixedMode: false
            )
        }

        // Validate marker ordering
        let orderErrors = validateMarkerOrdering(markers: markers)
        errors.append(contentsOf: orderErrors)

        // Validate segment lengths
        let lengthErrors = validateSegmentLengths(
            codestream: codestream, markers: markers
        )
        errors.append(contentsOf: lengthErrors)

        // Validate capability signaling
        let (capErrors, capWarnings, isHTJ2K, isMixed) =
            validateCapabilitySignaling(codestream: codestream, markers: markers)
        errors.append(contentsOf: capErrors)
        warnings.append(contentsOf: capWarnings)

        // Check basic structure
        let structureErrors = validateBasicStructure(markers: markers)
        errors.append(contentsOf: structureErrors)

        return InteroperabilityResult(
            passed: errors.isEmpty,
            markers: markers,
            errors: errors,
            warnings: warnings,
            isHTJ2K: isHTJ2K,
            isMixedMode: isMixed
        )
    }

    /// Validates that markers appear in the required order per ISO/IEC 15444-1 and 15444-15.
    ///
    /// The required main header ordering is:
    /// 1. SOC (must be first)
    /// 2. SIZ (must be second)
    /// 3. CAP (if present, must appear before COD)
    /// 4. COD (required)
    /// 5. QCD (required)
    ///
    /// - Parameter codestream: The JPEG 2000 codestream data.
    /// - Returns: Array of ordering errors found.
    public func validateMarkerOrdering(codestream: Data) -> [String] {
        let markers = parseMarkers(from: codestream)
        return validateMarkerOrdering(markers: markers)
    }

    /// Validates segment lengths for all marker segments.
    ///
    /// Each marker segment's declared length must be consistent with the data
    /// available in the codestream. Invalid lengths would cause interoperability
    /// failures with other decoders.
    ///
    /// - Parameter codestream: The JPEG 2000 codestream data.
    /// - Returns: Array of segment length errors found.
    public func validateSegmentLengths(codestream: Data) -> [String] {
        let markers = parseMarkers(from: codestream)
        return validateSegmentLengths(codestream: codestream, markers: markers)
    }

    /// Validates HTJ2K capability signaling in the codestream.
    ///
    /// For HTJ2K codestreams, the CAP marker must correctly signal Part 15
    /// capability, and the CPF marker should indicate the appropriate profile.
    ///
    /// - Parameter codestream: The JPEG 2000 codestream data.
    /// - Returns: Tuple of (errors, warnings, isHTJ2K, isMixedMode).
    public func validateCapabilitySignaling(
        codestream: Data
    ) -> (errors: [String], warnings: [String], isHTJ2K: Bool, isMixedMode: Bool) {
        let markers = parseMarkers(from: codestream)
        return validateCapabilitySignaling(codestream: codestream, markers: markers)
    }

    // MARK: - Internal Validation Methods

    /// Parses all markers from a codestream.
    internal func parseMarkers(from data: Data) -> [MarkerInfo] {
        var markers: [MarkerInfo] = []
        var offset = 0

        guard data.count >= 2 else { return markers }

        while offset + 1 < data.count {
            let byte1 = data[offset]
            guard byte1 == 0xFF else {
                offset += 1
                continue
            }

            let byte2 = data[offset + 1]
            let code = (UInt16(byte1) << 8) | UInt16(byte2)

            // Skip fill bytes (0xFF followed by another 0xFF)
            if byte2 == 0xFF {
                offset += 1
                continue
            }

            // Skip non-marker bytes
            guard byte2 >= 0x01 else {
                offset += 2
                continue
            }

            // Markers without segment length: SOC, SOD, EOC
            let noLengthMarkers: Set<UInt16> = [0xFF4F, 0xFF93, 0xFFD9]

            if noLengthMarkers.contains(code) {
                markers.append(MarkerInfo(
                    code: code, offset: offset, segmentLength: nil
                ))
                offset += 2

                // After SOD, skip to the next tile or end
                if code == 0xFF93 {
                    // SOD: data follows until the next marker
                    break
                }
            } else {
                // Read segment length (2 bytes, includes the length field itself)
                guard offset + 3 < data.count else { break }
                let lengthHigh = Int(data[offset + 2])
                let lengthLow = Int(data[offset + 3])
                let segmentLength = (lengthHigh << 8) | lengthLow

                markers.append(MarkerInfo(
                    code: code, offset: offset, segmentLength: segmentLength
                ))

                // Advance past marker (2 bytes) + segment data
                offset += 2 + segmentLength
            }
        }

        return markers
    }

    /// Validates marker ordering against the standard requirements.
    private func validateMarkerOrdering(markers: [MarkerInfo]) -> [String] {
        var errors: [String] = []

        guard !markers.isEmpty else {
            errors.append("No markers found")
            return errors
        }

        // SOC must be first
        if markers[0].code != MarkerCode.soc.rawValue {
            errors.append(
                "First marker must be SOC (0xFF4F), found \(markers[0].name)"
            )
        }

        // SIZ must be second
        if markers.count > 1 && markers[1].code != MarkerCode.siz.rawValue {
            errors.append(
                "Second marker must be SIZ (0xFF51), found \(markers[1].name)"
            )
        }

        // CAP must appear before COD if present
        let capIndex = markers.firstIndex { $0.code == MarkerCode.cap.rawValue }
        let codIndex = markers.firstIndex { $0.code == MarkerCode.cod.rawValue }

        if let capIdx = capIndex, let codIdx = codIndex {
            if capIdx > codIdx {
                errors.append("CAP marker must appear before COD marker")
            }
        }

        // COD must appear before SOT/SOD
        let sotIndex = markers.firstIndex { $0.code == MarkerCode.sot.rawValue }
        let sodIndex = markers.firstIndex { $0.code == MarkerCode.sod.rawValue }

        if let codIdx = codIndex {
            if let sotIdx = sotIndex, codIdx > sotIdx {
                errors.append("COD marker must appear before SOT marker")
            }
            if let sodIdx = sodIndex, codIdx > sodIdx {
                errors.append("COD marker must appear before SOD marker")
            }
        }

        // QCD must appear before SOT/SOD
        let qcdIndex = markers.firstIndex { $0.code == MarkerCode.qcd.rawValue }
        if let qcdIdx = qcdIndex {
            if let sotIdx = sotIndex, qcdIdx > sotIdx {
                errors.append("QCD marker must appear before SOT marker")
            }
        }

        return errors
    }

    /// Validates segment lengths are consistent with the codestream data.
    private func validateSegmentLengths(
        codestream: Data,
        markers: [MarkerInfo]
    ) -> [String] {
        var errors: [String] = []

        for marker in markers {
            guard let length = marker.segmentLength else { continue }

            // Segment length must be at least 2 (the length field itself)
            if length < 2 {
                errors.append(
                    "\(marker.name) at offset \(marker.offset): " +
                    "segment length \(length) is less than minimum 2"
                )
                continue
            }

            // Segment must not extend beyond the codestream
            let segmentEnd = marker.offset + 2 + length
            if segmentEnd > codestream.count {
                errors.append(
                    "\(marker.name) at offset \(marker.offset): " +
                    "segment extends beyond codestream " +
                    "(end \(segmentEnd) > size \(codestream.count))"
                )
            }
        }

        return errors
    }

    /// Validates HTJ2K capability signaling.
    private func validateCapabilitySignaling(
        codestream: Data,
        markers: [MarkerInfo]
    ) -> (errors: [String], warnings: [String], isHTJ2K: Bool, isMixedMode: Bool) {
        var errors: [String] = []
        var warnings: [String] = []
        var isHTJ2K = false
        var isMixedMode = false

        let capMarker = markers.first { $0.code == MarkerCode.cap.rawValue }
        let cpfMarker = markers.first { $0.code == MarkerCode.cpf.rawValue }

        if let cap = capMarker, let segLen = cap.segmentLength {
            let dataStart = cap.offset + 4  // marker (2) + length (2)
            let dataEnd = cap.offset + 2 + segLen

            guard dataEnd <= codestream.count && dataStart + 4 <= codestream.count else {
                errors.append("CAP marker segment data is truncated")
                return (errors, warnings, false, false)
            }

            // Parse Pcap (4 bytes): capability bits
            let pcap = (UInt32(codestream[dataStart]) << 24) |
                       (UInt32(codestream[dataStart + 1]) << 16) |
                       (UInt32(codestream[dataStart + 2]) << 8) |
                       UInt32(codestream[dataStart + 3])

            // Bit 14 (from MSB in 32-bit) = Part 15 HT capability
            isHTJ2K = (pcap & (1 << 17)) != 0

            if isHTJ2K && dataStart + 6 <= codestream.count {
                let ccap = (UInt16(codestream[dataStart + 4]) << 8) |
                           UInt16(codestream[dataStart + 5])
                isMixedMode = (ccap & 0x0002) != 0
            }

            // Validate: if HTJ2K, CAP should have Part 15 extensions
            if isHTJ2K && segLen < 8 {
                warnings.append(
                    "HTJ2K CAP marker segment may be missing Ccap extension data"
                )
            }
        }

        // If HTJ2K, CPF marker should be present
        if isHTJ2K && cpfMarker == nil {
            warnings.append("HTJ2K codestream should include a CPF marker")
        }

        // Validate CPF marker if present
        if let cpf = cpfMarker, let segLen = cpf.segmentLength {
            let dataStart = cpf.offset + 4
            let dataEnd = cpf.offset + 2 + segLen

            guard dataEnd <= codestream.count && dataStart + 2 <= codestream.count else {
                errors.append("CPF marker segment data is truncated")
                return (errors, warnings, isHTJ2K, isMixedMode)
            }

            let pcpf = (UInt16(codestream[dataStart]) << 8) |
                       UInt16(codestream[dataStart + 1])

            // Bit 15: 0 = Part 1, 1 = Part 15
            let cpfIsHTJ2K = (pcpf & 0x8000) != 0

            // Cross-validate CAP and CPF
            if isHTJ2K && !cpfIsHTJ2K {
                warnings.append(
                    "CAP signals HTJ2K but CPF indicates Part 1 profile"
                )
            }
            if !isHTJ2K && cpfIsHTJ2K {
                warnings.append(
                    "CPF indicates Part 15 but CAP does not signal HTJ2K"
                )
            }
        }

        return (errors, warnings, isHTJ2K, isMixedMode)
    }

    /// Validates basic codestream structure.
    private func validateBasicStructure(markers: [MarkerInfo]) -> [String] {
        var errors: [String] = []

        let markerCodes = markers.map { $0.code }

        // Required markers for any valid JPEG 2000 codestream
        if !markerCodes.contains(MarkerCode.soc.rawValue) {
            errors.append("Missing required SOC marker")
        }

        if !markerCodes.contains(MarkerCode.siz.rawValue) {
            errors.append("Missing required SIZ marker")
        }

        if !markerCodes.contains(MarkerCode.cod.rawValue) {
            errors.append("Missing required COD marker")
        }

        if !markerCodes.contains(MarkerCode.qcd.rawValue) {
            errors.append("Missing required QCD marker")
        }

        // SOT or SOD should be present (codestream must have data)
        let hasSOT = markerCodes.contains(MarkerCode.sot.rawValue)
        let hasSOD = markerCodes.contains(MarkerCode.sod.rawValue)
        if !hasSOT && !hasSOD {
            errors.append("Missing SOT/SOD markers - codestream has no data section")
        }

        return errors
    }

    /// Generates an interoperability test report for multiple codestreams.
    ///
    /// - Parameter results: Array of interoperability results to summarize.
    /// - Returns: A formatted report string.
    public static func generateReport(
        results: [InteroperabilityResult]
    ) -> String {
        var report = "HTJ2K Interoperability Test Report\n"
        report += "===================================\n\n"

        let passCount = results.filter { $0.passed }.count
        let totalCount = results.count
        let passRate = totalCount > 0
            ? Double(passCount) / Double(totalCount) * 100.0 : 0.0

        report += "Summary: \(passCount)/\(totalCount) passed "
        report += "(\(String(format: "%.1f", passRate))%)\n\n"

        for (index, result) in results.enumerated() {
            let status = result.passed ? "✓ PASS" : "✗ FAIL"
            report += "Test \(index + 1): \(status)\n"
            report += "  Markers: \(result.markers.count)\n"
            report += "  HTJ2K: \(result.isHTJ2K)\n"

            if !result.errors.isEmpty {
                report += "  Errors:\n"
                for error in result.errors {
                    report += "    - \(error)\n"
                }
            }

            if !result.warnings.isEmpty {
                report += "  Warnings:\n"
                for warning in result.warnings {
                    report += "    - \(warning)\n"
                }
            }
            report += "\n"
        }

        return report
    }

    /// Creates a minimal valid JPEG 2000 codestream for testing interoperability.
    ///
    /// This generates a synthetic codestream with correct marker ordering and
    /// structure that any conformant JPEG 2000 decoder should be able to parse.
    ///
    /// - Parameters:
    ///   - width: Image width.
    ///   - height: Image height.
    ///   - components: Number of components.
    ///   - bitDepth: Bit depth per component.
    ///   - htj2k: Whether to include HTJ2K markers (CAP, CPF).
    /// - Returns: The synthetic codestream data.
    public static func createSyntheticCodestream(
        width: Int,
        height: Int,
        components: Int,
        bitDepth: Int,
        htj2k: Bool
    ) -> Data {
        var data = Data()

        // SOC marker
        data.append(contentsOf: [0xFF, 0x4F])

        // SIZ marker segment
        var sizBody = Data()
        // Rsiz (2 bytes): Profile 0
        sizBody.append(contentsOf: [0x00, 0x00])
        // Xsiz (4 bytes): image width
        sizBody.append(contentsOf: withUnsafeBytes(of: UInt32(width).bigEndian) {
            Array($0)
        })
        // Ysiz (4 bytes): image height
        sizBody.append(contentsOf: withUnsafeBytes(of: UInt32(height).bigEndian) {
            Array($0)
        })
        // XOsiz, YOsiz (8 bytes): origin = 0
        sizBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        // XTsiz, YTsiz (8 bytes): tile size = image size
        sizBody.append(contentsOf: withUnsafeBytes(of: UInt32(width).bigEndian) {
            Array($0)
        })
        sizBody.append(contentsOf: withUnsafeBytes(of: UInt32(height).bigEndian) {
            Array($0)
        })
        // XTOsiz, YTOsiz (8 bytes): tile origin = 0
        sizBody.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        // Csiz (2 bytes): number of components
        sizBody.append(contentsOf: [
            UInt8((components >> 8) & 0xFF),
            UInt8(components & 0xFF)
        ])
        // For each component: Ssiz (1), XRsiz (1), YRsiz (1)
        for _ in 0..<components {
            sizBody.append(UInt8(bitDepth - 1))  // Ssiz: bit depth - 1 (unsigned)
            sizBody.append(1)  // XRsiz: horizontal subsampling = 1
            sizBody.append(1)  // YRsiz: vertical subsampling = 1
        }

        let sizLength = UInt16(sizBody.count + 2)
        data.append(contentsOf: [0xFF, 0x51])
        data.append(contentsOf: [
            UInt8((sizLength >> 8) & 0xFF),
            UInt8(sizLength & 0xFF)
        ])
        data.append(sizBody)

        // CAP marker (for HTJ2K)
        if htj2k {
            var capBody = Data()
            // Pcap (4 bytes): Part 15 capability bit
            let pcap: UInt32 = 1 << 17
            capBody.append(contentsOf: withUnsafeBytes(of: pcap.bigEndian) {
                Array($0)
            })
            // Ccap (2 bytes): HT capability extension
            capBody.append(contentsOf: [0x00, 0x01])  // HTJ2K enabled, no mixed mode

            let capLength = UInt16(capBody.count + 2)
            data.append(contentsOf: [0xFF, 0x50])
            data.append(contentsOf: [
                UInt8((capLength >> 8) & 0xFF),
                UInt8(capLength & 0xFF)
            ])
            data.append(capBody)
        }

        // COD marker segment
        var codBody = Data()
        // Scod (1 byte): coding style
        codBody.append(0x00)
        // SGcod: progression order (LRCP=0), layers=1, MCT=0
        codBody.append(contentsOf: [0x00, 0x00, 0x01, 0x00])
        // SPcod: decomposition levels, code-block size, style
        codBody.append(5)  // NL: 5 decomposition levels
        codBody.append(5)  // xcb: code-block width exponent offset = 5 (32)
        codBody.append(5)  // ycb: code-block height exponent offset = 5 (32)
        codBody.append(0)  // code-block style
        codBody.append(0)  // wavelet transform: 9/7 irreversible

        let codLength = UInt16(codBody.count + 2)
        data.append(contentsOf: [0xFF, 0x52])
        data.append(contentsOf: [
            UInt8((codLength >> 8) & 0xFF),
            UInt8(codLength & 0xFF)
        ])
        data.append(codBody)

        // CPF marker (for HTJ2K)
        if htj2k {
            var cpfBody = Data()
            // Pcpf (2 bytes): Part 15 profile
            let pcpf: UInt16 = 0x8000  // Bit 15 set = Part 15 profile
            cpfBody.append(contentsOf: [
                UInt8((pcpf >> 8) & 0xFF),
                UInt8(pcpf & 0xFF)
            ])

            let cpfLength = UInt16(cpfBody.count + 2)
            data.append(contentsOf: [0xFF, 0x59])
            data.append(contentsOf: [
                UInt8((cpfLength >> 8) & 0xFF),
                UInt8(cpfLength & 0xFF)
            ])
            data.append(cpfBody)
        }

        // QCD marker segment
        var qcdBody = Data()
        // Sqcd (1 byte): quantization style (no quantization)
        qcdBody.append(0x00)
        // SPqcd: step sizes for each subband
        let numSubbands = 3 * 5 + 1  // 3 subbands × 5 levels + LL
        for _ in 0..<numSubbands {
            qcdBody.append(0x08)  // Exponent=1, mantissa=0
        }

        let qcdLength = UInt16(qcdBody.count + 2)
        data.append(contentsOf: [0xFF, 0x5C])
        data.append(contentsOf: [
            UInt8((qcdLength >> 8) & 0xFF),
            UInt8(qcdLength & 0xFF)
        ])
        data.append(qcdBody)

        // SOT marker segment
        var sotBody = Data()
        // Isot (2 bytes): tile index = 0
        sotBody.append(contentsOf: [0x00, 0x00])
        // Psot (4 bytes): tile-part length = 0 (rest of codestream)
        sotBody.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // TPsot (1 byte): tile-part index = 0
        sotBody.append(0x00)
        // TNsot (1 byte): number of tile-parts = 1
        sotBody.append(0x01)

        let sotLength = UInt16(sotBody.count + 2)
        data.append(contentsOf: [0xFF, 0x90])
        data.append(contentsOf: [
            UInt8((sotLength >> 8) & 0xFF),
            UInt8(sotLength & 0xFF)
        ])
        data.append(sotBody)

        // SOD marker
        data.append(contentsOf: [0xFF, 0x93])

        // Minimal encoded data (empty)
        data.append(contentsOf: [0x00])

        // EOC marker
        data.append(contentsOf: [0xFF, 0xD9])

        return data
    }
}
