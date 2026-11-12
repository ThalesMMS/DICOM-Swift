# Clinical mapping fixtures

Synthetic HL7 v2 messages written for this repository (no upstream source, no clinical data):
`order.hl7` (ORM O01 with placer/filler numbers and accession issuers), `result.hl7` (ORU R01 with
OBR-19 Study Instance UID, numeric/coded/text OBX and NTE), `result-corrected.hl7` (OBR-25 C) and
`adt.hl7` (ADT A08). DICOM objects are generated in memory by `DicomStructuralFixtures`.
