#!/usr/bin/env bash
# Issue #2320: validated dataset profiles and required independent reader checks.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

ORACLE_PYTHON="${DICOM_DIFFERENTIAL_PYTHON:-python3}"
RUN_PARENT="${DICOM_DIFFERENTIAL_OUTPUT_ROOT:-.build/clinical-conformance}"
mkdir -p "$RUN_PARENT"
RUN_DIR="$(mktemp -d "$RUN_PARENT/data-fidelity.XXXXXX")"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"
export DICOM_DIFFERENTIAL_REWRITE_DIR="$RUN_DIR/rewrites"

"$ORACLE_PYTHON" - <<'PY' > "$RUN_DIR/preflight.json"
import json
import pydicom
if pydicom.__version__ != "3.0.1":
    raise SystemExit("This oracle profile requires pydicom 3.0.1; qualify other versions explicitly")
print(json.dumps({"oracle": "pydicom", "version": pydicom.__version__, "required": True}))
PY

python3 Scripts/Dictionary/generate_dictionary.py --check
swift test --filter 'DicomVRRoundTripMatrixTests|DicomDataFidelityTests|DicomContextualVRTests|DicomISO2022Tests|DicomPrivateDictionaryTests|DicomDictionaryDefinitionTests|DicomElementMultiplicityTests|DicomStrictDataSetReadTests|DicomTextValueValidationTests|DicomTextWriterValidationTests|DicomValidatedWriterTests|DicomSourceMetadataTests|DCMDecoderContextualVRTests' \
  2>&1 | tee "$RUN_DIR/test.log"
for ORACLE in data_fidelity vr_matrix contextual_vr; do
  "$ORACLE_PYTHON" "Scripts/conformance/${ORACLE}_oracle.py" \
    --directory "$DICOM_DIFFERENTIAL_REWRITE_DIR/data-fidelity" --report "$RUN_DIR/${ORACLE}.json"
done
"$ORACLE_PYTHON" Scripts/conformance/charset_fidelity_oracle.py \
  --directory "$DICOM_DIFFERENTIAL_REWRITE_DIR/charset-fidelity" --report "$RUN_DIR/charset_fidelity.json"
echo "Dataset fidelity gate passed. Evidence and external-reader limitations: $RUN_DIR"
