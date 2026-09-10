#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

main() {
  create_local_dirs

  local resolved_path
  resolved_path="$(terraform_configured_pool_path)"
  record_terraform_pool_directory "${resolved_path}"
  printf '%s\n' "${resolved_path}"
}

main "$@"
