//
//  DCMDecoderActorTests.swift
//  DicomCoreTests
//
//  Checks actor isolation across file loading, concurrent access, and multiple DICOM decoder
//  instances.
//
//  Thales Matheus Mendonça Santos — June 2026
//

import XCTest
@testable import DicomCore

final class DCMDecoderActorTests: XCTestCase {

    // MARK: - Actor Isolation Tests

    func testActorIsolation() async {
        // Test that decoder can be used inside an actor without warnings
        actor DecoderActor {
            private let decoder: DCMDecoder

            init() {
                self.decoder = DCMDecoder()
            }

            func validateDecoder() -> Bool {
                return decoder.isValid()
            }

            func getValidationStatus() -> (isValid: Bool, hasPixels: Bool) {
                let status = decoder.getValidationStatus()
                return (status.isValid, status.hasPixels)
            }

            func getDimensions() -> (width: Int, height: Int) {
                return (decoder.width, decoder.height)
            }

            func getPatientName() -> String {
                return decoder.info(for: .patientName)
            }

            func getPixelData() -> ([UInt16]?, [UInt8]?) {
                return (decoder.getPixels16(), decoder.getPixels8())
            }
        }

        // Create actor with decoder
        let decoderActor = DecoderActor()

        // Verify operations work through actor isolation
        let isValid = await decoderActor.validateDecoder()
        XCTAssertFalse(isValid, "Decoder should not be valid initially")

        let status = await decoderActor.getValidationStatus()
        XCTAssertFalse(status.isValid, "Validation status should be invalid")
        XCTAssertFalse(status.hasPixels, "Should have no pixels")

        let dimensions = await decoderActor.getDimensions()
        XCTAssertEqual(dimensions.width, 1, "Width should be 1 (default)")
        XCTAssertEqual(dimensions.height, 1, "Height should be 1 (default)")

        let patientName = await decoderActor.getPatientName()
        XCTAssertEqual(patientName, "", "Patient name should be empty")

        let pixels = await decoderActor.getPixelData()
        XCTAssertNil(pixels.0, "16-bit pixels should be nil")
        XCTAssertNil(pixels.1, "8-bit pixels should be nil")
    }

    func testActorIsolationWithFileLoading() async {
        // Test that decoder can be injected and used inside an actor
        actor DicomLoaderActor {
            private var decoder: DicomDecoderProtocol?

            func loadDecoder(_ decoder: DicomDecoderProtocol) async {
                self.decoder = decoder
            }

            func getDecoderInfo() -> (isValid: Bool, width: Int, height: Int) {
                guard let decoder = decoder else {
                    return (false, 0, 0)
                }
                return (decoder.isValid(), decoder.width, decoder.height)
            }

            func getMetadata() -> (patientInfo: [String: String], modality: String) {
                guard let decoder = decoder else {
                    return ([:], "")
                }
                return (decoder.getPatientInfo(), decoder.info(for: .modality))
            }
        }

        let mock = MockDecoderBuilder.makeDecoder(width: 64, height: 32, pixelValue: 7)
        mock.setTag(DicomTag.patientName.rawValue, value: "Actor^Patient")
        mock.setTag(DicomTag.modality.rawValue, value: "CT")

        // Create actor and inject a deterministic decoder
        let loaderActor = DicomLoaderActor()

        await loaderActor.loadDecoder(mock)

        // Verify decoder loaded successfully
        let info = await loaderActor.getDecoderInfo()
        XCTAssertTrue(info.isValid, "Decoder should be valid after loading")
        XCTAssertGreaterThan(info.width, 0, "Width should be positive")
        XCTAssertGreaterThan(info.height, 0, "Height should be positive")

        // Verify metadata access through actor
        let metadata = await loaderActor.getMetadata()
        XCTAssertFalse(metadata.patientInfo.isEmpty, "Patient info should not be empty")
        XCTAssertFalse(metadata.modality.isEmpty, "Modality should not be empty")
    }

    func testMultipleActorsWithDecoders() async {
        // Test that multiple actors can each have their own decoder instances
        actor DecoderActor {
            let id: Int
            private let decoder: DCMDecoder

            init(id: Int) {
                self.id = id
                self.decoder = DCMDecoder()
            }

            func performOperations() -> (id: Int, isValid: Bool, width: Int) {
                return (id, decoder.isValid(), decoder.width)
            }
        }

        // Create multiple actors
        let actorCount = 10
        let actors = (0..<actorCount).map { DecoderActor(id: $0) }

        // Execute operations on all actors concurrently
        await withTaskGroup(of: (Int, Bool, Int).self) { group in
            for actor in actors {
                group.addTask {
                    await actor.performOperations()
                }
            }

            var results: [(Int, Bool, Int)] = []
            for await result in group {
                results.append(result)
            }

            // Verify all actors completed successfully
            XCTAssertEqual(results.count, actorCount, "All actors should complete")
            for result in results {
                XCTAssertFalse(result.1, "Decoder in actor \(result.0) should not be valid")
                XCTAssertEqual(result.2, 1, "Width in actor \(result.0) should be 1 (default)")
            }
        }
    }

