# DICOM Loading

Use ``DicomSeriesLoader`` when an app needs to load a DICOM series from a
directory, ZIP archive, or selected DICOM file. The decoder owns source
preparation, path-traversal validation, slice ordering, geometry validation,
rescale slope/intercept, window metadata, and DICOM-specific errors.
`DicomSeriesLoader` is a package-only loader: it supports single-frame,
uncompressed 8/16/32-bit MONOCHROME1/2 grayscale inputs and normalizes the
assembled voxel buffer to `Int16`. It explicitly rejects compressed transfer
syntaxes, color samples, and multiframe images with typed pixel-format errors.

```swift
let loader = DicomSeriesLoader()
let decoded = try loader.loadDecodedSeries(from: sourceURL) { progress in
    switch progress {
    case .started(let totalSlices):
        print("Loading \(totalSlices) slices")
    case .reading(let fraction, let slicesLoaded):
        print("Loaded \(slicesLoaded) slices: \(fraction)")
    }
}

let raw = decoded.rawVoxels
let modality = decoded.modalityVoxels
let window = decoded.recommendedWindow
```

``DicomDecodedSeries`` exposes both raw stored voxels and modality-converted
voxels. The converted buffer applies rescale slope/intercept, rounds to `Int16`,
and saturates to the representable `Int16` range. Rendering frameworks should
consume `modalityVoxels` unless they explicitly need stored pixel values.

``DicomSeriesSource`` supports:

- ``DicomSeriesSource/directory(_:)`` for a directory containing DICOM slices.
- ``DicomSeriesSource/file(_:)`` for a selected file, using its parent directory
  as the series.
- ``DicomSeriesSource/zip(_:)`` for a ZIP archive, with unsafe paths rejected
  before extraction.
