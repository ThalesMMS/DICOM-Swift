# DICOM Interop Smoke Tests

This directory contains the opt-in local interop harness for QA-03 (#281).
The regular unit test cycle does not start network services. The smoke tests
only run when `DICOM_INTEROP_SMOKE=1`.

## Local Run

### Audit receiver and secure defaults (#2359)

`dicomtool audit receive` is a loopback syslog receiver; `audit emit` sends
PS3.15-format messages and `audit validate` checks XML structure, not a full
Relax NG schema. The [security loopback recipe](../../DISTRIBUTION.md)
covers receive/emit, synthetic TLS identities and explicit lab listeners.
Syslog uses RFC 5424/RFC 6587 framing and RFC 5425 TLS. These witnesses do not
establish ATNA/HIPAA compliance or deployed-collector interoperability.

`dicomtool web serve` and `net listen` always supply exposure policy and refuse
non-loopback binding without TLS plus authentication unless `--intranet-lab`
is explicit. The lab exception records a finding and never applies to external
mode. Legacy toolkit hosts may omit policy; DIMSE still defaults to binding all
interfaces in that case. AE Titles and peer addresses are not principals.

### Existing local harness

For routing/webhook loopback work, `dicomtool webhook receive` is the local
signed-event receiver. `dicomtool delivery enqueue|run|status|cancel|requeue`
exercises the durable outbox; `dicomtool webhook send|verify` supplies direct
diagnostics. The [routing and webhooks recipe](../../DISTRIBUTION.md)
uses `webhook receive` with `delivery run`. This HTTP loopback witness does not
qualify HTTPS transport to a hosted receiver.

```bash
cd DICOM-Swift
Scripts/interop/run_interop_smoke.sh
```

The script starts local Orthanc and dcm4chee containers, waits for their HTTP
surfaces, exports the endpoint variables consumed by `DicomInteropSmokeTests`,
and writes failure diagnostics to `.build/interop-logs/`.

Use `--orthanc-only` for a quicker local loop, `--keep` to leave services up for
manual debugging, or `--no-up` to run against services you started yourself.

Without Docker, `--no-up --orthanc-only` runs against Orthanc binaries started
by hand: one Orthanc with the DICOMweb plugin, DICOM AET `ORTHANC`, and a
`MTKSMOKE` modality at `127.0.0.1` on the Storage SCP port, and a second one
with `AuthenticationEnabled` and the registered user `smoke`. Point the script
at them with `ORTHANC_HTTP_PORT`, `ORTHANC_AUTH_HTTP_PORT`, `ORTHANC_DIMSE_PORT`
and `DICOM_INTEROP_STORAGE_SCP_PORT`, and give each a temporary database.

The smoke stores fixed UIDs. When dcm4chee is among the archives, the script
rejects the smoke study with `POST {DICOMweb}/studies/{uid}/reject/113039%5EDCM`
(Data Retention Policy Expired) after every run, passed or failed, so the run
can be repeated. Orthanc accepts the same instances again and needs no cleanup.

## CI Opt-In

The smoke group is safe to add as an opt-in CI job:

```bash
cd DICOM-Swift
DICOM_INTEROP_SMOKE=1 Scripts/interop/run_interop_smoke.sh
```

The fast test suite can still run all normal unit tests without Docker because
`DicomInteropSmokeTests` skips unless `DICOM_INTEROP_SMOKE=1`.

## Endpoints

Default endpoints:

| Archive | DIMSE | DICOMweb |
| --- | --- | --- |
| Orthanc | `127.0.0.1:4242`, called AE `ORTHANC` | `http://127.0.0.1:8042/dicom-web` |
| dcm4chee | `127.0.0.1:11112`, called AE `DCM4CHEE` | `http://127.0.0.1:8080/dcm4chee-arc/aets/DCM4CHEE/rs` |

The compose file uses `orthancteam/orthanc` and `dcm4che/dcm4chee-arc-psql`
families. Override image tags through `ORTHANC_IMAGE`,
`DCM4CHEE_ARC_IMAGE`, `DCM4CHEE_DB_IMAGE`, and `DCM4CHEE_LDAP_IMAGE` when a
specific local or CI environment needs pinned versions.

## Coverage

`DicomInteropSmokeTests` covers:

- DICOMweb STOW-RS, QIDO-RS, and WADO-RS metadata retrieval.
- STOW-RS in batches of two (`storeFiles`) where the archive refuses one
  instance of another study and stores the rest of the batch.
- Paged QIDO-RS at instance level with `limit=1`, each instance returned once.
- WADO-RS retrieve of the study, the series and one instance.
- Frames with `transfer-syntax=*` and with plain `application/octet-stream`.
- An Accept with an unknown transfer syntax, refused alone, then retrieved
  through a `DicomWebAcceptList` that falls back to `transfer-syntax=*`.
- The `BulkDataURI` values of three 8 KiB palette color LUTs, resolved with
  `resolveBulkData(in:)` and compared byte for byte.
- DIMSE C-ECHO, C-STORE, and C-FIND for configured archives.
- DIMSE C-GET for archives declaring `dimse-get`.
- C-MOVE into a local Storage SCP (`DicomStorageSCPServer`) and
  received-instance storage for archives declaring `dimse-move` and
  `storage-scp`.
- Stable C-FIND attribute assertions at STUDY and SERIES level (patient
  ID/name, series UID, modality), issue #1223.
- Query cancellation through `DicomDIMSEOperationHandle` surfacing the
  typed `operationCancelled` error.
- Retry-policy and TLS-against-plaintext failure paths surfacing their errors
  instead of hiding them: a typed `DicomNetworkError`, or the connection's own
  refusal (`ECONNREFUSED`), which the TCP transport keeps unwrapped.
- Authenticated DICOMweb path against the `orthanc-auth` service (valid
  Basic credentials round-trip STOW/QIDO; invalid credentials surface the
  typed HTTP 401). Local-only credentials: `smoke` /
  `ORTHANC_AUTH_PASSWORD` (default `smoke-secret`).
- WADO-RS metadata `BulkDataURI` resolution and retrieval of the pixel data.
- PHI-free diagnostics: audit events and error bodies are asserted not to
  carry the fixture's patient name/ID.

Failures keep the service logs and Swift test output under
`.build/interop-logs/` so CI artifacts have enough detail for diagnosis.

### Recorded runs

- 2026-10-04, Apple Silicon, without Docker: Orthanc 1.13.0 with DICOMweb
  plugin 1.24 (macOS package 26.9.1), `--no-up --orthanc-only`. All 11
  `DicomInteropSmokeTests` passed, none skipped, in three consecutive runs on
  the same database. Orthanc answers an Accept it cannot satisfy with 400, not
  406, so the smoke counts 400 as a fallback status; it refuses an instance of
  another study with 409 and Failure Reason 0x0110 while storing the rest of
  the request.
- dcm4chee 5.35 has no recorded run: that host had no container runtime. The
  dcm4chee cases and the rejection cleanup are implemented but not exercised.

## Independent pynetdicom peer (Lot A1)

`pynetdicom_peer.py` takes one JSON object on stdin or as its first argument.
It requires pynetdicom 3.0.4 and pydicom 3.0.2. No library is patched.

```sh
printf '%s\n' '{"role":"scp","port":0,"aet":"PYNETDICOM","max_pdu":1024}' | /tmp/isis-2321-iod-oracle/bin/python Scripts/interop/pynetdicom_peer.py
```

SCP stdout reports `{"ready":true,"port":...}`; SIGTERM ends the peer and emits
JSON evidence: received request items, async proposals, command IDs, response
statuses/counters, stored UIDs/syntaxes/payload SHA-256, maximum outstanding count
and cancellation. Optional `ready_path` and `result_path` mirror the JSON to files.
The Swift launcher allocates temporary paths and waits for the readiness handshake.

Configuration:

- `services` (SOP Class UID list), `syntaxes` (transfer syntax UID list), `max_pdu`.
- `fail_store_uid`, `store_delay` for per-object failure and response delay.
- `datasets`, `pending_count`, `pending_delay`, `ignore_cancel` for FIND/MWL.
- `instances` (in-memory attribute dictionaries, optional `pixel_data_hex`) or
  `files` (Part 10 paths) for GET/MOVE; `move_host`/`move_port` select the receiver.
- MPPS N-CREATE/N-SET return success; Storage Commitment N-ACTION can schedule a
  callback using `commitment_port`, `commitment_aet`, `commitment_delay`, and
  `fail_commitment_uid` (failure reason 0112).
- `identity_primary`, `identity_secondary`, `identity_response` configure identity
  checks. `extended_flags` controls supported Q/R flag bytes. Async negotiation
  always remains pynetdicom's native `(1,1)` response.
- `wrong_response_id` deliberately corrupts response correlation through the
  DIMSE-sent event for a negative test; it does not alter peer dispatch.
- `tls_certificate`/`tls_key` enable Python SSL. `generate_tls` generates a
  self-signed certificate with OpenSSL for the untrusted-peer test.
- `generate_rle` is consumed by the Swift launcher to request a synthetic Part 10
  RLE fixture through `fixture_path`.

`role: "scu"` accepts `operation: "echo" | "store" | "find" | "get" | "move" |
"action"`, plus `host`, `port`, `called_aet`, `identifier`, `files` and
`destination_aet`. It emits establishment, statuses and received-store evidence.

Run the filtered Swift command and consult
[`../../DISTRIBUTION.md`](../../DISTRIBUTION.md) for
what the tests prove and the independent-concurrency limitation. These tests do
not require the Docker smoke-test opt-in flag.

### A2: pynetdicom as SCU

The JSON `role: "scu"` accepts `echo`, `find` (Study Root), `patient_find`,
`mwl`, `get`, `move`, `mpps`, `action`, `store`, and `concurrent` operations.
`cancel_after` sends C-CANCEL after that many responses. GET proposes the
Storage SCP role; `fail_store_uid` injects one C-STORE failure. MOVE uses
`destination_aet`. MPPS creates IN PROGRESS, sets COMPLETED, then attempts
DISCONTINUED to test final-state refusal.

For commitment, `callback_listener: true` starts a listener and publishes its
port in `ready_path`. An optional `start_path` barrier lets the test install the
AE destination before sending N-ACTION. `same_association_role: true` explicitly
proposes the requestor's SCU role, which receives N-EVENT-REPORT per PS3.4 J.3.3.
`max_pdu`, `user_identity`, `extended_flags`, and `async_window` configure the RQ.

`concurrent` sends three FINDs and an ECHO using pynetdicom's native DIMSE
primitives, normal reactor handoff and one response consumer. It uses the
installed 3.0.4 internal reactor API rather than concurrently calling the
synchronous convenience methods; no peer code is patched. Results include
negotiated window, correlated response IDs/statuses, retrieve counters and
notification details. The server tests require `DICOM_SWIFT_PYNETDICOM_PYTHON`
and fail rather than skip if it is missing.

### UPS and IAN (Lot A1)

The unmodified pynetdicom 3.0.4 peer supports the five UPS abstract syntaxes and
IAN. Its SCP stores UPS objects in an independent Python dictionary under a lock;
N-CREATE, N-SET, N-GET, Change State and C-FIND do not call the Swift engine.
Received IAN datasets are recorded in `ian`. UPS event reports are recorded in
`events` as `{type, state}` and acknowledged only by the event handler response.

SCU operations are `ups_create`, `ups_find`, `ups_get`, `ups_set`, `ups_action` and
`ian_create`. Each accepts `uid` and `attributes` (pydicom keyword objects).
`ups_action` accepts `action` (default 1); `ups_get` accepts `attribute_ids`.
`context` selects the negotiated syntax for normalized Pull/Watch operations;
the command SOP Class remains Push. `sequence` executes its `steps` array on one
association. `callback_listener: true` starts a UPS Event listener and publishes
its port in the readiness record; `start_path` lets the harness configure the
Swift destination resolver before operations begin. Results contain `statuses`
and `ups_results` (DICOM JSON datasets, or null), in response order.

The four new UPS/IAN test files run through the issue's `verify_a1.sh`. They require
`DICOM_SWIFT_PYNETDICOM_PYTHON` pointing at Python with pynetdicom 3.0.4; setting
`DICOM_REQUIRE_PYNETDICOM=1` turns absence of that interpreter into a test failure.
The Python SCP is an independent test oracle for the exercised operations, not a
production implementation or a claim of full UPS conformance.

### UPS-RS and WebSocket notification witness (Lot A2)

`ups_rs_probe.py <service-base-url>` uses independent `requests` and `websockets==17.1`
clients against a running `DicomWebHTTPListener`. It covers every chapter 11 transaction,
JSON statuses and Location/Content-Location/Warning headers, the WebSocket upgrade,
SCHEDULED → IN PROGRESS → progress → COMPLETED event objects, ping/pong, close 1009,
and a disconnected update followed by re-subscription and a fresh initial state report.
All workitems are synthetic. The probe prints one JSON result and exits nonzero on failure.

`DicomWebUPSRSIndependentTests` starts the listener with the in-memory A1 UPS engine,
launches the probe, asserts its result and verifies that the A1 observer recorded
`noConnection`. The interpreter is selected by `DICOM_SWIFT_PYNETDICOM_PYTHON`, defaulting
to `/tmp/isis-2321-iod-oracle/bin/python`. An absent interpreter skips only when
`DICOM_REQUIRE_PYNETDICOM` is not `1`; missing Python modules or a failing probe never skip.

## Print Management SCU qualification (issue #2353, Lot A1)

The SCP role accepts a `"print": {...}` object to select an independent in-memory
Print SCP. It uses unmodified pynetdicom 3.0.4 dispatch and pydicom datasets. It
creates Film Sessions, Film Boxes with their Image/Annotation Boxes, Presentation
LUTs and Print Jobs. No toolkit SCP or compositor is used.

```json
{
  "role": "scp",
  "print": {
    "replace_uids": true,
    "annotation_formats": {"LABEL": 2},
    "jobs": true,
    "configuration": [{
      "SOPClassesSupported": ["1.2.840.10008.5.1.1.9"],
      "MaximumCollatedFilms": 4,
      "DefaultPrinterResolutionID": "STANDARD",
      "DecimateCropResult": "DEF FAIL",
      "SupportedImageDisplayFormatsSequence": [{
        "ImageDisplayFormat": "STANDARD\\1,1",
        "FilmOrientation": "PORTRAIT",
        "FilmSizeID": "8INX10IN",
        "PrinterResolutionID": "STANDARD",
        "RequestedImageSizeFlag": "YES"
      }]
    }]
  }
}
```

Print configuration keys:

| Key | Behavior |
| --- | --- |
| `replace_uids` | Defaults to true; return independent Session/Box/LUT UIDs. |
| `annotation_formats` | Maps Annotation Display Format ID to box count. |
| `custom_layouts` | Maps SLIDE/SUPERSLIDE/CUSTOM wire values to box count. STANDARD/ROW/COL are parsed. |
| `max_image_boxes` | Maximum Image Boxes per Film Box response, default 64. Larger counts return N-CREATE 0106 before any Film/Image Box objects are created. |
| `jobs` | Negotiate Print Job; action returns a reference and emits Pending, Printing, Done on the same association. |
| `job_failure`, `job_failure_info` | Emit Failure instead of Done; default info is FILM JAM. |
| `job_stall` | Remain Pending to test bounded monitoring. |
| `printer_status`, `printer_status_info` | Printer N-GET state and detail, default NORMAL. |
| `printer_event` | Event type 2 (Warning) or 3 (Failure), before the first Printer N-GET response. |
| `configuration` | Printer Configuration Sequence items, using pydicom keywords. |
| `refuse_color_contexts`, `refuse_annotation_context` | Reject the respective presentation contexts. |
| `refuse_lut` | Refuse Presentation LUT N-CREATE. |
| `insufficient_boxes`, `insufficient_annotations` | Subtract from the generated Image/Annotation Box counts. |
| `fail_create`, `fail_set`, `fail_action`, `fail_get`, `fail_delete` | Integer status or map of SOP Class UID to status. |
| `unknown_attribute_warning` | Inject N-SET 0x0107 (attribute list warning). Annotation identification must then be refused. |
| `box_size` | Maximum `[rows, columns]`; oversize images return C603 for FAIL, otherwise B604. |
| `memory_limit` | Pixel Data byte limit for N-SET; excess returns C605. |

The result JSON includes `films` (UID, parent session, layout, attributes, image
positions/SHA-256/dimensions/photometric interpretation, source image references,
annotations, acceptance and deletion), `print_sessions`, collated `print_order`,
`print_operations` with statuses, and acknowledged `job_events`. Failed image
N-SET attempts also retain the hash of the submitted bytes. The tests write these
JSONs to `/tmp/isis-2353-print-evidence/`; no patient data is used. Burn-in fixtures
are preformatted synthetic text rasters created only in the test target.

Implementation choices use the supplied PS3.4 2026c Annex H and PS3.3 C.13 extracts:

- Printer N-GET uses the accepted Printer context, or its containing Meta context.
- Optional LUT references are emitted only after negotiated LUT creation; returned
  UIDs are used throughout. A missing response UID retains a supplied request UID;
  missing referenced Image/Annotation/Print Job identities are never generated.
- N-ACTION acceptance means `accepted`, not proof of physical printing. Monitoring
  ends at Done or typed Failure, before release. One N-GET establishes current job
  state, then the SCU receives and acknowledges the mandatory status events; it
  avoids overlapping repeated N-GET requests with the peer's notifications.
- `(2100,0500)` is encoded numerically for the action's Referenced Print Job
  Sequence. pydicom's `ReferencedPrintJobSequence` keyword names a different tag;
  this harness does not substitute that dictionary keyword for the supplied table.
- Cleanup defaults to true. Film Boxes are deleted in reverse creation order,
  then the session, then LUT, as requested by the lot; deletion failures remain warnings.
  H.4.2.2.3 only specifies deletion of the last-created box, so explicit deletion
  of older boxes versus session-level cascade remains a conformance question. Cancellation
  stops subsequent N-SET/N-ACTION and cleans the working hierarchy. Accepted print
  jobs may still print after cancellation/release (H.5).
- Requested Image Size is matched to configuration layout/orientation/size/
  resolution. Unknown capability needs caller force; an explicit NO is never
  overridden. Decimate/Crop is sent only for a `DEF ...` configuration result.
- LUT tables validate 256/4096 entries, first mapped value zero and 10–16 output
  bits. The current RGB8 raster ingress requires a 256-entry table when sending.
- Declared-input job/batch initializers validate all raster budgets before invoking
  any renderer. Existing bitmap initializers validate caller-owned dimensions
  before creating wire pixel buffers. Limits count uncompressed RGB bytes, not
  whole-process peak memory.

Known compatibility conflicts intentionally left for the issue owner: pre-existing
Meta-only command-sequence assertions omit Printer N-GET, and a pre-existing
layout test permits a printer-defined family without `expectedImageBoxCount`.
The old color raster contract uses interleaved Planar Configuration 0, whereas the
supplied C.13 print table enumerates 1; that existing expectation was not authorized
for modification. `DicomImageDisplayFormat` accepts opaque CUSTOM identifiers;
the supplied C.13 table describes an integer, and that parser is outside this lot.

## A2: independent Print SCU and reusable printer emulator

The same peer script accepts `role: "print_scu"` to drive the Swift SCP. Its
`print` object accepts `color`, `layout`, `copies`, `images` (rows, columns,
hexadecimal pixels), `annotations`, `annotation_format`, `lut` (true for IDENTITY,
or a dataset-shaped object), `unknown_attribute`, `delete_referenced_lut` and
`abort_after_action`. RGB test pixels use planar configuration 1. Results include
per-operation statuses, returned instance UIDs, Attribute Identifier List,
per-image SHA-256 and Pending/Printing/Done/Failure events. The harness fails on
missing image boxes before issuing image N-SETs; it never invents missing UIDs.
Event handlers return the pynetdicom `(status, reply_dataset)` tuple.

For example, with a running Swift SCP at port 11112:

```sh
python Scripts/interop/pynetdicom_peer.py '{"role":"print_scu","port":11112,"called_aet":"PRINT","print":{"layout":"ROW\\1,2","lut":true,"annotations":["SYNTHETIC"]},"result_path":"/tmp/print-result.json"}'
```

The new CLI commands share the compositor and A1 SCU:

```sh
swift run dicomtool print scp --port 11112 --aet PRINT --gray --color --lut --print-job --annotation-format LABEL=1 --output-dir /tmp/print-output --duration 60
swift run dicomtool print scu --host 127.0.0.1 --port 11112 --called-aet PRINT --mode gray --layout 'ROW\1,2' --annotation-format-id LABEL --annotation 1=SYNTHETIC --lut identity --monitor --preview-dir /tmp/preview synthetic.dcm
swift run dicomtool print compose --layout 'STANDARD\1,1' --output /tmp/sheet.png synthetic.dcm
swift run dicomtool print status --host 127.0.0.1 --port 11112 --called-aet PRINT
```

SCP fault flags (`--fail-create`, `--fail-set`, `--fail-action`) accept hexadecimal
statuses. A CREATE warning still creates and returns an instance. `--pdf FILE`
selects a multi-page PDF, published after its last page; PNG filenames use job UID
and film index. Existing PDF destinations are not overwritten. SCP stdout emits
one JSON record per successfully received output film, with its fingerprint and
raw received pixel hashes, without patient text.

`--config FILE.json` accepts `outputWidth`, `maximumQueuedJobs`,
`maximumFilmsPerSession`, `imageBoxesPerFilm`, `bytesPerFilm`, `bytesPerSession`,
`annotationFormats` (ID to row count), `supportsCollation`, `keepJobsOnRelease`,
`printerName` and `identify`. Configuration and LUT JSON are limited to one MiB.
`--max-bytes` rejects files larger than its budget before decoding and validates
all declared RGB dimensions before rendering or associating. This conservative
file-size check includes metadata as well as pixels. LUT JSON has `descriptor`
and `values` arrays. Pre-association preview needs explicit gray/color; automatic
mode without preview uses the A1 negotiation. To obtain matching previews and
SCP output, use the same width, annotation geometry and identification setting.
With `--identify`, configure SCP `identify: true`; CLI image inputs must carry
Study Instance UID and usable identification. Mixed studies and same names with
different Study UIDs are identified separately on the sheet.

A2 XCTest coverage lives in `DicomFilmCompositorTests`,
`DicomDIMSEServerPrintTests`, `DicomPrintSCPPynetdicomTests`,
`DicomPrintLoopbackTests` and `PrintCommandTests`. The supplied `verify_a2.sh`
runs those together with A1 and pre-existing print/network command tests. The
pynetdicom tests require `DICOM_SWIFT_PYNETDICOM_PYTHON`; they do not silently skip.
The conformance statement lists the status-to-test mapping and explicitly marks
C613 and LUT-CREATE B605 as response-injection coverage, not semantic proof.

## Independent OpenJPIP server (issue #2354, Lot H)

`openjpip_server.py` prepares an indexed JPEG 2000 target and launches the
unmodified OpenJPEG `opj_server`, with no Swift dependencies. The HTTP and
FastCGI listeners bind to `127.0.0.1` on OS-assigned ports. Python 3, NumPy and
an OpenJPEG toolchain are required; DICOM conversion additionally uses pydicom and its
available pixel decoders. The self-test uses requests, Pillow,
`jpip_to_j2k` and `j2k_to_image` (1.5.2), or `opj_jpip_transcode` and
`opj_decompress` (2.5.x). Nothing is installed automatically.

Build OpenJPIP separately (the ordinary Homebrew OpenJPEG installation does not
include the JPIP server). For an unpacked OpenJPEG 2.5.4 release source directory:

```sh
brew install fcgi cmake openjpeg
cmake -S openjpeg-2.5.4 -B openjpip-build \
  -DBUILD_JPIP=ON -DBUILD_JPIP_SERVER=ON -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_PREFIX_PATH="$(brew --prefix fcgi)"
cmake --build openjpip-build --parallel
export DICOM_JPIP_OPENJPIP_BIN="$PWD/openjpip-build/bin"
```

The presence of `image_to_j2k` in the configured bin directory selects
`toolchain: "openjpeg-1.5.2"`, requiring executable `image_to_j2k`, `j2k_to_image`,
`jpip_to_j2k`, and `opj_server` there. Otherwise the harness selects
`openjpeg-2.5.x` and requires `opj_compress`, `opj_decompress`,
`opj_jpip_transcode`, and `opj_server` in that directory. The 1.5.2 build also
provides `jpip_to_jp2`; the self-test uses the codestream oracle `jpip_to_j2k`.
Readiness and result JSON include toolchain, encoder command, index box summary,
and versions. The encoder version is read from its codestream COM marker;
other tool versions are explicitly `unreported`, rather than inferred from filenames. An **unset** `DICOM_JPIP_OPENJPIP_BIN` produces
`{"skipped":true,"reason":"DICOM_JPIP_OPENJPIP_BIN is unset"}` and exit **77**;
callers should translate only this condition into a skipped optional test.
An explicitly configured but missing/broken executable, missing Python module,
or unsuccessful self-test is a failure (exit 1), never a skip.

From the repository root:

```sh
/tmp/isis-2321-iod-oracle/bin/python \
  DICOM-Swift/Scripts/interop/openjpip_server.py --self-test

# Reusable fixture process; send SIGTERM after the consuming test finishes.
/tmp/isis-2321-iod-oracle/bin/python \
  DICOM-Swift/Scripts/interop/openjpip_server.py \
  --input /tmp/synthetic.pgm --rates 8,4,1 --resolutions 3 \
  --precincts '[64,64]' --tile-size 128,128 \
  --ready-path /tmp/jpip-ready.json --result-path /tmp/jpip-result.json
```

Without `--input`, the fixture is a synthetic 256×256 gradient. PGM/PPM inputs
use `--format portable` (the default). Unsigned raw grayscale requires
`--format raw --width W --height H --bits 8|16`; `--byte-order little|big`
selects the byte order for 16-bit input. DICOM input uses
`--format dicom --bits 8|16 [--frame 0]`: pydicom extracts a monochrome frame,
normalizes stored sample min/max into the chosen unsigned range, and inverts
MONOCHROME1. This fixture conversion is not clinical windowing; metadata is not
copied into the PGM/JP2. Use only synthetic or deidentified pixels: conversion
does not remove burned-in patient text. `--quality 30,40,50` selects `-q`
instead of `--rates`/`-r`. Encoding always sets `-jpip -p RPCL -TP R`; RPCL is
required by this index writer, and resolution tile-parts are required for JPT.
This is ordinary JPEG 2000, not HTJ2K qualification.

The child launch is exactly `[DICOM_JPIP_OPENJPIP_BIN/opj_server]`, without
arguments, with the inherited environment and `cwd` set to the fixture directory.
`subprocess.Popen(stdin=listening_socket)` duplicates the TCP FastCGI listening
socket onto fd 0 before exec. OpenJPEG 2.5.4 does **not** read
`OPJ_SERVER_PORT`. Its separate auxiliary TCP transport is hard-coded to port
60000 by `init_JPIPserver(60000, 0)`; this harness only uses HTTP transport.
The upstream auxiliary listener is outside the harness's loopback/ephemeral
port selection, so multiple simultaneous upstream processes can conflict.

A startup probe against an unknown channel verifies FastCGI before readiness;
it is excluded from HTTP request counters. Stdout and optional `--ready-path`
receive `{"ready":true,"port":N,"target":"target.jp2"}`. Query the endpoint as
`http://127.0.0.1:N/?target=target.jp2&type=jpp-stream&fsiz=64,64`.
Every GET forwards `REQUEST_METHOD`, `QUERY_STRING`, `SCRIPT_NAME`, CGI server
fields and `HTTP_*` headers through a fresh FastCGI connection to the same child,
so the child retains JPIP session state. CGI status and response headers become
HTTP headers, and FastCGI stdout body records stream as HTTP chunks. The child
itself assembles its response before writing stdout; chunking does not make its
encoder incremental. Requests are serialized, matching the upstream accept loop.

SIGTERM/SIGINT stops the child and listener, emits final JSON, and writes it to
`--result-path` (default: `result.json` in the fixture directory). It contains
`request_count`, total body `bytes`, and `requests` with sanitized `query`,
`status`, `content_type`, and `length`; incomplete responses also report an error
type. Arbitrary query strings, request headers, source filenames, DICOM tags and
native stderr are not copied into that result. Targets always have the fixed
name `target.jp2`. Temporary directories have mode 0700 and remain for inspection;
`--work-dir` chooses a new retained directory. Remove fixture artifacts after use.

The self-test fixes the gradient to 256×256, three quality layers (`-r 8,4,1`)
and three resolutions, with `-c '[64,64]'`. The 1.5.2 encoder command is:

```sh
"$DICOM_JPIP_OPENJPIP_BIN/image_to_j2k" -i input.pgm -o target.jp2 \
  -jpip -p RPCL -TP R -n 3 -c '[64,64]' -r 8,4,1
```

The working directory is the retained fixture directory. Despite the 1.5.2 help
showing an unbracketed precinct pair, its parser requires the brackets.
It requests reduced resolution, one layer, session
creation/refinement/closure, JPT, and ROI. Its JSON includes exact synthetic
request/response headers, body paths/sizes, EOR boundary checks, native tool exit
codes and decoded dimensions. Each received body is saved unchanged. Session
refinement is also transcoded from accumulated data-bin messages (with EOR
records removed between responses), since a session delta may omit cached
headers. Any failed required assertion or standalone transcode/decode leaves
`ok:false` and exits 1; limitations are not silently converted into passes.

**Observed prerequisite failure on 2026-09-11:** the supplied Homebrew
`opj_compress` accepted `-jpip` and exited 0, but its generated target had no
usable `iptr`/`cidx`/`fidx` index. Serving it crashed the supplied OpenJPIP 2.5.4
binary in `check_JP2boxidx` → `gene_childboxbyType` (SIGSEGV). The harness now
checks required top-level boxes before launch and fails clearly for that output.
The build recipe above builds the server tools; it does not guarantee a working
JPIP index writer. The supplied 2.5.4 source guards index writing with `USE_JPIP`
and its index-writing functions contain placeholders. A compatible index writer
is required; no source patch, replacement encoder or rebuild is performed here.
The 1.5.2 writer passes the box walk: `jp2c` is 2735 bytes, `cidx` is
2671 bytes with `cptr`, `manf`, `mhix`, `tpix/faix`, `thix`, `ppix/faix`, and
`phix/faix`, and `fidx` is 49 bytes with `prxy`. Sizes include box headers.
The zero-filled placeholder rejection remains active for 2.5.x output.

**Lot H3 observations (2026-09-11, supplied unmodified 1.5.2 binaries):**
The self-test remains **failing**, because session closure cannot meet its EOR
assertion. Stateless responses record `eor.present: false`; session creation
and refinement require EOR and returned reasons 2 and 1 respectively.

- Targets are resolved relative to the child's fixture `cwd`. Keep
  `target=target.jp2` for independent requests. Replacing it with the returned
  `tid` alone crashed this server with SIGSEGV.
- `cid=<CID>&cclose=*` and `cid=<CID>&cclose=<CID>` crashed the server.
  The harness uses `cclose=<CID>` alone, which returns HTTP 200 with no body,
  Content-type, or EOR. The upstream response path otherwise retains a freed
  channel after closing it. No EOR is synthesized and the closure assertions
  remain failures. A passing run needs an explicitly revised closure acceptance
  rule or an upstream fix; rebuilding/patching OpenJPEG is outside this lot.
- Small fsiz: 2334 bytes, JPP, decoded 64×64. Session creation: 2617 bytes,
  JPP, decoded 128×128. Refinement: 645 bytes; its standalone transcoder exited
  -11 because the body lacks cached headers. Accumulated creation/refinement
  data (EOR records removed) transcodes and decodes to 256×256, both exit 0.
- `layers=1`: 3094 bytes, JPP; transcode exits 0 but decode exits 1. This is
  recorded as an oracle limitation, not a successful layer decode.
- JPT: 2747 bytes, transcode/decode exit 0, decoded 256×256.
- ROI: 255 bytes, transcode/decode exit 0, decoded canvas 256×256 (not a
  cropped 64×64 image). Dimensions alone do not qualify ROI pixel correctness.
- No response emitted `JPIP-fsiz` or `JPIP-layers`. `JPIP-rsiz`/`JPIP-roff`
  were returned for small, layer1, session creation/refinement, and JPT; neither
  was returned for ROI. Header absence does not by itself prove a field ignored.
- The server also exited with SIGSEGV during SIGTERM cleanup in the observed
  run; its final return code is preserved. All seven HTTP requests completed
  before cleanup. No OpenJPEG sources were modified or rebuilt.

### Lot A1 client qualification

From the repository root, run the client qualification with the configured external tools:

```sh
swift test --package-path DICOM-Swift --filter 'DicomJPIP'
```

The verified run executed 46 JPIP tests: zero failures, one skip. The skip belongs
only to the pre-existing complete-entity `DicomJPIPReferenceInteropTests`, which
requires `DICOM_JPIP_REFERENCE_URL`. The new OpenJPIP test executed, not skipped.
An unset `DICOM_JPIP_OPENJPIP_BIN` skips that test unless
`DICOM_REQUIRE_OPENJPIP=1`; a configured toolchain failure fails the test.

`DicomJPIPOpenJPIPInteropTests` creates a synthetic 512×512 unsigned 16-bit
PGM and encodes RPCL with four resolutions, 64×64 requested precincts and five
layers (`32,16,8,4,1`). Evidence stays in the printed `jpip-a1-*` directory.
For each channel update, `*-cumulative-http.bin` contains the exact concatenation
of HTTP bodies received so far. The `.wire` input to `jpip_to_j2k` retains those
original databin bytes cumulatively, removing only each terminal EOR envelope:
OpenJPIP 1.5.2's utility does not parse EOR and otherwise mistakes it for databin
content. No isolated refinement body is used as an oracle.

The test uses `j2k_to_image -l` on the original for each requested layer count and
`-r 1` for half resolution. The supplied 1.5.2 decoder supports both options.
When present at the sibling `openjpip/build/bin/opj_decompress` path, OpenJPEG
2.5.4 supplies an additional native decode of the same oracle codestream.

Observed independent evidence and explicit oracle limitations:

- JPP cumulative updates 1/3/5 decode identically through our reconstruction and
  the independently transcoded oracle; the final equals the original JP2.
  Update 2 remains undecodable in both reconstructions. All codestream bytes
  agree after normalizing only the reference's stale SOT tile-part count
  (`TNsot=4` versus the single reconstructed tile-part). This is byte-level
  evidence for that update, **not** a successful layer-2 pixel golden.
- The original's `-l` decodes disagree with the server/transcoder's partial
  updates: OpenJPIP sends all lower-resolution layers, and truncated class-0
  precincts lack packet-boundary metadata/padding. These comparisons use
  explicit `XCTExpectFailure` with version and reason. A native 1.5.2 versus
  2.5.4 decoder discrepancy is also isolated as an expected failure between
  those two tools; client pixels must still equal the 2.5.4 oracle pixels.
- JPT updates 1/2/3/5 match the cumulative oracle and full decode. The server
  sends all tile data on the first update, so requests for fewer layers differ
  from original `-l` decodes and do not prove progressive JPT delivery.
- Half-size JPP reconstruction matches the 256×256 transcode and original
  `j2k_to_image -r 1` decode.
- ROI comparisons cover only requested interior pixels. Client and transcode
  crops agree, but the original crop differs. The log includes both SHA-256
  checksums and response headers (stateless ROI omits served `JPIP-roff/rsiz`).
  For `roff=64,64&rsiz=128,128`, 11 overlapping precinct IDs are absent from
  the server response: `9,10,17,18,73,74,81,82,137,138,145`. The reference
  `enqueue_precincts` compares unscaled window coordinates at lower resolutions.
  Our reconstruction retains every received edge-precinct packet; the
  oracle/original crop disagreement is an explicit expected failure.
- The second session response is cancelled from the real URLSession data
  callback after 4096 bytes. The same window is reissued on the same channel.
  OpenJPIP has already advanced its model and returns only EOR, so the client
  performs a stateless repair and retains the channel. Final pixels equal the
  original and finality is true. `supportsCacheModel: false` is explicit for
  this peer: sending `model=` to 1.5.2 aborts the server. Capable peers receive
  the actual cache model on reconnect and stateless repair.
- Two overlapping windows return 166260 bytes and then only 3 EOR bytes.
- Sessions emit EOR 2 (window done) and 1 (image done); stateless responses omit
  EOR. Session headers include `JPIP-cnew`, `JPIP-tid`, `JPIP-roff`, and
  `JPIP-rsiz`; no `JPIP-fsiz` or `JPIP-layers` was observed. Close with
  `cclose=<cid>` alone: empty HTTP 200 without EOR. Do not send `tid` alone or
  `cid` together with `cclose`. The teardown SIGSEGV on SIGTERM remains a
  known server teardown behavior.

Measured databin accounting (excludes JPIP wire headers):

| Scenario | Useful bytes | Redundant bytes | Peak cache bytes |
| --- | ---: | ---: | ---: |
| JPP cumulative final | 318950 | 0 | 318950 |
| JPT cumulative final | 318994 | 0 | 318994 |
| Interruption and repair | 318950 | 124195 | 318950 |
| Overlapping windows | 161616 | 0 | 161616 |

`DicomJPIPPerformanceReport` records first-preview/final `Date` values and peak
cache bytes; the independent test prints these fields, including the actual
session report for interruption/reconnect. Repair redundancy is bounded by one
replay of the cached prefix because this peer cannot negotiate cache models.

Hermetic coverage includes parser mutation/chunk-boundary cases; active-window
LRU protection including partially overlapping border precincts and headers;
`model`/`need` descriptor import (without inventing received data); stateless
`model=` emission and mutually exclusive `need`; five progression orders with
PLT packet limits; and a locally encoded HTJ2K JPT passthrough that preserves CAP
and all codestream bytes and decodes to the original pixels. Cache-model rules
follow [T.808 C.8](https://www.itu.int/rec/T-REC-T.808-202212-I/en).

The ten synthetic files in `Tests/Fixtures/JPIP/` total 100685 bytes. For each
order LRCP/RLCP/RPCL/PCRL/CPRL, the input is a 64×64 RGB8 image whose component
value is `(x*7+y*11+c*37+(x*y%19))%256`, encoded using the sibling 2.5.4 tools:

```sh
opj_compress -i input.ppm -o ORDER.j2k -PLT -p ORDER -n 2 \
  -c '[16,16],[16,16]' -r 16,4,1
opj_decompress -i ORDER.j2k -o ORDER-layer1.ppm -l 1
```

`ORDER-layer1.rgb` contains the PPM's 12288 raw pixel bytes. Tests index packets
from PLT without invoking an external encoder/decoder, compare partially
received bins against these first-layer goldens, and compare final pixels with
the fixture decode. HTJ2K is generated hermetically using the existing encoder.

Tile COD/COC/POC overrides remain rejected with `unsupportedPacketOrdering`.
LRCP/RLCP multilayer reconstruction requires PLT or sufficient extended packet
boundaries. Other partial class-0 precincts preserve their contiguous bytes for
decoder truncation; this does not guarantee every partial stream decodes.
`stream`, cache-model peer negotiation and HTJ2K remain **pending independent
evidence** because OpenJPIP 1.5.2 lacks those capabilities. No oracle exception
waives a disagreement between our reconstruction and the independent oracle.

### Building OpenJPEG 1.5.2 with the JPIP index writer (recipe used on 2026-09-11)

OpenJPEG 2.5.x accepts `opj_compress -jpip` but writes only placeholder `iptr`/`cidx`/`fidx`
boxes, and its `opj_server` loops on such targets. The last release with the real index
writer (`image_to_j2k -jpip`) and a working FastCGI `opj_server` is 1.5.2:

```bash
brew install fcgi
curl -sL https://github.com/uclouvain/openjpeg/archive/refs/tags/version.1.5.2.tar.gz | tar xz
mkdir build && cd build
cmake ../openjpeg-version.1.5.2 -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DBUILD_JPIP=ON -DBUILD_JPIP_SERVER=ON -DBUILD_CODEC=ON -DBUILD_THIRDPARTY=OFF \
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH='/opt/homebrew;/opt/homebrew/opt/libpng;/opt/homebrew/opt/libtiff;/opt/homebrew/opt/little-cms2' \
  -DFCGI_INCLUDE_DIR=/opt/homebrew/opt/fcgi/include -DFCGI_LIBRARY=/opt/homebrew/opt/fcgi/lib/libfcgi.dylib \
  -DCMAKE_C_FLAGS='-Wno-error -Wno-implicit-function-declaration -Wno-int-conversion -Wno-implicit-int'
make -j8 -k
export DICOM_JPIP_OPENJPIP_BIN="$PWD/bin"   # image_to_j2k, j2k_to_image, opj_server, jpip_to_j2k, jpip_to_jp2
```

The bundled third-party libpng of 1.5.2 does not compile on current macOS (`fp.h`), hence
`BUILD_THIRDPARTY=OFF` with the Homebrew image libraries. The 2.5.4 tree can still be built
for `opj_jpip_transcode`/`opj_decompress` as secondary oracles.

## Offline HL7 v2 oracle (#2360)

`hl7v2_oracle.py` independently parses ER7 with **hl7apy 1.3.5** (schema tables
2.2–2.8.2) and **python-hl7 0.4.5** (structure). It accepts one JSON object on
stdin or in argv[1]:

```json
{"messages":[{"id":"synthetic","path":"/tmp/synthetic.hl7"}],"checks":["structure","validate","roundtrip"]}
```

Each message may supply `base64` instead of `path`. Optional `ready_path` and
`result_path` receive JSON files; stdout contains the final JSON object with
`ready`, exact `dependencies`, `unavailable` and per-message `messages`.
Results contain metadata, segment names, field counts (excluding segment name,
including MSH-1), validity, sanitized first error path/code and serialized SHA-256.
No message values or upstream exception text are emitted. No networking or
package installation occurs. An absent or wrong dependency version is unavailable.

Unknown structures/versions and grouping that discards segments are explicitly
`unsupported`; they never count as agreement or disagreement. Structural parsing
can still be compared where schema validation is unavailable. `validate` and
`roundtrip` control their respective expensive checks; structural metadata is
always returned. LF/CRLF inputs are normalized to CR before both oracle parses.
The first MSH-18 declaration selects decoding, with byte-transparent Latin-1
fallback. hl7apy omits final CR and trims trailing empty fields/components;
Swift's default serializer is asserted byte-exact separately.

The Swift tests invoke this script live. No raw oracle JSON is checked in.
Missing `HL7V2_ORACLE_PYTHON` skips with an explicit explanation, while
`HL7V2_REQUIRE_ORACLE=1` makes a missing/wrong-version oracle fail.

```bash
cd DICOM-Swift
HL7V2_ORACLE_PYTHON=/tmp/isis-2321-iod-oracle/bin/python HL7V2_REQUIRE_ORACLE=1 swift test --filter 'HL7OracleCrossParse|HL7ToolCommand' 2>&1 | tail -30
```

## MLLP oracle (#2361)

`mllp_oracle.py` consumes JSON on stdin and publishes `ready_path`/`result_path`
atomically. Roles are `server` (python-hl7 asyncio), `server-hl7apy` (MLLPServer)
and `client` (python-hl7). Servers bind ephemeral loopback ports; lifetime is
bounded. Configure AA/AE, ACK delay/duplication, disconnect after N messages,
7-byte fragments or concatenated frames. The client also supports `giant_bytes`
for refusal tests. Results contain synthetic control IDs and byte lengths in
temporary files, never console logs. Plain TCP only; no hosted peer or TLS oracle.

Use `HL7V2_ORACLE_PYTHON` pointing to python-hl7 0.4.5 / hl7apy 1.3.5 and set
`HL7V2_REQUIRE_ORACLE=1` to prohibit skips. `MLLPOracleInteropTests` exercises all
three roles through the production Swift client/listener. Full configuration
and the authorized local command are in [HL7 toolkit QA](../../DISTRIBUTION.md).

## Offline CDA oracle (#2362)

`cda_oracle.py` independently examines CDA R2 documents with **lxml 6.1.3**
(libxml2; entity resolution, DTD loading and network access disabled). It accepts
one JSON object on stdin or in argv[1]:

```json
{"documents":[{"id":"synthetic","path":"/tmp/synthetic.xml"}],"checks":["xsd","c14n"],"xsd_dir":null}
```

Each document may supply `base64` instead of `path`. `xsd` validates against the
macOS-installed `CDA_SDTC.xsd` set (`xsd_dir`, `CDA_XSD_DIR`, or the HealthKit
default directory; the schema is never copied into this repository) and returns
`xsdValid` plus an error count. `c14n` returns the exclusive C14N 2.0 SHA-256 so
Swift round trips can be compared for equality. Every document also gets a
structural inventory: root name, template OIDs, section codes, entry count,
narrative `ID` count, `reference` count and dangling references. Inputs with
`<!DOCTYPE`/`<!ENTITY` are `refused: dtd`; unparsable inputs are `refused: malformed`.
No narrative text, names or error messages are emitted. `CDAOracleInteropTests`
invokes it live; no oracle output is committed.

```bash
cd DICOM-Swift
CDA_REQUIRE_XSD=1 HL7V2_ORACLE_PYTHON=/tmp/isis-2321-iod-oracle/bin/python HL7V2_REQUIRE_ORACLE=1 swift test --filter 'CDAOracleInterop' 2>&1 | tail -30
```

## FHIR oracle (#2363)

`fhir_oracle.py` (fhir.resources 8.3.0 R4B models, fhirpathpy 2.2.4) accepts one JSON
object on stdin or in argv[1]. Role `examine` (default) validates each document
(`path` or `base64`, `format` json|xml), returning validity with path:code issues,
resource type, canonical JSON SHA-256 and re-serialization equality; `<!DOCTYPE`/`<!ENTITY`
XML is `refused: dtd`. Role `fhirpath` evaluates `expressions` on each document with
the R4 model. Role `server` starts a loopback FHIR REST server on an ephemeral port
(`ready_path` receives `{"base": ...}`, `lifetime` bounded to 600 s) supporting
create/read/vread/history/update/delete, conditional create, search subset with
paging, `_include`/`_revinclude`, chaining, `_has`, `_sort`, `_total`, batch/transaction
and Subscription rest-hook delivery; every stored resource is validated by
fhir.resources. Output carries no patient values beyond what the caller supplied.

```bash
cd DICOM-Swift
HL7V2_ORACLE_PYTHON=/tmp/isis-2321-iod-oracle/bin/python HL7V2_REQUIRE_ORACLE=1 swift test --filter 'FHIROracleInterop|FHIRClientOracle|FHIRPathOracle' 2>&1 | tail -30
```

### SMART issuer role (#2364)

With `behaviors.smart` set, the `server` role also acts as a loopback SMART App Launch
issuer: `/.well-known/smart-configuration`, `/auth/authorize` (302 with `code`, `state`
and `iss`), `/auth/token` (authorization_code with PKCE S256 verification, refresh_token
with rotation, optional `confidential_secret` Basic auth, `token_ttl`, `granted_scope`,
`token_delay`, `deny`, `issuer_override`, `insecure_endpoints`), `/auth/revoke` and
`/auth/_log`. `require_bearer` makes every FHIR path demand a valid, unexpired bearer
token whose scopes cover the resource type (401/403 with `WWW-Authenticate`). Tokens
are random opaque strings; `id_token` is an HS256 JWT with a test secret.
