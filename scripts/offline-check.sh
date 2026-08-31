#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/common.sh"

REQUESTED_MODE="${1:-auto}"
TFVARS_PATH="${TERRAFORM_DIR}/terraform.tfvars"

read_tfvar() {
  local key="${1:?key required}"
  local default_value="${2:-}"
  if [[ ! -f "${TFVARS_PATH}" ]]; then
    printf '%s\n' "${default_value}"
    return 0
  fi

  python3 - "${TFVARS_PATH}" "${key}" "${default_value}" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
default = sys.argv[3]
pattern = re.compile(rf'^\s*{re.escape(key)}\s*=\s*(.+?)\s*$')

for raw_line in path.read_text(encoding="utf-8").splitlines():
    line = raw_line.split("#", 1)[0].strip()
    if not line:
        continue
    match = pattern.match(line)
    if not match:
        continue
    value = match.group(1).strip()
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    print(value)
    sys.exit(0)

print(default)
PY
}

main() {
  ensure_repo_layout
  ensure_command python3

  local lock_file image_path configured_image_path install_docker install_qga configured_mode
  lock_file="$(terraform_lock_file_path)"
  configured_image_path="$(read_tfvar "ubuntu_image_path" "../images/${DEFAULT_IMAGE_FILENAME}")"
  install_docker="$(read_tfvar "install_docker" "true")"
  install_qga="$(read_tfvar "install_qemu_guest_agent" "true")"
  image_path="$(python3 - "${TERRAFORM_DIR}" "${configured_image_path}" <<'PY'
import os
import sys

base, configured = sys.argv[1:]
if os.path.isabs(configured):
    print(os.path.realpath(configured))
else:
    print(os.path.realpath(os.path.join(base, configured)))
PY
)"

  [[ -f "${lock_file}" ]] || die "Terraform lock file missing: ${lock_file}. Run make init or make prepare-offline first."
  [[ -d "${CACHE_DIR}/terraform/provider-mirror" ]] || die "Terraform provider mirror missing. Run make prepare-offline first."
  [[ -f "${image_path}" ]] || die "Configured image path does not exist: ${image_path}"

  if [[ "${install_docker}" == "false" && "${install_qga}" == "false" && "${configured_image_path}" == *golden* ]]; then
    configured_mode="fully-prepared-candidate"
  else
    configured_mode="image-cached"
  fi

  if [[ "${configured_mode}" == "image-cached" ]]; then
    "${SCRIPT_DIR}/verify-image.sh" >/dev/null
  fi

  printf 'Offline assets status\n'
  printf '  Lock file:               %s\n' "${lock_file}"
  printf '  Provider mirror:         %s\n' "${CACHE_DIR}/terraform/provider-mirror"
  printf '  Configured image:        %s\n' "${image_path}"
  printf '  Configured mode:         %s\n' "${configured_mode}"

  case "${REQUESTED_MODE}" in
    auto)
      ;;
    image-cached)
      [[ "${configured_mode}" == "image-cached" ]] || die "Configured mode is ${configured_mode}, not image-cached."
      ;;
    fully-prepared)
      [[ "${configured_mode}" == "fully-prepared-candidate" ]] || die "A fully prepared offline configuration is not set. Use a local golden image and set install_docker=false and install_qemu_guest_agent=false."
      ;;
    *)
      die "Unsupported offline-check mode: ${REQUESTED_MODE}"
      ;;
  esac

  if [[ "${configured_mode}" == "image-cached" ]]; then
    warn "Guest package installation is still expected during first boot; this is not a fully offline guest build."
  else
    warn "The repository is configured for a fully prepared candidate image. This checks configuration intent only; it does not inspect qcow2 contents."
  fi
}

main "$@"
