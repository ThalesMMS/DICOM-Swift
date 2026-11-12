# CDA template fixtures (#2362)

These PHI-free, synthetic fixtures exercise the structural template layer.
`manifest.json` lists each built-in template reference, its valid XML fixture
and its intentionally invalid companion. The `specialInvalid` entries cover
forbidden nullFlavor, cardinality and unknown-template findings. Valid fixtures
also pass the local `CDA_SDTC.xsd` oracle (`xmllint`).

`cyclic-inheritance.json` is deliberately not a document: the template-model
tests load it to verify deterministic inheritance-cycle rejection.
