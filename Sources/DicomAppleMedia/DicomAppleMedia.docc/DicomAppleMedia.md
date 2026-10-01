# ``DicomAppleMedia``

Author and remux encoded DICOM video for Apple media frameworks without
decoding or re-encoding the compressed frames.

## Overview

`DicomAppleMedia` is the optional Apple-platform media layer of DICOM-Swift.
It consumes `DicomVideo` values from `DicomCore` while keeping AVFoundation and
CoreMedia out of `DicomCore`. Link this product only in applications that need
native playback-container preparation or H.264 elementary-stream authoring.

``DicomH264ElementaryStreamBuilder`` converts the length-prefixed NAL units
produced by Apple encoders into an Annex-B elementary stream. It obtains SPS,
PPS, and the AVCC length-field size from a CoreMedia format description, then
validates each complete sample before changing its output.

``DicomVideoRemuxer`` preserves an existing ISO base media stream byte-for-byte,
wraps MPEG-2 elementary streams in an MPEG-2 transport stream, and converts
H.264 or H.265 Annex-B access units into an ISO base media container. Its
parsers validate the elementary-stream structure and required codec parameter
sets before writing. The operation never decodes pixels and never changes the
video codec.

H.264 B-slices are supported in a qualified subset: progressive Main or High
profile, 8-bit 4:2:0, picture-order-count type 0, one slice per picture, and
closed GOPs starting with an IDR. B pictures must be non-reference pictures;
I/P pictures must be reference pictures, and I pictures must be IDRs. The
sequence and picture parameter sets must remain byte-identical. Weighted
prediction, field pictures, slice groups, redundant pictures, SPS scaling
matrices, long-term references, adaptive reference marking, and extension NAL
units are outside this subset. Each GOP must have contiguous even picture
order counts beginning at zero. POC wrap uses the previous reference picture;
each IDR resets that state.

Samples retain decode order and their encoded bytes. Presentation timestamps
use picture order, while monotonic decode timestamps include the required
preroll. Playback begins at presentation time zero and uses the caller's fixed
`frameRate`; VUI/SEI timing and variable frame durations are not used to derive
a separate timeline. Only IDR pictures are marked as independent seek points.
MPEG-2 B-pictures, H.265 B-slices, and H.264 reordering outside the qualified
subset still throw ``DicomVideoRemuxError/frameReorderingUnsupported(codec:)``
before writing. Existing ISO base media containers retain their own timing and
are still copied byte-for-byte.

The caller owns destination-file lifecycle, cache policy, playback UI, and the
choice of output filename extension. Failures that describe unsupported codecs,
malformed elementary streams, missing parameter sets, absent video frames,
unsupported frame reordering, CoreMedia construction, or AVFoundation writing are exposed as
``DicomVideoRemuxError``.

```swift
import DicomAppleMedia
import DicomCore

func preparePlayback(dicomURL: URL, cacheDirectory: URL) async throws -> URL? {
    let decoder = try await DCMDecoder(contentsOf: dicomURL)
    guard let video = decoder.video else { return nil }

    let outputExtension = video.codec == .mpeg2 ? "ts" : "mp4"
    let outputURL = cacheDirectory
        .appendingPathComponent("playback")
        .appendingPathExtension(outputExtension)

    try await DicomVideoRemuxer.writePlayableContainer(
        for: video,
        frameRate: video.frameRate ?? 30,
        to: outputURL
    )
    return outputURL
}
```

## Topics

### Remuxing

- ``DicomVideoRemuxer``
- ``DicomVideoRemuxError``

### Authoring

- ``DicomH264ElementaryStreamBuilder``
- ``DicomH264ElementaryStreamError``
