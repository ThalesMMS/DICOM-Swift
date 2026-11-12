# HL7 v2 transformation fixtures (#2362)

The four `.hl7` files are unchanged copies of the corrected Lot B fixtures in
`../../../HL7v2Tests/Fixtures/lotB/valid/` (#2360), themselves derivatives of the
synthetic MIT HL7kit corpus (`LICENSE-HL7kit.txt`, Copyright (c) 2026 Raster Lab;
upstream commit 92577023c47b74d78d25865608898f73e2c04c2b). They contain no
clinical data. They are used only as inputs for v2↔CDA transformation tests;
the CDA outputs are generated in memory and never committed.
