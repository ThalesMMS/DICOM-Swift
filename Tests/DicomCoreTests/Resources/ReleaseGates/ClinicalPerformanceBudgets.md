# Clinical Performance Budgets

`ClinicalPerformanceBudgetManifest.json` is the DICOM-Swift side of the issue
#1436 correctness-first performance contract. It references fixture and backend
qualification from `ClinicalCodecConformanceManifest.json`.

The manifest distinguishes cold SDK, prewarmed first-clinical-call, isolated
warm, sustained warm, concurrent, and fallback modes. It declares PR, nightly,
release, and manual-device tiers; JSON/CSV/Markdown output; host-comparison
keys; and workflow collectors for codecs, partial decode, JPIP, JP3D, CPU/Metal
display, memory, copies, temporary I/O, and command buffers.

Run the DICOM-Swift contract gate directly with:

```bash
swift test --package-path DICOM-Swift --filter PerformanceBudgetTests
swift test --package-path DICOM-Swift --filter ClinicalPerformanceReporterTests
```

Run the integrated cross-component PR tier from the Isis repository root:

```bash
Tools/Scripts/Performance/run_clinical_performance_gates.sh pr-smoke
```

Correctness always runs before performance. Absolute warning/failure budgets
apply without a baseline; relative warning/failure deltas apply only to the
same host, OS, architecture, build, mode, fixture, tier, and CLI-startup scope.
Reports contain aggregate measurements and non-PHI fixture identifiers only.
