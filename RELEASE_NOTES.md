# 2.0.1

This patch release of the `DicomWebClient` product changes how the built-in
URLSession transport uses the URL cache, found while running the interop smoke
against dcm4chee. Swift tools 6.2, Swift 6 language mode, iOS, visionOS or
macOS 26.0+ and the announced products are those of 2.0.0, and no public API
changed. A `from: "2.0.0"` requirement selects 2.0.1.

## Fixed

- `URLSessionDicomWebHTTPTransport` sends every request to the server, and the
  response reader that it and other transports share through
  `URLSession.dicomWebResponse(for:delegate:)` stores no response in the URL
  cache. dcm4chee 5.35 gives all representations of an instance one `ETag`,
  sends no `Vary: Accept` and answers a conditional request with 304 whatever
  the Accept. With a session that had a URL cache, as `URLSession.shared` has,
  a retrieve asking for another transfer syntax could be answered with the
  representation retrieved earlier without reaching the server, and DICOM
  response bodies could be written to that cache.

## Interoperability

- The interop compose file now uses dcm4chee tags that exist,
  `slapd-dcm4chee:2.6.14-35.2`, `postgres-dcm4chee:18.3-35` and
  `dcm4chee-arc-psql:5.35.2`, points the archive at its LDAP and PostgreSQL
  services and keeps PostgreSQL 18's data where the dcm4chee init scripts
  expect it. `run_interop_smoke.sh` falls back to the standalone
  `docker-compose` and waits for the archive's AE list with a deadline.
- dcm4chee refuses an Accept it cannot transcode with 500, not 406. A caller
  that wants the as-stored fallback from such a server adds 500 to the
  `fallbackStatuses` of its `DicomWebAcceptList`, as the smoke does for
  dcm4chee. It refuses an instance of another study with 409 and Failure
  Reason 0xC409.

## Executed validation

Apple Swift 6.4, the macOS 27.0 SDK and an arm64 host were used. The release
tree was exported from the canonical package; it matched the public mirror
apart from the refreshed `DistributionContents.json`, and the export tool's
`verify` operation matched all recorded distribution files.

- `Scripts/interop/run_interop_smoke.sh`, with Docker through Colima, against
  dcm4chee 5.35.2 and Orthanc 1.13.0: all 11 `DicomInteropSmokeTests` passed,
  none skipped, in two consecutive runs, with the dcm4chee smoke study
  rejected (`113039^DCM`) after each run.
- `DicomWebIndependentClientTests` (dicomweb-client 0.61.2) and
  `DicomWebUPSRSIndependentTests` (`requests`, `websockets` 17.1) passed with
  `DICOM_REQUIRE_PYNETDICOM=1`, none skipped.
- The `DicomWebClientTests` suites that run through the URLSession transport,
  including the new URL-cache case, and `DicomInteropScriptTests` executed 89
  cases: all passed, none skipped.
- The existing public-API consumer passed in Debug and Release against the
  exported tree, and its build outputs again excluded Core, codecs, DIMSE, the
  listener, ZIP, SwiftUI, Metal and Network framework dependencies.
- `swift package diagnose-api-breaking-changes 2.0.0 --products
  DicomWebClient` reported no breaking change.

## Known limits

- dcm4chee was run with the unsecured `dcm4chee-arc-psql` image and its
  default configuration; Keycloak-secured archives were not exercised.
- The full suite, the `release` gate and optional runtimes were not run for
  this release. The other limits of 2.0.0 still apply.

# 2.0.0

This is the first stable 2.x source-package release. It consolidates
2.0.0-rc.1, rc.2 and rc.3, whose sections below keep the detail, and adds the
documentation corrections made after rc.3. Since rc.3 only the text of the
DICOMweb server's conformance matrix, its test and the documentation changed;
the `DicomWebClient` and `DicomWebOIDC` sources are those of rc.3.

## Requirements and products

Swift tools 6.2 and iOS, visionOS or macOS 26.0+ remain the minimums of 1.5.0.
The package now compiles in Swift 6 language mode instead of Swift 5.

1.5.0 announced `DicomCore` and `dicomtool`. 2.0.0 announces the libraries
`DicomData`, `DicomCore`, `DicomCodecs`, `DicomObjects`, `DicomNetwork`,
`DicomWebClient`, `DicomWebOIDC`, `DicomWebHTTP`, `DicomDocumentContent`,
`DicomAppleMedia`, `DicomSwiftUI`, `HL7v2`, `HL7MLLP`, `HL7v3CDA`,
`HL7v3Transport`, `FHIR` and `ClinicalMapping`, and the executables
`dicomtool`, `hl7tool` and `DicomSwiftUIExample`. The JPEG 2000, JPEG-LS and
JPEG XL codecs are incorporated sources with their original notices; the
J2KSwift, JLSwift and JXLSwift package dependencies are gone. The remaining
package dependencies are swift-argument-parser, ZIPFoundation and
swift-docc-plugin. No binary framework or binary release asset is required.

