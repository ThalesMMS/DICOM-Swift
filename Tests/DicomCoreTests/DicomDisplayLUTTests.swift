//
//  DicomDisplayLUTTests.swift
//  DicomCoreTests
//
//  The cached presentation LUT, pinned (issue #1906). The table is built
//  from `DicomDisplayTransformProfile.displayValue`, so these tests hold it
//  to exact equality with that formula over every representable stored
//  value — no tolerance, nil included.
//

import DicomTestSupport
import XCTest
@testable import DicomCore

final class DicomDisplayLUTTests: XCTestCase {

    // MARK: - Profile fixtures

    private func windowProfile(
        center: Double = 40,
        width: Double = 400,
        rescale: RescaleParameters = RescaleParameters(intercept: -1024, slope: 1),
        photometric: String = "MONOCHROME2",
        shape: DicomPresentationLUTShape? = nil,
        explanation: String? = nil
    ) -> DicomDisplayTransformProfile {
        DicomDisplayTransformProfile(
            rescaleParameters: rescale,
            windows: [DicomDisplayWindow(
                settings: WindowSettings(center: center, width: width),
                explanation: explanation,
                source: .dicom(index: 0)
            )],
            presentationLUTShape: shape,
            photometricInterpretation: photometric
        )
    }

    private func modalityLUTProfile(bitsStored: Int) -> DicomDisplayTransformProfile {
        let entryCount = 1 << bitsStored
        let lut = DicomLookupTable(
            descriptor: DicomLUTDescriptor(storedEntryCount: entryCount == 65_536 ? 0 : entryCount,
                                           firstMappedValue: 0,
                                           bitsPerEntry: 16)!,
            explanation: nil,
            lutType: "US",
            data: (0..<entryCount).map { UInt16(($0 * 7) % 65_536) }
        )
        return DicomDisplayTransformProfile(
            modalityLUTs: [lut],
            windows: [DicomDisplayWindow(settings: WindowSettings(center: 500, width: 2000),
                                         explanation: nil,
                                         source: .dicom(index: 0))],
            photometricInterpretation: "MONOCHROME2"
        )
    }

    private func voiLUTProfile() -> DicomDisplayTransformProfile {
        let voi = DicomLookupTable(
            descriptor: DicomLUTDescriptor(storedEntryCount: 4096,
                                           firstMappedValue: -1024,
                                           bitsPerEntry: 12)!,
            explanation: "VOI",
            lutType: nil,
            data: (0..<4096).map { UInt16($0) }
        )
        return DicomDisplayTransformProfile(
            rescaleParameters: RescaleParameters(intercept: -1024, slope: 1),
            voiLUTs: [voi],
            photometricInterpretation: "MONOCHROME2"
        )
    }

    /// The exhaustive contract: for every representable stored value, the
    /// table answers exactly what the scalar formula answers — value or nil.
    private func assertExhaustiveParity(
        profile: DicomDisplayTransformProfile,
        selection: DicomDisplaySelection?,
        bitsStored: Int,
        isSigned: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let lut = DicomDisplayLUT(profile: profile,
                                        selection: selection,
                                        bitsStored: bitsStored,
                                        isSigned: isSigned) else {
            return XCTFail("LUT construction failed for bitsStored \(bitsStored)", file: file, line: line)
        }
        let minimum = isSigned ? -(1 << (bitsStored - 1)) : 0
        let count = 1 << bitsStored
        for offset in 0..<count {
            let stored = minimum + offset
            let expected = profile.displayValue(forStoredPixelValue: Double(stored),
                                                selection: selection)
            let actual = lut.displayValue(forStoredPixelValue: stored)
            if expected != actual {
                return XCTFail(
                    "stored \(stored): LUT \(String(describing: actual)) ≠ scalar \(String(describing: expected))",
                    file: file, line: line
                )
            }
        }
    }

    // MARK: - Exhaustive parity across the matrix

    func test_presentationTable_cacheSignatureAndExhaustiveParity() throws {
        let descriptor = try XCTUnwrap(DicomLUTDescriptor(storedEntryCount: 4, firstMappedValue: 3, bitsPerEntry: 16))
        func profile(_ data: [UInt16], explanation: String) -> DicomDisplayTransformProfile {
            DicomDisplayTransformProfile(presentationLUT: DicomLookupTable(
                descriptor: descriptor, explanation: explanation, lutType: nil, data: data))
        }
        let first = profile([0, 10000, 40000, 65535], explanation: "first")
        let renamed = profile([0, 10000, 40000, 65535], explanation: "renamed")
        let changed = profile([0, 20000, 40000, 65535], explanation: "first")
        let selection = DicomDisplaySelection.customWindow(WindowSettings(center: 2048, width: 4096))
        func key(_ value: DicomDisplayTransformProfile) -> DicomDisplayLUTKey {
            DicomDisplayLUTKey(profile: value, selection: selection, bitsStored: 12, isSigned: false)
        }
        XCTAssertEqual(key(first), key(renamed))
        XCTAssertNotEqual(key(first), key(changed))
        let lut = try XCTUnwrap(DicomDisplayLUT(profile: first, selection: selection, bitsStored: 12, isSigned: false))
        for value in 0..<4096 {
            XCTAssertEqual(lut.displayValue(forStoredPixelValue: value),
                           first.displayValue(forStoredPixelValue: Double(value), selection: selection))
        }
    }

