#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

main() {
  ensure_command sha256sum
  local bundle_path hash_path

  bundle_path="${1:-}"
  if [[ -z "${bundle_path}" ]]; then
    bundle_path="$(find "${DIST_DIR}" -maxdepth 1 -type f -name "${PROJECT_SLUG}-*.tar.gz" | sort | tail -n 1)"
  fi
  [[ -n "${bundle_path}" ]] || die "No bundle path supplied and no bundle found in ${DIST_DIR}"

  hash_path="${bundle_path}.sha256"
  [[ -f "${bundle_path}" ]] || die "Bundle not found: ${bundle_path}"
  [[ -f "${hash_path}" ]] || die "Bundle checksum file not found: ${hash_path}"

  (
    cd -- "$(dirname -- "${bundle_path}")"
    sha256sum --check "$(basename -- "${hash_path}")"
  )
}

main "$@"
