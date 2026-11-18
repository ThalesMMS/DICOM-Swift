# Enhanced dimension behavior fixtures

Synthetic data only. These files exercise dimension grouping, spatial assembly and
the application viewer; they are not a complete Enhanced MR IOD conformance corpus.

Generated with pydicom 3.0.2:

```sh
python Tools/Scripts/Fixtures/build_enhanced_dimensions_fixture.py \
  DICOM-Swift/Tests/DicomCoreTests/Fixtures/EnhancedDimensions
```

`single/enhanced_dimensions.dcm` contains 24 shuffled 32×32 native unsigned frames:
two stacks, three positions at 2.5 mm spacing, two temporal positions and two echoes.
Rescale, window and stored samples vary across partitions. `manifest.json` is read
back through pydicom and records original frame indices and numerical expectations.
`DicomEnhancedIndependentFixtureTests` compares all eight selected volumes against it.

`concatenation/` splits the same shuffled frames into two members. Their filenames
deliberately reverse concatenation order; object identity and offsets determine
provenance, while patient-space positions determine volume slice order.

`ambiguous/duplicate_position.dcm` repeats one physical position within stack 1,
time 1, echo 1 while preserving distinct logical spatial ordinals. That partition
cannot form a volume; its original frames and the seven other partitions remain
available. Use this directory separately because it deliberately shares the valid
fixture's synthetic object identifiers.

The fixture generator uses fixed synthetic UIDs and deterministic frame shuffling.
The pydicom implementation version recorded in file meta may differ after a library
upgrade, so keep the generator version pinned when comparing encoded artifacts.