    func test_exhaustiveParity_windowedSignedAndUnsignedAcrossBitDepths() {
        for bitsStored in [8, 10, 12, 16] {
            for isSigned in [false, true] {
                assertExhaustiveParity(profile: windowProfile(),
                                       selection: .window(index: 0),
                                       bitsStored: bitsStored,
                                       isSigned: isSigned)
            }
        }
    }

    func test_exhaustiveParity_monochrome1AndPresentationShapes() {
        for photometric in ["MONOCHROME1", "MONOCHROME2"] {
            for shape in [DicomPresentationLUTShape?.none, .identity, .inverse] {
                assertExhaustiveParity(
                    profile: windowProfile(photometric: photometric, shape: shape),
                    selection: .window(index: 0),
                    bitsStored: 12,
                    isSigned: true
                )
            }
        }
    }

    func test_exhaustiveParity_modalityLUTAndVOILUT() {
        assertExhaustiveParity(profile: modalityLUTProfile(bitsStored: 12),
                               selection: .window(index: 0),
                               bitsStored: 12,
                               isSigned: false)
        assertExhaustiveParity(profile: voiLUTProfile(),
                               selection: .voiLUT(index: 0),
                               bitsStored: 12,
                               isSigned: true)
    }

    func test_exhaustiveParity_presetAndCustomWindow() {
        assertExhaustiveParity(profile: windowProfile(),
                               selection: .preset(.lung),
                               bitsStored: 10,
                               isSigned: true)
        assertExhaustiveParity(profile: windowProfile(),
                               selection: .customWindow(WindowSettings(center: -600, width: 1500)),
                               bitsStored: 16,
                               isSigned: true)
    }

    /// The formula's refusals are preserved: an invalid selection makes the
    /// scalar path answer nil for every value, and so does the table.
    func test_nilAnswersArePreservedNotInvented() {
        let profile = windowProfile(width: 0)
        let lut = DicomDisplayLUT(profile: profile,
                                  selection: .window(index: 0),
                                  bitsStored: 8,
                                  isSigned: false)!
        XCTAssertTrue(lut.hasUnmappedEntries)
        XCTAssertNil(lut.displayValue(forStoredPixelValue: 40))
        XCTAssertNil(lut.displayValue(forStoredPixelValue: 1 << 8), "out of range is nil, like the domain says")
    }

    // MARK: - Cache identity

    func test_cosmeticDifferencesShareOneTable() {
        let cache = DicomDisplayLUTCache(capacity: 4)
        _ = cache.table(profile: windowProfile(explanation: "SOFT TISSUE"),
                        selection: .window(index: 0), bitsStored: 12, isSigned: true)
        _ = cache.table(profile: windowProfile(explanation: "completely different label"),
                        selection: .window(index: 0), bitsStored: 12, isSigned: true)
        XCTAssertEqual(cache.debugBuildCount, 1,
                       "a window explanation is a label, not a presentation")
    }

    func test_everyPresentationSemanticChangeGetsItsOwnTable() {
        let cache = DicomDisplayLUTCache(capacity: 16)
        _ = cache.table(profile: windowProfile(), selection: .window(index: 0), bitsStored: 12, isSigned: true)
        _ = cache.table(profile: windowProfile(center: 41), selection: .window(index: 0), bitsStored: 12, isSigned: true)
        _ = cache.table(profile: windowProfile(rescale: RescaleParameters(intercept: 0, slope: 2)),
                        selection: .window(index: 0), bitsStored: 12, isSigned: true)
        _ = cache.table(profile: windowProfile(photometric: "MONOCHROME1"),
                        selection: .window(index: 0), bitsStored: 12, isSigned: true)
        _ = cache.table(profile: windowProfile(shape: .inverse),
                        selection: .window(index: 0), bitsStored: 12, isSigned: true)
        _ = cache.table(profile: windowProfile(), selection: .window(index: 0), bitsStored: 10, isSigned: true)
        _ = cache.table(profile: windowProfile(), selection: .window(index: 0), bitsStored: 12, isSigned: false)
        XCTAssertEqual(cache.debugBuildCount, 7)
    }

    func test_evictionIsDeterministicFIFO() {
        let cache = DicomDisplayLUTCache(capacity: 2)
        _ = cache.table(profile: windowProfile(center: 1), selection: .window(index: 0), bitsStored: 8, isSigned: false)
        _ = cache.table(profile: windowProfile(center: 2), selection: .window(index: 0), bitsStored: 8, isSigned: false)
        _ = cache.table(profile: windowProfile(center: 3), selection: .window(index: 0), bitsStored: 8, isSigned: false)
        // center 1 left; asking again rebuilds it.
        _ = cache.table(profile: windowProfile(center: 1), selection: .window(index: 0), bitsStored: 8, isSigned: false)
        XCTAssertEqual(cache.debugBuildCount, 4)
        // center 3 stayed.
        _ = cache.table(profile: windowProfile(center: 3), selection: .window(index: 0), bitsStored: 8, isSigned: false)
        XCTAssertEqual(cache.debugBuildCount, 4)
    }

