# Configuring progressive JPEG 2000 encoding

Use ``DicomJPEG2000EncodingOptions`` with the async ``DicomTranscoder`` or
``DicomCodecWorkflowEngine`` API. The options contain neutral Swift values;
clients do not import a codec implementation.

```swift
let options = DicomJPEG2000EncodingOptions(
    qualityLayers: 3, decompositionLevels: 3, progression: .rlcp
)
let plan = try DicomCodecWorkflowEngine().plan(
    sourceData, to: .jpeg2000Lossless, jpeg2000Options: options
)
let result = try await DicomTranscoder().execute(plan, source: sourceData)
```

Each cumulative layer adds complete wavelet resolutions. Resolution `r` first
appears in layer `r * qualityLayers / (decompositionLevels + 1)`. The final layer
retains all coefficients of the chosen reversible or irreversible encoding.
There are no bitrate targets or partial code-block pass contributions in this profile.

The single-tile profile accepts LRCP or RLCP for `.90/.91/.201/.203`. It permits
`1...D+1` layers and `0...min(10, max(0, floor(log2(shortestSide)) - 1))`
decompositions, with image sides at most 32768 samples. Existing codec precision,
signedness and colour restrictions also apply. Nil decomposition/order values
select the dimension-bounded default; explicit invalid values are never clamped.

The `.202` encoder uses one RPCL layer, TLM and sufficient decompositions for a
base-resolution width or height at most 64 samples. It refuses other orders or
multiple layers. PCRL/CPRL, explicit tiling and Part 2 options are unsupported.
``DicomJPEG2000EncodingError`` reports unsupported requests before publication.

Omitting the options preserves existing one-layer codestreams. Supplying options
forces re-encoding even for an unchanged UID. Reversible final samples remain
exact; irreversible intent retains the existing loss history and derived SOP
Instance UID behavior. Cancellation removes staged output.

The CLI passes the same configuration to planning and execution:

```sh
dicomtool codec transcode input.dcm --output output.dcm \
  --transfer-syntax 1.2.840.10008.1.2.4.90 \
  --j2k-layers 3 --j2k-decompositions 3 --j2k-progression rlcp
```

Add `--plan --format json` to inspect the resolved configuration without writing.
OpenJPEG 2.5.4 independently qualifies multi-layer Part 1 and HT output. OpenJPH
0.31.0 accepts only one layer; its qualification covers single-layer HT output,
including `.202` and reduced resolutions.
