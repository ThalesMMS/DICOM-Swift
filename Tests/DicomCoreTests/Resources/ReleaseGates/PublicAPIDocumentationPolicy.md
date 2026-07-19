# Public API Documentation Policy

Public API declarations in DICOM-Swift should carry DocC-compatible comments
before they become part of the package contract. The local gate checks Swift
source files for public declarations that do not have a preceding `///`
documentation comment.

Core workflows covered by the documentation manifest:

- Decode local DICOM file
- Browse decoded series
- Adjust window and level
- Inspect DICOM metadata

Documented limitations cover codecs, network behavior, clinical objects,
export, fixtures, and device-specific performance.
