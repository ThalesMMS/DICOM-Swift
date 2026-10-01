# Standalone source distribution

Use the public HTTPS package URL `https://github.com/ThalesMMS/DICOM-Swift.git`
with an exact released version. The manifest requires Swift tools 6.2, Swift 6
language mode and iOS, visionOS or macOS 26.0+. The public source mirror preserves
its release history; application history and local development instructions are
not exported. Package consumers do not need a sibling application checkout.

The distribution retains all manifest products, Sources, Tests, processed/copied
resources, Examples, package Scripts/Tooling, the optional MetalBenchmark source
recipe and original licenses. Agent instructions,
application documentation, caches, local configuration, build products, private
exams and application history are excluded. Exported Markdown references to
parent-repository qualification records are redirected here and declared as
adaptations. Those application records are not standalone runtime prerequisites.
No new exam, binary fixture, image or binary framework is added by export.

`DistributionContents.json` enumerates SHA-256 hashes for the exported content
(excluding itself), adaptations and excluded package paths.
`DistributionProvenance.json` is a filtered derivation of the existing toolkit
inventory, covering incorporated sources, test data, license materials and
standalone dependency pins. Attribution materials originally stored outside the
package accompany the export under ThirdPartyLicenses. Original component
source hashes describe their upstream origin; exported-file hashes describe
this distribution. A recorded attribution commit does not establish an unknown
revision from which a port was originally written. That uncertainty remains;
publication does not manufacture it. LICENSE and ThirdPartyNotices.txt apply
alongside each component's notices, including non-Apache components.

For the extracted `DicomWebClient` product, import `DicomWebClient` and
`DicomData` for client operations and DICOM datasets/JSON respectively. Select
only that product in a consumer to keep the compiled graph free of Core, pixel
codecs, DIMSE, listener, UI and ZIPFoundation. SwiftPM can still resolve package
manifest dependencies used by other products. Resolution, compilation and
runtime linkage are different facts. A dependency's Package.resolved is not
inherited by an application root; commit the consumer's own lockfile.

Basic package checks use the existing `Scripts/validate_target_boundaries.py`,
SwiftPM builds and focused XCTest. Client-specific examples and test selectors
ship with the client extraction. Validation records must identify the actual
revision, toolchain, commands, successful cases, failures and skips. Publication
checks compile the client consumer in Debug/Release from an independent tree,
then resolve the published tag remotely. These source-export checks do not
claim execution of every feature or the whole optional runtime matrix.

Core codecs, Apple media, Metal, interop peers and conformance oracles have
platform/runtime requirements independent of the client product. Use
`swift run dicomtool preflight` for installed backend diagnostics and typed
unsupported/unavailable outcomes. Synthetic bundled tests run locally;
external corpus/oracle/service tests need their explicit environments and can
skip when absent. See [Releasing](RELEASING.md), the package recipe scripts,
[interop setup](Scripts/interop/README.md) and ThirdPartyNotices.txt. No claim of
universal codec availability follows from exporting a source or registry entry.
