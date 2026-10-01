# 2.0.0-rc.1

This is a source-package release candidate with the independent DICOMweb
client. It does not represent a stable application release.

## Requirements and breaking changes

The package compiles in Swift 6 language mode instead of the public 1.5.0
line's Swift 5 mode. Swift tools 6.2 and iOS, visionOS or macOS 26.0+ remain
the minimums already required by 1.5.0; this release does not raise them.
The language-mode change and reorganized module/API ownership support a new
major version. Review imports, concurrency diagnostics and public API usage
when moving to this line.

The independent `DicomWebClient` product owns QIDO-RS, WADO-RS retrieval into
sinks, file-backed STOW-RS/batches, multipart handling, authentication and
client transport/error types. Import `DicomWebClient` for these APIs and
`DicomData` for typed datasets, Part 10/UID utilities and DICOM JSON/XML.
`searchResponse` provides bounded wire bytes without dataset normalization.
`DicomCore` consumes/reexports the same implementation. Selecting only the
client product keeps Core, codecs, DIMSE, the HTTP listener, UI and ZIP out of
the compiled client graph; SwiftPM can still resolve dependencies used by other
products. Applications retain their own transport and destination policies.

Use the exact `2.0.0-rc.1` version and the consumer's own resolved lockfile.
A `from: "1.0.0"` requirement cannot select this 2.x candidate. Migration does
not require copying package sources or patching a resolved checkout.

## Networking changes

File-backed STOW validates File Meta Information within an independent bound
and preserves accepted instance bytes. Chunk reads/writes have bounded temporary
buffer lifetimes; cancellation and failures clean up owned staging files.
QIDO validates response MIME and keeps the documented JSON/204 behavior.
Strict DICOM retrieval checks response metadata against actual Part 10 File Meta
Information across chunks, rejects mismatches and preserves generic rendered/
bulk-data sinks. Credentials, destinations and HTTP policy remain application
responsibilities.

## Distribution and attribution

All announced package products, tests/resources, examples and pertinent recipes
remain present, with internally incorporated codec sources and original notices.
No binary framework or binary release asset is required. The public mirror
retains its prior Git history. DistributionContents.json records exact exported
hashes and declared documentation/material adaptations; DistributionProvenance.json
is derived from the existing component inventory. LICENSE, component notices
and source modification notices remain attached. An unknown original port
revision remains unknown.

## Executed validation

The independent export was tested using Apple Swift 6.4, the macOS 27.0 SDK
and an arm64 host, with its own scratch directories and caches:

- The existing public-API consumer passed in both Debug and Release: QIDO,
  bounded wire bytes, retrieve to a file sink, STOW files and batches. Its build
  outputs and linked frameworks excluded Core, codecs, DIMSE, listener, ZIP,
  SwiftUI, Metal and Network framework dependencies.
- Fourteen client XCTest suites executed 114 cases: 113 passed, no failures,
  and one optional external Orthanc case skipped because its endpoint was not
  configured. That skipped case is not a pass.
- The two Data fidelity/binary suites passed all 26 cases, including synthetic
  corpus export; this does not claim an independent external oracle run.
- Target boundaries, the exported manifest, source/material hashes and recipe
  identity passed. All 2,512 exported files matched the recorded content after
  execution. Documentation/material adaptations were declared; Swift production
  sources were not transformed by export.

Separate canonical integration evidence was reused for identical sources:
Core/HTTP/CLI builds and 122 unique cases approved in aggregate (117 initial
passes plus five focused retries), and 88 application-transport cases approved
in aggregate (73 initial passes, one corpus retry and 14 request-factory cases).
Those are distinct from new standalone export execution and are not presented
as fresh complete-suite runs. The combined canonical lint passed.

## Performance and remaining limits

One Debug comparative campaign used the existing synthetic file-backed STOW
workload with three 48 MiB instances and two samples per variant. Observed
process-footprint growth decreased from approximately 150–151 MiB to
7.63–9.19 MiB; wire bytes, UIDs, syntax, payload hashes and original files were
preserved. Mean elapsed time increased descriptively by 2.65%, with variation
greater than that delta. With two samples this is statistically inconclusive,
not a latency guarantee or speed claim.

The comparative Release test instrument could not compile a compatible test
module, so it produced zero samples. No Release memory/latency equivalence is
claimed. The independent production consumer's successful Release build/run is
separate functional evidence. No new performance instrument or repeated campaign
was added for export.

The application's shared full gate, UI smoke and main integration remain pending;
this package candidate does not establish stable app acceptance. Apple media,
Metal, optional codec runtimes and external corpus/oracle/service cases retain
their documented conditions. This release does not claim execution of the whole
optional-runtime matrix or validation on every supported platform/architecture.