    func testActorIsolationWithConcurrentAccess() async {
        // Test that an actor with a decoder can handle concurrent access from multiple tasks
        actor SharedDecoderActor {
            private let decoder: DCMDecoder
            private var accessCount = 0

            init() {
                self.decoder = DCMDecoder()
            }

            func checkValidation() -> (count: Int, isValid: Bool) {
                accessCount += 1
                return (accessCount, decoder.isValid())
            }

            func getDimensions() -> (count: Int, width: Int, height: Int) {
                accessCount += 1
                return (accessCount, decoder.width, decoder.height)
            }

            func getMetadata() -> (count: Int, patientName: String) {
                accessCount += 1
                return (accessCount, decoder.info(for: .patientName))
            }

            func getPixels() -> (count: Int, hasPixels: Bool) {
                accessCount += 1
                let pixels = decoder.getPixels16()
                return (accessCount, pixels != nil)
            }

            func getTotalAccessCount() -> Int {
                return accessCount
            }
        }

        // Create shared actor
        let sharedActor = SharedDecoderActor()

        // Launch multiple concurrent tasks accessing the actor
        await withTaskGroup(of: Void.self) { group in
            // Launch 20 tasks performing different operations
            for i in 0..<20 {
                group.addTask {
                    switch i % 4 {
                    case 0:
                        let result = await sharedActor.checkValidation()
                        XCTAssertGreaterThan(result.count, 0, "Access count should increase")
                        XCTAssertFalse(result.isValid, "Decoder should not be valid")
                    case 1:
                        let result = await sharedActor.getDimensions()
                        XCTAssertGreaterThan(result.count, 0, "Access count should increase")
                        XCTAssertEqual(result.width, 1, "Width should be 1 (default)")
                        XCTAssertEqual(result.height, 1, "Height should be 1 (default)")
                    case 2:
                        let result = await sharedActor.getMetadata()
                        XCTAssertGreaterThan(result.count, 0, "Access count should increase")
                        XCTAssertEqual(result.patientName, "", "Patient name should be empty")
                    case 3:
                        let result = await sharedActor.getPixels()
                        XCTAssertGreaterThan(result.count, 0, "Access count should increase")
                        XCTAssertFalse(result.hasPixels, "Should not have pixels")
                    default:
                        break
                    }
                }
            }

            // Wait for all tasks to complete
            await group.waitForAll()
        }

        // Verify total access count
        let totalCount = await sharedActor.getTotalAccessCount()
        XCTAssertEqual(totalCount, 20, "All 20 operations should complete")
    }

    func testActorIsolationWithFileLoadingConcurrent() async throws {
        // Test multiple actors loading different files concurrently
        actor FileLoaderActor {
            let filePath: String
            private var decoder: DCMDecoder?

            init(filePath: String) {
                self.filePath = filePath
            }

            func loadAndValidate() async throws -> (path: String, isValid: Bool, width: Int, height: Int) {
                self.decoder = try await DCMDecoder(contentsOfFile: filePath)
                guard let decoder = decoder else {
                    throw DICOMError.fileNotFound(path: filePath)
                }
                return (filePath, decoder.isValid(), decoder.width, decoder.height)
            }
        }

        let testFiles = try [
            getCTSyntheticFixtureURL().path,
            getMRSyntheticFixtureURL().path,
            getUSSyntheticFixtureURL().path,
            getXRSyntheticFixtureURL().path
        ]

        // Create actors for each file
        let actors = testFiles.map { FileLoaderActor(filePath: $0) }

        // Load files concurrently using actors
        do {
            var successCount = 0
            try await withThrowingTaskGroup(of: (String, Bool, Int, Int).self) { group in
                for actor in actors {
                    group.addTask {
                        let result = try await actor.loadAndValidate()
                        return (result.path, result.isValid, result.width, result.height)
                    }
                }

                for try await data in group {
                    XCTAssertTrue(data.1, "File should load successfully: \(data.0)")
                    XCTAssertGreaterThan(data.2, 0, "Width should be positive for \(data.0)")
                    XCTAssertGreaterThan(data.3, 0, "Height should be positive for \(data.0)")
                    successCount += 1
                }

                XCTAssertEqual(successCount, testFiles.count, "All files should load successfully")
            }
        } catch {
            XCTFail("Failed to load file in actor: \(error)")
        }
    }
}
