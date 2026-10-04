# 2.0.0-rc.2

This source-package release candidate adds DICOMweb client robustness work on
top of 2.0.0-rc.1. It does not represent a stable application release. Swift
tools 6.2, Swift 6 language mode and iOS, visionOS or macOS 26.0+ are
unchanged, and so are the announced products.

## DICOMweb client changes

- Response bodies are read in blocks rather than byte by byte. Bodies that are
  not consumed spill to a file. Requests to the same host share connections.
  Body blocks that arrived before a dropped connection are still delivered.
- `DicomWebClientConfiguration.retryPolicy` retries transient failures: GET on
  408, 429, 502, 503, 504 and connection failures, STOW-RS only on 429, 503 or
  when no answer arrived, honouring a bounded Retry-After. The default is
  `DicomWebRetryPolicy.none`: a request is sent once unless the application
  opts in. Errors keep the server's diagnostic text.
- `instanceAccept(transferSyntaxUIDs:fallbackStatuses:)` returns an ordered
  `DicomWebAcceptList`, and a retrieve asks again with the next syntax after a 406.
- QIDO paging removes duplicate results and stops on a page that repeats
  earlier results without adding a UID, or on its paging limits.
- Bulk-data retrieval keeps every part, resolves bulk-data URIs against the
  metadata and accepts range responses.
- A streamed request body is reopened when URLSession must send it again, and
  a failed STOW-RS batch keeps its URL error code.

## Behaviour changes

`swift package diagnose-api-breaking-changes 2.0.0-rc.1 --products
DicomWebClient` reports two changed initializers:
`DicomWebStoreFileResult.init(url:sopInstanceUID:state:reason:dicomStatus:httpStatus:)`
gained `transportErrorCode:` and `DicomWebRedirectDelegate.init(policy:credentialHeaderNames:followsRedirects:)`
gained `bodyFileURL:`. Both new parameters have defaults, so existing calls
still compile; only the binary signatures changed. Other additions also carry
defaults.

Header values now send RFC 9110 token parameters such as a transfer syntax UID
or `*` unquoted, as dcm4che and dicomweb-client do. `type` remains quoted.
The legacy study search, metadata and UPS calls report HTTP failures as
`DicomWebError`, like the other operations, instead of
`DicomWebClientError.httpStatus`. Applications that matched the old case should
read `DicomWebError.statusCode`.

The DICOMweb server in `DicomCore` serves stored syntaxes it cannot send as
Explicit VR Little Endian and can start on a fixed port and bind address. Byte
swapping during transcoding between byte orders was corrected.

Use the exact `2.0.0-rc.2` version and the consumer's own resolved lockfile.

## Executed validation

The release tree was exported from the canonical package and compared with the
public mirror. Sources, tests and the manifest were identical, apart from the
declared documentation adaptations. The export tool's `verify` operation matched
all recorded distribution files. Apple Swift 6.4, the macOS 27.0 SDK and an
arm64 host were used:

- The existing public-API consumer passed in Debug and Release against the
  mirror: QIDO, bounded wire bytes, retrieve to a file sink, STOW files and
  batches. Its build outputs and linked frameworks again excluded Core, codecs,
  DIMSE, listener, ZIP, SwiftUI, Metal and Network framework dependencies.
- Eleven client XCTest suites, the ones changed since rc.1 plus media type and
  streaming transport, executed 99 cases. All 99 passed, with no failures and
  no skips.

The full suite, the `release` gate and optional runtimes were not run for this
candidate. The limits stated for 2.0.0-rc.1 still apply.

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
