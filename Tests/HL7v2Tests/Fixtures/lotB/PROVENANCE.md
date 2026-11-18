# Lot B validation fixtures

The six files in `valid/` are corrected derivatives of the synthetic MIT corpus
in `../hl7kit/valid/`. The original files, upstream provenance, and MIT license
remain unchanged. This folder contains no clinical data.

Corrections for schema validation (2.5.1):

- Fill MSH-9.3 from the event/structure mapping; the ACK also supplies A01 in MSH-9.2.
- Move misplaced provider/visit composites from PV1-6/16/18 to the applicable
  provider and visit fields. Clear misplaced text in PV1-39/41 and PV2-7/28.
- Add the required PV1 with patient class N to A08.
- Clear the overlength legacy DG1-2 coding-method label; DG1-3 retains the coded diagnosis.
- Encode the provider in OBR-32.1 as CNN subcomponents within NDL.

These copies validate without errors. Warnings are limited to fields marked B
(backward compatibility) by the tables: EVN-1, PID-19, PV1-9, AL1-6, DG1-2,
ORC-7, OBR-14 and MSA-3 where still populated.

`HL7ValidatorTests` separately locks down the error paths of all original
`hl7kit/valid` files. They are parser fixtures, not evidence of schema validity.
The original `invalid/missing_required_evn.hl7` actually contains EVN, PID-5 and
PV1; its schema error is missing MSH-9.3. `bad_segment_id.hl7` fails parsing at
MSH before a message can be passed to the validator. Neither original is altered.