Use `.package(url: "https://github.com/ThalesMMS/DICOM-Swift.git", from:
"2.0.0")` and commit the consumer's own resolved lockfile. A `from: "1.0.0"`
requirement cannot select 2.x.

## Breaking changes since 1.5.0

- The Swift 6 language mode and the reorganized module and API ownership
  break source compatibility. `DicomData` owns typed datasets, Part 10, UIDs
  and DICOM JSON/XML; `DicomWebClient` owns QIDO-RS, WADO-RS, STOW-RS,
  multipart, authentication and the client transport and error types, which
  `DicomCore` reexports. Review imports, concurrency diagnostics and public
  API usage.
- The legacy study search, metadata and UPS calls report HTTP failures as
  `DicomWebError` instead of `DicomWebClientError.httpStatus`; read
  `DicomWebError.statusCode`.
- Header values send RFC 9110 token parameters, such as a transfer syntax UID
  or `*`, unquoted. `type` remains quoted.
- The default rendered and thumbnail `Accept` asks for one image type, and a
  4xx answer that carries a DICOM store response is returned as store results
  instead of thrown.
- Between candidates, `swift package diagnose-api-breaking-changes` on the
  `DicomWebClient` product reported two initializers that gained a defaulted
  parameter in rc.2, `DicomWebStoreFileResult.init(...transportErrorCode:)`
  and `DicomWebRedirectDelegate.init(...bodyFileURL:)`, and no break in rc.3.
  Existing calls still compile.

## DICOMweb client

- Selecting only `DicomWebClient` keeps Core, codecs, DIMSE, the HTTP
  listener, UI and ZIP out of the compiled client graph. `searchResponse`
  gives bounded wire bytes without dataset normalization.
- STOW-RS is file-backed and validates File Meta Information within its own
  bound. Through a `DicomWebStreamedBodyTransport`, as the built-in transport
  is, each instance is read straight from its file. `storeFiles` results keep
  the answer's `Warning` header and the `DicomWebError` that failed a batch.
- Retrieval checks response metadata against the Part 10 File Meta
  Information, asks again with the next transfer syntax of an ordered
  `DicomWebAcceptList` after a 406, keeps every bulk-data part, resolves
  bulk-data URIs against the metadata and accepts range responses.
- Response bodies are read in blocks, unconsumed bodies spill to a file and
  requests to the same host share connections. `retryPolicy`, off by default,
  retries transient failures within a bounded Retry-After.
- QIDO paging removes duplicate results and stops on a repeated page or at its
  paging limits. Study, series and instance metadata are decoded as their
  DICOM JSON arrives, and invalid elements are read tolerantly within the
  same limits.
- Rendered and thumbnail retrieves of studies, series, instances and frames
  take window, viewport and quality options. A multi-frame rendered request
  refused with 400, 406 or 415 is asked again one frame at a time.
- A `DicomWebAuthorizationProvider` supplies credentials for each request and
  renews them once after a 401. `serverTrust` adds trust anchors or a pinned
  leaf certificate hash, keeping host name and date checks, and
  `clientIdentity` answers a client-certificate request. The `DicomWebOIDC`
  product signs a public client in with OpenID Connect (authorization code
  with PKCE S256, ID-token verification, shared refresh), with no UI or token
  store of its own.

## DICOMweb server in DicomCore

The server pages study, series and instance searches through injected
providers, answers 405 to a method a resource does not serve and 204 to a
search without matches, matches any dictionary keyword or tag, reports ignored
parameters with Warning 299 and can build its URLs from a public base URL or
forwarded headers. It serves stored syntaxes it cannot send as Explicit VR
Little Endian and can start on a fixed port and bind address. After rc.3, the
rows of `DicomWebConformanceMatrix` for bulk data, multipart, authentication,
pagination and error semantics, the README summary and the conformance
statement describe this current behaviour.

## Executed validation

The release tree was exported from the canonical package and compared with the
public mirror. Sources, tests and the manifest were identical, apart from the
declared documentation adaptations. The export tool's `verify` operation matched
all recorded distribution files. Apple Swift 6.4, the macOS 27.0 SDK and an
arm64 host were used:

- The existing public-API consumer passed in Debug and Release against the
  exported tree: QIDO, bounded wire bytes, retrieve to a file sink, STOW files
  and batches. Its build outputs and linked frameworks again excluded Core,
  codecs, DIMSE, listener, ZIP, SwiftUI, Metal and Network framework
  dependencies.
