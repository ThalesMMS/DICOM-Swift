# DICOM Advanced Parity Matrix

This matrix tracks the fixture-manifest feature IDs validated by
`ClinicalParityFixtureManifestTests`. The rows are intentionally not marked done
until their codec or object-specific parity issues carry executable evidence.

| Feature ID | Issue | Status | Evidence |
| --- | --- | --- | --- |
| uncompressed | #1052 | In progress | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| jpeg-lossless | #1065 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| jpeg-2000 | #1065 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| rle | #1065 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| multiframe | #1052 | In progress | `Tests/DicomCoreTests/Fixtures/DecoderParity/us_multiframe_metadata.dcm` |
| seg | #1073 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| rtstruct | #1073 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| rtdose | #1073 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| sr-tid1500 | #1071 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| pr | #1073 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| hp | #1073 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| rwv | #1073 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| pmap | #1073 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| dicomdir | #1073 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| encapsulated-pdf | #1073 | Planned | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalParityFixtureManifest.json` |
| waveform | #1073 | Done: scoped helper matrix and tests | `DicomExportSupportMatrix.packageDefault`; `Tests/DicomCoreTests/DicomWaveformTests.swift` |
| video | #1073 | Done: scoped stream-forwarding matrix and tests | `DicomExportSupportMatrix.packageDefault`; `Tests/DicomCoreTests/DicomVideoTests.swift` |
| performance-budgets | #282 | Done: performance budget manifest | `Tests/DicomCoreTests/Resources/ReleaseGates/ClinicalPerformanceBudgetManifest.json`; `Tests/DicomCoreTests/PerformanceBenchmarks/PerformanceBudgetTests.swift` |
| public-api-docs | #283 | Done: documentation manifest | `Tests/DicomCoreTests/Resources/ReleaseGates/PublicAPIDocumentationManifest.json`; `Tooling/check_public_api_docs.py`; `Tests/DicomCoreTests/PublicAPIDocumentationPolicyTests.swift` |
