# Numbered H.264 fixtures

Generated solely from uniform grayscale bars by `generate.py`, using ffmpeg
and libx264. No patient data, downloaded media, or third-party artwork is used.
Each 128 × 64 frame encodes its zero-based number in eight 16-pixel-wide bars,
least significant bit first. All streams contain IDs 0…95 at 12 fps. The
generator independently decodes and verifies every barcode.

- `known-bframes`: Main profile, two non-reference B pictures between references.
- `known-high-bframes`: the same sequence in High profile.
- `known-pframes`: no B pictures; regression fixture for independent seek markers.
- `unsupported-b-pyramid`: reference B pictures.
- `unsupported-weighted`: weighted prediction.
- `unsupported-interlaced`: field/MBAFF coding.
- `unsupported-multislice`: two slices per picture.
- `unsupported-open-gop`: non-IDR I picture at the second GOP.

Regenerate with Python 3 and an ffmpeg build providing libx264. Encoded bytes
can vary by encoder version; the checked-in samples are the repeatable test
inputs, and decoded barcode identity is the regeneration invariant. Tests do
not invoke ffmpeg. Full qualification is documented in
`../../../DISTRIBUTION.md` in the parent Isis repository.