- Fourteen client XCTest suites, the `DicomWebOIDC` and DICOM JSON stream
  decoder suites, the documentation reconciliation suite and the server's
  conformance matrix documentation case executed 140 cases: 139 passed, no
  failures, and one optional external Orthanc case skipped because its
  endpoint was not configured. That skipped case is not a pass.

## Known limits

- Interoperability was checked against a local Orthanc during the candidates.
  The interop run against dcm4chee and the probe with the Python
  dicomweb-client have not been run for this release.
- The full suite, the `release` gate and optional runtimes were not run for
  this release. Apple media, Metal, optional codec runtimes and external
  corpus, oracle and service cases keep their documented conditions, and no
  claim covers every supported platform or architecture.
- Some v1 APIs that the migration guide planned to remove in 2.0.0, such as
  `setDicomFilename(_:)`, `loadDICOMFileAsync(_:)`, the tuple
  `windowSettings` property and the async pixel wrappers, are still present in
  this release.
- The performance limits stated for 2.0.0-rc.1 still apply.

# 2.0.0-rc.3

This source-package release candidate adds DICOMweb client, server and
authentication work on top of 2.0.0-rc.2. It does not represent a stable
application release. Swift tools 6.2, Swift 6 language mode and iOS, visionOS
or macOS 26.0+ are unchanged. One product is added, `DicomWebOIDC`; the other
announced products are unchanged.

## DICOMweb client changes

- STOW-RS through a `DicomWebStreamedBodyTransport`, as the built-in transport
  is, reads each instance straight from its file, with no copy of the batch on
  disk. Any other transport still receives the body staged in a temporary
  file. A 4xx answer that carries a DICOM JSON or XML store response, such as a
  400 with a Failed SOP Sequence, is returned as a result with each instance's
  Failure Reason, like a 409; 401, 403, 404 and 429 still throw.
- `storeFiles` results keep the answer's `Warning` header and, in the new
  `error` property, the `DicomWebError` that failed the file's batch or stopped
  the store before it, with what the server said about it.
- A `DicomWebAuthorizationProvider` set as the client's `authorizationProvider`
  supplies credential headers for each request and renews them once after a
  401, which repeats the request once. The new `DicomWebOIDC` product signs a
  public client in with OpenID Connect (discovery, authorization code with PKCE
  S256, ID-token verification, shared refresh), without UI or a token store of
  its own.
- `DicomWebClientConfiguration.serverTrust` can add trust anchors or a leaf
  certificate hash, keeping the host name and date checks, and `clientIdentity`
  answers a server that requires a client certificate.
- Rendered and thumbnail retrieves of studies, series, instances and frames
  take window, viewport and quality options (`DicomWebRenderedOptions`). Their
  default `Accept` now asks for one image type, because some servers refuse a
  list. A multi-frame rendered request refused with 400, 406 or 415 is asked
  again one frame at a time.
- Study, series and instance metadata are decoded as their DICOM JSON arrives
  (`DicomJSONStreamDecoder`), and invalid elements are read tolerantly within
  the same limits.
- Multipart parts inherit the outer `type` parameter, and delimiter candidates
  are checked in one pass over the raw bytes.

## Behaviour changes

`swift package diagnose-api-breaking-changes 2.0.0-rc.2 --products
DicomWebClient` reports no breaking change. The default rendered and thumbnail
`Accept` headers and the store results of 4xx answers changed as described
above.

The DICOMweb server in `DicomCore` answers 405 to a method a resource does not
serve and 204 to any search without matches. It matches any dictionary keyword
or tag, reports the parameters it ignored with Warning 299, and can build its
URLs from a configured public base URL or forwarded headers.

Use the exact `2.0.0-rc.3` version and the consumer's own resolved lockfile.

## Executed validation

The release tree was exported from the canonical package and compared with the
public mirror. Sources, tests and the manifest were identical, apart from the
declared documentation adaptations. The export tool's `verify` operation matched
all recorded distribution files. Apple Swift 6.4, the macOS 27.0 SDK and an
arm64 host were used:

- The existing public-API consumer passed in Debug and Release against the
  exported tree: QIDO, bounded wire bytes, retrieve to a file sink, STOW files
  and batches. Its build outputs and linked frameworks again excluded Core,
  codecs, DIMSE, listener, ZIP, SwiftUI, Metal and Network framework
  dependencies.
- Twelve client XCTest suites, the ones changed since rc.2 plus media type,
  and the `DicomWebOIDC` and DICOM JSON stream decoder suites, executed 113
  cases. All 113 passed, with no failures and no skips.

The full suite, the `release` gate and optional runtimes were not run for this
candidate. The limits stated for 2.0.0-rc.1 still apply.

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