    // MARK: - CPU and Metal produce identical bytes

    func test_cpuAndMetalIndexTheSameTableToIdenticalBytes() throws {
        try DicomTestRuntimePreflight.require(.metalDevice)
        let profile = windowProfile()
        let bitsStored = 12
        let lut = try XCTUnwrap(DicomDisplayLUT(profile: profile,
                                                selection: .window(index: 0),
                                                bitsStored: bitsStored,
                                                isSigned: true))
        XCTAssertFalse(lut.hasUnmappedEntries)

        // The whole signed 12-bit domain, in order.
        let storedValues = Array(lut.minimumStoredValue..<(lut.minimumStoredValue + lut.count))

        var cpuBytes = [UInt8]()
        cpuBytes.reserveCapacity(storedValues.count)
        for value in storedValues {
            cpuBytes.append(try XCTUnwrap(lut.displayValue(forStoredPixelValue: value)))
        }

        let processor = try MetalWindowingProcessor()
        let gpuData = try XCTUnwrap(processor.applyDisplayLUT(storedValues: storedValues, lut: lut))

        // Byte-identical, no ±1: both sides read one table.
        XCTAssertEqual([UInt8](gpuData), cpuBytes)
    }

    func test_metalRefusesWhatTheScalarPathWouldReportPerPixel() throws {
        try DicomTestRuntimePreflight.require(.metalDevice)
        let processor = try MetalWindowingProcessor()

        let unmapped = DicomDisplayLUT(profile: windowProfile(width: 0),
                                       selection: .window(index: 0),
                                       bitsStored: 8,
                                       isSigned: false)!
        XCTAssertNil(try processor.applyDisplayLUT(storedValues: [1, 2], lut: unmapped),
                     "an unmapped table stays on the scalar path where failures are reported")

        let mapped = DicomDisplayLUT(profile: windowProfile(),
                                     selection: .window(index: 0),
                                     bitsStored: 8,
                                     isSigned: false)!
        XCTAssertNil(try processor.applyDisplayLUT(storedValues: [4096], lut: mapped),
                     "an out-of-range stored value must not become a silent zero")
    }

    // MARK: - Opt-in benchmark

    /// Reports scalar vs LUT-CPU vs LUT-Metal timings. Opt-in
    /// (`DICOM_LUT_BENCHMARK=1`) and assertion-free: it records what this
    /// hardware measured instead of declaring an unmeasured gain.
    func test_benchmark_scalarVsLUTCPUvsLUTMetal() throws {
        guard ProcessInfo.processInfo.environment["DICOM_LUT_BENCHMARK"] == "1" else {
            throw XCTSkip("Set DICOM_LUT_BENCHMARK=1 to run the presentation LUT benchmark.")
        }
        let profile = windowProfile()
        let bitsStored = 12
        let lut = try XCTUnwrap(DicomDisplayLUT(profile: profile,
                                                selection: .window(index: 0),
                                                bitsStored: bitsStored,
                                                isSigned: true))
        let pixelCount = 2048 * 2048
        let storedValues = (0..<pixelCount).map { ($0 % 4096) - 2048 }

        let scalarStart = Date()
        var scalarChecksum = 0
        for value in storedValues {
            scalarChecksum &+= Int(profile.displayValue(forStoredPixelValue: Double(value),
                                                        selection: .window(index: 0)) ?? 0)
        }
        let scalarSeconds = Date().timeIntervalSince(scalarStart)

        let lutStart = Date()
        var lutChecksum = 0
        for value in storedValues {
            lutChecksum &+= Int(lut.displayValue(forStoredPixelValue: value) ?? 0)
        }
        let lutSeconds = Date().timeIntervalSince(lutStart)
        XCTAssertEqual(scalarChecksum, lutChecksum)

        var metalReport = "metal: unavailable"
        if let processor = try? MetalWindowingProcessor() {
            let metalStart = Date()
            _ = try processor.applyDisplayLUT(storedValues: storedValues, lut: lut)
            let metalSeconds = Date().timeIntervalSince(metalStart)
            metalReport = String(format: "metal(lut): %.4fs (%@)", metalSeconds, processor.deviceName)
        }

        print("""
        [DicomDisplayLUT benchmark] pixels=\(pixelCount) bitsStored=\(bitsStored) \
        scalar: \(String(format: "%.4f", scalarSeconds))s \
        cpu(lut): \(String(format: "%.4f", lutSeconds))s \
        \(metalReport) \
        host=\(ProcessInfo.processInfo.machineHardwareName ?? "unknown")
        """)
    }
}

private extension ProcessInfo {
    var machineHardwareName: String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return nil }
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &value, &size, nil, 0)
        let bytes = value.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
