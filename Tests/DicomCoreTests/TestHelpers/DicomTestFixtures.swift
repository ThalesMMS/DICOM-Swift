import Foundation
import XCTest
import DicomTestSupport

/// Computes the URL for the `Fixtures` directory used by tests, located relative to this source file.
/// - Returns: A `URL` pointing to the `Fixtures` directory.
func getFixturesPath() -> URL {
    DicomTestFixtures.directory
}

/// Locate the CT synthetic DICOM fixture and return its file URL.
/// - Returns: The `URL` of the CT synthetic DICOM fixture file (`CT/ct_synthetic.dcm`).
/// - Throws: `DicomRuntimeRequirementError` if the required bundled fixture is missing.
func getCTSyntheticFixtureURL() throws -> URL {
    try requireFixtureURL(relativePath: "CT/ct_synthetic.dcm")
}

/// Locate the MR synthetic DICOM fixture URL.
/// - Returns: The file URL for "MR/mr_synthetic.dcm" inside the test Fixtures directory.
/// - Throws: `DicomRuntimeRequirementError` when the required bundled fixture is missing.
func getMRSyntheticFixtureURL() throws -> URL {
    try requireFixtureURL(relativePath: "MR/mr_synthetic.dcm")
}

/// Locate and return the file URL for the US synthetic DICOM fixture.
/// - Returns: The file URL for "US/us_synthetic.dcm".
/// - Throws: `DicomRuntimeRequirementError` if the required bundled fixture is missing.
func getUSSyntheticFixtureURL() throws -> URL {
    try requireFixtureURL(relativePath: "US/us_synthetic.dcm")
}

/// Locate the XR synthetic DICOM fixture.
/// - Returns: The filesystem URL to the "XR/xr_synthetic.dcm" file inside the Fixtures directory.
/// - Throws: `DicomRuntimeRequirementError` if the required bundled fixture is missing.
func getXRSyntheticFixtureURL() throws -> URL {
    try requireFixtureURL(relativePath: "XR/xr_synthetic.dcm")
}

/// Finds and returns the first DICOM file URL inside the project's Fixtures directory.
/// 
/// Searches the Fixtures directory for a file whose extension is `dcm` or `dicom` and returns its URL.
/// - Returns: The file URL of the first DICOM file found.
/// - Throws: `DicomRuntimeRequirementError` if required bundled fixtures are missing.
func getAnyFixtureDICOMURL() throws -> URL {
    try DicomTestRuntimePreflight.require(.bundledSyntheticFixtures)
    let fixturesPath = getFixturesPath()

    guard FileManager.default.fileExists(atPath: fixturesPath.path) else {
        throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
            capability: .bundledSyntheticFixtures,
            kind: .regression,
            message: "Fixtures directory not found at \(fixturesPath.path)."
        ))
    }

    let enumerator = FileManager.default.enumerator(at: fixturesPath, includingPropertiesForKeys: nil)
    var candidates: [URL] = []
    while let fileURL = enumerator?.nextObject() as? URL {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "dcm" || ext == "dicom" {
            candidates.append(fileURL)
        }
    }

    if let first = candidates.sorted(by: { $0.path < $1.path }).first {
        return first
    }

    throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
        capability: .bundledSyntheticFixtures,
        kind: .regression,
        message: "No DICOM files found in required bundled Fixtures directory."
    ))
}

/// Resolve the URL for a file located under the test Fixtures directory or skip the test if it is missing.
/// - Parameters:
///   - relativePath: Path to the fixture file relative to the Fixtures directory (e.g. "CT/ct_synthetic.dcm").
/// - Returns: The file `URL` for the requested fixture.
/// - Throws: `DicomRuntimeRequirementError` when the required bundled fixture is missing.
private func requireFixtureURL(relativePath: String) throws -> URL {
    try DicomTestRuntimePreflight.require(.bundledSyntheticFixtures)
    let url = getFixturesPath().appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw DicomRuntimeRequirementError(status: DicomRuntimeStatus(
            capability: .bundledSyntheticFixtures,
            kind: .regression,
            message: "Required fixture '\(relativePath)' not found."
        ))
    }
    return url
}
