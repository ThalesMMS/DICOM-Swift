import Foundation
@testable import DicomCore
import XCTest

final class DicomDIMSEServiceSCUArchitectureTests: XCTestCase {
    func test_facadeKeepsOperationsAndNetworkSubsystemsInFocusedFiles() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DicomCore")
        let facade = try source(named: "DicomDIMSEServiceSCU.swift", in: sourceRoot)
        let focusedSources = [
            "DicomDIMSEModels.swift": "public struct DicomDIMSEConnectionConfiguration",
            "DicomDIMSEServiceSCU+Verification.swift": "public func verify(",
            "DicomDIMSEServiceSCU+QueryRetrieve.swift": "public func get(",
            "DicomDIMSEServiceSCU+Storage.swift": "public func store(",
            "DicomDIMSEServiceSCU+NormalizedOperations.swift": "public func sendPrintJob(",
            "DicomDIMSEServiceSCU+Session.swift": "func openAssociation(",
            "DicomDIMSEMessageReader.swift": "final class DicomDIMSEMessageReader",
            "DicomTCPAssociationTransport.swift": "public final class DicomTCPAssociationTransport"
        ]

        XCTAssertTrue(facade.contains("public struct DicomDIMSEServiceSCU"))
        XCTAssertFalse(facade.contains("public func verify("))
        XCTAssertFalse(facade.contains("final class DicomDIMSEMessageReader"))
        XCTAssertFalse(facade.contains("final class DicomTCPAssociationTransport"))

        for (fileName, requiredDeclaration) in focusedSources {
            let source = try source(named: fileName, in: sourceRoot)
            XCTAssertTrue(
                source.contains(requiredDeclaration),
                "\(fileName) must own \(requiredDeclaration)"
            )
        }
    }

    private func source(named fileName: String, in sourceRoot: URL) throws -> String {
        try String(
            contentsOf: sourceRoot.appendingPathComponent(fileName),
            encoding: .utf8
        )
    }
}
