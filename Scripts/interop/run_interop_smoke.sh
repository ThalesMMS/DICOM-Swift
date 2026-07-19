#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
PROJECT_NAME="${DICOM_INTEROP_PROJECT:-mtk-dicom-interop}"
LOG_DIR="${DICOM_INTEROP_LOG_DIR:-${PACKAGE_DIR}/.build/interop-logs}"
KEEP_SERVICES=0
START_SERVICES=1
ARCHIVES="orthanc,dcm4chee"

usage() {
  cat <<'USAGE'
Run opt-in DICOM interop smoke tests against local Orthanc and dcm4chee.

Usage:
  Scripts/interop/run_interop_smoke.sh [--no-up] [--keep] [--orthanc-only]

Options:
  --no-up        Do not start docker compose services; use already-running endpoints.
  --keep         Leave services running after the smoke tests finish.
  --orthanc-only Start and test only Orthanc. Useful for quick local checks.
  -h, --help     Show this help.

Environment overrides:
  ORTHANC_HTTP_PORT, ORTHANC_DIMSE_PORT, ORTHANC_IMAGE
  DCM4CHEE_HTTP_PORT, DCM4CHEE_DIMSE_PORT, DCM4CHEE_ARC_IMAGE
  DICOM_INTEROP_LOG_DIR, DICOM_INTEROP_PROJECT
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-up)
      START_SERVICES=0
      shift
      ;;
    --keep)
      KEEP_SERVICES=1
      shift
      ;;
    --orthanc-only)
      ARCHIVES="orthanc"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

mkdir -p "${LOG_DIR}"

compose() {
  docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" "$@"
}

print_logs() {
  if command -v docker >/dev/null 2>&1; then
    compose ps >"${LOG_DIR}/docker-compose.ps.log" 2>&1 || true
    compose logs --tail=250 >"${LOG_DIR}/docker-compose.logs" 2>&1 || true
    echo "Interop logs written to ${LOG_DIR}" >&2
  fi
}

cleanup() {
  status=$?
  if [[ ${status} -ne 0 ]]; then
    print_logs
  fi
  if [[ ${START_SERVICES} -eq 1 && ${KEEP_SERVICES} -eq 0 ]]; then
    compose down >/dev/null 2>&1 || true
  fi
  exit "${status}"
}
trap cleanup EXIT

wait_http() {
  local name="$1"
  local url="$2"
  local attempts="${3:-90}"
  local delay="${4:-2}"

  echo "Waiting for ${name}: ${url}"
  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS "${url}" >/dev/null 2>&1; then
      echo "${name} is ready"
      return 0
    fi
    sleep "${delay}"
  done
  echo "${name} did not become ready at ${url}" >&2
  return 1
}

if [[ ${START_SERVICES} -eq 1 ]]; then
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker is required unless --no-up is used" >&2
    exit 69
  fi

  if [[ "${ARCHIVES}" == "orthanc" ]]; then
    compose up -d orthanc orthanc-auth
  else
    compose up -d orthanc orthanc-auth dcm4chee-arc
  fi
fi

wait_http "Orthanc HTTP" "http://127.0.0.1:${ORTHANC_HTTP_PORT:-8042}/system"
wait_http "Orthanc (auth) HTTP" "http://smoke:${ORTHANC_AUTH_PASSWORD:-smoke-secret}@127.0.0.1:${ORTHANC_AUTH_HTTP_PORT:-8043}/system"
if [[ "${ARCHIVES}" != "orthanc" ]]; then
  wait_http "dcm4chee HTTP" "http://127.0.0.1:${DCM4CHEE_HTTP_PORT:-8080}/dcm4chee-arc"
fi

export DICOM_INTEROP_SMOKE=1
export DICOM_INTEROP_ARCHIVES="${ARCHIVES}"
export DICOM_INTEROP_STORAGE_SCP_PORT="${DICOM_INTEROP_STORAGE_SCP_PORT:-11114}"

export DICOM_INTEROP_ORTHANC_DIMSE_HOST="${DICOM_INTEROP_ORTHANC_DIMSE_HOST:-127.0.0.1}"
export DICOM_INTEROP_ORTHANC_DIMSE_PORT="${DICOM_INTEROP_ORTHANC_DIMSE_PORT:-${ORTHANC_DIMSE_PORT:-4242}}"
export DICOM_INTEROP_ORTHANC_CALLED_AE="${DICOM_INTEROP_ORTHANC_CALLED_AE:-ORTHANC}"
export DICOM_INTEROP_ORTHANC_CALLING_AE="${DICOM_INTEROP_ORTHANC_CALLING_AE:-DICOMSWIFT}"
export DICOM_INTEROP_ORTHANC_DICOMWEB_URL="${DICOM_INTEROP_ORTHANC_DICOMWEB_URL:-http://127.0.0.1:${ORTHANC_HTTP_PORT:-8042}/dicom-web}"
export DICOM_INTEROP_ORTHANC_MOVE_DESTINATION_AE="${DICOM_INTEROP_ORTHANC_MOVE_DESTINATION_AE:-DICOMSWIFT}"
export DICOM_INTEROP_ORTHANC_CAPABILITIES="${DICOM_INTEROP_ORTHANC_CAPABILITIES:-dicomweb,dimse-echo,dimse-store,dimse-find,dimse-get,dimse-move,storage-scp}"

# Authenticated DICOMweb endpoint (issue #1223): exercised by the
# authenticated-path smoke test; credentials are local-only and non-secret.
export DICOM_INTEROP_ORTHANC_AUTH_DICOMWEB_URL="${DICOM_INTEROP_ORTHANC_AUTH_DICOMWEB_URL:-http://127.0.0.1:${ORTHANC_AUTH_HTTP_PORT:-8043}/dicom-web}"
export DICOM_INTEROP_ORTHANC_AUTH_USER="${DICOM_INTEROP_ORTHANC_AUTH_USER:-smoke}"
export DICOM_INTEROP_ORTHANC_AUTH_PASSWORD="${DICOM_INTEROP_ORTHANC_AUTH_PASSWORD:-${ORTHANC_AUTH_PASSWORD:-smoke-secret}}"

export DICOM_INTEROP_DCM4CHEE_DIMSE_HOST="${DICOM_INTEROP_DCM4CHEE_DIMSE_HOST:-127.0.0.1}"
export DICOM_INTEROP_DCM4CHEE_DIMSE_PORT="${DICOM_INTEROP_DCM4CHEE_DIMSE_PORT:-${DCM4CHEE_DIMSE_PORT:-11112}}"
export DICOM_INTEROP_DCM4CHEE_CALLED_AE="${DICOM_INTEROP_DCM4CHEE_CALLED_AE:-DCM4CHEE}"
export DICOM_INTEROP_DCM4CHEE_CALLING_AE="${DICOM_INTEROP_DCM4CHEE_CALLING_AE:-DICOMSWIFT}"
export DICOM_INTEROP_DCM4CHEE_DICOMWEB_URL="${DICOM_INTEROP_DCM4CHEE_DICOMWEB_URL:-http://127.0.0.1:${DCM4CHEE_HTTP_PORT:-8080}/dcm4chee-arc/aets/DCM4CHEE/rs}"
export DICOM_INTEROP_DCM4CHEE_CAPABILITIES="${DICOM_INTEROP_DCM4CHEE_CAPABILITIES:-dicomweb,dimse-echo,dimse-store,dimse-find}"

(
  cd "${PACKAGE_DIR}"
  swift test --filter DicomInteropSmokeTests 2>&1 | tee "${LOG_DIR}/swift-test.log"
)
