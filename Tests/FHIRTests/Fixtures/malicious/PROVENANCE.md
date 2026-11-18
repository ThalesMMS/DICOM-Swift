# Malicious FHIR inputs

Synthetic hostile inputs: `entity-expansion.xml` (internal entity bomb), `external-entity.xml`
(external entity reference) and `deep-nesting.json` (129 nested arrays). They must be refused
by limits before any expansion or allocation.
